#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
系统资源采样器（兼容 Python 3.6+）

子命令:
    metadata   写入静态环境快照 (metadata.json)
    capture    按间隔采样时序数据 (timeseries.jsonl)
    summarize  从时序数据生成汇总 (summary.json)

用法:
    python3 resource_sampler.py metadata --output results/multi/resources/metadata.json \\
        --cpus 0-7 --numa 0 --proc-count 4

    python3 resource_sampler.py capture --output-dir results/multi/resources \\
        --duration 60 --interval 0.1 --cpus 0,1,2,3

    python3 resource_sampler.py summarize --output-dir results/multi/resources
"""

import argparse
import datetime
import json
import math
import os
import platform
import re
import statistics
import subprocess
import sys
import time


# ============================================================
# 工具函数
# ============================================================
def _run(cmd, timeout=10):
    try:
        r = subprocess.run(
            cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=timeout,
        )
        out = r.stdout.decode("utf-8", errors="replace").strip()
        err = r.stderr.decode("utf-8", errors="replace").strip()
        return r.returncode, out, err
    except Exception as exc:
        return 1, "", str(exc)


def _read_int(path, default=0):
    try:
        with open(path) as f:
            return int(f.read().strip())
    except (IOError, OSError, ValueError):
        return default


def _read_text(path, default=""):
    try:
        with open(path) as f:
            return f.read().strip()
    except (IOError, OSError):
        return default


def _parse_cpu_list(spec):
    """解析 CPU 列表: '0-7' 或 '0,2,4'。"""
    cpus = []
    if not spec:
        return cpus
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            start_s, end_s = part.split("-", 1)
            start, end = int(start_s), int(end_s)
            cpus.extend(range(start, end + 1))
        else:
            cpus.append(int(part))
    return cpus


def _percentile(sorted_vals, pct):
    if not sorted_vals:
        return 0.0
    n = len(sorted_vals)
    idx = max(0, min(n - 1, int(math.ceil(n * pct / 100.0)) - 1))
    return float(sorted_vals[idx])


def _stats(values):
    if not values:
        return {"min": 0, "max": 0, "mean": 0, "p50": 0, "p95": 0, "p99": 0}
    s = sorted(values)
    n = len(s)
    return {
        "min": s[0],
        "max": s[-1],
        "mean": round(statistics.mean(s), 2),
        "p50": round(_percentile(s, 50), 2),
        "p95": round(_percentile(s, 95), 2),
        "p99": round(_percentile(s, 99), 2),
    }


def _now_iso():
    return datetime.datetime.now().isoformat(timespec="seconds")


def _find_containerd_pid():
    rc, out, _ = _run("pgrep -x containerd")
    if rc == 0 and out:
        return int(out.splitlines()[0])
    rc, out, _ = _run("systemctl show containerd -p MainPID --value")
    if rc == 0 and out.isdigit() and int(out) > 0:
        return int(out)
    return None


def _proc_metrics(pid):
    if not pid:
        return {}
    base = "/proc/{}".format(pid)
    if not os.path.isdir(base):
        return {}
    status = _read_text(os.path.join(base, "status"))
    metrics = {"pid": pid}
    for line in status.splitlines():
        if line.startswith(("VmRSS:", "Threads:", "FDSize:")):
            key, val = line.split(":", 1)
            metrics[key.strip()] = val.strip()
    try:
        metrics["fd_count"] = len(os.listdir(os.path.join(base, "fd")))
    except OSError:
        metrics["fd_count"] = 0
    rss_kb = 0
    m = re.search(r"VmRSS:\s+(\d+)", status)
    if m:
        rss_kb = int(m.group(1))
    metrics["rss_mb"] = round(rss_kb / 1024.0, 1)
    m = re.search(r"Threads:\s+(\d+)", status)
    metrics["threads"] = int(m.group(1)) if m else 0
    return metrics


def _cpus_to_mpstat_arg(cpus_spec):
    """将 CPU 规格转为 mpstat -P 参数（保留范围，如 1-8,33-47）。"""
    if not cpus_spec:
        return ""
    parts = []
    for part in cpus_spec.split(","):
        part = part.strip()
        if part:
            parts.append(part)
    return ",".join(parts)


def _find_containerd_cpus():
    """从 containerd.service 解析 numactl -C 绑定的 CPU。"""
    service_file = "/usr/lib/systemd/system/containerd.service"
    text = _read_text(service_file)
    if not text:
        return ""
    m = re.search(r"numactl\s+-C\s+([0-9,\-]+)", text)
    return m.group(1) if m else ""


MPSTAT_FIELDS = (
    "usr", "nice", "sys", "iowait", "irq", "soft", "steal", "guest", "gnice", "idle",
)


def _average_mpstat_rows(rows):
    """对多核 mpstat 采样行取算术平均。"""
    if not rows:
        return None
    out = {"cpus": rows[0].get("cpus", "")}
    for field in MPSTAT_FIELDS:
        vals = [r[field] for r in rows if field in r and r[field] is not None]
        if vals:
            out[field] = round(sum(vals) / len(vals), 2)
    return out


def _parse_mpstat_json(output, cpus_spec):
    try:
        data = json.loads(output)
        stats = data["sysstat"]["hosts"][0]["statistics"][-1]
        cpu_load = stats.get("cpu-load", [])
        rows = []
        for entry in cpu_load:
            cpu_id = str(entry.get("cpu", ""))
            if cpu_id.lower() in ("all", "average"):
                continue
            row = {"cpus": cpus_spec}
            for field in MPSTAT_FIELDS:
                if field in entry:
                    row[field] = float(entry[field])
            rows.append(row)
        return _average_mpstat_rows(rows)
    except (ValueError, KeyError, IndexError, TypeError):
        return None


def _parse_mpstat_text(output, cpus_spec):
    """解析 mpstat 文本输出 Average 段（各核）并合并平均。"""
    rows = []
    in_average = False
    header_fields = None

    for line in output.splitlines():
        line = line.strip()
        if line.startswith("Average:") and "CPU" in line and "%usr" in line:
            in_average = True
            header_fields = None
            continue
        if not in_average or not line.startswith("Average:"):
            continue

        parts = line.split()
        if len(parts) < 3:
            continue
        # Average: <cpu> %usr %nice %sys ...
        if parts[1] == "CPU":
            continue
        try:
            int(parts[1])
        except ValueError:
            continue

        vals = []
        for p in parts[2:]:
            try:
                vals.append(float(p))
            except ValueError:
                break
        if len(vals) < len(MPSTAT_FIELDS):
            continue

        row = {"cpus": cpus_spec}
        for i, field in enumerate(MPSTAT_FIELDS):
            row[field] = vals[i]
        rows.append(row)

    return _average_mpstat_rows(rows)


def _sample_mpstat(cpus_spec):
    """对指定 CPU 组运行 mpstat，返回合并平均后的 CPU 分解指标。"""
    mpstat_arg = _cpus_to_mpstat_arg(cpus_spec)
    if not mpstat_arg:
        return None

    cmd = "mpstat -P {} 1 1".format(mpstat_arg)
    rc, out, _ = _run(cmd, timeout=15)
    if rc != 0 or not out:
        return None

    # 优先 JSON（sysstat 11.7+ 已支持）
    rcj, outj, _ = _run("mpstat -P {} -o JSON 1 1".format(mpstat_arg), timeout=15)
    if rcj == 0 and outj:
        parsed = _parse_mpstat_json(outj, cpus_spec)
        if parsed:
            parsed["source"] = "mpstat-json"
            return parsed

    parsed = _parse_mpstat_text(out, cpus_spec)
    if parsed:
        parsed["source"] = "mpstat-text"
    return parsed


def _is_block_device(name):
    if re.match(r"^(loop|ram|dm-|md)\d", name):
        return False
    return name.startswith(("sd", "nvme", "vd", "xvd"))


def _aggregate_iostat_disks(disks):
    """聚合块设备 iostat 指标。"""
    block = [d for d in disks if _is_block_device(d.get("disk_device", ""))]
    if not block:
        return None

    def _f(disk, key, default=0.0):
        return float(disk.get(key, default) or default)

    total_r_s = sum(_f(d, "r/s") for d in block)
    total_w_s = sum(_f(d, "w/s") for d in block)
    rkB_s = sum(_f(d, "rkB/s") for d in block)
    wkB_s = sum(_f(d, "wkB/s") for d in block)
    util_pct = max(_f(d, "util") for d in block)

    r_await = 0.0
    if total_r_s > 0:
        r_await = sum(_f(d, "r_await") * _f(d, "r/s") for d in block) / total_r_s
    w_await = 0.0
    if total_w_s > 0:
        w_await = sum(_f(d, "w_await") * _f(d, "w/s") for d in block) / total_w_s

    avgqu_sz = sum(_f(d, "aqu-sz") for d in block)

    return {
        "r_s": round(total_r_s, 2),
        "w_s": round(total_w_s, 2),
        "rkB_s": round(rkB_s, 2),
        "wkB_s": round(wkB_s, 2),
        "util_pct": round(util_pct, 2),
        "r_await_ms": round(r_await, 2),
        "w_await_ms": round(w_await, 2),
        "avgqu_sz": round(avgqu_sz, 2),
        "device_count": len(block),
    }


def _parse_iostat_json(output):
    try:
        data = json.loads(output)
        stats = data["sysstat"]["hosts"][0]["statistics"][-1]
        disks = stats.get("disk", [])
        return _aggregate_iostat_disks(disks)
    except (ValueError, KeyError, IndexError, TypeError):
        return None


def _parse_iostat_text(output):
    disks = []
    header = None
    for line in output.splitlines():
        line = line.strip()
        if not line or line.startswith("Linux"):
            continue
        if line.startswith("Device") and "rkB/s" in line:
            header = line.split()
            continue
        if not header:
            continue
        parts = line.split()
        if len(parts) < len(header):
            continue
        name = parts[0]
        if not _is_block_device(name):
            continue
        row = {"disk_device": name}
        for i, col in enumerate(header[1:], 1):
            if i >= len(parts):
                break
            try:
                row[col] = float(parts[i])
            except ValueError:
                pass
        disks.append(row)
    return _aggregate_iostat_disks(disks)


def _sample_iostat():
    """运行 iostat -x，返回聚合块设备 IO 指标。"""
    rcj, outj, _ = _run("iostat -x -y -o JSON 1 1", timeout=15)
    if rcj == 0 and outj:
        parsed = _parse_iostat_json(outj)
        if parsed:
            parsed["source"] = "iostat-json"
            return parsed

    rc, out, _ = _run("iostat -x -y 1 1", timeout=15)
    if rc != 0 or not out:
        return None
    parsed = _parse_iostat_text(out)
    if parsed:
        parsed["source"] = "iostat-text"
    return parsed


# ============================================================
# /proc 读取
# ============================================================
def _read_proc_stat():
    cpus = {}
    ctxt = 0
    with open("/proc/stat") as f:
        for line in f:
            if line.startswith("cpu "):
                parts = [int(x) for x in line.split()[1:]]
                idle = parts[3] + (parts[4] if len(parts) > 4 else 0)
                cpus["total"] = {"busy": sum(parts) - idle, "total": sum(parts)}
            elif line.startswith("cpu"):
                idx = int(line.split()[0][3:])
                parts = [int(x) for x in line.split()[1:]]
                idle = parts[3] + (parts[4] if len(parts) > 4 else 0)
                cpus[idx] = {"busy": sum(parts) - idle, "total": sum(parts)}
            elif line.startswith("ctxt "):
                ctxt = int(line.split()[1])
    return cpus, ctxt


def _cpu_usage_pct(prev, curr, key):
    if key not in prev or key not in curr:
        return None
    dt_total = curr[key]["total"] - prev[key]["total"]
    dt_busy = curr[key]["busy"] - prev[key]["busy"]
    if dt_total <= 0:
        return 0.0
    return round(100.0 * dt_busy / dt_total, 1)


def _read_meminfo():
    info = {}
    with open("/proc/meminfo") as f:
        for line in f:
            parts = line.split()
            if len(parts) >= 2:
                info[parts[0].rstrip(":")] = int(parts[1])
    avail = info.get("MemAvailable", info.get("MemFree", 0))
    return {
        "mem_total_mb": round(info.get("MemTotal", 0) / 1024.0, 1),
        "mem_available_mb": round(avail / 1024.0, 1),
        "mem_used_mb": round((info.get("MemTotal", 0) - avail) / 1024.0, 1),
        "swap_used_mb": round(
            (info.get("SwapTotal", 0) - info.get("SwapFree", 0)) / 1024.0, 1
        ),
        "cached_mb": round(info.get("Cached", 0) / 1024.0, 1),
        "slab_mb": round(info.get("Slab", 0) / 1024.0, 1),
    }


def _read_loadavg():
    parts = _read_text("/proc/loadavg", "0 0 0").split()
    if len(parts) >= 3:
        return {
            "load_1m": float(parts[0]),
            "load_5m": float(parts[1]),
            "load_15m": float(parts[2]),
        }
    return {"load_1m": 0.0, "load_5m": 0.0, "load_15m": 0.0}


def _read_diskstats():
    """返回各磁盘的 cumulative sectors 和 io ticks。"""
    disks = {}
    with open("/proc/diskstats") as f:
        for line in f:
            parts = line.split()
            if len(parts) < 14:
                continue
            name = parts[2]
            if re.match(r"^(loop|ram|dm-|md)\d", name):
                continue
            if parts[0] == "259" or name.startswith(("sd", "nvme", "vd", "xvd")):
                disks[name] = {
                    "read_sectors": int(parts[5]),
                    "write_sectors": int(parts[9]),
                    "io_ms": int(parts[12]),
                }
    return disks


def _disk_rates(prev, curr, interval):
    read_sectors = 0
    write_sectors = 0
    io_ms = 0
    per_disk = {}
    for name, c in curr.items():
        if name not in prev:
            continue
        dr = c["read_sectors"] - prev[name]["read_sectors"]
        dw = c["write_sectors"] - prev[name]["write_sectors"]
        dms = c["io_ms"] - prev[name]["io_ms"]
        read_sectors += dr
        write_sectors += dw
        io_ms += dms
        per_disk[name] = {
            "read_kb_s": round(dr * 512.0 / 1024.0 / interval, 1),
            "write_kb_s": round(dw * 512.0 / 1024.0 / interval, 1),
            "util_pct": round(100.0 * dms / (interval * 1000.0), 1),
        }
    return {
        "io_read_kb_s": round(read_sectors * 512.0 / 1024.0 / interval, 1),
        "io_write_kb_s": round(write_sectors * 512.0 / 1024.0 / interval, 1),
        "io_util_pct": round(100.0 * io_ms / (interval * 1000.0), 1),
        "disks": per_disk,
    }


def _read_numa_system():
    """解析 numastat -m 系统级各 NUMA 节点内存。"""
    rc, out, _ = _run("numastat -m 2>/dev/null")
    if rc != 0 or not out:
        return {}
    nodes = {}
    in_table = False
    for line in out.splitlines():
        if line.strip().startswith("Node ") and "Total" in line:
            in_table = True
            continue
        if not in_table:
            continue
        parts = line.split()
        if len(parts) < 4:
            continue
        metric = parts[0]
        if metric not in ("MemTotal", "MemFree", "MemUsed", "Active", "Inactive"):
            continue
        for i, val in enumerate(parts[1:-1]):
            node_key = str(i)
            nodes.setdefault(node_key, {})
            try:
                nodes[node_key][metric.lower() + "_mb"] = round(float(val), 1)
            except ValueError:
                pass
    return nodes


def _read_numa_process(pid):
    """解析 numastat -p PID 进程在各 NUMA 节点的 Private 内存。"""
    if not pid:
        return {}
    rc, out, _ = _run("numastat -p {} 2>/dev/null".format(pid))
    if rc != 0 or not out:
        return {}
    nodes = {}
    in_table = False
    for line in out.splitlines():
        if "Node" in line and "Total" in line:
            in_table = True
            continue
        if not in_table:
            continue
        parts = line.split()
        if not parts:
            continue
        metric = parts[0]
        if metric != "Private":
            continue
        for i, val in enumerate(parts[1:-1]):
            try:
                nodes[str(i)] = round(float(val), 2)
            except ValueError:
                pass
        break
    return nodes


def _read_blkio_k8s():
    path = "/sys/fs/cgroup/blkio/k8s.io/blkio.io_service_bytes_recursive"
    totals = {"Read": 0, "Write": 0}
    text = _read_text(path)
    if not text:
        return totals
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[1] in totals:
            try:
                totals[parts[1]] += int(parts[2])
            except ValueError:
                pass
    return totals


def _read_cpuacct_stat():
    path = "/sys/fs/cgroup/cpu,cpuacct/k8s.io/cpuacct.stat"
    stats = {"user": 0, "system": 0}
    text = _read_text(path)
    for line in text.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0] in stats:
            stats[parts[0]] = int(parts[1])
    return stats


def _read_cgroup_k8s():
    paths = {
        "memory_usage_bytes": "/sys/fs/cgroup/memory/k8s.io/memory.usage_in_bytes",
        "memory_rss_bytes": "/sys/fs/cgroup/memory/k8s.io/memory.stat",
        "cpu_usage_ns": "/sys/fs/cgroup/cpu,cpuacct/k8s.io/cpuacct.usage",
        "memory_failcnt": "/sys/fs/cgroup/memory/k8s.io/memory.failcnt",
        "pids_current": "/sys/fs/cgroup/pids/k8s.io/pids.current",
    }
    mem_bytes = _read_int(paths["memory_usage_bytes"])
    cpu_ns = _read_int(paths["cpu_usage_ns"])
    failcnt = _read_int(paths["memory_failcnt"])
    pids = _read_int(paths["pids_current"])

    mem_stats = {}
    stat_text = _read_text(paths["memory_rss_bytes"])
    for line in stat_text.splitlines():
        parts = line.split()
        if len(parts) == 2:
            mem_stats[parts[0]] = int(parts[1])

    rss_bytes = mem_stats.get("total_rss", mem_stats.get("rss", 0))
    cache_bytes = mem_stats.get("total_cache", mem_stats.get("cache", 0))
    anon_bytes = mem_stats.get("total_active_anon", 0) + mem_stats.get(
        "total_inactive_anon", 0
    )

    return {
        "k8s_io_mem_mb": round(mem_bytes / (1024.0 * 1024.0), 1),
        "k8s_io_rss_mb": round(rss_bytes / (1024.0 * 1024.0), 1),
        "k8s_io_cache_mb": round(cache_bytes / (1024.0 * 1024.0), 1),
        "k8s_io_anon_mb": round(anon_bytes / (1024.0 * 1024.0), 1),
        "k8s_io_cpu_ns": cpu_ns,
        "k8s_io_memory_failcnt": failcnt,
        "k8s_io_pids": pids,
        "k8s_io_cpu_user": _read_cpuacct_stat()["user"],
        "k8s_io_cpu_system": _read_cpuacct_stat()["system"],
        "k8s_io_blkio_read_bytes": _read_blkio_k8s()["Read"],
        "k8s_io_blkio_write_bytes": _read_blkio_k8s()["Write"],
    }


def _sandbox_count():
    rc, out, _ = _run("crictl pods -q 2>/dev/null")
    if rc != 0:
        return 0
    lines = [l for l in out.splitlines() if l.strip()]
    return len(lines)


# ============================================================
# metadata
# ============================================================
def cmd_metadata(args):
    data = {
        "timestamp": _now_iso(),
        "benchmark": {
            "cpus": args.cpus,
            "numa": args.numa,
            "proc_count": args.proc_count,
            "passthru_args": args.passthru_args,
            "worker_cpus": getattr(args, "worker_cpus", args.cpus),
            "sandbox_cpus": getattr(args, "sandbox_cpus", ""),
            "containerd_cpus": _find_containerd_cpus(),
        },
        "host": {
            "hostname": platform.node(),
            "kernel": platform.release(),
            "arch": platform.machine(),
            "os": platform.platform(),
        },
        "runtime": {},
        "resources_baseline": {},
        "sysctl": {},
    }

    for name, cmd in [
        ("containerd", "containerd --version 2>/dev/null | head -1"),
        ("crictl", "crictl --version 2>/dev/null | head -1"),
        ("runc", "runc --version 2>/dev/null | head -1"),
        ("numactl", "numactl --version 2>/dev/null | head -1"),
        ("mpstat", "mpstat -V 2>/dev/null | head -1"),
        ("iostat", "iostat -V 2>/dev/null | head -1"),
    ]:
        rc, out, _ = _run(cmd)
        if rc == 0 and out:
            data["runtime"][name] = out

    rc, out, _ = _run("lscpu 2>/dev/null")
    if rc == 0:
        data["host"]["lscpu"] = out

    rc, out, _ = _run("numactl -H 2>/dev/null")
    if rc == 0:
        data["host"]["numa_topology"] = out

    data["resources_baseline"].update(_read_meminfo())
    data["resources_baseline"].update(_read_loadavg())
    data["resources_baseline"]["sandbox_count"] = _sandbox_count()
    data["resources_baseline"]["cgroup_k8s_io"] = {
        k: v for k, v in _read_cgroup_k8s().items() if not k.endswith("_ns")
    }
    data["resources_baseline"]["numa_system"] = _read_numa_system()

    pid = _find_containerd_pid()
    data["runtime"]["containerd_pid"] = pid
    data["resources_baseline"]["containerd"] = _proc_metrics(pid)
    data["resources_baseline"]["numa_containerd"] = _read_numa_process(pid)

    rc, out, _ = _run("df -B1 / 2>/dev/null | tail -1")
    if rc == 0:
        parts = out.split()
        if len(parts) >= 4:
            data["resources_baseline"]["root_fs"] = {
                "total_bytes": int(parts[1]),
                "used_bytes": int(parts[2]),
                "avail_bytes": int(parts[3]),
            }

    for key in (
        "fs.inotify.max_user_instances",
        "fs.inotify.max_user_watches",
        "vm.max_map_count",
    ):
        rc, out, _ = _run("sysctl -n {} 2>/dev/null".format(key))
        if rc == 0:
            data["sysctl"][key] = out

    out_dir = os.path.dirname(os.path.abspath(args.output))
    if out_dir and not os.path.isdir(out_dir):
        os.makedirs(out_dir)

    with open(args.output, "w") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print("[resources] metadata → {}".format(args.output))
    return 0


# ============================================================
# capture
# ============================================================
def cmd_capture(args):
    out_dir = args.output_dir
    os.makedirs(out_dir, exist_ok=True)
    ts_path = os.path.join(out_dir, "timeseries.jsonl")
    containerd_pid = _find_containerd_pid()
    bind_numa = getattr(args, "numa", None)

    worker_cpus = getattr(args, "worker_cpus", None) or args.cpus
    sandbox_cpus = getattr(args, "sandbox_cpus", "") or ""
    containerd_cpus = _find_containerd_cpus()

    if not containerd_cpus:
        print("[resources] ⚠ 未解析 containerd CPU 绑定，跳过 containerd mpstat", file=sys.stderr)
    if not sandbox_cpus:
        print("[resources] ⚠ 未指定 sandbox CPUs (--sandbox-cpus)，跳过 sandbox mpstat", file=sys.stderr)
    if not worker_cpus:
        print("[resources] ⚠ 未指定 worker CPUs，跳过 worker mpstat", file=sys.stderr)

    start = time.time()
    seq = 0

    prev_ctxt = _read_proc_stat()[1]
    prev_cgroup = _read_cgroup_k8s()

    with open(ts_path, "w") as out_f:
        while True:
            loop_start = time.time()
            if loop_start - start >= args.duration:
                break

            _, curr_ctxt = _read_proc_stat()
            curr_cgroup = _read_cgroup_k8s()
            elapsed = round(loop_start - start, 1)

            sample = {
                "seq": seq,
                "ts": _now_iso(),
                "elapsed_s": elapsed,
            }
            sample.update(_read_meminfo())
            sample.update(_read_loadavg())

            cpu_mpstat = {}
            if containerd_cpus:
                ctr_mp = _sample_mpstat(containerd_cpus)
                if ctr_mp:
                    cpu_mpstat["containerd"] = ctr_mp
            if sandbox_cpus:
                sb_mp = _sample_mpstat(sandbox_cpus)
                if sb_mp:
                    cpu_mpstat["sandbox"] = sb_mp
            if worker_cpus:
                wk_mp = _sample_mpstat(worker_cpus)
                if wk_mp:
                    cpu_mpstat["worker"] = wk_mp
            if cpu_mpstat:
                sample["cpu_mpstat"] = cpu_mpstat

            io_iostat = _sample_iostat()
            if io_iostat:
                sample["io_iostat"] = io_iostat

            dt_ctxt = curr_ctxt - prev_ctxt
            sample["context_switches_per_s"] = round(dt_ctxt / args.interval, 1)

            sample["sandbox_count"] = _sandbox_count()
            sample["containerd"] = _proc_metrics(containerd_pid)

            sample["k8s_io_mem_mb"] = curr_cgroup["k8s_io_mem_mb"]
            sample["k8s_io_rss_mb"] = curr_cgroup["k8s_io_rss_mb"]
            sample["k8s_io_cache_mb"] = curr_cgroup["k8s_io_cache_mb"]
            sample["k8s_io_anon_mb"] = curr_cgroup["k8s_io_anon_mb"]
            sample["k8s_io_pids"] = curr_cgroup["k8s_io_pids"]
            sample["k8s_io_memory_failcnt"] = curr_cgroup["k8s_io_memory_failcnt"]

            dt_cpu_ns = curr_cgroup["k8s_io_cpu_ns"] - prev_cgroup["k8s_io_cpu_ns"]
            sample["k8s_io_cpu_pct"] = round(
                100.0 * dt_cpu_ns / (args.interval * 1e9 * os.cpu_count()), 1
            ) if os.cpu_count() else 0.0

            dt_user = curr_cgroup["k8s_io_cpu_user"] - prev_cgroup["k8s_io_cpu_user"]
            dt_sys = curr_cgroup["k8s_io_cpu_system"] - prev_cgroup["k8s_io_cpu_system"]
            hz = os.sysconf(getattr(os, "SC_CLK_TCK", 100))
            sample["k8s_io_cpu_user_pct"] = round(
                100.0 * dt_user / (args.interval * hz * os.cpu_count()), 1
            ) if os.cpu_count() else 0.0
            sample["k8s_io_cpu_system_pct"] = round(
                100.0 * dt_sys / (args.interval * hz * os.cpu_count()), 1
            ) if os.cpu_count() else 0.0

            dt_blk_r = (
                curr_cgroup["k8s_io_blkio_read_bytes"]
                - prev_cgroup["k8s_io_blkio_read_bytes"]
            )
            dt_blk_w = (
                curr_cgroup["k8s_io_blkio_write_bytes"]
                - prev_cgroup["k8s_io_blkio_write_bytes"]
            )
            sample["k8s_io_blkio_read_kb_s"] = round(
                dt_blk_r / 1024.0 / args.interval, 1
            )
            sample["k8s_io_blkio_write_kb_s"] = round(
                dt_blk_w / 1024.0 / args.interval, 1
            )

            numa_sys = _read_numa_system()
            numa_ctr = _read_numa_process(containerd_pid)
            sample["numa"] = {
                "bind_node": bind_numa,
                "system": numa_sys,
                "containerd_private_mb": numa_ctr,
            }
            if bind_numa is not None:
                node_key = str(bind_numa)
                bind_node = numa_sys.get(node_key, {})
                sample["numa_bind_mem_free_mb"] = bind_node.get("memfree_mb", 0)
                sample["numa_bind_mem_used_mb"] = bind_node.get("memused_mb", 0)
                sample["numa_bind_containerd_mb"] = numa_ctr.get(node_key, 0)

            out_f.write(json.dumps(sample, ensure_ascii=False))
            out_f.write("\n")
            out_f.flush()

            prev_ctxt = curr_ctxt
            prev_cgroup = curr_cgroup
            seq += 1

            spent = time.time() - loop_start
            remaining = args.interval - spent
            if remaining > 0 and (time.time() + remaining - start) < args.duration:
                time.sleep(remaining)

    print("[resources] capture 完成: {} 样本 → {}".format(seq, ts_path))
    return 0


# ============================================================
# summarize
# ============================================================
def _load_timeseries(path):
    rows = []
    if not os.path.isfile(path):
        return rows
    with open(path) as f:
        for line in f:
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def cmd_summarize(args):
    out_dir = args.output_dir
    ts_path = os.path.join(out_dir, "timeseries.jsonl")
    rows = _load_timeseries(ts_path)

    if not rows:
        print("[resources] ⚠ 无时序数据: {}".format(ts_path), file=sys.stderr)
        summary = {"samples": 0, "metrics": {}}
    else:
        metrics = {}
        scalar_keys = [
            "mem_available_mb", "mem_used_mb",
            "load_1m", "sandbox_count",
            "context_switches_per_s",
            "k8s_io_mem_mb", "k8s_io_rss_mb", "k8s_io_cache_mb", "k8s_io_anon_mb",
            "k8s_io_cpu_pct", "k8s_io_cpu_user_pct", "k8s_io_cpu_system_pct",
            "k8s_io_pids", "k8s_io_memory_failcnt",
            "k8s_io_blkio_read_kb_s", "k8s_io_blkio_write_kb_s",
            "numa_bind_mem_free_mb", "numa_bind_mem_used_mb",
            "numa_bind_containerd_mb",
        ]
        iostat_keys = [
            "io_iostat.rkB_s", "io_iostat.wkB_s", "io_iostat.util_pct",
            "io_iostat.r_await_ms", "io_iostat.w_await_ms", "io_iostat.avgqu_sz",
        ]
        for key in scalar_keys:
            vals = [r[key] for r in rows if key in r and r[key] is not None]
            if vals:
                metrics[key] = _stats(vals)

        for dotted in iostat_keys:
            src, field = dotted.split(".", 1)
            vals = [
                r[src][field] for r in rows
                if src in r and isinstance(r[src], dict) and field in r[src]
            ]
            if vals:
                metrics[dotted] = _stats(vals)

        mpstat_groups = ("containerd", "sandbox", "worker")
        mpstat_metrics = {}
        for group in mpstat_groups:
            gm = {}
            for field in MPSTAT_FIELDS:
                vals = [
                    r["cpu_mpstat"][group][field]
                    for r in rows
                    if group in r.get("cpu_mpstat", {})
                    and field in r["cpu_mpstat"][group]
                ]
                if vals:
                    gm[field] = _stats(vals)
            if gm:
                mpstat_metrics[group] = gm
        if mpstat_metrics:
            metrics["cpu_mpstat"] = mpstat_metrics

        # containerd RSS
        ctr_rss = [
            r["containerd"]["rss_mb"] for r in rows
            if r.get("containerd") and r["containerd"].get("rss_mb") is not None
        ]
        if ctr_rss:
            metrics["containerd_rss_mb"] = _stats(ctr_rss)

        # worker CPU keys union (legacy, 仅旧数据)
        worker_keys = set()
        for r in rows:
            worker_keys.update(r.get("cpu_workers", {}).keys())
        worker_metrics = {}
        for wk in sorted(worker_keys, key=lambda x: int(x)):
            vals = [
                r["cpu_workers"][wk] for r in rows
                if wk in r.get("cpu_workers", {})
            ]
            if vals:
                worker_metrics[wk] = _stats(vals)
        if worker_metrics:
            metrics["cpu_workers"] = worker_metrics

        # 各磁盘 I/O 汇总 (legacy)
        disk_names = set()
        for r in rows:
            disk_names.update(r.get("disks", {}).keys())
        disk_metrics = {}
        for dk in sorted(disk_names):
            dm = {}
            for field in ("read_kb_s", "write_kb_s", "util_pct"):
                vals = [
                    r["disks"][dk][field] for r in rows
                    if dk in r.get("disks", {}) and field in r["disks"][dk]
                ]
                if vals:
                    dm[field] = _stats(vals)
            if dm:
                disk_metrics[dk] = dm
        if disk_metrics:
            metrics["disks"] = disk_metrics

        # 峰值时刻
        peaks = {}
        for key in ("sandbox_count", "mem_used_mb"):
            vals = [(r.get(key), r.get("elapsed_s"), r.get("ts")) for r in rows]
            vals = [(v, e, t) for v, e, t in vals if v is not None]
            if vals:
                peak = max(vals, key=lambda x: x[0])
                peaks[key] = {"value": peak[0], "elapsed_s": peak[1], "ts": peak[2]}

        # 瓶颈标记（跳过前 2 个样本，避免 drop_caches 干扰）
        steady_rows = rows[2:] if len(rows) > 2 else rows
        steady_metrics = {}
        for key in ("mem_available_mb",):
            vals = [r[key] for r in steady_rows if key in r and r[key] is not None]
            if vals:
                steady_metrics[key] = _stats(vals)
        io_util_vals = [
            r["io_iostat"]["util_pct"] for r in steady_rows
            if "io_iostat" in r and "util_pct" in r["io_iostat"]
        ]
        if io_util_vals:
            steady_metrics["io_iostat.util_pct"] = _stats(io_util_vals)

        flags = []
        for group in ("containerd", "sandbox", "worker"):
            usr_p95 = (
                metrics.get("cpu_mpstat", {})
                .get(group, {})
                .get("usr", {})
                .get("p95")
            )
            sys_p95 = (
                metrics.get("cpu_mpstat", {})
                .get(group, {})
                .get("sys", {})
                .get("p95")
            )
            if usr_p95 and sys_p95 and (usr_p95 + sys_p95) >= 90:
                flags.append("{}_cpu_saturation".format(group))
        if steady_metrics.get("mem_available_mb", {}).get("min", 1e18) < 512:
            flags.append("low_memory")
        if steady_metrics.get("io_iostat.util_pct", {}).get("p95", 0) >= 80:
            flags.append("disk_saturation")
        oom_failcnt = max(
            (r.get("k8s_io_memory_failcnt", 0) for r in rows), default=0
        )
        if oom_failcnt > 0:
            flags.append("memory_limit_pressure")

        summary = {
            "samples": len(rows),
            "duration_s": rows[-1].get("elapsed_s", 0) if rows else 0,
            "metrics": metrics,
            "peaks": peaks,
            "flags": flags,
        }

    summary_path = os.path.join(out_dir, "summary.json")
    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2, ensure_ascii=False)
        f.write("\n")

    print("[resources] summary → {}".format(summary_path))
    if summary.get("flags"):
        print("[resources] 瓶颈标记: {}".format(", ".join(summary["flags"])))

    # 打印摘要表
    m = summary.get("metrics", {})
    if m:
        print("")
        print("--- 资源摘要 ---")
        print("{:<24} {:>8} {:>8} {:>8} {:>8}".format(
            "METRIC", "P50", "P95", "MAX", "MEAN"))
        for key in (
            "mem_available_mb", "mem_used_mb",
            "sandbox_count", "containerd_rss_mb",
            "k8s_io_mem_mb", "k8s_io_cpu_pct", "k8s_io_pids",
            "numa_bind_mem_free_mb",
        ):
            if key not in m:
                continue
            s = m[key]
            print("{:<24} {:>8.1f} {:>8.1f} {:>8.1f} {:>8.1f}".format(
                key, s["p50"], s["p95"], s["max"], s["mean"]))

    return 0


# ============================================================
# main
# ============================================================
def main():
    parser = argparse.ArgumentParser(description="系统资源采样器")
    sub = parser.add_subparsers(dest="command")

    p_meta = sub.add_parser("metadata", help="写入静态环境快照")
    p_meta.add_argument("--output", required=True)
    p_meta.add_argument("--cpus", default="")
    p_meta.add_argument("--numa", type=int, default=0)
    p_meta.add_argument("--proc-count", type=int, default=1)
    p_meta.add_argument("--passthru-args", default="")

    p_cap = sub.add_parser("capture", help="采样时序数据")
    p_cap.add_argument("--output-dir", required=True)
    p_cap.add_argument("--duration", type=int, default=30)
    p_cap.add_argument("--interval", type=float, default=0.1)
    p_cap.add_argument("--cpus", default="",
                       help="Worker CPU 列表 (兼容旧参数，同 --worker-cpus)")
    p_cap.add_argument("--worker-cpus", default="",
                       help="Worker 绑定 CPU 列表")
    p_cap.add_argument("--sandbox-cpus", default="",
                       help="Sandbox cpuset CPU 列表 (--cpuset-cpus)")
    p_cap.add_argument("--numa", type=int, default=None)

    p_sum = sub.add_parser("summarize", help="生成汇总报告")
    p_sum.add_argument("--output-dir", required=True)

    args = parser.parse_args()
    if args.command == "metadata":
        return cmd_metadata(args)
    if args.command == "capture":
        if not getattr(args, "worker_cpus", ""):
            args.worker_cpus = args.cpus
        return cmd_capture(args)
    if args.command == "summarize":
        return cmd_summarize(args)

    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
