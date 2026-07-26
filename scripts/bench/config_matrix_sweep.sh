#!/usr/bin/env bash
# ============================================================
# 配置矩阵吞吐扫描（推荐入口）:
#   1) 编译 runtime：默认 release；可选 profile(=debug)
#   2) 记录环境基线（内核、二进制版本、NUMA 等）
#   3) 遍历 CNI × runtime × hypervisor，内层 throughput_sweep
#
# 拓扑默认:
#   worker-numa=1；HOST 排除 CPU0；sandbox-modes=excl-cd
#   → containerd 落 numa0 低编号核；sandbox = HOST\CD
#
# 组合展开:
#   runc → 忽略 hypervisor（一组）
#   kata → 与 --hypervisors 笛卡尔积
#   再与 --cnis 笛卡尔积
#
# 用法:
#   ./scripts/bench/config_matrix_sweep.sh \
#     --cnis bridge,ipvlan-l3 \
#     --runtimes runc,kata \
#     --hypervisors qemu,cloud-hypervisor \
#     --containerd-cpus 2,4,8,16 \
#     --worker-cpus 64,128 \
#     --workers 64,128,256 \
#     --duration 30 --max-mean-ms 200
#
#   ./scripts/bench/config_matrix_sweep.sh ... --profile          # 编译 debug
#   ./scripts/bench/config_matrix_sweep.sh ... --skip-build       # 跳过编译
#   ./scripts/bench/config_matrix_sweep.sh ... --dry-run
# ============================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SETUP_SCRIPT="${REPO_DIR}/scripts/setup/setup.sh"
BUILD_SCRIPT="${REPO_DIR}/scripts/setup/build_install_runtime.sh"
SWEEP_SCRIPT="${SCRIPT_DIR}/throughput_sweep.sh"
COLD_START_PY="${SCRIPT_DIR}/cold_start_bench.py"
RESOURCE_SAMPLER="${REPO_DIR}/scripts/profile/resource_sampler.py"

CNIS="bridge,ipvlan-l3"
RUNTIMES="runc,kata"
HYPERVISORS="qemu"
IP_MASQ="false"
WORKER_NUMA="1"
SANDBOX_MODES="excl-cd"
CONTAINERD_COUNTS=""
WORKER_COUNTS=""
WORKERS_K=""
DURATION=30
PRECONFIG=50
MAX_MEAN_MS=""
MEMS_OVERRIDE=""
ALLOW_CPU0=false
HOST_CPUS=""
DRY_RUN=false
SKIP_SETUP=false
SKIP_BUILD=false
SKIP_COLD_START=false
COLD_START_RUNS=50
BUILD_MODE="release"   # release | debug（profile）
CONFIRM_DURATION=""
CONFIRM_TOP=0

usage() {
    cat <<'EOF'
配置矩阵吞吐扫描：编译 → 环境基线 → 每组合 cold_start_bench → throughput_sweep

必选（透传内层）:
  --containerd-cpus LIST
  --worker-cpus LIST
  --workers LIST              K 候选（可省略，内层按 N_w 补）

编译（Profile = debug 编译）:
  --build-mode release|debug  默认 release
  --profile                   同 --build-mode debug
  --skip-build                跳过 build_install_runtime

冷启动时延（每组合 setup 后、吞吐扫前）:
  --cold-start-runs N         默认 50（cold_start_bench.py --runs）
  --skip-cold-start           跳过冷启动时延采集

矩阵:
  --cnis LIST                 默认 bridge,ipvlan-l3
  --runtimes LIST             默认 runc,kata
  --hypervisors LIST          默认 qemu；仅对 kata 展开
  --ip-masq true|false        默认 false（bridge 时传给 setup）

拓扑 / 压测（默认已按方案固定）:
  --worker-numa LIST          默认 1
  --sandbox-modes LIST        默认 excl-cd
  --duration SEC              默认 30
  --preconfig N               默认 50
  --max-mean-ms N
  --mems SPEC
  --host-cpus SPEC
  --allow-cpu0
  --confirm-duration SEC
  --confirm-top N

其它:
  --skip-setup                不跑 setup.sh（仅压测；需环境已就绪）
  --dry-run                   只打印组合，不编译、不 setup、不压测
  -h, --help

示例:
  ./scripts/bench/config_matrix_sweep.sh \
    --cnis bridge,ipvlan-l3 \
    --runtimes runc,kata \
    --hypervisors qemu,cloud-hypervisor \
    --containerd-cpus 2,4,8,16 \
    --worker-cpus 64,128 \
    --workers 64,128,256 \
    --duration 30 --max-mean-ms 200

  # profile（debug 编译）矩阵:
  ./scripts/bench/config_matrix_sweep.sh ... --profile

  ./scripts/bench/config_matrix_sweep.sh ... --dry-run
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cnis) CNIS="$2"; shift 2 ;;
        --runtimes) RUNTIMES="$2"; shift 2 ;;
        --hypervisors) HYPERVISORS="$2"; shift 2 ;;
        --ip-masq) IP_MASQ="$2"; shift 2 ;;
        --containerd-cpus) CONTAINERD_COUNTS="$2"; shift 2 ;;
        --worker-cpus) WORKER_COUNTS="$2"; shift 2 ;;
        --workers) WORKERS_K="$2"; shift 2 ;;
        --worker-numa) WORKER_NUMA="$2"; shift 2 ;;
        --sandbox-modes) SANDBOX_MODES="$2"; shift 2 ;;
        --duration) DURATION="$2"; shift 2 ;;
        --preconfig) PRECONFIG="$2"; shift 2 ;;
        --max-mean-ms) MAX_MEAN_MS="$2"; shift 2 ;;
        --mems) MEMS_OVERRIDE="$2"; shift 2 ;;
        --host-cpus) HOST_CPUS="$2"; shift 2 ;;
        --allow-cpu0) ALLOW_CPU0=true; shift ;;
        --confirm-duration) CONFIRM_DURATION="$2"; shift 2 ;;
        --confirm-top) CONFIRM_TOP="$2"; shift 2 ;;
        --build-mode) BUILD_MODE="$2"; shift 2 ;;
        --profile) BUILD_MODE="debug"; shift ;;
        --skip-build) SKIP_BUILD=true; shift ;;
        --cold-start-runs) COLD_START_RUNS="$2"; shift 2 ;;
        --skip-cold-start) SKIP_COLD_START=true; shift ;;
        --skip-setup) SKIP_SETUP=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage ;;
        *) echo "未知参数: $1"; usage ;;
    esac
done

[[ -n "$CONTAINERD_COUNTS" ]] || { echo "错误: 需要 --containerd-cpus"; usage; }
[[ -n "$WORKER_COUNTS" ]] || { echo "错误: 需要 --worker-cpus"; usage; }
[[ -f "$SETUP_SCRIPT" ]] || { echo "错误: 未找到 $SETUP_SCRIPT"; exit 1; }
[[ -f "$BUILD_SCRIPT" ]] || { echo "错误: 未找到 $BUILD_SCRIPT"; exit 1; }
[[ -f "$SWEEP_SCRIPT" ]] || { echo "错误: 未找到 $SWEEP_SCRIPT"; exit 1; }
[[ -f "$COLD_START_PY" ]] || { echo "错误: 未找到 $COLD_START_PY"; exit 1; }
[[ -x "$SWEEP_SCRIPT" ]] || chmod +x "$SWEEP_SCRIPT"
if ! [[ "$COLD_START_RUNS" =~ ^[1-9][0-9]*$ ]]; then
    echo "错误: --cold-start-runs 须为正整数，收到: $COLD_START_RUNS"
    exit 1
fi

case "$IP_MASQ" in
    true|false) ;;
    *) echo "错误: --ip-masq 必须是 true|false"; exit 1 ;;
esac
case "$BUILD_MODE" in
    release|debug) ;;
    *) echo "错误: --build-mode 必须是 release|debug，收到: $BUILD_MODE"; exit 1 ;;
esac

parse_csv() {
    local s="$1" out=() x
    IFS=',' read -ra parts <<< "$s"
    for x in "${parts[@]}"; do
        x="${x// /}"
        [[ -n "$x" ]] || continue
        out+=("$x")
    done
    echo "${out[*]}"
}

# 写环境基线：env_baseline.txt + env_baseline.json（尽量复用 resource_sampler）
write_env_baseline() {
    local out_dir="$1"
    local txt="${out_dir}/env_baseline.txt"
    local json="${out_dir}/env_baseline.json"
    local cni_conf="/etc/cni/net.d/10-mynet.conf"
    local cd_cfg="/etc/containerd/config.toml"

    mkdir -p "$out_dir"

    {
        echo "timestamp:          $(date -Iseconds 2>/dev/null || date)"
        echo "build_mode:         $BUILD_MODE"
        echo "skip_build:         $SKIP_BUILD"
        echo "hostname:           $(hostname 2>/dev/null || true)"
        echo "kernel:             $(uname -r 2>/dev/null || true)"
        echo "arch:               $(uname -m 2>/dev/null || true)"
        echo "os:                 $(uname -srm 2>/dev/null || true)"
        echo "cpu_online:         $(cat /sys/devices/system/cpu/online 2>/dev/null || true)"
        echo "containerd:         $(containerd --version 2>/dev/null | head -1 || echo n/a)"
        echo "containerd_path:    $(command -v containerd 2>/dev/null || echo n/a)"
        echo "runc:               $(runc --version 2>/dev/null | head -1 || echo n/a)"
        echo "runc_path:          $(command -v runc 2>/dev/null || echo n/a)"
        echo "crictl:             $(crictl --version 2>/dev/null | head -1 || echo n/a)"
        echo "shim:               $(containerd-shim-runc-v2 -v 2>/dev/null | head -1 || echo n/a)"
        if [ -x /opt/kata/runtime-rs/bin/containerd-shim-kata-v2 ]; then
            echo "kata_shim:          /opt/kata/runtime-rs/bin/containerd-shim-kata-v2"
        elif command -v containerd-shim-kata-v2 &>/dev/null; then
            echo "kata_shim:          $(command -v containerd-shim-kata-v2)"
        else
            echo "kata_shim:          n/a"
        fi
        if [ -L /opt/kata/share/defaults/kata-containers/runtime-rs/configuration.toml ]; then
            echo "kata_hypervisor_cfg: $(readlink -f /opt/kata/share/defaults/kata-containers/runtime-rs/configuration.toml 2>/dev/null || true)"
        fi
        echo "cni_conf:           $cni_conf"
        if [ -f "$cni_conf" ]; then
            echo "cni_conf_type:      $(grep -oE '"type"[[:space:]]*:[[:space:]]*"[^"]+"' "$cni_conf" 2>/dev/null | head -3 | tr '\n' ' ')"
            echo "cni_conf_sha256:    $(sha256sum "$cni_conf" 2>/dev/null | awk '{print $1}')"
        fi
        echo "containerd_config:  $cd_cfg"
        if [ -f "$cd_cfg" ]; then
            echo "containerd_cfg_sha: $(sha256sum "$cd_cfg" 2>/dev/null | awk '{print $1}')"
        fi
        local pid
        pid=$(pgrep -nx containerd 2>/dev/null || true)
        if [ -n "$pid" ]; then
            echo "containerd_pid:     $pid"
            echo "containerd_affinity:$(taskset -pc "$pid" 2>/dev/null | awk -F': ' '{print $NF}')"
        fi
        echo ""
        echo "=== numa (numactl -H) ==="
        numactl -H 2>/dev/null || echo "n/a"
        echo ""
        echo "=== node cpulist ==="
        for f in /sys/devices/system/node/node*/cpulist; do
            [ -f "$f" ] || continue
            echo "$(basename "$(dirname "$f")"): $(cat "$f")"
        done
        echo ""
        echo "=== matrix args ==="
        echo "cnis=$CNIS runtimes=$RUNTIMES hypervisors=$HYPERVISORS ip_masq=$IP_MASQ"
        echo "containerd_cpus=$CONTAINERD_COUNTS worker_cpus=$WORKER_COUNTS workers=$WORKERS_K"
        echo "worker_numa=$WORKER_NUMA sandbox_modes=$SANDBOX_MODES duration=$DURATION max_mean_ms=$MAX_MEAN_MS"
    } > "$txt"

    # 结构化 JSON：优先 resource_sampler，再叠矩阵字段
    if [ -f "$RESOURCE_SAMPLER" ]; then
        local numa0="${WORKER_NUMA%%,*}"
        numa0="${numa0// /}"
        [[ "$numa0" =~ ^[0-9]+$ ]] || numa0=0
        python3 "$RESOURCE_SAMPLER" metadata \
            --output "$json" \
            --cpus "" \
            --numa "$numa0" \
            --proc-count 0 \
            --passthru-args "config_matrix_sweep" \
            2>/dev/null || true
    fi
    python3 - "$json" "$BUILD_MODE" "$SKIP_BUILD" "$txt" <<'PY'
import json, os, sys, platform, subprocess, hashlib
from datetime import datetime, timezone

path, build_mode, skip_build, txt = sys.argv[1:5]
data = {}
if os.path.isfile(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except Exception:
        data = {}

def sh(cmd):
    try:
        return subprocess.check_output(cmd, shell=True, text=True, stderr=subprocess.DEVNULL).strip()
    except Exception:
        return ""

def sha(p):
    try:
        h = hashlib.sha256()
        with open(p, "rb") as f:
            for chunk in iter(lambda: f.read(1 << 20), b""):
                h.update(chunk)
        return h.hexdigest()
    except Exception:
        return ""

data.setdefault("host", {})
data["host"].update({
    "hostname": platform.node(),
    "kernel": platform.release(),
    "arch": platform.machine(),
    "os": platform.platform(),
    "cpu_online": sh("cat /sys/devices/system/cpu/online 2>/dev/null"),
})
data["matrix"] = {
    "timestamp": datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds"),
    "build_mode": build_mode,
    "skip_build": skip_build.lower() == "true",
    "env_baseline_txt": txt,
}
data.setdefault("runtime", {})
for name, cmd in [
    ("containerd", "containerd --version 2>/dev/null | head -1"),
    ("runc", "runc --version 2>/dev/null | head -1"),
    ("crictl", "crictl --version 2>/dev/null | head -1"),
    ("shim_runc_v2", "containerd-shim-runc-v2 -v 2>/dev/null | head -1"),
]:
    out = sh(cmd)
    if out:
        data["runtime"][name] = out
data["paths"] = {
    "containerd": sh("command -v containerd"),
    "runc": sh("command -v runc"),
    "cni_conf": "/etc/cni/net.d/10-mynet.conf",
    "containerd_config": "/etc/containerd/config.toml",
}
cni = "/etc/cni/net.d/10-mynet.conf"
cfg = "/etc/containerd/config.toml"
data["config_digest"] = {
    "cni_conf_sha256": sha(cni) if os.path.isfile(cni) else "",
    "containerd_config_sha256": sha(cfg) if os.path.isfile(cfg) else "",
}
with open(path, "w") as f:
    json.dump(data, f, indent=2, ensure_ascii=False)
    f.write("\n")
print("[env] baseline →", path)
PY

    echo "[env] baseline txt → $txt"
}

IFS=' ' read -ra CNI_ARR <<< "$(parse_csv "$CNIS")"
IFS=' ' read -ra RT_ARR <<< "$(parse_csv "$RUNTIMES")"
IFS=' ' read -ra HV_ARR <<< "$(parse_csv "$HYPERVISORS")"

[[ ${#CNI_ARR[@]} -gt 0 ]] || { echo "错误: --cnis 为空"; exit 1; }
[[ ${#RT_ARR[@]} -gt 0 ]] || { echo "错误: --runtimes 为空"; exit 1; }

for cni in "${CNI_ARR[@]}"; do
    case "$cni" in
        bridge|ipvlan-l2|ipvlan-l3) ;;
        *) echo "错误: 未知 cni: $cni"; exit 1 ;;
    esac
done
for rt in "${RT_ARR[@]}"; do
    case "$rt" in
        runc|kata) ;;
        *) echo "错误: 未知 runtime: $rt"; exit 1 ;;
    esac
done
for hv in "${HV_ARR[@]}"; do
    case "$hv" in
        dragonball|qemu|cloud-hypervisor|firecracker) ;;
        *) echo "错误: 未知 hypervisor: $hv"; exit 1 ;;
    esac
done

# 展开组合: lines of "cni|runtime|hypervisor"
COMBOS=()
for cni in "${CNI_ARR[@]}"; do
    for rt in "${RT_ARR[@]}"; do
        if [ "$rt" = "runc" ]; then
            COMBOS+=("${cni}|runc|")
        else
            if [ ${#HV_ARR[@]} -eq 0 ]; then
                echo "错误: runtime=kata 需要 --hypervisors"
                exit 1
            fi
            for hv in "${HV_ARR[@]}"; do
                COMBOS+=("${cni}|kata|${hv}")
            done
        fi
    done
done

TS=$(date +%Y%m%d%H%M%S)
MATRIX_ROOT="${REPO_DIR}/results/config_matrix/${TS}"
mkdir -p "$MATRIX_ROOT"
INDEX_CSV="${MATRIX_ROOT}/matrix_index.csv"
MERGED_CSV="${MATRIX_ROOT}/matrix_best_by_cd_n.csv"
MERGED_UNDER_CSV="${MATRIX_ROOT}/matrix_best_by_cd_n_under_mean.csv"
COLD_START_CSV="${MATRIX_ROOT}/matrix_cold_start.csv"
MATRIX_LOG="${MATRIX_ROOT}/matrix.log"
BUILD_LOG="${MATRIX_ROOT}/build.log"

exec > >(tee -a "$MATRIX_LOG") 2>&1

echo "=============================================="
echo "  配置矩阵 config_matrix_sweep"
echo "=============================================="
echo "  build-mode:       $BUILD_MODE$($SKIP_BUILD && echo ' (skip-build)' || true)"
echo "  cnis:             $CNIS"
echo "  runtimes:         $RUNTIMES"
echo "  hypervisors:      $HYPERVISORS  (仅 kata)"
echo "  ip-masq:          $IP_MASQ"
echo "  combos:           ${#COMBOS[@]}"
echo "  worker-numa:      $WORKER_NUMA"
echo "  sandbox-modes:    $SANDBOX_MODES"
echo "  containerd-cpus:  $CONTAINERD_COUNTS"
echo "  worker-cpus:      $WORKER_COUNTS"
echo "  workers K:        ${WORKERS_K:-(auto)}"
echo "  duration:         $DURATION"
echo "  max-mean-ms:      ${MAX_MEAN_MS:-(未启用)}"
echo "  cold-start-runs:  $COLD_START_RUNS$($SKIP_COLD_START && echo ' (skip)' || true)"
echo "  skip-setup:       $SKIP_SETUP"
echo "  dry-run:          $DRY_RUN"
echo "  output:           $MATRIX_ROOT"
echo "=============================================="
echo ""
echo "将运行的组合:"
for combo in "${COMBOS[@]}"; do
    IFS='|' read -r cni rt hv <<< "$combo"
    if [ "$rt" = "runc" ]; then
        echo "  - cni=$cni runtime=runc"
    else
        echo "  - cni=$cni runtime=kata hypervisor=$hv"
    fi
done
echo ""

# ---------- 1) 编译（默认 release；--profile → debug）----------
if $DRY_RUN; then
    echo "[build] dry-run：将执行 build_install_runtime --mode $BUILD_MODE"
elif $SKIP_BUILD; then
    echo "[build] --skip-build，使用当前已安装二进制"
else
    echo "[build] bash $BUILD_SCRIPT --mode $BUILD_MODE"
    set +e
    bash "$BUILD_SCRIPT" --mode "$BUILD_MODE" 2>&1 | tee "$BUILD_LOG"
    build_rc=${PIPESTATUS[0]}
    set -e
    if [ "$build_rc" -ne 0 ]; then
        echo "[build] 失败 rc=$build_rc，见 $BUILD_LOG"
        exit "$build_rc"
    fi
    echo "[build] 完成 → $BUILD_LOG"
fi

# ---------- 2) 环境基线 ----------
if $DRY_RUN; then
    echo "[env] dry-run：跳过 env_baseline 采集"
else
    write_env_baseline "$MATRIX_ROOT"
fi

# 调试：只编译+基线后退出（MATRIX_BASELINE_ONLY=1）
if [ "${MATRIX_BASELINE_ONLY:-0}" = "1" ]; then
    echo "[env] MATRIX_BASELINE_ONLY=1 → 退出（不跑矩阵）"
    echo "  txt:  ${MATRIX_ROOT}/env_baseline.txt"
    echo "  json: ${MATRIX_ROOT}/env_baseline.json"
    exit 0
fi

echo "cni,runtime,hypervisor,status,sweep_dir,best_by_cd_n,cold_start_report,note" > "$INDEX_CSV"
echo "cni,runtime,hypervisor,cd_n,tps,mean,p50,p95,p99,numa,wr_n,K,sandbox_mode,cd_cpus,wr_cpus,sandbox_cpus,status,total,success,run_dir" \
    > "$MERGED_CSV"
echo "cni,runtime,hypervisor,runs,success,fail,total_p50_ms,total_p95_ms,total_p99_ms,total_mean_ms,runp_p50_ms,runp_mean_ms,ready_p50_ms,ready_mean_ms,report" \
    > "$COLD_START_CSV"
if [ -n "$MAX_MEAN_MS" ]; then
    echo "cni,runtime,hypervisor,cd_n,tps,mean,p50,p95,p99,numa,wr_n,K,sandbox_mode,cd_cpus,wr_cpus,sandbox_cpus,status,total,success,run_dir" \
        > "$MERGED_UNDER_CSV"
fi

# 从 cold_start_report.json 抽摘要行追加到 matrix_cold_start.csv
append_cold_start_summary() {
    local cni="$1" rt="$2" hv="$3" report="$4"
    [[ -f "$report" ]] || return 0
    python3 - "$cni" "$rt" "$hv" "$report" "$COLD_START_CSV" <<'PY'
import json, sys
cni, rt, hv, path, csv_path = sys.argv[1:6]
with open(path) as f:
    d = json.load(f)
s = d.get("summary", {})
ph = d.get("phases", {})
tot = ph.get("total_ms", {})
runp = ph.get("t_runp", {})
ready = ph.get("t_ready", {})
def g(m, k):
    v = m.get(k)
    return "" if v is None else v
row = [
    cni, rt, hv,
    g(s, "total_runs"), g(s, "success_runs"), g(s, "failure_runs"),
    g(tot, "p50"), g(tot, "p95"), g(tot, "p99"), g(tot, "mean"),
    g(runp, "p50"), g(runp, "mean"),
    g(ready, "p50"), g(ready, "mean"),
    path,
]
with open(csv_path, "a") as f:
    f.write(",".join(str(x) for x in row) + "\n")
PY
}

combo_slug() {
    local cni="$1" rt="$2" hv="$3"
    if [ "$rt" = "runc" ]; then
        echo "${cni}_${rt}"
    else
        echo "${cni}_${rt}_${hv}"
    fi
}

append_best_csv() {
    local src="$1" dest="$2"
    [[ -f "$src" ]] || return 0
    tail -n +2 "$src" >> "$dest" || true
}

run_one_combo() {
    local cni="$1" rt="$2" hv="$3"
    local slug sweep_dir status note setup_args=() sweep_args=()

    slug=$(combo_slug "$cni" "$rt" "$hv")
    sweep_dir="${MATRIX_ROOT}/${slug}"
    mkdir -p "$sweep_dir"
    status="ok"
    note=""

    echo ""
    echo "######## 组合: cni=$cni runtime=$rt hypervisor=${hv:--} ########"

    local cold_report="${sweep_dir}/cold_start_report.json"

    if $DRY_RUN; then
        echo "[dry-run] setup --cni-type $cni --runtime $rt ${hv:+--hypervisor $hv} --ip-masq $IP_MASQ --no-warmup"
        if ! $SKIP_COLD_START; then
            echo "[dry-run] cold_start_bench --runtime $rt --runs $COLD_START_RUNS --output $cold_report"
        fi
        echo "[dry-run] throughput_sweep --out-root $sweep_dir --runtime $rt ..."
        echo "$cni,$rt,$hv,dry-run,$sweep_dir,,$cold_report,dry-run" >> "$INDEX_CSV"
        return 0
    fi

    if ! $SKIP_SETUP; then
        # setup 内默认 warmup 跳过；改由本脚本显式跑 cold_start_bench 并落盘
        setup_args=(--cni-type "$cni" --runtime "$rt" --ip-masq "$IP_MASQ" --no-warmup)
        if [ "$rt" = "kata" ]; then
            setup_args+=(--hypervisor "$hv")
        fi
        echo "[setup] bash $SETUP_SCRIPT ${setup_args[*]}"
        set +e
        sudo bash "$SETUP_SCRIPT" "${setup_args[@]}"
        local setup_rc=$?
        set -e
        if [ "$setup_rc" -ne 0 ]; then
            status="setup_fail"
            note="setup_exit_$setup_rc"
            echo "[setup] 失败 rc=$setup_rc，跳过本组合压测"
            echo "$cni,$rt,$hv,$status,$sweep_dir,,,${note}" >> "$INDEX_CSV"
            return 0
        fi
        # 每组合切换后追加一份轻量快照
        write_env_baseline "$sweep_dir" >/dev/null || true
        cp -f "${sweep_dir}/env_baseline.txt" "${MATRIX_ROOT}/env_baseline_${slug}.txt" 2>/dev/null || true
    else
        echo "[setup] --skip-setup，跳过环境切换"
    fi

    # ---- 冷启动时延（cold_start_bench.py）----
    if ! $SKIP_COLD_START; then
        echo "[cold-start] python3 $COLD_START_PY --runtime $rt --runs $COLD_START_RUNS --output $cold_report"
        set +e
        (cd "$REPO_DIR" && python3 "$COLD_START_PY" \
            --runtime "$rt" \
            --runs "$COLD_START_RUNS" \
            --output "$cold_report")
        local cold_rc=$?
        set -e
        if [ "$cold_rc" -ne 0 ]; then
            note="${note:+$note;}cold_start_exit_$cold_rc"
            echo "[cold-start] 失败 rc=$cold_rc（继续吞吐扫描）"
        elif [[ -f "$cold_report" ]]; then
            append_cold_start_summary "$cni" "$rt" "$hv" "$cold_report"
            echo "[cold-start] 报告 → $cold_report"
        else
            note="${note:+$note;}cold_start_missing_report"
            echo "[cold-start] 未生成报告文件"
        fi
    else
        echo "[cold-start] --skip-cold-start，跳过"
        cold_report=""
    fi

    sweep_args=(
        --containerd-cpus "$CONTAINERD_COUNTS"
        --worker-cpus "$WORKER_COUNTS"
        --worker-numa "$WORKER_NUMA"
        --sandbox-modes "$SANDBOX_MODES"
        --duration "$DURATION"
        --preconfig "$PRECONFIG"
        --runtime "$rt"
        --label-cni "$cni"
        --label-hypervisor "$hv"
        --out-root "$sweep_dir"
    )
    [[ -n "$WORKERS_K" ]] && sweep_args+=(--workers "$WORKERS_K")
    [[ -n "$MAX_MEAN_MS" ]] && sweep_args+=(--max-mean-ms "$MAX_MEAN_MS")
    [[ -n "$MEMS_OVERRIDE" ]] && sweep_args+=(--mems "$MEMS_OVERRIDE")
    [[ -n "$HOST_CPUS" ]] && sweep_args+=(--host-cpus "$HOST_CPUS")
    $ALLOW_CPU0 && sweep_args+=(--allow-cpu0)
    [[ -n "$CONFIRM_DURATION" ]] && sweep_args+=(--confirm-duration "$CONFIRM_DURATION")
    [[ "${CONFIRM_TOP:-0}" -gt 0 ]] && sweep_args+=(--confirm-top "$CONFIRM_TOP")

    echo "[sweep] bash $SWEEP_SCRIPT ${sweep_args[*]}"
    set +e
    bash "$SWEEP_SCRIPT" "${sweep_args[@]}"
    local sweep_rc=$?
    set -e
    if [ "$sweep_rc" -ne 0 ]; then
        status="sweep_fail"
        note="sweep_exit_$sweep_rc"
    fi

    local best_csv="${sweep_dir}/best_by_cd_n.csv"
    if [[ -f "$best_csv" ]]; then
        append_best_csv "$best_csv" "$MERGED_CSV"
    else
        [[ "$status" = "ok" ]] && status="no_best_by_cd"
        note="${note:+$note;}missing_best_by_cd_n"
    fi
    if [ -n "$MAX_MEAN_MS" ] && [[ -f "${sweep_dir}/best_by_cd_n_under_mean.csv" ]]; then
        append_best_csv "${sweep_dir}/best_by_cd_n_under_mean.csv" "$MERGED_UNDER_CSV"
    fi

    echo "$cni,$rt,$hv,$status,$sweep_dir,${best_csv},${cold_report},$note" >> "$INDEX_CSV"
    echo "[combo] 完成 status=$status → $sweep_dir"
}

# ---------- 3) 矩阵 ----------
for combo in "${COMBOS[@]}"; do
    IFS='|' read -r cni rt hv <<< "$combo"
    run_one_combo "$cni" "$rt" "$hv"
done

echo ""
echo "=============================================="
echo "  矩阵汇总"
echo "=============================================="
echo "  build-mode:         $BUILD_MODE"
echo "  env_baseline:       ${MATRIX_ROOT}/env_baseline.txt"
echo "  env_baseline.json:  ${MATRIX_ROOT}/env_baseline.json"
echo "  cold_start:         $COLD_START_CSV"
echo "  index:              $INDEX_CSV"
echo "  best_by_cd_n:       $MERGED_CSV"
if [ -n "$MAX_MEAN_MS" ]; then
    echo "  best_by_cd_n(mean): $MERGED_UNDER_CSV"
fi
echo "  log:                $MATRIX_LOG"
echo ""

if ! $DRY_RUN && [[ -f "$COLD_START_CSV" ]] && [[ $(wc -l < "$COLD_START_CSV") -gt 1 ]]; then
    echo "  各配置冷启动时延 (cold_start_bench):"
    printf "  %-14s %-8s %-18s %-8s %-10s %-10s %-10s\n" \
        "cni" "runtime" "hypervisor" "success" "total_p50" "total_p95" "total_mean"
    echo "  --------------------------------------------------------------------------------"
    tail -n +2 "$COLD_START_CSV" | while IFS=',' read -r cni rt hv runs suc fail tp50 tp95 tp99 tmean rest; do
        printf "  %-14s %-8s %-18s %-8s %-10s %-10s %-10s\n" \
            "$cni" "$rt" "${hv:--}" "$suc/$runs" "${tp50}ms" "${tp95}ms" "${tmean}ms"
    done
    echo ""
fi

if ! $DRY_RUN && [[ -f "$MERGED_CSV" ]] && [[ $(wc -l < "$MERGED_CSV") -gt 1 ]]; then
    echo "  各配置 × containerd 核数 最大吞吐:"
    printf "  %-14s %-8s %-18s %-6s %-10s %-10s %-6s %-6s\n" \
        "cni" "runtime" "hypervisor" "cd_n" "tps" "mean_ms" "wr_n" "K"
    echo "  --------------------------------------------------------------------------------"
    tail -n +2 "$MERGED_CSV" | while IFS=',' read -r cni rt hv cd_n tps mean p50 p95 p99 numa wr_n K rest; do
        printf "  %-14s %-8s %-18s %-6s %-10s %-10s %-6s %-6s\n" \
            "$cni" "$rt" "${hv:--}" "$cd_n" "${tps}/s" "$mean" "$wr_n" "$K"
    done
    echo ""
fi

echo "=============================================="
echo "  矩阵扫描完成 → $MATRIX_ROOT"
echo "=============================================="
