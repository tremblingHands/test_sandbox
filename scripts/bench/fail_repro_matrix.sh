#!/usr/bin/env bash
# 小矩阵复现：抓 FAIL error + journal 片段，定位 total>success 原因。
# 固定 cd=4 wr=64；扫 bridge/ipvlan × runc/(kata+qemu) × K=64/128。
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/../.." && pwd)"
SETUP_SCRIPT="${REPO_DIR}/scripts/setup/setup.sh"
SWEEP_SCRIPT="${SCRIPT_DIR}/throughput_sweep.sh"

STAMP=$(date +%Y%m%d%H%M%S)
OUT_ROOT="${REPO_DIR}/results/fail_repro/${STAMP}"
mkdir -p "$OUT_ROOT"
LOG="${OUT_ROOT}/repro.log"

DURATION="${DURATION:-20}"
IP_MASQ="${IP_MASQ:-false}"

exec > >(tee -a "$LOG") 2>&1

echo "=============================================="
echo "  FAIL 复现小矩阵"
echo "=============================================="
echo "  out:      $OUT_ROOT"
echo "  duration: ${DURATION}s"
echo "  crictl:   $(grep -E '^(timeout|runtime-endpoint)' /etc/crictl.yaml 2>/dev/null | tr '\n' ' ')"
echo "=============================================="

summarize_errors() {
    local run_root="$1"
    python3 - <<PY
import json, glob, collections, os
root = "$run_root"
hist = collections.Counter()
tot = suc = fail = 0
for f in glob.glob(root + "/runs/*/multi_results/proc*_cpu*_node*.json"):
    d = json.load(open(f))
    tot += d["summary"]["total_sandboxes"]
    suc += d["summary"]["success"]
    fail += d["summary"].get("failed", 0)
    for r in d.get("results", []):
        if r.get("sandbox_id") == "FAIL" and r.get("error"):
            hist[r["error"]] += 1
print("  aggregate: total={} success={} failed={}".format(tot, suc, fail))
if hist:
    print("  FAIL error Top:")
    for e, c in hist.most_common(10):
        print("    [{:>4}] {}".format(c, e))
else:
    print("  (no error fields — bench too old or no FAIL)")
# also dump per-run summary.csv lines with total>success
csv = os.path.join(root, "summary.csv")
if os.path.isfile(csv):
    print("  summary.csv rows:")
    with open(csv) as fh:
        hdr = fh.readline().strip()
        for line in fh:
            print("   ", line.strip())
PY
}

capture_journal() {
    local tag="$1" since="$2"
    local jf="${OUT_ROOT}/journal_${tag}.log"
    journalctl -u containerd --since "$since" --no-pager 2>/dev/null \
        | rg -i "DeadlineExceeded|context deadline|failed to|CNI|RunPodSandbox|error|ipvlan|kata" \
        | tail -n 200 > "$jf" || true
    echo "  journal snippet → $jf ($(wc -l < "$jf") lines)"
}

run_combo() {
    local cni="$1" rt="$2" hv="${3:-}"
    local slug
    if [ "$rt" = "runc" ]; then
        slug="${cni}_${rt}"
    else
        slug="${cni}_${rt}_${hv}"
    fi
    local sweep_dir="${OUT_ROOT}/${slug}"
    mkdir -p "$sweep_dir"

    echo ""
    echo "######## ${slug} ########"
    local since
    since=$(date '+%Y-%m-%d %H:%M:%S')

    local setup_args=(--cni-type "$cni" --runtime "$rt" --ip-masq "$IP_MASQ")
    if [ "$rt" = "kata" ]; then
        setup_args+=(--hypervisor "$hv")
    fi
    echo "[setup] ${setup_args[*]}"
    set +e
    bash "$SETUP_SCRIPT" "${setup_args[@]}"
    local rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        echo "[setup] FAIL rc=$rc — skip sweep"
        echo "$cni,$rt,${hv:-},setup_fail" >> "${OUT_ROOT}/index.csv"
        return 0
    fi

    echo "[sweep] cd=4 wr=64 K=64,128 duration=${DURATION}s"
    set +e
    bash "$SWEEP_SCRIPT" \
        --containerd-cpus 4 \
        --worker-cpus 64 \
        --worker-numa 1 \
        --containerd-numa 0 \
        --sandbox-modes excl-cd \
        --workers 64,128 \
        --duration "$DURATION" \
        --preconfig 50 \
        --runtime "$rt" \
        --label-cni "$cni" \
        --label-hypervisor "${hv:-}" \
        --out-root "$sweep_dir"
    rc=$?
    set -e
    echo "[sweep] rc=$rc"
    summarize_errors "$sweep_dir"
    capture_journal "$slug" "$since"
    echo "$cni,$rt,${hv:-},ok,$sweep_dir" >> "${OUT_ROOT}/index.csv"
}

echo "cni,runtime,hypervisor,status,dir" > "${OUT_ROOT}/index.csv"

# 对照顺序：先 bridge/runc 基线，再加压与切换
run_combo bridge runc
run_combo bridge kata qemu
run_combo ipvlan-l3 runc
run_combo ipvlan-l3 kata qemu

echo ""
echo "=============================================="
echo "  完成 → $OUT_ROOT"
echo "=============================================="
