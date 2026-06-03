#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
并发 Pod 沙箱冷启动测试（多线程，基于 crictl）
兼容 Python 3.6+。

两种模式:
  continuous - 每轮内 N 个线程持续发送 runp，不等就绪即取下一任务；
               全部 runp 完成后统一轮询 SANDBOX_READY。
  serial     - 每轮内 N 个线程各自 runp → 等就绪 → 清理 → 取下一任务。

每个沙箱独立记录 t_runp 和 t_ready。

用法:
    python3 concurrent_cold_start.py \
        --concurrency 5 --per-round 20 --rounds 3 --mode continuous

前置条件:
    ./scripts/setup.sh
"""

import time
import subprocess
import statistics
import json
import uuid
import argparse
import sys
import os
import threading
import itertools

try:
    import queue
except ImportError:
    import Queue as queue  # Python 2 fallback (实际上 Python 3 就是 queue)

# ============================================================
# 配置
# ============================================================
PAUSE_IMAGE = "registry.aliyuncs.com/google_containers/pause:3.9"
OUTPUT_FILE = "concurrent_cold_start_report.json"
POD_CONFIG_DIR = "/tmp/conc-pod-configs"


# ============================================================
# 数据模型
# ============================================================
class SandboxResult(object):
    """单个沙箱的冷启动时延"""

    def __init__(self, round_num, worker_id, task_index, sandbox_id,
                 t_runp_ms, t_ready_ms, total_ms):
        self.round_num = round_num
        self.worker_id = worker_id
        self.task_index = task_index
        self.sandbox_id = sandbox_id
        self.t_runp_ms = t_runp_ms
        self.t_ready_ms = t_ready_ms
        self.total_ms = total_ms

    def to_dict(self):
        return {
            "round": self.round_num,
            "worker": self.worker_id,
            "task": self.task_index,
            "sandbox_id": self.sandbox_id,
            "t_runp_ms": self.t_runp_ms,
            "t_ready_ms": self.t_ready_ms,
            "total_ms": self.total_ms,
        }


class Stats(object):
    def __init__(self, p50, p95, p99, mean, stddev, min_val, max_val):
        self.p50 = p50; self.p95 = p95; self.p99 = p99
        self.mean = mean; self.stddev = stddev
        self.min_val = min_val; self.max_val = max_val

    def to_dict(self):
        return {
            "p50": self.p50, "p95": self.p95, "p99": self.p99,
            "mean": self.mean, "stddev": self.stddev,
            "min": self.min_val, "max": self.max_val,
        }


# ============================================================
# 工具函数
# ============================================================
def _run(cmd):
    # type: (str) -> str
    r = subprocess.run(
        cmd, shell=True, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, timeout=60
    )
    stdout = r.stdout.decode("utf-8", errors="replace").strip()
    stderr = r.stderr.decode("utf-8", errors="replace").strip()
    if r.returncode != 0:
        raise RuntimeError("cmd failed [{}]: {}".format(cmd, stderr))
    return stdout


def _write_file(path, content):
    with open(path, "w") as f:
        f.write(content)


def compute_stats(values):
    if not values:
        return Stats(0, 0, 0, 0, 0, 0, 0)
    s = sorted(values)
    n = len(s)
    return Stats(
        p50=s[int(n * 0.50) - 1] if n >= 1 else 0,
        p95=s[int(n * 0.95) - 1] if n >= 1 else 0,
        p99=s[int(n * 0.99) - 1] if n >= 1 else 0,
        mean=statistics.mean(s),
        stddev=statistics.stdev(s) if n > 1 else 0,
        min_val=s[0],
        max_val=s[-1],
    )


def clear_caches():
    _run("echo 3 > /proc/sys/vm/drop_caches")
    time.sleep(2)


# ============================================================
# 前置条件检查
# ============================================================
def check_prerequisites():
    errors = []
    try:
        version = _run("crictl --version")
        print("[check] crictl 可用: {}".format(version))
    except Exception:
        errors.append("crictl 未找到，请执行 ./scripts/setup.sh")

    try:
        _run("crictl info")
        print("[check] CRI 运行时连接正常")
    except Exception as e:
        errors.append("CRI 运行时异常: {}".format(e))

    try:
        existing = _run("crictl images -q {}".format(PAUSE_IMAGE))
        if PAUSE_IMAGE in existing:
            print("[check] pause 镜像已缓存: {}".format(PAUSE_IMAGE))
        else:
            raise RuntimeError("未找到")
    except Exception:
        print("[check] pause 镜像缺失，正在拉取: {} ...".format(PAUSE_IMAGE))
        try:
            _run("crictl pull {}".format(PAUSE_IMAGE))
            print("[check] pause 镜像拉取完成")
        except Exception as e:
            errors.append("pause 镜像拉取失败: {}".format(e))

    if not os.path.isfile("/proc/sys/vm/drop_caches"):
        errors.append("/proc/sys/vm/drop_caches 不可用")

    if errors:
        print("\n前置条件检查失败:")
        for err in errors:
            print("  ✗ {}".format(err))
        sys.exit(1)

    print("[check] 所有前置条件满足\n")


# ============================================================
# Pod 配置生成
# ============================================================
def generate_pod_config(task_index, round_num):
    unique_uid = "conc-{}-r{}-t{}".format(uuid.uuid4().hex[:12], round_num, task_index)
    path = "{}/pod-{}.json".format(POD_CONFIG_DIR, task_index)
    content = json.dumps({
        "metadata": {
            "name": "conc-bench-r{}-t{}".format(round_num, task_index),
            "namespace": "default",
            "uid": unique_uid,
            "attempt": 1
        },
        "log_directory": "/tmp/sandbox-logs",
        "linux": {
            "security_context": {
                "namespace_options": {"network": 0}
            }
        }
    })
    _write_file(path, content)
    return path


# ============================================================
# Pod 沙箱操作
# ============================================================
def run_pod_sandbox(pod_config_path):
    return _run("crictl runp --runtime runc {}".format(pod_config_path))


def poll_until_ready(sandbox_id, timeout_sec=30.0):
    deadline = time.perf_counter() + timeout_sec
    while time.perf_counter() < deadline:
        try:
            info = _run("crictl inspectp {}".format(sandbox_id))
            status = json.loads(info)
            state = status.get("status", {}).get("state", "")
            if state == "SANDBOX_READY":
                return
        except RuntimeError:
            pass
        time.sleep(0.01)
    raise RuntimeError("sandbox {} not ready in {}s".format(sandbox_id, timeout_sec))


def stop_sandbox(sandbox_id):
    _run("crictl stopp {}".format(sandbox_id))


def remove_sandbox(sandbox_id):
    _run("crictl rmp {}".format(sandbox_id))


def cleanup_sandbox(sandbox_id):
    try:
        stop_sandbox(sandbox_id)
    except Exception:
        pass
    try:
        remove_sandbox(sandbox_id)
    except Exception:
        pass


def batch_cleanup(round_num):
    sandboxes = _run("crictl pods -q --name conc-bench-r{}".format(round_num))
    for sid in sandboxes.split("\n") if sandboxes else []:
        sid = sid.strip()
        if sid:
            cleanup_sandbox(sid)


# ============================================================
# Worker 线程
# ============================================================

# 全局结果存储（线程安全）
_results_lock = threading.Lock()
_results = []  # type: list[SandboxResult]


def add_result(result):
    with _results_lock:
        _results.append(result)


def worker_serial(worker_id, task_queue, round_num):
    """
    Mode 2: serial
    runp → poll ready → 记录 t_runp + t_ready → cleanup → 取下一个
    """
    while True:
        item = task_queue.get()
        if item is None:
            break
        task_index, pod_config_path = item

        # ---- runp ---- #
        t0 = time.perf_counter()
        try:
            sandbox_id = run_pod_sandbox(pod_config_path)
        except Exception as e:
            add_result(SandboxResult(
                round_num=round_num, worker_id=worker_id,
                task_index=task_index, sandbox_id="FAIL",
                t_runp_ms=0, t_ready_ms=0, total_ms=0))
            continue
        t1 = time.perf_counter()
        t_runp_ms = round((t1 - t0) * 1000, 3)

        # ---- poll ready ---- #
        try:
            poll_until_ready(sandbox_id)
        except Exception:
            t_ready_ms = -1
        else:
            t2 = time.perf_counter()
            t_ready_ms = round((t2 - t1) * 1000, 3)

        # ---- record ---- #
        add_result(SandboxResult(
            round_num=round_num, worker_id=worker_id,
            task_index=task_index, sandbox_id=sandbox_id[:12],
            t_runp_ms=t_runp_ms, t_ready_ms=t_ready_ms,
            total_ms=round(t_runp_ms + max(t_ready_ms, 0), 3)))

        # ---- cleanup ---- #
        cleanup_sandbox(sandbox_id)


# ============================================================
# worker for continuous mode — 只做 runp，产出 push 到共享队列
# ============================================================
def worker_continuous_runp(worker_id, task_queue, ready_queue):
    """
    continuous mode: 不停取 task → runp → push sandbox 到 ready_queue。
    """
    while True:
        item = task_queue.get()
        if item is None:
            break
        task_index, pod_config_path = item

        t0 = time.perf_counter()
        try:
            sandbox_id = run_pod_sandbox(pod_config_path)
        except Exception:
            sandbox_id = None
        t1 = time.perf_counter()
        t_runp_ms = round((t1 - t0) * 1000, 3)

        ready_queue.put({
            "worker": worker_id,
            "task_index": task_index,
            "sandbox_id": sandbox_id,
            "t_runp_ms": t_runp_ms,
            "t_after_runp": t1,   # perf_counter，用于计算 t_ready
        })

    # 通知 poll worker 该 worker 已完成
    ready_queue.put(None)


# ============================================================
# worker for continuous mode — 从 ready_queue 取，poll 就绪
# ============================================================
def worker_continuous_poll(worker_id, round_num, ready_queue, runp_finished_counter, n_runp_workers):
    """
    continuous mode: 不停从 ready_queue 取已完成的 sandbox → poll 就绪 → 记录 → 清理。
    runp worker 产出后立刻被 pick up，t_ready 精确。
    """
    while True:
        item = ready_queue.get()
        if item is None:
            # 一个 runp worker 完成
            runp_finished_counter[0] += 1
            if runp_finished_counter[0] >= n_runp_workers:
                # 所有 runp worker 都完成了，通知其他 poll worker 退出
                ready_queue.put(None)
                break
            continue

        sid = item["sandbox_id"]
        if sid is not None:
            try:
                poll_until_ready(sid)
                t_ready_ms = round(
                    (time.perf_counter() - item["t_after_runp"]) * 1000, 3)
            except Exception:
                t_ready_ms = -1
        else:
            t_ready_ms = -1

        total_ms = round(item["t_runp_ms"] + max(t_ready_ms, 0), 3)

        add_result(SandboxResult(
            round_num=round_num,
            worker_id=item["worker"],
            task_index=item["task_index"],
            sandbox_id=(sid[:12] if sid else "FAIL"),
            t_runp_ms=item["t_runp_ms"],
            t_ready_ms=t_ready_ms if t_ready_ms >= 0 else 0,
            total_ms=total_ms,
        ))

        # 清理
        if sid:
            cleanup_sandbox(sid)


# ============================================================
# 轮次执行 — continuous 模式
# ============================================================
def run_round_continuous(round_num, concurrency, per_round):
    """
    Mode 1: continuous
    N runp workers + N poll workers 同时启动。
    runp worker: task → runp → push 到 ready_queue（不等就绪）
    poll worker: 从 ready_queue pull → poll ready → 记录 → 清理
    """
    print("[第 {}/{} 轮] 清缓存...".format(round_num, args.rounds))
    clear_caches()

    # ---- 准备 task 队列 ---- #
    task_queue = queue.Queue()
    for i in range(per_round):
        pod_config_path = generate_pod_config(i, round_num)
        task_queue.put((i, pod_config_path))
    for _ in range(concurrency):
        task_queue.put(None)

    # ---- 共享 ready 队列 ---- #
    ready_queue = queue.Queue()

    # ---- 启动 runp + poll workers 同时运行 ---- #
    print("[第 {}/{} 轮] continuous: {} runp + {} poll workers, 共 {} 沙箱...".format(
        round_num, args.rounds, concurrency, concurrency, per_round))

    t_start = time.perf_counter()

    runp_finished_counter = [0]  # 用 list 包装实现跨线程修改

    # 启动 runp workers
    runp_threads = []
    for w in range(concurrency):
        t = threading.Thread(
            target=worker_continuous_runp,
            args=(w, task_queue, ready_queue)
        )
        t.start()
        runp_threads.append(t)

    # 启动 poll workers（与 runp 同时运行）
    poll_threads = []
    for w in range(concurrency):
        t = threading.Thread(
            target=worker_continuous_poll,
            args=(w, round_num, ready_queue, runp_finished_counter, concurrency)
        )
        t.start()
        poll_threads.append(t)

    # 等待全部完成
    for t in runp_threads:
        t.join()
    for t in poll_threads:
        t.join()

    t_end = time.perf_counter()
    wall_ms = round((t_end - t_start) * 1000, 1)

    print("  完成: 挂钟 {}ms".format(wall_ms))

    # 清理残留
    batch_cleanup(round_num)

    return wall_ms


def run_round_serial(round_num, concurrency, per_round):
    """
    Mode 2: serial
    每个 worker 线程: runp → poll ready → cleanup → 取下一个
    """
    print("[第 {}/{} 轮] 清缓存...".format(round_num, args.rounds))
    clear_caches()

    task_queue = queue.Queue()
    for i in range(per_round):
        pod_config_path = generate_pod_config(i, round_num)
        task_queue.put((i, pod_config_path))
    for _ in range(concurrency):
        task_queue.put(None)

    print("[第 {}/{} 轮] {} 线程串行模式 (runp→ready→cleanup), 共 {} 沙箱...".format(
        round_num, args.rounds, concurrency, per_round))

    t_start = time.perf_counter()

    threads = []
    for w in range(concurrency):
        t = threading.Thread(
            target=worker_serial,
            args=(w, task_queue, round_num)
        )
        t.start()
        threads.append(t)

    for t in threads:
        t.join()

    t_end = time.perf_counter()
    wall_ms = round((t_end - t_start) * 1000, 1)
    print("  完成: 挂钟 {}ms".format(wall_ms))

    # 清理残留
    batch_cleanup(round_num)

    return wall_ms


# ============================================================
# 汇总报告
# ============================================================
def print_summary(all_wall_times):
    global _results

    runps = [r.t_runp_ms for r in _results]
    readys = [r.t_ready_ms for r in _results if r.t_ready_ms >= 0]
    totals = [r.total_ms for r in _results]

    r_stats = compute_stats(runps)
    d_stats = compute_stats(readys)
    t_stats = compute_stats(totals)

    print("")
    print("=" * 70)
    print("并发 Pod 沙箱冷启动测试 — 结果汇总")
    print("=" * 70)
    print("模式:     {}".format(args.mode))
    print("并发数:   {} threads".format(args.concurrency))
    print("每轮数:   {} sandboxes".format(args.per_round))
    print("总轮次:   {}".format(args.rounds))
    print("总沙箱:   {}".format(args.rounds * args.per_round))
    print("成功:     {}/{}".format(len(totals), args.rounds * args.per_round))
    print("=" * 70)

    print("")
    print("各轮挂钟总耗时:")
    for r, wall in enumerate(all_wall_times, 1):
        print("  第 {} 轮: {}ms".format(r, wall))

    print("")
    print("{:<18} {:>8} {:>8} {:>8} {:>8} {:>8}".format(
        "", "P50(ms)", "P95(ms)", "P99(ms)", "Mean(ms)", "Min/Max"))
    print("-" * 65)
    print("{:<18} {:>8.1f} {:>8.1f} {:>8.1f} {:>8.1f} {:>8.1f}/{}".format(
        "t_runp", r_stats.p50, r_stats.p95, r_stats.p99,
        r_stats.mean, r_stats.min_val, r_stats.max_val))
    print("{:<18} {:>8.1f} {:>8.1f} {:>8.1f} {:>8.1f} {:>8.1f}/{}".format(
        "t_ready", d_stats.p50, d_stats.p95, d_stats.p99,
        d_stats.mean, d_stats.min_val, d_stats.max_val))
    print("-" * 65)
    print("{:<18} {:>8.1f} {:>8.1f} {:>8.1f} {:>8.1f} {:>8.1f}/{}".format(
        "total", t_stats.p50, t_stats.p95, t_stats.p99,
        t_stats.mean, t_stats.min_val, t_stats.max_val))

    # 按轮次统计
    print("")
    print("各轮次耗时分布:")
    for rnd in range(1, args.rounds + 1):
        round_results = [res for res in _results if res.round_num == rnd]
        if round_results:
            round_totals = [res.total_ms for res in round_results]
            s = compute_stats(round_totals)
            print("  r{}: 样本={}  P50={:.0f}ms  P95={:.0f}ms  Min/Max={:.0f}/{:.0f}ms".format(
                rnd, len(round_totals), s.p50, s.p95, s.min_val, s.max_val))

    print("")
    print("详细报告: {}".format(args.output))


# ============================================================
# CLI
# ============================================================
if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="并发 Pod 沙箱冷启动测试 (crictl, 多线程)"
    )
    parser.add_argument("--concurrency", type=int, default=5,
                        help="并发线程数 N (默认 5)")
    parser.add_argument("--per-round", type=int, default=20,
                        help="每轮沙箱总数 M (默认 20)")
    parser.add_argument("--rounds", type=int, default=3,
                        help="总轮次 K (默认 3)")
    parser.add_argument("--mode", choices=["continuous", "serial"],
                        default="continuous",
                        help="模式: continuous(不等就绪) / serial(等就绪) (默认 continuous)")
    parser.add_argument("--output", default=OUTPUT_FILE,
                        help="JSON 报告输出路径")
    parser.add_argument("--skip-check", action="store_true",
                        help="跳过前置条件检查")
    args = parser.parse_args()

    # 前置检查
    if not args.skip_check:
        check_prerequisites()

    # 准备目录
    if not os.path.isdir(POD_CONFIG_DIR):
        os.makedirs(POD_CONFIG_DIR)

    total_sandboxes = args.rounds * args.per_round
    print("")
    print("=" * 50)
    print("并发 Pod 沙箱冷启动测试")
    print("=" * 50)
    print("模式:     {}".format(args.mode))
    print("并发数:   {} threads".format(args.concurrency))
    print("每轮数:   {} sandboxes".format(args.per_round))
    print("总轮次:   {}".format(args.rounds))
    print("总沙箱:   {}".format(total_sandboxes))
    print("=" * 50)
    print("")

    # 重置全局结果
    _results = []

    all_wall_times = []

    fn = run_round_continuous if args.mode == "continuous" else run_round_serial

    for round_num in range(1, args.rounds + 1):
        wall = fn(round_num, args.concurrency, args.per_round)
        all_wall_times.append(wall)

    # 输出报告
    print_summary(all_wall_times)

    # 写入 JSON
    report = {
        "config": {
            "concurrency": args.concurrency,
            "per_round": args.per_round,
            "rounds": args.rounds,
            "mode": args.mode,
            "pause_image": PAUSE_IMAGE,
            "runtime": "runc (via crictl)",
        },
        "summary": {
            "total_sandboxes": args.rounds * args.per_round,
            "success": sum(1 for r in _results if r.sandbox_id != "FAIL"),
            "failed": sum(1 for r in _results if r.sandbox_id == "FAIL"),
        },
        "wall_times_per_round": all_wall_times,
        "phases": {
            "t_runp": compute_stats(
                [r.t_runp_ms for r in _results]).to_dict(),
            "t_ready": compute_stats(
                [r.t_ready_ms for r in _results if r.t_ready_ms >= 0]).to_dict(),
            "total": compute_stats(
                [r.total_ms for r in _results]).to_dict(),
        },
        "results": [r.to_dict() for r in _results],
    }
    with open(args.output, "w") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)

    print("报告已保存: {}".format(args.output))
