#!/bin/bash
# -*- coding: utf-8 -*-
#
# 多进程 Pod 沙箱冷启动测试启动器
#
# 用法:
#     ./multi_single_cold_start.sh <M>-<N> <K> <NUMA> [--profile] [-- <single_cold_start.py 的额外参数>]
#
# 参数:
#     M-N    CPU 范围，如 0-7。进程将从 M 开始依次绑定到核心。
#     K      启动的进程数量。
#     NUMA   NUMA 节点号，所有进程统一用 numactl --membind=<NUMA> 绑定内存。
#     --profile    通过 containerd trace 日志统计各阶段时延（P50/P95/P99/Mean）
#
#     额外参数通过 -- 分隔后透传给 single_cold_start.py。
#
# 示例:
#     ./multi_single_cold_start.sh 0-7 4 0 -- --duration 60
#     ./multi_single_cold_start.sh 4-11 8 1 -- --duration 30 --cleanup
#     ./multi_single_cold_start.sh 0-7 4 0 --profile -- --duration 60
#
# 前置条件:
#     - numactl 已安装
#     - scripts/single_cold_start.py 可用
#     - scripts/setup.sh 已执行
#

set -euo pipefail

# ============================================================
# 参数解析
# ============================================================
if [ $# -lt 3 ]; then
    echo "用法: $0 <M>-<N> <K> <NUMA> [--profile] [-- <single_cold_start.py 的额外参数>]"
    echo ""
    echo "  M-N    CPU 范围，进程将依次绑定到 M, M+1, ..."
    echo "  K      启动的进程数量"
    echo "  NUMA   NUMA 节点号，所有进程内存统一绑定"
    echo ""
    echo "示例:"
    echo "  $0 0-7 4 0 -- --duration 60 --cleanup"
    exit 1
fi

CPU_RANGE="$1"
PROC_COUNT="$2"
NUMA_NODE="$3"
shift 3

# 解析 --profile 和 -- 后的透传参数
PROFILE=false
PASSTHRU_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            PROFILE=true; shift ;;
        --)
            shift; PASSTHRU_ARGS=("$@"); break ;;
        *)
            echo "错误: 未知参数: $1"
            echo "用法: $0 <M>-<N> <K> <NUMA> [--profile] [-- <single_cold_start.py 的额外参数>]"
            exit 1 ;;
    esac
done

# 解析 CPU 范围 M-N
IFS='-' read -r CPU_START CPU_END <<< "$CPU_RANGE"
if [ -z "${CPU_START:-}" ] || [ -z "${CPU_END:-}" ]; then
    echo "错误: CPU 范围格式不正确，应为 M-N (如 0-7)"
    exit 1
fi
if [ "$CPU_START" -gt "$CPU_END" ]; then
    echo "错误: CPU 范围 $CPU_START > $CPU_END"
    exit 1
fi

# 可用 CPU 数
AVAILABLE_CPUS=$((CPU_END - CPU_START + 1))
if [ "$PROC_COUNT" -le 0 ]; then
    echo "错误: 进程数必须为正整数，当前为 $PROC_COUNT"
    exit 1
fi

# 验证 numactl 可用
if ! command -v numactl &>/dev/null; then
    echo "错误: 未找到 numactl，请先安装"
    exit 1
fi

# 定位 single_cold_start.py
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SINGLE_PY="${SCRIPT_DIR}/single_cold_start.py"
if [ ! -f "$SINGLE_PY" ]; then
    echo "错误: 未找到 $SINGLE_PY"
    exit 1
fi

# 结果目录（运行前清理旧结果）
RESULT_DIR="results/multi"
rm -rf "$RESULT_DIR"
mkdir -p "$RESULT_DIR"

# ============================================================
# 输出配置
# ============================================================
CPU_COUNT=$AVAILABLE_CPUS
CPU_END_IDX=$((CPU_START + PROC_COUNT - 1))

echo ""
echo "=================================================="
echo "多进程 Pod 沙箱冷启动测试"
echo "=================================================="
echo "CPU 范围:  $CPU_RANGE  (共 $CPU_COUNT 个核心)"
echo "NUMA 节点: $NUMA_NODE"
echo "进程数:    $PROC_COUNT"
if [ "$PROC_COUNT" -gt "$CPU_COUNT" ]; then
    echo "绑定策略: 轮转 (超出后回到 $CPU_START)"
fi
echo "结果目录:  $RESULT_DIR"
echo "透传参数:  ${PASSTHRU_ARGS[*]:-(无)}"
if $PROFILE; then
    echo "Profile:   已开启 (containerd trace 各阶段时延汇总)"
fi
echo "=================================================="
echo ""

# ============================================================
# 全局清缓存（由启动器统一完成一次）
# ============================================================
echo "[pre] 清缓存..."
sudo sh -c 'echo 3 > /proc/sys/vm/drop_caches' || true
sleep 2
echo "[pre] 清缓存完成"
echo ""

# ============================================================
# Profile: 记录测试窗口起止时间（journalctl --since/--until 使用）
# ============================================================
if $PROFILE; then
    PROFILE_START=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[profile] 测试窗口起始: $PROFILE_START"
    echo ""
fi

# ============================================================
# 启动进程（每个 single_cold_start.py 不再自行清缓存和清理）
# ============================================================
PIDS=()
PROC=0
while [ "$PROC" -lt "$PROC_COUNT" ]; do
    BIND_CPU=$((CPU_START + (PROC % CPU_COUNT)))
    OUTPUT_FILE="${RESULT_DIR}/proc${PROC}_cpu${BIND_CPU}_node${NUMA_NODE}.json"

    echo "[proc $PROC] 启动: numactl --physcpubind=$BIND_CPU --membind=$NUMA_NODE"

    numactl --physcpubind="$BIND_CPU" --membind="$NUMA_NODE" \
        python3 "$SINGLE_PY" \
            --output "$OUTPUT_FILE" \
            --worker-id "$PROC" \
            --no-clear-caches \
            --no-batch-cleanup \
            "${PASSTHRU_ARGS[@]}" \
        > "${RESULT_DIR}/proc${PROC}_stdout.log" 2>&1 &

    PIDS+=($!)
    PROC=$((PROC + 1))
done

echo ""
echo "已启动 ${#PIDS[@]} 个进程, PID: ${PIDS[*]}"
echo ""

# ============================================================
# 等待所有进程退出
# ============================================================
FAILED=0
for pid in "${PIDS[@]}"; do
    if wait "$pid"; then
        echo "[pid $pid] 退出: 成功"
    else
        echo "[pid $pid] 退出: 失败 (exit=$?)"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
echo "=================================================="
if [ "$FAILED" -eq 0 ]; then
    echo "全部 ${#PIDS[@]} 个进程正常退出"
else
    echo "完成: 成功 $(( ${#PIDS[@]} - FAILED ))/${#PIDS[@]}, 失败 $FAILED"
fi
echo "结果: $RESULT_DIR/"
echo "=================================================="

# ============================================================
# Profile: containerd trace 分析（所有 worker 的所有 sandbox 汇总）
# ============================================================
if $PROFILE; then
    PROFILE_END=$(date '+%Y-%m-%d %H:%M:%S')
    PROFILE_LOG="/tmp/multi-profile-$$.log"

    echo ""
    echo "[profile] 采集窗口: $PROFILE_START → $PROFILE_END"
    echo "[profile] 正在查询 containerd 日志..."

    journalctl -u containerd \
        --since="$PROFILE_START" \
        --until="$PROFILE_END" \
        -o cat --no-pager \
        > "$PROFILE_LOG" 2>/dev/null || true

    log_size=$(wc -c < "$PROFILE_LOG" 2>/dev/null || echo 0)
    echo "[profile] 日志大小: ${log_size} bytes"

    if [ "$log_size" -gt 0 ]; then
        echo ""
        python3 "${SCRIPT_DIR}/trace_analyzer.py" "$PROFILE_LOG" --summary-tree || \
            echo "[profile] ⚠ 未在日志中找到 trace span（containerd 可能未配置 TRACE 级别日志）"
    else
        echo "[profile] ⚠ containerd 日志为空（可能未开启 TRACE 级别日志）"
    fi

    rm -f "$PROFILE_LOG"
fi

# ============================================================
# 汇总
# ============================================================
echo ""
echo "--- 各进程摘要 ---"
printf "%-20s %10s %10s %10s %10s %10s %10s\n" \
    "PROC" "sandboxes" "成功" "P50(ms)" "P95(ms)" "P99(ms)" "Mean(ms)"
for f in "$RESULT_DIR"/proc*_cpu*_node*.json; do
    [ -f "$f" ] || continue
    label="$(basename "$f" .json)"
    read -r total success p50 p95 p99 mean <<< \
        $(python3 -c "
import json
d = json.load(open('$f'))
t = d['phases']['total']
print(d['summary']['total_sandboxes'],
      d['summary']['success'],
      round(t['p50'], 1),
      round(t['p95'], 1),
      round(t['p99'], 1),
      round(t['mean'], 1))
")
    printf "%-20s %10s %10s %10s %10s %10s %10s\n" \
        "$label" "$total" "$success" "$p50" "$p95" "$p99" "$mean"
done

# 汇总所有 CPU
echo ""
echo "--- 总计 ---"
python3 -c "
import json, glob, statistics

all_results = []
total_sandboxes = 0
total_success = 0
duration = None

for f in sorted(glob.glob('$RESULT_DIR/proc*_cpu*_node*.json')):
    d = json.load(open(f))
    total_sandboxes += d['summary']['total_sandboxes']
    total_success += d['summary']['success']
    if duration is None:
        duration = d['config']['duration']
    for r in d['results']:
        all_results.append(r['total_ms'])

if all_results:
    s = sorted(all_results)
    n = len(s)
    p50 = s[int(n * 0.50) - 1] if n >= 1 else 0
    p95 = s[int(n * 0.95) - 1] if n >= 1 else 0
    p99 = s[int(n * 0.99) - 1] if n >= 1 else 0
    mean = statistics.mean(s)
    tps = total_sandboxes / duration if duration else 0
    print('{:<16} {:>10} {:>10} {:>10.1f} {:>10.1f} {:>10.1f} {:>10.1f}  {:>8.1f}/s'.format(
        'ALL', total_sandboxes, total_success, p50, p95, p99, mean, tps))
else:
    print('(无数据)')
"

# ============================================================
# 最终批量清理（由启动器统一完成）
# ============================================================
echo ""
echo "[post] 清理所有残留 pod..."
crictl rmp -a -f >/dev/null 2>&1 || crictl rmp --all --force >/dev/null 2>&1 || true
echo "[post] 清理完成"
