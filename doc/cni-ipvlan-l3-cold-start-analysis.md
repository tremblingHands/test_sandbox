# CNI ipvlan-l3 沙箱冷启动性能分析

## 1. 文档概述

### 1.1 背景

在 bridge CNI + cgroup v2 工作点下，同配置冷启动已到 `cri.sandbox.run` Avg **~3.36s** / P95 **~3.71s**，其中 `cni.setup` 仅 **~111ms**（见 `doc/sandbox-cold-start-bottleneck-analysis.md` §8.6）。为验证「去掉 bridge / 无 veth 对」能否进一步压低配网，将业务网切到 **ipvlan mode l3**，并在同 worker / 同绑核条件下复测。

**结论先行**：ipvlan-l3 **未能**改善端到端冷启动；瓶颈从「NewContainer / bbolt」重新回到 **CNI**。基线 `cni.setup` Avg **~6.73s**（约占 run **81%**），端到端 **~8.3s** / P95 **~11.1–11.4s**。注释 rename `netdev_info` 后（§3.3）run Avg **~6.81s**、setup **~5.90s**；内置 loopback 端到端几乎无收益。containerd 配网路径对 bridge/ipvlan **相同**，差异在插件与 netlink（§4.6）；单次 ipvlan ADD 约 **5～6 次 RTNL 写**（§4.4），高并发下全局串行排队；仍远慢于 bridge+v2（setup ~111ms）。上游 7.2 **无**并行建链红利；tgt_net 查重名可支撑免 rename，但须改插件（§4.5）。

### 1.2 数据来源

| 类型 | 路径 |
|------|------|
| 结果根目录（基线） | `profile/ipvlan-l3-containerd-1-4_workers-cores-128-255_workers-nums-128_sandbox-0-255/` |
| 关 rename INFO 对照 | `..._disable-printk/`（§3.3；须 `proc_count=128`） |
| TRACE 汇总 | `.../profile` |
| pprof | `.../pprof/`（含 `pprof_analysis.txt`） |
| perf | `.../perf/`（containerd 核 1–4 on/off-CPU） |
| resources | `.../resources/`（`report.md` / `summary.json` / `metadata.json`） |

采集入口：`scripts/multi_single_cold_start.sh`（`--profile --pprof --perf --resources`）。

### 1.3 相关文档

| 文档 | 关系 |
|------|------|
| `doc/sandbox-cold-start-bottleneck-analysis.md` | 总瓶颈阶梯；§8.6 为 bridge+v2 对照基线 |
| `doc/cni-bridge-network-analysis.md` | bridge / host-local / loopback 行为与 RTNL 路径；与本文 **§4.6** 对照 |
| `doc/sandbox-ready-and-startup-latency.md` | Ready / 启动时延语义 |
| `/home/nathan/linux-upstream-v1` | 上游 7.2 对照；ipvlan/RTNL 可用性见本文 **§4.5** |
| `/home/nathan/containerd`、`/home/nathan/plugins` | CRI / go-cni / bridge·ipvlan 源码；差异表见 **§4.6** |

---

## 2. 压测配置

### 2.1 环境与绑定

| 项 | 值 |
|----|-----|
| 主机 | HM70，aarch64，内核 **5.10.229+debug+** |
| containerd | v2.3.0（shim-exec-split） |
| runc | 1.4.3（含本地 TRACE / cgroup misc 改动） |
| Workers | **128**（CPU **128–255**，NUMA 1） |
| containerd CPU | **1–4** |
| 沙箱 CPU | `--cpuset-cpus 0-255`，`--cpuset-mems 0-1` |
| 时长 / 预配置 | `--duration 60`，`--preconfig 50` |
| 时间戳（resources） | 2026-07-22T00:05:34 |

### 2.2 CNI 配置（`/etc/cni/net.d/10-mynet.conf`）

```json
{
  "cniVersion": "0.3.1",
  "name": "mynet",
  "type": "ipvlan",
  "master": "eth0",
  "mode": "l3",
  "ipam": {
    "type": "host-local",
    "subnet": "10.0.0.0/12",
    "routes": [
      { "dst": "0.0.0.0/0" }
    ]
  }
}
```

| 字段 | 含义 |
|------|------|
| `type: ipvlan` | 执行 `/opt/cni/bin/ipvlan` |
| `master: eth0` | 以宿主机 `eth0` 为 ipvlan 父设备 |
| `mode: l3` | L3 模式（按 IP 路由，无 L2 广播域） |
| `ipam: host-local` | 本机分配，子网 `10.0.0.0/12` |

CRI 默认仍会并行挂 **loopback**（`UseInternalLoopback=false` 时走 CNI `loopback` 插件），见 bridge 分析文档 §3。

---

## 3. 总体结果

### 3.1 端到端延迟

| 来源 | 指标 | 数值 |
|------|------|------|
| resources | 总沙箱数 | **1004** |
| resources | 窗口 / 吞吐（约） | ~67s → **~15 沙箱/s** |
| resources | P50 / P95 / P99 | **8199 / 11075 / 12222 ms** |
| TRACE | `cri.sandbox.run` Cnt | **355**（折叠样本；读 Avg/分位） |
| TRACE | Avg / P50 / P95 / P99 | **8.30s / 8.35s / 11.40s / 12.68s** |

TRACE 与 resources 分位一致，端到端可信。

### 3.2 阶段拆解（TRACE）

```text
cri.sandbox.run ≈ 8.30s
├── cni.setup_pod_network     6.73s   (~81%)  ← 绝对主头
│     ├── ipvlan              ~5.9–7.5s
│     └── loopback            ~2.1–2.7s（并行，墙钟≈取 max）
├── container.NewTask         207ms   (~2.5%)
├── client.NewContainer        78ms
├── client.task.Start          （数十 ms 量级）
└── metadata.*（lease/Create/Update）  多为十余～数十 ms
```

| Span | Cnt | Avg | P50 | P95 | 约占 run |
|------|-----|-----|-----|-----|----------|
| `cri.sandbox.run` | 355 | **8.30s** | 8.35s | 11.40s | 100% |
| `cni.setup_pod_network` | 421 | **6.73s** | 6.98s | 9.53s | **~81%** |
| `cni.plugin.ipvlan`（树内） | 209 | **5.90s** | 6.04s | 7.60s | — |
| `cni.plugin.ipvlan`（独立林） | 212 | **7.51s** | 7.50s | 10.12s | — |
| `cni.plugin.loopback`（树内） | 293 | **2.72s** | 2.74s | 5.60s | — |
| `cni.plugin.loopback`（独立林） | 104 | **2.07s** | 1.80s | 3.89s | — |
| `client.NewContainer` | 418 | **77.7ms** | 21.6ms | 327ms | ~1% |
| `container.NewTask` | 377 | **207ms** | 137ms | 634ms | ~2.5% |
| `shim.runc.create` | 377 | **127ms** | 93.3ms | 356ms | — |
| `shim.cgroup.load` | 377 | **0.36ms** | — | — | — |
| `runc.create`（合并） | 987 | **102ms** | 69.4ms | 247ms | — |
| `runc.cgroup.apply` | 987 | **3.73ms** | 2.95ms | 8.55ms | — |
| `runc.init.sync` | 987 | **66.2ms** | 40.2ms | 158ms | — |

> **Cnt 说明**：并行 attach / journal 折叠会导致 ipvlan 与 loopback、树内与独立林 Cnt 不一致。读 **Avg + `cni.setup` 总墙钟** 即可，不必纠结绝对计数。

### 3.3 注释 `dev_change_name`/`netdev_info` 后对照（128 worker）

数据目录：`profile/ipvlan-l3-containerd-1-4_workers-cores-128-255_workers-nums-128_sandbox-0-255_disable-printk/`  
同配置 **128 workers**（勿与误跑的 256 worker 中间结果混淆）。  
内核提交：`7632b645eab4`（注释 `netdev_info("renamed from %s")`），已装载复测（~12:07）。

| 指标 | 关前（§3.1 基线） | **关后** | 变化 |
|------|-------------------|----------|------|
| resources P50 / P95 | 8199 / 11075 ms | **7671 / 9868 ms** | P95 **约 −11%** |
| 总沙箱数（~60s 窗） | ~1004 | **~1087** | 吞吐略升 |
| `cri.sandbox.run` Avg | **8.30s** | **6.81s** | **约 −18%** |
| `cni.setup` Avg | **6.73s** | **5.90s** | **约 −12%** |
| ipvlan（树内 / 独立林 Avg） | 5.90s / 7.51s | 6.48s / **5.36s** | 林侧更好；树内 Cnt 较少有噪声 |
| loopback Avg | ~2.7s | **~2.4–2.6s** | 略降或持平 |
| NewContainer / NewTask | 78ms / 207ms | 39ms / 151ms | 仍非主头 |

关后 `cni.setup` 仍约占 run 的 **~87%**，阶段结构未变。

**机制侧（perf / 日志）**：

| 信号 | 关前 | 关后 |
|------|------|------|
| on-CPU `pl011` / `printk` / `netdev_info` | ~2.8–2.9% | **0%** |
| on-CPU `dev_change_name` / `rtnl_setlink` | ~3%（含打印） | **≈0%** |
| 测试窗 kernel `renamed from` | 大量 | **0** |

解读：去掉 rename 路径 INFO→串口放大后，持锁变短、排队略松，端到端有一截收益；**主瓶颈仍是 ipvlan+loopback 的 RTNL 争用**。下一步优先 **内置 loopback**（§8）。

### 3.4 与 bridge + cgroup v2（总分析文档 §8.6）对照

同配置：128 workers、containerd 绑核 1–4、`--duration 60`、内核 5.10。

| Span | ipvlan-l3（本轮） | bridge + cgroup v2（§8.6） | 差值 |
|------|------------------|---------------------------|------|
| `cri.sandbox.run` | **8.30s** | **3.36s** | **+~5s** |
| `cni.setup` | **6.73s** | **111ms** | **~60×** |
| `client.NewContainer` | **78ms** | 444ms | 本轮更轻 |
| `container.NewTask` | **207ms** | 165ms | 同量级 |
| `runc.init.sync` | **66ms** | ~0.9s（v1 细粒度树）/ v2 路径已轻 | 健康 |
| `runc.cgroup.apply` | **3.7ms** | **25.5ms** | 健康 |

**解读**：端到端回退几乎全部来自 **CNI**；元数据 / NewTask / runc / cgroup **不是**本轮主因。非 CNI 阶段「变轻」更可能是 CNI 拖慢全局节奏后，单位时间完成的沙箱变少，对 bbolt / mount 的并发争用下降（见 §5）。

---

## 4. CNI 细拆

### 4.1 并行挂网模型

CRI `setup_serially = false` 时走 `cni.attach_networks_parallel`：

- 网络 A：业务网 → **`cni.plugin.ipvlan`**
- 网络 B（`use_internal_loopback=false`）：默认 loopback → **`cni.plugin.loopback`**
- `use_internal_loopback=true`：不挂 CNI lo；`setupPodNetwork` 内先 **`bringUpLoopback`**，再只 Setup 业务网（§4.4.2）

默认并行时：`cni.setup_pod_network` 墙钟 ≈ **max(ipvlan, loopback) + 调度/收尾**。本轮（基线）ipvlan 更长，故 setup ≈ 6–7s；loopback 仍是 **2s+** 的第二段重载。内置 lo 后墙钟仍由 ipvlan 主导（§8）。

### 4.2 ipvlan L3 为何没有「绕开」全局锁

相对 bridge 的预期收益：

| 预期 | 本轮结果 |
|------|----------|
| 无 veth 对、少一层 L2 | **墙钟未受益** |
| 无 bridge 转发 / 无 iptables masq | 未见 xtables 主导；**主耗时仍在建网** |
| 共用 `eth0` master | 高并发下大量 ipvlan slave 仍挤在同一条 **RTNL / netlink** 路径 |

ipvlan ADD 热路径仍包括：建链、rename、配地址与路由（代码级清单见 **§4.4**）。这些操作与 bridge 一样依赖内核 **RTNL 全局串行**（见总分析文档 §7 / §16.5）。换插件类型 **没有改变**「高并发建网要抢全局 netlink」这一本质。

本轮 CNI Avg（~6.7s）与早期「bridge + printk 开」时 CNI ~5–6s **同量级**，说明瓶颈类属回归到配网争用，而非 ipvlan 独有的用户态逻辑。配置与 netlink 逐步对照见 **§4.6**。

### 4.3 host-local

仍使用 `10.0.0.0/12` + host-local。本轮 TRACE 上 IPAM 未单独露出为数秒级 span；主头在插件级 ipvlan/loopback。仍建议保持 `by_id` 目录干净、旁路索引可用，避免 Walk 回潮叠加在 RTNL 争用之上。

`ipam.ExecAdd("host-local", …)` 主要是文件系统上的 IP 分配（目录/锁文件），**一般不发 RTNL**；RTNL 写操作集中在 ipvlan 插件自身的 `createIpvlan` + `ConfigureIface`（§4.4）。

### 4.4 ipvlan ADD 路径上的 RTNL 操作（代码级）

源码位置：

| 组件 | 路径 |
|------|------|
| CRI 配网入口 | `/home/nathan/containerd/internal/cri/server/sandbox_run.go` → `setupPodNetwork` |
| 内置 lo | `…/sandbox_run_linux.go` → `bringUpLoopback` |
| ipvlan 插件 | `/home/nathan/plugins/plugins/main/ipvlan/ipvlan.go` |
| rename 封装 | `/home/nathan/plugins/pkg/ip/link_linux.go` → `RenameLink` / `RandomVethName` / `DelLinkByName` |
| 配 IP/路由 | `/home/nathan/plugins/pkg/ipam/ipam_linux.go` → `ConfigureIface` |

用户态统一经 `github.com/vishvananda/netlink` → netlink socket → 内核 `rtnetlink`；**改链路 / 地址 / 路由**的消息在内核持 **`rtnl_mutex`**（火焰图：`rtnetlink_rcv` / `mutex_lock` / `mutex_spin_on_owner`）。

#### 4.4.1 调用总览

```text
containerd setupPodNetwork
  ├─ [use_internal_loopback=true] bringUpLoopback
  │     LinkByName("lo") + LinkSetUp(lo)          // 容器 ns；串行，在业务网之前
  └─ go-cni Setup → exec /opt/cni/bin/ipvlan
        cmdAdd
          ├─ createIpvlan
          │     LinkByName(master)                 // host：取 parent index
          │     RandomVethName()                   // 仅字符串，无 RTNL
          │     LinkAdd(ipvlan, Name=tmp, NsFd)    // NEWLINK → 容器 ns
          │     RenameLink(tmp → eth0)             // LinkByName + LinkSetName
          │     LinkByName(eth0)                   // 取 MAC
          ├─ ipam.ExecAdd(host-local)              // 通常无 RTNL
          └─ netns.Do → ConfigureIface
                LinkByName(eth0)
                AddrAdd × N
                LinkSetUp(eth0)
                RouteAddEcmp × M                   // 本机 conf 通常 M=1
```

`use_internal_loopback=false`（默认）时：不走 `bringUpLoopback`，改为并行 exec `/opt/cni/bin/loopback`（其内部亦为 `LinkByName("lo")` + `LinkSetUp`），与 ipvlan 同时抢 RTNL。

#### 4.4.2 containerd：`bringUpLoopback`（内置 lo）

`setupPodNetwork` 在调用 go-cni **之前**：

```go
// sandbox_run.go
if c.config.UseInternalLoopback {
    err := c.bringUpLoopback(path)  // path = sandbox NetNS
}
```

```go
// sandbox_run_linux.go
func (c *criService) bringUpLoopback(netns string) error {
    return ns.WithNetNSPath(netns, func(_ ns.NetNS) error {
        link, err := netlink.LinkByName("lo")
        if err != nil { return err }
        return netlink.LinkSetUp(link)
    })
}
```

| 调用 | netns | RTNL | 说明 |
|------|-------|------|------|
| `LinkByName("lo")` | 容器 | 读 | |
| `LinkSetUp(lo)` | 容器 | **写** | 与业务网串行；TRACE 上可表现为 `cni.setup` > `cni.plugin_setup` |

#### 4.4.3 `cmdAdd` 骨架

```go
// ipvlan.go
func cmdAdd(args *skel.CmdArgs) error {
    n, cniVersion, err := loadConf(args, false)
    netns, err := ns.GetNS(args.Netns)
    ipvlanInterface, err := createIpvlan(n, args.IfName, netns)  // IfName 通常 eth0

    r, err := ipam.ExecAdd(n.IPAM.Type, args.StdinData)         // host-local
    result, err = current.NewResultFromResult(r)
    // … 把 IP 绑到 interface 0，填 result.Interfaces …

    return netns.Do(func(_ ns.NetNS) error {
        _, _ = sysctl.Sysctl("net/ipv4/conf/"+args.IfName+"/arp_notify", "1")  // /proc，非 RTNL
        _, _ = sysctl.Sysctl("net/ipv6/conf/"+args.IfName+"/ndisc_notify", "1")
        return ipam.ConfigureIface(args.IfName, result)
    })
}
```

#### 4.4.4 `createIpvlan`：建链 + rename（写路径核心）

```go
// ipvlan.go — createIpvlan（LinkContNs=false 时，本机默认）
m, err = netlinksafe.LinkByName(conf.Master)   // host eth0

tmpName, err := ip.RandomVethName()            // "veth" + 随机 hex；注释：避 NM，非建 veth

linkAttrs.Name = tmpName
linkAttrs.ParentIndex = m.Attrs().Index
linkAttrs.Namespace = netlink.NsFd(int(netns.Fd()))

netlink.LinkAdd(&netlink.IPVlan{LinkAttrs: linkAttrs, Mode: mode})

netns.Do(func(_ ns.NetNS) error {
    ip.RenameLink(tmpName, ifName)             // → eth0
    contIpvlan, err := netlinksafe.LinkByName(ipvlan.Name)
    ipvlan.Mac = contIpvlan.Attrs().HardwareAddr.String()
    return nil
})
```

```go
// pkg/ip/link_linux.go
func RenameLink(curName, newName string) error {
    link, err := netlinksafe.LinkByName(curName)
    if err == nil {
        err = netlink.LinkSetName(link, newName)  // → 内核 dev_change_name
    }
    return err
}
```

插件注释：

```go
// due to kernel bug we have to create with tmpname or it might
// collide with the name on the host and error out
```

本机验证见 §6.4.2：host 侧 `LinkAdd(Name=eth0)` 会在 `__rtnl_newlink` 用 **sock_net=host** 查名 → 撞物理 eth0 → `-EEXIST`；临时名 + 容器内 rename **必要**。

| # | 调用 | netns | 内核侧 | 说明 |
|---|------|-------|--------|------|
| 1 | `LinkByName(master)` | **host** | 读 | 取 parent index |
| 2 | `LinkAdd(ipvlan)` | sock=host，`IFLA_NET_NS_FD`→容器 | **NEWLINK，持锁** | 临时名 `veth%x`，parent=host eth0 |
| 3 | `LinkByName(tmp)` | **容器** | 读 | rename 前查找 |
| 4 | `LinkSetName(→eth0)` | **容器** | **SETLINK / `dev_change_name`，持锁** | 曾触发 `netdev_info`→pl011（§6.3） |
| 5 | `LinkByName(eth0)` | **容器** | 读 | 取 MAC |

#### 4.4.5 `ConfigureIface`：地址 / UP / 路由

仍在 **容器 netns**（`cmdAdd` 的 `netns.Do`）：

```go
// pkg/ipam/ipam_linux.go
func ConfigureIface(ifName string, res *current.Result) error {
    link, err := netlinksafe.LinkByName(ifName)
    for _, ipc := range res.IPs {
        // … IPv6 时可能 sysctl disable_ipv6 / keep_addr_on_down（非 RTNL）…
        netlink.AddrAdd(link, &netlink.Addr{IPNet: &ipc.Address})
    }
    netlink.LinkSetUp(link)
    for _, r := range res.Routes {
        netlink.RouteAddEcmp(&netlink.Route{
            Dst: &r.Dst, LinkIndex: link.Attrs().Index, Gw: gw, ...
        })
    }
    return nil
}
```

本机典型 conf（1×IPv4 + 1×默认路由 `0.0.0.0/0`）：

| # | 调用 | RTNL |
|---|------|------|
| 6 | `LinkByName(eth0)` | 读 |
| 7 | `AddrAdd` ×1 | **写** |
| 8 | `LinkSetUp(eth0)` | **写** |
| 9 | `RouteAddEcmp` ×1 | **写** |

#### 4.4.6 DEL（冷启动次要，仍抢同一把锁）

```go
// ipvlan.go cmdDel
ns.WithNetNSPath(args.Netns, func(_ ns.NetNS) error {
    return ip.DelLinkByName(args.IfName)  // LinkByName + LinkDel
})
```

边建边清时，`LinkDel` 与 ADD 的 NEWLINK/SETLINK 等 **共用 `rtnl_mutex`**。

#### 4.4.7 单次成功 ADD 的 RTNL **写**操作清单（本机）

| 顺序 | 来源 | 写操作 |
|------|------|--------|
| 0 | containerd `bringUpLoopback`（若开启） | `LinkSetUp(lo)` |
| 1 | `createIpvlan` | `LinkAdd`（临时名 ipvlan） |
| 2 | `createIpvlan` | `LinkSetName`（→ eth0） |
| 3 | `ConfigureIface` | `AddrAdd` |
| 4 | `ConfigureIface` | `LinkSetUp(eth0)` |
| 5 | `ConfigureIface` | `RouteAddEcmp` |

外加若干 `LinkByName` 读。成功路径约 **5～6 次写**抢全局 RTNL；128 worker 同时 ADD → 排队，墙钟到数秒。

与 perf 对齐：off-CPU 上 `ipvlan` 柱大、`rtnetlink`/`mutex_lock` 帧仅约 **~3%**——多数时间在 **等锁 / 等 netlink 回包（futex）**，而不是一直跑在 `rtnl_*` 符号上。

#### 4.4.8 与「能否减少 RTNL」的对应

| 操作 | 能否去掉 / 减弱 |
|------|-----------------|
| `LinkAdd` | **否**（建网本体） |
| `LinkSetName` | **5.10** 现 host 插件路径 **否**（§6.4.2）；**上游 7.2** 起 CREATE\|EXCL 在 **tgt_net** 查重名，具备「目标 ns 内直接 eth0 + LINK_NETNSID」免 rename 的内核前提（§4.5），需改插件并复测 |
| `AddrAdd` / `LinkSetUp` / `RouteAdd` | 可尝试合并 netlink 消息；单次次数有限，难单独把数秒压到百毫秒 |
| `bringUpLoopback` | 已开；仍 1 次 `LinkSetUp(lo)`，且在 ipvlan **前串行**（实测端到端几乎无收益，§8） |
| 读 `LinkByName(master)` | 可缓存 ifindex，收益小 |
| **升上游内核 alone** | **不能**自动把 setup 打到 bridge ~100ms；无并行建链 / 批量 NEWLINK（§4.5） |
| **降并发 / 换 bridge+v2** | 不减单次次数，但减排队或换已验证更快的工作点 |

### 4.5 上游内核（linux-upstream-v1 / 7.2）对当前场景的可用性

对照树：

| 树 | 版本 | 路径 |
|----|------|------|
| 本机运行 / 分析基线 | **5.10.229+debug+** | `/home/nathan/linux` |
| 上游对照 | **7.2.0-rc4** | `/home/nathan/linux-upstream-v1` |

**结论先行**：上游 **没有**「高并发建 ipvlan slave 不再抢全局 RTNL / 批量建链」类特性，**不能指望升内核后 `cni.setup` 自动接近 bridge ~111ms**。与冷启动相关的实质变化主要是 **NEWLINK 重名查找网**，为「去掉 rename」提供内核前提（仍须改 CNI 插件并复测）。

#### 4.5.1 与建链相关的实质变化：`CREATE|EXCL` 按目标 netns 查名

**5.10**（本机已实测，§6.4.2）：host socket 发 NEWLINK、`Name=eth0` 时，用 **`sock_net`（host）** 做存在性检查 → 撞物理 eth0 → `-EEXIST`。

**上游**（2025-02，`ec061546c6cf` *rtnetlink: Lookup device in target netns when creating link*）：

```c
/* net/core/rtnetlink.c — 创建路径 */
/* When creating, lookup for existing device in target net namespace */
device_net = (nlh->nlmsg_flags & NLM_F_CREATE) &&
             (nlh->nlmsg_flags & NLM_F_EXCL) ?
             tgt_net : net;
```

即：带 `NLM_F_CREATE|NLM_F_EXCL` 时，ifname 冲突在 **`tgt_net`（容器 netns）** 内判断，而不是默认按发送 netlink 的 host 网。

同时 ipvlan `newlink` 用 `rtnl_newlink_link_net(params)` 在 **link_net** 解析 parent（`IFLA_LINK` / `IFLA_LINK_NETNSID`），host 上的物理 eth0 仍可正确作为 master：

```c
/* drivers/net/ipvlan/ipvlan_main.c — 上游 */
int ipvlan_link_new(struct net_device *dev, struct rtnl_newlink_params *params, ...)
{
        struct net *link_net = rtnl_newlink_link_net(params);
        ...
        phy_dev = __dev_get_by_index(link_net, nla_get_u32(tb[IFLA_LINK]));
```

| 项 | 说明 |
|----|------|
| 能做什么 | 在 **7.2+** 上改插件：目标 netns 内 `Name=eth0` + `IFLA_LINK`/`LINK_NETNSID`→host eth0，**理论上少 1 次 `LinkSetName`** |
| 不能自动得到 | 现成 CNI ipvlan **仍是** `RandomVethName` + `RenameLink`；升内核 alone 无用户态收益 |
| 预期收益 | 少一次 RTNL 写；**128 worker 下很难单独把数秒压到百毫秒** |

配套整理：`cf517ac16ad9` *Use link/peer netns in newlink()*（`rtnl_newlink_link_net` / `peer_net` 回退逻辑），属 API 清晰化，与上条同一方向。

#### 4.5.2 上游 ipvlan 其它改动（与冷启动弱相关）

| 方向 | 例（`git log` on `drivers/net/ipvlan/`） | 对冷启动 |
|------|------------------------------------------|----------|
| 数据面锁 | `d3ba32162488` addrs_lock per-port；组播队列减 spin | **几乎无关**（跑包 / 地址事件，非 CREATE 热路径） |
| 正确性 / 事件 | bonding 事件、L3S、UAF、header linear、NETDEV_DOWN 等 | 稳定，不减 RTNL 次数 |
| API | `newlink` 参数打包、`ida_alloc_*` 替代 `ida_simple_*` | 建链语义同构：仍是 `register_netdevice` → ida → `netdev_upper_dev_link` → `ipvlan_set_port_mode` |

上游 `ipvlan_link_new` **仍在全局设备 RTNL 下串行**；fib/nexthop/ethtool 等路径上的 **per-netns RTNL** **不**覆盖 ipvlan NEWLINK。

#### 4.5.3 对当前场景的建议

1. **不要指望**「升到 7.2 → ipvlan 冷启动自动接近 bridge+v2」。  
2. **若坚持 ipvlan且愿意改插件**：在 upstream 树上验证「目标 ns 内直接 eth0 + LINK_NETNSID」能否稳定免临时名（落地 §8 P3）。  
3. **端到端要快**：仍优先 bridge 调优工作点或降并发。  
4. 升内核若只为 ipvlan：主要红利是 **可尝试少 rename** + 数据面/正确性修补，**不是** RTNL 并行化。

### 4.6 containerd / CNI：bridge vs ipvlan 配置与 netlink 差异

源码位置：

| 组件 | 路径 |
|------|------|
| CRI 配网 | `/home/nathan/containerd/internal/cri/server/sandbox_run.go` → `setupPodNetwork` |
| CNI Load 选项 | `…/service_linux.go` → `cniLoadOptions` |
| bridge 插件 | `/home/nathan/plugins/plugins/main/bridge/bridge.go` |
| ipvlan 插件 | `/home/nathan/plugins/plugins/main/ipvlan/ipvlan.go` |
| 共用配 IP | `/home/nathan/plugins/pkg/ipam/ipam_linux.go` → `ConfigureIface` |
| veth 辅助 | `/home/nathan/plugins/pkg/ip/link_linux.go` → `SetupVeth` / `makeVethPair` |

#### 4.6.1 containerd 层：路径相同，只换 conf / 二进制

```text
RunPodSandbox
  → setupPodNetwork
       → [可选] bringUpLoopback          // use_internal_loopback
       → netPlugin.Setup / SetupSerially // go-cni
            → 按已 Load 的 networks 并行/串行 ADD
                 networks[0] = lo（WithLoNetwork，除非 internal）
                 networks[1] = conf_dir 第一份 conf → type 决定插件
```

```go
// service_linux.go
func (c *criService) cniLoadOptions() []cni.Opt {
    if c.config.UseInternalLoopback {
        return []cni.Opt{cni.WithDefaultConf}
    }
    return []cni.Opt{cni.WithLoNetwork, cni.WithDefaultConf}
}
```

| 项 | bridge | ipvlan |
|----|--------|--------|
| `setupPodNetwork` / go-cni Setup | **相同** | **相同** |
| `CNI_PATH` / `CNI_NETNS` / `CNI_IFNAME=eth0` | **相同** | **相同** |
| `WithLoNetwork` / internal lo | **相同机制** | **相同机制** |
| `bin_dirs` 里执行的二进制 | `/opt/cni/bin/bridge` | `/opt/cni/bin/ipvlan` |
| stdin JSON | `type: bridge` + bridge 字段 | `type: ipvlan` + master/mode |
| IPAM | 通常同为 `host-local`（本机） | 同左 |
| Result → `Interfaces["eth0"]` 取 Pod IP | **相同**（`defaultIfName`） | **相同** |

**结论**：containerd **不**因 bridge/ipvlan 分叉业务逻辑；差异几乎全部在 **CNI 配置 + 插件 ADD/DEL + 内核路径**。

#### 4.6.2 配置差异（本机 `/etc/cni/net.d/10-mynet.conf`）

**bridge（调优工作点示例）**：

```json
{
  "cniVersion": "0.3.1",
  "name": "mynet",
  "type": "bridge",
  "bridge": "cni0",
  "isGateway": true,
  "ipMasq": false,
  "ipam": { "type": "host-local", "subnet": "10.0.0.0/12", "routes": [{ "dst": "0.0.0.0/0" }] }
}
```

**ipvlan-l3（本文）**：

```json
{
  "cniVersion": "0.3.1",
  "name": "mynet",
  "type": "ipvlan",
  "master": "eth0",
  "mode": "l3",
  "ipam": { "type": "host-local", "subnet": "10.0.0.0/12", "routes": [{ "dst": "0.0.0.0/0" }] }
}
```

| 字段 | bridge | ipvlan |
|------|--------|--------|
| `type` | `bridge` | `ipvlan` |
| 上层设备 | 软件桥 `cni0`（可跨沙箱复用） | 物理/宿主 `master`（本机 eth0） |
| L2/L3 | 桥 + 网关（`isGateway`） | `mode: l2/l3/l3s` |
| `ipMasq` | 可选 per-sandbox iptables（本机调优为 false） | **无**（插件不解释该字段） |
| IPAM / routes | host-local + 默认路由 | **同结构** |

#### 4.6.3 插件 ADD 热路径对照（用户态）

**bridge `cmdAdd`**（`bridge.go`）：

```text
setupBridge / ensureBridge(cni0)     // 已存在则复用；否则 LinkAdd(type=bridge)
setupVeth(netns, br, ifName=eth0)
  └─ 容器 ns: LinkAdd(veth 对) → 容器端名=eth0；host 端移回 host ns
host: LinkSetMaster(hostVeth → cni0)
      LinkSetHairpin / LinkSetIsolated …
ipam.ExecAdd(host-local)
netns.Do → ConfigureIface(eth0)      // AddrAdd + LinkSetUp + RouteAdd*
[isGateway] ensureAddr(cni0, gw) …   // 网关地址多跨沙箱复用
[ipMasq] SetupIPMasq…                // iptables，非 RTNL
轮询 hostVeth OperUp（0/50/500/… ms sleep）
```

**ipvlan `cmdAdd`**（`ipvlan.go`，细节 §4.4）：

```text
createIpvlan
  LinkByName(master=eth0)            // host
  LinkAdd(ipvlan, Name=tmp, NsFd)    // 临时名，parent=eth0
  Rename → eth0                      // 容器 ns
ipam.ExecAdd(host-local)
netns.Do → ConfigureIface(eth0)
```

| 步骤 | bridge | ipvlan |
|------|--------|--------|
| 复用基础设施 | **`cni0` 跨沙箱复用** | 每沙箱在 **同一 phy eth0** 上新建 slave |
| 容器口 eth0 如何出现 | veth 创建时直接 `CNI_IFNAME` | **临时名 + `RenameLink`**（5.10 必要） |
| 挂上层 | `LinkSetMaster` → 桥端口 | `LinkAdd` 时 `ParentIndex` + 内核 `netdev_upper_dev_link` |
| 共用配 IP | **同一** `ConfigureIface` | **同一** |
| 额外 | STP/FDB、OperUp 等待、可选 masq | 无 STP；有 rename |

#### 4.6.4 netlink / RTNL 写操作差异（成功 ADD，本机典型 conf）

两边都经 `vishvananda/netlink` → 内核 `rtnetlink`，**同一把全局 `rtnl_mutex`**。

**ipvlan（约 5～6 次写，+ 可选 lo）**— 见 §4.4.7：

| # | 操作 | 内核侧（摘要） |
|---|------|----------------|
| 0 | `LinkSetUp(lo)`（internal） | 容器 lo UP |
| 1 | `LinkAdd(ipvlan)` | `ipvlan_link_new`：`register_netdevice` + upper_link + port/ida |
| 2 | `LinkSetName→eth0` | `dev_change_name` |
| 3–5 | `AddrAdd` / `LinkSetUp` / `RouteAdd` | 容器 eth0 配址 |

**bridge（每沙箱；不含首次建 cni0）**：

| # | 操作 | 内核侧（摘要） |
|---|------|----------------|
| — | `ensureBridge` 已存在 | 多为查桥，**无**新建 |
| 1 | `LinkAdd(veth)` | `veth_newlink`：**两次** `register_netdevice`（peer+本地） |
| 2 | ns 移动 / `LinkSetUp(hostVeth)` 等 | SETLINK / 改 ns（SetupVeth 路径） |
| 3 | `LinkSetMaster` | `do_set_master` → `br_add_if`（rx_handler、FDB、STP enable） |
| 4–6 | `ConfigureIface` | 与 ipvlan **相同**三类写 |
| ※ | 首次 `LinkAdd(bridge)` | `br_dev_newlink`（摊销到第一次） |
| ※ | `ensureAddr(cni0)` | 网关已在则轻；否则 `AddrAdd` on bridge |
| ※ | OperUp 轮询 | 多次 `LinkByName` **读** + **用户态 sleep**（可拉长墙钟，但不一定是「多持锁」） |

要点：

1. **次数上 bridge 往往不少于 ipvlan**（还多 veth 双端注册 + setmaster），因此「ipvlan 更慢」**不是**因为 netlink 调用更少。  
2. **结构上**：bridge 热路径是「veth 对 + 奴役进**复用的 cni0**」；ipvlan 是「在**共享物理 eth0** 上叠 slave + rename」。  
3. **调优杠杆不同**：bridge 曾靠关 STP `br_info`→串口、关 per-sandbox `ipMasq` 把临界区/附加成本砍短 → setup ~**111ms**；ipvlan 关 rename `netdev_info` 后仍数秒（§3.3），缺同等「一刀见血」。  
4. **未调优时** bridge CNI 也曾到 **~5–6s**（与 ipvlan 同量级），说明主矛盾是 **高并发 RTNL 排队 + 锁内放大**，而非「选了 ipvlan 类型」本身。

#### 4.6.5 内核路径一句话对照

| | bridge | ipvlan |
|--|--------|--------|
| NEWLINK kind | `veth`（+ 偶发 `bridge`） | `ipvlan` |
| 挂主设备 | `ndo_add_slave` → `br_add_if` | `ipvlan_link_new` 内 `netdev_upper_dev_link(phy, slave)` |
| 共享资源 | 软件桥 `cni0` + 每端口独立 veth | **同一 phy** 上的 ipvlan port / ida / 地址表 |
| 特有子系统 | STP、FDB、桥通知 | L3 NOARP / 地址哈希；**无 STP** |
| 历史锁内日志 | `br_set_state` → `br_info`（本机已关） | `dev_change_name` → `netdev_info`（本机已关） |

更细的内核展开见 `doc/cni-bridge-network-analysis.md` 与本文 §4.4；本节聚焦 **containerd 不分叉 + 插件/netlink 差异表**。

#### 4.6.6 与实测的对应

| 工作点 | `cni.setup` Avg | 含义 |
|--------|-----------------|------|
| bridge + 关 printk + `ipMasq:false` + cgroup v2 | **~111ms** | 排队被打穿 |
| ipvlan-l3 + 关 rename INFO | **~5.9s** | 仍卡在 RTNL 排队（slave@eth0 + rename） |
| bridge 早期（放大器开） | **~5–6s** | 与 ipvlan **同量级** |

因此：换 ipvlan **并未**减少 containerd 开销，也 **未**自动比「未调优 bridge」更轻；相对「已调优 bridge」回退，是因为 **插件/内核路径不同 + 调优不对等**，不是 go-cni 多跑了一层。

---

高并发下队头在 CNI 时：

1. 单位时间完成的 sandbox **变少** → 同时抢 **bbolt** 的写事务变少  
2. TRACE：`metadata.*.tx.wait` 多为 **十余～三十 ms**（对比 bridge 变差轮次的数百 ms～1s+）  
3. `runc` mounts / pivot / sync 落在 **数十 ms** 量级；`cgroup.apply` **~3.7ms**

因此：**不是 ipvlan「优化了」runc/cgroup**，而是 CNI 把全局节奏拖慢后，后面阶段排队变少。

资源侧也一致：

| 信号 | 观察 |
|------|------|
| load_1m | max **~114** |
| 上下文切换 | mean ~**400 万/s**，max ~**476 万/s** |
| containerd 核 (1–4) | 有可观 sys，但仍有明显 idle（在等插件/锁，不是纯打满） |
| worker / sandbox 核 | 大量 idle（算力未被端到端延迟用满） |
| goroutine（pprof 趋势） | 压测中从约 **2.4k → 8.7k**（堆在等 CNI/RPC） |

---

## 6. pprof / perf 辅证

### 6.1 containerd CPU pprof

`pprof_analysis.txt`（60s 采样，Total samples ≈ 27.45s）：

| 观察 | 含义 |
|------|------|
| `Syscall6` flat **~42%** | daemon 侧系统调用占比高（与等插件、读写、netlink 交互一致） |
| mutex 仍可见 `metadata.(*DB).Update` | 锁等待仍存在，但 TRACE 上 **非墙钟主头** |
| 几乎看不到 ipvlan 用户态符号 | CNI 是 **独立进程**，不在 containerd CPU profile 内 |

### 6.2 perf（绑核 1–4）— 有效采样（2026-07-22 10:49）

目录内 `perf/` 已更新为与 **`--duration 60`** 对齐的抓取（metadata：60s；off-CPU data ~**408MB**）。  
此前同目录曾混入一份 **30s 空采**（几乎无 `ipvlan` comm），不可用；以下均以更新后数据为准。

采集：`perf record -C 1-4`（on-CPU 99Hz；off-CPU sched + inject）。CNI 插件由 containerd **exec 继承 cpuset 1–4**，故 `-C 1-4` **可以**看到 `ipvlan` / `loopback`（不必误以为插件跑在别的核上）。

#### 6.2.1 Off-CPU（等什么）

`perf script -F comm` 与火焰图进程柱（约）：

| 进程 | 角色 | 约占比 / 量级 |
|------|------|----------------|
| containerd-shim | 沙箱生命周期 futex 等待 | **~63%**（整图最大柱） |
| **ipvlan** | 业务网插件睡眠 | **~23%**（~38.7M ms 加权） |
| **loopback** | 并行 lo 插件睡眠 | **~8%** |
| containerd | 等插件退出等 | ~5.5% |
| host-local | IPAM | 很小 |

与 RTNL 相关的 off-CPU 帧仍在，例如：

- `rtnetlink_rcv*` / `mutex_lock*` ~**3.3%**
- `loopback_net_init` → `register_netdev` → `rtnl_lock_killable` ~**0.5%**

ipvlan 进程侧可见 `runtime.usleep` / `runtime.futex`（Go 运行时 + 等 netlink），与「墙钟很长、多数时间不在跑」一致。

#### 6.2.2 On-CPU（跑什么）

核 1–4 上进程级约占比：

| 进程 | on-CPU 约占比 |
|------|----------------|
| runc / containerd / containerd-shim | 各约 **20–23%** |
| **ipvlan** | **~14%** |
| host-local | ~5.6% |
| loopback | ~5.4% |

采准之后 **ipvlan 在 on-CPU 上清晰可见**（对比空采时「图上没有 ipvlan」）。相对历史 bridge 热点仍更「薄」，但绝非零。

**ipvlan 进程内两条关键栈：**

1. **抢 RTNL 时自旋（占核等锁）**

```text
sendto → netlink_* → rtnetlink_rcv_msg
       → mutex_lock → mutex_spin_on_owner
```

全图 `mutex_spin_on_owner` ~**4.2%**；ipvlan 子树内约 **2%+**。拿不到 `rtnl_mutex` 时先 spin，再睡——故 top 上也能感到一点热。

2. **持锁 rename 时打串口（放大持锁）**

```text
rtnl_setlink → do_setlink → dev_change_name
  → netdev_info → printk → console_unlock → pl011_console_write
```

约 **~1.9% `pl011_console_write`**（连带 printk 链约 **~2.8–2.9%**）。  
对应 ipvlan 用临时名 `LinkAdd` 再 **rename 为 eth0** 时内核的 `netdev_info`——与 bridge 时代「锁内 printk→串口」同类放大器。

采样时本机：

```text
/proc/sys/kernel/printk = 7 4 1 7   → console_loglevel=7，INFO 会上串口
```

其它 on-CPU：`rtnl_newlink` / `ipvlan_link_new`、`ipvlan_addr_busy` / `ipvlan_find_addr`、地址/路由 notifier 等，份额小于上述两条。

#### 6.2.3 与「CPU 低但墙钟长」的统一解释

```text
墙钟 CNI ~数秒
  ├─ off-CPU：ipvlan + loopback 排队（RTNL / futex / usleep）← 主体积
  ├─ on-CPU：偶发持锁 → newlink / setlink(rename)
  │            └─ rename 时 netdev_info → pl011 拉长持锁
  └─ 争用者：mutex_spin 或继续睡 → TRACE 中 cni.setup 很长
```

| 现象 | 解释 |
|------|------|
| 相对 bridge，ipvlan `%CPU` 往往更低 | 无 veth/挂桥/等端口，临界区更薄 |
| 采准后 on-CPU 仍有 ~14% ipvlan | 锁内工作 + spin + printk 可见 |
| 旧 off-CPU 图没有 ipvlan | **空采/目录混用**；新数据 ~23% ipvlan |

读图时先点 **`ipvlan` / `loopback` 柱**，不要只看整图最大的 shim futex。

### 6.3 dmesg：满屏 `eth0: renamed from veth…` 的内核路径

压测时 `dmesg` 几乎被同一条 INFO 占满（本机采样约 **988/999** 条为该类）：

```text
eth0: renamed from vethcceade63
eth0: renamed from veth4a2f5d5a
...
```

**不是**在创建 Linux veth 设备；`veth%x` 只是 CNI 插件生成的**临时接口名字符串**（见下节）。

#### 6.3.1 内核打印点（`/home/nathan/linux`）

`net/core/dev.c` → `dev_change_name()`：

```c
ASSERT_RTNL();   /* 已持 rtnl_mutex */
memcpy(oldname, dev->name, IFNAMSIZ);
err = dev_get_valid_name(net, dev, newname);  /* 此处已把 dev->name 写成 eth0 */
...
if (oldname[0] && !strchr(oldname, '%'))
    netdev_info(dev, "renamed from %s\n", oldname);
```

因此日志前缀是**新名** `eth0:`，正文是**旧名** `veth…`。  
`netdev_info` 为 **KERN_INFO**（`define_netdev_printk_level(netdev_info, KERN_INFO)`）。

**本机源码改动（2026-07-22）**：上述 `netdev_info` 已在树内**注释掉**（`7632b645eab4`）。**128 worker 复测见 §3.3**（run/setup 下降，火焰图无 pl011）。

用户态改名经 rtnetlink：

```text
netlink.LinkSetName
  → RTM_SETLINK → do_setlink()          /* net/core/rtnetlink.c */
       if (ifi_index > 0 && ifname[0])
         → dev_change_name()
              → netdev_info → printk
              → console_unlock → pl011_console_write   /* console_loglevel 高时 */
```

与 §6.2.2 on-CPU 栈一致；**持锁打串口**会拉长 `rtnl_mutex` 临界区。

#### 6.3.2 谁触发：CNI ipvlan 临时名 → eth0

完整 ADD/RTNL 清单见 **§4.4**。此处只强调 rename 触发点：`createIpvlan()` 中：

```text
tmpName = RandomVethName()     // "veth" + 随机 hex（字符串，非建 veth）
LinkAdd(Name=tmpName, Namespace=容器 netns, type=ipvlan)
RenameLink(tmpName → args.IfName)   // 通常 eth0 → LinkSetName → 上面内核路径
```

`pkg/ip/link_linux.go` 中 `RandomVethName()` 注释写明：名字以 `veth` 开头是为让 NetworkManager 忽略，与网桥 veth 对无关。macvlan / vlan / tap 使用同一「临时名 + rename」模式。

---

### 6.4 是否一定要 rename？可以不 rename 吗？

| 需求 | 是否必须 |
|------|----------|
| 最终接口名是 **`eth0`** | **对本 CRI 路径基本必须**（go-cni 默认 `ifName=eth0`；containerd `selectPodIPs` 读 `Interfaces["eth0"]`） |
| 必须先 `veth*` 再 **rename** | **不是**硬性内核要求，是插件规避策略 |

#### 6.4.1 插件为何写成临时名

注释原文：

```go
// due to kernel bug we have to create with tmpname or it might
// collide with the name on the host and error out
```

历史问题：若建链时在 **host / init_net** 视角做名字唯一性检查，宿主机已有 `eth0`，再创建名为 `eth0` 会 `-EEXIST`。故先用几乎不冲突的 `veth%x`，进入容器 ns 后再改成 CNI `ifName`。

#### 6.4.2 本机实测：从宿主机直接建名为 `eth0` **不可行**

宿主机确有物理 `eth0`。在 **5.10.229** 上用与 CNI 相同的「host 侧 netlink + `netns <容器>`」方式验证：

```text
ip link add link eth0 name eth0 netns <ns> type ipvlan mode l3
→ RTNETLINK answers: File exists     # 失败

ip link add link eth0 name zztest1 netns <ns> type ipvlan mode l3
→ OK
ip netns exec <ns> ip link set zztest1 name eth0
→ OK   # 容器内 eth0 与宿主机 eth0 可并存
```

**原因不在「名字全局唯一」，而在 `__rtnl_newlink` 的查找网：**

```c
/* net/core/rtnetlink.c — net = sock_net(skb->sk)，即发 netlink 的命名空间 = 宿主机 */
dev = rtnl_dev_get(net, ..., ifname);   /* 用 ifname=eth0 在 HOST 上查找 */
if (dev) {
    if (nlh->nlmsg_flags & NLM_F_EXCL)
        return -EEXIST;                 /* 命中宿主机 eth0 → 直接失败 */
    ...
}
/* 后面才会用 IFLA_NET_NS_FD 得到 dest_net 并在容器里 register */
```

因此：即使目标 netns 里没有 `eth0`，只要 **在宿主机上发起**、且请求名是 `eth0`，就会撞上宿主机那块网卡。  
插件注释里的 “kernel bug / collide with the name on the host” **在本机成立**；临时名 + rename 是必要规避，不是多余步骤。

rename 能成功，是因为 `dev_change_name` 在**容器 netns** 内做名字唯一性检查——那里还没有 `eth0`，与宿主机 `eth0` 无关。完成后两边可以各有一个 `eth0`（不同 netns）。

#### 6.4.3 可选做法（修正）

| 方案 | 做法 | 本机结论 |
|------|------|----------|
| **A. 创建即 eth0（host netlink + netns fd）** | `Name=eth0` + `Namespace=容器`，去掉 rename | **不可行**（实测 `-EEXIST`，撞宿主机 eth0） |
| **B. 临时名 + rename（现状）** | `RandomVethName` → `RenameLink(eth0)` | **可行且必要**（当前插件路径） |
| **C. 保留临时名且不改成 eth0** | — | **不可行**（CRI 要 `Interfaces["eth0"]`） |
| **D. 减日志 / 压 console** | 关 INFO 上串口，或 `netdev_info`→`netdev_dbg` | **可行**；不改插件也能砍掉 pl011 放大 |
| **E. 其它建链路径（进阶）** | 目标 netns 内 NEWLINK、`IFLA_LINK_NETNSID` 指 host master；或升 **7.2+** 后利用 tgt_net 查重名直接 `Name=eth0`（§4.5） | **5.10**：host 侧 Name=eth0 不可行。**上游**：内核前提已改善；插件未改、**未在本环境验证** |

结论：**在现有「5.10 + 宿主机执行 ipvlan 插件」模型下，rename 去不掉**；优化应优先 **D（printk/console）**。免 rename 需 **升内核 + 改插件**（§4.5），不能单靠删 rename。

---

### 6.5 多网卡：容器内已有 eth0 时再建网 / RunPodSandbox 能否拿到 IP

#### 6.5.1 go-cni 正常多网卡命名

`WithLoNetwork` + `loadFromConfDir`（`max_conf_num` 控制业务网个数）：

```text
networks[0] = loopback      ifName = "lo"
networks[1] = 第 1 个 conf  ifName = "eth0"   ← getIfName("eth", 0)
networks[2] = 第 2 个 conf  ifName = "eth1"   ← getIfName("eth", 1)
...
```

每个 network 的 `CNI_IFNAME` 不同，**第二张业务网不会再叫 eth0**。  
本机默认 `max_conf_num = 1` → 只有 `lo` + 一张业务网 `eth0`。

#### 6.5.2 RunPodSandbox 如何取 IP

`internal/cri/server/sandbox_run.go` → `setupPodNetwork`：

```go
if configs, ok := result.Interfaces["eth0"]; ok && len(configs.IPConfigs) > 0 {
    sandbox.IP, sandbox.AdditionalIPs = selectPodIPs(..., configs.IPConfigs, ...)
    return nil
}
return fmt.Errorf("failed to find network info for sandbox %q", id)
```

| 规则 | 行为 |
|------|------|
| Pod 主 IP | **只认 `Interfaces["eth0"]`** |
| `AdditionalIPs` | **同一块 eth0** 上的其它地址（如 IPv6），**不是 eth1 的 IP** |
| eth1 / eth2 有 IP | 可留在 `CNIResult.Interfaces`，**不作为** `sandbox.IP` |
| eth0 缺失或无 IPConfigs | **RunPodSandbox 失败** |
| 任一 network Attach 失败 | 整个 `Setup` 失败 → 建沙箱失败 |

#### 6.5.3 「容器里已经有 eth0」时再创建设备

| 场景 | 设备侧 | RunPodSandbox / IP |
|------|--------|---------------------|
| 正规两张业务网（`max_conf_num≥2`） | 第一张 `eth0`，第二张 **`eth1`**（ipvlan：临时名→rename 到 eth1） | 成功；主 IP 仍来自 **eth0**；eth1 IP 在 Result 中 |
| 已有 eth0，再建目标仍为 **`CNI_IFNAME=eth0`** | `LinkAdd(临时名)` 或可成功；`RenameLink→eth0` 在容器 ns 内 **EEXIST** → CNI ADD 失败 | **失败，拿不到 sandbox.IP** |
| 已有 eth0，再建目标为 eth1 | 与 eth0 不冲突 | 成功；主 IP 仍 eth0 |
| eth0 建好但 IPAM 未返回地址 | 接口可能存在 | **失败**（`Interfaces["eth0"]` 无 IP） |

冲突路径（ipvlan）：

```text
容器内已有 eth0
  → LinkAdd(veth*)        // 通常仍可成功
  → RenameLink → eth0     // 同 netns 内名字冲突 → EEXIST
  → CNI ADD 失败
  → setupPodNetwork 失败
  → RunPodSandbox 失败（不会进入 selectPodIPs）
```

说明：此处冲突检查在**容器 netns**（`dev_change_name`），与宿主机物理 `eth0` 无关；§6.4.2 的 host 侧 `-EEXIST` 是另一回事（建链请求名在 sock_net=host 上查找）。

host-device 等把宿主机网卡迁入容器、目标名已是 eth0 时，容器内已有 eth0 同样会在最终 `LinkSetName` 失败（upstream 用临时名规避的是另一类迁移冲突）。

#### 6.5.4 小结

- 官方 go-cni 多 conf：**eth0 / eth1 / … 错开**，一般不会「再抢 eth0」。  
- Pod 主 IP **永远只看 eth0**；多网卡时其它接口 IP 不进 `sandbox.IP` / `AdditionalIPs`（AdditionalIPs 仅 eth0 多地址）。  
- 若容器内已有 eth0 仍要求建成 eth0 → **CNI 失败，RunPodSandbox 无 IP**。  
- Multus 等旁路不走「按 conf 下标编 ethN」时，细节以该方案为准，但「目标 ifName 已存在 → 插件失败 → 沙箱失败」仍常见。

---

## 7. 机制小结

```text
128 并发 RunPodSandbox
        │
        ├─► attach loopback  ──┐
        │                      ├──► 争用 rtnl_mutex / netlink（全局串行）
        └─► attach ipvlan L3 ──┘         │
              │                          │
              │  临时 veth* 名 LinkAdd     │
              │  → RenameLink(eth0)       │
              │  → dev_change_name        │
              │  → netdev_info→pl011      │  （console_loglevel 高时放大持锁）
              ▼                          ▼
                              cni.setup ≈ 6.7s（~81% of run）
                                         │
                                         ▼
                         NewContainer / NewTask / runc 仅数百 ms 内
                                         │
                                         ▼
                              cri.sandbox.run ≈ 8.3s
```

| 层级 | 结论 |
|------|------|
| 端到端（基线） | **~8.3s / P95 ~11.1s**；关 rename INFO 后 **~6.8s / P95 ~9.9s**（§3.3） |
| 主瓶颈 | **CNI（ipvlan + loopback 并行）**；关 printk 后仍占 ~87% |
| perf（有效） | off-CPU：**ipvlan ~23%** + loopback ~8%；on-CPU：ipvlan ~14%，含 **mutex_spin** 与 **pl011@rename** |
| dmesg | 几乎全是 `dev_change_name` 的 `eth0: renamed from veth…`（插件临时名，非真 veth） |
| rename | 最终要 **`eth0`**；从宿主机直接 `LinkAdd(Name=eth0)` **会撞 host eth0（已实测）**，临时名+rename **必要** |
| 多网卡 | go-cni 用 eth0/eth1…；主 IP 只认 eth0；容器内已有 eth0 再抢 eth0 → ADD 失败、无 Pod IP（§6.5） |
| 已健康 | NewContainer / NewTask / runc / cgroup / bbolt wait |
| 相对 bridge+v2 | 配网从 **0.1s 级回到数秒级**；其它阶段反而更轻 |
| 根因类属 | **RTNL 串行**（单次 ADD 约 5～6 次写，§4.4）+ 曾有锁内 rename printk；换 ipvlan **未消除** RTNL |

---

## 8. 优化方向（按杠杆）— 剩余可行方案

> **已否证（5.10）**：从宿主机 `LinkAdd(Name=eth0)` 去掉临时名+rename（撞 host eth0，§6.4.2）。  
> **上游 7.2**：CREATE\|EXCL 按 tgt_net 查名，免 rename **具备内核前提**，仍须改插件（§4.5）；**未复测**。

### 8.1 方案总表

| 优先级 | 方案 | 做法 | 预期 / 状态 |
|--------|------|------|-------------|
| P0 | **关 console INFO** | `printk`/console_loglevel 使 INFO 不上串口；防回潮 `7 4 1 7` | 去掉 pl011 持锁放大（类 bridge 关 printk） |
| P0 | **注释 rename 的 netdev_info** | `/home/nathan/linux` `dev_change_name` 注释该打印 | **已复测（§3.3）**：run Avg 8.30→**6.81s**，setup 6.73→**5.90s**；pl011 消失 |
| P1 | **裁剪 / 内置 loopback** | CRI `use_internal_loopback=true` | **已复测**：TRACE 无 `cni.plugin.loopback`；run 7.08→**7.39s**、setup 5.85→**6.18s**（略差）。墙钟本就被 ipvlan 撑住；lo 改串行 `bringUpLoopback` 后 setup−plugin 仍差 ~1s |
| P1 | **降并发建网** | 少 worker / 限流同时 ADD | 缓解 `rtnl_mutex` 排队；可验证锁模型（§4.4） |
| P2 | **回到 bridge+v2 工作点** | 关 printk + `ipMasq:false` + cgroup v2 | 已知 `cni.setup` ~100ms；ipvlan 未赢 |
| P2 | **插件少 netlink round-trip** | 缓存 master ifindex、合并 Addr/Route 等 | 单次次数有限（§4.4.8）；难单独压到百毫秒 |
| P2 | **其它少 netlink 的配网** | 预建网 / 池化等 | 需单独设计 |
| P3 | **升 7.2+ 并免 rename 建链** | 利用 tgt_net 查重名 + `IFLA_LINK_NETNSID`；改 ipvlan 插件去掉临时名 | 内核前提见 **§4.5**；少 1 次 `LinkSetName`；**未复测**；难单独到百毫秒 |
| P3 | **容器 ns 内建链免 rename（5.10）** | sock_net=容器 + `IFLA_LINK_NETNSID` | 与上条同属进阶；5.10 上 host Name=eth0 已否证 |
| — | **仅升上游内核、不改插件** | 装 7.2 ipvlan | **无端到端红利预期**（§4.5）；无并行建链 |
| — | **改 go-cni/CRI 不用 eth0** | 改 prefix / `defaultIfName` | 牵动面大，一般不划算 |
| 延后 | **bbolt / mounts 等** | `no_sync`、`CLONE_EMPTY_MNTNS`、裁剪 readonly/mask | CNI 仍占 ~80% 时优先级低 |

### 8.2 建议落地顺序

1. ~~注释 `netdev_info` 并复测~~ → **已完成（§3.3）**  
2. ~~内置 loopback~~ → **已复测：端到端几乎无收益（§8.1）**  
3. 仍不够 → **降并发**验证排队，或 **回到 bridge+v2**  
4. 进阶：插件合并 netlink；或 **升 7.2 + 改插件免 rename**（§4.5）

### 8.3 其它注意

- **host-local**：保持 `/12` 目录干净、旁路索引可用。  
- **采集**：`perf/metadata.txt` 时长与 `--duration` 对齐；`perf script -F comm` 应见 `ipvlan`；整目录拷贝到 `profile/`。

---

## 9. 复现要点

```bash
# CNI：/etc/cni/net.d/10-mynet.conf 使用本文 §2.2 的 ipvlan-l3
bash scripts/multi_single_cold_start.sh 128-255 128 1 \
  --profile --pprof --perf --resources -- \
  --duration 60 --cpuset-cpus "0-255" --cpuset-mems "0-1" --preconfig 50

# 采完自检
cat results/multi/perf/metadata.txt    # 应为 60s，时间贴近 worker
perf script -i results/multi/perf/perf_off_cpu.data -F comm \
  | sort | uniq -c | sort -rn | head   # 应有 ipvlan / loopback
dmesg | grep -c 'renamed from'         # rename 热点量级
```

内核树：`/home/nathan/linux`（5.10；`dev_change_name` / `rtnetlink` / `ipvlan_link_new`）。  
上游对照：`/home/nathan/linux-upstream-v1`（7.2.0-rc4；可用性见 **§4.5**）。  
CNI 插件：`/home/nathan/plugins`（`plugins/main/ipvlan/ipvlan.go`；RTNL 清单 **§4.4**）。  
containerd：`/home/nathan/containerd`（`bringUpLoopback` / `setupPodNetwork`）。

结果目录：
- 基线：`profile/ipvlan-l3-containerd-1-4_workers-cores-128-255_workers-nums-128_sandbox-0-255`
- 关 rename INFO：`..._disable-printk`（须确认 `proc_count=128`，且 containerd 实际亲和 1–4）

`use_internal_loopback`：`/etc/containerd/config.toml` → `[plugins.'io.containerd.cri.v1.runtime'.cni]` → `use_internal_loopback = true`，然后 `systemctl restart containerd` 并 `taskset -pc $(pgrep -nx containerd)` 确认 1–4。

---

## 10. 修订记录

| 日期 | 说明 |
|------|------|
| 2026-07-22 | 初版：基于 `profile/ipvlan-l3-...` 的 TRACE / resources / pprof /（空）perf 分析 |
| 2026-07-22 | 更新 §6.2/§7/§8：有效 perf（60s）显示 ipvlan off/on-CPU、RTNL spin、rename→pl011；修正「插件不在 1–4」表述 |
| 2026-07-22 | 新增 §6.3/§6.4：dmesg↔`dev_change_name` 内核路径；讨论可否去 rename |
| 2026-07-22 | **修正 §6.4**：本机实测从 host 直接建 `eth0` 因撞宿主机网卡失败；rename 在现路径下必要 |
| 2026-07-22 | 新增 §6.5：多网卡命名、RunPodSandbox 只认 eth0、容器内已有 eth0 再建网的行为 |
| 2026-07-22 | §8 重写为剩余方案总表；记录已注释 `dev_change_name` 的 `netdev_info`（需重编内核） |
| 2026-07-22 | 新增 §3.3：128 worker 关 rename INFO 对照（run 8.30→6.81s）；更新 §7/§8 状态 |
| 2026-07-22 | 新增 **§4.4**：结合 containerd/ipvlan/`ConfigureIface` 源码的 RTNL 写操作清单；更新 §4.1/§8（内置 lo 已复测无端到端收益） |
| 2026-07-22 | 新增 **§4.5**：对照 `linux-upstream-v1`（7.2）：无并行建链红利；`ec061546c6cf` tgt_net 查重名可支撑免 rename；更新 §6.4/§8 |
| 2026-07-22 | 新增 **§4.6**：结合 containerd + CNI 源码对照 bridge vs ipvlan 的配置、ADD 热路径与 netlink/RTNL 差异；更新 §1.1/§1.3 |
