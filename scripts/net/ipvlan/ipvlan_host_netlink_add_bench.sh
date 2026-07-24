#!/usr/bin/env bash
# 宿主机创建 N 个 ipvlan（仅 ip link add）耗时；可选火焰图 / 内核函数时延
#
# 绑核与 perf 分开：
#   --cpus CPUS   创建循环 taskset 绑核
#   --perf        开启 on/off-CPU 火焰图（采样核默认跟 --cpus）
#
# 用法:
#   sudo $0 100 eth0 --cpus 128
#   sudo $0 100 eth0 --cpus 128 --perf
#   sudo $0 1000 eth0 --cpus 128 --ktrace --ktrace-mode filter \
#       --ktrace-funcs '*netlink*,*ipvlan*,*netdev*' --ktrace-funcs-max 512
#   sudo $0 200 eth0 --cpus 128 --perf --ktrace
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PERF_SCRIPT="${SCRIPT_DIR}/../../profile/containerd_perf.sh"
KTRACE_SCRIPT="${SCRIPT_DIR}/ipvlan_kfunc_trace.sh"

N=100
MASTER=""
CPUS=""
PERF=0
PERF_FREQ=99
PERF_CALL_GRAPH=fp
OUT_DIR=""
KTRACE=0
KTRACE_FUNCS=""
KTRACE_FUNCS_MAX=""
KTRACE_CPUS=""
KTRACE_MODE=""

usage() {
    cat <<EOF
用法: $0 [N] [master] [选项]

位置参数:
  N                     创建个数（默认: 100）
  master                ipvlan master（默认: default route 的 dev / eth0）

选项:
  --cpus CPUS           创建循环绑核（taskset）；perf/ktrace 未另指定时也用作采样核
  --perf                开启 bench 窗口 on/off-CPU 火焰图（需同时给 --cpus）
  --perf-freq HZ        on-CPU 采样频率（默认: ${PERF_FREQ}）
  --perf-call-graph M   on-CPU call-graph: fp|dwarf|...（默认: ${PERF_CALL_GRAPH}）
  --ktrace              bench 窗口抓内核函数时延（调用 ipvlan_kfunc_trace.sh）
  --ktrace-funcs LIST   逗号分隔；精确名或 ftrace glob（如 ipvlan_*；默认见 ktrace 脚本）
  --ktrace-funcs-max N  展开后函数数上限（默认见 ipvlan_kfunc_trace.sh --funcs-max）
  --ktrace-cpus CPUS    ktrace 采样核（默认跟 --cpus）
  --ktrace-mode MODE    graph|filter（默认 graph；见 ipvlan_kfunc_trace.sh --mode）
  --output DIR          输出根目录（默认: results/ipvlan_host_netlink_add/<ts>）
  -h, --help            帮助

兼容（旧）:
  --perf-cpus CPUS      等价于 --cpus CPUS --perf

示例:
  sudo \$0 100 eth0 --cpus 128
  sudo \$0 200 eth0 --cpus 128 --perf
  sudo \$0 1000 eth0 --cpus 128 --ktrace --ktrace-mode filter \\
      --ktrace-funcs '*netlink*,*ipvlan*,*netdev*' --ktrace-funcs-max 512
  sudo \$0 200 eth0 --cpus 128 --perf --ktrace --ktrace-mode graph
EOF
}

POS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --cpus)            CPUS="$2"; shift 2 ;;
        --perf)            PERF=1; shift ;;
        --perf-cpus)       # 兼容旧用法
            CPUS="$2"
            PERF=1
            shift 2
            ;;
        --perf-freq)       PERF_FREQ="$2"; shift 2 ;;
        --perf-call-graph) PERF_CALL_GRAPH="$2"; shift 2 ;;
        --ktrace)          KTRACE=1; shift ;;
        --ktrace-funcs)    KTRACE_FUNCS="$2"; KTRACE=1; shift 2 ;;
        --ktrace-funcs-max) KTRACE_FUNCS_MAX="$2"; KTRACE=1; shift 2 ;;
        --ktrace-cpus)     KTRACE_CPUS="$2"; KTRACE=1; shift 2 ;;
        --ktrace-mode)     KTRACE_MODE="$2"; KTRACE=1; shift 2 ;;
        --output)          OUT_DIR="$2"; shift 2 ;;
        -h|--help)         usage; exit 0 ;;
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

if [[ "$PERF" -eq 1 && -z "$CPUS" ]]; then
    echo "错误: --perf 需要同时指定 --cpus（作为 -C 采样核）" >&2
    exit 2
fi

# ktrace 采样核：显式 --ktrace-cpus > --cpus
if [[ "$KTRACE" -eq 1 && -z "$KTRACE_CPUS" && -n "$CPUS" ]]; then
    KTRACE_CPUS=$CPUS
fi
if [[ -n "$KTRACE_MODE" && "$KTRACE_MODE" != "graph" && "$KTRACE_MODE" != "filter" ]]; then
    echo "错误: --ktrace-mode 须为 graph 或 filter" >&2
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
    echo "[perf] capture-live -C ${CPUS}（脚本绑核 0）→ ${dir}"
    setsid taskset -c 0 bash "$PERF_SCRIPT" capture-live \
        --output-dir "$dir" \
        --cpus "$CPUS" \
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
        kill -TERM "$PERF_PID" 2>/dev/null || true
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

start_ktrace() {
    local dir=$1
    mkdir -p "$dir"
    rm -f "${dir}/capture.ready"
    if [[ ! -x "$KTRACE_SCRIPT" && ! -f "$KTRACE_SCRIPT" ]]; then
        echo "错误: 未找到 $KTRACE_SCRIPT" >&2
        return 1
    fi
    local -a args=(capture-live --output-dir "$dir" --affinity 0)
    if [[ -n "$KTRACE_FUNCS" ]]; then
        args+=(--funcs "$KTRACE_FUNCS")
    fi
    if [[ -n "$KTRACE_FUNCS_MAX" ]]; then
        args+=(--funcs-max "$KTRACE_FUNCS_MAX")
    fi
    if [[ -n "$KTRACE_CPUS" ]]; then
        args+=(--cpus "$KTRACE_CPUS")
    fi
    if [[ -n "$KTRACE_MODE" ]]; then
        args+=(--mode "$KTRACE_MODE")
    fi
    echo "[ktrace] ${KTRACE_SCRIPT} ${args[*]}"
    setsid bash "$KTRACE_SCRIPT" "${args[@]}" </dev/null &
    KTRACE_PID=$!
    local ready_deadline=$(( $(date +%s) + 30 ))
    while (( $(date +%s) < ready_deadline )); do
        if ! kill -0 "$KTRACE_PID" 2>/dev/null; then
            echo "错误: ktrace 提前退出" >&2
            wait "$KTRACE_PID" || true
            return 1
        fi
        if [[ -f "${dir}/capture.ready" ]]; then
            echo "[ktrace] ready (pid=${KTRACE_PID})"
            return 0
        fi
        sleep 0.1
    done
    kill -TERM "$KTRACE_PID" 2>/dev/null || true
    echo "错误: 等待 ktrace ready 超时" >&2
    return 1
}

stop_ktrace() {
    if [[ -z "${KTRACE_PID:-}" ]]; then
        return 0
    fi
    if kill -0 "$KTRACE_PID" 2>/dev/null; then
        echo "[ktrace] 停止（导出 function_graph / summary[/tree]）..."
        kill -TERM "$KTRACE_PID" 2>/dev/null || true
        local w=0
        while kill -0 "$KTRACE_PID" 2>/dev/null && (( w < 120 )); do
            sleep 1
            w=$((w + 1))
        done
        if kill -0 "$KTRACE_PID" 2>/dev/null; then
            echo "[ktrace] 警告: 超时，强制结束" >&2
            kill -KILL "$KTRACE_PID" 2>/dev/null || true
        fi
        wait "$KTRACE_PID" 2>/dev/null || true
    fi
    KTRACE_PID=""
}

stop_all_capture() {
    stop_perf
    stop_ktrace
}

PERF_PID=""
KTRACE_PID=""
trap 'stop_all_capture' EXIT

cleanup

BASE_OUT=""
if [[ "$PERF" -eq 1 || "$KTRACE" -eq 1 ]]; then
    if [[ -z "$OUT_DIR" ]]; then
        BASE_OUT="results/ipvlan_host_netlink_add/$(date +%Y%m%d%H%M%S)"
    else
        BASE_OUT=$OUT_DIR
    fi
    mkdir -p "$BASE_OUT"
fi

if [[ "$PERF" -eq 1 ]]; then
    start_perf "${BASE_OUT}/perf"
fi
if [[ "$KTRACE" -eq 1 ]]; then
    start_ktrace "${BASE_OUT}/ktrace"
fi

ok=0
fail=0
echo "开始测试 (N=${N}, master=${MASTER}${CPUS:+, cpus=${CPUS}})"
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

if [[ -n "$CPUS" ]] && command -v taskset &>/dev/null; then
    echo "[bench] taskset -c ${CPUS}"
    _r=$(mktemp)
    taskset -c "$CPUS" bash -c '
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

stop_all_capture
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

if [[ -n "$BASE_OUT" ]]; then
    echo "output → ${BASE_OUT}"
    if [[ "$PERF" -eq 1 && -d "${BASE_OUT}/perf" ]]; then
        shopt -s nullglob
        svgs=("${BASE_OUT}/perf"/*.svg)
        shopt -u nullglob
        if (( ${#svgs[@]} > 0 )); then
            printf '  perf: %s\n' "${svgs[@]}"
        else
            echo "  perf: (无 SVG)"
        fi
    fi
    if [[ "$KTRACE" -eq 1 && -f "${BASE_OUT}/ktrace/summary.txt" ]]; then
        echo "  ktrace summary:"
        sed 's/^/    /' "${BASE_OUT}/ktrace/summary.txt"
    fi
    if [[ "$KTRACE" -eq 1 && -f "${BASE_OUT}/ktrace/summary_tree.txt" ]]; then
        echo "  ktrace summary_tree:"
        sed 's/^/    /' "${BASE_OUT}/ktrace/summary_tree.txt"
    fi
fi

[[ "$ok" -gt 0 ]]
