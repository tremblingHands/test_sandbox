#!/usr/bin/env bash
# 宿主机创建 N 个 ipvlan（link add + addr add + up）耗时
# 用法: sudo $0 [个数N] [master]
# 例:   sudo $0 100 eth0
set -euo pipefail

N=${1:-100}
MASTER=${2:-$(ip route show default 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')}
MASTER=${MASTER:-eth0}

if ! [[ "$N" =~ ^[1-9][0-9]*$ ]]; then
    echo "错误: N 须为正整数" >&2
    exit 2
fi

cleanup() {
    ip -o link 2>/dev/null | awk -F': ' '$2 ~ /^ivlb/ {print $2}' |
        while read -r n; do ip link del "${n%%@*}" 2>/dev/null || true; done
}

cleanup
ok=0
fail=0
echo "开始测试"
start=$(date +%s%N)
for ((i = 1; i <= N; i++)); do
    name=$(printf 'ivlb%08x' "$i")
    addr=$(printf '10.88.%d.%d/16' $((i / 256)) $((i % 256)))
    if ip link add link "$MASTER" name "$name" type ipvlan mode l3 2>/dev/null &&
       ip addr add "$addr" dev "$name" 2>/dev/null &&
       ip link set "$name" up 2>/dev/null; then
        ok=$((ok + 1))
    else
        ip link del "$name" 2>/dev/null || true
        fail=$((fail + 1))
    fi
done
end=$(date +%s%N)
echo "测试结束，开始清理"
cleanup

awk -v ok="$ok" -v fail="$fail" -v a="$start" -v b="$end" 'BEGIN{
  sec = (b - a) / 1e9
  printf "n=%d ok=%d fail=%d time=%.4fs", ok+fail, ok, fail, sec
  if (ok > 0 && sec > 0) printf " (%.2f ADD/s)", ok/sec
  printf "\n"
}'

[[ "$ok" -gt 0 ]]
