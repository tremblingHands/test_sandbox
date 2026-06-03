#!/bin/bash
# ============================================================
# 沙箱冷启动测试 — 环境准备脚本
# 安装 containerd + crictl，拉取 pause 镜像，配置运行环境。
#
# 用法:
#   ./setup.sh                # 完整安装并检查
#   ./setup.sh --check-only   # 仅检查，不安装
# ============================================================
set -euo pipefail

PAUSE_IMAGE="registry.aliyuncs.com/google_containers/pause:3.9"
CRICTL_VERSION="v1.30.0"
CONTAINERD_VERSION="1.7.19"

# 自动检测架构
detect_arch() {
    local machine
    machine=$(uname -m)
    case "$machine" in
        x86_64)     echo "amd64" ;;
        aarch64)    echo "arm64" ;;
        arm64)      echo "arm64" ;;
        *)
            echo "ERROR: 不支持的架构: $machine (仅支持 amd64 / arm64)" >&2
            exit 1
            ;;
    esac
}
ARCH=$(detect_arch)

CHECK_ONLY=false
if [[ "${1:-}" == "--check-only" ]]; then
    CHECK_ONLY=true
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; }

# ============================================================
# 检查 containerd
# ============================================================
check_containerd() {
    echo "--- containerd ---"

    # 检查二进制
    if command -v containerd &>/dev/null; then
        local ver
        ver=$(containerd --version 2>/dev/null | head -1)
        pass "containerd 已安装: $ver"
    else
        if $CHECK_ONLY; then
            fail "containerd 未安装"
            return 1
        fi
        warn "containerd 未安装，正在安装..."

        # 下载 containerd
        local url="https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-${ARCH}.tar.gz"
        echo "  下载: $url"
        curl -fsSL "$url" -o /tmp/containerd.tar.gz
        sudo tar -C /usr/local -xzf /tmp/containerd.tar.gz
        rm -f /tmp/containerd.tar.gz

        # 安装 systemd service
        if ! [ -f /usr/lib/systemd/system/containerd.service ]; then
            echo "  安装 systemd service..."
            curl -fsSL https://raw.githubusercontent.com/containerd/containerd/v${CONTAINERD_VERSION}/containerd.service | \
                sudo tee /usr/lib/systemd/system/containerd.service > /dev/null
            sudo systemctl daemon-reload
            sudo systemctl enable containerd
        fi
        pass "containerd 安装完成"
    fi

    # 检查 runc
    if command -v runc &>/dev/null; then
        pass "runc 已安装: $(runc --version | head -1)"
    else
        if $CHECK_ONLY; then
            warn "runc 未安装（containerd 可能需要手动安装 runc）"
        fi
    fi

    # 检查服务状态
    if systemctl is-active --quiet containerd 2>/dev/null; then
        pass "containerd 服务运行中"
    else
        if $CHECK_ONLY; then
            warn "containerd 服务未运行"
            return 1
        fi
        warn "启动 containerd 服务..."
        sudo systemctl start containerd
        sleep 2
        if systemctl is-active --quiet containerd; then
            pass "containerd 服务已启动"
        else
            fail "containerd 启动失败，检查 journalctl -u containerd"
            return 1
        fi
    fi

    # 检查 snapshotters
    if ctr plugins ls 2>/dev/null | grep -q io.containerd.snapshotter; then
        pass "containerd snapshotter 插件就绪"
    fi

    return 0
}

# ============================================================
# 检查 CNI 网络配置（确保子网够大，支持大量 pod）
# ============================================================
CNI_CONF_FILE="/etc/cni/net.d/10-mynet.conf"
CNI_SUBNET="10.0.0.0/12"          # ~100 万 IP，足够大规模并发测试

check_cni_network() {
    echo ""
    echo "--- CNI 网络配置 ---"

    # 确保 CNI 配置目录存在
    local cni_dir
    cni_dir=$(dirname "$CNI_CONF_FILE")
    if [ ! -d "$cni_dir" ]; then
        if $CHECK_ONLY; then
            warn "CNI 配置目录不存在: $cni_dir"
            return 1
        fi
        sudo mkdir -p "$cni_dir"
    fi

    # 如果配置文件不存在，创建默认配置
    if [ ! -f "$CNI_CONF_FILE" ]; then
        if $CHECK_ONLY; then
            warn "CNI 配置文件不存在: $CNI_CONF_FILE"
            return 1
        fi
        echo "  创建 CNI bridge 配置 (subnet=$CNI_SUBNET)..."
        cat | sudo tee "$CNI_CONF_FILE" > /dev/null <<'CONFEOF'
{
  "cniVersion": "0.3.1",
  "name": "mynet",
  "type": "bridge",
  "bridge": "cni0",
  "isGateway": true,
  "ipMasq": true,
  "ipam": {
    "type": "host-local",
    "subnet": "10.0.0.0/12",
    "routes": [
      { "dst": "0.0.0.0/0" }
    ]
  }
}
CONFEOF
        pass "CNI bridge 配置已创建 (subnet=$CNI_SUBNET)"
        # 重启使配置生效
        sudo systemctl restart containerd
        sleep 2
        return 0
    fi

    # 检查子网配置是否足够大
    local current_subnet
    current_subnet=$(grep -o '"subnet": "[^"]*"' "$CNI_CONF_FILE" 2>/dev/null | head -1 | cut -d'"' -f4)

    if [ -z "$current_subnet" ]; then
        warn "无法解析当前 CNI subnet"
        return 1
    fi

    # 计算子网位数
    local mask
    mask=$(echo "$current_subnet" | cut -d'/' -f2)

    if [ "$mask" -le 12 ] 2>/dev/null; then
        pass "CNI subnet 已足够大: $current_subnet"
    else
        if $CHECK_ONLY; then
            warn "CNI subnet 太小: $current_subnet (推荐 /12 或更小)"
            return 1
        fi
        echo "  扩大 CNI subnet: $current_subnet → $CNI_SUBNET ..."
        sudo sed -i "s|\"subnet\": \"[^\"]*\"|\"subnet\": \"$CNI_SUBNET\"|" "$CNI_CONF_FILE"
        # 清理旧的 IP 分配记录（子网变了旧记录无效）
        sudo rm -rf /var/lib/cni/networks/mynet/
        # 删除旧网桥（否则新子网 IP 无法绑定）
        sudo ip link delete cni0 2>/dev/null || true
        pass "CNI subnet 已更新为: $CNI_SUBNET"

        # 重启 containerd 使配置生效
        echo "  重启 containerd 使 CNI 配置生效..."
        sudo systemctl restart containerd
        sleep 2
        pass "containerd 已重启"
    fi

    return 0
}

# ============================================================
# 检查 crictl
# ============================================================
check_crictl() {
    echo ""
    echo "--- crictl ---"

    if command -v crictl &>/dev/null; then
        local ver
        ver=$(crictl --version 2>/dev/null | head -1)
        pass "crictl 已安装: $ver"
    else
        if $CHECK_ONLY; then
            fail "crictl 未安装"
            return 1
        fi
        warn "crictl 未安装，正在安装 v${CRICTL_VERSION}..."

        local url="https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz"
        echo "  下载: $url"
        curl -fsSL "$url" -o /tmp/crictl.tar.gz
        sudo tar -C /usr/local/bin -xzf /tmp/crictl.tar.gz
        sudo chmod +x /usr/local/bin/crictl
        rm -f /tmp/crictl.tar.gz
        pass "crictl 安装完成: $(crictl --version)"
    fi

    return 0
}

# ============================================================
# 检查 crictl 配置文件
# ============================================================
check_crictl_config() {
    echo ""
    echo "--- crictl 连接配置 ---"

    local config_file="/etc/crictl.yaml"
    local expected_endpoint="unix:///run/containerd/containerd.sock"

    if [ -f "$config_file" ]; then
        pass "crictl 配置文件存在: $config_file"
    else
        if $CHECK_ONLY; then
            warn "crictl 配置文件不存在，将使用默认 endpoint"
        else
            echo "  写入 crictl 配置..."
            cat | sudo tee "$config_file" > /dev/null <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint: unix:///run/containerd/containerd.sock
timeout: 30
debug: false
EOF
            pass "crictl 配置已写入"
        fi
    fi

    # 验证连接
    if crictl info &>/dev/null; then
        pass "crictl 连接 containerd 正常"
    else
        if $CHECK_ONLY; then
            fail "crictl 无法连接 containerd"
            return 1
        fi
        fail "crictl 无法连接到 containerd，请检查:"
        echo "  1. containerd 是否已启动: systemctl status containerd"
        echo "  2. socket 路径是否正确: ls -la /run/containerd/containerd.sock"
        return 1
    fi

    return 0
}

# ============================================================
# 配置 registry 镜像源（registry.k8s.io → 阿里云）
# ============================================================
check_registry_mirror() {
    echo ""
    echo "--- registry 镜像源 ---"

    local certs_dir="/etc/containerd/certs.d"
    local hosts_file="$certs_dir/registry.k8s.io/hosts.toml"

    # ---- 1. hosts.toml: registry.k8s.io 映射到阿里云 ---- #
    if [ -f "$hosts_file" ]; then
        pass "registry.k8s.io → 阿里云镜像源 已配置"
    else
        if $CHECK_ONLY; then
            warn "registry.k8s.io 未配置镜像源"
            return 1
        fi

        # 设置 containerd config_path
        local config_file="/etc/containerd/config.toml"
        if ! grep -q "config_path.*certs.d" "$config_file" 2>/dev/null; then
            if grep -q "config_path" "$config_file"; then
                sudo sed -i "s|config_path = .*|config_path = '$certs_dir'|" "$config_file"
            else
                sudo sed -i "/\[plugins.'io.containerd.cri.v1.images'.registry\]/a\      config_path = '$certs_dir'" "$config_file"
            fi
        fi

        sudo mkdir -p "$(dirname "$hosts_file")"
        cat | sudo tee "$hosts_file" > /dev/null <<TOML
server = "https://registry.k8s.io"

[host."https://registry.aliyuncs.com/google_containers"]
  capabilities = ["pull", "resolve"]
TOML
        need_restart=true
        pass "registry.k8s.io → 阿里云镜像源 配置完成"
    fi

    # ---- 2. pinned_images: 替换为阿里云镜像 ---- #
    local config_file="/etc/containerd/config.toml"
    if grep -q "pinned_images" "$config_file" 2>/dev/null; then
        if grep -q "registry.k8s.io/pause" "$config_file" 2>/dev/null; then
            if $CHECK_ONLY; then
                warn "containerd pinned_images 仍指向 registry.k8s.io，需替换为阿里云镜像"
                return 1
            fi
            echo "  替换 pinned_images sandbox 镜像为阿里云源..."
            sudo sed -i "s|sandbox = 'registry.k8s.io/pause:[^']*'|sandbox = '$PAUSE_IMAGE'|" "$config_file"
            need_restart=true
            pass "pinned_images 已更新为: $PAUSE_IMAGE"
        else
            pass "pinned_images 已指向可用镜像源"
        fi
    else
        pass "未使用 pinned_images（无需修改）"
    fi

    # ---- 3. 修复 runc systemd cgroup 兼容性 ---- #
    if grep -q "SystemdCgroup = true" "$config_file" 2>/dev/null; then
        if $CHECK_ONLY; then
            warn "runc SystemdCgroup=true 可能导致 cgroup 路径格式错误"
            return 1
        fi
        echo "  禁用 runc SystemdCgroup（使用标准 cgroups 路径）..."
        sudo sed -i 's/SystemdCgroup = true/SystemdCgroup = false/' "$config_file"
        need_restart=true
        pass "runc SystemdCgroup 已禁用"
    fi

    # ---- 4. 配置有变更时重启 containerd ---- #
    if ${need_restart:-false}; then
        echo "  重启 containerd 使配置生效..."
        if sudo systemctl restart containerd; then
            sleep 2
        else
            fail "containerd 重启失败"
            return 1
        fi
    fi

    return 0
}

# ============================================================
# 检查 pause 镜像
# ============================================================
check_pause_image() {
    echo ""
    echo "--- pause 镜像 ---"

    if crictl images -q 2>/dev/null | grep -qF "$PAUSE_IMAGE"; then
        pass "pause 镜像已缓存: $PAUSE_IMAGE"
        return 0
    fi

    if $CHECK_ONLY; then
        fail "pause 镜像缺失: $PAUSE_IMAGE"
        return 1
    fi

    warn "pause 镜像缺失，正在拉取: $PAUSE_IMAGE ..."
    if crictl pull "$PAUSE_IMAGE"; then
        pass "pause 镜像拉取完成"
        return 0
    fi

    fail "pause 镜像拉取失败，请检查网络"
    return 1
}

# ============================================================
# 检查内核参数
# ============================================================
check_kernel_params() {
    echo ""
    echo "--- 内核参数 ---"

    local params=(
        "vm.max_map_count:262144"
        "fs.inotify.max_user_instances:8192"
        "fs.inotify.max_user_watches:1048576"
    )

    for param_entry in "${params[@]}"; do
        local name="${param_entry%:*}"
        local recommended="${param_entry#*:}"
        local current
        current=$(sysctl -n "$name" 2>/dev/null || echo "unknown")
        if [ "$current" -ge "$recommended" ] 2>/dev/null; then
            pass "$name = $current (推荐 >= $recommended)"
        else
            if $CHECK_ONLY; then
                warn "$name = $current (推荐 >= $recommended)"
            else
                warn "$name = $current，正在设置为 $recommended..."
                sudo sysctl -w "${name}=${recommended}" > /dev/null
                pass "$name 已设置为 $recommended"
            fi
        fi
    done

    return 0
}

# ============================================================
# 主流程
# ============================================================
main() {
    echo "=============================================="
    echo "  沙箱冷启动测试 — 环境准备"
    echo "=============================================="
    echo "  检测架构: $(uname -m) → $ARCH"
    echo "  安装目标: containerd + crictl + pause 镜像"
    echo "  pause 镜像: $PAUSE_IMAGE"
    echo "=============================================="
    echo

    local errors=0

    check_containerd      || errors=$((errors + 1))
    check_cni_network     || errors=$((errors + 1))
    check_crictl          || errors=$((errors + 1))
    check_crictl_config   || { [[ $? -eq 1 ]] && errors=$((errors + 1)); }
    check_registry_mirror || errors=$((errors + 1))
    check_pause_image     || errors=$((errors + 1))
    check_kernel_params

    echo ""
    echo "=============================================="
    if [ "$errors" -eq 0 ]; then
        echo -e "${GREEN}所有前置条件满足 ✓${NC}"
    else
        echo -e "${RED}$errors 项检查未通过${NC}"
        echo "请根据上述提示修复后重新运行"
    fi
    echo "=============================================="
    echo ""
    echo "下一步:"
    echo "  # 单发冷启动测试"
    echo "  python3 scripts/cold_start_bench.py --runs 50"
    echo ""
    echo "  # 并发冷启动测试"
    echo "  ./scripts/concurrent_cold_start.sh 10 3"
    echo ""

    return $errors
}

main
