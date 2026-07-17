#!/bin/bash
# -*- coding: utf-8 -*-
#
# 多进程 Pod 沙箱冷启动测试启动器
#
# 用法:
#     ./multi_single_cold_start.sh <CPUS> <K> <NUMA> [--profile] [--pprof [OPTS]] [--perf [OPTS]] [--perf_sandbox] [--resources [OPTS]] [-- <single_cold_start.py 的额外参数>]
#
# 参数:
#     CPUS   CPU 列表: "0-7" (连续范围) 或 "32,34,36,38" (指定核心)。
#            进程将按列表顺序依次绑定到核心。
#     K      启动的进程数量。
#     NUMA   NUMA 节点号，所有进程统一用 numactl --membind=<NUMA> 绑定内存。
#     --profile    通过 containerd trace 日志统计各阶段时延（P50/P95/P99/Mean）
#     --pprof      通过 go pprof 抓取 containerd profile（调用 containerd_pprof.sh）
#                     抓取时长默认与 single_cold_start --duration 保持一致
#         --pprof-cpu-seconds SEC     CPU profile 采样时长（默认: 与 duration 相同）
#         --pprof-series-interval SEC 瞬时 profile 抓取间隔（默认: 1）
#     --perf       通过 perf 抓取 containerd on/off CPU 火焰图（调用 containerd_perf.sh）
#     --perf_sandbox 通过 perf 抓取沙箱 on/off CPU 火焰图（CPU 由 --cpuset-cpus 决定）
#                     采样时长默认与 --duration 保持一致
#         --perf-frequency HZ        采样频率（默认: 99）
#         --perf-duration SEC        采样时长（默认: 与 duration 相同）
#         --perf-call-graph MODE     仅 on-CPU 回溯（默认: fp；Go 符号用 dwarf,65528）
#     --resources  采集系统资源时序（CPU/内存/磁盘/沙箱数/containerd/cgroup）
#         --resource-interval SEC    采样间隔（默认: 0.1）
#
#     额外参数通过 -- 分隔后透传给 single_cold_start.py。
#
# 示例:
#     ./multi_single_cold_start.sh 0-7 4 0 -- --duration 60
#     ./multi_single_cold_start.sh 4-11 8 1 -- --duration 30 --cleanup
#     ./multi_single_cold_start.sh 32,34,36,38 4 0 -- --duration 60
#     ./multi_single_cold_start.sh 0-7 4 0 --profile -- --duration 60
#     ./multi_single_cold_start.sh 0-7 4 0 --pprof -- --duration 60
#     ./multi_single_cold_start.sh 0-7 4 0 --pprof --perf -- --duration 60
#     ./multi_single_cold_start.sh 0-7 4 0 --perf --perf-call-graph dwarf,65528 -- --duration 60
#     ./multi_single_cold_start.sh 0-7 4 0 --resources -- --duration 60
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
    echo "用法: $0 <CPUS> <K> <NUMA> [--profile] [--pprof [OPTS]] [--perf [OPTS]] [--perf_sandbox] [--resources [OPTS]] [-- <single_cold_start.py 的额外参数>]"
    echo ""
    echo "  CPUS   CPU 列表: 0-7 (范围) 或 32,34,36,38 (指定核心)"
    echo "  K      启动的进程数量"
    echo "  NUMA   NUMA 节点号，所有进程内存统一绑定"
    echo "  --profile    通过 containerd trace 日志统计各阶段时延"
    echo "  --pprof      通过 go pprof 抓取 containerd profile"
    echo "  --perf       通过 perf 抓取 containerd on/off CPU 火焰图"
    echo "  --resources  采集系统资源时序 (CPU/内存/磁盘/沙箱数)"
    echo ""
    echo "示例:"
    echo "  $0 0-7 4 0 -- --duration 60 --cleanup"
    echo "  $0 32,34,36,38 4 0 -- --duration 60"
    echo "  $0 0-7 4 0 --pprof -- --duration 60"
    echo "  $0 0-7 4 0 --pprof --perf -- --duration 60"
    exit 1
fi

CPU_RANGE="$1"
PROC_COUNT="$2"
NUMA_NODE="$3"
shift 3

# 解析 --profile, --pprof, --perf 和 -- 后的透传参数
PROFILE=false
PPROF=false
PPROF_CPU_SECONDS=""           # 空 = 自动与 duration 对齐
PPROF_SERIES_INTERVAL=1
PERF=false
PERF_FREQUENCY=99
PERF_DURATION=""               # 空 = 自动与 duration 对齐
PERF_CALL_GRAPH="fp"           # 仅 on-CPU；默认 fp（与历史 -g 一致）
PERF_SANDBOX=false
RESOURCES=false
RESOURCE_INTERVAL=0.1
PASSTHRU_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            PROFILE=true; shift ;;
        --resources)
            RESOURCES=true; shift
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --resource-interval)
                        RESOURCE_INTERVAL="$2"; shift 2 ;;
                    --)
                        shift; PASSTHRU_ARGS=("$@"); break 2 ;;
                    *)
                        break ;;
                esac
            done
            ;;
        --pprof)
            PPROF=true; shift
            # 可选: --pprof 后跟子选项 (--pprof-cpu-seconds N --pprof-series-interval N)
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --pprof-cpu-seconds)
                        PPROF_CPU_SECONDS="$2"; shift 2 ;;
                    --pprof-series-interval)
                        PPROF_SERIES_INTERVAL="$2"; shift 2 ;;
                    --)
                        shift; PASSTHRU_ARGS=("$@"); break 2 ;;
                    *)
                        break ;;
                esac
            done
            ;;
        --perf)
            PERF=true; shift
            # 可选: --perf 后跟子选项 (--perf-frequency / --perf-duration / --perf-call-graph)
            while [[ $# -gt 0 ]]; do
                case "$1" in
                    --perf-frequency)
                        PERF_FREQUENCY="$2"; shift 2 ;;
                    --perf-duration)
                        PERF_DURATION="$2"; shift 2 ;;
                    --perf-call-graph)
                        PERF_CALL_GRAPH="$2"; shift 2 ;;
                    --)
                        shift; PASSTHRU_ARGS=("$@"); break 2 ;;
                    *)
                        break ;;
                esac
            done
            ;;
        --perf_sandbox)
            PERF_SANDBOX=true; shift ;;
        --)
            shift; PASSTHRU_ARGS=("$@"); break ;;
        *)
            echo "错误: 未知参数: $1"
            echo "用法: $0 <CPUS> <K> <NUMA> [--profile] [--pprof [OPTS]] [--perf [OPTS]] [--perf_sandbox] [--resources [OPTS]] [-- <single_cold_start.py 的额外参数>]"
            exit 1 ;;
    esac
done

# 解析 CPU 列表: "M-N" (连续范围) 或 "C1,C2,C3,..." (指定核心)
CPU_LIST=()                     # 所有可用 CPU 核心的数组
if [[ "$CPU_RANGE" == *,* ]]; then
    # 逗号分隔的 CPU 核心列表
    IFS=',' read -ra CPU_LIST <<< "$CPU_RANGE"
    for cpu in "${CPU_LIST[@]}"; do
        if ! [[ "$cpu" =~ ^[0-9]+$ ]]; then
            echo "错误: CPU 核心列表格式不正确: $CPU_RANGE (应为数字逗号分隔，如 32,34,36,38)"
            exit 1
        fi
    done
else
    # M-N 连续范围
    IFS='-' read -r CPU_START CPU_END <<< "$CPU_RANGE"
    if [ -z "${CPU_START:-}" ] || [ -z "${CPU_END:-}" ]; then
        echo "错误: CPU 范围格式不正确，应为 M-N (如 0-7) 或逗号分隔列表 (如 32,34,36,38)"
        exit 1
    fi
    if [ "$CPU_START" -gt "$CPU_END" ]; then
        echo "错误: CPU 范围 $CPU_START > $CPU_END"
        exit 1
    fi
    # 展开范围为数组
    for ((c=CPU_START; c<=CPU_END; c++)); do
        CPU_LIST+=("$c")
    done
fi

# 可用 CPU 数
AVAILABLE_CPUS=${#CPU_LIST[@]}
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

# 从透传参数中提取 --duration 和 --cpuset-cpus 值
TEST_DURATION=""
SANDBOX_CPUS=""
for ((i=0; i<${#PASSTHRU_ARGS[@]}; i++)); do
    if [ "${PASSTHRU_ARGS[$i]}" = "--duration" ] && [ $((i+1)) -lt ${#PASSTHRU_ARGS[@]} ]; then
        TEST_DURATION="${PASSTHRU_ARGS[$((i+1))]}"
    fi
    if [ "${PASSTHRU_ARGS[$i]}" = "--cpuset-cpus" ] && [ $((i+1)) -lt ${#PASSTHRU_ARGS[@]} ]; then
        SANDBOX_CPUS="${PASSTHRU_ARGS[$((i+1))]}"
    fi
done

# 结果目录（运行前清理旧结果）
RESULT_DIR="results/multi"
rm -rf "$RESULT_DIR"
mkdir -p "$RESULT_DIR"

# pprof 时长: 优先用户指定的，否则与 test duration 对齐
if $PPROF; then
    if [ -z "$PPROF_CPU_SECONDS" ]; then
        if [ -n "$TEST_DURATION" ]; then
            PPROF_CPU_SECONDS="$TEST_DURATION"
        else
            PPROF_CPU_SECONDS=30
        fi
    fi
    PPROF_SERIES_DURATION="$PPROF_CPU_SECONDS"
    PPROF_SCRIPT="${SCRIPT_DIR}/containerd_pprof.sh"
    if [ ! -f "$PPROF_SCRIPT" ]; then
        echo "错误: 未找到 pprof 脚本: $PPROF_SCRIPT"
        exit 1
    fi
    PPROF_OUTPUT_DIR="${RESULT_DIR}/pprof"
fi

# perf 时长: 优先用户指定的，否则与 test duration 对齐
if $PERF; then
    if [ -z "$PERF_DURATION" ]; then
        if [ -n "$TEST_DURATION" ]; then
            PERF_DURATION="$TEST_DURATION"
        else
            PERF_DURATION=30
        fi
    fi
    PERF_SCRIPT="${SCRIPT_DIR}/containerd_perf.sh"
    if [ ! -f "$PERF_SCRIPT" ]; then
        echo "错误: 未找到 perf 脚本: $PERF_SCRIPT"
        exit 1
    fi
    PERF_OUTPUT_DIR="${RESULT_DIR}/perf"
fi
# perf_sandbox 时长: 优先用 --perf-duration，否则与 test duration 对齐
if $PERF_SANDBOX; then
    if [ -z "$SANDBOX_CPUS" ]; then
        echo "错误: --perf_sandbox 需要通过 --cpuset-cpus 指定沙箱 CPU"
        exit 1
    fi
    if [ -z "$PERF_DURATION" ]; then
        if [ -n "$TEST_DURATION" ]; then
            PERF_DURATION="$TEST_DURATION"
        else
            PERF_DURATION=30
        fi
    fi
    PERF_SANDBOX_SCRIPT="${SCRIPT_DIR}/containerd_perf.sh"
    if [ ! -f "$PERF_SANDBOX_SCRIPT" ]; then
        echo "错误: 未找到 perf 脚本: $PERF_SANDBOX_SCRIPT"
        exit 1
    fi
    PERF_SANDBOX_OUTPUT_DIR="${RESULT_DIR}/perf_sandbox"
fi

# resources 时长: 与 test duration 对齐
if $RESOURCES; then
    if [ -n "$TEST_DURATION" ]; then
        RESOURCE_DURATION="$TEST_DURATION"
    else
        RESOURCE_DURATION=30
    fi
    RESOURCES_SCRIPT="${SCRIPT_DIR}/system_resources.sh"
    if [ ! -f "$RESOURCES_SCRIPT" ]; then
        echo "错误: 未找到资源采集脚本: $RESOURCES_SCRIPT"
        exit 1
    fi
    RESOURCE_OUTPUT_DIR="${RESULT_DIR}/resources"
    mkdir -p "$RESOURCE_OUTPUT_DIR"
fi

# ============================================================
# 输出配置
# ============================================================
CPU_COUNT=$AVAILABLE_CPUS

echo ""
echo "=================================================="
echo "多进程 Pod 沙箱冷启动测试"
echo "=================================================="
echo "CPU 列表:  $CPU_RANGE  (共 $CPU_COUNT 个核心)"
echo "NUMA 节点: $NUMA_NODE"
echo "进程数:    $PROC_COUNT"
if [ "$PROC_COUNT" -gt "$CPU_COUNT" ]; then
    echo "绑定策略: 轮转 (超出后回到 ${CPU_LIST[0]})"
fi
echo "结果目录:  $RESULT_DIR"
echo "透传参数:  ${PASSTHRU_ARGS[*]:-(无)}"
if $PROFILE; then
    echo "Profile:   已开启 (containerd trace 各阶段时延汇总)"
fi
if $PPROF; then
    echo "pprof:     已开启 (go pprof)"
    echo "           采样时长: ${PPROF_CPU_SECONDS}s, 间隔: ${PPROF_SERIES_INTERVAL}s"
fi
if $PERF; then
    echo "perf:      已开启 (on/off CPU 火焰图)"
    echo "           采样时长: ${PERF_DURATION}s, 频率: ${PERF_FREQUENCY}Hz, on-CPU call-graph: ${PERF_CALL_GRAPH}"
fi
	if $PERF_SANDBOX; then
	    echo "perf_sbox: 已开启 (沙箱火焰图, CPUs: ${SANDBOX_CPUS})"
	    echo "           采样时长: ${PERF_DURATION}s, 频率: ${PERF_FREQUENCY}Hz, on-CPU call-graph: ${PERF_CALL_GRAPH}"
	fi
if $RESOURCES; then
    echo "resources: 已开启 (系统资源时序)"
    echo "           采样时长: ${RESOURCE_DURATION}s, 间隔: ${RESOURCE_INTERVAL}s"
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
# Resources: 静态环境快照
# ============================================================
if $RESOURCES; then
    echo "[resources] 采集静态环境快照..."
    "${RESOURCES_SCRIPT}" metadata \
        --output "${RESOURCE_OUTPUT_DIR}/metadata.json" \
        --cpus "$CPU_RANGE" \
        --numa "$NUMA_NODE" \
        --proc-count "$PROC_COUNT" \
        --passthru-args "${PASSTHRU_ARGS[*]:-}"
    echo ""
fi

# ============================================================
# Profile: 记录测试窗口起止时间（journalctl --since/--until 使用）
# ============================================================
if $PROFILE; then
    PROFILE_START=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[profile] 测试窗口起始: $PROFILE_START"
    # Host-visible runc TRACE file (stderr is often redirected by shim).
    : > /tmp/runc-trace.log 2>/dev/null || true
    echo ""
fi

# ============================================================
# 启动进程（每个 single_cold_start.py 不再自行清缓存和清理）
# ============================================================
PIDS=()
PROC=0
while [ "$PROC" -lt "$PROC_COUNT" ]; do
    BIND_CPU=${CPU_LIST[$((PROC % CPU_COUNT))]}
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
# profiling: 启动 pprof / perf 抓取（与测试进程并行）
# ============================================================
PPROF_PID=""
PERF_PID=""
PERF_SANDBOX_PID=""
RESOURCE_PID=""
if $PPROF || $PERF || $PERF_SANDBOX; then
    echo "[profile] 等待 3s 让沙箱进入稳态..."
    sleep 3
fi

if $RESOURCES; then
    echo "[resources] 启动时序采样..."
    echo "[resources]   时长: ${RESOURCE_DURATION}s, 间隔: ${RESOURCE_INTERVAL}s, CPUs: ${CPU_RANGE}"

    "${RESOURCES_SCRIPT}" capture \
        --output-dir "${RESOURCE_OUTPUT_DIR}" \
        --duration "${RESOURCE_DURATION}" \
        --interval "${RESOURCE_INTERVAL}" \
        --worker-cpus "$CPU_RANGE" \
        --sandbox-cpus "${SANDBOX_CPUS:-}" \
        --numa "$NUMA_NODE" &
    RESOURCE_PID=$!
    echo "[resources] 采样进程 PID: $RESOURCE_PID"
fi

if $PPROF; then
    echo "[pprof] 启动 containerd profile 抓取..."
    echo "[pprof]   CPU 采样: ${PPROF_CPU_SECONDS}s, 瞬时间隔: ${PPROF_SERIES_INTERVAL}s, 总时长: ${PPROF_SERIES_DURATION}s"

    sudo "${PPROF_SCRIPT}" capture \
        --output-dir "${PPROF_OUTPUT_DIR}" \
        --cpu-seconds "${PPROF_CPU_SECONDS}" \
        --series-interval "${PPROF_SERIES_INTERVAL}" \
        --series-duration "${PPROF_SERIES_DURATION}" &
    PPROF_PID=$!
    echo "[pprof] pprof 抓取进程 PID: $PPROF_PID"
fi

if $PERF; then
    echo "[perf] 启动 perf 火焰图抓取..."
    echo "[perf]   时长: ${PERF_DURATION}s, 频率: ${PERF_FREQUENCY}Hz, call-graph: ${PERF_CALL_GRAPH}"

    sudo "${PERF_SCRIPT}" capture \
        --output-dir "${PERF_OUTPUT_DIR}" \
        --duration "${PERF_DURATION}" \
        --frequency "${PERF_FREQUENCY}" \
        --call-graph "${PERF_CALL_GRAPH}" &
    PERF_PID=$!
    echo "[perf] perf 抓取进程 PID: $PERF_PID"
fi
if $PERF_SANDBOX; then
    echo "[perf_sbox] 启动沙箱火焰图抓取..."
    echo "[perf_sbox]   CPUs: ${SANDBOX_CPUS}, 时长: ${PERF_DURATION}s, 频率: ${PERF_FREQUENCY}Hz, call-graph: ${PERF_CALL_GRAPH}"

    sudo "${PERF_SANDBOX_SCRIPT}" capture \
        --cpus "${SANDBOX_CPUS}" \
        --output-dir "${PERF_SANDBOX_OUTPUT_DIR}" \
        --duration "${PERF_DURATION}" \
        --frequency "${PERF_FREQUENCY}" \
        --call-graph "${PERF_CALL_GRAPH}" &
    PERF_SANDBOX_PID=$!
    echo "[perf_sbox] 抓取进程 PID: $PERF_SANDBOX_PID"
fi

if $PPROF || $PERF || $PERF_SANDBOX || $RESOURCES; then
    echo ""
fi

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
# resources: 等待采样完成并汇总
# ============================================================
if $RESOURCES && [ -n "$RESOURCE_PID" ]; then
    echo ""
    echo "[resources] 等待采样完成 (PID: $RESOURCE_PID)..."
    if wait "$RESOURCE_PID"; then
        echo "[resources] 采样完成"
        "${RESOURCES_SCRIPT}" summarize "${RESOURCE_OUTPUT_DIR}" || \
            echo "[resources] ⚠ 汇总过程中出现问题"
        echo "[resources] 开始关联分析..."
        python3 "${SCRIPT_DIR}/resource_analyzer.py" "${RESULT_DIR}" || \
            echo "[resources] ⚠ 关联分析过程中出现问题"
    else
        echo "[resources] ⚠ 采样失败 (exit=$?)"
    fi
fi

# ============================================================
# pprof: 等待抓取完成并分析
# ============================================================
if $PPROF && [ -n "$PPROF_PID" ]; then
    echo ""
    echo "[pprof] 等待 pprof 抓取完成 (PID: $PPROF_PID)..."
    if wait "$PPROF_PID"; then
        echo "[pprof] 抓取完成"

        # 分析
        if [ -f "${PPROF_SCRIPT}" ]; then
            echo "[pprof] 开始分析..."
            "${PPROF_SCRIPT}" analyze "${PPROF_OUTPUT_DIR}" || \
                echo "[pprof] ⚠ 分析过程中出现问题（profile 文件仍保留在 ${PPROF_OUTPUT_DIR}）"
        fi
    else
        echo "[pprof] ⚠ pprof 抓取失败 (exit=$?)"
    fi
fi

# ============================================================
# perf: 等待抓取完成并生成火焰图
# ============================================================
if $PERF && [ -n "$PERF_PID" ]; then
    echo ""
    echo "[perf] 等待 perf 抓取完成 (PID: $PERF_PID)..."
    if wait "$PERF_PID"; then
        echo "[perf] 抓取完成"

        # perf capture 内部已生成 SVG，这里无需再调用 analyze
        svg_count=$(find "${PERF_OUTPUT_DIR}" -name '*.svg' -type f 2>/dev/null | wc -l)
        echo "[perf] 火焰图 × ${svg_count} → ${PERF_OUTPUT_DIR}/"
    else
        echo "[perf] ⚠ perf 抓取失败 (exit=$?)"
    fi
fi

# ============================================================
# perf_sandbox: 等待抓取完成并生成火焰图
# ============================================================
if $PERF_SANDBOX && [ -n "$PERF_SANDBOX_PID" ]; then
    echo ""
    echo "[perf_sbox] 等待沙箱火焰图抓取完成 (PID: $PERF_SANDBOX_PID)..."
    if wait "$PERF_SANDBOX_PID"; then
        echo "[perf_sbox] 抓取完成"
        svg_count=$(find "${PERF_SANDBOX_OUTPUT_DIR}" -name '*.svg' -type f 2>/dev/null | wc -l)
        echo "[perf_sbox] 火焰图 × ${svg_count} → ${PERF_SANDBOX_OUTPUT_DIR}/"
    else
        echo "[perf_sbox] ⚠ 抓取失败 (exit=$?)"
    fi
fi

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

    # Merge runc [TRACE] lines (written to host file; stderr may be container IO).
    if [ -s /tmp/runc-trace.log ]; then
        echo "[profile] 合并 runc TRACE 文件 (/tmp/runc-trace.log, $(wc -l < /tmp/runc-trace.log) lines)..."
        cat /tmp/runc-trace.log >> "$PROFILE_LOG"
    fi

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
