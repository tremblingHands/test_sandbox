#!/bin/bash
# ============================================================
# 删除 kata-runtime — 清理 kata 二进制与 containerd 配置
#
# 用法:
#   ./scripts/setup/remove_kata.sh           # 完整删除
#   ./scripts/setup/remove_kata.sh --dry-run # 仅展示将要删除的内容
# ============================================================
set -euo pipefail

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

KATA_INSTALL_DIR="/opt/kata"
KATA_SYMLINKS=(
    "/opt/kata/bin/qemu-system-aarch64"
    "/opt/kata/bin/cloud-hypervisor"
    "/opt/kata/bin/firecracker"
    "/opt/kata/bin/stratovirt"
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

say()  { echo -e "$1$2${NC}"; }
run()  { if $DRY_RUN; then echo "  [dry-run] $*"; else "$@"; fi; }

echo "=============================================="
echo "  删除 kata-runtime"
echo "=============================================="
echo

# ---- 0. 清理残留 kata pod ---- #
echo "--- 清理 kata pod ---"
KATA_PODS=$(crictl pods --state Ready -q 2>/dev/null | while read sid; do
    crictl inspectp "$sid" 2>/dev/null | grep -q "io.containerd.kata" && echo "$sid"
done || true)
if [ -n "$KATA_PODS" ]; then
    for sid in $KATA_PODS; do
        echo "  停止/删除 kata pod: ${sid:0:12}..."
        run sudo crictl stopp "$sid" 2>/dev/null
        run sudo crictl rmp "$sid" 2>/dev/null
    done
fi
say "$GREEN" "✓ kata pod 已清理"

# ---- 1. 删除 kata 安装目录 ---- #
echo ""
echo "--- 删除 kata 文件 ---"
if [ -d "$KATA_INSTALL_DIR" ]; then
    if $DRY_RUN; then
        echo "  [dry-run] rm -rf $KATA_INSTALL_DIR"
    else
        say "$YELLOW" "  删除 $KATA_INSTALL_DIR ..."
        sudo rm -rf "$KATA_INSTALL_DIR"
        say "$GREEN" "✓ kata 安装目录已删除"
    fi
else
    echo "  kata 安装目录不存在，跳过"
fi

# ---- 2. 删除 /etc/kata-containers 配置 ---- #
if [ -d /etc/kata-containers ]; then
    run sudo rm -rf /etc/kata-containers
    say "$GREEN" "✓ /etc/kata-containers 已删除"
fi

# ---- 3. 从 containerd config 中移除 kata runtime ---- #
echo ""
echo "--- 清理 containerd 配置 ---"
CONTAINERD_CONFIG="/etc/containerd/config.toml"
if grep -q "io.containerd.kata.v2" "$CONTAINERD_CONFIG" 2>/dev/null; then
    if $DRY_RUN; then
        echo "  [dry-run] 从 containerd config 移除 kata runtime 段"
    else
        # 删除 [plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.kata] 及其子段
        sudo sed -i '/\[plugins.*runtimes\.kata\]/,/^$/d' "$CONTAINERD_CONFIG"
        # 清理残留空行
        sudo sed -i '/^$/{N;/^\n$/d;}' "$CONTAINERD_CONFIG"
        say "$GREEN" "✓ kata runtime 已从 containerd 配置中移除"
    fi
else
    echo "  containerd 中无 kata 配置，跳过"
fi

# ---- 4. 清理 CNI IP 分配记录 ---- #
echo ""
if [ -d "/var/lib/cni/networks/mynet" ]; then
    run sudo rm -rf /var/lib/cni/networks/mynet
    say "$GREEN" "✓ CNI IP 分配记录已清理"
fi

# ---- 5. 重启 containerd ---- #
echo ""
if ! $DRY_RUN; then
    echo "  重启 containerd..."
    if sudo systemctl restart containerd; then
        sleep 2
        say "$GREEN" "✓ containerd 已重启"
    else
        say "$RED" "✗ containerd 重启失败"
        exit 1
    fi
fi

echo ""
echo "=============================================="
say "$GREEN" "kata-runtime 删除完成"
echo "=============================================="
