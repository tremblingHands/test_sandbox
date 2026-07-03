#!/bin/bash
# -*- coding: utf-8 -*-
#
# containerd pprof 抓取与分析脚本
#
# 用法:
#     ./containerd_pprof.sh capture [OPTIONS]       # 抓取 profile
#     ./containerd_pprof.sh analyze <OUTPUT_DIR>    # 解析已抓取的 profile
#
# capture 选项:
#     --output-dir DIR          输出目录（必需）
#     --debug-sock PATH         containerd debug socket（默认: /run/containerd/debug.sock）
#     --cpu-seconds SEC         CPU profile 采样时长（默认: 30）
#     --series-interval SEC     瞬时 profile 抓取间隔（默认: 5）
#     --series-duration SEC     瞬时 profile 抓取总时长（默认: 60，从首次抓取开始计时）
#     --series-profiles LIST    瞬时时间序列 profile，逗号分隔（默认: heap,goroutine,allocs）
#     --cumulative-profiles LIST 累积型 profile，基线+结束做差（默认: block,mutex,threadcreate）
#
# 示例:
#     sudo ./containerd_pprof.sh capture --output-dir results/multi/pprof
#     sudo ./containerd_pprof.sh capture --output-dir /tmp/pprof --cpu-seconds 60 --series-interval 2
#     ./containerd_pprof.sh analyze results/multi/pprof
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GO_BIN="${GO_BIN:-/opt/go/bin/go}"

# ============================================================
# 默认值
# ============================================================
DEFAULT_DEBUG_SOCK="/run/containerd/debug.sock"
DEFAULT_CPU_SECONDS=30
DEFAULT_SERIES_INTERVAL=5
DEFAULT_SERIES_DURATION=60
DEFAULT_SERIES_PROFILES="heap,goroutine,allocs"
DEFAULT_CUMULATIVE_PROFILES="block,mutex,threadcreate"

# ============================================================
# 工具函数
# ============================================================
fetch_profile() {
    # 从 containerd debug socket 抓取单个 profile
    # 用法: fetch_profile <profile_name> <output_path> [query_params]
    local profile="$1"
    local output="$2"
    local params="${3:-}"

    local url="http://localhost/debug/pprof/${profile}"
    if [ -n "$params" ]; then
        url="${url}?${params}"
    fi

    curl -s --max-time 120 --unix-socket "$DEBUG_SOCK" "$url" -o "$output"
    local rc=$?
    if [ $rc -ne 0 ] || [ ! -s "$output" ]; then
        echo "[pprof] 警告: 抓取 $profile 失败 (curl rc=$rc)" >&2
        rm -f "$output"
        return 1
    fi
    return 0
}

timestamp_ms() {
    date +%s%3N
}

# ============================================================
# analyze 子命令
# ============================================================
cmd_analyze() {
    if [ $# -lt 1 ]; then
        echo "用法: $0 analyze <OUTPUT_DIR>"
        echo ""
        echo "  OUTPUT_DIR   containerd_pprof.sh capture 的输出目录"
        echo ""
        echo "示例:"
        echo "  $0 analyze results/multi/pprof"
        exit 1
    fi

    local pprof_dir="$1"
    local analysis_file="${pprof_dir}/pprof_analysis.txt"

    if [ ! -d "$pprof_dir" ]; then
        echo "错误: 目录不存在: $pprof_dir"
        exit 1
    fi

    # 读取 metadata
    local metadata="${pprof_dir}/metadata.txt"
    if [ -f "$metadata" ]; then
        echo "=================================================="
        echo "Profile 抓取元数据"
        echo "=================================================="
        cat "$metadata"
        echo ""
    fi

    {
        echo "=================================================="
        echo "pprof 分析报告"
        echo "生成时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "=================================================="
        echo ""

        # --- CPU Profile ---
        if [ -f "${pprof_dir}/cpu.pprof" ]; then
            echo "=== CPU Profile (-top 前 40) ==="
            CGO_ENABLED=0 "$GO_BIN" tool pprof -top "${pprof_dir}/cpu.pprof" 2>&1 | head -50
            echo ""
        fi

        # --- Instantaneous Series Profiles ---
        for profile_type in heap goroutine allocs; do
            local series_dir="${pprof_dir}/${profile_type}"
            if [ ! -d "$series_dir" ]; then
                continue
            fi

            local files=("$series_dir"/*.pprof)
            if [ ! -f "${files[0]}" ]; then
                continue
            fi

            echo "=== ${profile_type} 时间序列 (文件数: ${#files[@]}) ==="

            # 统计总数趋势
            echo ""
            echo "--- 总量趋势 ---"
            printf "%-6s %-14s %10s\n" "Seq" "Time" "Total"
            for f in "${files[@]}"; do
                local fname=$(basename "$f" .pprof)
                local seq="${fname%%_*}"
                local ts="${fname#*_}"
                local total=$(CGO_ENABLED=0 "$GO_BIN" tool pprof -top "$f" 2>/dev/null | \
                    grep -oP '\d+(?= total)' | head -1 || echo "?")
                printf "%-6s %-14s %10s\n" "$seq" "$ts" "${total:-?}"
            done

            # goroutine 额外输出状态分布
            if [ "$profile_type" = "goroutine" ]; then
                echo ""
                echo "--- 状态分布趋势 ---"
                echo "Seq  Time         Total  | 状态分布 (count state)"
                for f in "${files[@]}"; do
                    local fname=$(basename "$f" .pprof)
                    local seq="${fname%%_*}"
                    local ts="${fname#*_}"
                    local total=$(CGO_ENABLED=0 "$GO_BIN" tool pprof -top "$f" 2>/dev/null | \
                        grep -oP '\d+(?= total)' | head -1 || echo "?")
                    local states=$(CGO_ENABLED=0 "$GO_BIN" tool pprof -traces "$f" 2>/dev/null | \
                        grep -oP '^goroutine \d+ \[\K[^\]]+' | sort | uniq -c | sort -rn | \
                        awk '{printf "%s:%s ", $2, $1}' | sed 's/ $//')
                    printf "%-4s %-12s %6s  |  %s\n" "$seq" "$ts" "${total:-?}" "${states:-无数据}"
                done

                echo ""
                echo "--- 最后一次 goroutine 详细栈 (top 30 goroutines) ---"
                local last_file="${files[-1]}"
                CGO_ENABLED=0 "$GO_BIN" tool pprof -traces "$last_file" 2>/dev/null | head -200
            fi

            echo ""
        done

        # --- Cumulative Profiles (diff) ---
        for profile_type in block mutex threadcreate; do
            local baseline="${pprof_dir}/${profile_type}_baseline.pprof"
            local end="${pprof_dir}/${profile_type}_end.pprof"

            if [ -f "$baseline" ] && [ -f "$end" ]; then
                echo "=== ${profile_type} (测试窗口内增量, -base 做差) ==="
                CGO_ENABLED=0 "$GO_BIN" tool pprof -top -base="$baseline" "$end" 2>&1 | head -40
                echo ""

                # 也输出原始 end 快照的 top
                echo "--- ${profile_type} end 快照 (全生命周期累积) ---"
                CGO_ENABLED=0 "$GO_BIN" tool pprof -top "$end" 2>&1 | head -20
                echo ""
            elif [ -f "$end" ]; then
                echo "=== ${profile_type} (无基线，仅 end 快照) ==="
                CGO_ENABLED=0 "$GO_BIN" tool pprof -top "$end" 2>&1 | head -40
                echo ""
            fi
        done

    } > "$analysis_file"

    # ============================================================
    # 生成 SVG 图
    # ============================================================
    local svg_dir="${pprof_dir}/svg"
    mkdir -p "$svg_dir"

    # 检查 dot 是否可用
    if ! command -v dot &>/dev/null; then
        echo "[pprof] ⚠ 未找到 graphviz dot，跳过 SVG 生成（apt install graphviz）"
        echo "[pprof] 分析完成 → $analysis_file"
        return
    fi

    echo "[pprof] 生成 SVG 图..."

    local svg_count=0

    # --- CPU ---
    if [ -f "${pprof_dir}/cpu.pprof" ]; then
        echo "[pprof]   cpu.svg ..."
        CGO_ENABLED=0 "$GO_BIN" tool pprof -dot "${pprof_dir}/cpu.pprof" 2>/dev/null | \
            dot -Tsvg -o "${svg_dir}/cpu.svg" 2>/dev/null && svg_count=$((svg_count + 1)) || \
            echo "[pprof]   警告: cpu.svg 生成失败"
    fi

    # --- 瞬时 profile: 所有快照都生成 SVG ---
    for profile_type in heap goroutine allocs; do
        local series_dir="${pprof_dir}/${profile_type}"
        if [ -d "$series_dir" ]; then
            local files=("$series_dir"/*.pprof)
            if [ -f "${files[0]}" ]; then
                local svg_subdir="${svg_dir}/${profile_type}"
                mkdir -p "$svg_subdir"
                for f in "${files[@]}"; do
                    local fname=$(basename "$f" .pprof)
                    CGO_ENABLED=0 "$GO_BIN" tool pprof -dot "$f" 2>/dev/null | \
                        dot -Tsvg -o "${svg_subdir}/${fname}.svg" 2>/dev/null && \
                        svg_count=$((svg_count + 1)) || true
                done
                echo "[pprof]   ${profile_type}/ → ${#files[@]} 个 SVG"
            fi
        fi
    done

    # --- 累积 profile: 基线 / 结束 / 差值 各一张 ---
    for profile_type in block mutex threadcreate; do
        local baseline="${pprof_dir}/${profile_type}_baseline.pprof"
        local end="${pprof_dir}/${profile_type}_end.pprof"

        if [ -f "$baseline" ]; then
            echo "[pprof]   ${profile_type}_baseline.svg ..."
            CGO_ENABLED=0 "$GO_BIN" tool pprof -dot "$baseline" 2>/dev/null | \
                dot -Tsvg -o "${svg_dir}/${profile_type}_baseline.svg" 2>/dev/null && \
                svg_count=$((svg_count + 1)) || true
        fi

        if [ -f "$end" ]; then
            echo "[pprof]   ${profile_type}_end.svg ..."
            CGO_ENABLED=0 "$GO_BIN" tool pprof -dot "$end" 2>/dev/null | \
                dot -Tsvg -o "${svg_dir}/${profile_type}_end.svg" 2>/dev/null && \
                svg_count=$((svg_count + 1)) || true
        fi

        if [ -f "$baseline" ] && [ -f "$end" ]; then
            echo "[pprof]   ${profile_type}_diff.svg ..."
            CGO_ENABLED=0 "$GO_BIN" tool pprof -dot -base="$baseline" "$end" 2>/dev/null | \
                dot -Tsvg -o "${svg_dir}/${profile_type}_diff.svg" 2>/dev/null && \
                svg_count=$((svg_count + 1)) || true
        fi
    done

    echo "[pprof] 分析完成 → $analysis_file | SVG × ${svg_count} → ${svg_dir}/"
}

# ============================================================
# capture 子命令
# ============================================================
cmd_capture() {
    # 参数解析
    local OUTPUT_DIR=""
    local DEBUG_SOCK="$DEFAULT_DEBUG_SOCK"
    local CPU_SECONDS="$DEFAULT_CPU_SECONDS"
    local SERIES_INTERVAL="$DEFAULT_SERIES_INTERVAL"
    local SERIES_DURATION="$DEFAULT_SERIES_DURATION"
    local SERIES_PROFILES="$DEFAULT_SERIES_PROFILES"
    local CUMULATIVE_PROFILES="$DEFAULT_CUMULATIVE_PROFILES"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output-dir)       OUTPUT_DIR="$2"; shift 2 ;;
            --debug-sock)       DEBUG_SOCK="$2"; shift 2 ;;
            --cpu-seconds)      CPU_SECONDS="$2"; shift 2 ;;
            --series-interval)  SERIES_INTERVAL="$2"; shift 2 ;;
            --series-duration)  SERIES_DURATION="$2"; shift 2 ;;
            --series-profiles)  SERIES_PROFILES="$2"; shift 2 ;;
            --cumulative-profiles) CUMULATIVE_PROFILES="$2"; shift 2 ;;
            *)
                echo "错误: 未知参数: $1"
                echo "用法: $0 capture --output-dir DIR [...]"
                exit 1
                ;;
        esac
    done

    if [ -z "$OUTPUT_DIR" ]; then
        echo "错误: --output-dir 是必需参数"
        echo "用法: $0 capture --output-dir DIR [...]"
        exit 1
    fi

    # 验证 debug socket
    if [ ! -S "$DEBUG_SOCK" ]; then
        echo "[pprof] 错误: containerd debug socket 不存在: $DEBUG_SOCK"
        exit 1
    fi

    # 创建输出目录
    mkdir -p "$OUTPUT_DIR"

    IFS=',' read -ra SERIES_ARR <<< "$SERIES_PROFILES"
    IFS=',' read -ra CUMUL_ARR <<< "$CUMULATIVE_PROFILES"

    # ============================================================
    # 输出元数据
    # ============================================================
    local METADATA="${OUTPUT_DIR}/metadata.txt"
    cat > "$METADATA" <<EOF
抓取时间: $(date '+%Y-%m-%d %H:%M:%S')
Debug Socket: $DEBUG_SOCK
CPU 采样时长: ${CPU_SECONDS}s
瞬时 Profile: ${SERIES_PROFILES}
    间隔: ${SERIES_INTERVAL}s
    总时长: ${SERIES_DURATION}s
累积 Profile: ${CUMULATIVE_PROFILES}
EOF

    echo ""
    echo "[pprof] 开始抓取 containerd profile..."
    echo "[pprof] 输出目录: $OUTPUT_DIR"
    echo "[pprof] CPU 采样: ${CPU_SECONDS}s"
    echo "[pprof] 瞬时序列: ${SERIES_PROFILES} (间隔 ${SERIES_INTERVAL}s, 总 ${SERIES_DURATION}s)"
    echo "[pprof] 累积做差: ${CUMULATIVE_PROFILES}"
    echo ""

    # ============================================================
    # Step 1: 抓取累积型 profile 的基线
    # ============================================================
    echo "[pprof] Step 1/5: 抓取累积 profile 基线..."
    for p in "${CUMUL_ARR[@]}"; do
        fetch_profile "$p" "${OUTPUT_DIR}/${p}_baseline.pprof" || true
        echo "[pprof]   基线: ${p}_baseline.pprof ($(wc -c < "${OUTPUT_DIR}/${p}_baseline.pprof" 2>/dev/null || echo 0) bytes)"
    done
    echo ""

    # ============================================================
    # Step 2: 后台启动 CPU profile（阻塞 N 秒）
    # ============================================================
    echo "[pprof] Step 2/5: 启动 CPU profile (${CPU_SECONDS}s 采样)..."
    curl -s --max-time $((CPU_SECONDS + 30)) --unix-socket "$DEBUG_SOCK" \
        "http://localhost/debug/pprof/profile?seconds=${CPU_SECONDS}" \
        -o "${OUTPUT_DIR}/cpu.pprof" &
    CPU_PID=$!
    echo "[pprof]   CPU profile PID: $CPU_PID"
    sleep 1  # 给 CPU profiler 一点启动时间

    # ============================================================
    # Step 3: 循环抓取瞬时 profile（与 CPU profile 并行）
    # ============================================================
    echo "[pprof] Step 3/5: 开始瞬时 profile 时间序列抓取..."
    local SEQ=0
    local DEADLINE=$((SECONDS + SERIES_DURATION))

    while [ $SECONDS -lt $DEADLINE ]; do
        local TS=$(timestamp_ms)

        # 并行抓取所有瞬时 profile，只回收这批 PID（不能用无参数 wait，否则会误回收 CPU profile）
        BATCH_PIDS=()
        for p in "${SERIES_ARR[@]}"; do
            local profile_dir="${OUTPUT_DIR}/${p}"
            mkdir -p "$profile_dir"
            local seq_padded=$(printf "%04d" "$SEQ")
            fetch_profile "$p" "${profile_dir}/${seq_padded}_${TS}.pprof" &
            BATCH_PIDS+=($!)
        done
        for bp in "${BATCH_PIDS[@]}"; do
            wait "$bp" || true
        done

        echo "[pprof]   seq=$SEQ | ${SERIES_PROFILES} 已抓取 (ts=$TS)"

        SEQ=$((SEQ + 1))

        # 检查是否还有时间（不等最后可能超出的间隔）
        if [ $((SECONDS + SERIES_INTERVAL)) -ge $DEADLINE ]; then
            break
        fi
        sleep "$SERIES_INTERVAL"
    done

    echo "[pprof]   共抓取 $SEQ 轮"
    echo ""

    # ============================================================
    # Step 4: 等待 CPU profile 完成
    # ============================================================
    echo "[pprof] Step 4/5: 等待 CPU profile 完成..."
    if wait "$CPU_PID"; then
        echo "[pprof]   CPU profile 完成 ($(wc -c < "${OUTPUT_DIR}/cpu.pprof" 2>/dev/null || echo 0) bytes)"
    else
        echo "[pprof]   警告: CPU profile 抓取失败"
    fi
    echo ""

    # ============================================================
    # Step 5: 抓取累积型 profile 的结束快照
    # ============================================================
    echo "[pprof] Step 5/5: 抓取累积 profile 结束快照..."
    for p in "${CUMUL_ARR[@]}"; do
        fetch_profile "$p" "${OUTPUT_DIR}/${p}_end.pprof" || true
        echo "[pprof]   结束: ${p}_end.pprof ($(wc -c < "${OUTPUT_DIR}/${p}_end.pprof" 2>/dev/null || echo 0) bytes)"
    done
    echo ""

    # ============================================================
    # 完成
    # ============================================================
    echo "[pprof] ================================================"
    echo "[pprof] 抓取完成"
    echo "[pprof] ================================================"
    echo "[pprof] 输出文件:"
    find "$OUTPUT_DIR" -type f -exec ls -lh {} \; | sed 's/^/[pprof]   /'
    echo ""
}

# ============================================================
# 主入口
# ============================================================
usage() {
    echo "用法: $0 <command> [options]"
    echo ""
    echo "命令:"
    echo "  capture   抓取 containerd pprof profile"
    echo "  analyze   解析已抓取的 profile"
    echo ""
    echo "capture 选项:"
    echo "  --output-dir DIR          输出目录（必需）"
    echo "  --debug-sock PATH         containerd debug socket（默认: $DEFAULT_DEBUG_SOCK）"
    echo "  --cpu-seconds SEC         CPU profile 采样时长（默认: $DEFAULT_CPU_SECONDS）"
    echo "  --series-interval SEC     瞬时 profile 抓取间隔（默认: $DEFAULT_SERIES_INTERVAL）"
    echo "  --series-duration SEC     瞬时 profile 抓取总时长（默认: $DEFAULT_SERIES_DURATION）"
    echo "  --series-profiles LIST    瞬时时间序列 profile（默认: $DEFAULT_SERIES_PROFILES）"
    echo "  --cumulative-profiles LIST 累积型 profile（默认: $DEFAULT_CUMULATIVE_PROFILES）"
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
