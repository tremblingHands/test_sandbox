#!/bin/bash
# ============================================================
# 清理脱离 CRI 视图的 kata 孤儿（shim / hypervisor / run 目录）
#
# 背景:
#   crictl rmp 只清 containerd/CRI 的 pod 元数据。runp 超时后 shim 可能已用
#   长寿命 ctx 拉起 VM，客户端拿不到 sandbox_id，rmp -a 看不到这些进程。
#
# 用法:
#   ./cleanup_orphans.sh              # 默认：先尝试 rmp，再杀孤儿并校验
#   ./cleanup_orphans.sh --check      # 仅统计，有残留则 exit 1
#   ./cleanup_orphans.sh --kill       # 强制清理（与默认相同，可显式写出）
#   ./cleanup_orphans.sh --log FILE   # 明细写入 FILE（stdout 只打摘要）
#
# 环境变量:
#   CLEANUP_TIMEOUT   crictl -t（默认 60s）
#   CLEANUP_ROUNDS    rmp 重试轮数（默认 3）
# ============================================================
set -euo pipefail

MODE="kill"   # check | kill
LOG_FILE=""
CRI_TIMEOUT="${CLEANUP_TIMEOUT:-60s}"
CRI_ROUNDS="${CLEANUP_ROUNDS:-3}"

usage() {
    sed -n '2,18p' "$0" | sed 's/^# \?//'
    exit 0
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage ;;
        --check) MODE="check"; shift ;;
        --kill)  MODE="kill"; shift ;;
        --log)
            LOG_FILE="$2"; shift 2 ;;
        *)
            echo "未知参数: $1" >&2
            exit 2 ;;
    esac
done

log() {
    if [ -n "$LOG_FILE" ]; then
        printf '%s\n' "$*" >>"$LOG_FILE"
    fi
}

# 终端摘要
say() { printf '%s\n' "$*"; }

# 匹配进程：打印 "pid cmd"，无匹配时空。
# pattern 经 -v 传入 awk；排除扫描器自身（含 awk/本脚本）。
list_procs() {
    local pat="$1"
    local self=$$
    # shellcheck disable=SC2009
    ps -eo pid=,args= | awk -v pat="$pat" -v self="$self" '
        $1 == self { next }
        {
            pid = $1
            $1 = ""
            cmd = $0
            sub(/^ +/, "", cmd)
            if (cmd ~ /(^|[ \/])awk([ ]|$)/) next
            if (cmd ~ /cleanup_orphans\.sh/) next
            if (pat != "" && cmd ~ pat) print pid, cmd
        }'
}

count_procs() {
    list_procs "$1" | wc -l | tr -d ' '
}

count_dir_entries() {
    local d="$1"
    if [ -d "$d" ]; then
        # 不含 . / ..；空目录为 0
        find "$d" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '
    else
        echo 0
    fi
}

# 各类孤儿计数（stdout: name=N 多行）
snapshot() {
    echo "shim_kata=$(count_procs 'containerd-shim-kata')"
    echo "qemu=$(count_procs 'qemu-system')"
    echo "cloud_hypervisor=$(count_procs 'cloud-hypervisor')"
    echo "firecracker=$(count_procs '(^|/)firecracker( |$)')"
    echo "virtiofsd=$(count_procs 'virtiofsd')"
    echo "dragonball=$(count_procs 'dragonball')"
    echo "stratovirt=$(count_procs 'stratovirt')"
    echo "run_kata=$(count_dir_entries /run/kata)"
    echo "run_vc_sbs=$(count_dir_entries /run/vc/sbs)"
    echo "run_vc_vm=$(count_dir_entries /run/vc/vm)"
    local pods=0
    if command -v crictl >/dev/null 2>&1; then
        pods=$(crictl -t "$CRI_TIMEOUT" pods -q 2>/dev/null | grep -c . || true)
    fi
    echo "crictl_pods=${pods:-0}"
}

total_orphans_from_snap() {
    # 不含 crictl_pods：pod 由 rmp 管；这里看进程+目录
    awk -F= '
        /^shim_kata=/ || /^qemu=/ || /^cloud_hypervisor=/ || /^firecracker=/ ||
        /^virtiofsd=/ || /^dragonball=/ || /^stratovirt=/ ||
        /^run_kata=/ || /^run_vc_sbs=/ || /^run_vc_vm=/ {
            n += $2
        }
        END { print n+0 }
    '
}

# 打印快照摘要；孤儿合计写入全局 ORPHAN_TOTAL（不含 crictl_pods）
ORPHAN_TOTAL=0
print_snapshot() {
    local prefix="$1"
    local snap sample
    snap=$(snapshot)
    ORPHAN_TOTAL=$(printf '%s\n' "$snap" | total_orphans_from_snap)
    say "${prefix}$(printf '%s\n' "$snap" | tr '\n' ' ' | sed 's/ $//')  orphan_total=${ORPHAN_TOTAL}"
    log "===== ${prefix}$(date '+%Y-%m-%d %H:%M:%S') orphan_total=${ORPHAN_TOTAL} ====="
    log "$snap"
    sample=$(list_procs 'containerd-shim-kata|qemu-system|cloud-hypervisor|firecracker|virtiofsd|dragonball|stratovirt' | head -n 8 || true)
    if [ -n "$sample" ]; then
        log "sample processes:"
        log "$sample"
    fi
}

cri_rmp_rounds() {
    command -v crictl >/dev/null 2>&1 || return 0
    local round=1 remain
    remain=$(crictl -t "$CRI_TIMEOUT" pods -q 2>/dev/null | grep -c . || true)
    if [ "${remain:-0}" -eq 0 ]; then
        say "  crictl pods: 0（跳过 rmp）"
        return 0
    fi
    while [ "$round" -le "$CRI_ROUNDS" ]; do
        remain=$(crictl -t "$CRI_TIMEOUT" pods -q 2>/dev/null | grep -c . || true)
        [ "${remain:-0}" -eq 0 ] && break
        say "  crictl rmp 第 ${round}/${CRI_ROUNDS} 轮: pods=${remain}"
        log "===== crictl rmp round ${round} remain=${remain} ====="
        {
            crictl -t "$CRI_TIMEOUT" rmp -a -f || crictl -t "$CRI_TIMEOUT" rmp --all --force || true
        } >>"${LOG_FILE:-/dev/null}" 2>&1
        sleep 1
        round=$((round + 1))
    done
}

kill_pattern() {
    local pat="$1"
    local pids
    pids=$(list_procs "$pat" | awk '{print $1}' || true)
    if [ -z "$pids" ]; then
        return 0
    fi
    log "SIGKILL pattern=$pat pids=$(echo "$pids" | tr '\n' ' ')"
    # shellcheck disable=SC2086
    kill -9 $pids 2>/dev/null || true
}

kill_orphans() {
    # 先 shim（可能是 hypervisor 父进程），再 HV / virtiofsd
    kill_pattern 'containerd-shim-kata'
    kill_pattern 'qemu-system'
    kill_pattern 'cloud-hypervisor'
    kill_pattern '(^|/)firecracker( |$)'
    kill_pattern 'virtiofsd'
    kill_pattern 'dragonball'
    kill_pattern 'stratovirt'
    sleep 1
    # 第二轮：仍存活的再杀一次
    kill_pattern 'containerd-shim-kata'
    kill_pattern 'qemu-system'
    kill_pattern 'cloud-hypervisor'
    kill_pattern '(^|/)firecracker( |$)'
    kill_pattern 'virtiofsd'
    kill_pattern 'dragonball'
    kill_pattern 'stratovirt'
}

clean_run_dirs() {
    # 保留 vm-cache / template 目录本身，只清实例子项
    local d
    for d in /run/kata /run/vc/sbs; do
        if [ -d "$d" ]; then
            log "rm -rf ${d:?}/*"
            # 不用 rm -rf "$d"，避免权限/挂载奇怪时误伤
            find "$d" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
        fi
    done
    # /run/vc/vm：保留 template（factory），清其余 sandbox 目录
    if [ -d /run/vc/vm ]; then
        find /run/vc/vm -mindepth 1 -maxdepth 1 ! -name template -exec rm -rf {} + 2>/dev/null || true
        log "cleaned /run/vc/vm (kept template if any)"
    fi
    # kata-containers 下常见为 sock/命名空间残留；保留 cache.sock（vm-cache）
    if [ -d /run/kata-containers ]; then
        find /run/kata-containers -mindepth 1 -maxdepth 1 \
            ! -name 'cache.sock' \
            -exec rm -rf {} + 2>/dev/null || true
        log "cleaned /run/kata-containers (kept cache.sock if any)"
    fi
}

# ---------- main ----------
if [ -n "$LOG_FILE" ]; then
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    : >"$LOG_FILE"
fi

print_snapshot "before: "
before=$ORPHAN_TOTAL

if [ "$MODE" = "check" ]; then
    if [ "$before" -gt 0 ]; then
        say "[cleanup_orphans] 检测到孤儿合计 ${before}（进程+run 目录项），exit 1"
        exit 1
    fi
    say "[cleanup_orphans] 无孤儿"
    exit 0
fi

# MODE=kill
if [ "$before" -eq 0 ]; then
    # 仍可能有 crictl pods
    cri_rmp_rounds
    print_snapshot "after: "
    if [ "$ORPHAN_TOTAL" -eq 0 ]; then
        say "[cleanup_orphans] 无需清理"
        exit 0
    fi
fi

say "[cleanup_orphans] 清理中（CRI rmp → 杀进程 → 清 /run）..."
cri_rmp_rounds
kill_orphans
clean_run_dirs
sleep 1

print_snapshot "after: "
if [ "$ORPHAN_TOTAL" -gt 0 ]; then
    say "[cleanup_orphans] 仍有残留合计 ${ORPHAN_TOTAL}（见 ${LOG_FILE:-无日志文件}）"
    exit 1
fi
say "[cleanup_orphans] 清理完成（0 残留）"
exit 0
