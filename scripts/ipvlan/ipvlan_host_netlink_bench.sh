#!/usr/bin/env bash
# -*- coding: utf-8 -*-
#
# 宿主机直建 ipvlan（无 netns）微基准，对齐:
#   python3 scripts/ipvlan/ipvlan_l3_bench.py -c N --duration T --no-netns --mode netlink
#
# 每轮:
#   ip link add link <master> name ivlbXXXXXXXX type ipvlan mode l3
#   ip addr add <ip>/<prefix> dev ivlb…
#   ip link set ivlb… up
#   （不配默认路由；结束后统一 delete）
#
# 用法:
#   sudo ./scripts/ipvlan/ipvlan_host_netlink_bench.sh
#   sudo ./scripts/ipvlan/ipvlan_host_netlink_bench.sh -c 1 --duration 10
#   sudo ./scripts/ipvlan/ipvlan_host_netlink_bench.sh -c 4 --duration 30 --master eth0
#
set -euo pipefail

CONCURRENCY=1
DURATION=10
MASTER=""
SUBNET="10.88.0.0/16"
IF_PREFIX="ivlb"
OUT_DIR=""

usage() {
    cat <<EOF
用法: $0 [选项]

选项:
  -c, --concurrency N   并发 worker 数（默认: ${CONCURRENCY}）
  --duration SEC        压测秒数（默认: ${DURATION}）
  --master DEV          ipvlan master（默认: 自动探测 default route 的 dev）
  --subnet CIDR         地址网段（默认: ${SUBNET}）
  --output DIR          结果目录（默认: results/ipvlan_host_netlink/<ts>）
  -h, --help            帮助

示例:
  sudo $0 -c 1 --duration 10
  sudo $0 -c 4 --duration 30 --master eth0
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--concurrency) CONCURRENCY="$2"; shift 2 ;;
        --duration)       DURATION="$2"; shift 2 ;;
        --master)         MASTER="$2"; shift 2 ;;
        --subnet)         SUBNET="$2"; shift 2 ;;
        --output)         OUT_DIR="$2"; shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *)
            echo "错误: 未知参数: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

if [[ "$(id -u)" -ne 0 ]]; then
    echo "警告: 通常需要 root（ip link / addr）" >&2
fi

if ! [[ "$CONCURRENCY" =~ ^[1-9][0-9]*$ ]]; then
    echo "错误: --concurrency 须为正整数" >&2
    exit 2
fi
if ! awk -v d="$DURATION" 'BEGIN{exit !(d+0 > 0)}'; then
    echo "错误: --duration 须 > 0" >&2
    exit 2
fi

detect_master() {
    local line dev
    line=$(ip -o route show default 2>/dev/null | head -1 || true)
    # shellcheck disable=SC2206
    set -- $line
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "dev" && -n "${2:-}" ]]; then
            echo "$2"
            return
        fi
        shift
    done
    echo "eth0"
}

if [[ -z "$MASTER" ]]; then
    MASTER=$(detect_master)
fi
if ! ip link show "$MASTER" &>/dev/null; then
    echo "错误: master 网卡不存在: $MASTER" >&2
    exit 1
fi

# 解析 subnet → 网络地址 / 前缀 / 起始 host 序号（跳过 .0，从 .1 的下一可用开始用 .2 风格）
parse_subnet() {
    local cidr="$1"
    local net prefix
    net="${cidr%/*}"
    prefix="${cidr#*/}"
    if [[ -z "$net" || -z "$prefix" || "$net" == "$cidr" ]]; then
        echo "错误: 无效 subnet: $cidr" >&2
        exit 2
    fi
    SUBNET_PREFIX="$prefix"
    # 仅支持 IPv4 a.b.c.d/prefix；把前三/四段拆开做简单递增（/16 用第三、四段）
    IFS=. read -r o1 o2 o3 o4 <<<"$net"
    BASE_O1=$o1
    BASE_O2=$o2
    BASE_O3=$o3
    BASE_O4=$o4
}

parse_subnet "$SUBNET"

# IP 池：从网络地址 + 2 起递增（避开网络地址与常见 .1 gateway）
# 序号 seq(从 1) → host_offset = seq+1
ip_from_seq() {
    local seq=$1
    local offset=$((seq + 1))
    local o4 o3 o2 o1 carry
    o4=$((BASE_O4 + offset))
    o3=$BASE_O3
    o2=$BASE_O2
    o1=$BASE_O1
    carry=0
    if (( o4 > 255 )); then
        carry=$((o4 / 256))
        o4=$((o4 % 256))
        o3=$((o3 + carry))
    fi
    if (( o3 > 255 )); then
        carry=$((o3 / 256))
        o3=$((o3 % 256))
        o2=$((o2 + carry))
    fi
    if (( o2 > 255 )); then
        carry=$((o2 / 256))
        o2=$((o2 % 256))
        o1=$((o1 + carry))
    fi
    if (( o1 > 255 )); then
        echo "错误: subnet 地址耗尽 (seq=$seq)" >&2
        return 1
    fi
    echo "${o1}.${o2}.${o3}.${o4}/${SUBNET_PREFIX}"
}

ifname_from_seq() {
    printf '%s%08x' "$IF_PREFIX" "$(( $1 & 0xffffffff ))"
}

cleanup_ifaces() {
    local name
    while read -r name; do
        [[ -z "$name" ]] && continue
        name="${name%%@*}"
        ip link delete "$name" 2>/dev/null || true
    done < <(ip -o link show 2>/dev/null | awk -F': ' -v p="$IF_PREFIX" '$2 ~ "^"p {print $2}')
}

now_ns() {
    date +%s%N
}

percentile() {
    # stdin: one float ms per line; args: p in (0,1]
    local p="$1"
    local -a arr=()
    local n idx
    mapfile -t arr
    n=${#arr[@]}
    if (( n == 0 )); then
        echo "0"
        return
    fi
    IFS=$'\n' arr=($(printf '%s\n' "${arr[@]}" | sort -n))
    idx=$(awk -v n="$n" -v p="$p" 'BEGIN{i=int(n*p)-1; if(i<0)i=0; if(i>=n)i=n-1; print i}')
    echo "${arr[$idx]}"
}

mean_of() {
    awk '{s+=$1; n++} END{if(n) printf "%.4f", s/n; else print 0}'
}

if [[ -z "$OUT_DIR" ]]; then
    OUT_DIR="results/ipvlan_host_netlink/$(date +%Y%m%d%H%M%S)"
fi
mkdir -p "$OUT_DIR"
LATENCY_DIR=$(mktemp -d /tmp/ipvlan-host-bench.XXXXXX)
STOP_FILE="${LATENCY_DIR}/stop"
OK_FILE="${LATENCY_DIR}/ok"
FAIL_FILE="${LATENCY_DIR}/fail"
: >"$OK_FILE"
: >"$FAIL_FILE"

echo "=============================================="
echo "  ipvlan host netlink benchmark"
echo "=============================================="
echo "  concurrency: ${CONCURRENCY}"
echo "  duration:    ${DURATION}s"
echo "  master:      ${MASTER}"
echo "  subnet:      ${SUBNET}"
echo "  output:      ${OUT_DIR}"
echo "=============================================="

cleanup_ifaces

echo "[bench] 开始（duration=${DURATION}s, concurrency=${CONCURRENCY}）"

SEQ_FILE="${LATENCY_DIR}/seq"
echo 0 >"$SEQ_FILE"

worker() {
    local wid="$1"
    local lat_file="${LATENCY_DIR}/lat.${wid}"
    : >"$lat_file"
    local seq ifname addr t0 t1 ms rc
    while [[ ! -f "$STOP_FILE" ]]; do
        seq=$(flock "$SEQ_FILE" bash -c 'n=$(cat "'"$SEQ_FILE"'"); n=$((n+1)); echo "$n" >"'"$SEQ_FILE"'"; echo "$n"')
        ifname=$(ifname_from_seq "$seq")
        if ! addr=$(ip_from_seq "$seq"); then
            echo 1 >>"$FAIL_FILE"
            continue
        fi
        t0=$(now_ns)
        rc=0
        if ! ip link add link "$MASTER" name "$ifname" type ipvlan mode l3 2>/dev/null; then
            rc=1
        elif ! ip addr add "$addr" dev "$ifname" 2>/dev/null; then
            ip link delete "$ifname" 2>/dev/null || true
            rc=1
        elif ! ip link set "$ifname" up 2>/dev/null; then
            ip link delete "$ifname" 2>/dev/null || true
            rc=1
        fi
        t1=$(now_ns)
        if [[ "$rc" -eq 0 ]]; then
            ms=$(awk -v a="$t0" -v b="$t1" 'BEGIN{printf "%.4f", (b-a)/1e6}')
            echo "$ms" >>"$lat_file"
            echo 1 >>"$OK_FILE"
        else
            echo 1 >>"$FAIL_FILE"
        fi
    done
}

WALL0=$(now_ns)
for ((i = 0; i < CONCURRENCY; i++)); do
    worker "$i" &
done
WORKER_PIDS=($(jobs -p))

# 定时结束
sleep "$DURATION"
touch "$STOP_FILE"
wait "${WORKER_PIDS[@]}" 2>/dev/null || true
WALL1=$(now_ns)
WALL_S=$(awk -v a="$WALL0" -v b="$WALL1" 'BEGIN{printf "%.4f", (b-a)/1e9}')

echo "[bench] 结束（wall=${WALL_S}s）"

# 合并延迟
ALL_LAT="${LATENCY_DIR}/all.lat"
cat "${LATENCY_DIR}"/lat.* 2>/dev/null >"$ALL_LAT" || : >"$ALL_LAT"
OK=$(wc -l <"$OK_FILE" | tr -d ' ')
FAIL=$(wc -l <"$FAIL_FILE" | tr -d ' ')
N_LAT=$(wc -l <"$ALL_LAT" | tr -d ' ')
TPS=$(awk -v ok="$OK" -v w="$WALL_S" 'BEGIN{if(w>0) printf "%.2f", ok/w; else print 0}')

P50=$(percentile 0.50 <"$ALL_LAT")
P95=$(percentile 0.95 <"$ALL_LAT")
P99=$(percentile 0.99 <"$ALL_LAT")
MEAN=$(mean_of <"$ALL_LAT")

echo "[post] 统一清理宿主机 ipvlan ..."
cleanup_ifaces

echo ""
echo "---- 结果 ----"
echo "  wall:       ${WALL_S}s"
echo "  ok/fail:    ${OK}/${FAIL}"
echo "  throughput: ${TPS} ADD/s"
if [[ "$N_LAT" -gt 0 ]]; then
    printf '  ipvlan ADD  n=%-6s p50=%8.2f p95=%8.2f p99=%8.2f mean=%8.2f ms\n' \
        "$N_LAT" "$P50" "$P95" "$P99" "$MEAN"
else
    echo "  ipvlan ADD: (no data)"
fi

SUMMARY="${OUT_DIR}/summary.json"
cat >"$SUMMARY" <<EOF
{
  "config": {
    "concurrency": ${CONCURRENCY},
    "duration": ${DURATION},
    "master": "${MASTER}",
    "subnet": "${SUBNET}",
    "no_netns": true,
    "mode": "netlink"
  },
  "wall_s": ${WALL_S},
  "ok": ${OK},
  "fail": ${FAIL},
  "throughput_add_per_s": ${TPS},
  "phases_ms": {
    "ipvlan_add": {
      "n": ${N_LAT},
      "p50": ${P50:-0},
      "p95": ${P95:-0},
      "p99": ${P99:-0},
      "mean": ${MEAN:-0}
    }
  }
}
EOF
echo "  summary → ${SUMMARY}"

rm -rf "$LATENCY_DIR"

if [[ "$FAIL" -gt 0 && "$OK" -eq 0 ]]; then
    exit 1
fi
exit 0
