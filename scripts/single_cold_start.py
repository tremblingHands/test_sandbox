#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
单 Worker Pod 沙箱冷启动测试（串行，基于 crictl）
兼容 Python 3.6+。

用法:
    python3 single_cold_start.py --duration 30

    python3 single_cold_start.py --duration 60 --cleanup --cpuset-cpus 0-3

前置条件:
    ./scripts/setup.sh
"""

import time
import subprocess
import statistics
import json
import uuid
import argparse
import os


# ============================================================
# 配置
# ============================================================
PAUSE_IMAGE = "registry.aliyuncs.com/google_containers/pause:3.9"
OUTPUT_FILE = "results/single_cold_start_report.json"
POD_CONFIG_DIR = "/tmp/conc-pod-configs"
CPUSET_K8S_IO = "/sys/fs/cgroup/cpuset/k8s.io"


# ============================================================
# 数据模型
# ============================================================
class SandboxResult(object):
    def __init__(self, task_index, sandbox_id,
                 t_runp_ms, t_ready_ms, total_ms):
        self.task_index = task_index
        self.sandbox_id = sandbox_id
        self.t_runp_ms = t_runp_ms
        self.t_ready_ms = t_ready_ms
        self.total_ms = total_ms

    def to_dict(self):
        return {
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
        stderr=subprocess.PIPE
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


CPUSET_POOL_DIR = CPUSET_K8S_IO + "/conc-bench"


def setup_cpuset_limits(cpuset_cpus, cpuset_mems):
    """在 k8s.io 下创建 conc-bench 子 cgroup 并设置 cpuset 限制。"""
    if not cpuset_cpus and not cpuset_mems:
        return
    if not os.path.isdir(CPUSET_POOL_DIR):
        try:
            os.mkdir(CPUSET_POOL_DIR)
        except OSError:
            pass
    if not os.path.isdir(CPUSET_POOL_DIR):
        print("  [cpuset] 跳过: 无法创建 {}".format(CPUSET_POOL_DIR))
        return
    if cpuset_cpus:
        _write_file(os.path.join(CPUSET_POOL_DIR, "cpuset.cpus"),
                     cpuset_cpus + "\n")
        print("  [cpuset] {}/cpuset.cpus = {}".format(CPUSET_POOL_DIR, cpuset_cpus))
    if cpuset_mems:
        _write_file(os.path.join(CPUSET_POOL_DIR, "cpuset.mems"),
                     cpuset_mems + "\n")
        print("  [cpuset] {}/cpuset.mems = {}".format(CPUSET_POOL_DIR, cpuset_mems))


def restore_cpuset_limits(cpuset_cpus, cpuset_mems):
    """清理 conc-bench cgroup 目录。"""
    if not cpuset_cpus and not cpuset_mems:
        return
    for base in (CPUSET_K8S_IO, "/sys/fs/cgroup/cpu,cpuacct/k8s.io",
                 "/sys/fs/cgroup/memory/k8s.io",
                 "/sys/fs/cgroup/systemd/k8s.io"):
        pool_dir = os.path.join(base, "conc-bench")
        if os.path.isdir(pool_dir):
            try:
                os.rmdir(pool_dir)
            except OSError:
                pass
    print("  [cpuset] conc-bench 已清理")


# ============================================================
# Pod 配置生成
# ============================================================
def generate_pod_config(worker_id, seq):
    unique_uid = "single-{}".format(uuid.uuid4().hex[:12])
    path = "{}/pod-w{}-{}.json".format(POD_CONFIG_DIR, worker_id, seq)
    linux_config = {
        "security_context": {
            "namespace_options": {"network": 0}
        }
    }
    if G.cpuset_cpus or G.cpuset_mems:
        linux_config["cgroup_parent"] = "/k8s.io/conc-bench"
    content = json.dumps({
        "metadata": {
            "name": "single-bench-w{}-{}".format(worker_id, seq),
            "namespace": "default",
            "uid": unique_uid,
            "attempt": 1
        },
        "log_directory": "/tmp/sandbox-logs",
        "linux": linux_config,
    })
    _write_file(path, content)
    return path


_preconfig_count = 0
_on_demand_triggered = False


def preconfig_configs(count, worker_id=0):
    """预生成 pod config 文件。"""
    global _preconfig_count
    _preconfig_count = count
    for i in range(count):
        generate_pod_config(worker_id, i)
    print("  preconfig: {} configs 已预生成 (worker={})".format(count, worker_id))


def get_config(worker_id, seq):
    """获取 pod config 路径：seq 在预生成范围内的直接返回路径，否则按需生成。"""
    global _on_demand_triggered
    if seq < _preconfig_count:
        return "{}/pod-w{}-{}.json".format(POD_CONFIG_DIR, worker_id, seq)
    _on_demand_triggered = True
    return generate_pod_config(worker_id, seq)


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


def batch_cleanup():
    sandboxes = _run("crictl pods -q --name single-bench")
    for sid in sandboxes.split("\n") if sandboxes else []:
        sid = sid.strip()
        if sid:
            cleanup_sandbox(sid)


# ============================================================
# 汇总报告
# ============================================================
def print_summary(results, duration):
    global _on_demand_triggered

    stats_ok = [r for r in results if r.sandbox_id != "FAIL"]
    if not stats_ok:
        stats_ok = results

    runps = [r.t_runp_ms for r in stats_ok]
    readys = [r.t_ready_ms for r in stats_ok if r.t_ready_ms >= 0]
    totals = [r.total_ms for r in stats_ok]

    r_stats = compute_stats(runps)
    d_stats = compute_stats(readys)
    t_stats = compute_stats(totals)

    success = sum(1 for r in results if r.sandbox_id != "FAIL")
    tps = len(results) / duration if duration > 0 else 0

    print("")
    print("=" * 70)
    print("单 Worker Pod 沙箱冷启动测试 — 结果汇总")
    print("=" * 70)
    print("时长:     {}s".format(duration))
    print("总计沙箱: {}".format(len(results)))
    print("成功:     {}/{}".format(success, len(results)))
    print("吞吐:     {:.1f} sandboxes/s".format(tps))
    if _on_demand_triggered:
        print("Config:   预生成不足，触发了按需生成")
    print("=" * 70)

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
    print("详细报告: {}".format(args.output))


# ============================================================
# 全局状态
# ============================================================
class _Globals(object):
    pass
G = _Globals()
G.cpuset_cpus = None
G.cpuset_mems = None
G.cleanup = False


# ============================================================
# CLI
# ============================================================
if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="单 Worker Pod 沙箱冷启动测试 (crictl, 串行)"
    )
    parser.add_argument("--duration", type=int, required=True,
                        help="测试持续时间（秒）")
    parser.add_argument("--runtime", choices=["runc", "kata"], default="runc",
                        help="OCI 运行时 (默认 runc)")
    parser.add_argument("--output", default=OUTPUT_FILE,
                        help="JSON 报告输出路径")
    parser.add_argument("--preconfig", type=int, default=0,
                        help="提前生成 N 个 pod config (默认 0, 即按需生成)")
    parser.add_argument("--cleanup", action="store_true",
                        help="每个 sandbox 就绪后立即清理（默认不清理）")
    parser.add_argument("--cpuset-cpus", type=str, default=None,
                        help="限制所有测试 pod 的 CPU 核心，如 '0-3' "
                             "(写入 /sys/fs/cgroup/cpuset/k8s.io/cpuset.cpus)")
    parser.add_argument("--cpuset-mems", type=str, default=None,
                        help="限制所有测试 pod 的 NUMA 内存节点，如 '0' "
                             "(写入 /sys/fs/cgroup/cpuset/k8s.io/cpuset.mems)")
    parser.add_argument("--no-clear-caches", action="store_true",
                        help="跳过清缓存（由外部调用者统一处理）")
    parser.add_argument("--no-batch-cleanup", action="store_true",
                        help="跳过最终批量清理（由外部调用者统一处理）")
    parser.add_argument("--worker-id", type=int, default=0,
                        help="Worker 标识，用于区分不同进程的配置文件和 pod 名称 (默认 0)")
    args = parser.parse_args()

    G.cleanup = args.cleanup
    G.cpuset_cpus = args.cpuset_cpus
    G.cpuset_mems = args.cpuset_mems

    if not os.path.isdir(POD_CONFIG_DIR):
        os.makedirs(POD_CONFIG_DIR)

    print("")
    print("=" * 50)
    print("单 Worker Pod 沙箱冷启动测试")
    print("=" * 50)
    print("时长:     {}s".format(args.duration))
    print("清理:     {}".format("是 (每就绪一个清理一个)" if G.cleanup else "否 (仅结束时统一清理)"))
    if args.worker_id != 0:
        print("Worker ID: {}".format(args.worker_id))
    if G.cpuset_cpus or G.cpuset_mems:
        parts = []
        if G.cpuset_cpus:
            parts.append("cpus={}".format(G.cpuset_cpus))
        if G.cpuset_mems:
            parts.append("mems={}".format(G.cpuset_mems))
        print("cpuset:   {}".format(" ".join(parts)))
    print("=" * 50)
    print("")

    # 清缓存
    if not args.no_clear_caches:
        clear_caches()

    # 预生成 config
    if args.preconfig > 0:
        preconfig_configs(args.preconfig, args.worker_id)

    # 设置 cpuset 限制
    setup_cpuset_limits(args.cpuset_cpus, args.cpuset_mems)

    # ============================================================
    # 主循环：串行 runp → poll → record → next
    # ============================================================
    results = []
    seq = 0
    t_start = time.perf_counter()

    while True:
        elapsed = time.perf_counter() - t_start
        if elapsed >= args.duration:
            break

        pod_config_path = get_config(args.worker_id, seq)

        t0 = time.perf_counter()
        try:
            sandbox_id = run_pod_sandbox(pod_config_path, args.runtime)
        except Exception:
            t1 = time.perf_counter()
            t_runp_ms = round((t1 - t0) * 1000, 3)
            results.append(SandboxResult(seq, "FAIL", t_runp_ms, 0, t_runp_ms))
            seq += 1
            continue
        t1 = time.perf_counter()
        t_runp_ms = round((t1 - t0) * 1000, 3)

        try:
            poll_until_ready(sandbox_id)
            t_ready_ms = round((time.perf_counter() - t1) * 1000, 3)
        except Exception:
            t_ready_ms = -1

        results.append(SandboxResult(
            seq,
            sandbox_id[:12],
            t_runp_ms,
            t_ready_ms if t_ready_ms >= 0 else 0,
            round(t_runp_ms + max(t_ready_ms, 0), 3)))
        if G.cleanup:
            cleanup_sandbox(sandbox_id)
        seq += 1

    elapsed_ms = round((time.perf_counter() - t_start) * 1000, 1)
    print("完成: 挂钟 {}ms, 共 {} sandboxes".format(elapsed_ms, len(results)))

    # 恢复 cpuset 默认值
    restore_cpuset_limits(args.cpuset_cpus, args.cpuset_mems)

    print_summary(results, args.duration)

    # 最终清理
    if not args.no_batch_cleanup:
        print("")
        print("[final cleanup] 清理所有测试 pod...")
        batch_cleanup()
        print("[final cleanup] 完成")

    # JSON 报告
    report = {
        "config": {
            "duration": args.duration,
            "pause_image": PAUSE_IMAGE,
            "runtime": "{} (via crictl)".format(args.runtime),
            "on_demand_config": _on_demand_triggered,
            "cpuset_cpus": args.cpuset_cpus,
            "cpuset_mems": args.cpuset_mems,
        },
        "summary": {
            "total_sandboxes": len(results),
            "success": sum(1 for r in results if r.sandbox_id != "FAIL"),
            "failed": sum(1 for r in results if r.sandbox_id == "FAIL"),
        },
        "phases": {
            "t_runp": compute_stats(
                [r.t_runp_ms for r in results]).to_dict(),
            "t_ready": compute_stats(
                [r.t_ready_ms for r in results if r.t_ready_ms >= 0]).to_dict(),
            "total": compute_stats(
                [r.total_ms for r in results]).to_dict(),
        },
        "results": [r.to_dict() for r in results],
    }

    with open(args.output, "w") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)

    print("报告已保存: {}".format(args.output))
