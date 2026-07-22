# CNI ipvlan-l3 沙箱冷启动性能分析

## 1. 文档概述

### 1.1 背景

在 bridge CNI + cgroup v2 工作点下，同配置冷启动已到 `cri.sandbox.run` Avg **~3.36s** / P95 **~3.71s**，其中 `cni.setup` 仅 **~111ms**（见 `doc/sandbox-cold-start-bottleneck-analysis.md` §8.6）。为验证「去掉 bridge / 无 veth 对」能否进一步压低配网，将业务网切到 **ipvlan mode l3**，并在同 worker / 同绑核条件下复测。

**结论先行**：ipvlan-l3 **未能**改善端到端冷启动；瓶颈从「NewContainer / bbolt」重新回到 **CNI**，`cni.setup` Avg **~6.73s**（约占 `cri.sandbox.run` 的 **81%**），端到端 Avg **~8.3s** / P95 **~11.1–11.4s**。

### 1.2 数据来源

| 类型 | 路径 |
|------|------|
| 结果根目录 | `profile/ipvlan-l3-containerd-1-4_workers-cores-128-255_workers-nums-128_sandbox-0-255/` |
| TRACE 汇总 | `.../profile` |
| pprof | `.../pprof/`（含 `pprof_analysis.txt`） |
| perf | `.../perf/`（containerd 核 1–4 on/off-CPU） |
| resources | `.../resources/`（`report.md` / `summary.json` / `metadata.json`） |

采集入口：`scripts/multi_single_cold_start.sh`（`--profile --pprof --perf --resources`）。

### 1.3 相关文档

| 文档 | 关系 |
|------|------|
| `doc/sandbox-cold-start-bottleneck-analysis.md` | 总瓶颈阶梯；§8.6 为 bridge+v2 对照基线 |
| `doc/cni-bridge-network-analysis.md` | bridge / host-local / loopback 行为与 RTNL 路径 |
| `doc/sandbox-ready-and-startup-latency.md` | Ready / 启动时延语义 |

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

### 3.3 与 bridge + cgroup v2（§8.6）对照

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
- 网络 B：默认 loopback → **`cni.plugin.loopback`**

`cni.setup_pod_network` 墙钟 ≈ **max(ipvlan, loopback) + 调度/收尾**。本轮 ipvlan 更长，故 setup ≈ 6–7s；loopback 仍是 **2s+** 的第二段重载，即使将来 ipvlan 单独优化，并行墙钟也会被 loopback 托住一截，除非去掉或轻量化 lo。

### 4.2 ipvlan L3 为何没有「绕开」全局锁

相对 bridge 的预期收益：

| 预期 | 本轮结果 |
|------|----------|
| 无 veth 对、少一层 L2 | **墙钟未受益** |
| 无 bridge 转发 / 无 iptables masq | 未见 xtables 主导；**主耗时仍在建网** |
| 共用 `eth0` master | 高并发下大量 ipvlan slave 仍挤在同一条 **RTNL / netlink** 路径 |

ipvlan ADD 热路径仍包括：建 netns、在 master 上创建 ipvlan 设备、移入 netns、配地址与路由。这些操作与 bridge 一样依赖内核 **RTNL 全局串行**（见总分析文档 §7 / §16.5）。换插件类型 **没有改变**「高并发建网要抢全局 netlink」这一本质。

本轮 CNI Avg（~6.7s）与早期「bridge + printk 开」时 CNI ~5–6s **同量级**，说明瓶颈类属回归到配网争用，而非 ipvlan 独有的用户态逻辑。

### 4.3 host-local

仍使用 `10.0.0.0/12` + host-local。本轮 TRACE 上 IPAM 未单独露出为数秒级 span；主头在插件级 ipvlan/loopback。仍建议保持 `by_id` 目录干净、旁路索引可用，避免 Walk 回潮叠加在 RTNL 争用之上。

---

## 5. 非 CNI 路径为何显得健康

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

`plugins/main/ipvlan/ipvlan.go` → `createIpvlan()`：

```text
tmpName = RandomVethName()     // "veth" + 随机 hex（字符串，非建 veth）
LinkAdd(Name=tmpName, Namespace=容器 netns, type=ipvlan)
RenameLink(tmpName → args.IfName)   // 通常 eth0 → 触发上面内核路径
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
| **E. 其它建链路径（进阶）** | 例如在容器 netns 内发 netlink 建链（sock_net≠host），并正确指定 host 上的 parent（`IFLA_LINK_NETNSID` 等） | 理论上可避免「按 host 名查找 eth0」，但 ipvlan 要挂 host master，实现复杂，**未在本环境验证** |

结论：**在现有「宿主机执行 ipvlan 插件」模型下，rename 去不掉**；优化应优先 **D（printk/console）**，而不是删 rename。

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
| 端到端 | **~8.3s / P95 ~11.1–11.4s**，吞吐 ~15/s |
| 主瓶颈 | **CNI（ipvlan L3 ~6s + loopback ~2s 并行）** |
| perf（有效） | off-CPU：**ipvlan ~23%** + loopback ~8%；on-CPU：ipvlan ~14%，含 **mutex_spin** 与 **pl011@rename** |
| dmesg | 几乎全是 `dev_change_name` 的 `eth0: renamed from veth…`（插件临时名，非真 veth） |
| rename | 最终要 **`eth0`**；从宿主机直接 `LinkAdd(Name=eth0)` **会撞 host eth0（已实测）**，临时名+rename **必要** |
| 多网卡 | go-cni 用 eth0/eth1…；主 IP 只认 eth0；容器内已有 eth0 再抢 eth0 → ADD 失败、无 Pod IP（§6.5） |
| 已健康 | NewContainer / NewTask / runc / cgroup / bbolt wait |
| 相对 bridge+v2 | 配网从 **0.1s 级回到数秒级**；其它阶段反而更轻 |
| 根因类属 | **RTNL 串行** +（当前）**锁内 rename printk/串口**；换 ipvlan **未消除** RTNL |

---

## 8. 优化方向（按杠杆）

1. **压 console / printk（优先对照）**  
   将 console 调到 INFO 不上串口（或确认 `netdev_info` 不上 console），复测 `cni.setup` Avg——预期类似 bridge 关 printk 的收益。注意本机曾出现 `printk=7 4 1 7` 回潮。

2. **不要指望删掉 rename（本机已否证方案 A）**  
   从宿主机创建名为 `eth0` 会因查找落在 host net 而 `-EEXIST`（§6.4.2）。现路径下临时名+rename 保留。

3. **量化 / 裁剪 loopback**  
   对照「仅 ipvlan」与「ipvlan+loopback」；评估测试场景能否去掉默认 lo，或走 CRI 内部 `bringUpLoopback`。

4. **降并发验证锁模型**  
   降低 worker 数看 `cni.setup` 是否近似线性下降；若是，则坐实全局串行。

5. **内核侧减日志（备选，与关 console 正交）**  
   将 `dev_change_name` 中 `netdev_info` 改为 `netdev_dbg` 或删除（需自维护补丁）。

6. **保持 host-local 干净**  
   避免 `/12` 大网段 Walk / 无索引回潮叠在 RTNL 之上。

7. **非 CNI 优化暂缓**  
   本轮不必优先 bbolt `no_sync`、runc mounts、`CLONE_EMPTY_MNTNS`；等 CNI 回到百毫秒级后再打。

8. **采集注意**  
   确认 `perf/metadata.txt` 时长与 `--duration` 一致，且与 TRACE/resources **同一时间窗**；`perf script -F comm | sort | uniq -c` 应能看到 `ipvlan`。整目录拷贝到 `profile/`，避免只覆盖部分子目录导致空采混入。

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

内核树：`/home/nathan/linux`（`dev_change_name` / `rtnetlink` / `ipvlan_link_new`）。  
CNI 插件：`/home/nathan/plugins`（`plugins/main/ipvlan/ipvlan.go`）。

结果目录命名约定：`profile/ipvlan-l3-containerd-1-4_workers-cores-128-255_workers-nums-128_sandbox-0-255`。

---

## 10. 修订记录

| 日期 | 说明 |
|------|------|
| 2026-07-22 | 初版：基于 `profile/ipvlan-l3-...` 的 TRACE / resources / pprof /（空）perf 分析 |
| 2026-07-22 | 更新 §6.2/§7/§8：有效 perf（60s）显示 ipvlan off/on-CPU、RTNL spin、rename→pl011；修正「插件不在 1–4」表述 |
| 2026-07-22 | 新增 §6.3/§6.4：dmesg↔`dev_change_name` 内核路径；讨论可否去 rename |
| 2026-07-22 | **修正 §6.4**：本机实测从 host 直接建 `eth0` 因撞宿主机网卡失败；rename 在现路径下必要 |
| 2026-07-22 | 新增 §6.5：多网卡命名、RunPodSandbox 只认 eth0、容器内已有 eth0 再建网的行为 |
