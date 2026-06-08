#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
并发 Pod 沙箱冷启动扩展性评估
遍历并发线程数 (1,2,4,8,...N), 每级运行固定时间, 测量吞吐量和延迟。

用法:
    python3 scripts/scale_bench.py --max-concurrency 256 --duration 30
"""

import time
import subprocess
import json
import argparse
import sys
import os

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
CONCURRENT_SCRIPT = os.path.join(SCRIPT_DIR, "concurrent_cold_start.py")
RESULTS_DIR = "results"


def run_level(concurrency, duration, runtime, mode):
    """运行一个并发级别, 返回结果摘要"""
    output_file = "{}/scale-c{}.json".format(RESULTS_DIR, concurrency)
    log_file = "{}/scale-c{}.log".format(RESULTS_DIR, concurrency)

    cmd = [
        "python3", CONCURRENT_SCRIPT,
        "--concurrency", str(concurrency),
        "--duration", str(duration),
        "--rounds", "1",
        "--mode", mode,
        "--runtime", runtime,
        "--output", output_file,
    ]

    print("  [concurrency={}] 运行中...".format(concurrency), end=" ", flush=True)
    t0 = time.perf_counter()

    with open(log_file, "w") as log_f:
        rc = subprocess.call(cmd, stdout=log_f, stderr=subprocess.STDOUT)

    elapsed = time.perf_counter() - t0

    if rc != 0:
        print("FAIL (exit={}, 日志: {})".format(rc, log_file))
        return None

    # 读取 JSON 结果
    try:
        with open(output_file) as f:
            report = json.load(f)
    except Exception:
        print("FAIL (无法读取 {})".format(output_file))
        return None

    phases = report.get("phases", {})
    summary = report.get("summary", {})
    t_runp = phases.get("t_runp", {})
    t_ready = phases.get("t_ready", {})
    total_stats = phases.get("total", {})

    total_sandboxes = summary.get("total_sandboxes", 0)
    throughput = total_sandboxes / duration if duration > 0 else 0
    success_count = summary.get("success", total_sandboxes)
    failed_count = summary.get("failed", 0)
    total_count = success_count + failed_count
    success_rate = success_count / total_count * 100 if total_count > 0 else 0

    result = {
        "concurrency": concurrency,
        "total_sandboxes": total_sandboxes,
        "wall_seconds": round(elapsed, 1),
        "throughput": round(throughput, 1),
        "success": success_count,
        "failed": failed_count,
        "success_rate": round(success_rate, 1),
        "total_p50": round(total_stats.get("p50", 0), 1),
        "total_p95": round(total_stats.get("p95", 0), 1),
        "total_p99": round(total_stats.get("p99", 0), 1),
        "total_mean": round(total_stats.get("mean", 0), 1),
        "t_runp_p50": round(t_runp.get("p50", 0), 1),
        "t_runp_p95": round(t_runp.get("p95", 0), 1),
        "t_runp_p99": round(t_runp.get("p99", 0), 1),
        "t_runp_mean": round(t_runp.get("mean", 0), 1),
    }
    print("{} sandboxes, {:.1f}/s, {}% OK, P50={:.0f}ms P99={:.0f}ms".format(
        total_sandboxes, throughput, result["success_rate"], result["total_p50"], result["total_p99"]))
    return result


def print_table(results):
    """打印汇总表"""
    print("")
    print("=" * 130)
    print("并发扩展性测试结果 (runtime={}, mode={})".format(args.runtime, args.mode))
    print("=" * 130)
    print("{:>6} {:>10} {:>10} {:>10} {:>10} {:>10} {:>10} {:>10} {:>10} {:>8}".format(
        "并发", "沙箱总数", "吞吐量/s", "%OK", "P50(ms)", "P95(ms)", "P99(ms)", "Mean(ms)", "runpP50", "runpP95"))
    print("-" * 130)

    prev_tp = 0
    for r in results:
        tp_str = "{:.1f}".format(r["throughput"])
        if prev_tp > 0 and r["throughput"] < prev_tp * 1.05:
            tp_str += " ~"
        prev_tp = r["throughput"]

        ok_str = "{:.0f}%".format(r["success_rate"]) if r["success_rate"] >= 99 else "{:.0f}%!".format(r["success_rate"])

        print("{:>6} {:>10} {:>10} {:>10} {:>10.0f} {:>10.0f} {:>10.0f} {:>10.0f} {:>10.0f} {:>10.0f}".format(
            r["concurrency"], r["total_sandboxes"], tp_str, ok_str,
            r["total_p50"], r["total_p95"], r["total_p99"], r["total_mean"],
            r["t_runp_p50"], r["t_runp_p95"]))

    print("-" * 130)
    print("~ 表示吞吐量趋于饱和")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="并发 Pod 沙箱扩展性测试"
    )
    parser.add_argument("--min-concurrency", type=int, default=1,
                        help="起始并发线程数 (默认 1)")
    parser.add_argument("--max-concurrency", type=int, default=256,
                        help="最大并发线程数 (默认 256)")
    parser.add_argument("--duration", type=int, default=30,
                        help="每级测试持续时间秒 (默认 30)")
    parser.add_argument("--runtime", choices=["runc", "kata"], default="runc",
                        help="OCI 运行时 (默认 runc)")
    parser.add_argument("--mode", choices=["continuous", "serial"],
                        default="continuous",
                        help="模式 (默认 continuous)")
    parser.add_argument("--output", default="results/scale_report.json",
                        help="汇总报告输出路径")
    args = parser.parse_args()

    if not os.path.isdir(RESULTS_DIR):
        os.makedirs(RESULTS_DIR)

    # 生成并发级别: min, min*2, min*4, ..., max
    levels = []
    c = args.min_concurrency
    while c <= args.max_concurrency:
        levels.append(c)
        c *= 2
    # 确保 max_concurrency 被包含 (如果不是2的幂)
    if not levels or levels[-1] != args.max_concurrency:
        levels.append(args.max_concurrency)

    print("=" * 50)
    print("并发 Pod 沙箱扩展性评估")
    print("=" * 50)
    print("Runtime:     {}".format(args.runtime))
    print("模式:        {}".format(args.mode))
    print("每级时长:    {}s".format(args.duration))
    print("并发范围:    {} → {}".format(args.min_concurrency, args.max_concurrency))
    print("级别:        {}".format(levels))
    print("=" * 50)
    print("")

    results = []
    for level in levels:
        r = run_level(level, args.duration, args.runtime, args.mode)
        if r:
            results.append(r)
        else:
            print("  [concurrency={}] 跳过 (失败)".format(level))
        # 级别间冷却：等待 containerd 恢复，concurrent_cold_start 已自行清理
        cooldown = max(5, args.duration // 4)
        print("  冷却 {}s...".format(cooldown), end=" ", flush=True)
        time.sleep(cooldown)
        print("done")

    if not results:
        print("\n所有级别均失败")
        sys.exit(1)

    print_table(results)

    # 保存汇总报告
    report = {
        "config": {
            "runtime": args.runtime,
            "mode": args.mode,
            "duration_per_level": args.duration,
            "max_concurrency": args.max_concurrency,
            "levels": levels,
        },
        "results": results,
    }
    with open(args.output, "w") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)

    print("\n汇总报告: {}".format(args.output))
