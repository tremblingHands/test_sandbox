#!/bin/bash
# -*- coding: utf-8 -*-
#
# host-local IPAM 目录预填 / 清空，用于量化 GetByID filepath.Walk 成本。
#
# 用法:
#   ./scripts/hostlocal_prefill.sh status
#   ./scripts/hostlocal_prefill.sh clear
#   ./scripts/hostlocal_prefill.sh prefill 5000
#   ./scripts/hostlocal_prefill.sh prefill 5000 --start 10.0.0.2
#
# 说明:
#   - 数据目录默认 /var/lib/cni/networks/mynet（与 setup.sh bridge 一致）
#   - 预填文件名=IP，内容为假 ID；并写 last_reserved_ip.0 到「最后一个预填 IP」
#     使后续真实分配从下一位开始，减少 O_EXCL 撞车，突出 Walk 成本
#   - 操作前请确保无 single-bench / 业务沙箱占用；clear 会删掉全部占位
#
set -euo pipefail

DATA_DIR="${HOSTLOCAL_DATA_DIR:-/var/lib/cni/networks/mynet}"
DEFAULT_START="10.0.0.2"

usage() {
    cat <<EOF
用法: $0 <status|clear|prefill N> [--start A.B.C.D] [--dir PATH]

  status              显示目录文件数与游标
  clear               清空 $DATA_DIR（需无在用沙箱）
  prefill N           预填 N 个 IP 占位文件（默认从 $DEFAULT_START 起）

环境变量:
  HOSTLOCAL_DATA_DIR  覆盖数据目录（默认 $DATA_DIR）

示例（Walk 对照）:
  # A: 空目录
  $0 clear
  bash scripts/multi_single_cold_start.sh 128-255 128 1 --profile -- \\
    -- --duration 60 --cpuset-cpus 0-255 --cpuset-mems 0-1 --preconfig 50

  # B: 预填 5000 后再压
  $0 clear && $0 prefill 5000
  bash scripts/multi_single_cold_start.sh 128-255 128 1 --profile -- \\
    -- --duration 60 --cpuset-cpus 0-255 --cpuset-mems 0-1 --preconfig 50
EOF
}

ip_to_int() {
    local ip="$1"
    local a b c d
    IFS=. read -r a b c d <<<"$ip"
    echo $(( (a << 24) + (b << 16) + (c << 8) + d ))
}

int_to_ip() {
    local n="$1"
    echo "$(( (n >> 24) & 255 )).$(( (n >> 16) & 255 )).$(( (n >> 8) & 255 )).$(( n & 255 ))"
}

count_entries() {
    if [ ! -d "$DATA_DIR" ]; then
        echo 0
        return
    fi
    # 不含目录本身
    find "$DATA_DIR" -mindepth 1 -maxdepth 1 | wc -l
}

warn_if_sandboxes() {
    if ! command -v crictl &>/dev/null; then
        return 0
    fi
    local n
    n=$(crictl pods -q 2>/dev/null | wc -l || echo 0)
    if [ "${n:-0}" -gt 0 ] 2>/dev/null; then
        echo "警告: crictl 仍有 ${n} 个 Pod/沙箱；建议先清理再 clear/prefill，避免与真实占位冲突。" >&2
    fi
}

cmd_status() {
    echo "数据目录: $DATA_DIR"
    if [ ! -d "$DATA_DIR" ]; then
        echo "状态:     目录不存在"
        return 0
    fi
    local total ip_files
    total=$(count_entries)
    ip_files=$(find "$DATA_DIR" -mindepth 1 -maxdepth 1 -type f ! -name 'lock' ! -name 'last_reserved_ip.*' 2>/dev/null | wc -l)
    echo "条目数:   $total（其中 IP 占位约 $ip_files）"
    if [ -f "$DATA_DIR/last_reserved_ip.0" ]; then
        echo "游标:     last_reserved_ip.0 = $(cat "$DATA_DIR/last_reserved_ip.0")"
    else
        echo "游标:     (无 last_reserved_ip.0)"
    fi
    if [ -e "$DATA_DIR/lock" ]; then
        echo "锁文件:   存在"
    fi
}

cmd_clear() {
    warn_if_sandboxes
    if [ ! -d "$DATA_DIR" ]; then
        echo "目录不存在，无需清空: $DATA_DIR"
        return 0
    fi
    echo "清空: $DATA_DIR"
    sudo rm -rf "$DATA_DIR"
    echo "完成。下次 CNI ADD 会重建目录。"
}

cmd_prefill() {
    local n="$1"
    local start_ip="$2"

    if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -le 0 ]; then
        echo "错误: N 必须是正整数，当前=$n" >&2
        exit 1
    fi

    warn_if_sandboxes

    local start_int end_ip
    start_int=$(ip_to_int "$start_ip")
    # 跳过网关习惯上的 .0/.1：若 start 为 x.x.x.0 则从 .2 起
    if [ $(( start_int & 255 )) -eq 0 ]; then
        start_int=$((start_int + 2))
        start_ip=$(int_to_ip "$start_int")
        echo "提示: start 对齐到 $start_ip（跳过 .0/.1）"
    elif [ $(( start_int & 255 )) -eq 1 ]; then
        start_int=$((start_int + 1))
        start_ip=$(int_to_ip "$start_int")
        echo "提示: start 对齐到 $start_ip（跳过网关 .1）"
    fi

    end_ip=$(int_to_ip $((start_int + n - 1)))

    echo "预填: dir=$DATA_DIR count=$n range=$start_ip .. $end_ip"
    sudo mkdir -p "$DATA_DIR"

    # 用 python 批量写，避免 bash 循环过慢
    sudo python3 - "$DATA_DIR" "$start_int" "$n" <<'PY'
import os, sys
data_dir, start, n = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
for i in range(n):
    ip_int = start + i
    ip = "{}.{}.{}.{}".format(
        (ip_int >> 24) & 255,
        (ip_int >> 16) & 255,
        (ip_int >> 8) & 255,
        ip_int & 255,
    )
    path = os.path.join(data_dir, ip)
    # 内容格式贴近 host-local：id + ifname
    with open(path, "w") as f:
        f.write("prefill-%d\neth0\n" % i)
# 游标指到最后一个预填 IP，真实分配从下一地址开始
last = start + n - 1
last_ip = "{}.{}.{}.{}".format(
    (last >> 24) & 255,
    (last >> 16) & 255,
    (last >> 8) & 255,
    last & 255,
)
with open(os.path.join(data_dir, "last_reserved_ip.0"), "w") as f:
    f.write(last_ip)
# 确保 lock 文件存在（host-local NewFileLock 会用到）
lock = os.path.join(data_dir, "lock")
if not os.path.exists(lock):
    open(lock, "a").close()
print("wrote", n, "files; last_reserved_ip.0 =", last_ip)
PY

    cmd_status
    echo ""
    echo "可开始压测（建议结果目录名带 hostlocal-files-${n} 后缀）。"
}

# ---- 参数解析 ----
if [ $# -lt 1 ]; then
    usage
    exit 1
fi

CMD="$1"
shift

START_IP="$DEFAULT_START"
N=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --start)
            START_IP="$2"; shift 2 ;;
        --dir)
            DATA_DIR="$2"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            if [ -z "$N" ] && [[ "$1" =~ ^[0-9]+$ ]]; then
                N="$1"; shift
            else
                echo "错误: 未知参数: $1" >&2
                usage
                exit 1
            fi
            ;;
    esac
done

case "$CMD" in
    status)
        cmd_status
        ;;
    clear)
        cmd_clear
        ;;
    prefill)
        if [ -z "$N" ]; then
            echo "错误: prefill 需要 N，例如: $0 prefill 5000" >&2
            exit 1
        fi
        cmd_prefill "$N" "$START_IP"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo "错误: 未知命令: $CMD" >&2
        usage
        exit 1
        ;;
esac
