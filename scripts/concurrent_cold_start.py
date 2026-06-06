#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
并发 Pod 沙箱冷启动测试（多线程，基于 crictl）
兼容 Python 3.6+。

模式:
  continuous - runp 不等就绪即取下一任务，poll worker 异步就绪等待
  serial     - 每个线程 runp → 等就绪 → 清理 → 取下一任务

两种测试方式:
  --per-round M  - 每轮创建固定 M 个沙箱（通过 task_queue 分发）
  --duration S   - 每轮持续 S 秒，线程自驱循环，统计时间内完成数

用法:
    # 固定数量
    python3 concurrent_cold_start.py \
        --concurrency 5 --per-round 20 --rounds 3 --mode continuous

    # 固定时间
    python3 concurrent_cold_start.py \
        --concurrency 5 --duration 30 --rounds 3 --mode continuous

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

try:
    import queue
except ImportError:
    import Queue as queue


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
    try:
        _run("echo 3 > /proc/sys/vm/drop_caches")
        time.sleep(2)
    except Exception:
        pass


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
        existing = _run("crictl images {}".format(PAUSE_IMAGE))
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
def generate_pod_config(round_num, worker_id, local_seq):
    task_label = "w{}-{}".format(worker_id, local_seq)
    unique_uid = "conc-{}-r{}".format(uuid.uuid4().hex[:12], round_num)
    path = "{}/pod-w{}-{}.json".format(POD_CONFIG_DIR, worker_id, local_seq)
    content = json.dumps({
        "metadata": {
            "name": "conc-bench-r{}-w{}-{}".format(round_num, worker_id, local_seq),
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
def run_pod_sandbox(pod_config_path, runtime="runc"):
    return _run("crictl runp --runtime {} {}".format(runtime, pod_config_path))


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


def cleanup_sandbox(sandbox_id):
    try:
        _run("crictl stopp {}".format(sandbox_id))
    except Exception:
        pass
    try:
        _run("crictl rmp {}".format(sandbox_id))
    except Exception:
        pass


def batch_cleanup(round_num):
    sandboxes = _run("crictl pods -q --name conc-bench-r{}".format(round_num))
    for sid in sandboxes.split("\n") if sandboxes else []:
        sid = sid.strip()
        if sid:
            cleanup_sandbox(sid)


# ============================================================
# 全局结果存储（线程安全）
# ============================================================
_results_lock = threading.Lock()
_results = []


def add_result(result):
    with _results_lock:
        _results.append(result)


# ============================================================
# = 固定数量模式 workers（通过 task_queue 分发任务）         =
# ============================================================

def worker_counted_serial(worker_id, task_queue, round_num):
    """serial + 固定数量"""
    while True:
        item = task_queue.get()
        if item is None:
            break
        task_index, pod_config_path = item

        t0 = time.perf_counter()
        try:
            sandbox_id = run_pod_sandbox(pod_config_path, args.runtime)
        except Exception:
            add_result(SandboxResult(round_num, worker_id, task_index,
                                     "FAIL", 0, 0, 0))
            continue
        t1 = time.perf_counter()
        t_runp_ms = round((t1 - t0) * 1000, 3)

        try:
            poll_until_ready(sandbox_id)
            t_ready_ms = round((time.perf_counter() - t1) * 1000, 3)
        except Exception:
            t_ready_ms = -1

        add_result(SandboxResult(round_num, worker_id, task_index,
                                 sandbox_id[:12], t_runp_ms,
                                 t_ready_ms if t_ready_ms >= 0 else 0,
                                 round(t_runp_ms + max(t_ready_ms, 0), 3)))
        if G.cleanup:
            cleanup_sandbox(sandbox_id)


def worker_counted_continuous_runp(worker_id, task_queue, ready_queue):
    """continuous 固定数量: runp → push ready_queue"""
    while True:
        item = task_queue.get()
        if item is None:
            break
        task_index, pod_config_path = item

        t0 = time.perf_counter()
        try:
            sandbox_id = run_pod_sandbox(pod_config_path, args.runtime)
        except Exception:
            sandbox_id = None
        t1 = time.perf_counter()
        t_runp_ms = round((t1 - t0) * 1000, 3)

        ready_queue.put({
            "worker": worker_id,
            "task_index": task_index,
            "sandbox_id": sandbox_id,
            "t_runp_ms": t_runp_ms,
            "t_after_runp": t1,
        })
    ready_queue.put(None)


def worker_counted_continuous_poll(worker_id, round_num, ready_queue,
                                    runp_done_counter, n_runp_workers):
    """continuous 固定数量: 从 ready_queue 取 → poll → 记录 → 清理"""
    while True:
        item = ready_queue.get()
        if item is None:
            runp_done_counter[0] += 1
            if runp_done_counter[0] >= n_runp_workers:
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

        add_result(SandboxResult(
            round_num, item["worker"], item["task_index"],
            (sid[:12] if sid else "FAIL"),
            item["t_runp_ms"],
            t_ready_ms if t_ready_ms >= 0 else 0,
            round(item["t_runp_ms"] + max(t_ready_ms, 0), 3)))
        if sid and G.cleanup:
            cleanup_sandbox(sid)


# ============================================================
# = 固定时间模式 workers（线程自驱循环 + stop_event + 本地计数器）=
# ============================================================

def worker_timed_serial(worker_id, round_num, stop_event):
    """
    serial + 固定时间:
    线程本地序号 seq，循环: runp → poll → record → cleanup → seq++
    """
    seq = 0
    while not stop_event.is_set():
        pod_config_path = generate_pod_config(round_num, worker_id, seq)

        t0 = time.perf_counter()
        try:
            sandbox_id = run_pod_sandbox(pod_config_path, args.runtime)
        except Exception:
            add_result(SandboxResult(round_num, worker_id, seq,
                                     "FAIL", 0, 0, 0))
            seq += 1
            continue
        t1 = time.perf_counter()
        t_runp_ms = round((t1 - t0) * 1000, 3)

        # 检查 stop_event：如果 runp 期间时间到了，就绪等待后不再循环
        try:
            poll_until_ready(sandbox_id)
            t_ready_ms = round((time.perf_counter() - t1) * 1000, 3)
        except Exception:
            t_ready_ms = -1

        add_result(SandboxResult(
            round_num, worker_id, seq,
            sandbox_id[:12], t_runp_ms,
            t_ready_ms if t_ready_ms >= 0 else 0,
            round(t_runp_ms + max(t_ready_ms, 0), 3)))
        if G.cleanup:
            cleanup_sandbox(sandbox_id)
        seq += 1


def worker_timed_continuous_runp(worker_id, round_num, stop_event, ready_queue):
    """
    continuous + 固定时间: 线程自驱循环，runp → push ready_queue → seq++
    """
    seq = 0
    while not stop_event.is_set():
        pod_config_path = generate_pod_config(round_num, worker_id, seq)

        t0 = time.perf_counter()
        try:
            sandbox_id = run_pod_sandbox(pod_config_path, args.runtime)
        except Exception:
            sandbox_id = None
        t1 = time.perf_counter()
        t_runp_ms = round((t1 - t0) * 1000, 3)

        ready_queue.put({
            "worker": worker_id,
            "task_index": seq,
            "sandbox_id": sandbox_id,
            "t_runp_ms": t_runp_ms,
            "t_after_runp": t1,
        })
        seq += 1

    # 通知 poll worker
    ready_queue.put(None)


def worker_timed_continuous_poll(worker_id, round_num, stop_event, ready_queue,
                                  runp_done_counter, n_runp_workers):
    """
    continuous + 固定时间: 从 ready_queue 取 → poll → 记录 → 清理。
    当所有 runp worker 发来 None 时退出。
    """
    while True:
        # 使用 timeout 以便能检查 stop_event（但实际由 runp 线程的 None 控制）
        try:
            item = ready_queue.get(timeout=0.5)
        except queue.Empty:
            continue

        if item is None:
            runp_done_counter[0] += 1
            if runp_done_counter[0] >= n_runp_workers:
                # 通知其他 poll worker
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

        add_result(SandboxResult(
            round_num, item["worker"], item["task_index"],
            (sid[:12] if sid else "FAIL"),
            item["t_runp_ms"],
            t_ready_ms if t_ready_ms >= 0 else 0,
            round(item["t_runp_ms"] + max(t_ready_ms, 0), 3)))
        if sid and G.cleanup:
            cleanup_sandbox(sid)


# ============================================================
# = 轮次执行函数                                             =
# ============================================================

def run_round_counted_continuous(round_num, concurrency, per_round):
    """固定数量 + continuous"""
    print("[第 {}/{} 轮] 清缓存...".format(round_num, args.rounds))
    clear_caches()

    task_queue = queue.Queue()
    for i in range(per_round):
        pod_config_path = generate_pod_config(round_num, -1, i)
        task_queue.put((i, pod_config_path))
    for _ in range(concurrency):
        task_queue.put(None)

    ready_queue = queue.Queue()

    print("[第 {}/{} 轮] continuous(固定数量): {} runp + {} poll workers, {} sandboxes".format(
        round_num, args.rounds, concurrency, concurrency, per_round))

    t_start = time.perf_counter()
    runp_done = [0]

    runp_threads = []
    for w in range(concurrency):
        t = threading.Thread(target=worker_counted_continuous_runp,
                             args=(w, task_queue, ready_queue))
        t.start(); runp_threads.append(t)

    poll_threads = []
    for w in range(concurrency):
        t = threading.Thread(target=worker_counted_continuous_poll,
                             args=(w, round_num, ready_queue, runp_done, concurrency))
        t.start(); poll_threads.append(t)

    for t in runp_threads: t.join()
    for t in poll_threads: t.join()

    wall_ms = round((time.perf_counter() - t_start) * 1000, 1)
    print("  完成: 挂钟 {}ms".format(wall_ms))
    batch_cleanup(round_num)
    return wall_ms


def run_round_counted_serial(round_num, concurrency, per_round):
    """固定数量 + serial"""
    print("[第 {}/{} 轮] 清缓存...".format(round_num, args.rounds))
    clear_caches()

    task_queue = queue.Queue()
    for i in range(per_round):
        pod_config_path = generate_pod_config(round_num, -1, i)
        task_queue.put((i, pod_config_path))
    for _ in range(concurrency):
        task_queue.put(None)

    print("[第 {}/{} 轮] serial(固定数量): {} workers, {} sandboxes".format(
        round_num, args.rounds, concurrency, per_round))

    t_start = time.perf_counter()
    threads = []
    for w in range(concurrency):
        t = threading.Thread(target=worker_counted_serial,
                             args=(w, task_queue, round_num))
        t.start(); threads.append(t)
    for t in threads: t.join()

    wall_ms = round((time.perf_counter() - t_start) * 1000, 1)
    print("  完成: 挂钟 {}ms".format(wall_ms))
    batch_cleanup(round_num)
    return wall_ms


def run_round_timed_continuous(round_num, concurrency, duration):
    """固定时间 + continuous"""
    print("[第 {}/{} 轮] 清缓存...".format(round_num, args.rounds))
    clear_caches()

    stop_event = threading.Event()
    ready_queue = queue.Queue()

    print("[第 {}/{} 轮] continuous(固定时间): {} runp + {} poll workers, {}s".format(
        round_num, args.rounds, concurrency, concurrency, duration))

    t_start = time.perf_counter()
    runp_done = [0]

    runp_threads = []
    for w in range(concurrency):
        t = threading.Thread(target=worker_timed_continuous_runp,
                             args=(w, round_num, stop_event, ready_queue))
        t.start(); runp_threads.append(t)

    poll_threads = []
    for w in range(concurrency):
        t = threading.Thread(target=worker_timed_continuous_poll,
                             args=(w, round_num, stop_event, ready_queue,
                                   runp_done, concurrency))
        t.start(); poll_threads.append(t)

    time.sleep(duration)
    stop_event.set()

    for t in runp_threads: t.join()
    for t in poll_threads: t.join()

    elapsed_ms = round((time.perf_counter() - t_start) * 1000, 1)
    round_results = [r for r in _results if r.round_num == round_num]
    count = len(round_results)
    tps = count / (elapsed_ms / 1000.0) if elapsed_ms > 0 else 0

    print("  完成: {}ms, {} sandboxes, {:.1f} sandbox/s".format(
        elapsed_ms, count, tps))
    batch_cleanup(round_num)
    return elapsed_ms


def run_round_timed_serial(round_num, concurrency, duration):
    """固定时间 + serial"""
    print("[第 {}/{} 轮] 清缓存...".format(round_num, args.rounds))
    clear_caches()

    stop_event = threading.Event()

    print("[第 {}/{} 轮] serial(固定时间): {} workers, {}s".format(
        round_num, args.rounds, concurrency, duration))

    t_start = time.perf_counter()

    threads = []
    for w in range(concurrency):
        t = threading.Thread(target=worker_timed_serial,
                             args=(w, round_num, stop_event))
        t.start(); threads.append(t)

    time.sleep(duration)
    stop_event.set()

    for t in threads: t.join()

    elapsed_ms = round((time.perf_counter() - t_start) * 1000, 1)
    round_results = [r for r in _results if r.round_num == round_num]
    count = len(round_results)
    tps = count / (elapsed_ms / 1000.0) if elapsed_ms > 0 else 0

    print("  完成: {}ms, {} sandboxes, {:.1f} sandbox/s".format(
        elapsed_ms, count, tps))
    batch_cleanup(round_num)
    return elapsed_ms


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

    is_timed = G.use_timed

    print("")
    print("=" * 70)
    print("并发 Pod 沙箱冷启动测试 — 结果汇总")
    print("=" * 70)
    print("模式:     {}".format(args.mode))
    print("并发数:   {} threads".format(args.concurrency))
    if is_timed:
        print("每轮时长: {}s".format(args.duration))
        print("总计沙箱: {}".format(sum(1 for _ in _results)))
    else:
        print("每轮数:   {} sandboxes".format(args.per_round))
        print("总计沙箱: {}".format(args.rounds * args.per_round))
    print("总轮次:   {}".format(args.rounds))
    print("成功:     {}/{}".format(
        sum(1 for r in _results if r.sandbox_id != "FAIL"),
        len(_results)))
    print("=" * 70)

    print("")
    if is_timed:
        print("各轮统计:")
        for rnd in range(1, args.rounds + 1):
            wall = all_wall_times[rnd - 1]
            count = sum(1 for r in _results if r.round_num == rnd)
            tps = count / (wall / 1000.0) if wall > 0 else 0
            print("  第 {} 轮: {}ms, {} sandboxes, {:.1f} sandbox/s".format(
                rnd, wall, count, tps))
    else:
        print("各轮挂钟总耗时:")
        for rnd, wall in enumerate(all_wall_times, 1):
            print("  第 {} 轮: {}ms".format(rnd, wall))

    print("")
    print("{:<18} {:>8} {:>8} {:>8} {:>8} {:>8}".format(
        "", "P50(ms)", "P95(ms)", "P99(ms)", "Mean(ms)", "Min/Max"))
    print("-" * 65)
    print("{:<18} {:>8.1f} {:>8.1f} {:>8.1f} {:>8.1f} {:>8.1f}/{:.1f}".format(
        "t_runp", r_stats.p50, r_stats.p95, r_stats.p99,
        r_stats.mean, r_stats.min_val, r_stats.max_val))
    print("{:<18} {:>8.1f} {:>8.1f} {:>8.1f} {:>8.1f} {:>8.1f}/{:.1f}".format(
        "t_ready", d_stats.p50, d_stats.p95, d_stats.p99,
        d_stats.mean, d_stats.min_val, d_stats.max_val))
    print("-" * 65)
    print("{:<18} {:>8.1f} {:>8.1f} {:>8.1f} {:>8.1f} {:>8.1f}/{:.1f}".format(
        "total", t_stats.p50, t_stats.p95, t_stats.p99,
        t_stats.mean, t_stats.min_val, t_stats.max_val))

    print("")
    print("各轮次耗时分布:")
    for rnd in range(1, args.rounds + 1):
        round_res = [r for r in _results if r.round_num == rnd]
        if round_res:
            round_totals = [r.total_ms for r in round_res]
            s = compute_stats(round_totals)
            print("  r{}: 样本={}  P50={:.0f}ms  P95={:.0f}ms  Min/Max={:.0f}/{:.0f}ms".format(
                rnd, len(round_totals), s.p50, s.p95, s.min_val, s.max_val))

    print("")
    print("详细报告: {}".format(args.output))


# ============================================================
# 全局状态（避免到处传参数）
# ============================================================
class _Globals(object):
    pass
G = _Globals()


# ============================================================
# CLI
# ============================================================
if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="并发 Pod 沙箱冷启动测试 (crictl, 多线程)"
    )
    parser.add_argument("--concurrency", type=int, default=5,
                        help="并发线程数 N (默认 5)")
    parser.add_argument("--rounds", type=int, default=3,
                        help="总轮次 K (默认 3)")
    parser.add_argument("--runtime", choices=["runc", "kata"], default="runc",
                        help="OCI 运行时 (默认 runc)")
    parser.add_argument("--mode", choices=["continuous", "serial"],
                        default="continuous",
                        help="continuous(不等就绪) / serial(等就绪)")

    # --per-round / --duration 二选一
    count_group = parser.add_mutually_exclusive_group(required=True)
    count_group.add_argument("--per-round", type=int,
                              help="每轮固定沙箱数 M")
    count_group.add_argument("--duration", type=int,
                              help="每轮持续时间（秒），统计时间内完成数")

    parser.add_argument("--output", default=OUTPUT_FILE,
                        help="JSON 报告输出路径")
    parser.add_argument("--cleanup", action="store_true",
                        help="每个 sandbox 就绪后立即清理（默认不清理）")
    parser.add_argument("--skip-check", action="store_true",
                        help="跳过前置条件检查")
    args = parser.parse_args()

    G.cleanup = args.cleanup
    G.use_timed = args.duration is not None
    per_round_val = args.duration if G.use_timed else args.per_round

    # 前置检查
    if not args.skip_check:
        check_prerequisites()

    if not os.path.isdir(POD_CONFIG_DIR):
        os.makedirs(POD_CONFIG_DIR)

    print("")
    print("=" * 50)
    print("并发 Pod 沙箱冷启动测试")
    print("=" * 50)
    print("模式:     {}".format(args.mode))
    print("并发数:   {} threads".format(args.concurrency))
    print("清理:     {}".format("是 (每就绪一个清理一个)" if G.cleanup else "否 (仅轮末/结束统一清理)"))
    if G.use_timed:
        print("每轮时长: {}s (固定时间)".format(args.duration))
    else:
        print("每轮数:   {} sandboxes (固定数量)".format(args.per_round))
    print("总轮次:   {}".format(args.rounds))
    print("=" * 50)
    print("")

    # 重置
    _results = []

    # 选择执行函数
    if G.use_timed:
        round_fn = (run_round_timed_continuous if args.mode == "continuous"
                    else run_round_timed_serial)
    else:
        round_fn = (run_round_counted_continuous if args.mode == "continuous"
                    else run_round_counted_serial)

    all_wall_times = []
    for rnd in range(1, args.rounds + 1):
        wall = round_fn(rnd, args.concurrency, per_round_val)
        all_wall_times.append(wall)

    print_summary(all_wall_times)

    # JSON 报告
    report = {
        "config": {
            "concurrency": args.concurrency,
            "rounds": args.rounds,
            "mode": args.mode,
            "timed": G.use_timed,
            "per_round": args.per_round,
            "duration": args.duration,
            "pause_image": PAUSE_IMAGE,
            "runtime": "runc (via crictl)",
        },
        "summary": {
            "total_sandboxes": len(_results),
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
    # 测试结束后统一清理所有残留 pod
    print("")
    print("[final cleanup] 清理所有测试 pod...")
    for rnd in range(1, args.rounds + 1):
        batch_cleanup(rnd)
    print("[final cleanup] 完成")

    with open(args.output, "w") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)

    print("报告已保存: {}".format(args.output))
