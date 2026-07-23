#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ipvlan-l3 CNI 热路径 benchmark（对齐沙箱冷启动配网，不跑完整 sandbox）。

每轮大致复现:
  netns 创建 → [可选 lo] → ipvlan l3 ADD（配址/UP/路由）→ 结束后统一 DEL

  --mode cni      真插件 /opt/cni/bin/ipvlan + host-local（贴近沙箱）
  --mode netlink  用 ip/netlink 重放同序操作（无插件/IPAM，对照 RTNL）

用法:
  python3 scripts/ipvlan/ipvlan_l3_bench.py -c 128 --duration 60
  python3 scripts/ipvlan/ipvlan_l3_bench.py -c 64 --ops 2000 --master eth0
  numactl -C 1-4 python3 scripts/ipvlan/ipvlan_l3_bench.py -c 128 --duration 30
"""

from __future__ import print_function

import argparse
import ipaddress
import json
import os
import shutil
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed

DEFAULT_CNI_BIN = "/opt/cni/bin"
DEFAULT_SUBNET = "10.88.0.0/16"  # 独立网段，避免与生产 mynet /12 冲突
DEFAULT_IFNAME = "eth0"

_stop = threading.Event()
_ip_alloc_lock = threading.Lock()
_ip_host_iter = None  # set in main for netlink mode


def _run(cmd, env=None, input_data=None, check=True):
    # type: (list, dict, bytes, bool) -> subprocess.CompletedProcess
    kw = {
        "stdout": subprocess.PIPE,
        "stderr": subprocess.PIPE,
        "env": env or os.environ.copy(),
    }
    if input_data is not None:
        kw["input"] = input_data
    p = subprocess.run(cmd, **kw)
    if check and p.returncode != 0:
        err = (p.stderr or b"").decode("utf-8", "replace")
        out = (p.stdout or b"").decode("utf-8", "replace")
        raise RuntimeError(
            "cmd failed rc={}: {}\nstdout: {}\nstderr: {}".format(
                p.returncode, " ".join(cmd), out[:500], err[:800]
            )
        )
    return p


def detect_master():
    try:
        out = _run(["ip", "-o", "route", "show", "default"], check=False)
        line = (out.stdout or b"").decode().strip().splitlines()
        if line:
            parts = line[0].split()
            if "dev" in parts:
                return parts[parts.index("dev") + 1]
    except Exception:
        pass
    return "eth0"


def percentile(sorted_vals, p):
    if not sorted_vals:
        return 0.0
    n = len(sorted_vals)
    if n == 1:
        return float(sorted_vals[0])
    idx = max(0, min(n - 1, int(n * p) - 1))
    if idx < 0:
        idx = 0
    return float(sorted_vals[idx])


def build_netconf(master, subnet, data_dir, no_ipam=False):
    conf = {
        "cniVersion": "0.3.1",
        "name": "ipvlan-l3-bench",
        "type": "ipvlan",
        "master": master,
        "mode": "l3",
    }
    if no_ipam:
        conf["ipam"] = {}
    else:
        conf["ipam"] = {
            "type": "host-local",
            "subnet": subnet,
            "dataDir": data_dir,
            "routes": [{"dst": "0.0.0.0/0"}],
        }
    return conf


def cni_env(command, container_id, netns_path, ifname, cni_bin):
    env = os.environ.copy()
    env.update(
        {
            "CNI_COMMAND": command,
            "CNI_CONTAINERID": container_id,
            "CNI_NETNS": netns_path,
            "CNI_IFNAME": ifname,
            "CNI_PATH": cni_bin,
            "PATH": cni_bin + ":" + env.get("PATH", ""),
        }
    )
    return env


def cni_add_ipvlan(cni_bin, conf_bytes, container_id, netns_path, ifname):
    env = cni_env("ADD", container_id, netns_path, ifname, cni_bin)
    plugin = os.path.join(cni_bin, "ipvlan")
    return _run([plugin], env=env, input_data=conf_bytes)


def cni_del_ipvlan(cni_bin, conf_bytes, container_id, netns_path, ifname):
    env = cni_env("DEL", container_id, netns_path, ifname, cni_bin)
    plugin = os.path.join(cni_bin, "ipvlan")
    return _run([plugin], env=env, input_data=conf_bytes, check=False)


def cni_add_loopback(cni_bin, container_id, netns_path):
    conf = json.dumps(
        {"cniVersion": "0.3.1", "name": "lo-bench", "type": "loopback"}
    ).encode()
    env = cni_env("ADD", container_id, netns_path, "lo", cni_bin)
    plugin = os.path.join(cni_bin, "loopback")
    return _run([plugin], env=env, input_data=conf)


def ensure_netns(name):
    path = "/var/run/netns/{}".format(name)
    _run(["ip", "netns", "add", name])
    return path


def delete_netns(name):
    _run(["ip", "netns", "delete", name], check=False)


def random_tmp_ifname():
    # IFNAMSIZ=15；对齐 CNI 临时名风格
    return "ip" + uuid.uuid4().hex[:8]


def init_ip_allocator(subnet):
    global _ip_host_iter
    net = ipaddress.ip_network(subnet, strict=False)
    _ip_host_iter = net.hosts()


def alloc_addr_cidr(subnet):
    """netlink 模式：无 host-local，用内存计数分配地址。"""
    global _ip_host_iter
    prefix = ipaddress.ip_network(subnet, strict=False).prefixlen
    with _ip_alloc_lock:
        try:
            host = next(_ip_host_iter)
        except StopIteration:
            raise RuntimeError("subnet {} 地址耗尽".format(subnet))
    return "{}/{}".format(host, prefix)


def netlink_bring_lo(ns_name):
    _run(["ip", "-n", ns_name, "link", "set", "lo", "up"])


def netlink_add_ipvlan(master, ns_name, ifname, subnet):
    """
    对齐 CNI ipvlan ADD 的 netlink 步骤（不含插件/host-local）:
      LinkAdd(临时名) → set netns → Rename → AddrAdd → LinkSetUp → RouteAdd
    """
    tmp = random_tmp_ifname()
    _run(
        [
            "ip",
            "link",
            "add",
            "link",
            master,
            "name",
            tmp,
            "type",
            "ipvlan",
            "mode",
            "l3",
        ]
    )
    try:
        _run(["ip", "link", "set", tmp, "netns", ns_name])
    except Exception:
        _run(["ip", "link", "delete", tmp], check=False)
        raise
    _run(["ip", "-n", ns_name, "link", "set", tmp, "name", ifname])
    addr = alloc_addr_cidr(subnet)
    _run(["ip", "-n", ns_name, "addr", "add", addr, "dev", ifname])
    _run(["ip", "-n", ns_name, "link", "set", ifname, "up"])
    # l3：默认路由走设备（与 CNI routes 0.0.0.0/0 效果接近）
    _run(
        ["ip", "-n", ns_name, "route", "replace", "default", "dev", ifname],
        check=False,
    )
    return addr


def netlink_del_ipvlan(ns_name, ifname):
    _run(["ip", "-n", ns_name, "link", "delete", ifname], check=False)


def one_op(args, conf_bytes, seq):
    """执行一次 ADD（可选每轮 DEL）。返回 dict 含各阶段 ms。"""
    if _stop.is_set():
        return None

    cid = "ivlbench-{}-{}".format(os.getpid(), uuid.uuid4().hex[:12])
    ns_name = cid
    t0 = time.perf_counter()
    mode = args.mode

    phases = {}
    try:
        t = time.perf_counter()
        netns_path = ensure_netns(ns_name)
        phases["netns_ms"] = (time.perf_counter() - t) * 1000

        if args.with_lo:
            t = time.perf_counter()
            if mode == "cni":
                cni_add_loopback(args.cni_bin, cid, netns_path)
            else:
                netlink_bring_lo(ns_name)
            phases["lo_ms"] = (time.perf_counter() - t) * 1000

        t = time.perf_counter()
        if mode == "cni":
            cni_add_ipvlan(args.cni_bin, conf_bytes, cid, netns_path, args.ifname)
        else:
            netlink_add_ipvlan(args.master, ns_name, args.ifname, args.subnet)
        phases["add_ms"] = (time.perf_counter() - t) * 1000

        if args.cleanup_each:
            t = time.perf_counter()
            if mode == "cni":
                cni_del_ipvlan(args.cni_bin, conf_bytes, cid, netns_path, args.ifname)
            else:
                netlink_del_ipvlan(ns_name, args.ifname)
            delete_netns(ns_name)
            phases["del_ms"] = (time.perf_counter() - t) * 1000
            ns_name = None

        phases["total_ms"] = (time.perf_counter() - t0) * 1000
        phases["ok"] = True
        phases["cid"] = cid
        phases["ns"] = ns_name
        phases["mode"] = mode
        return phases
    except Exception as e:
        try:
            if mode == "cni":
                cni_del_ipvlan(
                    args.cni_bin, conf_bytes, cid, "/var/run/netns/" + ns_name, args.ifname
                )
            else:
                netlink_del_ipvlan(ns_name, args.ifname)
        except Exception:
            pass
        delete_netns(ns_name)
        return {
            "ok": False,
            "error": str(e),
            "total_ms": (time.perf_counter() - t0) * 1000,
            "cid": cid,
            "ns": None,
            "mode": mode,
        }


def worker_loop(args, conf_bytes, results, lock, counter):
    while not _stop.is_set():
        with lock:
            if args.ops is not None:
                if counter[0] >= args.ops:
                    return
                counter[0] += 1
                seq = counter[0]
            else:
                counter[0] += 1
                seq = counter[0]

        r = one_op(args, conf_bytes, seq)
        if r is None:
            return
        with lock:
            results.append(r)


def cleanup_leftovers(prefix="ivlbench-"):
    """清理残留 netns（本 bench 命名）。"""
    p = _run(["ip", "netns", "list"], check=False)
    text = (p.stdout or b"").decode()
    for line in text.splitlines():
        name = line.split()[0] if line.strip() else ""
        if name.startswith(prefix):
            delete_netns(name)


def print_stats(title, values_ms):
    if not values_ms:
        print("  {}: (no data)".format(title))
        return
    s = sorted(values_ms)
    mean = statistics.mean(s)
    print(
        "  {:<12} n={:<6} p50={:>8.2f} p95={:>8.2f} p99={:>8.2f} mean={:>8.2f} ms".format(
            title, len(s), percentile(s, 0.50), percentile(s, 0.95), percentile(s, 0.99), mean
        )
    )


def main():
    class _HelpFormatter(
        argparse.RawDescriptionHelpFormatter, argparse.ArgumentDefaultsHelpFormatter
    ):
        pass

    ap = argparse.ArgumentParser(
        description="ipvlan-l3 CNI ADD benchmark (sandbox-like path, no full pod)",
        formatter_class=_HelpFormatter,
        epilog="""
示例:
  python3 scripts/ipvlan/ipvlan_l3_bench.py -c 128 --duration 60
  python3 scripts/ipvlan/ipvlan_l3_bench.py -c 64 --ops 1000 --master eth0
  python3 scripts/ipvlan/ipvlan_l3_bench.py -c 128 --duration 30 --mode netlink
  numactl -C 1-4 python3 scripts/ipvlan/ipvlan_l3_bench.py -c 128 --duration 30 --with-lo
""",
    )
    ap.add_argument("-c", "--concurrency", type=int, default=32, help="并发 worker 数")
    ap.add_argument(
        "--mode",
        choices=("cni", "netlink"),
        default="cni",
        help="cni=真插件+host-local；netlink=ip/netlink 重放（无插件/IPAM，对照 RTNL）",
    )
    ap.add_argument(
        "--duration",
        type=float,
        default=None,
        help="压测秒数（与 --ops 二选一；两者都未指定时默认 30）",
    )
    ap.add_argument("--ops", type=int, default=None, help="总操作数上限（与 --duration 二选一）")
    ap.add_argument(
        "--master",
        type=str,
        default=None,
        help="ipvlan master 网卡（默认自动探测 default route 的 dev）",
    )
    ap.add_argument("--subnet", type=str, default=DEFAULT_SUBNET, help="地址网段（cni 用 host-local；netlink 用内存分配）")
    ap.add_argument("--cni-bin", type=str, default=DEFAULT_CNI_BIN, help="CNI bin 目录（仅 --mode cni）")
    ap.add_argument("--ifname", type=str, default=DEFAULT_IFNAME, help="容器内接口名")
    ap.add_argument(
        "--with-lo",
        action="store_true",
        help="ADD 前启用 lo（cni: loopback 插件；netlink: ip link set lo up）",
    )
    ap.add_argument(
        "--cleanup-each",
        action="store_true",
        help="每轮 ADD 后立刻 DEL+删 ns（默认压测期间保留，结束后统一清理）",
    )
    ap.add_argument(
        "--data-dir",
        type=str,
        default=None,
        help="host-local dataDir（仅 cni；默认临时目录 ipvlan-l3-bench-*/cni-ipam）",
    )
    ap.add_argument(
        "--output",
        type=str,
        default=None,
        help="summary.json 路径或目录（默认 results/ipvlan_l3_bench/<ts>/summary.json）",
    )
    args = ap.parse_args()
    args.cleanup_each = bool(args.cleanup_each)
    args.no_ipam = False

    if args.duration is None and args.ops is None:
        args.duration = 30.0
    if args.duration is not None and args.ops is not None:
        print("错误: --duration 与 --ops 只能选一个", file=sys.stderr)
        sys.exit(2)

    if args.mode == "cni":
        for need in ("ipvlan", "host-local"):
            path = os.path.join(args.cni_bin, need)
            if not os.path.isfile(path):
                print("错误: 缺少 CNI 插件: {}".format(path), file=sys.stderr)
                sys.exit(1)
        if args.with_lo and not os.path.isfile(os.path.join(args.cni_bin, "loopback")):
            print("错误: 缺少 loopback 插件", file=sys.stderr)
            sys.exit(1)

    if os.geteuid() != 0:
        print("警告: 通常需要 root（netns / CNI / netlink）", file=sys.stderr)

    master = args.master or detect_master()
    args.master = master

    tmp_root = tempfile.mkdtemp(prefix="ipvlan-l3-bench-")
    data_dir = args.data_dir or os.path.join(tmp_root, "cni-ipam")
    conf_bytes = b"{}"
    if args.mode == "cni":
        os.makedirs(data_dir, exist_ok=True)
        conf = build_netconf(master, args.subnet, data_dir, no_ipam=args.no_ipam)
        conf_bytes = json.dumps(conf).encode()
    else:
        init_ip_allocator(args.subnet)

    out_dir = args.output
    if out_dir is None:
        ts = time.strftime("%Y%m%d%H%M%S")
        out_dir = os.path.join("results", "ipvlan_l3_bench", ts)
    if out_dir.endswith(".json"):
        summary_path = out_dir
        out_dir = os.path.dirname(out_dir) or "."
    else:
        summary_path = os.path.join(out_dir, "summary.json")
    os.makedirs(out_dir, exist_ok=True)

    print("==============================================")
    print("  ipvlan-l3 benchmark")
    print("==============================================")
    print("  mode:        {}".format(args.mode))
    print("  concurrency: {}".format(args.concurrency))
    print("  duration:    {}".format(args.duration if args.duration else "-"))
    print("  ops:         {}".format(args.ops if args.ops else "-"))
    print("  master:      {}".format(master))
    print("  subnet:      {}".format(args.subnet))
    if args.mode == "cni":
        print("  cni-bin:     {}".format(args.cni_bin))
        print("  dataDir:     {}".format(data_dir))
    print("  with-lo:     {}".format(args.with_lo))
    print("  cleanup:     {}".format("each" if args.cleanup_each else "end (default)"))
    print("  output:      {}".format(summary_path))
    print("==============================================")

    cleanup_leftovers()

    results = []
    lock = threading.Lock()
    counter = [0]

    def _sig(_s, _f):
        _stop.set()

    signal.signal(signal.SIGINT, _sig)
    signal.signal(signal.SIGTERM, _sig)

    t_wall0 = time.perf_counter()
    with ThreadPoolExecutor(max_workers=args.concurrency) as ex:
        futs = [
            ex.submit(worker_loop, args, conf_bytes, results, lock, counter)
            for _ in range(args.concurrency)
        ]
        if args.duration is not None:
            end = time.perf_counter() + args.duration
            while time.perf_counter() < end and not _stop.is_set():
                time.sleep(0.2)
            _stop.set()
        for f in as_completed(futs):
            try:
                f.result()
            except Exception as e:
                print("worker error: {}".format(e), file=sys.stderr)

    wall = time.perf_counter() - t_wall0

    # 默认：压测期间保留，此处统一 DEL + 删 ns
    leftover_ns = []
    with lock:
        for r in results:
            if r.get("ns"):
                leftover_ns.append((r.get("cid"), r["ns"]))
    if leftover_ns:
        print("[post] 统一清理 {} 个 netns ...".format(len(leftover_ns)))
        for cid, ns in leftover_ns:
            if args.mode == "cni":
                cni_del_ipvlan(
                    args.cni_bin, conf_bytes, cid, "/var/run/netns/" + ns, args.ifname
                )
            else:
                netlink_del_ipvlan(ns, args.ifname)
            delete_netns(ns)
    cleanup_leftovers()

    ok = [r for r in results if r.get("ok")]
    fail = [r for r in results if not r.get("ok")]
    add_ms = [r["add_ms"] for r in ok if "add_ms" in r]
    total_ms = [r["total_ms"] for r in ok if "total_ms" in r]
    netns_ms = [r["netns_ms"] for r in ok if "netns_ms" in r]
    lo_ms = [r["lo_ms"] for r in ok if "lo_ms" in r]
    del_ms = [r["del_ms"] for r in ok if "del_ms" in r]

    tps = len(ok) / wall if wall > 0 else 0.0

    print("")
    print("---- 结果 ----")
    print("  wall:     {:.2f}s".format(wall))
    print("  ok/fail:  {}/{}".format(len(ok), len(fail)))
    print("  throughput: {:.2f} ADD/s".format(tps))
    print_stats("netns", netns_ms)
    if lo_ms:
        print_stats("loopback", lo_ms)
    print_stats("ipvlan ADD", add_ms)
    if del_ms:
        print_stats("DEL+ns", del_ms)
    print_stats("total", total_ms)
    if fail:
        print("  示例错误: {}".format(fail[0].get("error", "")[:200]))

    summary = {
        "config": {
            "mode": args.mode,
            "concurrency": args.concurrency,
            "duration": args.duration,
            "ops": args.ops,
            "master": master,
            "subnet": args.subnet,
            "cni_bin": args.cni_bin if args.mode == "cni" else None,
            "with_lo": args.with_lo,
            "cleanup_each": args.cleanup_each,
            "data_dir": data_dir if args.mode == "cni" else None,
        },
        "wall_s": wall,
        "ok": len(ok),
        "fail": len(fail),
        "throughput_add_per_s": tps,
        "phases_ms": {},
    }

    def pack(vals):
        if not vals:
            return None
        s = sorted(vals)
        return {
            "n": len(s),
            "p50": percentile(s, 0.50),
            "p95": percentile(s, 0.95),
            "p99": percentile(s, 0.99),
            "mean": statistics.mean(s),
        }

    summary["phases_ms"]["netns"] = pack(netns_ms)
    summary["phases_ms"]["loopback"] = pack(lo_ms)
    summary["phases_ms"]["ipvlan_add"] = pack(add_ms)
    summary["phases_ms"]["del"] = pack(del_ms)
    summary["phases_ms"]["total"] = pack(total_ms)

    with open(summary_path, "w") as f:
        json.dump(summary, f, indent=2)
        f.write("\n")
    print("  summary → {}".format(summary_path))

    # 临时 IPAM 目录：默认删掉；用户指定 --data-dir 则保留
    if args.data_dir is None:
        shutil.rmtree(tmp_root, ignore_errors=True)
    return 0 if not fail else 1


if __name__ == "__main__":
    sys.exit(main())
