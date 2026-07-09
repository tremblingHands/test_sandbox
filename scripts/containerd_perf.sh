#!/bin/bash
# -*- coding: utf-8 -*-
#
# containerd perf 火焰图抓取与分析脚本
#
# 用法:
#     ./containerd_perf.sh capture [OPTIONS]       # 抓取 on/off CPU 火焰图
#     ./containerd_perf.sh analyze <OUTPUT_DIR>    # 从已有数据生成 SVG
#
# capture 选项:
#     --output-dir DIR          输出目录（默认: results/perf）
#     --duration SEC            采样时长（默认: 30）
#     --frequency HZ            on-CPU 采样频率 Hz（默认: 99）
#     --offcpu-method METHOD    off-CPU 抓取方式: perf（默认）| ebpf
#                              perf: perf record -C <CPUS> (指定 core + sched 事件 + inject)
#                              ebpf: offcputime -p <PID> (eBPF 内核态聚合，轻量无大文件)
#
# 示例:
#     sudo ./containerd_perf.sh capture --output-dir results/multi/perf
#     sudo ./containerd_perf.sh capture --output-dir /tmp/perf --duration 60 --offcpu-method perf
#     ./containerd_perf.sh analyze results/multi/perf
#
# 输出:
#     on_cpu_<CPUS>.svg         On-CPU 火焰图
#     off_cpu_<CPUS>.svg        Off-CPU 火焰图（时间加权，颜色区分锁/IO/sleep）
#     perf_on_cpu.data          on-CPU 原始 perf 数据
#     off_cpu.folded | perf_off_cpu.data   off-CPU 折叠栈或原始 perf 数据
#
# On-CPU 方法:  perf record -F 99 -g -C <CPUS> → stackcollapse-perf.pl → flamegraph.pl
# Off-CPU ebpf: /usr/share/bcc/tools/offcputime -f -d -p <PID> → flamegraph.pl --colors=io
# Off-CPU perf: perf record -C <CPUS> sched events + inject -s → awk → stackcollapse.pl → flamegraph.pl
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================
# 默认值
# ============================================================
DEFAULT_FREQUENCY=99
DEFAULT_DURATION=30
DEFAULT_OUTPUT_DIR="results/perf"
DEFAULT_OFFCPU_METHOD="perf"

# ============================================================
# 工具函数
# ============================================================
find_containerd_cpus() {
    local service_file="/usr/lib/systemd/system/containerd.service"
    local cpus=""

    if [ -f "$service_file" ]; then
        cpus=$(grep -oP 'numactl\s+-C\s+\K[0-9,\-]+' "$service_file" 2>/dev/null | head -1) || true
    fi

    if [ -z "$cpus" ]; then
        echo "[perf] 错误: 无法从 $service_file 中解析 numactl -C 配置" >&2
        return 1
    fi

    echo "$cpus"
}

check_prereqs() {
    local method="$1"
    local missing=()

    if ! command -v perf &>/dev/null; then
        missing+=("perf (linux-tools)")
    fi
    if ! command -v stackcollapse-perf.pl &>/dev/null; then
        missing+=("stackcollapse-perf.pl (FlameGraph)")
    fi
    if ! command -v flamegraph.pl &>/dev/null; then
        missing+=("flamegraph.pl (FlameGraph)")
    fi

    # off-CPU 方法依赖不同工具
    case "$method" in
        ebpf)
            if [ ! -x /usr/share/bcc/tools/offcputime ]; then
                missing+=("offcputime (bcc-tools)")
            fi
            ;;
        perf)
            if ! command -v stackcollapse.pl &>/dev/null; then
                missing+=("stackcollapse.pl (FlameGraph)")
            fi
            ;;
    esac

    if [ ${#missing[@]} -gt 0 ]; then
        echo "[perf] 错误: 缺少依赖: ${missing[*]}" >&2
        return 1
    fi
    return 0
}

generate_oncpu_flamegraph() {
    local data="$1"
    local title="$2"
    local svg="$3"
    local colors="${4:-hot}"

    if [ ! -s "$data" ]; then
        return 1
    fi

    perf script -i "$data" 2>/dev/null | \
        stackcollapse-perf.pl 2>/dev/null | \
        flamegraph.pl --title "$title" --colors="$colors" \
        > "$svg" 2>/dev/null
}

generate_offcpu_flamegraph_ebpf() {
    # eBPF: offcputime 折叠栈 → flamegraph.pl
    local folded="$1"
    local title="$2"
    local svg="$3"

    if [ ! -s "$folded" ]; then
        return 1
    fi

    flamegraph.pl --title "$title" --colors=io --countname=us \
        < "$folded" > "$svg" 2>/dev/null
}

generate_offcpu_flamegraph_perf() {
    # perf: perf.data → perf script → awk → stackcollapse.pl → flamegraph.pl
    local data="$1"
    local title="$2"
    local svg="$3"

    if [ ! -s "$data" ]; then
        return 1
    fi

    perf script -i "$data" -F comm,pid,tid,cpu,time,period,event,ip,sym,dso,trace 2>/dev/null | \
        awk '
            NF > 4 { exec = $1; period_ms = int($5 / 1000000) }
            NF > 1 && NF <= 4 && period_ms > 0 { print $2 }
            NF < 2 && period_ms > 0 { printf "%s\n%d\n\n", exec, period_ms }
        ' | \
        stackcollapse.pl 2>/dev/null | \
        flamegraph.pl --title "$title" --colors=io --countname=ms \
        > "$svg" 2>/dev/null
}

# ============================================================
# analyze 子命令
# ============================================================
cmd_analyze() {
    if [ $# -lt 1 ]; then
        echo "用法: $0 analyze <OUTPUT_DIR>"
        echo "示例: $0 analyze results/multi/perf"
        exit 1
    fi

    local perf_dir="$1"

    if [ ! -d "$perf_dir" ]; then
        echo "错误: 目录不存在: $perf_dir"
        exit 1
    fi

    # analyze 时不清楚原方法，宽松检查
    local missing=()
    if ! command -v flamegraph.pl &>/dev/null; then missing+=("flamegraph.pl"); fi
    if [ ${#missing[@]} -gt 0 ]; then
        echo "错误: 缺少依赖: ${missing[*]}"
        exit 1
    fi

    local metadata="${perf_dir}/metadata.txt"
    if [ -f "$metadata" ]; then
        echo "=================================================="
        echo "Perf 抓取元数据"
        echo "=================================================="
        cat "$metadata"
        echo ""
    fi

    echo "[perf] 生成火焰图..."

    local cpus_file
    cpus_file=$(grep -oP 'Containerd CPUs:\s+\K.+' "$metadata" 2>/dev/null | tr ',' '-' || echo "unknown")

    # On-CPU
    if [ -f "${perf_dir}/perf_on_cpu.data" ] && [ -s "${perf_dir}/perf_on_cpu.data" ]; then
        local on_svg="${perf_dir}/on_cpu_${cpus_file}.svg"
        echo "[perf]   $(basename "$on_svg") ..."
        if command -v stackcollapse-perf.pl &>/dev/null && \
            generate_oncpu_flamegraph "${perf_dir}/perf_on_cpu.data" \
                "containerd on-CPU (CPUs ${cpus_file})" "$on_svg" "hot"; then
            echo "[perf]     OK ($(du -h "$on_svg" | cut -f1))"
        else
            echo "[perf]     警告: $(basename "$on_svg") 生成失败"
        fi
    else
        echo "[perf]   on_cpu: 无数据，跳过"
    fi

    # Off-CPU (两种可能：folded 文件 或 perf.data)
    local off_svg="${perf_dir}/off_cpu_${cpus_file}.svg"
    if [ -f "${perf_dir}/off_cpu.folded" ] && [ -s "${perf_dir}/off_cpu.folded" ]; then
        echo "[perf]   $(basename "$off_svg") ..."
        if generate_offcpu_flamegraph_ebpf "${perf_dir}/off_cpu.folded" \
            "containerd off-CPU (CPUs ${cpus_file})" "$off_svg"; then
            echo "[perf]     OK ($(du -h "$off_svg" | cut -f1))"
        else
            echo "[perf]     警告: $(basename "$off_svg") 生成失败"
        fi
    elif [ -f "${perf_dir}/perf_off_cpu.data" ] && [ -s "${perf_dir}/perf_off_cpu.data" ]; then
        echo "[perf]   $(basename "$off_svg") ..."
        if command -v stackcollapse.pl &>/dev/null && \
            generate_offcpu_flamegraph_perf "${perf_dir}/perf_off_cpu.data" \
                "containerd off-CPU (CPUs ${cpus_file})" "$off_svg"; then
            echo "[perf]     OK ($(du -h "$off_svg" | cut -f1))"
        else
            echo "[perf]     警告: $(basename "$off_svg") 生成失败"
        fi
    else
        echo "[perf]   off_cpu: 无数据，跳过"
    fi

    local svg_count=$(find "$perf_dir" -name '*.svg' -type f 2>/dev/null | wc -l)
    echo "[perf] 分析完成 → SVG × ${svg_count}"
}

# ============================================================
# capture 子命令
# ============================================================
cmd_capture() {
    local OUTPUT_DIR=""
    local DURATION="$DEFAULT_DURATION"
    local FREQUENCY="$DEFAULT_FREQUENCY"
    local OFFCPU_METHOD="$DEFAULT_OFFCPU_METHOD"
    local CPUS=""          # 空 = 自动从 containerd.service 解析

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output-dir)      OUTPUT_DIR="$2";    shift 2 ;;
            --duration)        DURATION="$2";       shift 2 ;;
            --frequency)       FREQUENCY="$2";      shift 2 ;;
            --offcpu-method)   OFFCPU_METHOD="$2";  shift 2 ;;
            --cpus)            CPUS="$2";           shift 2 ;;
            *)
                echo "错误: 未知参数: $1"
                echo "用法: $0 capture --output-dir DIR [...]"
                exit 1
                ;;
        esac
    done

    if [ -z "$OUTPUT_DIR" ]; then
        OUTPUT_DIR="$DEFAULT_OUTPUT_DIR"
    fi

    if [ "$OFFCPU_METHOD" != "ebpf" ] && [ "$OFFCPU_METHOD" != "perf" ]; then
        echo "错误: --offcpu-method 必须是 ebpf 或 perf，当前值: $OFFCPU_METHOD"
        exit 1
    fi

    check_prereqs "$OFFCPU_METHOD" || exit 1

    local CONTAINERD_CPUS
    if [ -n "$CPUS" ]; then
        CONTAINERD_CPUS="$CPUS"
    else
    CONTAINERD_CPUS=$(find_containerd_cpus) || exit 1
    fi

    mkdir -p "$OUTPUT_DIR"

    # metadata
    local offcpu_desc
    if [ "$OFFCPU_METHOD" = "ebpf" ]; then
        offcpu_desc="/usr/share/bcc/tools/offcputime -f -d -p <PID>"
    else
        offcpu_desc="perf record -C ${CONTAINERD_CPUS} sched events + inject -s"
    fi

    local METADATA="${OUTPUT_DIR}/metadata.txt"
    cat > "$METADATA" <<EOF
抓取时间: $(date '+%Y-%m-%d %H:%M:%S')
Containerd CPUs: $CONTAINERD_CPUS
采样时长: ${DURATION}s
采样频率: ${FREQUENCY} Hz
On-CPU 方法:  perf record -F ${FREQUENCY} -g -C ${CONTAINERD_CPUS}
Off-CPU 方法: $offcpu_desc
内核版本: $(uname -r)
架构: $(uname -m)
EOF

    echo ""
    echo "[perf] ================================================"
    echo "[perf] 抓取 containerd 火焰图"
    echo "[perf] CPUs:      $CONTAINERD_CPUS"
    echo "[perf] 时长:      ${DURATION}s, 频率: ${FREQUENCY} Hz"
    echo "[perf] on-CPU:    perf record"
    echo "[perf] off-CPU:   $OFFCPU_METHOD"
    echo "[perf] 输出:      $OUTPUT_DIR"
    echo "[perf] ================================================"
    echo ""

    # ============================================================
    # on-CPU: perf record (始终相同)
    # ============================================================
    echo "[perf] 启动 on-CPU perf record (${DURATION}s 采样, ${FREQUENCY}Hz)..."
    perf record \
        -F "$FREQUENCY" \
        -g \
        -C "$CONTAINERD_CPUS" \
        -o "${OUTPUT_DIR}/perf_on_cpu.data" \
        -- sleep "$DURATION" &
    ONCPU_PID=$!
    echo "[perf]   on-CPU  PID: $ONCPU_PID"

    # ============================================================
    # off-CPU: ebpf 或 perf
    # ============================================================
    OFFCPU_PID=""

    case "$OFFCPU_METHOD" in

    ebpf)
        echo "[perf] 启动 off-CPU eBPF offcputime (${DURATION}s)..."
        /usr/share/bcc/tools/offcputime \
            -f -d \
            -p "$(pgrep -nx containerd)" \
            -m 1000 \
            --stack-storage-size 10240 \
            "$DURATION" \
            > "${OUTPUT_DIR}/off_cpu.folded" &
        OFFCPU_PID=$!
        echo "[perf]   off-CPU PID: $OFFCPU_PID"
        ;;

    perf)
        echo "[perf] 准备 perf off-CPU 环境..."
        # 开启 schedstats
        if [ -w /proc/sys/kernel/sched_schedstats ]; then
            echo 1 > /proc/sys/kernel/sched_schedstats
            echo "[perf]   sched_schedstats = $(cat /proc/sys/kernel/sched_schedstats)"
        fi
        # 增大 perf mlock 限制
        if [ -w /proc/sys/kernel/perf_event_mlock_kb ]; then
            echo 262144 > /proc/sys/kernel/perf_event_mlock_kb 2>/dev/null || true
            echo "[perf]   perf_event_mlock_kb = $(cat /proc/sys/kernel/perf_event_mlock_kb)"
        fi

        echo "[perf] 启动 off-CPU perf record (${DURATION}s, CPUs $CONTAINERD_CPUS)..."
        # -C <CPUS>: 指定 core（非 -p PID）
        # -m 4096: 每 CPU buffer 16MB
        perf record \
            -g \
            -m 4096 \
            -C "$CONTAINERD_CPUS" \
            -e sched:sched_stat_sleep \
            -e sched:sched_stat_iowait \
            -e sched:sched_stat_blocked \
            -e sched:sched_switch \
            -e sched:sched_process_exit \
            -o "${OUTPUT_DIR}/perf_off_cpu.raw" \
            -- sleep "$DURATION" &
        OFFCPU_PID=$!
        echo "[perf]   off-CPU PID: $OFFCPU_PID"
        ;;

    esac
    echo ""

    # ============================================================
    # 等待完成
    # ============================================================
    echo "[perf] 等待抓取完成..."

    echo "[perf] 等待 on-CPU perf record 完成..."
    if wait "$ONCPU_PID"; then
        echo "[perf]   on-CPU  完成 ($(du -h "${OUTPUT_DIR}/perf_on_cpu.data" 2>/dev/null | cut -f1))"
    else
        echo "[perf]   警告: on-CPU perf record 失败 (exit=$?)"
    fi

    echo "[perf] 等待 off-CPU 完成..."
    if wait "$OFFCPU_PID"; then
        case "$OFFCPU_METHOD" in
            ebpf)
                local lines=$(wc -l < "${OUTPUT_DIR}/off_cpu.folded" 2>/dev/null || echo 0)
                echo "[perf]   off-CPU 完成 (${lines} 种不同栈, $(du -h "${OUTPUT_DIR}/off_cpu.folded" 2>/dev/null | cut -f1))"
                ;;
            perf)
                echo "[perf]   off-CPU record 完成 ($(du -h "${OUTPUT_DIR}/perf_off_cpu.raw" 2>/dev/null | cut -f1))"
                # perf inject -s: 合并 sched_stat delay → sched_switch
                if [ -s "${OUTPUT_DIR}/perf_off_cpu.raw" ]; then
                    echo "[perf]   perf inject -s (合并 sched_stat delay → sched_switch)..."
                    if perf inject -v -s -i "${OUTPUT_DIR}/perf_off_cpu.raw" \
                        -o "${OUTPUT_DIR}/perf_off_cpu.data" 2>/dev/null; then
                        echo "[perf]   inject 完成 ($(du -h "${OUTPUT_DIR}/perf_off_cpu.data" 2>/dev/null | cut -f1))"
                        rm -f "${OUTPUT_DIR}/perf_off_cpu.raw"
                    else
                        echo "[perf]   警告: perf inject 失败，保留 raw 数据"
                        mv "${OUTPUT_DIR}/perf_off_cpu.raw" "${OUTPUT_DIR}/perf_off_cpu.data"
                    fi
                fi
                ;;
        esac
    else
        echo "[perf]   警告: off-CPU 失败 (exit=$?)"
    fi

    echo ""

    # ============================================================
    # 生成火焰图
    # ============================================================
    echo "[perf] 生成火焰图..."

    local cpus_file_name
    cpus_file_name=$(echo "$CONTAINERD_CPUS" | tr ',' '-')

    # On-CPU
    if [ -f "${OUTPUT_DIR}/perf_on_cpu.data" ] && [ -s "${OUTPUT_DIR}/perf_on_cpu.data" ]; then
        local on_svg="${OUTPUT_DIR}/on_cpu_${cpus_file_name}.svg"
        echo "[perf]   $(basename "$on_svg") ..."
        if generate_oncpu_flamegraph "${OUTPUT_DIR}/perf_on_cpu.data" \
            "containerd on-CPU (CPUs $CONTAINERD_CPUS, ${DURATION}s, ${FREQUENCY}Hz)" \
            "$on_svg" "hot"; then
            echo "[perf]     OK ($(du -h "$on_svg" | cut -f1))"
        else
            echo "[perf]     警告: $(basename "$on_svg") 生成失败"
        fi
    fi

    # Off-CPU
    local off_svg="${OUTPUT_DIR}/off_cpu_${cpus_file_name}.svg"
    case "$OFFCPU_METHOD" in
        ebpf)
            if [ -f "${OUTPUT_DIR}/off_cpu.folded" ] && [ -s "${OUTPUT_DIR}/off_cpu.folded" ]; then
                echo "[perf]   $(basename "$off_svg") ..."
                if generate_offcpu_flamegraph_ebpf "${OUTPUT_DIR}/off_cpu.folded" \
                    "containerd off-CPU (CPUs $CONTAINERD_CPUS, ${DURATION}s)" \
                    "$off_svg"; then
                    echo "[perf]     OK ($(du -h "$off_svg" | cut -f1))"
                else
                    echo "[perf]     警告: $(basename "$off_svg") 生成失败"
                fi
            fi
            ;;
        perf)
            if [ -f "${OUTPUT_DIR}/perf_off_cpu.data" ] && [ -s "${OUTPUT_DIR}/perf_off_cpu.data" ]; then
                echo "[perf]   $(basename "$off_svg") ..."
                if generate_offcpu_flamegraph_perf "${OUTPUT_DIR}/perf_off_cpu.data" \
                    "containerd off-CPU (CPUs $CONTAINERD_CPUS, ${DURATION}s)" \
                    "$off_svg"; then
                    echo "[perf]     OK ($(du -h "$off_svg" | cut -f1))"
                else
                    echo "[perf]     警告: $(basename "$off_svg") 生成失败"
                fi
            fi
            ;;
    esac

    echo ""

    # ============================================================
    # 完成
    # ============================================================
    echo "[perf] ================================================"
    echo "[perf] 抓取完成"
    echo "[perf] ================================================"
    echo "[perf] 输出文件:"
    find "$OUTPUT_DIR" -type f -exec ls -lh {} \; | sed 's/^/[perf]   /'
    echo ""
}

# ============================================================
# 主入口
# ============================================================
usage() {
    echo "用法: $0 <command> [options]"
    echo ""
    echo "命令:"
    echo "  capture   抓取 on/off CPU 火焰图"
    echo "  analyze   从已有数据生成 SVG"
    echo ""
    echo "capture 选项:"
    echo "  --output-dir DIR          输出目录（默认: results/perf）"
    echo "  --duration SEC            采样时长（默认: $DEFAULT_DURATION）"
    echo "  --frequency HZ            on-CPU 采样频率（默认: $DEFAULT_FREQUENCY）"
    echo "  --offcpu-method METHOD    off-CPU 抓取方式: perf（默认）| perf"
    echo ""
    echo "analyze 用法:"
    echo "  $0 analyze <OUTPUT_DIR>"
}

if [ $# -lt 1 ]; then
    usage
    exit 1
fi

COMMAND="$1"
shift

case "$COMMAND" in
    capture)  cmd_capture "$@" ;;
    analyze)  cmd_analyze "$@" ;;
    -h|--help|help) usage ;;
    *)
        echo "错误: 未知命令 '$COMMAND'"
        usage
        exit 1
        ;;
esac
