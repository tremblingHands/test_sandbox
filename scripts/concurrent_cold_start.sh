#!/bin/bash
# 并发 Pod 沙箱冷启动测试
# 按轮次并发创建沙箱，每轮 N 个并发，共创建 M 个沙箱。
#
# 用法:
#   # 首次使用先准备环境
#   ./scripts/setup.sh
#
#   # 运行并发测试
#   ./concurrent_cold_start.sh <每轮并发数N> <总沙箱数M>
#
# 示例:
#   ./concurrent_cold_start.sh 10 30     # 每轮 10 并发，共 30 沙箱（3 轮）
#   ./concurrent_cold_start.sh 50 200    # 每轮 50 并发，共 200 沙箱（4 轮）
#   ./concurrent_cold_start.sh 5 5       # 每轮 5 并发，共 5 沙箱（1 轮）
#
# 前置条件（脚本运行时自动检查，也可用 setup.sh 一次性准备）:
#   - containerd 运行中 + crictl 可用
#   - pause 镜像已缓存（缺失则自动拉取）

set -euo pipefail

CONCURRENCY=${1:-10}        # 每轮并发数 N
TOTAL=${2:-30}              # 总沙箱数 M

PAUSE_IMAGE="registry.aliyuncs.com/google_containers/pause:3.9"
RESULT_DIR="/tmp/conc-start-results"
POD_CONFIG_DIR="/tmp/conc-pod-configs"
LOG_PREFIX="$RESULT_DIR/conc-times"

# 计算总轮次
ROUNDS=$(( (TOTAL + CONCURRENCY - 1) / CONCURRENCY ))

# ============================================================
# 初始化
# ============================================================
init() {
    # 清理上次测试的残留日志和临时文件
    rm -rf "$RESULT_DIR" "$POD_CONFIG_DIR"
    mkdir -p "$RESULT_DIR" "$POD_CONFIG_DIR"

    echo "=== 并发 Pod 沙箱冷启动测试 ==="
    echo "每轮并发数:  $CONCURRENCY"
    echo "总沙箱数:    $TOTAL"
    echo "总轮次:      $ROUNDS (最后一轮 $(( TOTAL - (ROUNDS - 1) * CONCURRENCY )) 个)"
    echo "运行时:      runc (via crictl)"
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
    local count="$2"   # 本轮要创建的沙箱数
    rm -f "$POD_CONFIG_DIR"/*.json

    for i in $(seq 1 "$count"); do
        local uid="conc-$(date +%s%N)-r${round}-${i}"
        cat > "$POD_CONFIG_DIR/pod-${i}.json" <<JSONEOF
{
  "metadata": {
    "name": "conc-bench-r${round}-${i}",
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
# 单轮并发测试
# ============================================================
run_concurrent_round() {
    local round="$1"
    local count="$2"    # 本轮并发数（最后一轮可能 < CONCURRENCY）
    local time_log="$LOG_PREFIX-r${round}.log"
    local wall_clock_file="$LOG_PREFIX-wall-r${round}.txt"

    echo "[第 $round 轮 / 共 $ROUNDS 轮] 并发创建 $count 个 Pod 沙箱..."
    generate_pod_configs "$round" "$count"

    echo "[第 $round 轮] 清除缓存..."
    echo 3 > /proc/sys/vm/drop_caches
    sleep 2

    # 记录挂钟开始时间
    local start_ns
    start_ns=$(date +%s%N)

    # 并发执行 crictl runp，各自记录耗时
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
        ) >> "$time_log" &
    done
    wait

    local end_ns
    end_ns=$(date +%s%N)
    local wall_ms=$(( (end_ns - start_ns) / 1000000 ))
    echo "$wall_ms" > "$wall_clock_file"

    local ok_count
    ok_count=$(grep -c ' OK$' "$time_log" 2>/dev/null || echo 0)
    echo "  挂钟耗时: ${wall_ms}ms  (成功: $ok_count/$count)"

    # ---- 等待所有沙箱就绪 ---- #
    echo "[第 $round 轮] 等待所有沙箱就绪..."
    local ready_start ready_end
    ready_start=$(date +%s%N)

    local ready_count=0
    for i in $(seq 1 "$count"); do
        local sand_id
        sand_id=$(crictl pods --name "conc-bench-r${round}-${i}" -q 2>/dev/null | head -1)
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

    ready_end=$(date +%s%N)
    local ready_ms=$(( (ready_end - ready_start) / 1000000 ))
    echo "  就绪等待: ${ready_ms}ms  (就绪: $ready_count/$count)"

    # ---- 清理 ---- #
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
    echo "各沙箱单次 runp 耗时统计:"
    echo "=========================================="

    # 汇总所有 OK 行的耗时
    local all_times
    all_times=$(grep -oh '[0-9]\+ms OK$' "$LOG_PREFIX"-r*.log 2>/dev/null | sed 's/ms OK//' | sort -n)

    if [ -z "$all_times" ]; then
        echo "  (无数据)"
        return
    fi

    local count min max
    count=$(echo "$all_times" | wc -l)
    min=$(echo "$all_times" | head -1)
    max=$(echo "$all_times" | tail -1)

    # 中位数
    local mid
    mid=$(( (count + 1) / 2 ))
    local median
    median=$(echo "$all_times" | sed -n "${mid}p")

    # P95
    local p95_idx
    p95_idx=$(echo "$count * 0.95" | bc | awk '{print int($1+0.5)}')
    [ "$p95_idx" -lt 1 ] && p95_idx=1
    local p95
    p95=$(echo "$all_times" | sed -n "${p95_idx}p")

    # 平均值
    local sum mean
    sum=$(echo "$all_times" | paste -sd+ | bc)
    mean=$(( sum / count ))

    echo "  样本数: $count (计划 $TOTAL)"
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
    for f in $(ls "$LOG_PREFIX"-r*.log 2>/dev/null | sort -V); do
        if [ -f "$f" ]; then
            local round_name
            round_name=$(basename "$f" .log | sed 's/.*-r//')
            local times
            times=$(grep -oh '[0-9]\+ms OK$' "$f" 2>/dev/null | sed 's/ms OK//' | sort -n)
            if [ -n "$times" ]; then
                local r_count r_min r_max
                r_count=$(echo "$times" | wc -l)
                r_min=$(echo "$times" | head -1)
                r_max=$(echo "$times" | tail -1)
                # 本轮中位数
                local r_mid r_median
                r_mid=$(( (r_count + 1) / 2 ))
                r_median=$(echo "$times" | sed -n "${r_mid}p")
                printf "  r%s: 样本=%d  中位数=%sms  最小=%sms  最大=%sms\n" \
                    "$round_name" "$r_count" "$r_median" "$r_min" "$r_max"
            fi
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

    local created=0
    for round in $(seq 1 "$ROUNDS"); do
        local remaining=$(( TOTAL - created ))
        local count=$(( remaining < CONCURRENCY ? remaining : CONCURRENCY ))
        run_concurrent_round "$round" "$count"
        created=$(( created + count ))
    done

    print_summary

    echo "详细日志: $RESULT_DIR"
}

main
