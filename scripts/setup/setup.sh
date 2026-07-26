#!/bin/bash
# ============================================================
# 沙箱冷启动测试 — 环境准备脚本
# 安装 containerd + crictl，拉取 pause 镜像，配置运行环境。
#
# 用法:
#   ./setup.sh                               # 完整安装，runc + ipvlan-l3
#   ./setup.sh --runtime kata                # kata + qemu（默认 hypervisor）
#   ./setup.sh --runtime kata --hypervisor dragonball
#   ./setup.sh --runtime kata --hypervisor cloud-hypervisor
#   ./setup.sh --runtime kata --hypervisor firecracker
#   ./setup.sh --cni-type bridge             # 使用 bridge CNI（默认 ipMasq=false）
#   ./setup.sh --cni-type bridge --ip-masq true   # bridge 且开启 per-sandbox MASQUERADE
#   ./setup.sh --snapshotter erofs           # 使用 erofs snapshotter
#   ./setup.sh --check-only                   # 仅检查，不安装
#   ./setup.sh --no-warmup                    # 成功后不跑 cold_start_bench warmup
#
# 安装包缓存:
#   默认目录 <repo>/install/（可用环境变量 INSTALL_FILES_DIR 覆盖，已在 .gitignore）
#   优先使用该目录中的包；没有则下载并保存到该目录，供下次复用
# ============================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
# 本地安装包目录：优先从此处取包，缺失再下载
INSTALL_FILES_DIR="${INSTALL_FILES_DIR:-${REPO_ROOT}/install}"

PAUSE_IMAGE="registry.aliyuncs.com/google_containers/pause:3.9"
CRICTL_VERSION="v1.30.0"
CONTAINERD_VERSION="1.6.32"
CNI_TYPE="ipvlan-l3"            # 默认: ipvlan L3（百万 pod 规模，无 bridge 瓶颈）
CONTAINERD_RUNTIME="runc"       # 默认: runc
SNAPSHOTTER="overlayfs"         # 默认: overlayfs（可选 erofs）
KATA_VERSION="3.22.0"           # kata containers 版本
KATA_HYPERVISOR="qemu"          # kata 默认 hypervisor（仅 --runtime kata 生效）
IP_MASQ="false"                 # bridge 专用: CNI ipMasq（默认 false；出网用节点级 MASQUERADE）

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
NO_WARMUP=false
HYPERVISOR_EXPLICIT=false

usage() {
    cat <<EOF
沙箱冷启动测试 — 环境准备（安装/检查 containerd、CNI、runtime 等）

用法:
  $0 [选项]

选项（括号内为默认值）:
  --cni-type TYPE          CNI 类型: bridge | ipvlan-l2 | ipvlan-l3
                           (默认: ${CNI_TYPE})
  --ip-masq true|false     bridge 的 CNI ipMasq；false 时用节点级 MASQUERADE
                           (默认: ${IP_MASQ})
  --runtime RUNTIME        OCI 运行时: runc | kata
                           (默认: ${CONTAINERD_RUNTIME})
  --hypervisor HV          kata hypervisor: dragonball | qemu | cloud-hypervisor | firecracker
                           (默认: ${KATA_HYPERVISOR}；仅 --runtime kata 时生效)
  --snapshotter NAME       snapshotter: overlayfs | erofs
                           (默认: ${SNAPSHOTTER})
  --check-only             仅检查，不安装/不修改
                           (默认: ${CHECK_ONLY})
  --no-warmup              成功后不跑 cold_start_bench warmup
                           (默认: ${NO_WARMUP}，即默认会 warmup)
  -h, --help               显示本帮助

其它默认（非 CLI，可改脚本内变量 / 环境变量）:
  pause 镜像:              ${PAUSE_IMAGE}
  crictl 版本:             ${CRICTL_VERSION}
  containerd 版本(安装包): ${CONTAINERD_VERSION}
  kata 版本:               ${KATA_VERSION}
  安装包目录:              ${INSTALL_FILES_DIR}
                           (可用环境变量 INSTALL_FILES_DIR 覆盖)

示例:
  $0
  $0 --cni-type bridge
  $0 --cni-type bridge --ip-masq true
  $0 --runtime kata --hypervisor qemu
  $0 --check-only
  $0 --no-warmup
EOF
    exit 0
}

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage ;;
        --check-only)
            CHECK_ONLY=true; shift ;;
        --no-warmup)
            NO_WARMUP=true; shift ;;
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
        --hypervisor)
            KATA_HYPERVISOR="$2"
            HYPERVISOR_EXPLICIT=true
            case "$KATA_HYPERVISOR" in
                dragonball|qemu|cloud-hypervisor|firecracker) ;;
                *)
                    echo "ERROR: --hypervisor 必须是 dragonball | qemu | cloud-hypervisor | firecracker"
                    exit 1
                    ;;
            esac
            shift 2 ;;
        --snapshotter)
            SNAPSHOTTER="$2"
            case "$SNAPSHOTTER" in
                overlayfs|erofs) ;;
                *) echo "ERROR: --snapshotter 必须是 overlayfs | erofs"; exit 1 ;;
            esac
            shift 2 ;;
        --ip-masq)
            IP_MASQ="$2"
            case "$IP_MASQ" in
                true|false) ;;
                *) echo "ERROR: --ip-masq 必须是 true | false"; exit 1 ;;
            esac
            shift 2 ;;
        *)
            echo "ERROR: 未知参数: $1"
            echo "运行 $0 --help 查看用法与默认值"
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

if $HYPERVISOR_EXPLICIT && [ "$CONTAINERD_RUNTIME" != "kata" ]; then
    warn "--hypervisor 仅在 --runtime kata 时生效（当前 runtime=$CONTAINERD_RUNTIME）"
fi

ensure_install_dir() {
    mkdir -p "$INSTALL_FILES_DIR"
}

# 优先从 INSTALL_FILES_DIR 取包；没有则下载并保存到该目录。
# 用法: path=$(fetch_pkg <文件名> <url>)
# 进度信息打到 stderr，stdout 只输出本地路径。
fetch_pkg() {
    local name=$1
    local url=$2
    local dest="${INSTALL_FILES_DIR}/${name}"
    local tmp

    ensure_install_dir
    if [[ -f "$dest" && -s "$dest" ]]; then
        echo "  使用本地包: $dest" >&2
        printf '%s\n' "$dest"
        return 0
    fi

    echo "  本地未找到 ${name}，下载: $url" >&2
    echo "  保存到: $dest" >&2
    tmp="${dest}.partial.$$"
    if ! curl -fsSL "$url" -o "$tmp"; then
        rm -f "$tmp"
        echo "ERROR: 下载失败: $url" >&2
        return 1
    fi
    mv "$tmp" "$dest"
    printf '%s\n' "$dest"
}

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

        local pkg url svc_pkg svc_url svc_path
        pkg="containerd-${CONTAINERD_VERSION}-linux-${ARCH}.tar.gz"
        url="https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/${pkg}"
        local tarball
        tarball=$(fetch_pkg "$pkg" "$url")
        sudo tar -C /usr/local -xzf "$tarball"

        # 安装 systemd service
        if ! [ -f /usr/lib/systemd/system/containerd.service ]; then
            echo "  安装 systemd service..."
            svc_pkg="containerd-${CONTAINERD_VERSION}.service"
            svc_url="https://raw.githubusercontent.com/containerd/containerd/v${CONTAINERD_VERSION}/containerd.service"
            svc_path=$(fetch_pkg "$svc_pkg" "$svc_url")
            sudo cp "$svc_path" /usr/lib/systemd/system/containerd.service
            sudo systemctl daemon-reload
            sudo systemctl enable containerd
        fi
        pass "containerd 安装完成"
    fi

    # 缺配置文件时生成默认 config.toml（否则 restart 会报 can't read .../config.toml）
    local config_file="/etc/containerd/config.toml"
    if [ -f "$config_file" ]; then
        pass "containerd 配置已存在: $config_file"
    else
        if $CHECK_ONLY; then
            fail "缺少 $config_file"
            return 1
        fi
        warn "未找到 $config_file，正在用 containerd config default 生成..."
        sudo mkdir -p /etc/containerd
        if ! containerd config default | sudo tee "$config_file" >/dev/null; then
            fail "生成 $config_file 失败"
            return 1
        fi
        pass "已生成 $config_file"
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

# bridge + ipMasq=false：用节点级一条 MASQUERADE 替代 CNI 每沙箱 CNI-* 链
# 规则: -s $CNI_SUBNET ! -o cni0 -j MASQUERADE
# ipMasq=true 时删除该节点级规则，改由 CNI 维护 per-sandbox 规则
ensure_bridge_egress_masq() {
    if [ "$CNI_TYPE" != "bridge" ]; then
        return 0
    fi

    local bridge_if="cni0"
    if [ "$IP_MASQ" = "false" ]; then
        if sudo iptables -t nat -C POSTROUTING -s "$CNI_SUBNET" ! -o "$bridge_if" -j MASQUERADE 2>/dev/null; then
            pass "节点级 MASQUERADE 已存在: -s $CNI_SUBNET ! -o $bridge_if"
            return 0
        fi
        if $CHECK_ONLY; then
            warn "缺少节点级 MASQUERADE（ipMasq=false 出网需要）: -s $CNI_SUBNET ! -o $bridge_if"
            return 1
        fi
        echo "  添加节点级 MASQUERADE: -s $CNI_SUBNET ! -o $bridge_if -j MASQUERADE ..."
        if ! sudo iptables -t nat -A POSTROUTING -s "$CNI_SUBNET" ! -o "$bridge_if" -j MASQUERADE; then
            fail "添加节点级 MASQUERADE 失败"
            return 1
        fi
        pass "节点级 MASQUERADE 已添加"
        return 0
    fi

    # ipMasq=true：去掉本脚本维护的节点级规则，避免与 CNI per-sandbox 规则叠加
    if sudo iptables -t nat -C POSTROUTING -s "$CNI_SUBNET" ! -o "$bridge_if" -j MASQUERADE 2>/dev/null; then
        if $CHECK_ONLY; then
            warn "ipMasq=true 时仍存在节点级 MASQUERADE（建议删除）: -s $CNI_SUBNET ! -o $bridge_if"
            return 0
        fi
        echo "  删除节点级 MASQUERADE（改由 CNI ipMasq 负责）..."
        sudo iptables -t nat -D POSTROUTING -s "$CNI_SUBNET" ! -o "$bridge_if" -j MASQUERADE
        pass "节点级 MASQUERADE 已删除"
    fi
    return 0
}

# ============================================================
# 检查 kata runtime（仅在 --runtime kata 时执行）
# ============================================================
KATA_INSTALL_DIR="/opt/kata"
KATA_BIN_DIR="$KATA_INSTALL_DIR/bin"
# kata-static tarball 内部前缀为 ./opt/kata/，需解压到 / 才能对齐
TARBALL_NAME="kata-static-${KATA_VERSION}-${ARCH}.tar.zst"

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

        local tarball_path
        local kata_url="https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/${TARBALL_NAME}"
        tarball_path=$(fetch_pkg "$TARBALL_NAME" "$kata_url")

        # kata-static tarball 内部前缀为 ./opt/kata/，需解压到 / 根目录
        if sudo tar --zstd -xf "$tarball_path" -C / 2>/dev/null; then
            true
        elif command -v zstd &>/dev/null; then
            local tmpdir; tmpdir=$(mktemp -d)
            zstd -d "$tarball_path" -o "$tmpdir/kata.tar" 2>/dev/null || \
                zstdcat "$tarball_path" > "$tmpdir/kata.tar"
            sudo tar -C / -xf "$tmpdir/kata.tar"
            rm -rf "$tmpdir"
        else
            fail "无法解压 .tar.zst 文件（需要 zstd 或 tar --zstd）"
            return 1
        fi

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

        # 重新检测 runtime-rs shim（安装后新文件已就位，更新 kata_shim）
        if [ -x "$kata_rs_shim" ]; then
            kata_shim="$kata_rs_shim"
        fi
    fi

    # ---- 1.5 按 --hypervisor 切换 runtime-rs 配置 ---- #
    local kata_config_dir="/opt/kata/share/defaults/kata-containers/runtime-rs"
    local target_config=""
    local target_link_name=""

    case "$KATA_HYPERVISOR" in
        dragonball)
            target_link_name="configuration-dragonball.toml"
            ;;
        qemu)
            target_link_name="configuration-qemu-runtime-rs.toml"
            ;;
        cloud-hypervisor)
            target_link_name="configuration-cloud-hypervisor.toml"
            ;;
        firecracker)
            target_link_name="configuration-rs-fc.toml"
            ;;
        *)
            fail "未知 hypervisor: $KATA_HYPERVISOR"
            return 1
            ;;
    esac
    target_config="$kata_config_dir/$target_link_name"

    if [ ! -f "$target_config" ]; then
        fail "hypervisor 配置不存在: $target_config"
        return 1
    fi

    # QEMU：做架构相关修补（ARM64 virt / firmware / rootfs driver）
    if [ "$KATA_HYPERVISOR" = "qemu" ]; then
        echo "  配置 runtime-rs QEMU..."
        if [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then
            # machine_type: q35 是 x86 专用，ARM64 必须用 virt
            sudo sed -i 's|machine_type = "q35"|machine_type = "virt"|' "$target_config"
            sudo sed -i 's|machine_type = ""|machine_type = "virt"|' "$target_config"
            # firmware: ARM64 UEFI
            if grep -q 'firmware = ""' "$target_config" 2>/dev/null; then
                sudo sed -i 's|firmware = ""|firmware = "/opt/kata/share/kata-qemu/qemu/edk2-aarch64-code.fd"|' "$target_config"
                sudo sed -i 's|firmware_volume = ""|firmware_volume = "/opt/kata/share/kata-qemu/qemu/edk2-arm-vars.fd"|' "$target_config"
            fi
            # virtio-pmem → virtio-blk-pci (ARM64 virt 上 pmem 会崩)
            sudo sed -i 's|vm_rootfs_driver = "virtio-pmem"|vm_rootfs_driver = "virtio-blk-pci"|' "$target_config"
        fi
        # 若配置里 kernel 路径不存在，尽量补成实际 vmlinux（排除 dragonball experimental）
        local cfg_kernel actual_kernel
        cfg_kernel=$(grep -E '^kernel =' "$target_config" | head -1 | sed 's/.*= *"//;s/"//')
        if [ -n "$cfg_kernel" ] && [ ! -e "$cfg_kernel" ]; then
            actual_kernel=$(ls /opt/kata/share/kata-containers/vmlinux-[0-9]* 2>/dev/null | grep -v dragonball | head -1 || true)
            [ -n "$actual_kernel" ] && sudo sed -i "s|^kernel = .*|kernel = \"$actual_kernel\"|" "$target_config"
        fi
    fi

    # 校验 hypervisor 二进制（dragonball 内置，无独立 path）
    case "$KATA_HYPERVISOR" in
        qemu)
            if [ ! -x /opt/kata/bin/qemu-system-x86_64 ] && \
               [ ! -x /opt/kata/bin/qemu-system-aarch64 ]; then
                warn "未找到 qemu-system-*，请确认 kata-static 已完整安装"
            fi
            ;;
        cloud-hypervisor)
            [ -x /opt/kata/bin/cloud-hypervisor ] || {
                fail "缺少 /opt/kata/bin/cloud-hypervisor"
                return 1
            }
            ;;
        firecracker)
            [ -x /opt/kata/bin/firecracker ] || {
                fail "缺少 /opt/kata/bin/firecracker"
                return 1
            }
            ;;
    esac

    local default_config="$kata_config_dir/configuration.toml"
    local current_target
    local hypervisor_changed=false
    current_target=$(readlink -f "$default_config" 2>/dev/null || true)
    if [ "$current_target" = "$(readlink -f "$target_config")" ]; then
        pass "runtime-rs hypervisor 已是 $KATA_HYPERVISOR ($target_link_name)"
    elif $CHECK_ONLY; then
        warn "hypervisor 期望 $KATA_HYPERVISOR，当前: ${current_target:-none}"
        return 1
    else
        echo "  切换 hypervisor → $KATA_HYPERVISOR ($target_link_name)"
        sudo rm -f "$default_config"
        sudo ln -s "$target_link_name" "$default_config"
        hypervisor_changed=true
        pass "runtime-rs hypervisor 已设为 $KATA_HYPERVISOR"
    fi

    # ---- 2. 检查 containerd 是否注册了 kata runtime ---- #
    local config_file="/etc/containerd/config.toml"
    if grep -q "io.containerd.kata.v2" "$config_file" 2>/dev/null; then
        # 验证 runtime_path 和 ConfigPath 是否正确（防止旧配置缓存问题）
        local need_fix=false
        if ! grep -q "runtime-rs" <<< "$(grep 'runtime_path.*kata' "$config_file")"; then
            warn "kata runtime_path 未指向 runtime-rs，正在修正..."
            sudo sed -i "/runtimes\.kata\]/,/^\[/s|runtime_path = .*|runtime_path = '$kata_shim'|" "$config_file"
            need_fix=true
        fi
        if ! grep -q "runtime-rs" <<< "$(grep 'ConfigPath.*kata' "$config_file")"; then
            warn "kata ConfigPath 未指向 runtime-rs，正在修正..."
            sudo sed -i "/runtimes\.kata\]/,/^\[/s|ConfigPath = .*|ConfigPath = '/opt/kata/share/defaults/kata-containers/runtime-rs/configuration.toml'|" "$config_file"
            need_fix=true
        fi
        if $need_fix || $hypervisor_changed; then
            if ! $CHECK_ONLY; then
                echo "  重启 containerd 使 hypervisor/配置生效..."
                sudo systemctl restart containerd
                sleep 2
            fi
            if $need_fix; then
                pass "containerd kata 配置已修正"
            else
                pass "containerd 已注册 kata runtime（hypervisor 已切换）"
            fi
        else
            pass "containerd 已注册 kata runtime"
        fi
        return 0
    fi

    if $CHECK_ONLY; then
        warn "containerd 未注册 kata runtime"
        return 1
    fi

    echo "  注册 kata runtime 到 containerd..."

    # 找到 kata 配置文件（runtime-rs 使用 runtime-rs 子目录下的配置）
    local kata_config_path=""
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

[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata]
  runtime_type = 'io.containerd.kata.v2'
  runtime_path = '$kata_shim'
  privileged_without_host_devices = true
  pod_annotations = ['io.katacontainers.*']
  [plugins."io.containerd.grpc.v1.cri".containerd.runtimes.kata.options]
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
                printf '{\n  "cniVersion": "0.3.1",\n  "name": "mynet",\n  "type": "bridge",\n  "bridge": "cni0",\n  "isGateway": true,\n  "ipMasq": %s,\n  "ipam": {\n    "type": "host-local",\n    "subnet": "%s",\n    "routes": [\n      { "dst": "0.0.0.0/0" }\n    ]\n  }\n}\n' "$IP_MASQ" "$CNI_SUBNET" | sudo tee "$CNI_CONF_FILE" > /dev/null
                ;;
            ipvlan-l2)
                local master
                master=$(detect_master_iface)
                echo "  ipvlan master 网卡: $master"
                printf '{\n  "cniVersion": "0.3.1",\n  "name": "mynet",\n  "type": "ipvlan",\n  "master": "%s",\n  "mode": "l2",\n  "ipam": {\n    "type": "host-local",\n    "subnet": "%s",\n    "routes": [\n      { "dst": "0.0.0.0/0" }\n    ]\n  }\n}\n' "$master" "$CNI_SUBNET" | sudo tee "$CNI_CONF_FILE" > /dev/null
                ;;
            ipvlan-l3)
                local master
                master=$(detect_master_iface)
                echo "  ipvlan master 网卡: $master"
                printf '{\n  "cniVersion": "0.3.1",\n  "name": "mynet",\n  "type": "ipvlan",\n  "master": "%s",\n  "mode": "l3",\n  "ipam": {\n    "type": "host-local",\n    "subnet": "%s",\n    "routes": [\n      { "dst": "0.0.0.0/0" }\n    ]\n  }\n}\n' "$master" "$CNI_SUBNET" | sudo tee "$CNI_CONF_FILE" > /dev/null
                ;;
        esac

        pass "CNI $CNI_TYPE 配置已创建"
        sudo systemctl restart containerd
        sleep 2
        # 新建配置后仍需同步节点级出网规则（尤其 ipMasq=false）
        ensure_bridge_egress_masq || return 1
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

    # ---- bridge 专属：ipMasq ---- #
    if [ "$CNI_TYPE" = "bridge" ]; then
        local current_ip_masq
        current_ip_masq=$(grep -oE '"ipMasq"[[:space:]]*:[[:space:]]*(true|false)' "$CNI_CONF_FILE" 2>/dev/null | head -1 | grep -oE 'true|false' || true)
        if [ -z "$current_ip_masq" ]; then
            current_ip_masq="(未设置)"
        fi
        if [ "$current_ip_masq" = "$IP_MASQ" ]; then
            pass "CNI ipMasq 已匹配: $IP_MASQ"
        else
            if $CHECK_ONLY; then
                warn "CNI ipMasq 不匹配: 当前=$current_ip_masq, 需要=$IP_MASQ"
                return 1
            fi
            echo "  更新 CNI ipMasq: $current_ip_masq → $IP_MASQ ..."
            # 注意：勿用 | 作 sed 分隔符，会与正则 (true|false) 冲突导致替换失败
            if grep -qE '"ipMasq"[[:space:]]*:' "$CNI_CONF_FILE"; then
                sudo sed -i -E "s#\"ipMasq\"[[:space:]]*:[[:space:]]*(true|false)#\"ipMasq\": $IP_MASQ#" "$CNI_CONF_FILE"
            else
                # 在 isGateway 行后插入（兼容旧配置缺字段）
                sudo sed -i -E "s#(\"isGateway\"[[:space:]]*:[[:space:]]*true)#\1,\n  \"ipMasq\": $IP_MASQ#" "$CNI_CONF_FILE"
            fi
            local updated_ip_masq
            updated_ip_masq=$(grep -oE '"ipMasq"[[:space:]]*:[[:space:]]*(true|false)' "$CNI_CONF_FILE" 2>/dev/null | head -1 | grep -oE 'true|false' || true)
            if [ "$updated_ip_masq" != "$IP_MASQ" ]; then
                fail "CNI ipMasq 更新失败: 期望=$IP_MASQ, 实际=${updated_ip_masq:-(未设置)}"
                return 1
            fi
            pass "CNI ipMasq 已更新为: $IP_MASQ"
        fi
        # ipMasq=false → 确保节点级 MASQUERADE；true → 清理节点级规则
        ensure_bridge_egress_masq || return 1
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

        local pkg url tarball
        pkg="crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz"
        url="https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/${pkg}"
        tarball=$(fetch_pkg "$pkg" "$url")
        sudo tar -C /usr/local/bin -xzf "$tarball"
        sudo chmod +x /usr/local/bin/crictl
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
# 检查 snapshotter 配置
# ============================================================
check_snapshotter() {
    echo ""
    echo "--- snapshotter ---"

    local config_file="/etc/containerd/config.toml"
    local current_snapshotter
    current_snapshotter=$(grep -oP "snapshotter\s*=\s*'\K[^']*" "$config_file" 2>/dev/null | head -1)

    if [ "$current_snapshotter" = "$SNAPSHOTTER" ]; then
        pass "snapshotter 已配置: $SNAPSHOTTER"
        return 0
    fi

    if $CHECK_ONLY; then
        warn "snapshotter 不匹配: 当前=${current_snapshotter:-未设置}, 需要=$SNAPSHOTTER"
        return 1
    fi

    if [ -z "$current_snapshotter" ]; then
        warn "snapshotter 未配置，正在设置为 $SNAPSHOTTER ..."
    else
        warn "snapshotter 当前为 $current_snapshotter，正在切换为 $SNAPSHOTTER ..."
    fi

    # 修改 containerd config 中的 snapshotter 设置
    if grep -q "snapshotter\s*=" "$config_file" 2>/dev/null; then
        sudo sed -i "s|snapshotter = '[^']*'|snapshotter = '$SNAPSHOTTER'|" "$config_file"
    else
        # 如果没有 snapshotter 行，在 [plugins."io.containerd.cri.v1.images"] 下添加
        sudo sed -i "/\[plugins.'io.containerd.cri.v1.images'\]/a\\
      snapshotter = '$SNAPSHOTTER'" "$config_file"
    fi

    # 重启 containerd 使配置生效
    echo "  重启 containerd..."
    sudo systemctl restart containerd
    sleep 2
    pass "snapshotter 已切换为: $SNAPSHOTTER"

    return 0
}

# ============================================================
# 检查 pause 镜像
# ============================================================
check_pause_image() {
    echo ""
    echo "--- pause 镜像 ---"

    if crictl images 2>/dev/null | awk '{print $1":"$2}' | grep -qF "$PAUSE_IMAGE"; then
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
# 输出 containerd 当前 CPU 亲和性（绑核）
# ============================================================
print_containerd_cpus() {
    echo ""
    echo "--- containerd CPU 亲和性 ---"

    local pid
    pid=$(pgrep -nx containerd 2>/dev/null || true)
    if [ -z "$pid" ]; then
        warn "未找到运行中的 containerd 进程"
        return 0
    fi

    local affinity
    affinity=$(taskset -pc "$pid" 2>/dev/null | awk -F': ' '{print $NF}')
    if [ -z "$affinity" ]; then
        warn "无法读取 containerd(pid=$pid) 的 CPU 亲和性"
        return 0
    fi

    pass "containerd pid=$pid 所在 CPU 核心: $affinity"
    # systemd 单元里的 CPUAffinity（若有）一并打印，便于对照
    local unit_cpus
    unit_cpus=$(systemctl show -p CPUAffinity --value containerd 2>/dev/null || true)
    if [ -n "$unit_cpus" ] && [ "$unit_cpus" != "[]" ] && [ "$unit_cpus" != "" ]; then
        echo "  systemd CPUAffinity: $unit_cpus"
    fi
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
    echo "  Runtime:     $CONTAINERD_RUNTIME"
    if [ "$CONTAINERD_RUNTIME" = "kata" ]; then
        echo "  Hypervisor:  $KATA_HYPERVISOR"
    fi
    echo "  CNI 类型:    $CNI_TYPE"
    if [ "$CNI_TYPE" = "bridge" ]; then
        echo "  CNI ipMasq:  $IP_MASQ"
    fi
    echo "  Snapshotter: $SNAPSHOTTER"
    echo "  pause 镜像:  $PAUSE_IMAGE"
    echo "  安装包目录: $INSTALL_FILES_DIR"
    echo "=============================================="
    echo

    # 提前创建缓存目录，便于手动放入安装包
    if ! $CHECK_ONLY; then
        ensure_install_dir
    fi

    local errors=0

    check_containerd      || errors=$((errors + 1))
    check_kata_runtime    || errors=$((errors + 1))
    check_cni_network     || errors=$((errors + 1))
    check_crictl          || errors=$((errors + 1))
    check_crictl_config   || { [[ $? -eq 1 ]] && errors=$((errors + 1)); }
    check_registry_mirror || errors=$((errors + 1))
    check_snapshotter     || errors=$((errors + 1))
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

    print_containerd_cpus

    # 仅全部检查成功时 warmup（--check-only / --no-warmup 跳过）
    if [ "$errors" -eq 0 ] && ! $CHECK_ONLY && ! $NO_WARMUP; then
        local warmup_py="${REPO_ROOT}/scripts/bench/cold_start_bench.py"
        echo ""
        echo "--- Warmup: cold_start_bench.py (runtime=$CONTAINERD_RUNTIME) ---"
        if [ ! -f "$warmup_py" ]; then
            warn "未找到 $warmup_py，跳过 warmup"
        else
            set +e
            (cd "$REPO_ROOT" && python3 "$warmup_py" --runtime "$CONTAINERD_RUNTIME")
            local warmup_rc=$?
            set -e
            if [ "$warmup_rc" -eq 0 ]; then
                pass "warmup 完成"
            else
                warn "warmup 失败 (exit=$warmup_rc)；环境已就绪，可稍后重跑 cold_start_bench.py"
            fi
        fi
    elif [ "$errors" -eq 0 ] && $NO_WARMUP; then
        echo ""
        echo "已跳过 warmup（--no-warmup）"
    fi

    echo ""
    echo "下一步:"
    echo "  # 单发冷启动测试"
    echo "  python3 scripts/bench/cold_start_bench.py --runs 50 --runtime $CONTAINERD_RUNTIME"
    echo ""
    echo "  # 并发冷启动测试"
    echo "  ./scripts/bench/concurrent_cold_start.py 10 3"
    echo ""
    if [ "$CNI_TYPE" = "bridge" ] && [ "$IP_MASQ" = "false" ]; then
        echo "提示: bridge + ipMasq=false 已由本脚本配置节点级出网规则:"
        echo "  iptables -t nat -A POSTROUTING -s $CNI_SUBNET ! -o cni0 -j MASQUERADE"
        echo "  （重启后若规则丢失，重新执行 setup.sh 或自行做 iptables 持久化）"
        echo ""
    fi

    return $errors
}

main
