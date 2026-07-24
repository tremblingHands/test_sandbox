#!/usr/bin/env bash
# 用户态微基准：仿 __netdev_has_upper_dev 的 upper 链表 DFS。
#
# 用法:
#   sudo $0 --cpus 128 --n 450 --iters 20000
#   sudo $0 --cpus 128 --n 1,10,100,450,900 --iters 20000
#   sudo $0 --cpus 0 --n 450 --no-membind
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SRC="${SCRIPT_DIR}/netdev_has_upper_bench.c"
OUT_BIN="${TMPDIR:-/tmp}/netdev_has_upper_bench.$$"

CPUS=""
NO_MEMBIND=0
N_LIST="450"
ITERS=10000
WARMUP=100
FIND="miss"
CC="${CC:-cc}"

usage() {
    cat <<EOF
用法: $0 [选项]

选项:
  --n LIST         upper 个数，逗号分隔可扫参（默认: ${N_LIST}）
  --iters N        每个 n 的 walk 次数（默认: ${ITERS}）
  --warmup N       预热次数（默认: ${WARMUP}）
  --find miss|last 查不存在或命中最后一个（默认: ${FIND}）
  --cpus CPUS      绑核；默认同时 membind 到同 NUMA node
  --no-membind     仅绑核，不绑内存
  -h, --help

示例:
  sudo \$0 --cpus 128 --n 1,10,100,450,900 --iters 20000
  sudo \$0 --cpus 0 --n 450 --iters 20000
EOF
}

expand_cpus_list() {
    local spec=$1
    local part a b i
    IFS=',' read -ra parts <<<"$spec"
    for part in "${parts[@]}"; do
        part=${part// /}
        [[ -z "$part" ]] && continue
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            a=${BASH_REMATCH[1]}
            b=${BASH_REMATCH[2]}
            (( a <= b )) || { echo "错误: 无效 CPU 范围: $part" >&2; return 1; }
            for ((i = a; i <= b; i++)); do
                echo "$i"
            done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            echo "$part"
        else
            echo "错误: 无效 CPU 描述: $part" >&2
            return 1
        fi
    done
}

cpu_to_numa_node() {
    local cpu=$1
    local link node
    # shellcheck disable=SC2086
    link=$(echo /sys/devices/system/cpu/cpu"${cpu}"/node[0-9]* 2>/dev/null | awk '{print $1}')
    if [[ -z "$link" || ! -e "$link" ]]; then
        echo "错误: 无法解析 CPU ${cpu} 的 NUMA node" >&2
        return 1
    fi
    node=$(basename "$(readlink -f "$link")")
    node=${node#node}
    [[ "$node" =~ ^[0-9]+$ ]] || { echo "错误: 无效 NUMA node: $node" >&2; return 1; }
    echo "$node"
}

cpus_to_numa_nodes() {
    local spec=$1
    local cpu node
    local -A seen=()
    local -a nodes=()
    while read -r cpu; do
        [[ -z "$cpu" ]] && continue
        node=$(cpu_to_numa_node "$cpu") || return 1
        if [[ -z "${seen[$node]:-}" ]]; then
            seen[$node]=1
            nodes+=("$node")
        fi
    done < <(expand_cpus_list "$spec")
    (( ${#nodes[@]} > 0 )) || { echo "错误: --cpus 未解析出任何 CPU" >&2; return 1; }
    local IFS=,
    echo "${nodes[*]}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --n)           N_LIST=$2; shift 2 ;;
        --iters)       ITERS=$2; shift 2 ;;
        --warmup)      WARMUP=$2; shift 2 ;;
        --find)        FIND=$2; shift 2 ;;
        --cpus)        CPUS=$2; shift 2 ;;
        --no-membind)  NO_MEMBIND=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        --*)
            echo "错误: 未知参数: $1" >&2
            usage >&2
            exit 2
            ;;
        *)
            echo "错误: 多余参数: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$FIND" != "miss" && "$FIND" != "last" ]]; then
    echo "错误: --find 须为 miss 或 last" >&2
    exit 2
fi

if [[ ! -f "$SRC" ]]; then
    echo "错误: 未找到 $SRC" >&2
    exit 1
fi

echo "[build] ${CC} -O2 -o ${OUT_BIN} ${SRC}"
"${CC}" -O2 -Wall -Wextra -o "$OUT_BIN" "$SRC"
trap 'rm -f "$OUT_BIN"' EXIT

run_one() {
    local n=$1
    local -a cmd=("$OUT_BIN" --n "$n" --iters "$ITERS" --warmup "$WARMUP" --find "$FIND")
    local mem_nodes=""

    if [[ -n "$CPUS" ]]; then
        if [[ "$NO_MEMBIND" -eq 0 ]]; then
            command -v numactl &>/dev/null || {
                echo "错误: 需要 numactl（或加 --no-membind）" >&2
                exit 2
            }
            mem_nodes=$(cpus_to_numa_nodes "$CPUS") || exit 2
            echo "---- n=${n} cpus=${CPUS} membind=${mem_nodes} find=${FIND} ----"
            numactl --physcpubind="$CPUS" --membind="$mem_nodes" "${cmd[@]}"
        elif command -v numactl &>/dev/null; then
            echo "---- n=${n} cpus=${CPUS} membind=off find=${FIND} ----"
            numactl --physcpubind="$CPUS" "${cmd[@]}"
        elif command -v taskset &>/dev/null; then
            echo "---- n=${n} cpus=${CPUS} membind=off find=${FIND} ----"
            taskset -c "$CPUS" "${cmd[@]}"
        else
            echo "错误: 需要 numactl 或 taskset" >&2
            exit 2
        fi
    else
        echo "---- n=${n} find=${FIND} ----"
        "${cmd[@]}"
    fi
}

IFS=',' read -ra NS <<<"$N_LIST"
for n in "${NS[@]}"; do
    n=${n// /}
    [[ -z "$n" ]] && continue
    [[ "$n" =~ ^[0-9]+$ ]] || { echo "错误: 无效 --n: $n" >&2; exit 2; }
    run_one "$n"
done
