#!/bin/bash
# ============================================================
# 沙箱冷启动测试 — 环境准备脚本
# 安装 containerd + crictl，拉取 pause 镜像，配置运行环境。
#
# 用法:
#   ./setup.sh                          # 完整安装，默认 ipvlan-l3
#   ./setup.sh --cni-type bridge        # 使用 bridge CNI
#   ./setup.sh --cni-type ipvlan-l2     # 使用 ipvlan L2 CNI
#   ./setup.sh --cni-type ipvlan-l3     # 使用 ipvlan L3 CNI（默认）
#   ./setup.sh --check-only              # 仅检查，不安装
# ============================================================
set -euo pipefail

PAUSE_IMAGE="registry.aliyuncs.com/google_containers/pause:3.9"
CRICTL_VERSION="v1.30.0"
CONTAINERD_VERSION="1.7.19"
CNI_TYPE="ipvlan-l3"          # 默认: ipvlan L3（百万 pod 规模，无 bridge 瓶颈）
CONTAINERD_RUNTIME="runc"     # 默认: runc
KATA_VERSION="3.22.0"         # kata containers 版本

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
# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check-only)
            CHECK_ONLY=true; shift ;;
        --cni-type)
            CNI_TYPE="$2"
            case "$CNI_TYPE" in
                bridge|ipvlan-l2|ipvlan-l3) ;;
                *) echo "ERROR: --cni-type 必须是 bridge | ipvlan-l2 | ipvlan-l3"; exit 1 ;;
            esac
            shift 2 ;;
        --runtime)
            CONTAINERD_RUNTIME="$2"
            case "$CONTAINERD_RUNTIME" in
                runc|kata) ;;
                *) echo "ERROR: --runtime 必须是 runc | kata"; exit 1 ;;
            esac
            shift 2 ;;
        *)
            echo "ERROR: 未知参数: $1"
            echo "用法: $0 [--cni-type bridge|ipvlan-l2|ipvlan-l3] [--runtime runc|kata] [--check-only]"
            exit 1 ;;
    esac
done

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
# 检查 CNI 网络配置
# 支持 bridge / ipvlan-l2 / ipvlan-l3，默认 ipvlan-l3（百万 pod 规模无瓶颈）
# ============================================================
CNI_CONF_FILE="/etc/cni/net.d/10-mynet.conf"
CNI_SUBNET="10.0.0.0/12"          # ~100 万 IP

# 自动检测默认路由对应的物理网卡（ipvlan master）
detect_master_iface() {
    local iface
    iface=$(ip -o route show default 2>/dev/null | head -1 | awk '{print $5}')
    if [ -z "$iface" ]; then
        # fallback: 找第一个非 lo 的 UP 状态的物理网卡
        iface=$(ip -o link show up 2>/dev/null | grep -v 'lo' | head -1 | awk -F': ' '{print $2}' | awk '{print $1}')
    fi
    echo "${iface:-eth0}"
}

# ============================================================
# 检查 kata runtime（仅在 --runtime kata 时执行）
# ============================================================
KATA_INSTALL_DIR="/opt/kata"
KATA_BIN_DIR="$KATA_INSTALL_DIR/bin"
# kata-static tarball 内部前缀为 ./opt/kata/，需解压到 / 才能对齐

check_kata_runtime() {
    # 非 kata 模式直接跳过
    if [ "$CONTAINERD_RUNTIME" != "kata" ]; then
        return 0
    fi

    echo ""
    echo "--- Kata Containers ---"

    # ---- 1. 检查 kata shim（优先 runtime-rs 静态二进制，兼容旧 glibc） ---- #
    local kata_bin="$KATA_BIN_DIR/kata-runtime"
    local kata_shim="$KATA_BIN_DIR/containerd-shim-kata-v2"
    local kata_rs_shim="$KATA_INSTALL_DIR/runtime-rs/bin/containerd-shim-kata-v2"

    # runtime-rs 是静态链接的 Rust 二进制，无需高版本 glibc
    if [ -x "$kata_rs_shim" ]; then
        pass "kata runtime-rs shim 可用: $kata_rs_shim"
        kata_shim="$kata_rs_shim"
    elif [ -x "$kata_shim" ] && ldd "$kata_shim" &>/dev/null; then
        ver=$("$kata_bin" --version 2>/dev/null | head -1 || echo "kata (glibc)")
        pass "kata-runtime 已安装: $ver"
    else
        if $CHECK_ONLY; then
            fail "kata-runtime 未安装（需要 --runtime kata）"
            return 1
        fi
        warn "kata-runtime 未安装，正在安装 v${KATA_VERSION}..."

        # 确保 zstd 解压工具可用
        if ! command -v zstd &>/dev/null; then
            echo "  安装 zstd..."
            sudo apt-get update -qq && sudo apt-get install -y -qq zstd 2>/dev/null || \
                sudo yum install -y -q zstd 2>/dev/null || true
        fi

        local kata_url="https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/kata-static-${KATA_VERSION}-${ARCH}.tar.zst"
        echo "  下载: $kata_url"
        local tmpdir
        tmpdir=$(mktemp -d)
        curl -fsSL "$kata_url" -o "$tmpdir/kata.tar.zst"

        # kata-static tarball 内部前缀为 ./opt/kata/，需解压到 / 根目录
        if sudo tar --zstd -xf "$tmpdir/kata.tar.zst" -C / 2>/dev/null; then
            true
        elif command -v zstd &>/dev/null; then
            zstd -d "$tmpdir/kata.tar.zst" -o "$tmpdir/kata.tar" 2>/dev/null || \
                zstdcat "$tmpdir/kata.tar.zst" > "$tmpdir/kata.tar"
            sudo tar -C / -xf "$tmpdir/kata.tar"
        else
            fail "无法解压 .tar.zst 文件（需要 zstd 或 tar --zstd）"
            rm -rf "$tmpdir"
            return 1
        fi
        rm -rf "$tmpdir"

        # kata-static 解包后查找 shim（优先 runtime-rs 静态二进制）
        if [ ! -x "$kata_shim" ]; then
            local found_shim
            # 优先 runtime-rs（静态链接，兼容旧 glibc）
            found_shim=$(find "$KATA_INSTALL_DIR" -path "*/runtime-rs/bin/containerd-shim-kata-v2" -type f 2>/dev/null | head -1)
            if [ -z "$found_shim" ]; then
                found_shim=$(find "$KATA_INSTALL_DIR" -name "containerd-shim-kata-v2" -type f 2>/dev/null | head -1)
            fi
            if [ -n "$found_shim" ]; then
                kata_shim="$found_shim"
            fi
        fi

        if [ -x "$kata_shim" ]; then
            pass "kata-runtime 安装完成: $("$kata_bin" --version 2>/dev/null | head -1 || echo ok)"
        else
            fail "kata-runtime 安装失败，未找到 containerd-shim-kata-v2"
            return 1
        fi
    fi

    # ---- 1.5 修补 runtime-rs QEMU 配置（ARM64 兼容性） ---- #
    local kata_config
    kata_config=$(find "$KATA_INSTALL_DIR" -name "configuration-qemu-runtime-rs.toml" -type f 2>/dev/null | head -1)
    if [ -z "$kata_config" ]; then
        kata_config="/opt/kata/share/defaults/kata-containers/runtime-rs/configuration-qemu-runtime-rs.toml"
    fi

    if [ -f "$kata_config" ]; then
        echo "  修补 runtime-rs QEMU 配置（ARM64 适配）..."
        # 1. machine_type: q35 是 x86 专用，ARM64 必须用 virt
        sudo sed -i 's|machine_type = ""|machine_type = "virt"|' "$kata_config"
        # 2. nvdimm: ARM64 virt 机型不支持
        sudo sed -i 's|machine_accelerators=""|machine_accelerators="nvdimm=off"|' "$kata_config"
        # 3. kernel: vmlinux.container 不存在，用实际文件
        local actual_kernel
        actual_kernel=$(ls /opt/kata/share/kata-containers/vmlinux-* 2>/dev/null | head -1)
        if [ -n "$actual_kernel" ]; then
            sudo sed -i "s|kernel = .*|kernel = \"$actual_kernel\"|" "$kata_config"
        fi
        # 4. firmware: ARM64 需要 UEFI firmware
        if grep -q 'firmware = ""' "$kata_config" 2>/dev/null; then
            sudo sed -i 's|firmware = ""|firmware = "/opt/kata/share/kata-qemu/qemu/edk2-aarch64-code.fd"|' "$kata_config"
            sudo sed -i 's|firmware_volume = ""|firmware_volume = "/opt/kata/share/kata-qemu/qemu/edk2-arm-vars.fd"|' "$kata_config"
        fi
        # 5. rootfs: 改用 initrd（跳过 virtio-fs 兼容问题）
        if grep -q '^image = ' "$kata_config" 2>/dev/null; then
            local actual_initrd
            actual_initrd=$(ls /opt/kata/share/kata-containers/kata-*.initrd 2>/dev/null | head -1)
            if [ -n "$actual_initrd" ]; then
                sudo sed -i 's|^image = .*|# image = "/opt/kata/share/kata-containers/kata-containers.img"|' "$kata_config"
                sudo sed -i "s|^# initrd = .*|initrd = \"$actual_initrd\"|" "$kata_config"
                sudo sed -i 's|disable_block_device_use = false|disable_block_device_use = true|' "$kata_config"
            fi
        fi
        # 6. rootfs driver: virtio-pmem → virtio-blk-pci（更兼容）
        sudo sed -i 's|vm_rootfs_driver = "virtio-pmem"|vm_rootfs_driver = "virtio-blk-pci"|' "$kata_config"
        pass "runtime-rs QEMU 配置已修补"
    else
        warn "未找到 runtime-rs QEMU 配置文件，跳过修补"
    fi

    # ---- 2. 检查 containerd 是否注册了 kata runtime ---- #
    local config_file="/etc/containerd/config.toml"
    if grep -q "io.containerd.kata.v2" "$config_file" 2>/dev/null; then
        pass "containerd 已注册 kata runtime"
        return 0
    fi

    if $CHECK_ONLY; then
        warn "containerd 未注册 kata runtime"
        return 1
    fi

    echo "  注册 kata runtime 到 containerd..."

    # 找到 kata 配置文件（runtime-rs 使用 runtime-rs 子目录下的配置）
    local kata_config_path
    if echo "$kata_shim" | grep -q "runtime-rs"; then
        kata_config_path=$(find "$KATA_INSTALL_DIR" -name "configuration.toml" -path "*/runtime-rs/*" 2>/dev/null | head -1)
    fi
    if [ -z "$kata_config_path" ]; then
        kata_config_path=$(find "$KATA_INSTALL_DIR" -name "configuration.toml" -path "*/kata-containers/*" 2>/dev/null | head -1)
    fi
    if [ -z "$kata_config_path" ]; then
        kata_config_path="/opt/kata/share/defaults/kata-containers/configuration.toml"
    fi

    # 附加 kata runtime 到 containerd config.toml 末尾
    # TOML 完整路径格式，append 到文件末尾即可
    sudo tee -a "$config_file" > /dev/null <<KATAEOF

[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.kata]
  runtime_type = 'io.containerd.kata.v2'
  runtime_path = '$kata_shim'
  privileged_without_host_devices = true
  pod_annotations = ['io.katacontainers.*']
  [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.kata.options]
    ConfigPath = '$kata_config_path'
KATAEOF

    # 重启 containerd 使配置生效
    echo "  重启 containerd 使 kata runtime 生效..."
    if ! sudo systemctl restart containerd; then
        fail "containerd 重启失败，检查 /etc/containerd/config.toml"
        return 1
    fi
    sleep 3

    # 验证注册成功
    if grep -q "io.containerd.kata.v2" "$config_file"; then
        # 进一步验证 containerd 能识别
        if ctr plugins ls 2>/dev/null | grep -q "io.containerd.kata"; then
            pass "kata runtime 已注册到 containerd"
        else
            warn "kata 配置已写入，但 containerd 未加载 kata 插件（可能需手动检查）"
        fi
    else
        fail "kata runtime 注册失败"
        return 1
    fi

    return 0
}

# ============================================================
check_cni_network() {
    echo ""
    echo "--- CNI 网络配置 (类型: $CNI_TYPE) ---"

    local cni_dir
    cni_dir=$(dirname "$CNI_CONF_FILE")
    if [ ! -d "$cni_dir" ]; then
        if $CHECK_ONLY; then
            warn "CNI 配置目录不存在: $cni_dir"
            return 1
        fi
        sudo mkdir -p "$cni_dir"
    fi

    # ---- 检测当前配置类型 ---- #
    local current_type="none"
    if [ -f "$CNI_CONF_FILE" ]; then
        current_type=$(grep -o '"type": "[^"]*"' "$CNI_CONF_FILE" 2>/dev/null | head -1 | cut -d'"' -f4)
    fi

    # ---- 配置不存在或类型不匹配 → 重新创建 ---- #
    if [ "$current_type" != "$CNI_TYPE" ]; then
        if $CHECK_ONLY; then
            warn "CNI 配置类型不匹配: 当前=$current_type, 需要=$CNI_TYPE"
            return 1
        fi

        # 清理旧的 CNI 状态
        case "$current_type" in
            bridge)
                sudo rm -rf /var/lib/cni/networks/mynet/
                sudo ip link delete cni0 2>/dev/null || true
                ;;
        esac

        echo "  创建 CNI $CNI_TYPE 配置 (subnet=$CNI_SUBNET)..."

        case "$CNI_TYPE" in
            bridge)
                cat | sudo tee "$CNI_CONF_FILE" > /dev/null <<CONFEOF
{
  "cniVersion": "0.3.1",
  "name": "mynet",
  "type": "bridge",
  "bridge": "cni0",
  "isGateway": true,
  "ipMasq": true,
  "ipam": {
    "type": "host-local",
    "subnet": "$CNI_SUBNET",
    "routes": [
      { "dst": "0.0.0.0/0" }
    ]
  }
}
CONFEOF
                ;;
            ipvlan-l2)
                local master
                master=$(detect_master_iface)
                echo "  ipvlan master 网卡: $master"
                cat | sudo tee "$CNI_CONF_FILE" > /dev/null <<CONFEOF
{
  "cniVersion": "0.3.1",
  "name": "mynet",
  "type": "ipvlan",
  "master": "$master",
  "mode": "l2",
  "ipam": {
    "type": "host-local",
    "subnet": "$CNI_SUBNET",
    "routes": [
      { "dst": "0.0.0.0/0" }
    ]
  }
}
CONFEOF
                ;;
            ipvlan-l3)
                local master
                master=$(detect_master_iface)
                echo "  ipvlan master 网卡: $master"
                cat | sudo tee "$CNI_CONF_FILE" > /dev/null <<CONFEOF
{
  "cniVersion": "0.3.1",
  "name": "mynet",
  "type": "ipvlan",
  "master": "$master",
  "mode": "l3",
  "ipam": {
    "type": "host-local",
    "subnet": "$CNI_SUBNET",
    "routes": [
      { "dst": "0.0.0.0/0" }
    ]
  }
}
CONFEOF
                ;;
        esac

        pass "CNI $CNI_TYPE 配置已创建"
        sudo systemctl restart containerd
        sleep 2
        return 0
    fi

    # ---- 配置已存在且类型匹配，检查子网 ---- #
    local current_subnet
    current_subnet=$(grep -o '"subnet": "[^"]*"' "$CNI_CONF_FILE" 2>/dev/null | head -1 | cut -d'"' -f4)

    if [ -z "$current_subnet" ]; then
        warn "无法解析当前 CNI subnet"
        return 1
    fi

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
        sudo rm -rf /var/lib/cni/networks/mynet/
        if [ "$CNI_TYPE" = "bridge" ]; then
            sudo ip link delete cni0 2>/dev/null || true
        fi
        pass "CNI subnet 已更新为: $CNI_SUBNET"
        sudo systemctl restart containerd
        sleep 2
    fi

    # ---- bridge 专属：hash_max ---- #
    if [ "$CNI_TYPE" = "bridge" ] && [ -d "/sys/class/net/cni0/bridge" ]; then
        local target_hash_max=1048576
        local current_hash
        current_hash=$(cat /sys/class/net/cni0/bridge/hash_max 2>/dev/null || echo 0)
        if [ "$current_hash" -lt "$target_hash_max" ] 2>/dev/null; then
            if $CHECK_ONLY; then
                warn "bridge hash_max 太小: $current_hash (推荐 $target_hash_max)"
                return 1
            fi
            echo "  扩大 bridge hash_max: $current_hash → $target_hash_max ..."
            sudo sh -c "echo $target_hash_max > /sys/class/net/cni0/bridge/hash_max"
            pass "bridge hash_max 已更新为: $(cat /sys/class/net/cni0/bridge/hash_max)"
        else
            pass "bridge hash_max 已足够大: $current_hash"
        fi
    fi

    # ---- ipvlan 专属：验证 master 网卡存在 ---- #
    if [[ "$CNI_TYPE" == ipvlan-* ]]; then
        local master
        master=$(grep -o '"master": "[^"]*"' "$CNI_CONF_FILE" 2>/dev/null | head -1 | cut -d'"' -f4)
        if ip link show "$master" &>/dev/null; then
            pass "ipvlan master 网卡可用: $master"
        else
            if $CHECK_ONLY; then
                fail "ipvlan master 网卡不可用: $master"
                return 1
            fi
            fail "ipvlan master 网卡不可用: $master，请修改 $CNI_CONF_FILE"
            return 1
        fi
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
    echo "  Runtime:  $CONTAINERD_RUNTIME"
    echo "  CNI 类型: $CNI_TYPE"
    echo "  pause 镜像: $PAUSE_IMAGE"
    echo "=============================================="
    echo

    local errors=0

    check_containerd      || errors=$((errors + 1))
    check_kata_runtime    || errors=$((errors + 1))
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
