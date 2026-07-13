#!/bin/bash
# -*- coding: utf-8 -*-
#
# 系统资源采集脚本
#
# 用法:
#     ./system_resources.sh metadata [OPTIONS]     # 静态环境快照
#     ./system_resources.sh capture [OPTIONS]      # 时序采样
#     ./system_resources.sh summarize <OUTPUT_DIR> # 汇总分析
#
# capture 选项:
#     --output-dir DIR       输出目录（必需）
#     --duration SEC         采样时长（默认: 30）
#     --interval SEC         采样间隔（默认: 0.1）
#     --cpus SPEC            Worker CPU 列表 (0-7 或 0,2,4)
#     --numa NODE            绑定的 NUMA 节点（用于 NUMA 指标）
#
# metadata 选项:
#     --output FILE          输出文件（必需）
#     --cpus SPEC            Worker CPU 列表
#     --numa NODE            NUMA 节点
#     --proc-count K         进程数
#     --passthru-args STR    透传参数字符串
#
# 示例:
#     ./system_resources.sh metadata --output results/multi/resources/metadata.json \
#         --cpus 0-7 --numa 0 --proc-count 4
#     ./system_resources.sh capture --output-dir results/multi/resources \
#         --duration 60 --interval 1 --cpus 0-7
#     ./system_resources.sh summarize results/multi/resources
#     ./system_resources.sh analyze results/multi
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAMPLER="${SCRIPT_DIR}/resource_sampler.py"
ANALYZER="${SCRIPT_DIR}/resource_analyzer.py"

if [ ! -f "$SAMPLER" ]; then
    echo "错误: 未找到 $SAMPLER" >&2
    exit 1
fi

cmd="${1:-}"
shift || true

case "$cmd" in
    metadata)
        OUTPUT=""
        CPUS=""
        NUMA=0
        PROC_COUNT=1
        PASSTHRU=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --output) OUTPUT="$2"; shift 2 ;;
                --cpus) CPUS="$2"; shift 2 ;;
                --numa) NUMA="$2"; shift 2 ;;
                --proc-count) PROC_COUNT="$2"; shift 2 ;;
                --passthru-args) PASSTHRU="$2"; shift 2 ;;
                *) echo "未知参数: $1" >&2; exit 1 ;;
            esac
        done
        if [ -z "$OUTPUT" ]; then
            echo "用法: $0 metadata --output FILE [--cpus SPEC] [--numa N] [--proc-count K]" >&2
            exit 1
        fi
        python3 "$SAMPLER" metadata \
            --output "$OUTPUT" \
            --cpus "$CPUS" \
            --numa "$NUMA" \
            --proc-count "$PROC_COUNT" \
            --passthru-args "$PASSTHRU"
        ;;

    capture)
        OUTPUT_DIR=""
        DURATION=30
        INTERVAL=0.1
        CPUS=""
        WORKER_CPUS=""
        SANDBOX_CPUS=""
        NUMA=""
        while [[ $# -gt 0 ]]; do
            case "$1" in
                --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
                --duration) DURATION="$2"; shift 2 ;;
                --interval) INTERVAL="$2"; shift 2 ;;
                --cpus) CPUS="$2"; shift 2 ;;
                --worker-cpus) WORKER_CPUS="$2"; shift 2 ;;
                --sandbox-cpus) SANDBOX_CPUS="$2"; shift 2 ;;
                --numa) NUMA="$2"; shift 2 ;;
                *) echo "未知参数: $1" >&2; exit 1 ;;
            esac
        done
        if [ -z "$OUTPUT_DIR" ]; then
            echo "用法: $0 capture --output-dir DIR [--duration SEC] [--interval SEC] [--worker-cpus SPEC] [--sandbox-cpus SPEC] [--numa N]" >&2
            exit 1
        fi
        if [ -z "$WORKER_CPUS" ]; then
            WORKER_CPUS="$CPUS"
        fi
        CAP_ARGS=(
            --output-dir "$OUTPUT_DIR"
            --duration "$DURATION"
            --interval "$INTERVAL"
            --worker-cpus "$WORKER_CPUS"
            --sandbox-cpus "$SANDBOX_CPUS"
        )
        if [ -n "$NUMA" ]; then
            CAP_ARGS+=(--numa "$NUMA")
        fi
        python3 "$SAMPLER" capture "${CAP_ARGS[@]}"
        ;;

    summarize)
        if [ $# -lt 1 ]; then
            echo "用法: $0 summarize <OUTPUT_DIR>" >&2
            exit 1
        fi
        python3 "$SAMPLER" summarize --output-dir "$1"
        ;;

    analyze)
        if [ $# -lt 1 ]; then
            echo "用法: $0 analyze <RESULT_DIR>" >&2
            exit 1
        fi
        if [ ! -f "$ANALYZER" ]; then
            echo "错误: 未找到 $ANALYZER" >&2
            exit 1
        fi
        python3 "$ANALYZER" "$1"
        ;;

    *)
        echo "用法: $0 {metadata|capture|summarize|analyze} [OPTIONS]" >&2
        echo ""
        echo "  metadata   写入静态环境快照 (metadata.json)"
        echo "  capture    采样时序数据 (timeseries.jsonl)"
        echo "  summarize  生成汇总 (summary.json)"
        echo "  analyze    关联分析 benchmark + 资源 (report.md, charts/*.svg)"
        exit 1
        ;;
esac
