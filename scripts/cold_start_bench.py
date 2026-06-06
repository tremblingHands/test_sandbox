#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Pod 沙箱冷启动时延测试（基于 crictl）
兼容 Python 3.6+，仅创建 Pod 沙箱 + pause 容器，不含镜像拉取。

用法:
    # 首次使用先准备环境
    ./scripts/setup.sh

    # 运行测试
    python3 cold_start_bench.py --runs 50 --output cold_start_report.json

前置条件（脚本运行时自动检查，也可用 setup.sh 一次性准备）:
    - containerd 运行中 + crictl 可用
    - pause 镜像已缓存（缺失则自动执行 crictl pull）
"""

import time
import subprocess
import statistics
import json
import uuid
import argparse
import sys
import os


# ============================================================
# 配置（根据环境修改）
# ============================================================
PAUSE_IMAGE = "registry.aliyuncs.com/google_containers/pause:3.9"
OUTPUT_FILE = "cold_start_report.json"


# ============================================================
# 数据模型（不使用 dataclass，兼容 Python 3.6）
# ============================================================
class ColdStartTrace(object):
    """单次冷启动的完整时延追踪"""

    def __init__(self, run_id, sandbox_id, t_runp_ms, t_ready_ms, total_ms):
        self.run_id = run_id
        self.sandbox_id = sandbox_id
        self.t_runp_ms = t_runp_ms
        self.t_ready_ms = t_ready_ms
        self.total_ms = total_ms

    def to_dict(self):
        return {
            "run_id": self.run_id,
            "sandbox_id": self.sandbox_id,
            "t_runp_ms": self.t_runp_ms,
            "t_ready_ms": self.t_ready_ms,
            "total_ms": self.total_ms,
        }


class Stats(object):
    """统计摘要"""

    def __init__(self, p50, p95, p99, mean, stddev, min_val, max_val):
        self.p50 = p50
        self.p95 = p95
        self.p99 = p99
        self.mean = mean
        self.stddev = stddev
        self.min_val = min_val
        self.max_val = max_val

    def to_dict(self):
        return {
            "p50": self.p50,
            "p95": self.p95,
            "p99": self.p99,
            "mean": self.mean,
            "stddev": self.stddev,
            "min_val": self.min_val,
            "max_val": self.max_val,
        }


# ============================================================
# 工具函数
# ============================================================
def compute_stats(values):
    # type: (list) -> Stats
    s = sorted(values)
    n = len(s)
    return Stats(
        p50=s[int(n * 0.50) - 1] if n > 0 else 0,
        p95=s[int(n * 0.95) - 1] if n > 0 else 0,
        p99=s[int(n * 0.99) - 1] if n > 0 else 0,
        mean=statistics.mean(s) if n > 0 else 0,
        stddev=statistics.stdev(s) if n > 1 else 0,
        min_val=s[0] if n > 0 else 0,
        max_val=s[-1] if n > 0 else 0,
    )


def _run(cmd):
    # type: (str) -> str
    """执行 shell 命令，返回 stdout。失败抛出异常。"""
    r = subprocess.run(
        cmd, shell=True, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, timeout=60
    )
    stdout = r.stdout.decode("utf-8", errors="replace").strip()
    stderr = r.stderr.decode("utf-8", errors="replace").strip()
    if r.returncode != 0:
        raise RuntimeError("命令失败 [{}]: {}".format(cmd, stderr))
    return stdout


def _write_file(path, content):
    # type: (str, str) -> None
    with open(path, "w") as f:
        f.write(content)


def _file_exists(path):
    # type: (str) -> bool
    return os.path.isfile(path)


# ============================================================
# 前置条件检查
# ============================================================
def check_prerequisites():
    """检查运行环境，缺失条件时自动修复（如拉取 pause 镜像）。"""
    errors = []

    # 1. 检查 crictl 是否可用
    try:
        version = _run("crictl --version")
        print("[check] crictl 可用: {}".format(version))
    except Exception:
        errors.append("crictl 未找到或不可用，请执行 ./scripts/setup.sh")

    # 2. 检查 CRI 运行时是否正常
    try:
        _run("crictl info")
        print("[check] CRI 运行时连接正常")
    except Exception as e:
        errors.append("CRI 运行时异常: {}".format(e))

    # 3. 检查 pause 镜像，缺失则自动拉取
    try:
        existing = _run("crictl images -q {}".format(PAUSE_IMAGE))
        if PAUSE_IMAGE in existing:
            print("[check] pause 镜像已缓存: {}".format(PAUSE_IMAGE))
        else:
            raise RuntimeError("镜像未找到")
    except Exception:
        print("[check] pause 镜像缺失，正在拉取: {} ...".format(PAUSE_IMAGE))
        try:
            _run("crictl pull {}".format(PAUSE_IMAGE))
            print("[check] pause 镜像拉取完成: {}".format(PAUSE_IMAGE))
        except Exception as e:
            errors.append("pause 镜像拉取失败: {}".format(e))

    # 4. 确认 drop_caches 可用
    if not _file_exists("/proc/sys/vm/drop_caches"):
        errors.append("/proc/sys/vm/drop_caches 不可用，清除缓存功能将无法工作")

    if errors:
        print("\n前置条件检查失败:")
        for err in errors:
            print("  ✗ {}".format(err))
        sys.exit(1)

    print("[check] 所有前置条件满足\n")


# ============================================================
# Pod 沙箱操作（crictl 封装）
# ============================================================
def prepare_pod_config(run_id):
    # type: (int) -> str
    """为本次测试生成唯一 pod 配置，避免 UID 冲突"""
    unique_uid = "bench-{}".format(uuid.uuid4().hex[:12])
    path = "/tmp/sandbox-pod-{}.json".format(run_id)
    content = json.dumps({
        "metadata": {
            "name": "sandbox-bench-{}".format(run_id),
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


def run_pod_sandbox(pod_config_path, runtime="runc"):
    # type: (str, str) -> str
    """调用 crictl runp 创建 Pod 沙箱，返回 sandbox ID"""
    return _run("crictl runp --runtime {} {}".format(runtime, pod_config_path))


def wait_until_ready(sandbox_id, timeout_sec=30.0):
    # type: (str, float) -> None
    """轮询 PodSandboxStatus 直到状态变为 SANDBOX_READY"""
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
        time.sleep(0.01)  # 10ms 轮询间隔
    raise RuntimeError("沙箱 {} 在 {}s 内未就绪".format(sandbox_id, timeout_sec))


def stop_pod_sandbox(sandbox_id):
    # type: (str) -> None
    """停止沙箱"""
    _run("crictl stopp {}".format(sandbox_id))


def remove_pod_sandbox(sandbox_id):
    # type: (str) -> None
    """删除沙箱"""
    _run("crictl rmp {}".format(sandbox_id))


def clear_caches():
    """清除内核缓存，保障每轮都是真正的冷启动"""
    try:
        with open("/proc/sys/vm/drop_caches", "w") as f:
            f.write("3\n")
        time.sleep(3)
    except Exception:
        pass  # 容器环境可能不支持


# ============================================================
# 核心测试：单次冷启动
# ============================================================
def single_cold_start(run_id):
    # type: (int) -> ColdStartTrace
    """
    执行一次完整的冷启动流程：
        crictl runp → 得到 sandbox ID → 等待 SANDBOX_READY
    全程不含镜像拉取（pause 镜像已预缓存）。
    """
    pod_config_path = prepare_pod_config(run_id)

    # ---- 阶段 1: t_runp ---- #
    t0 = time.perf_counter()
    sandbox_id = run_pod_sandbox(pod_config_path, args.runtime)
    t1 = time.perf_counter()
    t_runp_ms = (t1 - t0) * 1000

    # ---- 阶段 2: t_ready ---- #
    wait_until_ready(sandbox_id)
    t2 = time.perf_counter()
    t_ready_ms = (t2 - t1) * 1000

    # ---- 清理 ---- #
    stop_pod_sandbox(sandbox_id)
    remove_pod_sandbox(sandbox_id)

    return ColdStartTrace(
        run_id=run_id,
        sandbox_id=sandbox_id,
        t_runp_ms=round(t_runp_ms, 3),
        t_ready_ms=round(t_ready_ms, 3),
        total_ms=round(t_runp_ms + t_ready_ms, 3),
    )


# ============================================================
# 测试主流程
# ============================================================
def run_benchmark(runs=50):
    # type: (int) -> dict
    traces = []   # type: list
    failures = [] # type: list

    for i in range(runs):
        print("[{}/{}] 冷启动中...".format(i + 1, runs), end=" ", flush=True)
        clear_caches()
        try:
            trace = single_cold_start(i + 1)
            traces.append(trace)
            print("✓ t_runp={:.1f}ms  t_ready={:.1f}ms  total={:.1f}ms".format(
                trace.t_runp_ms, trace.t_ready_ms, trace.total_ms))
        except Exception as e:
            failures.append({"run_id": i + 1, "error": str(e)})
            print("✗ {}".format(e))

    totals = [t.total_ms for t in traces]
    runps = [t.t_runp_ms for t in traces]
    readys = [t.t_ready_ms for t in traces]

    return {
        "config": {
            "pause_image": PAUSE_IMAGE,
            "runtime": "runc (via crictl)",
            "description": "Pod sandbox cold start — pause container only, no image pull",
        },
        "summary": {
            "total_runs": len(traces) + len(failures),
            "success_runs": len(traces),
            "failure_runs": len(failures),
        },
        "phases": {
            "t_runp":   compute_stats(runps).to_dict(),
            "t_ready":  compute_stats(readys).to_dict(),
            "total_ms": compute_stats(totals).to_dict(),
        },
        "traces": [t.to_dict() for t in traces],
        "failures": failures,
    }


# ============================================================
# CLI
# ============================================================
if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Pod 沙箱冷启动时延测试 (crictl)"
    )
    parser.add_argument("--runs", type=int, default=50, help="测试轮次（默认 50）")
    parser.add_argument("--runtime", choices=["runc", "kata"], default="runc",
                        help="OCI 运行时 (默认 runc)")
    parser.add_argument("--output", default=OUTPUT_FILE, help="JSON 报告输出路径")
    parser.add_argument("--skip-check", action="store_true", help="跳过前置条件检查")
    args = parser.parse_args()

    if not args.skip_check:
        check_prerequisites()

    report = run_benchmark(runs=args.runs)

    with open(args.output, "w") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)

    # ---- 控制台摘要 ---- #
    total = report["phases"]["total_ms"]
    t_runp = report["phases"]["t_runp"]
    t_ready = report["phases"]["t_ready"]

    print("")
    print("=" * 70)
    print("Pod 沙箱冷启动时延测试 — 摘要")
    print("=" * 70)
    print("成功率: {}/{}".format(
        report["summary"]["success_runs"],
        report["summary"]["total_runs"]))
    print("")
    print("{:<25} {:>10} {:>10} {:>10} {:>10}".format(
        "阶段", "P50(ms)", "P95(ms)", "P99(ms)", "Mean(ms)"))
    print("-" * 65)
    print("{:<25} {:>10.1f} {:>10.1f} {:>10.1f} {:>10.1f}".format(
        "t_runp (RunPodSandbox API)",
        t_runp["p50"], t_runp["p95"], t_runp["p99"], t_runp["mean"]))
    print("{:<25} {:>10.1f} {:>10.1f} {:>10.1f} {:>10.1f}".format(
        "t_ready (等待就绪)",
        t_ready["p50"], t_ready["p95"], t_ready["p99"], t_ready["mean"]))
    print("-" * 65)
    print("{:<25} {:>10.1f} {:>10.1f} {:>10.1f} {:>10.1f}".format(
        "总冷启动时延",
        total["p50"], total["p95"], total["p99"], total["mean"]))
    print("")
    print("报告已保存: {}".format(args.output))
