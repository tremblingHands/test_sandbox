#!/usr/bin/env python3
"""
Pod 沙箱冷启动时延测试（基于 crictl）
仅创建 Pod 沙箱 + pause 容器，不包含业务容器，不含镜像拉取。

用法:
    python3 cold_start_bench.py --runs 50 --output cold_start_report.json

前置条件:
    crictl pull registry.k8s.io/pause:3.9   # pause 镜像必须预先缓存
"""

import time
import subprocess
import statistics
import json
import uuid
import argparse
from dataclasses import dataclass, asdict
from pathlib import Path


# ============================================================
# 配置（根据环境修改）
# ============================================================
PAUSE_IMAGE = "registry.k8s.io/pause:3.9"
OUTPUT_FILE = "cold_start_report.json"


# ============================================================
# 数据模型
# ============================================================
@dataclass
class ColdStartTrace:
    """单次冷启动的完整时延追踪"""
    run_id: int
    sandbox_id: str
    t_runp_ms: float        # RunPodSandbox API 调用耗时至得到 sandbox ID
    t_ready_ms: float       # 从 sandbox ID 返回到 PodSandboxStatus 变为 SANDBOX_READY
    total_ms: float         # 总耗时 = t_runp + t_ready


@dataclass
class Stats:
    """统计摘要"""
    p50: float; p95: float; p99: float
    mean: float; stddev: float; min_val: float; max_val: float


# ============================================================
# 工具函数
# ============================================================
def compute_stats(values: list[float]) -> Stats:
    s = sorted(values)
    n = len(s)
    return Stats(
        p50=s[int(n * 0.50) - 1] if n > 0 else 0,
        p95=s[int(n * 0.95) - 1] if n > 0 else 0,
        p99=s[int(n * 0.99) - 1] if n > 0 else 0,
        mean=statistics.mean(s),
        stddev=statistics.stdev(s) if n > 1 else 0,
        min_val=s[0],
        max_val=s[-1],
    )


def _run(cmd: str) -> str:
    """执行 shell 命令，返回 stdout。失败抛出异常。"""
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=30)
    if r.returncode != 0:
        raise RuntimeError(f"命令失败 [{cmd}]: {r.stderr.strip()}")
    return r.stdout.strip()


# ============================================================
# Pod 沙箱操作（crictl 封装）
# ============================================================
def prepare_pod_config(run_id: int) -> str:
    """为本次测试生成唯一 pod 配置，避免 UID 冲突"""
    unique_uid = f"bench-{uuid.uuid4().hex[:12]}"
    path = f"/tmp/sandbox-pod-{run_id}.json"
    content = json.dumps({
        "metadata": {
            "name": f"sandbox-bench-{run_id}",
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
    Path(path).write_text(content)
    return path


def run_pod_sandbox(pod_config_path: str) -> str:
    """调用 crictl runp 创建 Pod 沙箱，返回 sandbox ID"""
    return _run(f"crictl runp --runtime runc {pod_config_path}")


def wait_until_ready(sandbox_id: str, timeout_sec: float = 30.0) -> None:
    """轮询 PodSandboxStatus 直到状态变为 SANDBOX_READY"""
    deadline = time.perf_counter() + timeout_sec
    while time.perf_counter() < deadline:
        try:
            info = _run(f"crictl inspectp {sandbox_id}")
            status = json.loads(info)
            state = status.get("status", {}).get("state", "")
            # 注意: crictl inspectp 返回的字段依赖版本。
            # 也可以用 crictl pods -q --state Ready 检查。
            if state == "SANDBOX_READY":
                return
        except RuntimeError:
            pass
        time.sleep(0.01)  # 10ms 轮询间隔
    raise TimeoutError(f"沙箱 {sandbox_id} 在 {timeout_sec}s 内未就绪")


def stop_pod_sandbox(sandbox_id: str) -> None:
    """停止沙箱"""
    _run(f"crictl stopp {sandbox_id}")


def remove_pod_sandbox(sandbox_id: str) -> None:
    """删除沙箱"""
    _run(f"crictl rmp {sandbox_id}")


def clear_caches():
    """清除内核缓存，保障每轮都是真正的冷启动"""
    _run("echo 3 > /proc/sys/vm/drop_caches")
    time.sleep(3)  # 冷却间隔


# ============================================================
# 核心测试：单次冷启动
# ============================================================
def single_cold_start(run_id: int) -> ColdStartTrace:
    """
    执行一次完整的冷启动流程：
        crictl runp → 得到 sandbox ID → 等待 SANDBOX_READY
    全程不含镜像拉取（pause 镜像已预缓存）。
    """
    pod_config_path = prepare_pod_config(run_id)

    # ---- 阶段 1: t_runp ---- #
    t0 = time.perf_counter()
    sandbox_id = run_pod_sandbox(pod_config_path)
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
def run_benchmark(runs: int = 50) -> dict:
    traces: list[ColdStartTrace] = []
    failures: list[dict] = []

    for i in range(runs):
        print(f"[{i+1}/{runs}] 冷启动中...", end=" ", flush=True)
        clear_caches()
        try:
            trace = single_cold_start(i + 1)
            traces.append(trace)
            print(f"✓ t_runp={trace.t_runp_ms:.1f}ms  t_ready={trace.t_ready_ms:.1f}ms  total={trace.total_ms:.1f}ms")
        except Exception as e:
            failures.append({"run_id": i + 1, "error": str(e)})
            print(f"✗ {e}")

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
            "t_runp":   asdict(compute_stats(runps)),
            "t_ready":  asdict(compute_stats(readys)),
            "total_ms": asdict(compute_stats(totals)),
        },
        "traces": [asdict(t) for t in traces],
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
    parser.add_argument("--output", default=OUTPUT_FILE, help="JSON 报告输出路径")
    args = parser.parse_args()

    report = run_benchmark(runs=args.runs)

    with open(args.output, "w") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)

    # ---- 控制台摘要 ---- #
    total = report["phases"]["total_ms"]
    t_runp = report["phases"]["t_runp"]
    t_ready = report["phases"]["t_ready"]

    print(f"\n{'='*70}")
    print(f"Pod 沙箱冷启动时延测试 — 摘要")
    print(f"{'='*70}")
    print(f"成功率: {report['summary']['success_runs']}/{report['summary']['total_runs']}")
    print(f"\n{'阶段':<25} {'P50(ms)':>10} {'P95(ms)':>10} {'P99(ms)':>10} {'Mean(ms)':>10}")
    print(f"{'-'*65}")
    print(f"{'t_runp (RunPodSandbox API)':<25} {t_runp['p50']:>10.1f} {t_runp['p95']:>10.1f} {t_runp['p99']:>10.1f} {t_runp['mean']:>10.1f}")
    print(f"{'t_ready (等待就绪)':<25} {t_ready['p50']:>10.1f} {t_ready['p95']:>10.1f} {t_ready['p99']:>10.1f} {t_ready['mean']:>10.1f}")
    print(f"{'-'*65}")
    print(f"{'总冷启动时延':<25} {total['p50']:>10.1f} {total['p95']:>10.1f} {total['p99']:>10.1f} {total['mean']:>10.1f}")
    print(f"\n报告已保存: {args.output}")
