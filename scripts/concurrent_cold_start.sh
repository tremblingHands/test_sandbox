#!/bin/bash
# 并发 Pod 沙箱冷启动测试
# 共 K 轮，每轮创建 M 个沙箱（最多 N 个并发），总计 M×K 个沙箱。
#
# 用法:
#   # 首次使用先准备环境
#   ./scripts/setup.sh
#
#   # 运行并发测试
#   ./concurrent_cold_start.sh <并发数N> <每轮沙箱数M> <总轮次K>
#
# 示例:
#   ./concurrent_cold_start.sh 3 5 2     # 2 轮，每轮 5 沙箱/3 并发 → 共 10 沙箱
#   ./concurrent_cold_start.sh 10 10 3   # 3 轮，每轮 10 沙箱/10 并发 → 共 30 沙箱
#   ./concurrent_cold_start.sh 10 50 4   # 4 轮，每轮 50 沙箱/10 并发 → 共 200 沙箱
#
# 前置条件（脚本运行时自动检查，也可用 setup.sh 一次性准备）:
#   - containerd 运行中 + crictl 可用
#   - pause 镜像已缓存（缺失则自动拉取）

set -euo pipefail

CONCURRENCY=${1:-10}        # 每批并发数 N
PER_ROUND=${2:-30}          # 每轮沙箱数 M
TOTAL_ROUNDS=${3:-3}        # 总轮次 K

# 每轮内的批次数 = ceil(M / N)
BATCHES_PER_ROUND=$(( (PER_ROUND + CONCURRENCY - 1) / CONCURRENCY ))
TOTAL_SANDBOXES=$(( PER_ROUND * TOTAL_ROUNDS ))

PAUSE_IMAGE="registry.aliyuncs.com/google_containers/pause:3.9"
RESULT_DIR="/tmp/conc-start-results"
POD_CONFIG_DIR="/tmp/conc-pod-configs"
LOG_PREFIX="$RESULT_DIR/conc-times"

# ============================================================
# 初始化
# ============================================================
init() {
    rm -rf "$RESULT_DIR" "$POD_CONFIG_DIR"
    mkdir -p "$RESULT_DIR" "$POD_CONFIG_DIR"

    echo "=== 并发 Pod 沙箱冷启动测试 ==="
    echo "每批并发数:    $CONCURRENCY"
    echo "每轮沙箱数:    $PER_ROUND (每轮 $BATCHES_PER_ROUND 批)"
    echo "总轮次:        $TOTAL_ROUNDS"
    echo "总计沙箱数:    $TOTAL_SANDBOXES"
    echo "运行时:        runc (via crictl)"
    echo

    # 确保 pause 镜像已缓存
    if ! crictl images 2>/dev/null | grep -q "$PAUSE_IMAGE"; then
        echo "[init] 缓存 pause 镜像..."
        crictl pull "$PAUSE_IMAGE"
    else
        echo "[init] pause 镜像已缓存 ✓"
    fi
    echo
}

# ============================================================
# 生成 Pod 配置
# ============================================================
generate_pod_configs() {
    local round="$1"
    local batch="$2"
    local count="$3"   # 本批要创建的沙箱数
    rm -f "$POD_CONFIG_DIR"/*.json

    for i in $(seq 1 "$count"); do
        local uid="conc-$(date +%s%N)-r${round}-b${batch}-${i}"
        cat > "$POD_CONFIG_DIR/pod-${i}.json" <<JSONEOF
{
  "metadata": {
    "name": "conc-bench-r${round}-b${batch}-${i}",
    "namespace": "default",
    "uid": "$uid",
    "attempt": 1
  },
  "log_directory": "/tmp/sandbox-logs",
  "linux": {
    "security_context": {
      "namespace_options": {"network": 0}
    }
  }
}
JSONEOF
    done
}

# ============================================================
# 单批并发创建
# 返回：挂钟耗时（通过全局变量 BATCH_WALL_MS）
# ============================================================
run_batch() {
    local round="$1"
    local batch="$2"
    local count="$3"    # 本批并发数（最后一批可能 < CONCURRENCY）
    local batch_log="$LOG_PREFIX-r${round}-b${batch}.log"

    echo "    第 ${batch} 批: 并发创建 $count 个 Pod 沙箱..."

    generate_pod_configs "$round" "$batch" "$count"

    local start_ns
    start_ns=$(date +%s%N)

    for i in $(seq 1 "$count"); do
        (
            local pod_config="$POD_CONFIG_DIR/pod-${i}.json"
            local t0 t1 elapsed_ms
            t0=$(date +%s%N)
            if crictl runp --runtime runc "$pod_config" > /dev/null 2>&1; then
                t1=$(date +%s%N)
                elapsed_ms=$(( (t1 - t0) / 1000000 ))
                echo "sandbox-$i ${elapsed_ms}ms OK"
            else
                echo "sandbox-$i - FAIL"
            fi
        ) >> "$batch_log" &
    done
    wait

    local end_ns
    end_ns=$(date +%s%N)
    BATCH_WALL_MS=$(( (end_ns - start_ns) / 1000000 ))

    local ok_count
    ok_count=$(grep -c ' OK$' "$batch_log" 2>/dev/null || echo 0)
    echo "    批挂钟耗时: ${BATCH_WALL_MS}ms  (成功: $ok_count/$count)"
}

# ============================================================
# 单轮测试 = 多批并发
# ============================================================
run_one_round() {
    local round="$1"

    echo "[第 $round 轮 / 共 $TOTAL_ROUNDS 轮] 创建 $PER_ROUND 个沙箱 ($BATCHES_PER_ROUND 批 × 最多 $CONCURRENCY 并发)"

    echo "[第 $round 轮] 清除缓存..."
    echo 3 > /proc/sys/vm/drop_caches
    sleep 2

    # 轮次开始时间
    local round_start_ns
    round_start_ns=$(date +%s%N)

    # --- 分批并发 --- #
    local created=0
    for batch in $(seq 1 "$BATCHES_PER_ROUND"); do
        local remaining=$(( PER_ROUND - created ))
        local count=$(( remaining < CONCURRENCY ? remaining : CONCURRENCY ))
        run_batch "$round" "$batch" "$count"
        created=$(( created + count ))
    done

    # 轮次挂钟
    local round_end_ns
    round_end_ns=$(date +%s%N)
    local round_wall_ms=$(( (round_end_ns - round_start_ns) / 1000000 ))
    echo "$round_wall_ms" > "$LOG_PREFIX-wall-r${round}.txt"
    echo "  轮挂钟耗时: ${round_wall_ms}ms"

    # --- 等待所有沙箱就绪 --- #
    echo "[第 $round 轮] 等待所有沙箱就绪..."
    local ready_start_ns ready_end_ns
    ready_start_ns=$(date +%s%N)

    local ready_count=0
    for batch in $(seq 1 "$BATCHES_PER_ROUND"); do
        local remaining=$(( PER_ROUND - (batch - 1) * CONCURRENCY ))
        local count=$(( remaining < CONCURRENCY ? remaining : CONCURRENCY ))
        for i in $(seq 1 "$count"); do
            local sand_id
            sand_id=$(crictl pods --name "conc-bench-r${round}-b${batch}-${i}" -q 2>/dev/null | head -1)
            if [ -z "$sand_id" ]; then
                continue
            fi
            if timeout 30 sh -c "
                while true; do
                    if crictl inspectp '$sand_id' 2>/dev/null | grep -q 'SANDBOX_READY'; then
                        exit 0
                    fi
                    sleep 0.01
                done
            " 2>/dev/null; then
                ready_count=$((ready_count + 1))
            fi
        done
    done

    ready_end_ns=$(date +%s%N)
    local ready_ms=$(( (ready_end_ns - ready_start_ns) / 1000000 ))
    echo "  就绪等待: ${ready_ms}ms  (就绪: $ready_count/$PER_ROUND)"

    # --- 清理本轮的沙箱 --- #
    echo "[第 $round 轮] 清理沙箱..."
    for sand_id in $(crictl pods -q --name "conc-bench-r${round}" 2>/dev/null); do
        crictl stopp "$sand_id" &>/dev/null || true
        crictl rmp "$sand_id" &>/dev/null || true
    done
    echo "  清理完成"
    echo
}

# ============================================================
# 汇总报告
# ============================================================
print_summary() {
    echo "=========================================="
    echo "各轮挂钟总耗时（ms）:"
    echo "=========================================="
    for f in $(ls "$LOG_PREFIX"-wall-r*.txt 2>/dev/null | sort -V); do
        if [ -f "$f" ]; then
            local round_name
            round_name=$(basename "$f" .txt | sed 's/.*-wall-//')
            printf "  %s: %s ms\n" "$round_name" "$(cat "$f")"
        fi
    done

    echo
    echo "=========================================="
    echo "各沙箱单次 runp 耗时统计（全部轮次汇总）:"
    echo "=========================================="

    local all_times
    all_times=$(grep -oh '[0-9]\+ms OK$' "$LOG_PREFIX"-r*-b*.log 2>/dev/null | sed 's/ms OK//' | sort -n)

    if [ -z "$all_times" ]; then
        echo "  (无数据)"
        return
    fi

    local count min max
    count=$(echo "$all_times" | wc -l)
    min=$(echo "$all_times" | head -1)
    max=$(echo "$all_times" | tail -1)

    local mid
    mid=$(( (count + 1) / 2 ))
    local median
    median=$(echo "$all_times" | sed -n "${mid}p")

    local p95_idx
    p95_idx=$(echo "$count * 0.95" | bc | awk '{print int($1+0.5)}')
    [ "$p95_idx" -lt 1 ] && p95_idx=1
    local p95
    p95=$(echo "$all_times" | sed -n "${p95_idx}p")

    local sum mean
    sum=$(echo "$all_times" | paste -sd+ | bc)
    mean=$(( sum / count ))

    echo "  样本数: $count (计划 $TOTAL_SANDBOXES)"
    echo "  Min:    ${min}ms"
    echo "  P50:    ${median}ms"
    echo "  P95:    ${p95}ms"
    echo "  Max:    ${max}ms"
    echo "  Mean:   ${mean}ms"

    # 按轮次统计
    echo
    echo "=========================================="
    echo "各轮次耗时分布:"
    echo "=========================================="
    for r in $(seq 1 "$TOTAL_ROUNDS"); do
        local times
        times=$(grep -oh '[0-9]\+ms OK$' "$LOG_PREFIX"-r${r}-b*.log 2>/dev/null | sed 's/ms OK//' | sort -n)
        if [ -n "$times" ]; then
            local r_count r_min r_max
            r_count=$(echo "$times" | wc -l)
            r_min=$(echo "$times" | head -1)
            r_max=$(echo "$times" | tail -1)
            local r_mid r_median
            r_mid=$(( (r_count + 1) / 2 ))
            r_median=$(echo "$times" | sed -n "${r_mid}p")
            printf "  r%s: 样本=%d  中位数=%sms  最小=%sms  最大=%sms\n" \
                "$r" "$r_count" "$r_median" "$r_min" "$r_max"
        fi
    done
    echo
}

# ============================================================
# 清理函数
# ============================================================
cleanup() {
    echo "[cleanup] 清理残留沙箱..."
    for sand_id in $(crictl pods -q --name conc-bench 2>/dev/null); do
        crictl stopp "$sand_id" &>/dev/null || true
        crictl rmp "$sand_id" &>/dev/null || true
    done
    rm -rf "$POD_CONFIG_DIR"
    echo "[cleanup] 完成"
}
trap cleanup EXIT

# ============================================================
# 主流程
# ============================================================
main() {
    init

    for round in $(seq 1 "$TOTAL_ROUNDS"); do
        run_one_round "$round"
    done

    print_summary

    echo "详细日志: $RESULT_DIR"
}

main
