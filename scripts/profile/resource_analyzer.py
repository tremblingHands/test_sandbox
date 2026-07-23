#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
资源时序与 benchmark 结果关联分析（兼容 Python 3.6+）

读取 results/multi/ 下的 proc*.json 与 resources/timeseries.jsonl，
分析延迟与系统资源的关联，输出 report.md、charts/*.svg、analysis.json。

用法:
    python3 resource_analyzer.py results/multi
    python3 resource_analyzer.py results/multi --output-dir results/multi/resources
"""

import argparse
import glob
import json
import math
import os
import re
import statistics
import sys
from collections import defaultdict, OrderedDict


def _load_json(path):
    with open(path) as f:
        return json.load(f)


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


def _load_proc_reports(result_dir):
    pattern = os.path.join(result_dir, "proc*_cpu*_node*.json")
    reports = []
    for path in sorted(glob.glob(pattern)):
        try:
            data = _load_json(path)
            data["_path"] = path
            data["_label"] = os.path.splitext(os.path.basename(path))[0]
            reports.append(data)
        except (IOError, ValueError, KeyError):
            pass
    return reports


def _percentile(values, pct):
    if not values:
        return 0.0
    s = sorted(values)
    n = len(s)
    idx = max(0, min(n - 1, int(math.ceil(n * pct / 100.0)) - 1))
    return float(s[idx])


def build_latency_timeline(reports):
    bins = defaultdict(list)
    has_elapsed = False
    estimated = False

    for rep in reports:
        cumulative_ms = 0.0
        for r in rep.get("results", []):
            if r.get("sandbox_id") == "FAIL":
                continue
            total = r.get("total_ms", 0)
            elapsed_ms = r.get("elapsed_ms")
            if elapsed_ms is not None:
                has_elapsed = True
                sec = int(float(elapsed_ms) / 1000.0)
            else:
                estimated = True
                sec = int(cumulative_ms / 1000.0)
                cumulative_ms += total
            bins[sec].append(total)

    timeline = []
    for sec in sorted(bins.keys()):
        vals = bins[sec]
        timeline.append({
            "elapsed_s": sec,
            "count": len(vals),
            "p50_ms": round(_percentile(vals, 50), 1),
            "p95_ms": round(_percentile(vals, 95), 1),
            "p99_ms": round(_percentile(vals, 99), 1),
            "mean_ms": round(statistics.mean(vals), 1),
            "max_ms": round(max(vals), 1),
        })

    return timeline, has_elapsed, estimated


def align_series(timeseries, latency_timeline):
    lat_by_sec = {t["elapsed_s"]: t for t in latency_timeline}
    aligned = []
    for row in timeseries:
        sec = int(row.get("elapsed_s", 0))
        lat = lat_by_sec.get(sec, {})
        entry = {
            "elapsed_s": sec,
            "mem_used_mb": row.get("mem_used_mb"),
            "sandbox_count": row.get("sandbox_count"),
            "k8s_io_cpu_pct": row.get("k8s_io_cpu_pct"),
            "k8s_io_mem_mb": row.get("k8s_io_mem_mb"),
            "latency_p95_ms": lat.get("p95_ms"),
            "latency_count": lat.get("count", 0),
            "latency_mean_ms": lat.get("mean_ms"),
        }
        io = row.get("io_iostat", {})
        if io:
            entry["io_iostat_util_pct"] = io.get("util_pct")
        cmp = row.get("cpu_mpstat", {})
        for group in ("containerd", "sandbox", "worker"):
            if group in cmp:
                entry["cpu_mpstat_{}_usr".format(group)] = cmp[group].get("usr")
                entry["cpu_mpstat_{}_sys".format(group)] = cmp[group].get("sys")
        aligned.append(entry)
    return aligned


def _pearson(xs, ys):
    pairs = [(x, y) for x, y in zip(xs, ys) if x is not None and y is not None]
    n = len(pairs)
    if n < 3:
        return None
    xs = [p[0] for p in pairs]
    ys = [p[1] for p in pairs]
    mx = statistics.mean(xs)
    my = statistics.mean(ys)
    num = sum((x - mx) * (y - my) for x, y in zip(xs, ys))
    den_x = math.sqrt(sum((x - mx) ** 2 for x in xs))
    den_y = math.sqrt(sum((y - my) ** 2 for y in ys))
    if den_x == 0 or den_y == 0:
        return None
    return round(num / (den_x * den_y), 3)


def compute_correlations(aligned):
    lat_p95 = [r["latency_p95_ms"] for r in aligned]
    metrics = [
        "sandbox_count", "mem_used_mb",
        "k8s_io_cpu_pct", "k8s_io_mem_mb", "io_iostat_util_pct",
        "cpu_mpstat_containerd_usr", "cpu_mpstat_sandbox_usr",
        "cpu_mpstat_worker_usr",
    ]
    correlations = {}
    for m in metrics:
        vals = [r.get(m) for r in aligned]
        if any(v is not None for v in vals) and any(v is not None for v in lat_p95):
            r = _pearson(
                [v if v is not None else 0 for v in vals],
                [v if v is not None else 0 for v in lat_p95],
            )
            if r is not None:
                correlations[m] = r
    return correlations


def find_spike_events(aligned, latency_timeline):
    if not latency_timeline:
        return []

    all_p95 = [t["p95_ms"] for t in latency_timeline if t["count"] > 0]
    if not all_p95:
        return []
    baseline_p95 = _percentile(all_p95, 50)
    threshold = max(baseline_p95 * 1.25, baseline_p95 + 50)

    lat_by_sec = {t["elapsed_s"]: t for t in latency_timeline}
    events = []
    for row in aligned:
        sec = row["elapsed_s"]
        lat = lat_by_sec.get(sec)
        if not lat or lat["count"] == 0:
            continue
        if lat["p95_ms"] < threshold:
            continue

        triggers = []
        if (row.get("cpu_mpstat_containerd_usr") or 0) + (row.get("cpu_mpstat_containerd_sys") or 0) >= 70:
            triggers.append("high_containerd_cpu")
        if (row.get("cpu_mpstat_sandbox_usr") or 0) + (row.get("cpu_mpstat_sandbox_sys") or 0) >= 70:
            triggers.append("high_sandbox_cpu")
        if (row.get("io_iostat_util_pct") or 0) >= 50:
            triggers.append("high_disk_io")
        if (row.get("k8s_io_cpu_pct") or 0) >= 30:
            triggers.append("high_k8s_io_cpu")
        if row.get("sandbox_count") is not None:
            triggers.append("sandboxes_active")

        events.append({
            "elapsed_s": sec,
            "latency_p95_ms": lat["p95_ms"],
            "latency_count": lat["count"],
            "cpu_total_pct": row.get("cpu_total_pct"),
            "sandbox_count": row.get("sandbox_count"),
            "io_iostat_util_pct": row.get("io_iostat_util_pct"),
            "k8s_io_cpu_pct": row.get("k8s_io_cpu_pct"),
            "likely_triggers": triggers or ["unknown"],
        })
    return events


def summarize_benchmark(reports):
    all_totals = []
    workers = []
    for rep in reports:
        totals = [
            r["total_ms"] for r in rep.get("results", [])
            if r.get("sandbox_id") != "FAIL"
        ]
        all_totals.extend(totals)
        phases = rep.get("phases", {}).get("total", {})
        workers.append({
            "label": rep["_label"],
            "sandboxes": rep.get("summary", {}).get("total_sandboxes", 0),
            "success": rep.get("summary", {}).get("success", 0),
            "p50_ms": phases.get("p50"),
            "p95_ms": phases.get("p95"),
            "p99_ms": phases.get("p99"),
            "mean_ms": phases.get("mean"),
        })

    overall = {}
    if all_totals:
        overall = {
            "total_sandboxes": len(all_totals),
            "p50_ms": round(_percentile(all_totals, 50), 1),
            "p95_ms": round(_percentile(all_totals, 95), 1),
            "p99_ms": round(_percentile(all_totals, 99), 1),
            "mean_ms": round(statistics.mean(all_totals), 1),
        }
    return {"workers": workers, "overall": overall}


MPSTAT_FIELDS = (
    "usr", "nice", "sys", "iowait", "irq", "soft", "steal", "guest", "gnice", "idle",
)
MPSTAT_COLORS = {
    "usr": "#4e79a7", "nice": "#a0cbe8", "sys": "#f28e2b", "iowait": "#ffbe7d",
    "irq": "#59a14f", "soft": "#8cd17d", "steal": "#b6992d", "guest": "#499894",
    "gnice": "#86bcb6", "idle": "#bab0ac",
}
IOSTAT_FIELDS = (
    "rkB_s", "wkB_s", "r_s", "w_s", "util_pct",
    "r_await_ms", "w_await_ms", "avgqu_sz", "device_count",
)
LEGACY_SKIP_IF_MPSTAT = {"cpu_total_pct"}
LEGACY_SKIP_IF_IOSTAT = {"io_read_kb_s", "io_write_kb_s", "io_util_pct"}


def _safe_chart_name(metric_id):
    name = re.sub(r"[^a-zA-Z0-9._-]+", "_", metric_id)
    return name.strip("_") or "metric"


def _metric_label(metric_id):
    labels = {
        "cpu_total_pct": "全局 CPU 利用率",
        "sandbox_count": "沙箱数量",
        "mem_total_mb": "内存总量",
        "mem_available_mb": "可用内存",
        "mem_used_mb": "已用内存",
        "swap_used_mb": "Swap 使用",
        "cached_mb": "页缓存",
        "slab_mb": "Slab 内存",
        "load_1m": "Load (1m)",
        "load_5m": "Load (5m)",
        "load_15m": "Load (15m)",
        "context_switches_per_s": "上下文切换",
        "io_iostat.rkB_s": "iostat 读吞吐",
        "io_iostat.wkB_s": "iostat 写吞吐",
        "io_iostat.r_s": "iostat 读 IOPS",
        "io_iostat.w_s": "iostat 写 IOPS",
        "io_iostat.util_pct": "iostat 磁盘 util",
        "io_iostat.r_await_ms": "iostat 读 await",
        "io_iostat.w_await_ms": "iostat 写 await",
        "io_iostat.avgqu_sz": "iostat 队列长度",
        "io_iostat.device_count": "iostat 块设备数",
        "k8s_io_mem_mb": "k8s.io cgroup 内存",
        "k8s_io_rss_mb": "k8s.io cgroup RSS",
        "k8s_io_cache_mb": "k8s.io cgroup Cache",
        "k8s_io_anon_mb": "k8s.io cgroup Anon",
        "k8s_io_cpu_pct": "k8s.io cgroup CPU",
        "k8s_io_cpu_user_pct": "k8s.io cgroup CPU (user)",
        "k8s_io_cpu_system_pct": "k8s.io cgroup CPU (system)",
        "k8s_io_pids": "k8s.io cgroup 进程数",
        "k8s_io_memory_failcnt": "k8s.io memory failcnt",
        "k8s_io_blkio_read_kb_s": "k8s.io blkio 读",
        "k8s_io_blkio_write_kb_s": "k8s.io blkio 写",
        "numa_bind_mem_free_mb": "绑定 NUMA 空闲内存",
        "numa_bind_mem_used_mb": "绑定 NUMA 已用内存",
        "numa_bind_containerd_mb": "绑定 NUMA containerd 内存",
        "containerd.rss_mb": "containerd RSS",
        "containerd.threads": "containerd 线程数",
        "containerd.fd_count": "containerd 文件描述符",
        "latency.count": "每秒冷启动次数",
        "latency.p50_ms": "冷启动 P50",
        "latency.p95_ms": "冷启动 P95",
        "latency.p99_ms": "冷启动 P99",
        "latency.mean_ms": "冷启动 Mean",
        "latency.max_ms": "冷启动 Max",
    }
    if metric_id in labels:
        return labels[metric_id]
    if metric_id.startswith("cpu_workers."):
        return "Worker CPU {} %".format(metric_id.split(".", 1)[1])
    if metric_id.startswith("disks."):
        parts = metric_id.split(".")
        if len(parts) == 3:
            return "磁盘 {} {}".format(parts[1], parts[2])
    if metric_id.startswith("numa.system."):
        return "NUMA " + metric_id.replace("numa.system.", "").replace(".", " ")
    if metric_id.startswith("numa.containerd."):
        return "containerd NUMA node " + metric_id.split(".")[-1] + " (MB)"
    return metric_id


def _metric_unit(metric_id):
    if metric_id.startswith("io_iostat."):
        field = metric_id.split(".", 1)[1]
        if field.endswith("_kb_s") or field in ("rkB_s", "wkB_s"):
            return "KB/s"
        if field.endswith("_ms"):
            return "ms"
        if field.endswith("_pct") or field == "util_pct":
            return "%"
        if field in ("r_s", "w_s"):
            return "IOPS"
        if field == "device_count":
            return "count"
        if field == "avgqu_sz":
            return "queue"
    if metric_id.endswith("_mb"):
        return "MB"
    if metric_id.endswith("_kb_s"):
        return "KB/s"
    if metric_id.endswith("_ms"):
        return "ms"
    if metric_id.endswith("_per_s"):
        return "/s"
    if metric_id.startswith("latency."):
        return "ms" if metric_id != "latency.count" else "count"
    if metric_id in ("sandbox_count", "k8s_io_pids", "containerd.threads", "containerd.fd_count",
                     "k8s_io_memory_failcnt", "latency.count"):
        return "count"
    if metric_id.startswith("load_"):
        return "load"
    if metric_id.endswith("_pct") or metric_id.endswith("_util_pct"):
        return "%"
    return ""


def collect_all_metric_series(timeseries, latency_timeline):
    """从时序数据中提取所有可绘制的指标序列（不含 mpstat/iostat 专用图）。"""
    series_map = OrderedDict()
    has_mpstat = any("cpu_mpstat" in r for r in timeseries)
    has_iostat = any("io_iostat" in r for r in timeseries)

    def add_series(metric_id, elapsed_s, value):
        if value is None:
            return
        if isinstance(value, bool):
            return
        if isinstance(value, (int, float)):
            series_map.setdefault(metric_id, []).append((elapsed_s, float(value)))

    skip_keys = {
        "seq", "ts", "elapsed_s", "numa", "disks", "cpu_workers",
        "containerd", "cpu_mpstat", "io_iostat",
    }

    for row in timeseries:
        elapsed_s = float(row.get("elapsed_s", 0))

        for key, val in row.items():
            if key in skip_keys:
                continue
            if has_mpstat and key in LEGACY_SKIP_IF_MPSTAT:
                continue
            if has_iostat and key in LEGACY_SKIP_IF_IOSTAT:
                continue
            if isinstance(val, (int, float)):
                add_series(key, elapsed_s, val)

        if not has_mpstat:
            for cpu_id, pct in row.get("cpu_workers", {}).items():
                add_series("cpu_workers.{}".format(cpu_id), elapsed_s, pct)

        if not has_iostat:
            for disk, metrics in row.get("disks", {}).items():
                for field, val in metrics.items():
                    add_series("disks.{}.{}".format(disk, field), elapsed_s, val)

        ctr = row.get("containerd", {})
        for field in ("rss_mb", "threads", "fd_count"):
            if field in ctr:
                add_series("containerd.{}".format(field), elapsed_s, ctr[field])

        numa = row.get("numa", {})
        for node, node_metrics in numa.get("system", {}).items():
            for mk, mv in node_metrics.items():
                add_series(
                    "numa.system.{}.{}".format(node, mk), elapsed_s, mv
                )
        for node, mb in numa.get("containerd_private_mb", {}).items():
            add_series("numa.containerd.{}".format(node), elapsed_s, mb)

        io = row.get("io_iostat", {})
        for field, val in io.items():
            if field == "source":
                continue
            if isinstance(val, (int, float)):
                add_series("io_iostat.{}".format(field), elapsed_s, val)

    for lat in latency_timeline:
        elapsed_s = float(lat["elapsed_s"])
        for field in ("count", "p50_ms", "p95_ms", "p99_ms", "mean_ms", "max_ms"):
            if field in lat:
                add_series("latency.{}".format(field), elapsed_s, lat[field])

    return OrderedDict(
        (k, v) for k, v in series_map.items() if len(v) >= 2
    )


def _extract_mpstat_series(timeseries, group):
    series = OrderedDict()
    for field in MPSTAT_FIELDS:
        pts = []
        for row in timeseries:
            cmp = row.get("cpu_mpstat", {}).get(group, {})
            if field in cmp:
                pts.append((float(row["elapsed_s"]), float(cmp[field])))
        if len(pts) >= 2:
            series[field] = sorted(pts, key=lambda p: p[0])
    return series


def generate_mpstat_charts(timeseries, charts_dir):
    """生成 mpstat 三类 CPU 多曲线 SVG。"""
    os.makedirs(charts_dir, exist_ok=True)
    generated = []
    group_titles = {
        "containerd": "containerd CPU (mpstat)",
        "sandbox": "sandbox CPU (mpstat)",
        "worker": "worker CPU (mpstat)",
    }

    for group, gtitle in group_titles.items():
        series = _extract_mpstat_series(timeseries, group)
        if not series:
            continue
        cpus = ""
        for row in timeseries:
            g = row.get("cpu_mpstat", {}).get(group, {})
            if g.get("cpus"):
                cpus = g["cpus"]
                break
        defs = []
        for field in MPSTAT_FIELDS:
            if field not in series:
                continue
            defs.append((
                field, "%{}".format(field), MPSTAT_COLORS.get(field, "#333"),
                series[field],
            ))
        path = os.path.join(charts_dir, "cpu_mpstat_{}.svg".format(group))
        subtitle = "CPUs: {} | Y: % (0-100)".format(cpus or "-")
        if generate_multi_series_svg(gtitle, subtitle, defs, path, 0, 100, False):
            generated.append({
                "metric_id": "cpu_mpstat.{}".format(group),
                "label": gtitle,
                "unit": "%",
                "file": "charts/cpu_mpstat_{}.svg".format(group),
                "points": len(next(iter(series.values()))),
            })

    return generated


def generate_multi_series_svg(title, subtitle, series_defs, output_path,
                            y_min=0.0, y_max=100.0, normalize=False):
    """多曲线 SVG。series_defs: [(key, label, color, points), ...]"""
    if not series_defs:
        return False

    all_x = []
    for _, _, _, pts in series_defs:
        all_x.extend(p[0] for p in pts)
    if not all_x:
        return False
    max_x = max(all_x)

    width, height = 960, 420
    margin_l, margin_t, margin_r, margin_b = 72, 56, 24, 72
    plot_w = width - margin_l - margin_r
    plot_h = height - margin_t - margin_b

    def x_pos(t):
        return margin_l + (t / max_x * plot_w if max_x > 0 else 0)

    lines_svg = []
    legend_svg = []
    if normalize:
        y_min, y_max = 0.0, 100.0

    for idx, (key, label, color, points) in enumerate(series_defs):
        ys = [p[1] for p in points]
        if normalize:
            vmin, vmax = min(ys), max(ys)
            span = vmax - vmin if vmax > vmin else 1.0
            yvals = [(y - vmin) / span * 100.0 for y in ys]
            ymin, ymax, yspan = 0.0, 100.0, 100.0
        else:
            yvals = ys
            ymin, ymax = y_min, y_max
            yspan = ymax - ymin if ymax > ymin else 1.0

        pts_str = []
        for i, p in enumerate(points):
            y = margin_t + plot_h - ((yvals[i] - ymin) / yspan * plot_h)
            pts_str.append("{:.1f},{:.1f}".format(x_pos(p[0]), y))

        if pts_str:
            lines_svg.append(
                '<polyline fill="none" stroke="{}" stroke-width="2" '
                'points="{}" />'.format(color, " ".join(pts_str))
            )

        lx = margin_l + (idx % 5) * 180
        ly = height - 52 + (idx // 5) * 18
        legend_svg.append(
            '<line x1="{}" y1="{}" x2="{}" y2="{}" stroke="{}" stroke-width="3"/>'
            '<text x="{}" y="{}" font-size="11" fill="#333">{}</text>'.format(
                lx, ly, lx + 20, ly, color, lx + 26, ly + 4, label,
            )
        )

    y_ticks = []
    for i in range(6):
        val = y_min + (y_max - y_min) * i / 5.0
        y = margin_t + plot_h - (i / 5.0 * plot_h)
        y_ticks.append(
            '<line x1="{ml}" y1="{y:.1f}" x2="{xr:.1f}" y2="{y:.1f}" stroke="#eee"/>'
            '<text x="{mlx}" y="{yt:.1f}" font-size="10" fill="#666" '
            'text-anchor="end">{lab}</text>'.format(
                ml=margin_l, y=y, xr=margin_l + plot_w, mlx=margin_l - 8,
                yt=y + 4, lab=_format_tick(val),
            )
        )

    x_ticks = []
    step = max(1, int(max_x // 10))
    for t in range(0, int(max_x) + 1, step):
        x = x_pos(t)
        x_ticks.append(
            '<line x1="{x:.1f}" y1="{yb}" x2="{x:.1f}" y2="{yt:.1f}" stroke="#eee"/>'
            '<text x="{x:.1f}" y="{yl}" font-size="10" fill="#666" '
            'text-anchor="middle">{t}s</text>'.format(
                x=x, yb=margin_t + plot_h, yt=margin_t,
                yl=margin_t + plot_h + 16, t=t,
            )
        )

    svg = """<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}">
  <rect width="100%" height="100%" fill="#fafafa"/>
  <text x="{ml}" y="26" font-size="15" font-weight="bold" fill="#222">{title}</text>
  <text x="{ml}" y="44" font-size="11" fill="#888">{subtitle}</text>
  <rect x="{ml}" y="{mt}" width="{pw}" height="{ph}" fill="#fff" stroke="#ddd"/>
  {y_ticks}
  {x_ticks}
  {lines}
  <text x="{mx}" y="{h}" font-size="11" fill="#666" text-anchor="middle">elapsed (s)</text>
  {legend}
</svg>""".format(
        w=width, h=height, ml=margin_l, mt=margin_t, pw=plot_w, ph=plot_h,
        mx=margin_l + plot_w / 2, title=title, subtitle=subtitle,
        y_ticks="\n  ".join(y_ticks), x_ticks="\n  ".join(x_ticks),
        lines="\n  ".join(lines_svg), legend="\n  ".join(legend_svg),
    )

    with open(output_path, "w") as f:
        f.write(svg)
    return True


def _format_tick(val):
    if abs(val) >= 1000:
        return "{:.0f}".format(val)
    if abs(val) >= 10:
        return "{:.1f}".format(val)
    return "{:.2f}".format(val)


def generate_single_metric_svg(metric_id, points, output_path):
    """为单个指标生成 SVG 时间线图（使用真实数值 Y 轴）。"""
    if len(points) < 2:
        return False

    points = sorted(points, key=lambda p: p[0])
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    ymin, ymax = min(ys), max(ys)
    if ymin == ymax:
        ymin -= abs(ymin) * 0.1 + 1
        ymax += abs(ymax) * 0.1 + 1
    yspan = ymax - ymin
    max_x = max(xs) if xs else 1.0

    width, height = 900, 360
    margin_l, margin_t, margin_r, margin_b = 72, 48, 24, 56
    plot_w = width - margin_l - margin_r
    plot_h = height - margin_t - margin_b

    label = _metric_label(metric_id)
    unit = _metric_unit(metric_id)
    title = "{} ({})".format(label, unit) if unit else label

    def x_pos(t):
        return margin_l + (t / max_x * plot_w if max_x > 0 else 0)

    def y_pos(v):
        return margin_t + plot_h - ((v - ymin) / yspan * plot_h)

    poly_pts = ["{:.1f},{:.1f}".format(x_pos(xs[i]), y_pos(ys[i])) for i in range(len(xs))]

    y_ticks = []
    for i in range(6):
        val = ymin + yspan * i / 5.0
        y = y_pos(val)
        y_ticks.append(
            '<line x1="{ml}" y1="{y:.1f}" x2="{xr:.1f}" y2="{y:.1f}" stroke="#eee"/>'
            '<text x="{mlx}" y="{yt:.1f}" font-size="10" fill="#666" '
            'text-anchor="end">{lab}</text>'.format(
                ml=margin_l, y=y, xr=margin_l + plot_w, mlx=margin_l - 8,
                yt=y + 4, lab=_format_tick(val),
            )
        )

    x_ticks = []
    step = max(1, int(max_x // 10))
    for t in range(0, int(max_x) + 1, step):
        x = x_pos(t)
        x_ticks.append(
            '<line x1="{x:.1f}" y1="{yb}" x2="{x:.1f}" y2="{yt:.1f}" stroke="#eee"/>'
            '<text x="{x:.1f}" y="{yl}" font-size="10" fill="#666" '
            'text-anchor="middle">{t}s</text>'.format(
                x=x, yb=margin_t + plot_h, yt=margin_t,
                yl=margin_t + plot_h + 16, t=t,
            )
        )

    svg = """<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}">
  <rect width="100%" height="100%" fill="#fafafa"/>
  <text x="{ml}" y="28" font-size="15" font-weight="bold" fill="#222">{title}</text>
  <text x="{ml}" y="44" font-size="11" fill="#888">{metric_id}</text>
  <rect x="{ml}" y="{mt}" width="{pw}" height="{ph}" fill="#fff" stroke="#ddd"/>
  {y_ticks}
  {x_ticks}
  <polyline fill="none" stroke="#4e79a7" stroke-width="2" points="{pts}" />
  <text x="{mx}" y="{h}" font-size="11" fill="#666" text-anchor="middle">elapsed (s)</text>
</svg>""".format(
        w=width, h=height, ml=margin_l, mt=margin_t, pw=plot_w, ph=plot_h,
        mx=margin_l + plot_w / 2, title=title, metric_id=metric_id,
        y_ticks="\n  ".join(y_ticks), x_ticks="\n  ".join(x_ticks),
        pts=" ".join(poly_pts),
    )

    with open(output_path, "w") as f:
        f.write(svg)
    return True


def generate_all_timeline_svgs(timeseries, latency_timeline, output_dir):
    """生成 mpstat 专用图 + 其余指标（含 iostat 分项）独立 SVG。"""
    charts_dir = os.path.join(output_dir, "charts")
    if os.path.isdir(charts_dir):
        import shutil
        shutil.rmtree(charts_dir)
    os.makedirs(charts_dir, exist_ok=True)

    generated = generate_mpstat_charts(timeseries, charts_dir)

    series_map = collect_all_metric_series(timeseries, latency_timeline)
    for metric_id, points in series_map.items():
        filename = _safe_chart_name(metric_id) + ".svg"
        path = os.path.join(charts_dir, filename)
        if generate_single_metric_svg(metric_id, points, path):
            generated.append({
                "metric_id": metric_id,
                "label": _metric_label(metric_id),
                "unit": _metric_unit(metric_id),
                "file": "charts/" + filename,
                "points": len(points),
            })

    return generated


def generate_report_md(analysis, output_path):
    bench = analysis.get("benchmark", {})
    overall = bench.get("overall", {})
    corr = analysis.get("correlations", {})
    events = analysis.get("spike_events", [])
    flags = analysis.get("resource_flags", [])
    meta = analysis.get("metadata", {})

    lines = [
        "# Benchmark 资源关联分析报告",
        "",
        "## 执行摘要",
        "",
        "- **Worker 数**: {}".format(len(bench.get("workers", []))),
        "- **总沙箱数**: {}".format(overall.get("total_sandboxes", 0)),
        "- **冷启动 P50/P95/P99**: {} / {} / {} ms".format(
            overall.get("p50_ms", "-"),
            overall.get("p95_ms", "-"),
            overall.get("p99_ms", "-"),
        ),
        "- **资源采样点**: {}".format(analysis.get("resource_samples", 0)),
        "- **延迟时间线**: {} 秒窗口".format(
            len(analysis.get("latency_timeline", []))
        ),
    ]
    if analysis.get("elapsed_ms_estimated"):
        lines.append("- **注意**: 部分 worker 结果缺少 `elapsed_ms`，延迟时间线为估算值")
    if flags:
        lines.append("- **资源瓶颈标记**: `{}`".format("`, `".join(flags)))
    lines.append("")

    lines.extend(["## 各 Worker 延迟", ""])
    lines.append("| Worker | Sandboxes | P50 (ms) | P95 (ms) | P99 (ms) | Mean (ms) |")
    lines.append("|--------|-----------|----------|----------|----------|-----------|")
    for w in bench.get("workers", []):
        lines.append("| {} | {} | {} | {} | {} | {} |".format(
            w["label"], w["sandboxes"],
            w.get("p50_ms", "-"), w.get("p95_ms", "-"),
            w.get("p99_ms", "-"), w.get("mean_ms", "-"),
        ))
    lines.append("")

    if corr:
        lines.extend(["## 资源与延迟 P95 相关性 (Pearson r)", ""])
        lines.append("| 资源指标 | 相关系数 r | 解读 |")
        lines.append("|----------|-----------|------|")
        for metric, r in sorted(corr.items(), key=lambda x: -abs(x[1])):
            if abs(r) >= 0.7:
                hint = "强相关"
            elif abs(r) >= 0.4:
                hint = "中等相关"
            else:
                hint = "弱相关"
            lines.append("| `{}` | {} | {} |".format(metric, r, hint))
        lines.append("")

    if events:
        lines.extend(["## 延迟 Spike 事件", ""])
        lines.append("| 时间 (s) | P95 (ms) | 沙箱数 | CPU % | IO util % | 可能原因 |")
        lines.append("|----------|----------|--------|-------|-----------|----------|")
        for e in events[:20]:
            lines.append("| {} | {} | {} | {} | {} | {} |".format(
                e["elapsed_s"], e["latency_p95_ms"],
                e.get("sandbox_count", "-"),
                e.get("cpu_total_pct", "-"),
                e.get("io_util_pct", "-"),
                ", ".join(e.get("likely_triggers", [])),
            ))
        lines.append("")

    if meta:
        lines.extend(["## 环境信息", ""])
        host = meta.get("host", {})
        lines.append("- **主机**: {} ({})".format(
            host.get("hostname", "-"), host.get("kernel", "-")))
        rt = meta.get("runtime", {})
        if rt.get("containerd"):
            lines.append("- **containerd**: {}".format(rt["containerd"]))
        bench_cfg = meta.get("benchmark", {})
        if bench_cfg:
            lines.append("- **Benchmark CPUs**: `{}`, NUMA: {}, Workers: {}".format(
                bench_cfg.get("cpus", "-"),
                bench_cfg.get("numa", "-"),
                bench_cfg.get("proc_count", "-"),
            ))
        lines.append("")

    chart_files = analysis.get("chart_files", [])
    if chart_files:
        priority = [c for c in chart_files if c["metric_id"].startswith("cpu_mpstat.")]
        others = [c for c in chart_files if c not in priority]
        lines.extend(["## 时间线图", ""])
        lines.append("共 {} 张图，目录: `charts/`".format(len(chart_files)))
        if priority:
            lines.append("")
            lines.append("### mpstat CPU 专用图")
            lines.append("")
            lines.append("| 指标 | 文件 |")
            lines.append("|------|------|")
            for c in priority:
                unit = " ({})".format(c["unit"]) if c.get("unit") else ""
                lines.append("| {}{} | `{}` |".format(
                    c.get("label", c["metric_id"]), unit, c["file"]))
        if others:
            lines.append("")
            lines.append("### 其他指标（每指标一图）")
            lines.append("")
            lines.append("| 指标 | 文件 |")
            lines.append("|------|------|")
            for c in others[:40]:
                unit = " ({})".format(c["unit"]) if c.get("unit") else ""
                lines.append("| {}{} | `{}` |".format(
                    c.get("label", c["metric_id"]), unit, c["file"]))
            if len(others) > 40:
                lines.append("| ... | 共 {} 张 |".format(len(others)))
        lines.append("")

    lines.extend([
        "## 输出文件",
        "",
        "- `analysis.json` — 结构化分析结果",
        "- `report.md` — 本报告",
        "- `charts/*.svg` — 各指标独立时间线图",
        "",
    ])

    with open(output_path, "w") as f:
        f.write("\n".join(lines))
        f.write("\n")


def analyze(result_dir, output_dir=None):
    if output_dir is None:
        output_dir = os.path.join(result_dir, "resources")

    ts_path = os.path.join(output_dir, "timeseries.jsonl")
    meta_path = os.path.join(output_dir, "metadata.json")
    summary_path = os.path.join(output_dir, "summary.json")

    timeseries = _load_timeseries(ts_path)
    reports = _load_proc_reports(result_dir)
    metadata = _load_json(meta_path) if os.path.isfile(meta_path) else {}
    summary = _load_json(summary_path) if os.path.isfile(summary_path) else {}

    latency_timeline, has_elapsed, estimated = build_latency_timeline(reports)
    aligned = align_series(timeseries, latency_timeline)
    correlations = compute_correlations(aligned)
    spike_events = find_spike_events(aligned, latency_timeline)
    benchmark = summarize_benchmark(reports)

    os.makedirs(output_dir, exist_ok=True)
    analysis_path = os.path.join(output_dir, "analysis.json")
    report_path = os.path.join(output_dir, "report.md")

    chart_files = generate_all_timeline_svgs(timeseries, latency_timeline, output_dir)

    analysis = {
        "benchmark": benchmark,
        "resource_samples": len(timeseries),
        "latency_timeline": latency_timeline,
        "correlations": correlations,
        "spike_events": spike_events,
        "aligned_preview": aligned[:5],
        "has_elapsed_ms": has_elapsed,
        "elapsed_ms_estimated": estimated and not has_elapsed,
        "resource_flags": summary.get("flags", []),
        "metadata": metadata,
        "chart_files": chart_files,
        "chart_count": len(chart_files),
    }

    with open(analysis_path, "w") as f:
        json.dump(analysis, f, indent=2, ensure_ascii=False)
        f.write("\n")

    generate_report_md(analysis, report_path)

    print("[analyzer] analysis → {}".format(analysis_path))
    print("[analyzer] report   → {}".format(report_path))
    if chart_files:
        print("[analyzer] charts   → {}/charts/ ({} 张)".format(
            output_dir, len(chart_files)))
    else:
        print("[analyzer] ⚠ 未生成图表（无时序数据）")

    if correlations:
        print("")
        print("--- 延迟 P95 相关性 (|r| Top) ---")
        for metric, r in sorted(correlations.items(), key=lambda x: -abs(x[1]))[:5]:
            print("  {:<22} r={:+.3f}".format(metric, r))

    if spike_events:
        print("")
        print("--- 延迟 Spike × {} ---".format(len(spike_events)))
        for e in spike_events[:5]:
            print("  t={}s  P95={}ms  triggers={}".format(
                e["elapsed_s"], e["latency_p95_ms"],
                ",".join(e["likely_triggers"]),
            ))

    return analysis


def main():
    parser = argparse.ArgumentParser(description="资源与 benchmark 关联分析")
    parser.add_argument("result_dir", help="benchmark 结果目录 (如 results/multi)")
    parser.add_argument(
        "--output-dir", default=None,
        help="分析输出目录 (默认: <result_dir>/resources)",
    )
    args = parser.parse_args()

    if not os.path.isdir(args.result_dir):
        print("错误: 目录不存在: {}".format(args.result_dir), file=sys.stderr)
        return 1

    analyze(args.result_dir, args.output_dir)
    return 0


if __name__ == "__main__":
    sys.exit(main())
