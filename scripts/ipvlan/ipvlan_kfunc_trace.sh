#!/usr/bin/env bash
# 内核函数时延抓取（ftrace function_graph），供 bench 在创建窗口起停。
#
# 用法:
#   sudo $0 capture-live --output-dir DIR [--funcs f1,f2,...] [--cpus CPUS] [--affinity CPU]
#   sudo kill -TERM <pid>   # 结束采样并写出 trace + summary
#
# 示例:
#   sudo $0 capture-live --output-dir /tmp/ktrace --cpus 1
#   sudo $0 capture-live --output-dir /tmp/ktrace --cpus 1-3 --funcs ipvlan_link_new,__rtnl_newlink
#
set -euo pipefail

TRACE_ROOT="/sys/kernel/tracing"
DEFAULT_FUNCS="ipvlan_link_new,__rtnl_newlink,rtnl_newlink,register_netdevice"
SAVED_CPUMASK=""

usage() {
    cat <<EOF
用法: $0 <command> [options]

命令:
  capture-live   采样直到 SIGTERM/SIGINT，写出 function_graph 与时延摘要

选项:
  --output-dir DIR     输出目录（必需）
  --funcs LIST         逗号分隔函数名（默认: ${DEFAULT_FUNCS}）
  --cpus CPUS          只采这些 CPU 的 trace（tracing_cpumask；如 1 或 0-3,8）
                       默认: 全部 CPU
  --affinity CPU       本脚本绑核（默认: 0；与 --cpus 独立）
  --graph-depth N      function_graph 最大深度（默认: 3；过深易丢时延）
  -h, --help           帮助
EOF
}

die() { echo "错误: $*" >&2; exit 1; }

require_tracefs() {
    [[ -d "$TRACE_ROOT" ]] || die "未找到 $TRACE_ROOT（需 root 且内核开启 ftrace）"
    [[ -w "$TRACE_ROOT/tracing_on" ]] || die "无法写 $TRACE_ROOT（请 sudo）"
}

funcs_to_lines() {
    local s=$1
    s=${s//,/ }
    # shellcheck disable=SC2086
    printf '%s\n' $s
}

# 展开 "0-3,8" → 一行一个 CPU 号
expand_cpus() {
    local spec=$1
    local part a b i
    IFS=',' read -ra parts <<<"$spec"
    for part in "${parts[@]}"; do
        part=${part// /}
        [[ -z "$part" ]] && continue
        if [[ "$part" =~ ^([0-9]+)-([0-9]+)$ ]]; then
            a=${BASH_REMATCH[1]}
            b=${BASH_REMATCH[2]}
            (( a <= b )) || die "无效 CPU 范围: $part"
            for ((i = a; i <= b; i++)); do
                echo "$i"
            done
        elif [[ "$part" =~ ^[0-9]+$ ]]; then
            echo "$part"
        else
            die "无效 CPU 描述: $part"
        fi
    done
}

# CPU 列表 → tracing_cpumask（高字在前，末字为 CPU0-31）
cpus_to_cpumask() {
    local spec=$1
    local nbits words
    nbits=$(nproc --all 2>/dev/null || nproc)
    words=$(( (nbits + 31) / 32 ))
    # 用 awk 组 bitmask，避免 bash 大整数坑
    expand_cpus "$spec" | awk -v words="$words" -v nbits="$nbits" '
    {
      c = $1 + 0
      if (c < 0 || c >= nbits) {
        print "错误: CPU " c " 超出范围 [0," nbits ")" > "/dev/stderr"
        exit 1
      }
      bit[c] = 1
    }
    END {
      for (w = words - 1; w >= 0; w--) {
        v = 0
        for (b = 0; b < 32; b++) {
          c = w * 32 + b
          if (bit[c]) v += 2 ^ b
        }
        printf "%08x%s", v, (w > 0 ? "," : "")
      }
      printf "\n"
    }
    '
}

ftrace_reset() {
    echo 0 >"${TRACE_ROOT}/tracing_on" 2>/dev/null || true
    echo nop >"${TRACE_ROOT}/current_tracer" 2>/dev/null || true
    echo >"${TRACE_ROOT}/set_graph_function" 2>/dev/null || true
    echo >"${TRACE_ROOT}/set_ftrace_filter" 2>/dev/null || true
    echo >"${TRACE_ROOT}/set_ftrace_pid" 2>/dev/null || true
    echo >"${TRACE_ROOT}/trace" 2>/dev/null || true
    if [[ -w "${TRACE_ROOT}/max_graph_depth" ]]; then
        echo 0 >"${TRACE_ROOT}/max_graph_depth" 2>/dev/null || true
    fi
    if [[ -w "${TRACE_ROOT}/options/funcgraph-tail" ]]; then
        echo 0 >"${TRACE_ROOT}/options/funcgraph-tail" 2>/dev/null || true
    fi
    if [[ -n "$SAVED_CPUMASK" && -w "${TRACE_ROOT}/tracing_cpumask" ]]; then
        echo "$SAVED_CPUMASK" >"${TRACE_ROOT}/tracing_cpumask" 2>/dev/null || true
        SAVED_CPUMASK=""
    fi
}

parse_summary() {
    local trace_file=$1
    local out_file=$2
    shift 2
    local allow
    allow=$(printf '%s\n' "$@")
    ALLOW_FUNCS="$allow" awk '
    BEGIN {
      n = split(ENVIRON["ALLOW_FUNCS"], a, "\n")
      for (i = 1; i <= n; i++) if (a[i] != "") allow[a[i]] = 1
    }
    function add(fn, us) {
      if (!(fn in allow)) return
      cnt[fn]++
      sum[fn] += us
      if (!(fn in min) || us < min[fn]) min[fn] = us
      if (us > max[fn]) max[fn] = us
    }
    {
      # 1) 闭合:  123.4 us | } /* func ... */
      if (match($0, /([0-9]+(\.[0-9]+)?) us[[:space:]]+\|[[:space:]]*\}[[:space:]]*\/\*[[:space:]]*([a-zA-Z0-9_]+)/, m)) {
        add(m[3], m[1] + 0)
        next
      }
      # 2) 叶子:  123.4 us | func [mod]();  或  123.4 us | func();
      if (match($0, /([0-9]+(\.[0-9]+)?) us[[:space:]]+\|[[:space:]]*([a-zA-Z0-9_]+)[[:space:]]*(\[[^]]*\])?[[:space:]]*\(\)/, m)) {
        add(m[3], m[1] + 0)
        next
      }
    }
    END {
      printf "%-28s %8s %12s %12s %12s %12s\n", "function", "count", "total_us", "avg_us", "min_us", "max_us"
      printf "%-28s %8s %12s %12s %12s %12s\n", "--------", "-----", "--------", "------", "------", "------"
      for (fn in cnt) {
        printf "%-28s %8d %12.3f %12.3f %12.3f %12.3f\n",
          fn, cnt[fn], sum[fn], sum[fn]/cnt[fn], min[fn], max[fn]
      }
    }
    ' "$trace_file" >"$out_file"
}

cmd_capture_live() {
    local OUTPUT_DIR=""
    local FUNCS="$DEFAULT_FUNCS"
    local AFFINITY=0
    local CPUS=""
    local GRAPH_DEPTH=3

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output-dir)   OUTPUT_DIR=$2; shift 2 ;;
            --funcs)        FUNCS=$2; shift 2 ;;
            --cpus)         CPUS=$2; shift 2 ;;
            --affinity)     AFFINITY=$2; shift 2 ;;
            --graph-depth)  GRAPH_DEPTH=$2; shift 2 ;;
            -h|--help)      usage; exit 0 ;;
            *) die "未知参数: $1" ;;
        esac
    done

    [[ -n "$OUTPUT_DIR" ]] || die "capture-live 需要 --output-dir"
    require_tracefs
    [[ "$GRAPH_DEPTH" =~ ^[1-9][0-9]*$ ]] || die "--graph-depth 须为正整数"

    if command -v taskset &>/dev/null; then
        if [[ "${KTRACE_AFFINITY_APPLIED:-0}" != 1 ]]; then
            export KTRACE_AFFINITY_APPLIED=1
            local -a reexec=(
                bash "$0" capture-live
                --output-dir "$OUTPUT_DIR"
                --funcs "$FUNCS"
                --affinity "$AFFINITY"
                --graph-depth "$GRAPH_DEPTH"
            )
            [[ -n "$CPUS" ]] && reexec+=(--cpus "$CPUS")
            exec taskset -c "$AFFINITY" env KTRACE_AFFINITY_APPLIED=1 "${reexec[@]}"
        fi
    fi

    mkdir -p "$OUTPUT_DIR"
    rm -f "${OUTPUT_DIR}/capture.ready" "${OUTPUT_DIR}/function_graph.txt" \
        "${OUTPUT_DIR}/summary.txt" "${OUTPUT_DIR}/ktrace.pid"

    local f
    while read -r f; do
        [[ -z "$f" ]] && continue
        if ! grep -qE "^${f}( |\$)" "${TRACE_ROOT}/available_filter_functions"; then
            echo "警告: 函数不在 available_filter_functions: $f（将跳过）" >&2
        fi
    done < <(funcs_to_lines "$FUNCS")

    ftrace_reset

    local ok_funcs=()
    while read -r f; do
        [[ -z "$f" ]] && continue
        if grep -qE "^${f}( |\$)" "${TRACE_ROOT}/available_filter_functions"; then
            ok_funcs+=("$f")
            echo "$f" >>"${TRACE_ROOT}/set_graph_function"
        fi
    done < <(funcs_to_lines "$FUNCS")

    (( ${#ok_funcs[@]} > 0 )) || die "没有可用的 trace 函数"

    local cpumask_desc="all"
    if [[ -n "$CPUS" ]]; then
        [[ -w "${TRACE_ROOT}/tracing_cpumask" ]] || die "无法写 tracing_cpumask"
        SAVED_CPUMASK=$(cat "${TRACE_ROOT}/tracing_cpumask")
        local mask
        mask=$(cpus_to_cpumask "$CPUS") || die "无法解析 --cpus $CPUS"
        echo "$mask" >"${TRACE_ROOT}/tracing_cpumask"
        cpumask_desc="$CPUS (mask=$mask)"
    fi

    printf '%s\n' "${ok_funcs[@]}" >"${OUTPUT_DIR}/funcs.txt"

    cat >"${OUTPUT_DIR}/metadata.txt" <<EOF
抓取时间: $(date '+%Y-%m-%d %H:%M:%S')
模式: capture-live (ftrace function_graph)
函数: ${ok_funcs[*]}
cpus: ${cpumask_desc}
affinity: ${AFFINITY}
graph_depth: ${GRAPH_DEPTH}
内核: $(uname -r)
EOF

    echo function_graph >"${TRACE_ROOT}/current_tracer"
    # 闭合行默认不带函数名；打开 tail 才是:  } /* __rtnl_newlink */
    if [[ -w "${TRACE_ROOT}/options/funcgraph-tail" ]]; then
        echo 1 >"${TRACE_ROOT}/options/funcgraph-tail" 2>/dev/null || true
    fi
    # 创建路径很深，限制深度以免缓冲爆掉丢闭合时延；仍记录根函数总耗时
    if [[ -w "${TRACE_ROOT}/max_graph_depth" ]]; then
        echo "${GRAPH_DEPTH}" >"${TRACE_ROOT}/max_graph_depth" 2>/dev/null || true
    fi
    if [[ -w "${TRACE_ROOT}/buffer_size_kb" ]]; then
        echo 16384 >"${TRACE_ROOT}/buffer_size_kb" 2>/dev/null || true
    fi
    echo >"${TRACE_ROOT}/trace"
    echo 1 >"${TRACE_ROOT}/tracing_on"

    echo $$ >"${OUTPUT_DIR}/ktrace.pid"
    date +%s >"${OUTPUT_DIR}/capture.ready"
    echo "[ktrace] capture-live 启动 funcs=${ok_funcs[*]} cpus=${cpumask_desc} affinity=${AFFINITY} depth=${GRAPH_DEPTH} → ${OUTPUT_DIR}"

    _stopping=0
    _stop() {
        if [[ "$_stopping" -eq 1 ]]; then
            return
        fi
        _stopping=1
        echo "[ktrace] 收到停止信号，导出 trace..."
        echo 0 >"${TRACE_ROOT}/tracing_on" 2>/dev/null || true

        cp "${TRACE_ROOT}/trace" "${OUTPUT_DIR}/function_graph.txt" 2>/dev/null || \
            cat "${TRACE_ROOT}/trace" >"${OUTPUT_DIR}/function_graph.txt"

        local -a funcs_arr=()
        if [[ -f "${OUTPUT_DIR}/funcs.txt" ]]; then
            mapfile -t funcs_arr <"${OUTPUT_DIR}/funcs.txt"
        fi
        if (( ${#funcs_arr[@]} > 0 )); then
            parse_summary "${OUTPUT_DIR}/function_graph.txt" "${OUTPUT_DIR}/summary.txt" "${funcs_arr[@]}"
            local pat
            pat=$(IFS='|'; echo "${funcs_arr[*]}")
            grep -E "$pat" "${OUTPUT_DIR}/function_graph.txt" >"${OUTPUT_DIR}/function_graph.filtered.txt" || true
        else
            parse_summary "${OUTPUT_DIR}/function_graph.txt" "${OUTPUT_DIR}/summary.txt"
            : >"${OUTPUT_DIR}/function_graph.filtered.txt"
        fi

        ftrace_reset
        rm -f "${OUTPUT_DIR}/capture.ready" "${OUTPUT_DIR}/ktrace.pid"

        echo "[ktrace] summary:"
        cat "${OUTPUT_DIR}/summary.txt" || true
        echo "[ktrace] 完成 → ${OUTPUT_DIR}"
        exit 0
    }
    trap '_stop' INT TERM

    while true; do
        sleep 3600 &
        wait $! || true
    done
}

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

cmd=$1
shift
case "$cmd" in
    capture-live) cmd_capture_live "$@" ;;
    -h|--help|help) usage ;;
    *)
        echo "错误: 未知命令 '$cmd'" >&2
        usage >&2
        exit 1
        ;;
esac
