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
#   ./setup.sh --runtime kata --hypervisor firecracker  # 自动切 devmapper（块设备 rootfs）
#   ./setup.sh --runtime kata --hypervisor qemu --vm-template  # VM 模板加速冷启动（Go+qemu）
#   ./setup.sh --runtime kata --hypervisor qemu --vm-cache 3   # VM Cache 预热池（Go+qemu，常驻服务）
#   ./setup.sh --check-only                   # 仅检查，不安装
#   ./setup.sh --no-warmup                    # 成功后不跑 cold_start_bench warmup
#
# 安装包缓存:
#   默认目录 <repo>/install/（可用环境变量 INSTALL_FILES_DIR 覆盖，已在 .gitignore）
#   优先使用该目录中的包；没有则下载并保存到该目录，供下次复用
# 仓库配置（纳入 git）:
#   <repo>/config/kata/ — kata 捆绑 toml 等（可用环境变量 KATA_CONFIG_DIR 覆盖）
# ============================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
# 本地安装包目录：优先从此处取包，缺失再下载
INSTALL_FILES_DIR="${INSTALL_FILES_DIR:-${REPO_ROOT}/install}"
# 仓库内配置目录（toml 等，应纳入版本库）
KATA_CONFIG_DIR="${KATA_CONFIG_DIR:-${REPO_ROOT}/config/kata}"

# 保证能找到 /usr/local/bin 下的 crictl 等（勿再套一层 sudo 清 PATH）
export PATH="/usr/local/bin:/usr/local/sbin:${PATH:-/usr/bin:/bin}"

# 已是 root 时不调用真实 sudo（避免 secure_path 丢掉 /usr/local/bin）
if [ "$(id -u)" -eq 0 ]; then
    sudo() { "$@" ; }
elif ! command -v sudo >/dev/null 2>&1; then
    echo "ERROR: 需要 root，或安装 sudo 后以具备权限的用户运行" >&2
    exit 1
fi

PAUSE_IMAGE="registry.aliyuncs.com/google_containers/pause:3.9"
CRICTL_VERSION="v1.30.0"
CONTAINERD_VERSION="1.6.32"
CNI_TYPE="ipvlan-l3"            # 默认: ipvlan L3（百万 pod 规模，无 bridge 瓶颈）
CONTAINERD_RUNTIME="runc"       # 默认: runc
SNAPSHOTTER="overlayfs"         # 默认: overlayfs（可选 erofs | devmapper）
KATA_VERSION="4.0.0"           # kata containers 版本
KATA_HYPERVISOR="qemu"          # kata 默认 hypervisor（仅 --runtime kata 生效）
IP_MASQ="false"                 # bridge 专用: CNI ipMasq（默认 false；出网用节点级 MASQUERADE）
# 默认用 RFC6598 CGNAT 段，避开常见 10/8、172.16/12、192.168/16；可用 --cni-subnet 覆盖
CNI_SUBNET="${CNI_SUBNET:-100.64.0.0/12}"
VM_TEMPLATE=false               # Kata VM templating（factory）；仅 qemu + Go runtime
VM_CACHE_NUMBER=0               # Kata VM Cache 池大小；>0 启用（与 template 互斥；仅 qemu + Go）
VM_CACHE_ENDPOINT="/var/run/kata-containers/cache.sock"
VM_CACHE_UNIT="kata-vmcache.service"
HYPERVISOR_EXPLICIT=false
SNAPSHOTTER_EXPLICIT=false
CHECK_ONLY=false
NO_WARMUP=false
DEVMAPPER_DATA_DIR="/var/lib/containerd/devmapper"
DEVMAPPER_POOL_NAME="devpool4"
DEVMAPPER_DATA_SIZE="50G"       # sparse 数据盘
DEVMAPPER_META_SIZE="5G"        # sparse 元数据盘
DEVMAPPER_BASE_IMAGE_SIZE="10GB"

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

usage() {
    cat <<EOF
沙箱冷启动测试 — 环境准备（安装/检查 containerd、CNI、runtime 等）

用法:
  $0 [选项]

选项（括号内为默认值）:
  --cni-type TYPE          CNI 类型: bridge | ipvlan-l2 | ipvlan-l3
                           (默认: ${CNI_TYPE})
  --cni-subnet CIDR        CNI IPAM 子网（写入 10-mynet.conf + 节点级 MASQ）
                           (默认: ${CNI_SUBNET}；可用环境变量 CNI_SUBNET 覆盖)
  --ip-masq true|false     bridge 的 CNI ipMasq；false 时用节点级 MASQUERADE
                           (默认: ${IP_MASQ})
  --runtime RUNTIME        OCI 运行时: runc | kata
                           (默认: ${CONTAINERD_RUNTIME})
  --hypervisor HV          kata hypervisor: dragonball | qemu | cloud-hypervisor|clh | firecracker | stratovirt
                           (默认: ${KATA_HYPERVISOR}；仅 --runtime kata 时生效)
                           注: Kata 4.0 runtime-rs 中 CLH 配置段名为 clh（cloud-hypervisor 为别名）
                           注: stratovirt 走 Go shim（非 runtime-rs）；本机 glibc 过旧时用捆绑静态 Go shim
  --vm-template            启用 Kata VM templating（factory）；强制 qemu + Go runtime
                           需 initrd、shared_fs≠virtio-fs；ARM64 上官方测试曾标记不稳定
                           (默认: ${VM_TEMPLATE})
  --vm-cache N             启用 Kata VM Cache（预热 N 台 VM）；强制 qemu + Go + devmapper
                           与 --vm-template 互斥；shared_fs=none（factory 预热无 sharePath）
                           会安装并启动 ${VM_CACHE_UNIT}
                           (默认: ${VM_CACHE_NUMBER}=关闭；endpoint=${VM_CACHE_ENDPOINT})
  --snapshotter NAME       snapshotter: overlayfs | erofs | devmapper
                           (默认: ${SNAPSHOTTER}；firecracker 自动强制 devmapper)
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
  kata 配置目录:           ${KATA_CONFIG_DIR}
                           (可用环境变量 KATA_CONFIG_DIR 覆盖)

示例:
  $0
  $0 --cni-type bridge
  $0 --cni-type bridge --cni-subnet 100.64.0.0/12
  $0 --cni-type bridge --ip-masq true
  $0 --runtime kata --hypervisor qemu
  $0 --runtime kata --hypervisor qemu --vm-template
  $0 --runtime kata --hypervisor qemu --vm-cache 3
  $0 --runtime kata --hypervisor firecracker
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
        --vm-template)
            VM_TEMPLATE=true; shift ;;
        --vm-cache)
            VM_CACHE_NUMBER="$2"
            if ! [[ "$VM_CACHE_NUMBER" =~ ^[1-9][0-9]*$ ]]; then
                echo "ERROR: --vm-cache 需要正整数（预热 VM 数量）"; exit 1
            fi
            shift 2 ;;
        --cni-type)
            CNI_TYPE="$2"
            case "$CNI_TYPE" in
                bridge|ipvlan-l2|ipvlan-l3) ;;
                *) echo "ERROR: --cni-type 必须是 bridge | ipvlan-l2 | ipvlan-l3"; exit 1 ;;
            esac
            shift 2 ;;
        --cni-subnet)
            CNI_SUBNET="$2"
            if ! [[ "$CNI_SUBNET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/([0-9]|[12][0-9]|3[0-2])$ ]]; then
                echo "ERROR: --cni-subnet 须为 IPv4 CIDR，如 100.64.0.0/12；收到: $CNI_SUBNET"
                exit 1
            fi
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
                dragonball|qemu|cloud-hypervisor|clh|firecracker|stratovirt)
                    # Kata 4.0.0 runtime-rs 插件名/配置段为 clh
                    if [ "$KATA_HYPERVISOR" = "cloud-hypervisor" ]; then
                        KATA_HYPERVISOR=clh
                    fi
                    ;;
                *)
                    echo "ERROR: --hypervisor 必须是 dragonball | qemu | cloud-hypervisor|clh | firecracker | stratovirt"
                    exit 1
                    ;;
            esac
            shift 2 ;;
        --snapshotter)
            SNAPSHOTTER="$2"
            SNAPSHOTTER_EXPLICIT=true
            case "$SNAPSHOTTER" in
                overlayfs|erofs|devmapper) ;;
                *) echo "ERROR: --snapshotter 必须是 overlayfs | erofs | devmapper"; exit 1 ;;
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

# Firecracker 无 virtio-fs，只能挂块设备 rootfs → 强制 devmapper
if [ "$CONTAINERD_RUNTIME" = "kata" ] && [ "$KATA_HYPERVISOR" = "firecracker" ]; then
    if [ "$SNAPSHOTTER" != "devmapper" ]; then
        if $SNAPSHOTTER_EXPLICIT; then
            warn "firecracker 需要 devmapper；忽略 --snapshotter $SNAPSHOTTER"
        fi
        SNAPSHOTTER="devmapper"
    fi
fi

# VM template / VM Cache + shared_fs=none 需要块设备 rootfs（overlayfs 无法给 guest 提供 rootfs）
if { $VM_TEMPLATE || [ "$VM_CACHE_NUMBER" -gt 0 ]; } && [ "$SNAPSHOTTER" != "devmapper" ]; then
    local_why="--vm-template"
    [ "$VM_CACHE_NUMBER" -gt 0 ] && local_why="--vm-cache"
    if $SNAPSHOTTER_EXPLICIT; then
        warn "$local_why 需要块 rootfs；忽略 --snapshotter $SNAPSHOTTER → devmapper"
    else
        warn "$local_why 需要块 rootfs；切换 snapshotter → devmapper"
    fi
    SNAPSHOTTER="devmapper"
fi

# VM templating：仅 qemu；切到 Go runtime（kata-runtime factory init）
if $VM_TEMPLATE; then
    if [ "$CONTAINERD_RUNTIME" != "kata" ]; then
        echo "ERROR: --vm-template 需要 --runtime kata"; exit 1
    fi
    if [ "$VM_CACHE_NUMBER" -gt 0 ]; then
        echo "ERROR: --vm-template 与 --vm-cache 互斥"; exit 1
    fi
    if [ "$KATA_HYPERVISOR" = "stratovirt" ]; then
        echo "ERROR: --vm-template 与 stratovirt 互斥"; exit 1
    fi
    if [ "$KATA_HYPERVISOR" != "qemu" ]; then
        if $HYPERVISOR_EXPLICIT; then
            warn "--vm-template 仅支持 qemu；忽略 --hypervisor $KATA_HYPERVISOR"
        fi
        KATA_HYPERVISOR="qemu"
    fi
fi

# VM Cache：仅 qemu + Go；常驻 factory init（gRPC server）
if [ "$VM_CACHE_NUMBER" -gt 0 ]; then
    if [ "$CONTAINERD_RUNTIME" != "kata" ]; then
        echo "ERROR: --vm-cache 需要 --runtime kata"; exit 1
    fi
    if [ "$KATA_HYPERVISOR" = "stratovirt" ]; then
        echo "ERROR: --vm-cache 与 stratovirt 互斥"; exit 1
    fi
    if [ "$KATA_HYPERVISOR" != "qemu" ]; then
        if $HYPERVISOR_EXPLICIT; then
            warn "--vm-cache 仅支持 qemu；忽略 --hypervisor $KATA_HYPERVISOR"
        fi
        KATA_HYPERVISOR="qemu"
    fi
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
# CNI_SUBNET 默认/CLI/环境变量见脚本顶部与 --cni-subnet

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

    # ---- 1. 检查 kata shim ---- #
    # 默认优先 runtime-rs（静态 Rust，兼容旧 glibc）。
    # stratovirt 仅 Go runtime 支持 → 改用静态编译的 Go shim（官方动态链接包要 GLIBC≥2.32）。
    local kata_bin="$KATA_BIN_DIR/kata-runtime"
    local kata_shim="$KATA_BIN_DIR/containerd-shim-kata-v2"
    local kata_rs_shim="$KATA_INSTALL_DIR/runtime-rs/bin/containerd-shim-kata-v2"
    local kata_go_static_shim="$KATA_BIN_DIR/containerd-shim-kata-v2-go-static"
    local kata_go_static_bundled="${INSTALL_FILES_DIR}/go-shim-static/containerd-shim-kata-v2"
    local use_go_runtime=false

    if [ "$KATA_HYPERVISOR" = "stratovirt" ] || $VM_TEMPLATE || [ "$VM_CACHE_NUMBER" -gt 0 ]; then
        use_go_runtime=true
    fi

    # 确保已安装 kata 静态包（至少有 HV 二进制 / 配置）
    if [ ! -x "$kata_rs_shim" ] && [ ! -x "$KATA_BIN_DIR/stratovirt" ] && [ ! -x "$kata_shim" ]; then
        if $CHECK_ONLY; then
            fail "kata-runtime 未安装（需要 --runtime kata）"
            return 1
        fi
        warn "kata-runtime 未安装，正在安装 v${KATA_VERSION}..."

        if ! command -v zstd &>/dev/null; then
            echo "  安装 zstd..."
            sudo apt-get update -qq && sudo apt-get install -y -qq zstd 2>/dev/null || \
                sudo yum install -y -q zstd 2>/dev/null || true
        fi

        local tarball_path
        local kata_url="https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/${TARBALL_NAME}"
        tarball_path=$(fetch_pkg "$TARBALL_NAME" "$kata_url")

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
    fi

    if $use_go_runtime; then
        # 安装/选用静态 Go shim（避免官方 /opt/kata/bin/... 的 GLIBC_2.32+ 依赖）
        if [ ! -x "$kata_go_static_shim" ] || ! "$kata_go_static_shim" --version &>/dev/null; then
            if [ -x "$kata_go_static_bundled" ]; then
                echo "  安装捆绑的静态 Go shim（Go runtime / stratovirt / factory）..."
                sudo install -m 0755 "$kata_go_static_bundled" "$kata_go_static_shim"
            elif [ -x "$kata_shim" ] && "$kata_shim" --version &>/dev/null; then
                # 官方动态链接 shim 若在本机可跑则直接用
                kata_go_static_shim="$kata_shim"
            else
                fail "需要静态 Go shim，但本机 glibc 过旧且缺少 ${kata_go_static_bundled}"
                echo "  构建方法见: ${KATA_CONFIG_DIR}/go-shim-static/README.md"
                echo "  （或在 kata-containers 4.0.0 源码树）:"
                echo "    cd src/runtime && make pkg/katautils/config-settings.go"
                echo "    CGO_ENABLED=0 go build -mod=mod -ldflags '-s -w' -o ${kata_go_static_bundled} ./cmd/containerd-shim-kata-v2/"
                return 1
            fi
        fi
        if ! "$kata_go_static_shim" --version &>/dev/null; then
            fail "Go shim 无法执行: $kata_go_static_shim"
            return 1
        fi
        kata_shim="$kata_go_static_shim"
        pass "kata Go shim: $kata_shim ($("$kata_shim" --version 2>/dev/null | head -1))"
    else
        if [ -x "$kata_rs_shim" ]; then
            pass "kata runtime-rs shim 可用: $kata_rs_shim"
            kata_shim="$kata_rs_shim"
        elif [ -x "$kata_shim" ] && "$kata_shim" --version &>/dev/null; then
            ver=$("$kata_bin" --version 2>/dev/null | head -1 || echo "kata (glibc)")
            pass "kata-runtime 已安装: $ver"
        else
            fail "kata-runtime 安装失败，未找到可用的 containerd-shim-kata-v2"
            return 1
        fi
    fi

    # ---- 1.5 按 --hypervisor 切换配置（runtime-rs 或 Go） ---- #
    local kata_config_dir
    local target_config=""
    local target_link_name=""
    local default_config=""

    if $use_go_runtime; then
        kata_config_dir="/opt/kata/share/defaults/kata-containers"
        default_config="$kata_config_dir/configuration.toml"
    else
        kata_config_dir="/opt/kata/share/defaults/kata-containers/runtime-rs"
        default_config="$kata_config_dir/configuration.toml"
    fi

    case "$KATA_HYPERVISOR" in
        dragonball)
            target_link_name="configuration-dragonball.toml"
            ;;
        qemu)
            if $VM_TEMPLATE || [ "$VM_CACHE_NUMBER" -gt 0 ]; then
                # Go runtime + factory（template / VM Cache）
                target_link_name="configuration-qemu.toml"
            else
                target_link_name="configuration-qemu-runtime-rs.toml"
            fi
            ;;
        clh|cloud-hypervisor)
            # 4.0.0：配置文件名 configuration-clh-runtime-rs.toml，段名 [hypervisor.clh]
            # aarch64 官方静态包因未定义 CLHCMD 常缺此文件，用仓库捆绑配置补齐
            target_link_name="configuration-clh-runtime-rs.toml"
            KATA_HYPERVISOR=clh
            ;;
        firecracker)
            target_link_name="configuration-rs-fc.toml"
            ;;
        stratovirt)
            target_link_name="configuration-stratovirt.toml"
            ;;
        *)
            fail "未知 hypervisor: $KATA_HYPERVISOR"
            return 1
            ;;
    esac
    target_config="$kata_config_dir/$target_link_name"

    # 4.0.0 静态包（尤其 aarch64）常缺 runtime-rs 的 clh 配置；从仓库 config/kata 捆绑安装
    if [ "$KATA_HYPERVISOR" = "clh" ]; then
        local bundled="${KATA_CONFIG_DIR}/configuration-clh-runtime-rs.toml"
        # 兼容旧路径 install/runtime-rs-configs/
        if [ ! -f "$bundled" ] && [ -f "${INSTALL_FILES_DIR}/runtime-rs-configs/configuration-clh-runtime-rs.toml" ]; then
            bundled="${INSTALL_FILES_DIR}/runtime-rs-configs/configuration-clh-runtime-rs.toml"
        fi
        # 旧错误名（cloud-hypervisor 段）不可用：4.0 shim 插件注册名为 clh
        if [ -f "$target_config" ] && grep -q '^\[hypervisor\.cloud-hypervisor\]' "$target_config" 2>/dev/null; then
            warn "发现旧版 cloud-hypervisor 段名配置，将用捆绑的 [hypervisor.clh] 覆盖"
            sudo rm -f "$target_config"
        fi
        if [ ! -f "$target_config" ]; then
            if [ -f "$bundled" ]; then
                echo "  安装捆绑的 clh runtime-rs 配置..."
                sudo mkdir -p "$kata_config_dir"
                sudo cp "$bundled" "$target_config"
                pass "已安装 $target_config"
            fi
        fi
    fi

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
            # firmware: 已有 -kernel 直启时不需要 AAVMF/EDK2；4.0.0 默认
            # firmware=/opt/kata/share/aavmf/AAVMF_CODE.fd（64MB）会让冷启动多约 1.3s
            # （本机实测 t_runp ~2.3s → 清掉后 ~0.9s，与 3.22 量级一致）
            if grep -qE '^firmware\s*=' "$target_config" 2>/dev/null; then
                sudo sed -i 's|^firmware = .*|firmware = ""|' "$target_config"
                pass "qemu ARM64 已清空 firmware（-kernel 直启，避免 AAVMF 拖慢冷启动）"
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

    # Dragonball：ARM64 上 virtio-blk-pci 根盘 guest 看不到（VFS Unable to mount root fs），改用 mmio
    # 4.0.0 静态包可能带 AAVMF firmware；runtime-rs 校验要求 dragonball 的 firmware 必须为空
    if [ "$KATA_HYPERVISOR" = "dragonball" ]; then
        echo "  配置 runtime-rs Dragonball..."
        # runtime-rs: "Firmware for dragonball hypervisor should be empty"
        if grep -qE '^firmware\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i 's|^firmware = .*|firmware = ""|' "$target_config"
            pass "dragonball 已强制 firmware=\"\" （4.0 静态包常带 AAVMF，会校验失败）"
        fi
        if [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then
            if grep -q 'vm_rootfs_driver = "virtio-blk-pci"' "$target_config" 2>/dev/null || \
               grep -q 'block_device_driver = "virtio-blk-pci"' "$target_config" 2>/dev/null; then
                sudo sed -i 's|vm_rootfs_driver = "virtio-blk-pci"|vm_rootfs_driver = "virtio-blk-mmio"|' "$target_config"
                sudo sed -i 's|block_device_driver = "virtio-blk-pci"|block_device_driver = "virtio-blk-mmio"|' "$target_config"
                pass "dragonball ARM64 rootfs/block 驱动已改为 virtio-blk-mmio"
            else
                pass "dragonball ARM64 rootfs 驱动已是 mmio/非 pci"
            fi
        fi
    fi

    # Cloud Hypervisor (clh)：virtio-fs；ARM64 清 firmware、避免 virtio-pmem
    if [ "$KATA_HYPERVISOR" = "clh" ]; then
        echo "  配置 runtime-rs Cloud Hypervisor (clh)..."
        if ! grep -qE '^\[hypervisor\.clh\]' "$target_config" 2>/dev/null; then
            fail "clh 配置缺少 [hypervisor.clh]（Kata 4.0 插件名是 clh，不是 cloud-hypervisor）"
            return 1
        fi
        if grep -qE '^firmware\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i 's|^firmware = .*|firmware = ""|' "$target_config"
            pass "clh 已强制 firmware=\"\""
        fi
        if [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then
            sudo sed -i 's|vm_rootfs_driver = "virtio-pmem"|vm_rootfs_driver = "virtio-blk-pci"|' "$target_config"
            pass "clh ARM64 vm_rootfs_driver 使用 virtio-blk-pci"
        fi
        local cfg_kernel actual_kernel
        cfg_kernel=$(grep -E '^kernel =' "$target_config" | head -1 | sed 's/.*= *"//;s/"//')
        if [ -n "$cfg_kernel" ] && [ ! -e "$cfg_kernel" ]; then
            actual_kernel=$(ls /opt/kata/share/kata-containers/vmlinux-[0-9]* 2>/dev/null | grep -v dragonball | head -1 || true)
            [ -n "$actual_kernel" ] && sudo sed -i "s|^kernel = .*|kernel = \"$actual_kernel\"|" "$target_config"
        fi
    fi

    # Firecracker：default_maxvcpus=0 会解析为宿主机 CPU 数；本机 128+/256 超过
    # kata-types MAX_FIRECRACKER_VCPUS=32，校验失败 "can not support N vCPUs"
    # 另：vm_rootfs_driver 若为 virtio-blk-pci，guest 可能挂不上根盘 → agent hvsock unwrap panic
    if [ "$KATA_HYPERVISOR" = "firecracker" ]; then
        echo "  配置 runtime-rs Firecracker..."
        # 未显式写时默认 DEFAULT_BLOCK_DEVICE_TYPE=virtio-blk-pci，FC 不支持
        if grep -qE '^vm_rootfs_driver\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i 's|^vm_rootfs_driver = .*|vm_rootfs_driver = "virtio-blk-mmio"|' "$target_config"
        else
            sudo sed -i '/^block_device_driver = /a vm_rootfs_driver = "virtio-blk-mmio"' "$target_config"
        fi
        pass "firecracker vm_rootfs_driver = virtio-blk-mmio"
        # jailer 在部分环境下导致路径/挂载异常；默认关掉（可按需再开）
        if grep -qE '^jailer_path\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i 's|^jailer_path = |#jailer_path = |' "$target_config"
            pass "firecracker 已注释 jailer_path（非 jail 启动）"
        fi
        # 4.0.0 静态包把旧 dial_timeout=45(秒) 误写成 dial_timeout_ms=45000，
        # 而 reconnect 默认 3000 → retry_times=0 → hybrid_vsock last_err.unwrap() panic
        if grep -qE '^dial_timeout_ms\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i 's|^dial_timeout_ms = .*|dial_timeout_ms = 10|' "$target_config"
        else
            sudo sed -i '/^\[agent\.kata\]/a dial_timeout_ms = 10' "$target_config" 2>/dev/null || \
                echo 'dial_timeout_ms = 10' | sudo tee -a "$target_config" >/dev/null
        fi
        if grep -qE '^reconnect_timeout_ms\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i 's|^reconnect_timeout_ms = .*|reconnect_timeout_ms = 45000|' "$target_config"
        else
            sudo sed -i '/^dial_timeout_ms = /a reconnect_timeout_ms = 45000' "$target_config"
        fi
        pass "firecracker agent dial_timeout_ms=10, reconnect_timeout_ms=45000"
        local fc_max_vcpus=32
        local cur_max
        cur_max=$(grep -E '^default_maxvcpus\s*=' "$target_config" 2>/dev/null | head -1 | awk -F= '{gsub(/ /,"",$2); print $2}')
        if [ -z "$cur_max" ] || [ "$cur_max" = "0" ] || [ "$cur_max" -gt "$fc_max_vcpus" ] 2>/dev/null; then
            sudo sed -i "s|^default_maxvcpus = .*|default_maxvcpus = ${fc_max_vcpus}|" "$target_config"
            pass "firecracker default_maxvcpus ${cur_max:-unset} → ${fc_max_vcpus}（上限 MAX_FIRECRACKER_VCPUS）"
        else
            pass "firecracker default_maxvcpus=$cur_max（≤${fc_max_vcpus}）"
        fi
    fi

    # StratoVirt：Go runtime；ARM64 轻量机用 microvm+mmio（官方默认），标准机用 virt+pci
    if [ "$KATA_HYPERVISOR" = "stratovirt" ]; then
        echo "  配置 Go runtime StratoVirt..."
        local cfg_kernel actual_kernel
        cfg_kernel=$(grep -E '^kernel =' "$target_config" | head -1 | sed 's/.*= *"//;s/"//')
        if [ -n "$cfg_kernel" ] && [ ! -e "$cfg_kernel" ]; then
            actual_kernel=$(ls /opt/kata/share/kata-containers/vmlinux-[0-9]* 2>/dev/null | grep -v dragonball | head -1 || true)
            [ -n "$actual_kernel" ] && sudo sed -i "s|^kernel = .*|kernel = \"$actual_kernel\"|" "$target_config"
        fi
        # 确保 virtiofsd 路径存在
        if [ ! -x /opt/kata/libexec/virtiofsd ] && [ -x /opt/kata/bin/virtiofsd ]; then
            sudo sed -i 's|/opt/kata/libexec/virtiofsd|/opt/kata/bin/virtiofsd|' "$target_config"
        fi
        pass "stratovirt machine_type=$(grep -E '^machine_type' "$target_config" | head -1 | awk -F= '{gsub(/[" ]/,"",$2);print $2}') shared_fs=virtio-fs"
    fi

    # VM templating（Go qemu）：initrd、关 image、shared_fs≠virtio-fs、enable_template
    if $VM_TEMPLATE; then
        echo "  配置 Go runtime QEMU VM templating..."
        local initrd="/opt/kata/share/kata-containers/kata-containers-initrd.img"
        if [ ! -e "$initrd" ]; then
            fail "缺少 initrd: $initrd（VM template 要求 initrd，不支持纯 image）"
            return 1
        fi
        # image 与 initrd 不能同时设置
        if grep -qE '^image\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i 's|^image = |#image = |' "$target_config"
        fi
        if grep -qE '^#\s*initrd\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i "s|^#\s*initrd = .*|initrd = \"$initrd\"|" "$target_config"
        elif grep -qE '^initrd\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i "s|^initrd = .*|initrd = \"$initrd\"|" "$target_config"
        else
            sudo sed -i "/^\[hypervisor\.qemu\]/a initrd = \"$initrd\"" "$target_config"
        fi
        # template 与 virtio-fs 互斥。virtio-9p 在本机 guest agent/initrd 无 9p handler。
        # shared_fs=none + 静态 shim 补丁（MkdirAll sharePath）才能走 factory。
        if grep -qE '^shared_fs\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i 's|^shared_fs = .*|shared_fs = "none"|' "$target_config"
        else
            sudo sed -i '/^\[hypervisor\.qemu\]/a shared_fs = "none"' "$target_config"
        fi
        if grep -qE '^disable_block_device_use\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i 's|^disable_block_device_use = .*|disable_block_device_use = false|' "$target_config"
        fi
        if grep -qE '^enable_template\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i 's|^enable_template = .*|enable_template = true|' "$target_config"
        else
            sudo sed -i '/^\[factory\]/a enable_template = true' "$target_config"
        fi
        if ! grep -qE '^template_path\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i '/^enable_template = /a template_path = "/run/vc/vm/template"' "$target_config"
        fi
        # 与 VM Cache 互斥
        if grep -qE '^vm_cache_number\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i 's|^vm_cache_number = .*|vm_cache_number = 0|' "$target_config"
        fi
        # ARM64 qemu 常用修补
        if [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then
            sudo sed -i 's|machine_type = "q35"|machine_type = "virt"|' "$target_config"
            if grep -qE '^firmware\s*=' "$target_config" 2>/dev/null; then
                sudo sed -i 's|^firmware = .*|firmware = ""|' "$target_config"
            fi
            warn "ARM64 上 VM templating 官方测试曾 skip（可能不稳定）"
        fi
        # ARM64 virt：pcie_root_port 仅在 hot_plug_vfio=root-port 时生效；
        # template 无网卡时 epNum=0，否则不会创建 rp0，后续 ipvlan 热插失败。
        if grep -qE '^hot_plug_vfio\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i 's|^hot_plug_vfio = .*|hot_plug_vfio = "root-port"|' "$target_config"
        elif grep -qE '^#\s*hot_plug_vfio\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i 's|^#\s*hot_plug_vfio = .*|hot_plug_vfio = "root-port"|' "$target_config"
        else
            sudo sed -i '/^default_bridges = /a hot_plug_vfio = "root-port"' "$target_config"
        fi
        if grep -qE '^pcie_root_port\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i 's|^pcie_root_port = .*|pcie_root_port = 1|' "$target_config"
        else
            sudo sed -i '/^hot_plug_vfio = /a pcie_root_port = 1' "$target_config" 2>/dev/null || true
            if ! grep -qE '^pcie_root_port\s*=' "$target_config" 2>/dev/null; then
                sudo sed -i '/^default_bridges = /a pcie_root_port = 1' "$target_config"
            fi
        fi
        # static_sandbox_resource_mgmt 会把 DefaultMaxVCPUs 压成 default_vcpus；
        # factory 校验严格匹配，default_maxvcpus=0（主机核数）会导致永远 fallback 直启。
        local def_vcpus
        def_vcpus=$(grep -E '^default_vcpus\s*=' "$target_config" 2>/dev/null | head -1 | awk -F= '{gsub(/[" ]/,"",$2);print int($2)}')
        [ -z "$def_vcpus" ] || [ "$def_vcpus" -le 0 ] 2>/dev/null && def_vcpus=1
        if grep -qE '^default_maxvcpus\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i "s|^default_maxvcpus = .*|default_maxvcpus = $def_vcpus|" "$target_config"
        else
            sudo sed -i "/^default_vcpus = /a default_maxvcpus = $def_vcpus" "$target_config"
        fi
        # qemu+devmapper：sandbox_cgroup_only=false 会 cgroup.procs EINVAL（kata#6977）
        if grep -qE '^sandbox_cgroup_only\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i 's|^sandbox_cgroup_only = .*|sandbox_cgroup_only = true|' "$target_config"
        elif grep -qE '^#\s*sandbox_cgroup_only\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i 's|^#\s*sandbox_cgroup_only = .*|sandbox_cgroup_only = true|' "$target_config"
        else
            sudo sed -i '/^\[runtime\]/a sandbox_cgroup_only = true' "$target_config"
        fi
        pass "vm-template: enable_template=true, initrd, shared_fs=none, hot_plug_vfio=root-port, pcie_root_port=1, default_maxvcpus=$def_vcpus, sandbox_cgroup_only=true"
    fi

    # VM Cache（Go qemu）：预热池；与 template 互斥；factory 预热同样要求 shared_fs≠virtio-fs
    if [ "$VM_CACHE_NUMBER" -gt 0 ]; then
        echo "  配置 Go runtime QEMU VM Cache (n=${VM_CACHE_NUMBER})..."
        if ! grep -qE '^\[factory\]' "$target_config" 2>/dev/null; then
            printf '\n[factory]\n' | sudo tee -a "$target_config" >/dev/null
        fi
        if grep -qE '^enable_template\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i 's|^enable_template = .*|enable_template = false|' "$target_config"
        else
            sudo sed -i '/^\[factory\]/a enable_template = false' "$target_config"
        fi
        if grep -qE '^vm_cache_number\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i "s|^vm_cache_number = .*|vm_cache_number = ${VM_CACHE_NUMBER}|" "$target_config"
        elif grep -qE '^#\s*vm_cache_number\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i "s|^#\s*vm_cache_number = .*|vm_cache_number = ${VM_CACHE_NUMBER}|" "$target_config"
        else
            sudo sed -i "/^\[factory\]/a vm_cache_number = ${VM_CACHE_NUMBER}" "$target_config"
        fi
        if grep -qE '^vm_cache_endpoint\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i "s|^vm_cache_endpoint = .*|vm_cache_endpoint = \"${VM_CACHE_ENDPOINT}\"|" "$target_config"
        elif grep -qE '^#\s*vm_cache_endpoint\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i "s|^#\s*vm_cache_endpoint = .*|vm_cache_endpoint = \"${VM_CACHE_ENDPOINT}\"|" "$target_config"
        else
            sudo sed -i "/^vm_cache_number = /a vm_cache_endpoint = \"${VM_CACHE_ENDPOINT}\"" "$target_config"
        fi
        # factory GetBaseVM 时 SharedPath 为空 → virtio-fs 报 virtiofsd source path is empty
        if grep -qE '^shared_fs\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i 's|^shared_fs = .*|shared_fs = "none"|' "$target_config"
        else
            sudo sed -i '/^\[hypervisor\.qemu\]/a shared_fs = "none"' "$target_config"
        fi
        if grep -qE '^disable_block_device_use\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i 's|^disable_block_device_use = .*|disable_block_device_use = false|' "$target_config"
        fi
        # 热插网卡需要 root-port（与 template 同因）
        if grep -qE '^hot_plug_vfio\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i 's|^hot_plug_vfio = .*|hot_plug_vfio = "root-port"|' "$target_config"
        elif grep -qE '^#\s*hot_plug_vfio\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i 's|^#\s*hot_plug_vfio = .*|hot_plug_vfio = "root-port"|' "$target_config"
        else
            sudo sed -i '/^default_bridges = /a hot_plug_vfio = "root-port"' "$target_config"
        fi
        if grep -qE '^pcie_root_port\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i 's|^pcie_root_port = .*|pcie_root_port = 1|' "$target_config"
        else
            sudo sed -i '/^hot_plug_vfio = /a pcie_root_port = 1' "$target_config" 2>/dev/null || true
            if ! grep -qE '^pcie_root_port\s*=' "$target_config" 2>/dev/null; then
                sudo sed -i '/^default_bridges = /a pcie_root_port = 1' "$target_config"
            fi
        fi
        if grep -qE '^sandbox_cgroup_only\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i 's|^sandbox_cgroup_only = .*|sandbox_cgroup_only = true|' "$target_config"
        elif grep -qE '^#\s*sandbox_cgroup_only\s*=' "$target_config" 2>/dev/null; then
            sudo sed -i 's|^#\s*sandbox_cgroup_only = .*|sandbox_cgroup_only = true|' "$target_config"
        else
            sudo sed -i '/^\[runtime\]/a sandbox_cgroup_only = true' "$target_config"
        fi
        if [ "$(uname -m)" = "aarch64" ] || [ "$(uname -m)" = "arm64" ]; then
            sudo sed -i 's|machine_type = "q35"|machine_type = "virt"|' "$target_config"
            if grep -qE '^firmware\s*=' "$target_config" 2>/dev/null; then
                sudo sed -i 's|^firmware = .*|firmware = ""|' "$target_config"
            fi
        fi
        pass "vm-cache: enable_template=false, vm_cache_number=${VM_CACHE_NUMBER}, shared_fs=none, sandbox_cgroup_only=true"
    fi


    # 校验 hypervisor 二进制（dragonball 内置，无独立 path）
    case "$KATA_HYPERVISOR" in
        qemu)
            if [ ! -x /opt/kata/bin/qemu-system-x86_64 ] && \
               [ ! -x /opt/kata/bin/qemu-system-aarch64 ]; then
                warn "未找到 qemu-system-*，请确认 kata-static 已完整安装"
            fi
            ;;
        clh)
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
        stratovirt)
            [ -x /opt/kata/bin/stratovirt ] || {
                fail "缺少 /opt/kata/bin/stratovirt"
                return 1
            }
            ;;
    esac

    # default_config 已在上方按 Go/runtime-rs 设好目录
    local current_target
    local hypervisor_changed=false
    current_target=$(readlink -f "$default_config" 2>/dev/null || true)
    if [ "$current_target" = "$(readlink -f "$target_config")" ]; then
        pass "kata hypervisor 已是 $KATA_HYPERVISOR ($target_link_name)"
    elif $CHECK_ONLY; then
        warn "hypervisor 期望 $KATA_HYPERVISOR，当前: ${current_target:-none}"
        return 1
    else
        echo "  切换 hypervisor → $KATA_HYPERVISOR ($target_link_name)"
        sudo rm -f "$default_config"
        sudo ln -s "$target_link_name" "$default_config"
        hypervisor_changed=true
        pass "kata hypervisor 已设为 $KATA_HYPERVISOR"
    fi


    # VM template / VM Cache：安装静态 kata-runtime；template 同步 init，cache 走常驻服务
    _ensure_kata_runtime_static() {
        local kata_rt_static="$KATA_BIN_DIR/kata-runtime-go-static"
        local kata_rt_bundled="${INSTALL_FILES_DIR}/go-shim-static/kata-runtime"
        if [ ! -x "$kata_rt_static" ] || ! "$kata_rt_static" --version &>/dev/null; then
            if [ -x "$kata_rt_bundled" ]; then
                echo "  安装捆绑的静态 kata-runtime（factory CLI）..."
                sudo install -m 0755 "$kata_rt_bundled" "$kata_rt_static"
            else
                fail "缺少 ${kata_rt_bundled}（见 config/kata/go-shim-static/README.md）"
                return 1
            fi
        fi
        pass "kata-runtime（factory）: $("$kata_rt_static" --version 2>/dev/null | head -1)"
        return 0
    }

    _stop_vm_cache_server() {
        if systemctl list-unit-files "${VM_CACHE_UNIT}" &>/dev/null || \
           [ -f "/etc/systemd/system/${VM_CACHE_UNIT}" ]; then
            sudo systemctl stop "${VM_CACHE_UNIT}" >/dev/null 2>&1 || true
            sudo systemctl disable "${VM_CACHE_UNIT}" >/dev/null 2>&1 || true
        fi
        # 兜底：清掉残留 socket / 孤儿进程
        local kata_rt_static="$KATA_BIN_DIR/kata-runtime-go-static"
        if [ -x "$kata_rt_static" ]; then
            sudo "$kata_rt_static" --config "$default_config" factory destroy >/dev/null 2>&1 || true
        fi
        sudo rm -f "$VM_CACHE_ENDPOINT" >/dev/null 2>&1 || true
    }

    _start_vm_cache_server() {
        local kata_rt_static="$KATA_BIN_DIR/kata-runtime-go-static"
        local unit_path="/etc/systemd/system/${VM_CACHE_UNIT}"
        sudo tee "$unit_path" >/dev/null <<EOF
[Unit]
Description=Kata Containers VMCache server (pre-warmed VMs)
Documentation=https://github.com/kata-containers/kata-containers/blob/main/docs/how-to/what-is-vm-cache-and-how-do-I-use-it.md
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
WorkingDirectory=/run/vc/vm
ExecStartPre=/bin/mkdir -p /run/vc/vm
ExecStart=${kata_rt_static} --config ${default_config} factory init
ExecStop=${kata_rt_static} --config ${default_config} factory destroy
Restart=on-failure
RestartSec=3
# factory init 常驻；池大小由 configuration.toml 的 vm_cache_number 决定

[Install]
WantedBy=multi-user.target
EOF
        sudo systemctl daemon-reload
        # 先停旧实例，避免 socket 占用
        sudo systemctl stop "${VM_CACHE_UNIT}" >/dev/null 2>&1 || true
        sudo rm -f "$VM_CACHE_ENDPOINT" >/dev/null 2>&1 || true
        if ! sudo systemctl enable --now "${VM_CACHE_UNIT}"; then
            fail "启动 ${VM_CACHE_UNIT} 失败"
            sudo journalctl -u "${VM_CACHE_UNIT}" -n 40 --no-pager 2>/dev/null || true
            return 1
        fi
        # 等待池中至少有一台预热 VM（workers 失败会永久退出，不能只看 socket）
        local kata_rt_static="$KATA_BIN_DIR/kata-runtime-go-static"
        local i status_out
        for i in $(seq 1 120); do
            if ! systemctl is-active --quiet "${VM_CACHE_UNIT}"; then
                fail "${VM_CACHE_UNIT} 已退出"
                sudo journalctl -u "${VM_CACHE_UNIT}" -n 40 --no-pager 2>/dev/null || true
                return 1
            fi
            status_out=$(sudo "$kata_rt_static" --config "$default_config" factory status 2>/dev/null || true)
            if echo "$status_out" | grep -qE '^VM pid ='; then
                local nready
                nready=$(echo "$status_out" | grep -cE '^VM pid =' || true)
                pass "vm-cache server 就绪（${VM_CACHE_UNIT}, 池中 ${nready}/${VM_CACHE_NUMBER}）"
                return 0
            fi
            # 早期失败特征：virtiofsd / create new vm
            if journalctl -u "${VM_CACHE_UNIT}" -n 30 --no-pager 2>/dev/null | grep -q 'failed to create new vm'; then
                # 给一点时间看是否仍有 worker 在重试；cache 实现失败即退出 worker
                sleep 2
                status_out=$(sudo "$kata_rt_static" --config "$default_config" factory status 2>/dev/null || true)
                if ! echo "$status_out" | grep -qE '^VM pid ='; then
                    fail "vm-cache 预热失败（池为空）。详见: journalctl -u ${VM_CACHE_UNIT}"
                    sudo journalctl -u "${VM_CACHE_UNIT}" -n 40 --no-pager 2>/dev/null || true
                    return 1
                fi
            fi
            sleep 1
        done
        fail "等待 vm-cache 预热超时（${VM_CACHE_NUMBER} 台）"
        sudo "$kata_rt_static" --config "$default_config" factory status 2>/dev/null || true
        sudo journalctl -u "${VM_CACHE_UNIT}" -n 40 --no-pager 2>/dev/null || true
        return 1
    }

    if $VM_TEMPLATE; then
        _ensure_kata_runtime_static || return 1
        if ! $CHECK_ONLY; then
            _stop_vm_cache_server
            echo "  初始化 VM factory（kata-runtime factory init / template）..."
            local kata_rt_static="$KATA_BIN_DIR/kata-runtime-go-static"
            sudo "$kata_rt_static" --config "$default_config" factory destroy >/dev/null 2>&1 || true
            if sudo "$kata_rt_static" --config "$default_config" factory init; then
                pass "vm factory 已初始化（template_path=/run/vc/vm/template）"
            else
                fail "kata-runtime factory init 失败（ARM64 上可能不稳定，见官方 template 测试 skip）"
                return 1
            fi
        fi
    elif [ "$VM_CACHE_NUMBER" -gt 0 ]; then
        _ensure_kata_runtime_static || return 1
        if ! $CHECK_ONLY; then
            # 与 template 互斥：清掉残留 template
            if [ -d /run/vc/vm/template ]; then
                echo "  清理旧 VM template（与 vm-cache 互斥）..."
                local kata_rt_static="$KATA_BIN_DIR/kata-runtime-go-static"
                sudo "$kata_rt_static" --config "$default_config" factory destroy >/dev/null 2>&1 || \
                    sudo umount /run/vc/vm/template >/dev/null 2>&1 || true
                sudo rm -rf /run/vc/vm/template >/dev/null 2>&1 || true
            fi
            echo "  启动 VM Cache server（预热 ${VM_CACHE_NUMBER} 台）..."
            _start_vm_cache_server || return 1
        fi
    else
        if ! $CHECK_ONLY; then
            # 离开 cache：停常驻服务
            if systemctl is-active --quiet "${VM_CACHE_UNIT}" 2>/dev/null || \
               [ -S "$VM_CACHE_ENDPOINT" ]; then
                echo "  停止 VM Cache server..."
                _stop_vm_cache_server
                pass "vm-cache server 已停止"
            fi
            # 离开 template：清理残留 factory（避免占 tmpfs）
            if [ -d /run/vc/vm/template ]; then
                local kata_rt_static="$KATA_BIN_DIR/kata-runtime-go-static"
                if [ -x "$kata_rt_static" ]; then
                    echo "  清理旧 VM factory..."
                    sudo "$kata_rt_static" factory destroy >/dev/null 2>&1 || \
                        sudo umount /run/vc/vm/template >/dev/null 2>&1 || true
                    sudo rm -rf /run/vc/vm/template >/dev/null 2>&1 || true
                fi
            fi
            # 若仍指向 Go qemu 配置，把 cache number 归零以免下次误连
            if [ -f /opt/kata/share/defaults/kata-containers/configuration-qemu.toml ]; then
                local go_qemu=/opt/kata/share/defaults/kata-containers/configuration-qemu.toml
                if grep -qE '^vm_cache_number\s*=\s*[1-9]' "$go_qemu" 2>/dev/null; then
                    sudo sed -i 's|^vm_cache_number = .*|vm_cache_number = 0|' "$go_qemu"
                fi
            fi
        fi
    fi

    # ---- 2. 检查 containerd 是否注册了 kata runtime ---- #
    # containerd v2 (config version>=3) 使用 io.containerd.cri.v1.runtime；
    # 旧版使用 io.containerd.grpc.v1.cri。写错路径时 grep 仍能命中，但 CRI 看不到 kata。
    local config_file="/etc/containerd/config.toml"
    local cri_runtime_plugin="io.containerd.grpc.v1.cri"
    if grep -q "io.containerd.cri.v1.runtime" "$config_file" 2>/dev/null; then
        cri_runtime_plugin="io.containerd.cri.v1.runtime"
    fi
    local kata_runtime_section="[plugins.\"${cri_runtime_plugin}\".containerd.runtimes.kata]"
    local kata_options_section="[plugins.\"${cri_runtime_plugin}\".containerd.runtimes.kata.options]"
    # 单引号写法（containerd config dump 常用）
    local kata_runtime_section_alt="[plugins.'${cri_runtime_plugin}'.containerd.runtimes.kata]"
    local kata_options_section_alt="[plugins.'${cri_runtime_plugin}'.containerd.runtimes.kata.options]"

    # 使用本轮选中的 configuration.toml（runtime-rs 子目录或 Go 顶层）
    local kata_config_path="$default_config"

    _kata_section_present() {
        grep -qF "$kata_runtime_section" "$config_file" 2>/dev/null || \
            grep -qF "$kata_runtime_section_alt" "$config_file" 2>/dev/null
    }

    _kata_active_in_cri() {
        # crictl info 的 runtimes 才是 CRI 实际加载的 handler
        crictl info 2>/dev/null | grep -q '"kata"'
    }

    _write_kata_runtime_block() {
        local snap_line=""
        if [ "$SNAPSHOTTER" = "devmapper" ]; then
            snap_line="  snapshotter = 'devmapper'"
        fi
        # 注意：整块末尾必须有空行，便于后续按 section 清理；options 用完整表路径（与本机 dump 风格一致）
        sudo tee -a "$config_file" > /dev/null <<KATAEOF

${kata_runtime_section}
  runtime_type = 'io.containerd.kata.v2'
  runtime_path = '${kata_shim}'
  privileged_without_host_devices = true
${snap_line}
  pod_annotations = ['io.katacontainers.*']
${kata_options_section}
  ConfigPath = '${kata_config_path}'

KATAEOF
    }

    _strip_stale_kata_sections() {
        # 不能用 sed '/runtimes.kata/,/^$/d'：会误匹配 .kata.options，且嵌套无空行时会留下碎片
        # （曾导致 toml: table options already exists，containerd 无法启动）
        # 注意：错误写入时 section 头可能带缩进，必须 trim 后再判断
        local tmp
        tmp=$(mktemp)
        awk '
            {
                raw = $0
                line = $0
                sub(/^[[:space:]]+/, "", line)
            }
            line ~ /^\[/ {
                if (line ~ /runtimes\.kata(\.options)?[[:space:]]*\]/) {
                    skip = 1
                } else {
                    skip = 0
                }
            }
            skip { next }
            # 清理曾残留在其它 section 末尾的碎片行
            line ~ /^pod_annotations[[:space:]]*=[[:space:]]*\[.*katacontainers/ { next }
            line ~ /^ConfigPath[[:space:]]*=[[:space:]]*.*kata-containers/ { next }
            { print raw }
        ' "$config_file" > "$tmp"
        # 压缩多余空行
        sudo awk 'BEGIN{blank=0} /^$/{blank++; if(blank<=1) print; next} {blank=0; print}' "$tmp" | sudo tee "$config_file" >/dev/null
        rm -f "$tmp"
    }

    local need_restart=false
    local need_reregister=false

    if _kata_section_present; then
        local need_fix=false
        local cur_path cur_cfg
        cur_path=$(awk '/\[plugins.*runtimes\.kata\]/{p=1} p&&/runtime_path/{print; exit}' "$config_file")
        cur_cfg=$(awk '/\[plugins.*runtimes\.kata(\.options)?\]/{p=1} p&&/ConfigPath/{print; exit}' "$config_file")
        # 重复的 kata.options / 无法 parse → 强制重写（曾拖垮 containerd）
        local kata_opt_count
        kata_opt_count=$(grep -cE 'runtimes\.kata\.options' "$config_file" 2>/dev/null || echo 0)
        if [ "${kata_opt_count:-0}" -gt 1 ] 2>/dev/null; then
            warn "检测到重复的 kata.options 段（${kata_opt_count}），正在清理重写..."
            need_fix=true
        elif ! sudo containerd config dump >/dev/null 2>&1; then
            warn "containerd config.toml 无法解析，正在清理重写 kata 段..."
            need_fix=true
        fi
        if $use_go_runtime; then
            if ! echo "$cur_path" | grep -qE 'go-static|/opt/kata/bin/containerd-shim-kata-v2'; then
                warn "kata runtime_path 未指向 Go shim，正在修正..."
                need_fix=true
            fi
            if echo "$cur_cfg" | grep -q 'runtime-rs'; then
                warn "kata ConfigPath 仍指向 runtime-rs，正在改为 Go 配置..."
                need_fix=true
            elif ! echo "$cur_cfg" | grep -q 'kata-containers/configuration.toml'; then
                # 允许顶层 configuration.toml；若完全不对也修正
                if ! echo "$cur_cfg" | grep -q "$kata_config_path"; then
                    warn "kata ConfigPath 与 stratovirt 期望不符，正在修正..."
                    need_fix=true
                fi
            fi
            # shim 路径变化时也要重写
            if ! echo "$cur_path" | grep -Fq "$kata_shim"; then
                need_fix=true
            fi
        else
            if ! echo "$cur_path" | grep -q runtime-rs; then
                warn "kata runtime_path 未指向 runtime-rs，正在修正..."
                need_fix=true
            fi
            if ! echo "$cur_cfg" | grep -q runtime-rs; then
                warn "kata ConfigPath 未指向 runtime-rs，正在修正..."
                need_fix=true
            fi
        fi
        if $need_fix; then
            if $CHECK_ONLY; then
                warn "containerd kata 配置路径不正确"
                return 1
            fi
            _strip_stale_kata_sections
            _write_kata_runtime_block
            need_restart=true
            pass "containerd kata 配置已修正（plugin=${cri_runtime_plugin}）"
        elif $hypervisor_changed; then
            need_restart=true
            pass "containerd 已注册 kata runtime（hypervisor 已切换）"
        else
            pass "containerd 已注册 kata runtime（plugin=${cri_runtime_plugin}）"
        fi
    else
        # 可能只写了旧路径，或完全未注册
        if grep -q "io.containerd.kata.v2" "$config_file" 2>/dev/null; then
            warn "kata 写在非活动 CRI 路径，需迁移到 ${cri_runtime_plugin}"
        fi
        need_reregister=true
    fi

    if $need_reregister; then
        if $CHECK_ONLY; then
            warn "containerd 未在活动路径注册 kata runtime（期望 plugin=${cri_runtime_plugin}）"
            return 1
        fi
        echo "  注册 kata runtime 到 containerd（plugin=${cri_runtime_plugin}）..."
        _strip_stale_kata_sections
        _write_kata_runtime_block
        need_restart=true
    fi

    if $need_restart && ! $CHECK_ONLY; then
        echo "  重启 containerd 使 kata runtime 生效..."
        if ! sudo systemctl restart containerd; then
            fail "containerd 重启失败，检查 /etc/containerd/config.toml"
            return 1
        fi
        sleep 3
    fi

    # 验证：配置文件 + CRI 实际可见
    if ! _kata_section_present; then
        fail "kata runtime 注册失败（配置未写入活动路径 ${cri_runtime_plugin}）"
        return 1
    fi
    if _kata_active_in_cri; then
        pass "kata runtime 已对 CRI 生效（crictl 可见）"
        return 0
    fi

    # 配置正确但 CRI 未见：再重启一次（常见于先前写错路径）
    if ! $CHECK_ONLY; then
        warn "kata 已写入 ${cri_runtime_plugin}，但 crictl 未见，再重启 containerd..."
        if ! sudo systemctl restart containerd; then
            fail "containerd 重启失败，检查 /etc/containerd/config.toml"
            return 1
        fi
        sleep 3
        if _kata_active_in_cri; then
            pass "kata runtime 已对 CRI 生效（crictl 可见）"
            return 0
        fi
        fail "kata 已写入 ${cri_runtime_plugin}，但 crictl 仍看不到 kata"
        return 1
    fi

    warn "kata 已写入 ${cri_runtime_plugin}，但 crictl 尚未看到 kata"
    return 1
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

    if [ "$current_subnet" = "$CNI_SUBNET" ]; then
        pass "CNI subnet 已匹配: $current_subnet"
    else
        if $CHECK_ONLY; then
            warn "CNI subnet 不匹配: 当前=$current_subnet, 需要=$CNI_SUBNET"
            return 1
        fi
        echo "  更新 CNI subnet: $current_subnet → $CNI_SUBNET ..."
        sudo sed -i "s|\"subnet\": \"[^\"]*\"|\"subnet\": \"$CNI_SUBNET\"|" "$CNI_CONF_FILE"
        sudo rm -rf /var/lib/cni/networks/mynet/
        if [ "$CNI_TYPE" = "bridge" ]; then
            sudo ip link delete cni0 2>/dev/null || true
            # 清掉旧网段节点级 MASQUERADE，避免残留
            if [ -n "$current_subnet" ] && \
               sudo iptables -t nat -C POSTROUTING -s "$current_subnet" ! -o cni0 -j MASQUERADE 2>/dev/null; then
                echo "  删除旧节点级 MASQUERADE: -s $current_subnet ! -o cni0 ..."
                sudo iptables -t nat -D POSTROUTING -s "$current_subnet" ! -o cni0 -j MASQUERADE || true
            fi
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

# 查找 crictl（兼容 sudo 精简 PATH）
find_crictl() {
    if command -v crictl &>/dev/null; then
        command -v crictl
        return 0
    fi
    local p
    for p in /usr/local/bin/crictl /usr/bin/crictl; do
        if [ -x "$p" ]; then
            echo "$p"
            return 0
        fi
    done
    return 1
}

# ============================================================
# 检查 crictl
# ============================================================
check_crictl() {
    echo ""
    echo "--- crictl ---"

    local crictl_bin ver
    if crictl_bin=$(find_crictl); then
        # 保证后续步骤（含 sudo 子 shell）能直接调用
        if ! command -v crictl &>/dev/null; then
            export PATH="$(dirname "$crictl_bin"):${PATH}"
        fi
        ver=$("$crictl_bin" --version 2>/dev/null | head -1)
        pass "crictl 已安装: $ver ($crictl_bin)"
    else
        if $CHECK_ONLY; then
            fail "crictl 未安装"
            return 1
        fi
        # CRICTL_VERSION 已含 v 前缀，如 v1.30.0
        warn "crictl 未安装，正在安装 ${CRICTL_VERSION}..."

        local pkg url tarball
        pkg="crictl-${CRICTL_VERSION}-linux-${ARCH}.tar.gz"
        url="https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/${pkg}"
        tarball=$(fetch_pkg "$pkg" "$url")
        sudo tar -C /usr/local/bin -xzf "$tarball"
        sudo chmod +x /usr/local/bin/crictl
        export PATH="/usr/local/bin:${PATH}"
        pass "crictl 安装完成: $(/usr/local/bin/crictl --version)"
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
    local expected_timeout=30
    local cur_timeout=""

    if $CHECK_ONLY; then
        if [ ! -f "$config_file" ]; then
            warn "crictl 配置文件不存在，将使用默认 endpoint/timeout"
        else
            pass "crictl 配置文件存在: $config_file"
            cur_timeout=$(grep -E '^timeout:' "$config_file" 2>/dev/null | awk '{print $2}' | tr -d '"' || true)
            if [ "$cur_timeout" = "$expected_timeout" ]; then
                pass "crictl timeout 已是 ${expected_timeout}s"
            else
                warn "crictl timeout 为 ${cur_timeout:-未设置}（期望 ${expected_timeout}s）"
            fi
        fi
    else
        # 强制写入：已有文件也会覆盖 timeout / endpoint，避免历史 5s/10s 残留
        echo "  写入 crictl 配置 (timeout=${expected_timeout}s)..."
        cat | sudo tee "$config_file" > /dev/null <<EOF
runtime-endpoint: ${expected_endpoint}
image-endpoint: ${expected_endpoint}
timeout: ${expected_timeout}
debug: false
EOF
        pass "crictl 配置已强制写入: timeout=${expected_timeout}s endpoint=${expected_endpoint}"
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
        echo "  3. 默认 snapshotter 插件是否 ok: ctr plugins ls | grep snapshotter"
        echo "     （erofs 需先 modprobe erofs，否则 CRI ImageService 会 Unimplemented）"
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
# 准备 containerd devmapper thin-pool（Firecracker 必需）
# ============================================================
ensure_devmapper() {
    echo ""
    echo "--- devmapper thin-pool ---"

    if ! command -v dmsetup >/dev/null 2>&1 || ! command -v losetup >/dev/null 2>&1; then
        fail "缺少 dmsetup/losetup，无法配置 devmapper"
        return 1
    fi

    local data_file="${DEVMAPPER_DATA_DIR}/data4"
    local meta_file="${DEVMAPPER_DATA_DIR}/meta4"
    local reload_script="/usr/local/sbin/devmapper-reload.sh"
    local reload_unit="/etc/systemd/system/devmapper-reload.service"
    local config_file="/etc/containerd/config.toml"
    local need_restart=false

    if $CHECK_ONLY; then
        if dmsetup info "$DEVMAPPER_POOL_NAME" >/dev/null 2>&1 && \
           ctr plugins ls 2>/dev/null | grep devmapper | grep -q 'ok'; then
            pass "devmapper pool=$DEVMAPPER_POOL_NAME 就绪"
            return 0
        fi
        warn "devmapper 未就绪（pool 或插件）"
        return 1
    fi

    sudo mkdir -p "$DEVMAPPER_DATA_DIR"
    if [ ! -f "$data_file" ]; then
        echo "  创建 sparse data ${DEVMAPPER_DATA_SIZE} → $data_file"
        sudo truncate -s "$DEVMAPPER_DATA_SIZE" "$data_file"
    fi
    if [ ! -f "$meta_file" ]; then
        echo "  创建 sparse meta ${DEVMAPPER_META_SIZE} → $meta_file"
        sudo truncate -s "$DEVMAPPER_META_SIZE" "$meta_file"
    fi

    if ! dmsetup info "$DEVMAPPER_POOL_NAME" >/dev/null 2>&1; then
        echo "  创建 thin-pool $DEVMAPPER_POOL_NAME ..."
        # 清理可能残留的 loop 绑定
        local old
        for f in "$data_file" "$meta_file"; do
            while read -r old; do
                [ -n "$old" ] && sudo losetup -d "$old" 2>/dev/null || true
            done < <(losetup -j "$f" -O NAME -n 2>/dev/null || true)
        done
        local data_dev meta_dev data_size length
        data_dev=$(sudo losetup --find --show --direct-io=on "$data_file" 2>/dev/null \
            || sudo losetup --find --show "$data_file")
        meta_dev=$(sudo losetup --find --show --direct-io=on "$meta_file" 2>/dev/null \
            || sudo losetup --find --show "$meta_file")
        data_size=$(sudo blockdev --getsize64 "$data_dev")
        length=$((data_size / 512))
        sudo dmsetup create "$DEVMAPPER_POOL_NAME" \
            --table "0 ${length} thin-pool ${meta_dev} ${data_dev} 128 32768"
        pass "thin-pool $DEVMAPPER_POOL_NAME 已创建"
        need_restart=true
    else
        pass "thin-pool $DEVMAPPER_POOL_NAME 已存在"
    fi

    # 写入/更新 containerd devmapper 插件配置
    if ! grep -q "pool_name = '${DEVMAPPER_POOL_NAME}'" "$config_file" 2>/dev/null && \
       ! grep -q "pool_name = \"${DEVMAPPER_POOL_NAME}\"" "$config_file" 2>/dev/null; then
        echo "  写入 containerd devmapper 插件配置..."
        # 兼容单引号 / 双引号 section 写法
        if grep -q "io.containerd.snapshotter.v1.devmapper" "$config_file"; then
            sudo sed -i \
                -e "/io.containerd.snapshotter.v1.devmapper/,/^$/s|root_path = .*|root_path = '${DEVMAPPER_DATA_DIR}'|" \
                -e "/io.containerd.snapshotter.v1.devmapper/,/^$/s|pool_name = .*|pool_name = '${DEVMAPPER_POOL_NAME}'|" \
                -e "/io.containerd.snapshotter.v1.devmapper/,/^$/s|base_image_size = .*|base_image_size = '${DEVMAPPER_BASE_IMAGE_SIZE}'|" \
                -e "/io.containerd.snapshotter.v1.devmapper/,/^$/s|discard_blocks = .*|discard_blocks = true|" \
                "$config_file"
            # fs_type 空串时补 ext4（部分版本需要）
            if grep -A8 "io.containerd.snapshotter.v1.devmapper" "$config_file" | grep -q "fs_type = ''"; then
                sudo sed -i "/io.containerd.snapshotter.v1.devmapper/,/^$/s|fs_type = ''|fs_type = 'ext4'|" "$config_file"
            fi
        else
            sudo tee -a "$config_file" >/dev/null <<EOF

[plugins.'io.containerd.snapshotter.v1.devmapper']
  root_path = '${DEVMAPPER_DATA_DIR}'
  pool_name = '${DEVMAPPER_POOL_NAME}'
  base_image_size = '${DEVMAPPER_BASE_IMAGE_SIZE}'
  discard_blocks = true
  fs_type = 'ext4'
EOF
        fi
        need_restart=true
        pass "containerd devmapper 插件已配置"
    else
        pass "containerd devmapper 插件已配置"
    fi

    # 重启后自动恢复 thin-pool
    sudo tee "$reload_script" >/dev/null <<'RELOAD'
#!/bin/bash
set -euo pipefail
DATA_DIR=/var/lib/containerd/devmapper
POOL_NAME=devpool4
DATA_FILE="${DATA_DIR}/data4"
META_FILE="${DATA_DIR}/meta4"
[ -f "$DATA_FILE" ] && [ -f "$META_FILE" ] || exit 0
if dmsetup info "$POOL_NAME" >/dev/null 2>&1; then
    exit 0
fi
DATA_DEV=$(losetup --find --show --direct-io=on "$DATA_FILE" 2>/dev/null || losetup --find --show "$DATA_FILE")
META_DEV=$(losetup --find --show --direct-io=on "$META_FILE" 2>/dev/null || losetup --find --show "$META_FILE")
LENGTH=$(($(blockdev --getsize64 "$DATA_DEV") / 512))
dmsetup create "$POOL_NAME" --table "0 ${LENGTH} thin-pool ${META_DEV} ${DATA_DEV} 128 32768"
RELOAD
    sudo chmod +x "$reload_script"
    sudo tee "$reload_unit" >/dev/null <<EOF
[Unit]
Description=Reload containerd devmapper thin-pool
DefaultDependencies=no
Before=containerd.service
After=local-fs.target

[Service]
Type=oneshot
ExecStart=${reload_script}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
Also=containerd.service
EOF
    sudo systemctl daemon-reload
    if ! sudo systemctl enable devmapper-reload.service >/dev/null 2>&1; then
        sudo systemctl enable devmapper-reload.service
    fi

    if $need_restart; then
        echo "  重启 containerd 以加载 devmapper..."
        sudo systemctl restart containerd
        sleep 2
    fi

    if ctr plugins ls 2>/dev/null | grep devmapper | grep -q 'ok'; then
        pass "devmapper 插件状态 ok"
        return 0
    fi
    # 再试一次重启
    sudo systemctl restart containerd
    sleep 2
    if ctr plugins ls 2>/dev/null | grep devmapper | grep -q 'ok'; then
        pass "devmapper 插件状态 ok"
        return 0
    fi
    fail "devmapper 插件未就绪（ctr plugins ls | grep devmapper）"
    return 1
}

# ============================================================
# 确保 erofs 内核模块可用（否则 containerd 会 skip 插件并拖垮 CRI）
# ============================================================
ensure_erofs() {
    echo ""
    echo "--- erofs 内核模块 ---"

    if $CHECK_ONLY; then
        if lsmod 2>/dev/null | grep -q '^erofs\b' \
            && ctr plugins ls 2>/dev/null | grep -E 'snapshotter\.v1[[:space:]]+erofs' | grep -q 'ok'; then
            pass "erofs 模块与 snapshotter 插件就绪"
            return 0
        fi
        warn "erofs 未就绪（需 modprobe erofs，且插件状态 ok）"
        return 1
    fi

    if ! command -v mkfs.erofs >/dev/null 2>&1; then
        fail "缺少 mkfs.erofs（erofs-utils），无法使用 erofs snapshotter"
        return 1
    fi

    if ! lsmod 2>/dev/null | grep -q '^erofs\b'; then
        echo "  加载 erofs 内核模块..."
        if ! sudo modprobe erofs 2>/dev/null; then
            fail "modprobe erofs 失败（内核未启用 CONFIG_EROFS_FS？）"
            return 1
        fi
        pass "erofs 模块已加载"
    else
        pass "erofs 模块已加载"
    fi

    # 开机自动加载，避免重启后 CRI 因 snapshotter=erofs 而挂掉
    if [ ! -f /etc/modules-load.d/erofs.conf ]; then
        echo "erofs" | sudo tee /etc/modules-load.d/erofs.conf >/dev/null
        pass "已写入 /etc/modules-load.d/erofs.conf"
    fi

    return 0
}

# 切换/确认 snapshotter 后校验插件与 CRI（erofs 未加载时会 failed to find snapshotter）
_verify_snapshotter_ready() {
    local name="$1"
    if ! ctr plugins ls 2>/dev/null | grep -E "snapshotter\\.v1[[:space:]]+${name}" | grep -q 'ok'; then
        fail "snapshotter \"$name\" 插件未就绪（ctr plugins ls | grep $name）"
        if [ "$name" = "erofs" ]; then
            echo "  提示: journalctl -u containerd 常见原因: EROFS unsupported, please \`modprobe erofs\`"
        fi
        return 1
    fi
    if ! crictl info >/dev/null 2>&1; then
        fail "CRI 不可用：默认 snapshotter=$name 但插件加载失败，已拖垮 ImageService"
        return 1
    fi
    return 0
}

# ============================================================
# 检查 snapshotter 配置
# ============================================================
check_snapshotter() {
    echo ""
    echo "--- snapshotter ---"

    if [ "$SNAPSHOTTER" = "devmapper" ]; then
        ensure_devmapper || return 1
    fi
    if [ "$SNAPSHOTTER" = "erofs" ]; then
        ensure_erofs || return 1
    fi

    local config_file="/etc/containerd/config.toml"
    local current_snapshotter
    current_snapshotter=$(grep -oP "snapshotter\s*=\s*'\K[^']*" "$config_file" 2>/dev/null | head -1)

    if [ "$current_snapshotter" = "$SNAPSHOTTER" ]; then
        # kata runtime 段也尽量对齐 devmapper
        if [ "$SNAPSHOTTER" = "devmapper" ] && [ "$CONTAINERD_RUNTIME" = "kata" ]; then
            if ! awk '/\[plugins.*runtimes\.kata\]/{p=1} p&&/^\[/{if(!/runtimes\.kata/)p=0} p&&/snapshotter/{print; exit}' "$config_file" | grep -q devmapper; then
                if ! $CHECK_ONLY; then
                    if ! grep -A12 'runtimes\.kata\]' "$config_file" | grep -q "snapshotter"; then
                        warn "kata runtime 未声明 snapshotter=devmapper，正在补齐..."
                        sudo sed -i "/\[plugins.*runtimes\.kata\]/a\\  snapshotter = 'devmapper'" "$config_file"
                        sudo systemctl restart containerd
                        sleep 2
                    fi
                fi
            fi
        fi
        # 配置已是目标值，但仍可能因模块未加载导致 CRI 挂掉（尤其 erofs）
        if ! $CHECK_ONLY; then
            if ! ctr plugins ls 2>/dev/null | grep -E "snapshotter\\.v1[[:space:]]+${SNAPSHOTTER}" | grep -q 'ok'; then
                warn "snapshotter=$SNAPSHOTTER 已配置但插件未 ok，重启 containerd..."
                sudo systemctl restart containerd
                sleep 2
            fi
            _verify_snapshotter_ready "$SNAPSHOTTER" || return 1
        fi
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

    # kata + devmapper：runtime 段也写上
    if [ "$SNAPSHOTTER" = "devmapper" ] && [ "$CONTAINERD_RUNTIME" = "kata" ]; then
        if ! awk '/\[plugins.*runtimes\.kata\]/{p=1} p&&/snapshotter/{print; exit}' "$config_file" | grep -q devmapper; then
            sudo sed -i "/\[plugins.*runtimes\.kata\]/a\\  snapshotter = 'devmapper'" "$config_file"
        fi
    fi

    # 重启 containerd 使配置生效
    echo "  重启 containerd..."
    sudo systemctl restart containerd
    sleep 2
    _verify_snapshotter_ready "$SNAPSHOTTER" || return 1
    pass "snapshotter 已切换为: $SNAPSHOTTER"

    return 0
}

# ============================================================
# 检查 pause 镜像
# ============================================================
check_pause_image() {
    echo ""
    echo "--- pause 镜像 ---"

    _pause_listed() {
        crictl images 2>/dev/null | awk '{print $1":"$2}' | grep -qF "$PAUSE_IMAGE"
    }

    # devmapper：content 在但未 unpack 时 CRI 会报 not unpacked；用 ctr mount 触发 unpack
    _ensure_pause_unpacked() {
        [ "$SNAPSHOTTER" = "devmapper" ] || return 0
        # 已有 committed snapshot 即视为已 unpack（避免残留 View 干扰）
        # ctr snapshots ls：无 PARENT 时 KIND 在 $2，有 PARENT 时在 $3
        if sudo ctr -n k8s.io snapshots --snapshotter "$SNAPSHOTTER" ls 2>/dev/null | awk 'NR>1 && /Committed/{found=1} END{exit !found}'; then
            return 0
        fi
        local mnt="/tmp/pause-${SNAPSHOTTER}-unpack-$$"
        sudo mkdir -p "$mnt"
        sudo ctr -n k8s.io images unmount "$mnt" >/dev/null 2>&1 || true
        local plat="linux/${ARCH}"
        [ "$ARCH" = "arm64" ] && plat="linux/arm64"
        if sudo ctr -n k8s.io images mount --snapshotter "$SNAPSHOTTER" --platform "$plat" "$PAUSE_IMAGE" "$mnt" >/dev/null 2>&1            || sudo ctr -n k8s.io images mount --snapshotter "$SNAPSHOTTER" "$PAUSE_IMAGE" "$mnt" >/dev/null 2>&1; then
            sudo ctr -n k8s.io images unmount "$mnt" >/dev/null 2>&1 || true
            sudo ctr -n k8s.io snapshots --snapshotter "$SNAPSHOTTER" rm "$mnt" >/dev/null 2>&1 || true
            sudo rmdir "$mnt" 2>/dev/null || true
            return 0
        fi
        sudo rmdir "$mnt" 2>/dev/null || true
        return 1
    }

    if _pause_listed; then
        if [ "$SNAPSHOTTER" = "devmapper" ] && ! $CHECK_ONLY; then
            if _ensure_pause_unpacked; then
                pass "pause 镜像已缓存并 unpack 到 devmapper: $PAUSE_IMAGE"
                return 0
            fi
            warn "pause 已在镜像库但 devmapper unpack 失败，尝试重新 pull..."
        else
            pass "pause 镜像已缓存: $PAUSE_IMAGE"
            return 0
        fi
    fi

    if $CHECK_ONLY; then
        fail "pause 镜像缺失: $PAUSE_IMAGE"
        return 1
    fi

    warn "pause 镜像缺失，正在拉取: $PAUSE_IMAGE ..."
    if crictl pull "$PAUSE_IMAGE"; then
        _ensure_pause_unpacked || true
        pass "pause 镜像拉取完成"
        return 0
    fi

    # 离线：content 可能已有，仅需 devmapper unpack
    if _pause_listed && _ensure_pause_unpacked; then
        pass "pause 镜像已从本地 content unpack 到 $SNAPSHOTTER"
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
# cgroup v2: cpu controller + BPF device（runc 硬性依赖）
# ============================================================
# 探测 BPF_CGROUP_DEVICE 是否可用（cgroup v2 设备权限依赖 CONFIG_CGROUP_BPF）
# 注意: bpf_cmd / bpf_attach_type 枚举随内核演进，硬编码单一常量会在旧内核上误报 EINVAL。
# 例如 5.10 BTF: BPF_PROG_QUERY=16 BPF_CGROUP_DEVICE=6；较新 UAPI 常为 17 / 15。
_cgroup_bpf_device_ok() {
    python3 - <<'PY' 2>/dev/null
import ctypes, ctypes.util, os, platform, sys
NR_BPF = {"x86_64": 321, "aarch64": 280, "arm64": 280}.get(platform.machine(), 321)
libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
fd = os.open("/sys/fs/cgroup", os.O_RDONLY)

# (BPF_PROG_QUERY, BPF_CGROUP_DEVICE) 候选：先试本机常见旧值，再试新 UAPI
candidates = [(16, 6), (17, 15)]
ok = False
for cmd, attach_type in candidates:
    # 与 libbpf/bpftool 一致：传入完整 union bpf_attr 大小，尾部置零
    buf = (ctypes.c_byte * 128)()
    # target_fd u32 @0, attach_type u32 @4；其余保持 0（prog_ids=NULL, prog_cnt=0）
    ctypes.c_uint32.from_buffer(buf, 0).value = fd
    ctypes.c_uint32.from_buffer(buf, 4).value = attach_type
    ctypes.set_errno(0)
    ret = libc.syscall(NR_BPF, cmd, buf, 128)
    err = ctypes.get_errno()
    # 成功，或 ENOSPC/ENOBUFS/E2BIG（缓冲区不够但仍说明该 attach 受支持）
    if ret == 0 or err in (7, 28, 105):
        ok = True
        break
os.close(fd)
sys.exit(0 if ok else 1)
PY
}

check_cgroup_v2_cpu() {
    echo ""
    echo "--- cgroup v2 (cpu + BPF device) ---"

    if [ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null || true)" != "cgroup2fs" ]; then
        pass "非 cgroup v2（或未挂载），跳过"
        return 0
    fi

    local errors_local=0
    local root_sub k8s_ctrl

    # ---- BPF device（缺则 runc: bpf_prog_query(BPF_CGROUP_DEVICE) failed）----
    if _cgroup_bpf_device_ok; then
        pass "BPF_CGROUP_DEVICE 可用"
    else
        fail "内核不支持 cgroup BPF device（bpf_prog_query BPF_CGROUP_DEVICE 失败）"
        echo "  可查: zgrep CONFIG_CGROUP_BPF /proc/config.gz ；bpftool feature | grep cgroup_device"
        echo "  runc 在 cgroup v2 上用 eBPF 替代 v1 devices 控制器，缺则无法创建容器"
        echo "  修复任选:"
        echo "    A) 换回 cgroup v1: 去掉 cmdline 中 systemd.unified_cgroup_hierarchy=1 后 reboot"
        echo "    B) 换/重编启用 CONFIG_CGROUP_BPF=y 的内核"
        errors_local=$((errors_local + 1))
    fi

    # ---- cpu controller ----
    root_sub=$(cat /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true)
    if echo " $root_sub " | grep -qw cpu; then
        pass "root cgroup.subtree_control 含 cpu: $root_sub"
    else
        if ! $CHECK_ONLY; then
            if echo '+cpu' | sudo tee /sys/fs/cgroup/cgroup.subtree_control >/dev/null 2>&1; then
                root_sub=$(cat /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true)
                pass "已写入 +cpu → $root_sub"
            fi
        fi
        if ! echo " $(cat /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true) " | grep -qw cpu; then
            fail "cgroup v2 root 未启用 cpu（当前: ${root_sub:-empty}）"
            echo "  runc 会因缺少 cpu.weight 失败"
            echo "  修复: DefaultCPUAccounting=yes + reboot"
            if ! $CHECK_ONLY; then
                sudo mkdir -p /etc/systemd/system.conf.d
                if [ ! -f /etc/systemd/system.conf.d/50-cpu-accounting.conf ]; then
                    sudo tee /etc/systemd/system.conf.d/50-cpu-accounting.conf >/dev/null <<'EOF'
[Manager]
DefaultCPUAccounting=yes
EOF
                    pass "已写入 DefaultCPUAccounting=yes（需 reboot 生效）"
                else
                    pass "已存在 50-cpu-accounting.conf（需 reboot 若尚未重启）"
                fi
            fi
            errors_local=$((errors_local + 1))
        fi
    fi

    if [ -d /sys/fs/cgroup/k8s.io ]; then
        k8s_ctrl=$(cat /sys/fs/cgroup/k8s.io/cgroup.controllers 2>/dev/null || true)
        if echo " $k8s_ctrl " | grep -qw cpu; then
            pass "k8s.io cgroup.controllers 含 cpu"
        else
            fail "k8s.io 无 cpu controller（$k8s_ctrl）"
            errors_local=$((errors_local + 1))
        fi
    else
        pass "k8s.io 尚未创建（首次 runp 时会继承 root 的 cpu）"
    fi

    [ "$errors_local" -eq 0 ]
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
        if $VM_TEMPLATE; then
            echo "  VM template: on (Go factory)"
        elif [ "$VM_CACHE_NUMBER" -gt 0 ]; then
            echo "  VM cache:    on (n=${VM_CACHE_NUMBER}, Go factory server)"
        fi
    fi
    echo "  CNI 类型:    $CNI_TYPE"
    echo "  CNI subnet:  $CNI_SUBNET"
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
    # snapshotter 须在 CRI 连通性检查之前：默认 snapshotter 指向未加载的 erofs 时
    # 会拖垮 ImageService，导致后续 crictl/pause 全部 Unimplemented
    check_snapshotter     || errors=$((errors + 1))
    check_crictl_config   || { [[ $? -eq 1 ]] && errors=$((errors + 1)); }
    check_registry_mirror || errors=$((errors + 1))
    check_pause_image     || errors=$((errors + 1))
    check_kernel_params
    check_cgroup_v2_cpu   || errors=$((errors + 1))

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
            (cd "$REPO_ROOT" && python3 "$warmup_py" --runtime "$CONTAINERD_RUNTIME" --runs 3)
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
