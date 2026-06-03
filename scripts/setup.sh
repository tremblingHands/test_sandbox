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

PAUSE_IMAGE="registry.k8s.io/pause:3.9"
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
# 配置 registry 镜像源（阿里云）
# ============================================================
ALIYUN_K8S_MIRROR="https://registry.aliyuncs.com/google_containers"

check_registry_mirror() {
    echo ""
    echo "--- registry 镜像源 ---"

    # containerd v2 使用 hosts.toml 目录方式配置 mirror
    local certs_dir="/etc/containerd/certs.d"
    local hosts_dir="$certs_dir/registry.k8s.io"
    local hosts_file="$hosts_dir/hosts.toml"

    if [ -f "$hosts_file" ]; then
        pass "registry.k8s.io 镜像源已配置: $ALIYUN_K8S_MIRROR"
        return 0
    fi

    if $CHECK_ONLY; then
        warn "registry.k8s.io 未配置国内镜像源，拉取可能超时"
        return 1
    fi

    # 1. 确保 containerd 主配置设定了 config_path
    local config_file="/etc/containerd/config.toml"
    local config_path_line="config_path = '$certs_dir'"

    if ! grep -q "config_path.*certs.d" "$config_file" 2>/dev/null; then
        echo "  设置 containerd registry config_path..."
        # 在 [plugins.'io.containerd.cri.v1.images'.registry] 段下设置 config_path
        if grep -q "config_path" "$config_file"; then
            sudo sed -i "s|config_path = .*|config_path = '$certs_dir'|" "$config_file"
        else
            sudo sed -i "/\[plugins.'io.containerd.cri.v1.images'.registry\]/a\      config_path = '$certs_dir'" "$config_file"
        fi
    fi

    # 2. 创建 registry.k8s.io 的 hosts.toml
    echo "  配置 registry.k8s.io → $ALIYUN_K8S_MIRROR ..."
    sudo mkdir -p "$hosts_dir"
    cat | sudo tee "$hosts_file" > /dev/null <<TOML
server = "https://registry.k8s.io"

[host."$ALIYUN_K8S_MIRROR"]
  capabilities = ["pull", "resolve"]
TOML

    # 3. 重启 containerd 使配置生效
    echo "  重启 containerd 使镜像源配置生效..."
    if sudo systemctl restart containerd; then
        sleep 2
        pass "registry 镜像源配置完成"
    else
        fail "containerd 重启失败，请检查 /etc/containerd/config.toml"
        return 1
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
    if crictl pull "$PAUSE_IMAGE" 2>&1; then
        pass "pause 镜像拉取完成"
        return 0
    fi

    # 直接拉取失败时，尝试从阿里云镜像源拉取然后 re-tag
    warn "直接拉取失败，尝试从阿里云镜像源拉取..."
    local aliyun_image="registry.aliyuncs.com/google_containers/pause:3.9"
    # 关键: crictl 使用 k8s.io namespace，必须在这个 namespace 下操作
    if ctr -n k8s.io image pull "$aliyun_image" 2>&1; then
        ctr -n k8s.io image tag "$aliyun_image" "$PAUSE_IMAGE" 2>/dev/null || true
        pass "pause 镜像已从阿里云镜像源拉取并标记"
        return 0
    fi

    fail "pause 镜像拉取失败（已尝试直接拉取和阿里云镜像源），请检查网络"
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
