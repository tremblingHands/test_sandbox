#!/usr/bin/env bash
# 宿主机创建 N 个 ipvlan（仅 ip link add）耗时；可选在 bench 窗口抓 on/off-CPU 火焰图
# 用法:
#   sudo $0 [个数N] [master]
#   sudo $0 100 eth0 --perf-cpus 0-3
#   sudo $0 100 eth0 --perf-cpus 1 --perf-freq 99 --output results/ipvlan_add_perf
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PERF_SCRIPT="${SCRIPT_DIR}/../containerd_perf.sh"

N=100
MASTER=""
PERF_CPUS=""
PERF_FREQ=99
PERF_CALL_GRAPH=fp
OUT_DIR=""

usage() {
    cat <<EOF
用法: $0 [N] [master] [选项]

位置参数:
  N                     创建个数（默认: 100）
  master                ipvlan master（默认: default route 的 dev / eth0）

选项:
  --perf-cpus CPUS      bench 前后启动 capture-live，按 -C 采 on/off-CPU 火焰图
  --perf-freq HZ        on-CPU 采样频率（默认: ${PERF_FREQ}）
  --perf-call-graph M   on-CPU call-graph: fp|dwarf|...（默认: ${PERF_CALL_GRAPH}）
  --output DIR          perf 输出目录（默认: results/ipvlan_host_netlink_add/<ts>/perf）
  -h, --help            帮助

示例:
  sudo $0 100 eth0
  sudo $0 200 eth0 --perf-cpus 0-3
EOF
}

# 先吃掉位置参数，再解析选项
POS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --perf-cpus)      PERF_CPUS="$2"; shift 2 ;;
        --perf-freq)      PERF_FREQ="$2"; shift 2 ;;
        --perf-call-graph) PERF_CALL_GRAPH="$2"; shift 2 ;;
        --output)         OUT_DIR="$2"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        --*)
            echo "错误: 未知参数: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            POS+=("$1"); shift ;;
    esac
done

if (( ${#POS[@]} >= 1 )); then N=${POS[0]}; fi
if (( ${#POS[@]} >= 2 )); then MASTER=${POS[1]}; fi
if (( ${#POS[@]} > 2 )); then
    echo "错误: 多余位置参数: ${POS[*]:2}" >&2
    exit 2
fi

if [[ -z "$MASTER" ]]; then
    MASTER=$(ip route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
    MASTER=${MASTER:-eth0}
fi

if ! [[ "$N" =~ ^[1-9][0-9]*$ ]]; then
    echo "错误: N 须为正整数" >&2
    exit 2
fi

cleanup() {
    ip -o link 2>/dev/null | awk -F': ' '$2 ~ /^ivlb/ {print $2}' |
        while read -r n; do ip link del "${n%%@*}" 2>/dev/null || true; done
}

start_perf() {
    local dir=$1
    mkdir -p "$dir"
    rm -f "${dir}/capture.ready"
    if [[ ! -f "$PERF_SCRIPT" ]]; then
        echo "错误: 未找到 $PERF_SCRIPT" >&2
        return 1
    fi
    if ! command -v perf &>/dev/null; then
        echo "错误: 未找到 perf" >&2
        return 1
    fi
    echo "[perf] capture-live -C ${PERF_CPUS} → ${dir}"
    # 新 session，避免本脚本收到信号时连带打乱 stop 流程
    setsid bash "$PERF_SCRIPT" capture-live \
        --output-dir "$dir" \
        --cpus "$PERF_CPUS" \
        --frequency "$PERF_FREQ" \
        --call-graph "$PERF_CALL_GRAPH" \
        --offcpu-method perf \
        --title-prefix "ipvlan-host-add" \
        </dev/null &
    PERF_PID=$!
    local ready_deadline=$(( $(date +%s) + 30 ))
    while (( $(date +%s) < ready_deadline )); do
        if ! kill -0 "$PERF_PID" 2>/dev/null; then
            echo "错误: capture-live 提前退出" >&2
            wait "$PERF_PID" || true
            return 1
        fi
        if [[ -f "${dir}/capture.ready" ]]; then
            echo "[perf] capture-live ready (pid=${PERF_PID})"
            return 0
        fi
        sleep 0.1
    done
    kill -TERM "$PERF_PID" 2>/dev/null || true
    echo "错误: 等待 capture-live ready 超时" >&2
    return 1
}

stop_perf() {
    if [[ -z "${PERF_PID:-}" ]]; then
        return 0
    fi
    if kill -0 "$PERF_PID" 2>/dev/null; then
        echo "[perf] 停止 capture-live（生成 on/off SVG）..."
        # 只信号 bash 脚本，由其 trap 对 perf 发 SIGINT
        kill -TERM "$PERF_PID" 2>/dev/null || true
        # 生成 SVG 可能较慢
        local w=0
        while kill -0 "$PERF_PID" 2>/dev/null && (( w < 300 )); do
            sleep 1
            w=$((w + 1))
        done
        if kill -0 "$PERF_PID" 2>/dev/null; then
            echo "[perf] 警告: capture-live 超时，强制结束" >&2
            kill -KILL "$PERF_PID" 2>/dev/null || true
        fi
        wait "$PERF_PID" 2>/dev/null || true
    fi
    PERF_PID=""
}

PERF_PID=""
trap 'stop_perf' EXIT

cleanup

if [[ -n "$PERF_CPUS" ]]; then
    if [[ -z "$OUT_DIR" ]]; then
        OUT_DIR="results/ipvlan_host_netlink_add/$(date +%Y%m%d%H%M%S)/perf"
    fi
    start_perf "$OUT_DIR"
fi

ok=0
fail=0
echo "开始测试 (N=${N}, master=${MASTER})"
start=$(date +%s%N)

run_adds() {
    local i name
    for ((i = 1; i <= N; i++)); do
        name=$(printf 'ivlb%08x' "$i")
        if ip link add link "$MASTER" name "$name" type ipvlan mode l3 2>/dev/null; then
            ok=$((ok + 1))
        else
            ip link del "$name" 2>/dev/null || true
            fail=$((fail + 1))
        fi
    done
}

# 有 --perf-cpus 时把创建绑到采样核上，否则火焰图几乎采不到本脚本的 ip
if [[ -n "$PERF_CPUS" ]] && command -v taskset &>/dev/null; then
    echo "[perf] taskset -c ${PERF_CPUS} 绑定 bench"
    # taskset 起子 shell 时 ok/fail 在子进程，需用临时文件回传
    _r=$(mktemp)
    taskset -c "$PERF_CPUS" bash -c '
        set -euo pipefail
        N=$1; MASTER=$2
        ok=0; fail=0
        for ((i=1; i<=N; i++)); do
            name=$(printf "ivlb%08x" "$i")
            if ip link add link "$MASTER" name "$name" type ipvlan mode l3 2>/dev/null; then
                ok=$((ok+1))
            else
                ip link del "$name" 2>/dev/null || true
                fail=$((fail+1))
            fi
        done
        echo "$ok $fail" >"$3"
    ' bash "$N" "$MASTER" "$_r"
    read -r ok fail <"$_r"
    rm -f "$_r"
else
    run_adds
fi
end=$(date +%s%N)

# 必须在 post 清理前停 perf，避免把 DEL 采进去
stop_perf
trap - EXIT

echo "测试结束，开始清理"
cleanup

awk -v ok="$ok" -v fail="$fail" -v a="$start" -v b="$end" \
  'BEGIN{
    sec=(b-a)/1e9;
    printf "n=%d ok=%d fail=%d time=%.4fs", ok+fail, ok, fail, sec;
    if (ok>0 && sec>0) printf " (%.2f ADD/s)", ok/sec;
    printf "\n"
  }'

if [[ -n "$PERF_CPUS" && -n "$OUT_DIR" ]]; then
    echo "perf → ${OUT_DIR}"
    shopt -s nullglob
    svgs=("$OUT_DIR"/*.svg)
    shopt -u nullglob
    if (( ${#svgs[@]} > 0 )); then
        printf '  %s\n' "${svgs[@]}"
    else
        echo "  (无 SVG，可检查 FlameGraph / perf 数据)"
    fi
fi

[[ "$ok" -gt 0 ]]
