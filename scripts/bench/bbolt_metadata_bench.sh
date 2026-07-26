#!/usr/bin/env bash
# containerd metadata 风格的 bbolt 场景微基准（并发短 Update / no_sync / Batch）
#
# 用法:
#   ./scripts/bench/bbolt_metadata_bench.sh --goroutines 128 --rounds 200 --mode sync --tx update
#   ./scripts/bench/bbolt_metadata_bench.sh --goroutines 128 --mode no_sync --tx merged
#   ./scripts/bench/bbolt_metadata_bench.sh --cpus 128 --goroutines 64 --tx batch
#
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
PKG_DIR="$SCRIPT_DIR/bbolt_metadata_bench"

CPUS=""
NO_MEMBIND=0
ARGS=()

usage() {
    cat <<EOF
用法: $0 [包装选项] [-- bench 参数...]

包装选项:
  --cpus CPUS      绑核；默认 membind 到同 NUMA
  --no-membind     仅绑核
  -h, --help

bench 参数（传给 main）:
  --goroutines N         并发 worker（默认 32）
  --rounds N             每 worker round 数（默认 200）
  --updates-per-round K  update 模式下 Update 次数（默认 3）
  --mode sync|no_sync    是否 NoSync（默认 sync）
  --tx update|merged|batch
  --db PATH              db 文件（默认临时目录）
  --key-size / --value-size / --warmup

示例:
  \$0 --goroutines 128 --rounds 100 --mode sync --tx update
  \$0 --cpus 128 --goroutines 128 --mode no_sync --tx merged
  \$0 --goroutines 128 --tx batch --mode sync
EOF
}

expand_cpus_list() {
    local spec=$1 part a b i
    IFS=',' read -ra parts <<<"$spec"
    for part in "${parts[@]}"; do
        part=${part// /}
        [[ -z "$part" ]] && continue
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            a=${BASH_REMATCH[1]}; b=${BASH_REMATCH[2]}
            for ((i = a; i <= b; i++)); do echo "$i"; done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            echo "$part"
        else
            echo "错误: 无效 CPU: $part" >&2; return 1
        fi
    done
}

cpu_to_numa_node() {
    local cpu=$1 link node
    link=$(echo /sys/devices/system/cpu/cpu"${cpu}"/node[0-9]* 2>/dev/null | awk '{print $1}')
    [[ -e "$link" ]] || { echo "错误: 无法解析 CPU $cpu 的 NUMA" >&2; return 1; }
    node=$(basename "$(readlink -f "$link")")
    echo "${node#node}"
}

cpus_to_numa_nodes() {
    local spec=$1 cpu node
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
    local IFS=,
    echo "${nodes[*]}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cpus) CPUS=$2; shift 2 ;;
        --no-membind) NO_MEMBIND=1; shift ;;
        -h|--help) usage; exit 0 ;;
        --) shift; ARGS+=("$@"); break ;;
        *) ARGS+=("$1"); shift ;;
    esac
done

cd "$PKG_DIR"
if [[ ! -f go.sum ]]; then
    echo "[build] go mod tidy"
    go mod tidy
fi

run_cmd=(go run . "${ARGS[@]}")
if [[ -n "$CPUS" ]]; then
    if [[ "$NO_MEMBIND" -eq 0 ]]; then
        command -v numactl >/dev/null || { echo "错误: 需要 numactl 或 --no-membind" >&2; exit 2; }
        mem=$(cpus_to_numa_nodes "$CPUS")
        echo "[run] numactl --physcpubind=${CPUS} --membind=${mem}"
        numactl --physcpubind="$CPUS" --membind="$mem" "${run_cmd[@]}"
    elif command -v numactl >/dev/null; then
        echo "[run] numactl --physcpubind=${CPUS}"
        numactl --physcpubind="$CPUS" "${run_cmd[@]}"
    else
        taskset -c "$CPUS" "${run_cmd[@]}"
    fi
else
    "${run_cmd[@]}"
fi
