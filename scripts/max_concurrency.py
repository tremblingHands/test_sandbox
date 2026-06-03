#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
Pod 沙箱最大并发数评估（基于 crictl）
持续创建沙箱并等待就绪，评估单机可同时存在的最大沙箱数。

原理:
    逐个创建 Pod 沙箱，每个就绪后不销毁，继续创建下一个，
    直到创建失败（资源耗尽）或达到用户指定的上限。
    统计成功创建的沙箱总数即为最大并发容量。

用法:
    python3 max_concurrency.py --max 500    # 上限 500
    python3 max_concurrency.py              # 无上限，直到失败

前置条件:
    ./scripts/setup.sh
"""

import time
import subprocess
import json
import uuid
import argparse
import sys
import os


PAUSE_IMAGE = "registry.aliyuncs.com/google_containers/pause:3.9"
POD_CONFIG_DIR = "/tmp/max-conc-pod-configs"
POD_NAME_PREFIX = "maxconc"


def _run(cmd):
    r = subprocess.run(
        cmd, shell=True, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, timeout=60
    )
    stdout = r.stdout.decode("utf-8", errors="replace").strip()
    stderr = r.stderr.decode("utf-8", errors="replace").strip()
    return r.returncode, stdout, stderr


def _run_checked(cmd):
    rc, stdout, stderr = _run(cmd)
    if rc != 0:
        raise RuntimeError("cmd failed [{}]: {}".format(cmd, stderr))
    return stdout


def check_prerequisites():
    print("[check] 检查环境...")
    _run_checked("crictl --version")
    _run_checked("crictl info")
    existing = _run_checked("crictl images -q {}".format(PAUSE_IMAGE))
    if PAUSE_IMAGE not in existing:
        print("[check] 拉取 pause 镜像...")
        _run_checked("crictl pull {}".format(PAUSE_IMAGE))
    print("[check] 环境就绪\n")


def generate_pod_config(index):
    name = "{}-{}".format(POD_NAME_PREFIX, index)
    uid = "maxc-{}-{}".format(uuid.uuid4().hex[:8], index)
    path = "{}/pod-{}.json".format(POD_CONFIG_DIR, index)
    content = json.dumps({
        "metadata": {
            "name": name,
            "namespace": "default",
            "uid": uid,
            "attempt": 1
        },
        "log_directory": "/tmp/sandbox-logs",
        "linux": {
            "security_context": {
                "namespace_options": {"network": 0}
            }
        }
    })
    with open(path, "w") as f:
        f.write(content)
    return path, name


def create_sandbox(pod_config_path):
    return _run_checked("crictl runp --runtime runc {}".format(pod_config_path))


def wait_until_ready(sandbox_id, timeout_sec=60.0):
    deadline = time.perf_counter() + timeout_sec
    while time.perf_counter() < deadline:
        try:
            info = _run_checked("crictl inspectp {}".format(sandbox_id))
            status = json.loads(info)
            state = status.get("status", {}).get("state", "")
            if state == "SANDBOX_READY":
                return True
        except RuntimeError:
            pass
        time.sleep(0.05)
    return False


def get_pod_count():
    rc, stdout, _ = _run(
        "crictl pods --state Ready -q --name {} 2>/dev/null".format(POD_NAME_PREFIX))
    if rc != 0 or not stdout:
        return 0
    return len([l for l in stdout.split("\n") if l.strip()])


def get_containerd_memory():
    """获取 containerd 进程内存占用（粗略估计）"""
    rc, stdout, _ = _run(
        "awk '/^VmRSS:/ {print $2}' /proc/$(pidof containerd | awk '{print $1}')/status 2>/dev/null")
    if rc != 0 or not stdout:
        return 0
    return int(stdout.strip()) // 1024   # KB → MB


def batch_cleanup():
    print("[cleanup] 清理所有测试 pod...")
    sandboxes = _run_checked("crictl pods -q --name {}".format(POD_NAME_PREFIX))
    for sid in sandboxes.split("\n") if sandboxes else []:
        sid = sid.strip()
        if sid:
            try:
                _run("crictl stopp {}".format(sid))
            except Exception:
                pass
            try:
                _run("crictl rmp {}".format(sid))
            except Exception:
                pass


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Pod 沙箱最大并发数评估"
    )
    parser.add_argument("--max", type=int, default=0,
                        help="上限（0 = 无上限，直到创建失败）")
    parser.add_argument("--output", default="max_concurrency_report.json",
                        help="报告输出路径")
    parser.add_argument("--no-cleanup", action="store_true",
                        help="保留所有 pod 不清理（便于调试）")
    parser.add_argument("--skip-check", action="store_true",
                        help="跳过前置条件检查")
    args = parser.parse_args()

    if not args.skip_check:
        check_prerequisites()

    if not os.path.isdir(POD_CONFIG_DIR):
        os.makedirs(POD_CONFIG_DIR)

    print("=" * 55)
    print("Pod 沙箱最大并发数评估")
    print("=" * 55)
    if args.max > 0:
        print("上限: {}".format(args.max))
    else:
        print("上限: 无（直到创建失败）")
    print("镜像: {}".format(PAUSE_IMAGE))
    print("=" * 55)
    print("")

    sandbox_ids = []
    failures = []
    start_time = time.perf_counter()

    for i in range(1, args.max + 1 if args.max > 0 else sys.maxsize):
        pod_config_path, pod_name = generate_pod_config(i)

        # 记录当前状态
        mem_before = get_containerd_memory()
        ready_before = get_pod_count()

        # ---- 创建 ---- #
        t0 = time.perf_counter()
        try:
            sandbox_id = create_sandbox(pod_config_path)
        except Exception as e:
            err_msg = str(e)
            print("\n[FAIL] 第 {} 个沙箱创建失败:".format(i))
            print(err_msg)
            failures.append({"index": i, "error": err_msg})
            break
        t_runp_ms = round((time.perf_counter() - t0) * 1000, 1)

        # ---- 等待就绪 ---- #
        t1 = time.perf_counter()
        if not wait_until_ready(sandbox_id):
            print("[WARN] 第 {} 个沙箱就绪超时: {}".format(i, sandbox_id[:12]))
            failures.append({"index": i, "sandbox_id": sandbox_id[:12],
                             "error": "ready timeout"})
            break
        t_ready_ms = round((time.perf_counter() - t1) * 1000, 1)
        total_ms = round(t_runp_ms + t_ready_ms, 1)

        sandbox_ids.append(sandbox_id)
        ready_now = ready_before + 1   # 刚创建的这个
        mem_now = get_containerd_memory()

        print("[{:>4}] runp={:>6.0f}ms  ready={:>5.0f}ms  total={:>6.0f}ms  "
              "alive={:>5}  mem={:>5}MB".format(
                  i, t_runp_ms, t_ready_ms, total_ms, ready_now, mem_now))

        elapsed = time.perf_counter() - start_time
        rate = i / elapsed if elapsed > 0 else 0
        if i % 50 == 0:
            print("       --- {} 个完成, {:.0f}s, 速率 {:.1f} sandbox/s ---".format(
                i, elapsed, rate))

    elapsed_total = time.perf_counter() - start_time
    max_count = len(sandbox_ids)

    # 输出结果
    print("")
    print("=" * 55)
    print("结果")
    print("=" * 55)
    print("最大并发数: {}".format(max_count))
    print("总耗时:     {:.1f}s".format(elapsed_total))
    if max_count > 0:
        print("平均速率:   {:.1f} sandbox/s".format(max_count / elapsed_total))
    print("失败数:     {}".format(len(failures)))
    if failures:
        for f in failures:
            print("  - 第 {} 个: {}".format(f["index"], f["error"]))
    mem_final = get_containerd_memory()
    print("containerd 内存: {}MB".format(mem_final))
    print("")

    if args.no_cleanup:
        print("pod 已保留（--no-cleanup），可手动调试。")
        print("清理命令: crictl pods -q --name {} | xargs -r -n1 sh -c 'crictl stopp $1; crictl rmp $1' --".format(POD_NAME_PREFIX))
    else:
        print("10 秒后将清理所有 pod...")
        try:
            time.sleep(10)
        except KeyboardInterrupt:
            pass
        batch_cleanup()

    # JSON 报告
    report = {
        "max_concurrency": max_count,
        "elapsed_seconds": round(elapsed_total, 1),
        "avg_rate": round(max_count / elapsed_total, 1) if max_count > 0 else 0,
        "failures": failures,
        "containerd_memory_mb": mem_final,
        "config": {
            "pause_image": PAUSE_IMAGE,
            "upper_limit": args.max,
        },
        "sandbox_ids": [s[:12] for s in sandbox_ids],
    }
    with open(args.output, "w") as f:
        json.dump(report, f, indent=2, ensure_ascii=False)

    print("报告已保存: {}".format(args.output))
