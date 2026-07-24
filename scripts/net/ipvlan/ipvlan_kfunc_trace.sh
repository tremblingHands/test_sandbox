#!/usr/bin/env bash
# 内核函数时延抓取（ftrace function_graph），供 bench 在创建窗口起停。
#
# 两种过滤模式（--mode）:
#   graph  - set_graph_function：从关心的函数起画图，展开子调用（噪声多，看完整路径）
#   filter - set_ftrace_filter：只记录白名单函数，彼此嵌套仍保留（干净）
#            停止时额外生成 summary_tree.txt（同根合成树 + paths）
#
# 用法:
#   sudo $0 capture-live --output-dir DIR [--mode graph|filter] [--funcs ...] [--cpus CPUS]
#   sudo kill -TERM <pid>
#
# 示例:
#   sudo $0 capture-live --output-dir /tmp/ktrace --cpus 1 --mode filter
#   sudo $0 capture-live --output-dir /tmp/ktrace --cpus 1 --mode graph --graph-depth 3
#
set -euo pipefail

TRACE_ROOT="/sys/kernel/tracing"
DEFAULT_FUNCS="ipvlan_link_new,__rtnl_newlink,rtnl_newlink,register_netdevice"
DEFAULT_MODE="graph"
DEFAULT_FUNCS_MAX=256
SAVED_CPUMASK=""

usage() {
    cat <<EOF
用法: $0 <command> [options]

命令:
  capture-live   采样直到 SIGTERM/SIGINT，写出 function_graph 与时延摘要

选项:
  --output-dir DIR     输出目录（必需）
  --mode MODE          graph | filter（默认: ${DEFAULT_MODE}）
                         graph:  set_graph_function，展开子调用
                         filter: set_ftrace_filter，只打白名单，保留相互嵌套
  --funcs LIST         逗号分隔；精确名或 ftrace glob（如 ipvlan_*；默认: ${DEFAULT_FUNCS}）
                       原样写入内核，再读回展开列表供 summary/tree
  --funcs-max N        读回展开后函数数上限（默认: ${DEFAULT_FUNCS_MAX}）
  --cpus CPUS          只采这些 CPU（tracing_cpumask；默认全部）
  --affinity CPU       本脚本绑核（默认: 0；与 --cpus 独立）
  --graph-depth N      graph 默认 3；filter 默认 0（不限制）。仅影响 max_graph_depth
  -h, --help           帮助

输出:
  funcs_patterns.txt           原始 --funcs 条目
  funcs.txt                    内核展开后的具体函数名
  function_graph.txt           原始 function_graph
  function_graph.filtered.txt  仅含白名单函数的行
  summary.txt                  扁平时延统计
  summary_tree.txt             仅 --mode filter：合成调用树 + paths/edges
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

# 将 pattern（精确名或 ftrace glob）写入 filter 文件；失败则警告
ftrace_write_patterns() {
    local target=$1
    shift
    local pat rc
    local ok=0
    for pat in "$@"; do
        [[ -z "$pat" ]] && continue
        rc=0
        echo "$pat" >>"${TRACE_ROOT}/${target}" 2>"${OUTPUT_DIR:-/tmp}/.ktrace_filt_err" || rc=$?
        if [[ "$rc" -eq 0 ]]; then
            ok=$((ok + 1))
            echo "[ktrace] pattern → ${target}: $pat"
        else
            echo "警告: ftrace 拒绝 '$pat' → ${target}: $(tr '\n' ' ' <"${OUTPUT_DIR:-/tmp}/.ktrace_filt_err" 2>/dev/null)" >&2
        fi
    done
    rm -f "${OUTPUT_DIR:-/tmp}/.ktrace_filt_err"
    (( ok > 0 )) || return 1
    return 0
}

# 读回内核展开后的函数名（第一列，去重）
ftrace_read_funcs() {
    local target=$1
    awk 'NF && $1 !~ /^#/ { print $1 }' "${TRACE_ROOT}/${target}" | sort -u
}

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

cpus_to_cpumask() {
    local spec=$1
    local nbits words
    nbits=$(nproc --all 2>/dev/null || nproc)
    words=$(( (nbits + 31) / 32 ))
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
    echo >"${TRACE_ROOT}/set_ftrace_notrace" 2>/dev/null || true
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
      if (match($0, /([0-9]+(\.[0-9]+)?) us[[:space:]]+\|[[:space:]]*\}[[:space:]]*\/\*[[:space:]]*([a-zA-Z0-9_]+)/, m)) {
        add(m[3], m[1] + 0)
        next
      }
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

# filter 模式：同根合成树 + paths 列表 → summary_tree.txt
parse_tree() {
    local trace_file=$1
    local out_file=$2
    local funcs_file=$3
    python3 - "$trace_file" "$out_file" "$funcs_file" <<'PY'
from __future__ import print_function
import re
import sys
from collections import defaultdict

trace_file, out_file, funcs_file = sys.argv[1], sys.argv[2], sys.argv[3]
allow = set()
with open(funcs_file) as f:
    for line in f:
        name = line.strip()
        if name:
            allow.add(name)

re_open = re.compile(
    r'\|\s*([A-Za-z0-9_]+)\s*(?:\[[^\]]*\])?\s*\(\)\s*\{'
)
re_leaf = re.compile(
    r'([0-9]+(?:\.[0-9]+)?)\s+us\s+\|\s*([A-Za-z0-9_]+)\s*(?:\[[^\]]*\])?\s*\(\)\s*;'
)
re_close = re.compile(
    r'([0-9]+(?:\.[0-9]+)?)\s+us\s+\|\s*\}\s*/\*\s*([A-Za-z0-9_]+)'
)

stack = []  # {name, had_child}
edges = defaultdict(int)       # (parent, child) -> count
paths = defaultdict(int)       # tuple path -> count
node_n = defaultdict(int)
node_sum = defaultdict(float)
node_min = {}
node_max = {}

def add_node(name, us):
    if name not in allow:
        return
    node_n[name] += 1
    node_sum[name] += us
    if name not in node_min or us < node_min[name]:
        node_min[name] = us
    if name not in node_max or us > node_max[name]:
        node_max[name] = us

def push(name):
    if name not in allow:
        return
    if stack:
        edges[(stack[-1]["name"], name)] += 1
        stack[-1]["had_child"] = True
    stack.append({"name": name, "had_child": False})

def on_leaf(name, us):
    if name not in allow:
        return
    add_node(name, us)
    if stack:
        edges[(stack[-1]["name"], name)] += 1
        stack[-1]["had_child"] = True
        path = tuple(x["name"] for x in stack) + (name,)
    else:
        path = (name,)
    paths[path] += 1

def on_close(name, us):
    if name not in allow:
        return
    add_node(name, us)
    # 向上找到匹配帧（容错）
    idx = None
    for i in range(len(stack) - 1, -1, -1):
        if stack[i]["name"] == name:
            idx = i
            break
    if idx is None:
        return
    # 丢掉不匹配的尾部
    while len(stack) > idx + 1:
        stack.pop()
    frame = stack.pop()
    if not frame["had_child"]:
        path = tuple(x["name"] for x in stack) + (name,)
        paths[path] += 1

with open(trace_file) as f:
    for line in f:
        if "FUNCTION CALLS" in line or line.startswith("#"):
            continue
        m = re_leaf.search(line)
        if m and "{" not in line.split("|", 1)[-1]:
            on_leaf(m.group(2), float(m.group(1)))
            continue
        m = re_close.search(line)
        if m:
            on_close(m.group(2), float(m.group(1)))
            continue
        m = re_open.search(line)
        if m:
            push(m.group(1))
            continue

# 根：作为 path[0] 出现过的函数
root_count = defaultdict(int)
for path, n in paths.items():
    if path:
        root_count[path[0]] += n

children = defaultdict(set)
for (p, c), n in edges.items():
    children[p].add(c)

def avg_of(name):
    if node_n[name]:
        return node_sum[name] / node_n[name]
    return 0.0

def stats_of(name):
    return (
        node_n[name],
        node_sum[name],
        avg_of(name),
        node_min.get(name, 0.0),
        node_max.get(name, 0.0),
    )

# 先收集 (prefix, name)，再按固定统计列对齐打印
NAME_COL_MAX = 56  # 前缀+函数名最大宽度，超出截断

def tree_prefix(prefix_parts):
    if not prefix_parts:
        return ""
    parts = []
    for last in prefix_parts[:-1]:
        parts.append("   " if last else "│  ")
    parts.append("└─ " if prefix_parts[-1] else "├─ ")
    return "".join(parts)

def collect_rows(name, prefix_parts, visiting, rows):
    rows.append((tree_prefix(prefix_parts), name))
    if name in visiting:
        if children.get(name):
            rows.append((tree_prefix(prefix_parts + [True]), "(cycle)"))
        return
    visiting.add(name)
    kids = sorted(children.get(name, ()), key=lambda c: (-edges[(name, c)], c))
    for i, kid in enumerate(kids):
        collect_rows(kid, prefix_parts + [i == len(kids) - 1], visiting, rows)
    visiting.discard(name)

roots = sorted(root_count.keys(), key=lambda r: (-root_count[r], r))
if not roots:
    kids_all = {c for _, c in edges}
    roots = sorted((set(node_n) - kids_all) or set(node_n))

rows = []
for i, r in enumerate(roots):
    if i:
        rows.append(("", ""))  # 空行分隔多根
    collect_rows(r, [], set(), rows)

name_width = 8  # "function"
for prefix, name in rows:
    if not name:
        continue
    name_width = max(name_width, len(prefix) + len(name))
name_width = min(name_width, NAME_COL_MAX)

def fmt_name_cell(prefix, name):
    raw = prefix + name
    if len(raw) <= name_width:
        return raw.ljust(name_width)
    room = name_width - len(prefix)
    if room <= 1:
        return raw[: name_width - 1] + "…"
    if len(name) > room:
        name = name[: max(1, room - 1)] + "…"
    return (prefix + name).ljust(name_width)

HDR = "%s  %6s  %12s  %10s  %10s  %10s" % (
    "function".ljust(name_width), "n", "total_us", "avg_us", "min_us", "max_us"
)
SEP = "%s  %6s  %12s  %10s  %10s  %10s" % (
    "-" * name_width, "------", "------------", "----------", "----------", "----------"
)

lines = [
    "call tree (allowlist; inclusive us; same root merged)",
    "",
    HDR,
    SEP,
]

for prefix, name in rows:
    if not name:
        lines.append("")
        continue
    cell = fmt_name_cell(prefix, name)
    if name == "(cycle)":
        lines.append(
            "%s  %6s  %12s  %10s  %10s  %10s" % (cell, "-", "-", "-", "-", "-")
        )
        continue
    n, total, avg, mn, mx = stats_of(name)
    lines.append(
        "%s  %6d  %12.3f  %10.3f  %10.3f  %10.3f" % (cell, n, total, avg, mn, mx)
    )

lines.append("")
lines.append("paths:")
if not paths:
    lines.append("  (none)")
else:
    for path, n in sorted(paths.items(), key=lambda x: (-x[1], x[0])):
        lines.append("  %s    n=%d" % (" > ".join(path), n))

lines.append("")
lines.append("edges:")
if not edges:
    lines.append("  (none)")
else:
    for (p, c), n in sorted(edges.items(), key=lambda x: (-x[1], x[0])):
        lines.append("  %s -> %s    n=%d" % (p, c, n))

with open(out_file, "w") as f:
    f.write("\n".join(lines) + "\n")
PY
}

cmd_capture_live() {
    local OUTPUT_DIR=""
    local FUNCS="$DEFAULT_FUNCS"
    local FUNCS_MAX="$DEFAULT_FUNCS_MAX"
    local AFFINITY=0
    local CPUS=""
    local GRAPH_DEPTH=""
    local MODE="$DEFAULT_MODE"

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output-dir)   OUTPUT_DIR=$2; shift 2 ;;
            --funcs)        FUNCS=$2; shift 2 ;;
            --funcs-max)    FUNCS_MAX=$2; shift 2 ;;
            --cpus)         CPUS=$2; shift 2 ;;
            --affinity)     AFFINITY=$2; shift 2 ;;
            --graph-depth)  GRAPH_DEPTH=$2; shift 2 ;;
            --mode)         MODE=$2; shift 2 ;;
            -h|--help)      usage; exit 0 ;;
            *) die "未知参数: $1" ;;
        esac
    done

    [[ -n "$OUTPUT_DIR" ]] || die "capture-live 需要 --output-dir"
    require_tracefs
    case "$MODE" in
        graph|filter) ;;
        *) die "--mode 须为 graph 或 filter，当前: $MODE" ;;
    esac
    if [[ -z "$GRAPH_DEPTH" ]]; then
        if [[ "$MODE" == "filter" ]]; then
            GRAPH_DEPTH=0
        else
            GRAPH_DEPTH=3
        fi
    fi
    [[ "$GRAPH_DEPTH" =~ ^[0-9]+$ ]] || die "--graph-depth 须为非负整数"
    if [[ "$MODE" == "graph" && "$GRAPH_DEPTH" -eq 0 ]]; then
        die "--mode graph 时 --graph-depth 须为正整数（0 仅用于 filter 不限制）"
    fi
    [[ "$FUNCS_MAX" =~ ^[1-9][0-9]*$ ]] || die "--funcs-max 须为正整数"

    if command -v taskset &>/dev/null; then
        if [[ "${KTRACE_AFFINITY_APPLIED:-0}" != 1 ]]; then
            export KTRACE_AFFINITY_APPLIED=1
            local -a reexec=(
                bash "$0" capture-live
                --output-dir "$OUTPUT_DIR"
                --funcs "$FUNCS"
                --funcs-max "$FUNCS_MAX"
                --affinity "$AFFINITY"
                --graph-depth "$GRAPH_DEPTH"
                --mode "$MODE"
            )
            [[ -n "$CPUS" ]] && reexec+=(--cpus "$CPUS")
            exec taskset -c "$AFFINITY" env KTRACE_AFFINITY_APPLIED=1 "${reexec[@]}"
        fi
    fi

    mkdir -p "$OUTPUT_DIR"
    rm -f "${OUTPUT_DIR}/capture.ready" "${OUTPUT_DIR}/function_graph.txt" \
        "${OUTPUT_DIR}/summary.txt" "${OUTPUT_DIR}/summary_tree.txt" \
        "${OUTPUT_DIR}/funcs.txt" "${OUTPUT_DIR}/funcs_patterns.txt" \
        "${OUTPUT_DIR}/ktrace.pid"
    printf '%s\n' "$MODE" >"${OUTPUT_DIR}/mode.txt"

    local -a patterns=()
    local p
    while read -r p; do
        [[ -z "$p" ]] && continue
        patterns+=("$p")
    done < <(funcs_to_lines "$FUNCS")
    (( ${#patterns[@]} > 0 )) || die "--funcs 为空"
    printf '%s\n' "${patterns[@]}" >"${OUTPUT_DIR}/funcs_patterns.txt"

    ftrace_reset

    # 原样写入 ftrace（支持精确名 / glob）；再读回展开名供 summary
    local filter_file
    if [[ "$MODE" == "filter" ]]; then
        filter_file="set_ftrace_filter"
        ftrace_write_patterns "$filter_file" "${patterns[@]}" \
            || die "没有可用的 trace 函数（全部 pattern 被拒绝）"
        echo >"${TRACE_ROOT}/set_graph_function"
    else
        filter_file="set_graph_function"
        ftrace_write_patterns "$filter_file" "${patterns[@]}" \
            || die "没有可用的 trace 函数（全部 pattern 被拒绝）"
    fi

    local -a ok_funcs=()
    mapfile -t ok_funcs < <(ftrace_read_funcs "$filter_file")
    (( ${#ok_funcs[@]} > 0 )) || die "ftrace 展开后函数列表为空"
    if (( ${#ok_funcs[@]} > FUNCS_MAX )); then
        die "展开后 ${#ok_funcs[@]} 个函数，超过 --funcs-max ${FUNCS_MAX}（收窄 glob 或增大上限）"
    fi
    echo "[ktrace] patterns=${patterns[*]} → expanded ${#ok_funcs[@]} funcs"

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

    {
        echo "抓取时间: $(date '+%Y-%m-%d %H:%M:%S')"
        echo "模式: capture-live (ftrace function_graph, mode=${MODE})"
        echo "patterns: ${patterns[*]}"
        echo "展开函数数: ${#ok_funcs[@]}"
        echo "函数: ${ok_funcs[*]}"
        echo "cpus: ${cpumask_desc}"
        echo "affinity: ${AFFINITY}"
        if [[ "$MODE" == "filter" && "$GRAPH_DEPTH" -eq 0 ]]; then
            echo "graph_depth: 0 (unlimited)"
        else
            echo "graph_depth: ${GRAPH_DEPTH}"
        fi
        if [[ "$MODE" == "filter" ]]; then
            echo "summary_tree: yes"
        else
            echo "summary_tree: no"
        fi
        echo "内核: $(uname -r)"
    } >"${OUTPUT_DIR}/metadata.txt"

    echo function_graph >"${TRACE_ROOT}/current_tracer"
    if [[ -w "${TRACE_ROOT}/options/funcgraph-tail" ]]; then
        echo 1 >"${TRACE_ROOT}/options/funcgraph-tail" 2>/dev/null || true
    fi
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
    echo "[ktrace] capture-live mode=${MODE} patterns=${patterns[*]} expanded=${#ok_funcs[@]} cpus=${cpumask_desc} affinity=${AFFINITY} depth=${GRAPH_DEPTH} → ${OUTPUT_DIR}"

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
        local mode_now="$MODE"
        if [[ -f "${OUTPUT_DIR}/mode.txt" ]]; then
            mode_now=$(tr -d '[:space:]' <"${OUTPUT_DIR}/mode.txt")
        fi
        if [[ -f "${OUTPUT_DIR}/funcs.txt" ]]; then
            mapfile -t funcs_arr <"${OUTPUT_DIR}/funcs.txt"
        fi
        if (( ${#funcs_arr[@]} > 0 )); then
            parse_summary "${OUTPUT_DIR}/function_graph.txt" "${OUTPUT_DIR}/summary.txt" "${funcs_arr[@]}"
            local pat
            pat=$(IFS='|'; echo "${funcs_arr[*]}")
            grep -E "$pat" "${OUTPUT_DIR}/function_graph.txt" >"${OUTPUT_DIR}/function_graph.filtered.txt" || true
            if [[ "$mode_now" == "filter" ]]; then
                parse_tree "${OUTPUT_DIR}/function_graph.txt" \
                    "${OUTPUT_DIR}/summary_tree.txt" "${OUTPUT_DIR}/funcs.txt" || \
                    echo "警告: summary_tree 生成失败" >&2
            fi
        else
            parse_summary "${OUTPUT_DIR}/function_graph.txt" "${OUTPUT_DIR}/summary.txt"
            : >"${OUTPUT_DIR}/function_graph.filtered.txt"
        fi

        ftrace_reset
        rm -f "${OUTPUT_DIR}/capture.ready" "${OUTPUT_DIR}/ktrace.pid"

        echo "[ktrace] summary:"
        cat "${OUTPUT_DIR}/summary.txt" || true
        if [[ -f "${OUTPUT_DIR}/summary_tree.txt" ]]; then
            echo "[ktrace] summary_tree:"
            cat "${OUTPUT_DIR}/summary_tree.txt" || true
        fi
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
