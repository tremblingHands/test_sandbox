#!/bin/bash
# ============================================================
# 冷启动吞吐扫描：自动划核并遍历 containerd 核数 / worker 核数 / K / 沙箱 cpuset
#
# 约定（见会话方案）:
#   --containerd-cpus / --worker-cpus 只给「个数」，具体核由脚本分配
#   workers 核落在 --worker-numa；与 containerd 禁止重叠；不够则 skip
#   K 只跑 >= N_w 的候选（列表为空则至少跑 K=N_w）
#   沙箱 cpuset: all = HOST；excl-cd = HOST \ CD
#   multi_single 的 NUMA（membind）= --worker-numa
#
# 用法:
#   ./scripts/throughput_sweep.sh \
#     --containerd-cpus 2,4,8 \
#     --worker-cpus 64,128 \
#     --worker-numa 0,1 \
#     --workers 32,64,128,256 \
#     --sandbox-modes all,excl-cd \
#     --duration 30 --preconfig 50
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
MULTI_SCRIPT="${SCRIPT_DIR}/multi_single_cold_start.sh"

HOST_CPUS=""
CONTAINERD_COUNTS=""
WORKER_COUNTS=""
WORKER_NUMA=""
WORKERS_K=""
SANDBOX_MODES="all,excl-cd"
DURATION=30
PRECONFIG=50
MEMS_OVERRIDE=""
RESTORE=true
DRY_RUN=false
CONFIRM_DURATION=""
CONFIRM_TOP=0

DROPIN_SWEEP_LEFTOVER="/etc/systemd/system/containerd.service.d/90-throughput-sweep-cpuset.conf"
UNIT_FILE=""
UNIT_BACKUP=""

usage() {
    cat <<'EOF'
吞吐扫描：遍历 NUMA × containerd 核数 × worker 核数 × K × 沙箱 cpuset 模式

必选:
  --containerd-cpus LIST   containerd 核「个数」列表，如 2,4,8
  --worker-cpus LIST       worker 核「个数」列表，如 64,128
  --worker-numa LIST       workers 所在 NUMA node 列表，如 0,1（逐个遍历）
  --workers LIST           K 候选；实际只跑 K>=N_w（缺省/滤空则至少 K=N_w）

可选:
  --host-cpus SPEC         参与划核的全集（默认自动探测在线 CPU）
  --sandbox-modes LIST     all,excl-cd（默认两者）
  --duration SEC           压测时长（默认 30）
  --preconfig N            透传 --preconfig（默认 50）
  --mems SPEC              覆盖沙箱 --cpuset-mems（默认=当轮 worker-numa）
  --confirm-duration SEC   对 Top-N 再用更长 duration 复核（可选）
  --confirm-top N          复核点数（默认 0=不复核）
  --no-restore             结束不恢复扫前 containerd.service
  --dry-run                只打印将跑的组合，不改 unit、不压测
  -h, --help

划核: worker 在指定 NUMA 上取编号最大的 N_w 个；containerd 在 HOST\WR 取编号最小的 N_c 个。
绑核: 通过 systemctl show FragmentPath 定位实际加载的 containerd.service 再改；
      失败时回退 /etc → /usr/lib。结束可恢复扫前备份。
不够则 skip。workers 与 containerd 永不重叠。

示例:
  ./scripts/throughput_sweep.sh \
    --containerd-cpus 2,4,8 \
    --worker-cpus 64,128 \
    --worker-numa 0,1 \
    --workers 64,128,256 \
    --sandbox-modes all,excl-cd \
    --duration 30 --preconfig 50

  # 只打印组合、不压测:
  ./scripts/throughput_sweep.sh \
    --containerd-cpus 2,4 --worker-cpus 64,128 \
    --worker-numa 0,1 --workers 64,128 --dry-run
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host-cpus) HOST_CPUS="$2"; shift 2 ;;
        --containerd-cpus) CONTAINERD_COUNTS="$2"; shift 2 ;;
        --worker-cpus) WORKER_COUNTS="$2"; shift 2 ;;
        --worker-numa) WORKER_NUMA="$2"; shift 2 ;;
        --workers) WORKERS_K="$2"; shift 2 ;;
        --sandbox-modes) SANDBOX_MODES="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --preconfig) PRECONFIG="$2"; shift 2 ;;
        --mems) MEMS_OVERRIDE="$2"; shift 2 ;;
        --confirm-duration) CONFIRM_DURATION="$2"; shift 2 ;;
        --confirm-top) CONFIRM_TOP="$2"; shift 2 ;;
        --no-restore) RESTORE=false; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage ;;
        *) echo "未知参数: $1"; usage ;;
    esac
done

[[ -n "$CONTAINERD_COUNTS" ]] || { echo "错误: 需要 --containerd-cpus"; usage; }
[[ -n "$WORKER_COUNTS" ]] || { echo "错误: 需要 --worker-cpus"; usage; }
[[ -n "$WORKER_NUMA" ]] || { echo "错误: 需要 --worker-numa"; usage; }
[[ -f "$MULTI_SCRIPT" ]] || { echo "错误: 未找到 $MULTI_SCRIPT"; exit 1; }

# ---------- CPU set helpers（空格分隔的排序数字列表）----------

expand_spec_to_list() {
    # "0-3,8,10-11" → "0 1 2 3 8 10 11"
    local spec="$1" out=() part a b i
    IFS=',' read -ra parts <<< "$spec"
    for part in "${parts[@]}"; do
        part="${part// /}"
        [[ -n "$part" ]] || continue
        if [[ "$part" == *-* ]]; then
            IFS='-' read -r a b <<< "$part"
            for ((i=a; i<=b; i++)); do out+=("$i"); done
        else
            out+=("$part")
        fi
    done
    if [ ${#out[@]} -eq 0 ]; then
        echo ""
        return 0
    fi
    printf '%s\n' "${out[@]}" | sort -n | uniq | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

detect_online_cpus_spec() {
    if [ -f /sys/devices/system/cpu/online ]; then
        cat /sys/devices/system/cpu/online
    else
        local n
        n=$(nproc)
        echo "0-$((n-1))"
    fi
}

numa_cpulist_spec() {
    local node="$1" f
    f="/sys/devices/system/node/node${node}/cpulist"
    if [ ! -f "$f" ]; then
        echo ""
        return 1
    fi
    cat "$f"
}

list_count() {
    local s="$1"
    [[ -z "${s// }" ]] && { echo 0; return; }
    # shellcheck disable=SC2086
    set -- $s
    echo $#
}

list_contains() {
    local needle="$1" hay="$2" x
    # shellcheck disable=SC2086
    for x in $hay; do
        [[ "$x" == "$needle" ]] && return 0
    done
    return 1
}

list_intersect_nonempty() {
    local a="$1" b="$2" x
    # shellcheck disable=SC2086
    for x in $a; do
        list_contains "$x" "$b" && return 0
    done
    return 1
}

list_diff() {
    # A \ B
    local a="$1" b="$2" x out=()
    # shellcheck disable=SC2086
    for x in $a; do
        list_contains "$x" "$b" || out+=("$x")
    done
    if [ ${#out[@]} -eq 0 ]; then
        echo ""
        return
    fi
    printf '%s ' "${out[@]}" | sed 's/[[:space:]]*$//'
}

list_intersect() {
    local a="$1" b="$2" x out=()
    # shellcheck disable=SC2086
    for x in $a; do
        list_contains "$x" "$b" && out+=("$x")
    done
    if [ ${#out[@]} -eq 0 ]; then
        echo ""
        return
    fi
    printf '%s ' "${out[@]}" | sed 's/[[:space:]]*$//'
}

list_take_highest() {
    local n="$1" lst="$2"
    [[ -z "${lst// }" ]] && { echo ""; return; }
    # shellcheck disable=SC2086
    printf '%s\n' $lst | sort -n | tail -n "$n" | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

list_take_lowest() {
    local n="$1" lst="$2"
    [[ -z "${lst// }" ]] && { echo ""; return; }
    # shellcheck disable=SC2086
    printf '%s\n' $lst | sort -n | head -n "$n" | tr '\n' ' ' | sed 's/[[:space:]]*$//'
}

# 空格列表 → multi_single / numactl 可用规格：单段连续用 A-B，否则逗号枚举
list_to_spec() {
    local lst="$1"
    [[ -z "${lst// }" ]] && { echo ""; return; }
    local -a arr=()
    # shellcheck disable=SC2086
    read -ra arr <<< "$(printf '%s\n' $lst | sort -n | uniq | tr '\n' ' ')"
    local n=${#arr[@]}
    if [ "$n" -eq 0 ]; then
        echo ""
        return
    fi
    local first=${arr[0]} last=${arr[$((n-1))]}
    if [ "$n" -eq $((last - first + 1)) ]; then
        if [ "$n" -eq 1 ]; then
            echo "$first"
        else
            echo "${first}-${last}"
        fi
        return
    fi
    local IFS=','
    echo "${arr[*]}"
}

parse_csv_ints() {
    local s="$1" out=() x
    IFS=',' read -ra parts <<< "$s"
    for x in "${parts[@]}"; do
        x="${x// /}"
        [[ -n "$x" ]] || continue
        out+=("$x")
    done
    echo "${out[*]}"
}

# ---------- containerd 绑核（改 unit 文件，非 drop-in）----------

resolve_containerd_unit_file() {
    # 先问 systemd 当前实际加载的主 unit，再回退到常见路径
    local frag
    frag=$(systemctl show -p FragmentPath --value containerd 2>/dev/null || true)
    if [[ -n "$frag" && -f "$frag" ]]; then
        echo "$frag"
        return 0
    fi
    # 回退：/etc 优先于 /usr/lib
    if [ -f /etc/systemd/system/containerd.service ]; then
        echo /etc/systemd/system/containerd.service
        return 0
    fi
    if [ -f /usr/lib/systemd/system/containerd.service ]; then
        echo /usr/lib/systemd/system/containerd.service
        return 0
    fi
    echo ""
    return 1
}

detect_containerd_bin() {
    local p
    p=$(systemctl show -p ExecStart --value containerd 2>/dev/null | tr ' ' '\n' | grep -E 'containerd$' | tail -1 || true)
    if [[ -n "$p" && -x "$p" ]]; then
        echo "$p"
        return
    fi
    # 从 unit 文件里猜
    if [ -n "$UNIT_FILE" ] && [ -f "$UNIT_FILE" ]; then
        p=$(grep -E '^ExecStart=.*containerd' "$UNIT_FILE" | tail -1 | awk '{print $NF}' || true)
        if [[ -n "$p" && -x "$p" ]]; then
            echo "$p"
            return
        fi
    fi
    if [[ -x /usr/local/bin/containerd ]]; then
        echo /usr/local/bin/containerd
        return
    fi
    if [[ -x /usr/bin/containerd ]]; then
        echo /usr/bin/containerd
        return
    fi
    command -v containerd
}

detect_numactl_bin() {
    command -v numactl || echo /usr/bin/numactl
}

save_containerd_affinity_state() {
    UNIT_FILE=$(resolve_containerd_unit_file)
    if [ -z "$UNIT_FILE" ]; then
        echo "错误: 未找到 containerd.service（/etc 或 /usr/lib）"
        exit 1
    fi
    UNIT_BACKUP=$(mktemp)
    cp -a "$UNIT_FILE" "$UNIT_BACKUP"
    echo "[sweep] 将修改 unit: $UNIT_FILE（备份 → $UNIT_BACKUP）"
    # 去掉本脚本旧版遗留的 drop-in，避免盖住 unit 里的 ExecStart
    if [ -f "$DROPIN_SWEEP_LEFTOVER" ]; then
        sudo rm -f "$DROPIN_SWEEP_LEFTOVER"
        echo "[sweep] 已删除遗留 drop-in: $DROPIN_SWEEP_LEFTOVER"
    fi
}

apply_containerd_cpus() {
    local spec="$1"
    local bin numa_bin tmp
    bin=$(detect_containerd_bin)
    numa_bin=$(detect_numactl_bin)
    if [ -z "$UNIT_FILE" ] || [ ! -f "$UNIT_FILE" ]; then
        echo "错误: UNIT_FILE 无效"
        return 1
    fi

    tmp=$(mktemp)
    # 只改主进程 ExecStart=…containerd…；保留其它行
    awk -v numa="$numa_bin" -v spec="$spec" -v bin="$bin" '
      BEGIN { done=0 }
      /^ExecStart=.*containerd/ && !done {
        print "ExecStart=" numa " -C " spec " " bin
        done=1
        next
      }
      { print }
      END {
        if (!done) {
          # 无匹配时在 [Service] 后插入（由调用方再检查）
        }
      }
    ' "$UNIT_FILE" > "$tmp"

    if ! grep -qE "^ExecStart=.*-C ${spec} .*containerd" "$tmp"; then
        # 原文件可能没有 containerd ExecStart，尝试在第一个 ExecStart= 处替换，或追加
        if grep -qE '^ExecStart=' "$UNIT_FILE"; then
            awk -v numa="$numa_bin" -v spec="$spec" -v bin="$bin" '
              BEGIN { done=0 }
              /^ExecStart=/ && !/^ExecStartPre=/ && !done {
                print "ExecStart=" numa " -C " spec " " bin
                done=1
                next
              }
              { print }
            ' "$UNIT_FILE" > "$tmp"
        else
            awk -v numa="$numa_bin" -v spec="$spec" -v bin="$bin" '
              /^\[Service\]/ { print; print "ExecStart=" numa " -C " spec " " bin; next }
              { print }
            ' "$UNIT_FILE" > "$tmp"
        fi
    fi

    if ! grep -qE '^ExecStart=.*containerd' "$tmp"; then
        echo "错误: 无法写入 ExecStart 到 $UNIT_FILE"
        rm -f "$tmp"
        return 1
    fi

    sudo cp "$tmp" "$UNIT_FILE"
    rm -f "$tmp"
    echo "  已写 $UNIT_FILE → ExecStart=${numa_bin} -C ${spec} ${bin}"

    sudo systemctl daemon-reload
    sudo systemctl restart containerd
    sleep 2
    if ! systemctl is-active --quiet containerd; then
        echo "错误: containerd 重启后未 active（绑核 $spec）"
        return 1
    fi
    local pid aff
    pid=$(pgrep -nx containerd || true)
    if [ -n "$pid" ]; then
        aff=$(taskset -pc "$pid" 2>/dev/null | awk -F': ' '{print $NF}')
        echo "  containerd pid=$pid affinity=$aff (期望 $spec)"
    fi
}

restore_containerd_affinity() {
    if ! $RESTORE; then
        echo "[sweep] --no-restore：保留当前 $UNIT_FILE 绑核"
        return 0
    fi
    if [ -n "$UNIT_BACKUP" ] && [ -f "$UNIT_BACKUP" ] && [ -n "$UNIT_FILE" ]; then
        sudo cp -a "$UNIT_BACKUP" "$UNIT_FILE"
        rm -f "$UNIT_BACKUP"
        UNIT_BACKUP=""
        echo "[sweep] 已从备份恢复 $UNIT_FILE"
    else
        echo "[sweep] 无 unit 备份可恢复"
        return 0
    fi
    sudo systemctl daemon-reload
    sudo systemctl restart containerd
    sleep 2
    echo "[sweep] containerd 已按恢复配置重启"
}

# ---------- 解析压测结果 ----------

parse_all_line() {
    # stdin: multi_single 日志；stdout: total success p50 p95 p99 mean tps
    local line
    line=$(grep -E '^ALL[[:space:]]' | tail -1 || true)
    if [ -z "$line" ]; then
        echo ""
        return 1
    fi
    # ALL  total success p50 p95 p99 mean  tps/s
    echo "$line" | awk '{
      tps=$NF; sub(/\/s$/,"",tps);
      print $2,$3,$4,$5,$6,$7,tps
    }'
}

# ---------- 主流程 ----------

cd "$REPO_DIR"

if [ -z "$HOST_CPUS" ]; then
    HOST_CPUS=$(detect_online_cpus_spec)
fi
HOST_LIST=$(expand_spec_to_list "$HOST_CPUS")

IFS=' ' read -ra NUMA_ARR <<< "$(parse_csv_ints "$WORKER_NUMA")"
if [ ${#NUMA_ARR[@]} -eq 0 ]; then
    echo "错误: --worker-numa 为空"
    exit 1
fi
for _n in "${NUMA_ARR[@]}"; do
    if [ ! -f "/sys/devices/system/node/node${_n}/cpulist" ]; then
        echo "错误: 不存在 NUMA node${_n}"
        exit 1
    fi
done

TS=$(date +%Y%m%d%H%M%S)
OUT_ROOT="${REPO_DIR}/results/throughput_sweep/${TS}"
mkdir -p "$OUT_ROOT/runs"
SUMMARY_CSV="${OUT_ROOT}/summary.csv"
SWEEP_LOG="${OUT_ROOT}/sweep.log"
BEST_JSON="${OUT_ROOT}/best.json"

exec > >(tee -a "$SWEEP_LOG") 2>&1

echo "=============================================="
echo "  吞吐扫描 throughput_sweep"
echo "=============================================="
echo "  host-cpus:        $HOST_CPUS ($(list_count "$HOST_LIST") cpus)"
echo "  containerd-cpus:  $CONTAINERD_COUNTS  (counts)"
echo "  worker-cpus:      $WORKER_COUNTS  (counts)"
echo "  worker-numa:      $WORKER_NUMA"
for _n in "${NUMA_ARR[@]}"; do
    echo "    node${_n}: $(numa_cpulist_spec "$_n")"
done
echo "  workers K:        ${WORKERS_K:-(auto >= N_w)}"
echo "  sandbox-modes:    $SANDBOX_MODES"
echo "  duration:         $DURATION"
echo "  preconfig:        $PRECONFIG"
echo "  cpuset-mems:      ${MEMS_OVERRIDE:-(每轮=当轮 numa)}"
echo "  unit file:        $(resolve_containerd_unit_file)"
echo "  output:           $OUT_ROOT"
echo "  dry-run:          $DRY_RUN"
echo "=============================================="

echo "numa,cd_n,wr_n,K,sandbox_mode,cd_cpus,wr_cpus,sandbox_cpus,status,tps,total,success,p50,p95,p99,mean,run_dir,reason" \
    > "$SUMMARY_CSV"

IFS=' ' read -ra CD_COUNTS_ARR <<< "$(parse_csv_ints "$CONTAINERD_COUNTS")"
IFS=' ' read -ra WR_COUNTS_ARR <<< "$(parse_csv_ints "$WORKER_COUNTS")"
IFS=' ' read -ra SB_MODES_ARR <<< "$(parse_csv_ints "$SANDBOX_MODES")"
IFS=' ' read -ra K_CAND_ARR <<< "$(parse_csv_ints "${WORKERS_K:-}")"

best_tps="-1"
best_line=""

cleanup_on_exit() {
    if ! $DRY_RUN; then
        restore_containerd_affinity || true
    fi
}
trap cleanup_on_exit EXIT

if ! $DRY_RUN; then
    save_containerd_affinity_state
fi

run_id=0
for NUMA_NODE in "${NUMA_ARR[@]}"; do
    NODE_SPEC=$(numa_cpulist_spec "$NUMA_NODE")
    NODE_LIST=$(expand_spec_to_list "$NODE_SPEC")
    NODE_HOST_LIST=$(list_intersect "$NODE_LIST" "$HOST_LIST")
    MEMS_VAL="${MEMS_OVERRIDE:-$NUMA_NODE}"

    echo ""
    echo "######## worker NUMA=$NUMA_NODE (cpus $NODE_SPEC, usable $(list_count "$NODE_HOST_LIST")) ########"

    for N_c in "${CD_COUNTS_ARR[@]}"; do
        for N_w in "${WR_COUNTS_ARR[@]}"; do
            avail_wr=$(list_count "$NODE_HOST_LIST")
            if [ "$avail_wr" -lt "$N_w" ]; then
                echo "[skip] numa=$NUMA_NODE N_c=$N_c N_w=$N_w: 仅 ${avail_wr} 核 < N_w"
                echo "$NUMA_NODE,$N_c,$N_w,,,,,,skip,,,,,,,\"\",numa_too_small" >> "$SUMMARY_CSV"
                continue
            fi
            WR_LIST=$(list_take_highest "$N_w" "$NODE_HOST_LIST")
            WR_SPEC=$(list_to_spec "$WR_LIST")

            REST=$(list_diff "$HOST_LIST" "$WR_LIST")
            avail_cd=$(list_count "$REST")
            if [ "$avail_cd" -lt "$N_c" ]; then
                echo "[skip] numa=$NUMA_NODE N_c=$N_c N_w=$N_w WR=$WR_SPEC: HOST\\WR 仅 ${avail_cd} 核 < N_c"
                echo "$NUMA_NODE,$N_c,$N_w,,,${WR_SPEC},,skip,,,,,,,\"\",insufficient_cpus" >> "$SUMMARY_CSV"
                continue
            fi
            CD_LIST=$(list_take_lowest "$N_c" "$REST")
            CD_SPEC=$(list_to_spec "$CD_LIST")

            if list_intersect_nonempty "$CD_LIST" "$WR_LIST"; then
                echo "[skip] 内部错误: CD 与 WR 重叠"
                echo "$NUMA_NODE,$N_c,$N_w,,,${CD_SPEC},${WR_SPEC},,skip,,,,,,,\"\",overlap" >> "$SUMMARY_CSV"
                continue
            fi

            K_RUN=()
            if [ ${#K_CAND_ARR[@]} -eq 0 ]; then
                K_RUN=("$N_w")
            else
                for k in "${K_CAND_ARR[@]}"; do
                    if [ "$k" -ge "$N_w" ]; then
                        K_RUN+=("$k")
                    fi
                done
                if [ ${#K_RUN[@]} -eq 0 ]; then
                    K_RUN=("$N_w")
                    echo "[info] N_w=$N_w: --workers 无 K>=N_w，自动补 K=$N_w"
                fi
            fi

            echo ""
            echo ">>> 划核: NUMA=$NUMA_NODE | CD($N_c)=$CD_SPEC | WR($N_w)=$WR_SPEC | K=${K_RUN[*]}"

            if $DRY_RUN; then
                for K in "${K_RUN[@]}"; do
                    for mode in "${SB_MODES_ARR[@]}"; do
                        case "$mode" in
                            all) SB_SPEC=$(list_to_spec "$HOST_LIST") ;;
                            excl-cd) SB_SPEC=$(list_to_spec "$(list_diff "$HOST_LIST" "$CD_LIST")") ;;
                            *) echo "[skip] 未知 sandbox mode: $mode"; continue ;;
                        esac
                        echo "[dry-run] numa=$NUMA_NODE N_c=$N_c N_w=$N_w K=$K mode=$mode cd=$CD_SPEC wr=$WR_SPEC sb=$SB_SPEC"
                        echo "$NUMA_NODE,$N_c,$N_w,$K,$mode,$CD_SPEC,$WR_SPEC,$SB_SPEC,dry-run,,,,,,,\"\",\"\"" >> "$SUMMARY_CSV"
                    done
                done
                continue
            fi

            if ! apply_containerd_cpus "$CD_SPEC"; then
                echo "$NUMA_NODE,$N_c,$N_w,,,${CD_SPEC},${WR_SPEC},,fail,,,,,,,\"\",containerd_restart_failed" >> "$SUMMARY_CSV"
                continue
            fi

            for K in "${K_RUN[@]}"; do
                for mode in "${SB_MODES_ARR[@]}"; do
                    case "$mode" in
                        all) SB_SPEC=$(list_to_spec "$HOST_LIST") ;;
                        excl-cd) SB_SPEC=$(list_to_spec "$(list_diff "$HOST_LIST" "$CD_LIST")") ;;
                        *) echo "[skip] 未知 sandbox mode: $mode"; continue ;;
                    esac

                    run_id=$((run_id + 1))
                    run_tag=$(printf 'run%04d_numa%d_cd%d_wr%d_k%d_%s' "$run_id" "$NUMA_NODE" "$N_c" "$N_w" "$K" "$mode")
                    run_dir="${OUT_ROOT}/runs/${run_tag}"
                    mkdir -p "$run_dir"
                    run_log="${run_dir}/multi.log"

                    echo ""
                    echo "----- ${run_tag} -----"
                    echo "  multi_single $WR_SPEC $K $NUMA_NODE -- duration=$DURATION cpuset-cpus=$SB_SPEC mems=$MEMS_VAL"

                    set +e
                    bash "$MULTI_SCRIPT" "$WR_SPEC" "$K" "$NUMA_NODE" -- \
                        --duration "$DURATION" \
                        --cpuset-cpus "$SB_SPEC" \
                        --cpuset-mems "$MEMS_VAL" \
                        --preconfig "$PRECONFIG" \
                        >"$run_log" 2>&1
                    rc=$?
                    set -e

                    if [ -d "${REPO_DIR}/results/multi" ]; then
                        cp -a "${REPO_DIR}/results/multi" "${run_dir}/multi_results" 2>/dev/null || true
                    fi

                    parsed=$(parse_all_line < "$run_log" || true)
                    if [ -z "$parsed" ]; then
                        echo "  结果: FAIL/无 ALL 行 (rc=$rc) 见 $run_log"
                        echo "$NUMA_NODE,$N_c,$N_w,$K,$mode,$CD_SPEC,$WR_SPEC,$SB_SPEC,fail,,,,,,${run_dir},no_all_line" >> "$SUMMARY_CSV"
                        continue
                    fi
                    # shellcheck disable=SC2086
                    set -- $parsed
                    total=$1; success=$2; p50=$3; p95=$4; p99=$5; mean=$6; tps=$7
                    echo "  结果: tps=$tps total=$total success=$success p50=$p50 p95=$p95 mean=$mean"

                    echo "$NUMA_NODE,$N_c,$N_w,$K,$mode,$CD_SPEC,$WR_SPEC,$SB_SPEC,ok,$tps,$total,$success,$p50,$p95,$p99,$mean,${run_dir}," \
                        >> "$SUMMARY_CSV"

                    awk_best=$(awk -v t="$tps" -v b="$best_tps" 'BEGIN{print (t+0>b+0)?"1":"0"}')
                    if [ "$awk_best" = "1" ]; then
                        best_tps="$tps"
                        best_line="$NUMA_NODE,$N_c,$N_w,$K,$mode,$CD_SPEC,$WR_SPEC,$SB_SPEC,$tps,$total,$success,$p50,$p95,$p99,$mean,${run_dir}"
                    fi
                done
            done
        done
    done
done

# 可选：Top-N 长时复核
if ! $DRY_RUN && [ "${CONFIRM_TOP:-0}" -gt 0 ] && [ -n "${CONFIRM_DURATION:-}" ]; then
    echo ""
    echo "=== 复核 Top ${CONFIRM_TOP}（duration=${CONFIRM_DURATION}s）==="
    # csv: numa,cd_n,wr_n,K,mode,cd,wr,sb,status,tps,...
    mapfile -t TOP_LINES < <(awk -F, 'NR>1 && $9=="ok" {print $10","$0}' "$SUMMARY_CSV" | sort -t, -k1,1nr | head -n "$CONFIRM_TOP")
    for row in "${TOP_LINES[@]}"; do
        IFS=',' read -r _tps NUMA_NODE N_c N_w K mode CD_SPEC WR_SPEC SB_SPEC _rest <<< "$row"
        MEMS_VAL="${MEMS_OVERRIDE:-$NUMA_NODE}"
        echo "复核: numa=$NUMA_NODE CD=$CD_SPEC WR=$WR_SPEC K=$K mode=$mode"
        apply_containerd_cpus "$CD_SPEC" || continue
        run_id=$((run_id + 1))
        run_tag=$(printf 'confirm%04d_numa%s_cd%s_wr%s_k%s_%s' "$run_id" "$NUMA_NODE" "$N_c" "$N_w" "$K" "$mode")
        run_dir="${OUT_ROOT}/runs/${run_tag}"
        mkdir -p "$run_dir"
        set +e
        bash "$MULTI_SCRIPT" "$WR_SPEC" "$K" "$NUMA_NODE" -- \
            --duration "$CONFIRM_DURATION" \
            --cpuset-cpus "$SB_SPEC" \
            --cpuset-mems "$MEMS_VAL" \
            --preconfig "$PRECONFIG" \
            >"${run_dir}/multi.log" 2>&1
        set -e
        [ -d "${REPO_DIR}/results/multi" ] && cp -a "${REPO_DIR}/results/multi" "${run_dir}/multi_results" 2>/dev/null || true
        parsed=$(parse_all_line < "${run_dir}/multi.log" || true)
        if [ -n "$parsed" ]; then
            # shellcheck disable=SC2086
            set -- $parsed
            echo "  confirm tps=$7 (was $_tps)"
            echo "$NUMA_NODE,$N_c,$N_w,$K,$mode,$CD_SPEC,$WR_SPEC,$SB_SPEC,confirm,$7,$1,$2,$3,$4,$5,$6,${run_dir}," >> "$SUMMARY_CSV"
            awk_best=$(awk -v t="$7" -v b="$best_tps" 'BEGIN{print (t+0>b+0)?"1":"0"}')
            if [ "$awk_best" = "1" ]; then
                best_tps="$7"
                best_line="$NUMA_NODE,$N_c,$N_w,$K,$mode,$CD_SPEC,$WR_SPEC,$SB_SPEC,$7,$1,$2,$3,$4,$5,$6,${run_dir}"
            fi
        fi
    done
fi

if $DRY_RUN; then
    echo ""
    echo "[sweep] dry-run 完成 → $SUMMARY_CSV"
elif [ -n "$best_line" ]; then
    IFS=',' read -r b_numa b_nc b_nw b_k b_mode b_cd b_wr b_sb b_tps b_tot b_suc b_p50 b_p95 b_p99 b_mean b_dir <<< "$best_line"
    b_mems="${MEMS_OVERRIDE:-$b_numa}"
    cat > "$BEST_JSON" <<EOF
{
  "tps": $b_tps,
  "worker_numa": $b_numa,
  "containerd_cpus_count": $b_nc,
  "worker_cpus_count": $b_nw,
  "workers_K": $b_k,
  "sandbox_mode": "$b_mode",
  "containerd_cpus": "$b_cd",
  "worker_cpus": "$b_wr",
  "sandbox_cpus": "$b_sb",
  "cpuset_mems": "$b_mems",
  "duration": $DURATION,
  "total": $b_tot,
  "success": $b_suc,
  "p50_ms": $b_p50,
  "p95_ms": $b_p95,
  "p99_ms": $b_p99,
  "mean_ms": $b_mean,
  "run_dir": "$b_dir"
}
EOF
    echo ""
    echo "=============================================="
    echo "  最优吞吐: ${b_tps}/s"
    echo "  containerd: $b_cd ($b_nc)"
    echo "  workers:    $b_wr ($b_nw)  K=$b_k  numa=$b_numa"
    echo "  sandbox:    $b_mode → $b_sb"
    echo "  best.json:  $BEST_JSON"
    echo "  summary:    $SUMMARY_CSV"
    echo "=============================================="
else
    echo '{"tps": null, "note": "no successful runs"}' > "$BEST_JSON"
    echo "[sweep] 无成功跑通的组合（见 $SUMMARY_CSV）"
fi
