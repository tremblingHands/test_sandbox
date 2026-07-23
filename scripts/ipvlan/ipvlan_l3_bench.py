#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
ipvlan-l3 CNI 热路径 benchmark（对齐沙箱冷启动配网，不跑完整 sandbox）。

每轮大致复现:
  netns 创建 → [可选 lo] → ipvlan l3 ADD（配址/UP/路由）→ 结束后统一 DEL

  --precreate-netns [N]  预创建 N 个 netns（省略 N 时 = -c），均分给 M=-c 个 worker；
                         热路径跳过「建 ns」，其余与不配一致（含 --with-lo 每轮配 lo）；
                         份用尽后现场新建 ns，并打日志提示

  --mode cni      真插件 /opt/cni/bin/ipvlan + host-local（贴近沙箱）
  --mode netlink  用 ip/netlink 重放同序操作（无插件/IPAM，对照 RTNL）

用法:
  python3 scripts/ipvlan/ipvlan_l3_bench.py -c 128 --duration 60
  python3 scripts/ipvlan/ipvlan_l3_bench.py -c 64 --duration 30 --master eth0
  python3 scripts/ipvlan/ipvlan_l3_bench.py -c 8 --duration 30 --precreate-netns 800 --with-lo
  # 仅在 benchmark 窗口调用 containerd_perf.sh 采 on/off-CPU 火焰图:
  numactl -C 1-4 python3 scripts/ipvlan/ipvlan_l3_bench.py -c 128 --duration 30 \
      --precreate-netns 1024 --perf-cpus 1-4
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


def strip_iface(args, conf_bytes, cid, ns_name, ifname):
    """卸掉 ns 内业务网卡。"""
    netns_path = "/var/run/netns/" + ns_name
    if args.mode == "cni":
        cni_del_ipvlan(args.cni_bin, conf_bytes, cid, netns_path, ifname)
    else:
        netlink_del_ipvlan(ns_name, ifname)


def precreate_netns_list(count, args):
    """
    预先创建 count 个空 netns（不配 lo；--with-lo 仍在热路径每轮执行，与不配预创建一致）。
    返回 (list of dict{ns,path}, precreate_ms)。
    """
    t0 = time.perf_counter()
    items = []
    for i in range(count):
        ns = "ivlbench-pre-{}-{:04d}".format(os.getpid(), i)
        path = ensure_netns(ns)
        items.append({"ns": ns, "path": path})
    ms = (time.perf_counter() - t0) * 1000
    return items, ms


def split_netns_shares(items, m):
    """将 netns 列表连续切成 m 份（份大小最多差 1）。"""
    n = len(items)
    base, rem = divmod(n, m)
    shares = []
    start = 0
    for i in range(m):
        sz = base + (1 if i < rem else 0)
        shares.append(items[start : start + sz])
        start += sz
    return shares


def one_op(args, conf_bytes, seq, owned_ns=None):
    """执行一次 ADD。owned_ns 非空时跳过建 ns；--with-lo 行为与不配预创建一致。"""
    if _stop.is_set():
        return None

    mode = args.mode
    precreated = owned_ns is not None
    cid = "ivlbench-{}-{}".format(os.getpid(), uuid.uuid4().hex[:12])
    ns_name = None
    t0 = time.perf_counter()
    phases = {}

    try:
        if precreated:
            ns_name = owned_ns["ns"]
            netns_path = owned_ns["path"]
            phases["netns_ms"] = 0.0
        else:
            ns_name = cid
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

        if args.cleanup_each and not precreated:
            t = time.perf_counter()
            if mode == "cni":
                cni_del_ipvlan(args.cni_bin, conf_bytes, cid, netns_path, args.ifname)
            else:
                netlink_del_ipvlan(ns_name, args.ifname)
            delete_netns(ns_name)
            phases["del_ms"] = (time.perf_counter() - t) * 1000
            ns_name = None
            phases["ns"] = None
        else:
            # 保留 iface + netns，结束后统一清理
            phases["ns"] = ns_name

        phases["total_ms"] = (time.perf_counter() - t0) * 1000
        phases["ok"] = True
        phases["cid"] = cid
        if "ns" not in phases:
            phases["ns"] = ns_name
        phases["mode"] = mode
        phases["precreated"] = precreated
        return phases
    except Exception as e:
        # 预创建 ns 留给结束后统一清；现场新建的则尽量删掉
        if not precreated and ns_name:
            try:
                strip_iface(args, conf_bytes, cid, ns_name, args.ifname)
            except Exception:
                pass
            delete_netns(ns_name)
            ns_name = None
        return {
            "ok": False,
            "error": str(e),
            "total_ms": (time.perf_counter() - t0) * 1000,
            "cid": cid,
            "ns": ns_name if precreated else None,
            "mode": mode,
            "precreated": precreated,
        }


def worker_loop(args, conf_bytes, results, lock, counter, ns_share=None, overflow=None):
    """
    ns_share: 本 worker 独占的预创建 ns 列表。
    用尽后现场新建 ns；overflow 为 [count]，首次溢出打日志。
    """
    share_idx = 0
    while not _stop.is_set():
        with lock:
            counter[0] += 1
            seq = counter[0]

        owned = None
        if ns_share is not None:
            if share_idx < len(ns_share):
                owned = ns_share[share_idx]
                share_idx += 1
            else:
                # 容量用尽：回退到现场建 ns
                if overflow is not None:
                    with lock:
                        overflow[0] += 1
                        n = overflow[0]
                    if n == 1:
                        print(
                            "[warn] precreate 容量已用尽，后续将现场创建 netns"
                            "（与不配 --precreate-netns 相同）",
                            file=sys.stderr,
                            flush=True,
                        )
                    elif n % 100 == 0:
                        print(
                            "[warn] precreate 溢出累计 {} 次（现场新建 netns）".format(n),
                            file=sys.stderr,
                            flush=True,
                        )
                owned = None

        r = one_op(args, conf_bytes, seq, owned_ns=owned)
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


def which(cmd):
    return shutil.which(cmd)


def _perf_script_path():
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.join(here, "..", "containerd_perf.sh")


def start_perf_capture_live(cpus, out_dir, freq=99, call_graph="fp"):
    """
    调用 containerd_perf.sh capture-live：按 -C 采 on/off-CPU，直到 stop。
    仅应在 benchmark wall 窗口内启动。
    """
    script = os.path.normpath(_perf_script_path())
    if not os.path.isfile(script):
        raise RuntimeError("未找到 perf 脚本: {}".format(script))
    if not which("perf"):
        raise RuntimeError("未找到 perf")
    os.makedirs(out_dir, exist_ok=True)
    ready = os.path.join(out_dir, "capture.ready")
    if os.path.exists(ready):
        os.remove(ready)
    cmd = [
        "bash",
        script,
        "capture-live",
        "--output-dir",
        out_dir,
        "--cpus",
        cpus,
        "--frequency",
        str(freq),
        "--call-graph",
        call_graph,
        "--offcpu-method",
        "perf",
        "--title-prefix",
        "ipvlan-l3-bench",
    ]
    # 独立 session，避免 Ctrl+C 先杀掉采集再跑不到 finally
    p = subprocess.Popen(
        cmd,
        stdout=None,
        stderr=None,
        start_new_session=True,
    )
    deadline = time.time() + 30
    while time.time() < deadline:
        if p.poll() is not None:
            raise RuntimeError(
                "capture-live 提前退出 rc={}".format(p.returncode)
            )
        if os.path.isfile(ready):
            return p
        time.sleep(0.1)
    p.send_signal(signal.SIGTERM)
    raise RuntimeError("等待 capture-live ready 超时")


def stop_perf_capture_live(proc, wait_s=300):
    """发送 SIGTERM，让 capture-live 停采样并生成 on/off SVG。"""
    if proc is None:
        return
    if proc.poll() is None:
        try:
            # 只信号 bash 脚本，由其 trap 对 perf 发 SIGINT（勿 killpg）
            proc.send_signal(signal.SIGTERM)
        except OSError:
            try:
                proc.kill()
            except OSError:
                pass
    try:
        proc.wait(timeout=wait_s)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            try:
                proc.kill()
            except OSError:
                pass
        try:
            proc.wait(timeout=30)
        except Exception:
            pass


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
  python3 scripts/ipvlan/ipvlan_l3_bench.py -c 64 --duration 30 --master eth0
  python3 scripts/ipvlan/ipvlan_l3_bench.py -c 128 --duration 30 --mode netlink
  python3 scripts/ipvlan/ipvlan_l3_bench.py -c 8 --duration 30 --precreate-netns 800 --with-lo
  numactl -C 1-4 python3 scripts/ipvlan/ipvlan_l3_bench.py -c 128 --duration 30 \
      --precreate-netns 1024 --perf-cpus 1-4
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
        default=30.0,
        help="压测秒数（benchmark wall）",
    )
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
        help="每轮 ADD 后立刻 DEL+删 ns（默认压测期间保留，结束后统一清理；与 --precreate-netns 互斥）",
    )
    ap.add_argument(
        "--precreate-netns",
        nargs="?",
        const=-1,
        type=int,
        default=None,
        metavar="N",
        help="预创建 N 个空 netns（省略 N 时 = -c），连续均分给 M=-c 个 worker；"
        "热路径跳过建 ns，--with-lo 仍每轮执行；份用尽后现场新建并告警",
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
    ap.add_argument(
        "--perf-cpus",
        type=str,
        default=None,
        metavar="CPUS",
        help="仅在 benchmark 窗口调用 containerd_perf.sh capture-live "
        "采 on/off-CPU（如 1-4；pre/post 不采）",
    )
    ap.add_argument(
        "--perf-freq",
        type=int,
        default=99,
        help="--perf-cpus 时 on-CPU 采样频率 Hz",
    )
    ap.add_argument(
        "--perf-call-graph",
        type=str,
        default="fp",
        help="--perf-cpus 时 on-CPU call-graph（同 containerd_perf.sh）",
    )
    args = ap.parse_args()
    args.cleanup_each = bool(args.cleanup_each)
    args.no_ipam = False

    if args.duration is None or args.duration <= 0:
        print("错误: --duration 须 > 0", file=sys.stderr)
        sys.exit(2)

    precreate_n = None
    if args.precreate_netns is not None:
        if args.cleanup_each:
            print("错误: --precreate-netns 与 --cleanup-each 不能同时使用", file=sys.stderr)
            sys.exit(2)
        precreate_n = args.concurrency if args.precreate_netns < 0 else args.precreate_netns
        if precreate_n < args.concurrency:
            print(
                "错误: --precreate-netns N ({}) 须 >= -c ({})".format(
                    precreate_n, args.concurrency
                ),
                file=sys.stderr,
            )
            sys.exit(2)
    args.precreate_n = precreate_n

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
    print("  duration:    {}s".format(args.duration))
    print("  master:      {}".format(master))
    print("  subnet:      {}".format(args.subnet))
    if args.mode == "cni":
        print("  cni-bin:     {}".format(args.cni_bin))
        print("  dataDir:     {}".format(data_dir))
    print("  with-lo:     {}".format(args.with_lo))
    print("  cleanup:     {}".format("each" if args.cleanup_each else "end (default)"))
    print(
        "  precreate:   {}".format(
            "{} ns / {} workers".format(precreate_n, args.concurrency)
            if precreate_n
            else "off"
        )
    )
    print(
        "  perf-cpus:   {}".format(
            "{} @ {}Hz via containerd_perf.sh capture-live".format(
                args.perf_cpus, args.perf_freq
            )
            if args.perf_cpus
            else "off"
        )
    )
    print("  output:      {}".format(summary_path))
    print("==============================================")

    if args.perf_cpus:
        if not which("perf"):
            print("错误: --perf-cpus 需要 perf", file=sys.stderr)
            sys.exit(1)
        if not os.path.isfile(os.path.normpath(_perf_script_path())):
            print(
                "错误: 未找到 {}".format(os.path.normpath(_perf_script_path())),
                file=sys.stderr,
            )
            sys.exit(1)

    cleanup_leftovers()

    results = []
    lock = threading.Lock()
    counter = [0]
    overflow = [0]
    pre_ns = []
    ns_shares = None
    precreate_ms = 0.0
    perf_proc = None
    perf_dir = None

    if precreate_n:
        print(
            "[pre] 预创建 {} 个空 netns，均分给 {} 个 worker ...".format(
                precreate_n, args.concurrency
            )
        )
        pre_ns, precreate_ms = precreate_netns_list(precreate_n, args)
        ns_shares = split_netns_shares(pre_ns, args.concurrency)
        sizes = [len(s) for s in ns_shares]
        print(
            "[pre] 完成 {:.1f} ms；每 worker 份大小 {}..{}".format(
                precreate_ms, min(sizes), max(sizes)
            )
        )

    def _sig(_s, _f):
        _stop.set()

    signal.signal(signal.SIGINT, _sig)
    signal.signal(signal.SIGTERM, _sig)

    t_wall0 = time.perf_counter()
    print(
        "[bench] 开始（duration={}s, concurrency={}）".format(
            args.duration, args.concurrency
        ),
        flush=True,
    )
    try:
        if args.perf_cpus:
            perf_dir = os.path.join(out_dir, "perf")
            print(
                "[perf] capture-live -C {} → {}".format(args.perf_cpus, perf_dir),
                flush=True,
            )
            perf_proc = start_perf_capture_live(
                args.perf_cpus,
                perf_dir,
                freq=args.perf_freq,
                call_graph=args.perf_call_graph,
            )

        with ThreadPoolExecutor(max_workers=args.concurrency) as ex:
            futs = [
                ex.submit(
                    worker_loop,
                    args,
                    conf_bytes,
                    results,
                    lock,
                    counter,
                    ns_shares[i] if ns_shares else None,
                    overflow if ns_shares else None,
                )
                for i in range(args.concurrency)
            ]
            end = time.perf_counter() + args.duration
            while time.perf_counter() < end and not _stop.is_set():
                time.sleep(0.2)
            _stop.set()
            for f in as_completed(futs):
                try:
                    f.result()
                except Exception as e:
                    print("worker error: {}".format(e), file=sys.stderr)
    finally:
        # 必须在 post 清理前停 perf，避免把 DEL/删 ns 采进去
        if perf_proc is not None:
            print("[perf] 停止 capture-live（生成 on/off SVG）...", flush=True)
            stop_perf_capture_live(perf_proc)
            perf_proc = None

    wall = time.perf_counter() - t_wall0
    print("[bench] 结束（wall={:.2f}s）".format(wall), flush=True)

    # 统一 DEL iface + 删 ns（含预创建未用完的空 ns）
    leftover_ns = []
    with lock:
        for r in results:
            if r.get("ns"):
                leftover_ns.append((r.get("cid"), r["ns"]))
    used_ns = {ns for _, ns in leftover_ns}
    if leftover_ns:
        print("[post] 统一清理 {} 个已配置 netns ...".format(len(leftover_ns)))
        for cid, ns in leftover_ns:
            if args.mode == "cni":
                cni_del_ipvlan(
                    args.cni_bin, conf_bytes, cid, "/var/run/netns/" + ns, args.ifname
                )
            else:
                netlink_del_ipvlan(ns, args.ifname)
            delete_netns(ns)
    if pre_ns:
        unused = [item for item in pre_ns if item["ns"] not in used_ns]
        if unused:
            print("[post] 销毁未使用预创建 {} 个 netns ...".format(len(unused)))
            for item in unused:
                delete_netns(item["ns"])
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
    if precreate_n:
        print("  precreate: {:.1f} ms ({} ns, 不计入 wall)".format(precreate_ms, precreate_n))
    print("  ok/fail:  {}/{}".format(len(ok), len(fail)))
    if precreate_n and overflow[0]:
        print("  overflow: {} (现场新建 netns)".format(overflow[0]))
    print("  throughput: {:.2f} ADD/s".format(tps))
    if not precreate_n or overflow[0]:
        # 有现场新建时 netns 阶段有数据；纯预创建且无溢出则全是 0，略过
        if any(v > 0 for v in netns_ms) or not precreate_n:
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
            "master": master,
            "subnet": args.subnet,
            "cni_bin": args.cni_bin if args.mode == "cni" else None,
            "with_lo": args.with_lo,
            "cleanup_each": args.cleanup_each,
            "precreate_netns": precreate_n,
            "perf_cpus": args.perf_cpus,
            "perf_freq": args.perf_freq if args.perf_cpus else None,
            "perf_call_graph": args.perf_call_graph if args.perf_cpus else None,
            "data_dir": data_dir if args.mode == "cni" else None,
        },
        "wall_s": wall,
        "precreate_ms": precreate_ms if precreate_n else None,
        "overflow_create_ns": overflow[0] if precreate_n else None,
        "perf_dir": perf_dir,
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
