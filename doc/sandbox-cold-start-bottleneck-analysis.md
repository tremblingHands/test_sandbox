# 沙箱冷启动性能瓶颈分析

## 1. 文档概述

### 1.1 背景

在 AI Agent / 多租户场景下，Pod 沙箱冷启动延迟直接影响并发创建吞吐。本文基于一次高并发压测，按「**观测数据 → 瓶颈候选 → 逐项深挖**」的顺序，定位 containerd + bridge CNI 场景下的主要瓶颈。

### 1.2 分析路径

1. 汇总 profile / pprof / perf / resources 四类观测
2. 从耗时与热点交叉出若干瓶颈点
3. 对每个瓶颈点下钻到机制（用户态锁、内核锁、进程模型等）
4. 给出对照实验与复现命令

### 1.3 数据来源

| 类型 | 路径 | 说明 |
|------|------|------|
| 结果根目录 | `tmp/containerd-0-127_workers-cores-128-255_workers-nums-127_sandbox-0-255/` | 本次压测输出 |
| profile | `.../profile` | containerd TRACE 各阶段汇总 |
| pprof | `.../pprof/` | Go CPU / mutex / block / goroutine |
| perf | `.../perf/` | containerd CPU 1–4 on/off-CPU 火焰图 |
| resources | `.../resources/` | 系统资源时序与延迟关联报告 |

采集入口：`scripts/multi_single_cold_start.sh`（`--profile --pprof --perf --resources`）。

---

## 2. 压测配置与总体结果

### 2.1 环境与绑定

| 项 | 值 |
|----|-----|
| 主机 | HM70，aarch64，内核 5.10.229，2 × NUMA，256 核 |
| containerd | v2.3.0-100-g36696e157.m |
| Workers | **128**（绑定 CPU **128–255**，NUMA 1） |
| containerd CPU | **1–4**（仅 4 核） |
| 沙箱 CPU | `--cpuset-cpus 0-255`，`--cpuset-mems 0-1` |
| 时长 / 预配置 | `--duration 60`，`--preconfig 50` |
| CNI | bridge（`/etc/cni/net.d`；配置含 `ipMasq: true`） |

### 2.2 端到端延迟（resources）

| 指标 | 数值 |
|------|------|
| 总沙箱数 | 747 |
| P50 / P95 / P99 | **11151 / 15617 / 17139 ms** |
| 资源瓶颈标记 | **`containerd_cpu_saturation`** |
| Spike（约 51s） | P95 ≈ 16.3s，同时约 616 个沙箱活跃 |

**宏观结论**：128 路并发下冷启动 P95 约 **15.6s**；系统标记 containerd CPU 饱和。

---

# 第一部分：观测数据

以下各节只陈述事实与表面热点，机制分析放在第三部分。

---

## 3. Profile：阶段耗时

来源：`profile` 中 `cri.sandbox.run` 树（约 145 次完整 run）。

### 3.1 关键阶段

| Span | Count | Avg | P50 | P95 | P99 |
|------|-------|-----|-----|-----|-----|
| **cri.sandbox.run** | 145 | **11.73s** | 11.31s | 17.27s | 18.77s |
| **cni.setup_pod_network** | 297 | **5.77s** | 5.60s | 10.38s | 11.18s |
| └ cni.plugin.bridge | 297 | 5.77s | 5.60s | 10.38s | 11.18s |
| └ cni.plugin.loopback | 200 | 1.00s | 759ms | 2.39s | 3.04s |
| **container.NewTask** | 154 | **4.76s** | 4.67s | 7.76s | 8.16s |
| └ shim.task.create | 154 | 4.12s | 4.03s | 7.21s | 7.43s |
| └ shim.binary.exec | 227 | 576ms | 566ms | 1.39s | 2.14s |
| client.NewContainer | 226 | 565ms | 263ms | 2.95s | 3.19s |
| └ snapshotter.Prepare | 238 | 278ms | 110ms | 1.39s | 1.73s |
| client.task.Start | 153 | 327ms | 320ms | 585ms | 904ms |
| metadata.sandbox.Create | 203 | 225ms | 237ms | 323ms | 337ms |
| metadata.sandbox.Update | 558 | 258ms | 210ms | 677ms | 817ms |

### 3.2 占比（按 Avg）

```
cri.sandbox.run ≈ 11.73s
├── cni.setup_pod_network ≈ 5.77s   (~49%)
│     ├── cni.plugin.bridge   （主导）
│     └── cni.plugin.loopback （Avg ~1.0s）
├── container.NewTask     ≈ 4.76s   (~41%)
├── client.NewContainer   ≈ 0.57s   (~5%)
├── client.task.Start     ≈ 0.33s   (~3%)
└── metadata / status     分散多次（单次不高，Update 次数多）
```

**数据要点**：端到端时间几乎被 **CNI 配网** 与 **shim/NewTask** 平分；CNI 内 bridge 为主，loopback 单独也有约 1s 量级。

---

## 4. pprof：containerd 用户态

来源：`pprof/pprof_analysis.txt`、`pprof/svg/`。

### 4.1 CPU

| 热点 | flat% | 含义 |
|------|-------|------|
| `Syscall6` | **36.2%** | 大量系统调用 |
| `bbolt.(*Tx).write` | **12.5%** | metadata BoltDB 写盘 |
| runtime GC / malloc | 若干 | 高并发分配压力 |

### 4.2 Mutex（测试窗口增量）

| 热点 | 占比 | 调用链含义 |
|------|------|------------|
| `sync.(*Mutex).Unlock` 相关等待 | **~80%** | 等在 `metadata.(*DB).Update` |
| `RunPodSandbox` → `metadata.update` | ~80% cum | 128 路 gRPC 争用同一把 DB 锁 |
| `snapshotter.Prepare` | ~19% | 快照路径也争用 DB |
| `gcScheduler` / `GarbageCollect` | ~19% | GC 与创建路径争锁 |

### 4.3 Block / Goroutine

- Block：**~95%** `runtime.selectgo` → 大量 goroutine 在等外部工作（CNI / shim / gRPC 等）
- Goroutine 数：约 **1201 → 6226**，随沙箱数增长

**数据要点**：containerd 进程内可见的争用主要是 **metadata DB**；CNI/shim 耗时在 pprof 里更多表现为阻塞等待，而不是 Go 侧 CPU 热点。

---

## 5. perf：内核与 off-CPU

来源：`perf/on_cpu_1-4.svg`、`perf/off_cpu_1-4.svg`（仅 **containerd 绑定核 1–4**）。

### 5.1 On-CPU（显著符号）

| 符号 / 进程 | 相对显著 | 表面含义 |
|-------------|----------|----------|
| `bridge` / `loopback`（CNI 插件进程） | 高 | 配网插件在跑 |
| `netlink_*` / `rtnetlink_*` / `rtnl_*` | 高 | 内核 rtnetlink 路径活跃 |
| `rtnl_setlink` | **~7.3%** | `RTM_SETLINK` 改链路 |
| `rtnl_newlink` | ~0.3–0.5% | 新建链路 |
| `printk` / `pl011_console_write` | **~6.7%**（多在 `rtnetlink_rcv_msg` 之下） | bridge STP 状态日志打到串口（见 §7.5） |
| `loopback` / `loopback_net_init` | ~2.3% / ~0.5% | lo 相关 |
| `xtables-nft-multi` / `iptables` | 高 | 本配置下还有 netfilter 规则写入 |
| `runc` / `containerd-shim` | 高 | 启动 shim |
| `bbolt.(*Tx).write` | 中 | metadata 持久化 |

### 5.2 Off-CPU

| 热点 | 表面含义 |
|------|----------|
| `futex` / `__schedule` | 等锁、调度、睡眠 |
| `containerd-shim` / `runc` | shim 创建路径上的等待 |
| `bridge` | 配网过程中的阻塞 |
| `loopback_net_init` → `register_netdev` → `rtnl_lock_killable` | 建 netns 注册 `lo` 时卡在 RTNL 加锁 |

> 本次 perf **未覆盖** worker 核 128–255。分析沙箱侧 CPU 需加 `--perf_sandbox`。

**数据要点**：核 1–4 上配网（bridge/loopback/netlink）与 shim 都很热；`rtnetlink_rcv_msg` 栈上可见大量 `printk`→串口输出；off-CPU 大量 futex，且已能看到与 `rtnl_lock*` 相关的等待栈。

---

## 6. resources：系统资源

来源：`resources/report.md`、`resources/summary.json`。

| 指标 | 观察 | 解读 |
|------|------|------|
| `containerd_cpu_saturation` | 已标记 | containerd 4 核成为漏斗 |
| `k8s_io_cpu_pct` vs P95 | Pearson **r ≈ 0.59** | 延迟升高时 CRI 路径 CPU 也升高 |
| `io_iostat.util_pct` vs P95 | **r ≈ -0.66** | 磁盘利用率与延迟负相关，**非主因** |
| `io_iostat.w_await_ms` | P50 ≈ 0.17ms | 写延迟很低 |
| `load_1m` | 最高 ≈ 112 | 系统调度压力大 |
| `context_switches_per_s` | 最高 ≈ 547 万/s | 极高上下文切换 |
| 内存 / NUMA | 充足 | **排除**内存瓶颈 |

约 **51s** 处 Spike：P95 ≈ 16.3s，沙箱数 ≈ 616，伴随 high_containerd_cpu。符合「高并发叠加 → 各阶段更慢」的模式。

---

# 第二部分：瓶颈候选

由上述观测交叉，得到下列待深挖的瓶颈点（按对端到端时延的直接贡献排序）。

| # | 瓶颈点 | 主要依据 | 待回答的问题 |
|---|--------|----------|--------------|
| A | **CNI 网络配置时延高** | profile：`cni.setup` ~49%，P95 ~10s；含 bridge + loopback | 时间花在哪些内核/用户态路径？为何并发下急剧恶化？ |
| B | **shim / NewTask 创建慢** | profile：NewTask ~41%；perf：shim/runc + futex | 是 fork/exec、等就绪，还是别的？ |
| C | **metadata DB 争用** | pprof mutex ~80% 在 `DB.Update`；CPU 含 bbolt.write | 是否把 128 路 RunPodSandbox 串行化？ |
| D | **containerd 仅 4 核** | resources：`containerd_cpu_saturation` | 是否放大上述所有竞争？ |
| — | 磁盘 / 内存 | resources 负相关 / 充足 | **排除为主因** |

```
观测交叉示意：

profile:  CNI ~5.8s  +  NewTask ~4.8s  ≈  11.7s
              │                │
perf:     bridge/loopback   shim/runc/futex
          netlink/rtnl_*
              │                │
pprof:    selectgo 等待      mutex → DB.Update
              │                │
resources: containerd 4 核饱和；磁盘/内存非主因
```

---

# 第三部分：逐项深挖

---

## 7. 瓶颈 A：CNI 网络配置时延高

### 7.1 现象

- `cni.setup_pod_network` Avg **5.77s**，P95 **~10.4s**，约占 `cri.sandbox.run` 的一半。
- 子 span：`cni.plugin.bridge` 主导；`cni.plugin.loopback` Avg 仍约 **1.0s**（每个沙箱都会跑）。
- perf：核 1–4 上 `bridge`、`loopback`、`rtnetlink`/`rtnl_*` 显著；off-CPU 可见 `rtnl_lock_killable`。
- 火焰图中 **`rtnetlink_rcv_msg` 上方（子栈）出现大量 `printk` → `pl011_console_write`**，需单独解释（§7.5）。

结论先停留在：**配网阶段本身就是最大时间桶**；需要回答「配网内部卡在什么机制」。

### 7.2 下钻：rtnetlink 路径与全局锁 `rtnl_mutex`

对配网热点沿火焰图下钻，用户态 CNI 经 netlink `sendto` 进入内核：

```
CNI 插件（bridge / loopback）
  → sendto(netlink)
  → rtnetlink_rcv_msg
  → rtnl_lock() / rtnl_lock_killable()
  → doit（rtnl_newlink / rtnl_setlink / …）
```

内核中保护整条路径的是 **`rtnl_mutex`**（`net/core/rtnetlink.c`）：

| 项 | 说明 |
|----|------|
| 范围 | **主机全局一把**，不按 netns 分锁 |
| 入口 | `rtnl_lock()` / `rtnl_lock_killable()` |
| 持锁工作 | `rtnl_newlink`、`rtnl_setlink`、`register_netdev` 等链路与 netdev 注册 |
| 用户态 API | `vishvananda/netlink`：`LinkAdd`、`LinkSetMaster`、`LinkSetUp`、`LinkByName` 等 |

**这是从「CNI 时延高」推出的核心机制：高并发下大量配网操作在 `rtnl_mutex` 上串行。**

### 7.3 持锁 / 等锁时，CPU 会不会被让出？

`rtnl_mutex` 是 **sleeping mutex**（`mutex_lock` / `mutex_lock_killable`），**不是** spinlock。持锁与等锁对 CPU 的行为不同，需分开看：

| 角色 | 是否占用 CPU 跑临界区 | 会不会让出 CPU | 说明 |
|------|----------------------|----------------|------|
| **等锁者**（未拿到 `rtnl_mutex`） | 否（阻塞等待） | **会** | `mutex_lock*` 拿不到锁时进入睡眠，经 `schedule` 让出 CPU；其它线程/进程可在该核上运行 |
| **持锁者**（已拿到锁，正在跑 doit） | **通常会**（执行 `rtnl_setlink` / `newlink` / `register_netdev` 等） | **可以，但不等于「因持锁而主动让出」** | 临界区内是普通内核路径：可被抢占；也可能在持锁期间因内存分配等进入睡眠。睡眠时 **CPU 让出，但锁仍被占用** |

要点：

1. **等锁会让出 CPU**  
   等高并发 CNI 时，大量线程堵在 `rtnl_lock*` / `mutex_lock*` 上睡觉，对应 perf **off-CPU**（如 `loopback_net_init → register_netdev → rtnl_lock_killable`）。这些线程 **不空转占核**，但端到端延迟照样涨——在等唯一持锁者做完。

2. **持锁者主要在消耗 CPU 做配网工作**  
   拿到锁之后要跑完链路配置；火焰图 **on-CPU** 上 `rtnl_setlink` ~7% 等帧，就是持锁临界区在跑。mutex **不会**像 spinlock 那样关抢占死占核空转；但临界区本身往往是 CPU 密集的内核工作，表现为占核执行。

3. **「让出 CPU」≠「放开锁」**  
   - 等锁者：让出 CPU，且 **未持锁**。  
   - 持锁者若在临界区内 sleep：让出 CPU，但 **`rtnl_mutex` 仍被持有**，其它配网请求继续排队——这是 mutex 允许 sleep 带来的典型放大点（锁持有时间变长）。  
   - 因此：不能指望「持锁线程 sleep 了，别人就能配网」；全局串行仍然成立。

4. **和本压测的对应关系**

```
线程 A：持锁跑 rtnl_setlink / register_netdev …  →  on-CPU（占核做活）
线程 B/C/…：mutex_lock 失败 → schedule 睡眠     →  off-CPU（让出 CPU，等锁）
         ↑
    同一把 rtnl_mutex：A 做完才轮到下一个
```

对 containerd 绑定的 **4 核**而言：等锁线程让出 CPU 后，核可以被持锁配网、shim、其它工作使用；但配网吞吐仍被 **一把锁串行**卡住，多核帮不上「并行配网」。这与 resources 里的 CPU 饱和、以及「大量 futex/schedule 等待」可以同时成立。

### 7.4 谁在抢这把锁（不只是 bridge）

火焰图与内核/CNI 源码对照：凡改链路或注册 netdev 都会拿 RTNL。本压测至少包括：

| 调用方 | 典型操作 | 内核路径（示意） | 证据 |
|--------|----------|------------------|------|
| **建 netns** | 沙箱网络命名空间初始化 | `loopback_net_init` → `register_netdev` → `rtnl_lock_killable` | off-CPU 同栈 |
| **CNI loopback** | `netlink.LinkSetUp(lo)` | `RTM_SETLINK` → `rtnl_setlink` → `dev_change_flags` | profile loopback ~1s；on-CPU 进程 `loopback` ~2.3%；IPv6 `init_loopback` 有 `ASSERT_RTNL()` |
| **CNI bridge** | 建 veth、设 master、起停口 | `rtnl_newlink` / `rtnl_setlink` / `do_set_master` → `br_add_if` | on-CPU `rtnl_setlink` ~7.3% |
| 其它 | `getlink`、地址/路由 notifier | `rtnl_getlink`、`inetdev_event` / `fib_*` 等 | 火焰图可见 |

一次冷启动上的 RTNL 竞争示意：

```
RunPodSandbox
  └─ cni.setup_pod_network
       ├─ [netns 创建]  loopback_net_init → register_netdev ──┐
       ├─ cni.plugin.loopback  LinkSetUp(lo) ────────────────┼─ rtnl_mutex（全局串行）
       └─ cni.plugin.bridge    veth / setmaster / up ────────┘
```

要点：

- **loopback 与 bridge 共用同一把锁**；loopback 看似轻，但每沙箱必跑，会放大尾延迟。
- 关某一类用户态附加步骤（例如本配置里的 masquerade）**不能消除** RTNL；只要还有 netns/lo/veth/bridge 链路操作，锁仍在。

### 7.5 火焰图中的 `printk`：为何出现在 `rtnetlink_rcv_msg` 下

#### 现象

on-CPU 火焰图 / `perf report` call-graph 中，在 **`rtnetlink_rcv_msg` 之下**（不是之上；堆栈自下而上为调用者→被调用者）可见大段：

```
printk → vprintk_emit → console_unlock → pl011_console_write → …
```

定量：`printk` 相关 children 约 **6.7%**，几乎全部落在 **`pl011_console_write`（ARM UART 串口控制台）**。容易误解成「rtnetlink 协议栈在狂打日志」——实际不是。

#### 调用链（perf 还原）

```
rtnetlink_rcv_msg          ← 持 rtnl_mutex 处理 RTM_SETLINK
  → rtnl_setlink
  → do_setlink
  → do_set_master
  → br_add_slave / br_add_if   ← CNI bridge 把 veth 挂到网桥
  → br_init_port / br_stp_enable_port / …
  → br_set_state               ← 切换 STP 端口状态
  → br_info(…) → printk(…)
  → console_unlock → pl011_console_write   ← 同步写串口，极慢
```

即：**CNI bridge 加端口 → 内核 bridge STP 改状态 → 打 KERN_INFO → 当前 console_loglevel 允许打到串口 → CPU 耗在 UART。**

#### 结合代码

1. **STP 状态变更必打 info 日志**（`net/bridge/br_stp.c`）：

```c
void br_set_state(struct net_bridge_port *p, unsigned int state)
{
	/* ... */
	p->state = state;
	err = switchdev_port_attr_set(p->dev, &attr);
	if (err && err != -EOPNOTSUPP)
		br_warn(...);
	else
		br_info(p->br, "port %u(%s) entered %s state\n",
			(unsigned int) p->port_no, p->dev->name,
			br_port_state_names[p->state]);
	/* ... */
}
```

每个沙箱把 veth 加入 bridge 时，端口会经历 blocking / listening / learning / forwarding 等切换，**每次 `br_set_state` 成功路径都走 `br_info`**。高并发下日志条数随沙箱数 × 状态切换次数膨胀。

2. **`br_info` 就是带级别的 `printk`**（`net/bridge/br_private.h`）：

```c
#define br_printk(level, br, format, args...) \
	printk(level "%s: " format, (br)->dev->name, ##args)

#define br_info(__br, format, args...) \
	br_printk(KERN_INFO, __br, format, ##args)
```

`KERN_INFO` 对应级别 **6**。本机压测时 `/proc/sys/kernel/printk` 首项 **console_loglevel=7**，INFO 会输出到 console。

3. **为何 CPU 占比高**：`printk` 写入 ring buffer 后，若未按级别抑制，会走 `console_unlock` → 各 console 驱动。本机是 **PL011 串口**，按字符输出，远慢于内存日志；故火焰图热点在 `pl011_console_write`，而不是「格式化字符串」本身。

4. **与 `rtnl_mutex` 的关系**：上述路径发生在 **`rtnl_setlink` 持锁临界区内**。串口打印拉长持锁时间 → 其它等锁的配网请求排队更久。因此 `printk` 既是独立的 on-CPU 浪费，也是 RTNL 串行的放大器。

#### 调 `console_loglevel` 能否去掉？

| 手段 | 还会调用 `br_info`/`printk`？ | 还写 dmesg ring buffer？ | 还写串口（火焰图热点）？ |
|------|------------------------------|--------------------------|---------------------------|
| `dmesg -n 4` 或 `kernel.printk='4 4 1 7'` | **会** | **会** | **基本不会**（INFO 被 `suppress_message_printing` 跳过） |
| 去掉/不用串口 console | 会 | 会 | 不会 |
| 改内核去掉 `br_info` | 不会 | 不会 | 不会 |

内核逻辑（`level >= console_loglevel` 则不上 console）：把 console 调到 **4** 即可让 INFO 不上串口，**打掉火焰图里绝大部分 `pl011_*`**；但不会让 `br_set_state` 里的 `br_info` 调用消失。压测对照：

```bash
# 临时抑制 INFO 上串口（推荐压测时使用）
sudo dmesg -n 4
# 或: echo '4 4 1 7' | sudo tee /proc/sys/kernel/printk

# 恢复
sudo dmesg -n 7
```

#### 对照实验：内核去掉 netlink/`br_info` 路径上的 `printk`（已完成）

内核 commit **`0d91342dba12`**（`disable netlink printk`）：注释 `br_stp.c` 中 `br_set_state` 成功路径的 `br_info`，并一并关掉 `net/core/dev.c`、`net/ipv6/addrconf.c` 等配网热路径上的相关 `printk`。数据目录：

| 场景 | 路径 |
|------|------|
| 基线（含 printk） | `profile/containerd-0-127_workers-cores-128-255_workers-nums-127_sandbox-0-255` |
| 关 printk | `profile/..._disable-printk` |

同配置：128 workers、containerd 绑核 1–4、`--duration 60`。

| 指标 | 基线 | 关 printk | 变化 |
|------|------|-----------|------|
| 吞吐（沙箱/s，总沙箱÷采样窗） | **~12.8**（747 / 58.4s） | **~15.1**（895 / 59.1s） | **+18%**（约 11→15 量级） |
| 端到端 P50 / P95 / P99 | 11.2 / **15.6** / 17.1 s | 9.5 / **13.1** / 14.3 s | P95 **−16%** |
| `cni.setup_pod_network` Avg / P95 | **5.15s** / 6.77s | **1.21s** / 2.41s | Avg **约 −77%** |
| `cri.sandbox.run` Avg / P95 | 13.1s / 19.4s | 8.9s / 12.2s | 明显下降 |
| on-CPU `printk` / `pl011_console_write` | 有（约 1.8%） | **消失** | 串口路径被打掉 |
| on-CPU `rtnl_setlink` / `br_add_if` | **~7.3%** | **~0.4%** | 持锁临界区 CPU 占比大降 |
| containerd 核 mpstat **idle**（mean / p50） | **12.0% / 5.9%** | **1.1% / 0.8%** | idle 几乎被吃光 |
| containerd 核 mpstat **usr**（mean） | 22.6% | **32.6%** | 用户态更忙；sys ≈65% 两边相近 |
| 在飞沙箱数 mean / 上下文切换 | 356 / ~4.1M/s | **491** / **~6.0M/s** | 并发态与调度更密 |
| containerd RSS mean | 369 MB | **501 MB** | 更多并发态占用 |

**阶段占比变化**（相对 `cri.sandbox.run` Avg；同窗口 profile）：

| 阶段 | 基线 Avg（约占 run） | 关 printk Avg（约占 run） |
|------|----------------------|---------------------------|
| `cni.setup_pod_network` | 5.15s（~39%） | 1.21s（~14%） |
| `container.NewTask` | 6.32s（~48%） | 1.71s（~19%） |
| `client.NewContainer` | 0.53s（~4%） | **2.69s（~30%）← 新的第一大项** |
| `client.snapshotter.Prepare` | 0.23s | **1.06s（约 +3.5×）** |
| `metadata.sandbox.Update` | 0.15s | **0.63s（约 +3.3×）** |
| `runc.cgroup.apply` | 3.09s | **0.32s（约 −90%）** |

**解读**：

1. 关 `printk` 后 **CNI 不再是第一大阶段**；按占比 **`client.NewContainer`（含 snapshotter / metadata）成为新的头号阶段**。
2. 这直接验证了 §7.5 的因果：`br_info`→串口不是旁路噪音，而是 **RTNL 持锁放大器**；去掉后配网墙钟与 `rtnl_setlink` 帧同步下降。
3. **CPU 利用率上升、idle 下降是预期现象，不是回退**：基线里大量线程堵在 `rtnl_lock*` 上等锁睡觉（§7.3），holder 在串口上慢慢打日志，4 个 containerd 核上仍能看到可观 idle；关 `printk` 后持锁变短、排队变短，同一批核更多地在跑有效工作（usr↑），idle 从 ~12% 降到 ~1%。**更高利用率对应更高吞吐**，原先 idle 是「等锁空转」。
4. **连带变快：NewTask / cgroup**：`container.NewTask`、`runc.cgroup.apply` 也大幅下降。串口不再占满 4 核持锁路径后，shim/runc 少受队头阻塞，属于共享核上的「松绑」，不只是 CNI 自己变快。
5. **连带变慢并被暴露：NewContainer / metadata / snapshotter**：在飞沙箱更多，工作更早堆到 bbolt 与 snapshot 路径，Avg 升约 3–4×。关 printk 等于把下一层瓶颈推到台前（与瓶颈 C 一致）。
6. **火焰图相对结构变化**：bridge on-CPU 份额下降（~19%→~11%），**iptables / xtables 相对更显眼**（~21%→~25%）——配网主路径轻了之后，本配置 `ipMasq` 的成本更容易看见。
7. 吞吐仍受 `rtnl_mutex`、metadata、4 核漏斗等约束，故不是线性翻倍；但 **~+18% 吞吐、CNI Avg 降到约 1/4** 已说明串口日志是高杠杆项。下一轮对照宜优先：**bbolt/snapshot 争用**、以及 **关 `ipMasq`**（见下节，已完成）。
8. 生产侧更稳妥的等价手段仍是 **`dmesg -n 4` / 调低 console_loglevel** 或不用串口 console；内核注释 `br_info` 适合对照实验，不宜长期作为唯一修复。

#### 对照实验：`ipMasq: false`（关 printk 之上，已完成）

在 **`0d91342dba12` 关 printk** 不变的前提下，仅将 CNI 配置改为 `"ipMasq": false`（`scripts/setup.sh --cni-type bridge --ip-masq false`），去掉每沙箱 `SetupIPMasq` → `iptables`/`nft` 写 NAT。数据目录：

| 场景 | 路径 |
|------|------|
| 关 printk + `ipMasq: true` | `profile/..._disable-printk` |
| 关 printk + `ipMasq: false` | `profile/..._disable-printk_ip-masq-false` |

同配置：128 workers、containerd 绑核 1–4、`--duration 60`。

| 指标 | 关 printk（ipMasq true） | + ipMasq false | 变化 |
|------|-------------------------|----------------|------|
| 吞吐（沙箱/s） | **~15.1**（895 / 59.1s） | **~17.3**（1023 / 59.1s） | **+14%** |
| 端到端 P50 / P95 / P99 | 9.5 / **13.1** / 14.3 s | 7.7 / **10.7** / 11.8 s | P95 **−18%** |
| `cni.setup_pod_network` Avg / P95 | **1.21s** / 2.41s | **386ms** / 835ms | Avg **约 −68%** |
| `cni.plugin.bridge` Avg | 1.20s | **381ms** | 与 setup 同步下降 |
| `cni.plugin.loopback` Avg | 174ms | 166ms | **基本不变**（无 masq 路径） |
| `cri.sandbox.run` Avg / P95 | 8.86s / 12.2s | 6.92s / 10.3s | 明显下降 |
| on-CPU **`iptables`**（核 1–4） | **~24.9%** | **消失（~0%）** | 直接验证去掉 masq |
| on-CPU `bridge` | ~11.5% | ~8.3% | 略降 |
| on-CPU `runc` / `containerd` / shim | 19% / 18% / 16% | **31% / 23% / 22%** | 配网变轻后份额上移 |
| containerd 核 idle（mean） | 1.1% | 7.3% | 去掉 iptables 占核后略有空闲；报告另标 `disk_saturation` |
| 在飞沙箱 mean | 491 | **598** | 并发态更高 |

**阶段占比变化**（相对 `cri.sandbox.run` Avg）：

| 阶段 | 关 printk Avg（约占 run） | + ipMasq false Avg（约占 run） |
|------|---------------------------|--------------------------------|
| `cni.setup_pod_network` | 1.21s（~14%） | **386ms（~6%）** |
| `client.NewContainer` | 2.69s（~30%） | 1.95s（~28%） |
| `container.NewTask` | 1.71s（~19%） | **2.48s（~36%）← 新的第一大项** |
| `client.snapshotter.Prepare` | 1.06s | 764ms |
| `metadata.sandbox.Update` | 630ms | 459ms |
| `runc.cgroup.apply` | 321ms | 420ms |

**解读**：

1. **关 `ipMasq` 在关 printk 之上仍有可观收益**：吞吐再 **+14%**，`cni.setup` Avg 再降到约 **1/3**（1.21s→386ms），说明关 printk 后露出的 **xtables/`iptables` 开销是真实墙钟成本**，不是火焰图错觉。
2. **因果干净**：`loopback` span 几乎不动；`bridge` span 与 `cni.setup` 同幅度下降；perf 上 **`iptables` 从 ~25% 归零**——对准的就是 masq 写 NAT，而不是 RTNL 主路径被误伤。
3. **阶段再次换位**：CNI 只剩 ~6%；**`container.NewTask` / shim / runc 成为新的头号阶段**（Avg 1.71s→2.48s，占比 ~36%）。配网更快后，更多工作更早堆到 task 创建与 cgroup，与关 printk 后 NewContainer 被暴露是同一类「松绑→下一层冒头」。
4. **NewContainer / metadata / snapshotter 这次变快**（与关 printk 对照时它们变慢不同）：去掉占满 4 核的 iptables 后，bbolt/snapshot 路径少受队头阻塞，Avg 下降。说明这些阶段对「谁在占核」敏感，对照之间不可只看绝对毫秒、还要看争用对象。
5. **RTNL 仍在**：`bridge`/`loopback`/`host-local` 仍有可观 on-CPU；关 masq **不取消** `rtnl_mutex`。若要继续压 CNI，需换形态（ipvlan / hostNetwork）或接受 bridge+veth 的结构性串行。
6. **出网规则迁移（已写入 `setup.sh`）**：关 `ipMasq` 后冷启动不再写 per-sandbox NAT，出网改由**节点级一条** MASQUERADE 承担（见下）。下一轮优先：**NewTask / shim / runc.cgroup** 与 **bbolt/snapshot**。

**原规则 vs 节点级规则**

`ipMasq: true` 时，每个沙箱 ADD 写一套（iptables 后端示例）：

```text
-A POSTROUTING -s <pod-ip>/32 -m comment --comment "name: \"mynet\" id: \"...\"" -j CNI-<hash>
-A CNI-<hash> -d 10.0.0.0/12 ... -j ACCEPT          # 池内不伪装
-A CNI-<hash> ! -d 224.0.0.0/4 ... -j MASQUERADE   # 出网（非组播）伪装
```

N 个沙箱 → N 条 POSTROUTING 跳转 + N 条 `CNI-*` 链；DEL 时拆除。这是冷启动路径上 xtables/nft 开销的来源。

`ipMasq: false` 时 CNI 不再写上述规则。出网改为节点级一条（与 per-sandbox 出网效果对齐，冷启动不碰 iptables）：

```text
-A POSTROUTING -s 10.0.0.0/12 ! -o cni0 -j MASQUERADE
```

| | 原 CNI per-sandbox | 节点级一条 |
|--|--|--|
| 粒度 | 每沙箱 `/32` + 专用链 | 整池 `10.0.0.0/12` |
| 谁写 | bridge ADD/DEL | `setup.sh` 一次 ensure |
| 冷启动 | 每次改 nat | 不碰 |
| 出网 SNAT | 有 | 有（本场景等价） |
| 池内互访 | 链内 `-d 池 ACCEPT` | 走 `cni0`，不命中 `! -o cni0` |

复现 / 日常配置：

```bash
bash scripts/setup.sh --cni-type bridge --snapshotter overlayfs --ip-masq false
```

脚本会：① 把 `/etc/cni/net.d/10-mynet.conf` 的 `"ipMasq"` 设为 `false`；② 若不存在则添加上述节点级规则；③ 若改回 `--ip-masq true` 则删除该节点级规则，改由 CNI 维护。重启后 iptables 可能丢失，需重跑 `setup.sh` 或自行做 iptables 持久化。

#### 对照实验：host-local 目录预填（量化 `GetByID` Walk）

关 printk + `ipMasq: false` 后，`cni.setup` Avg 可降到 **~386ms**，CNI 不再是头号阶段。但本机 IPAM 是 **host-local**：自动分配时在目录 flock 内对 `/var/lib/cni/networks/mynet/` 做 **`GetByID` → `filepath.Walk` + 逐文件 `ReadFile`**（防重复分配），复杂度随**已占用 IP 文件数**增长（详见 `doc/cni-bridge-network-analysis.md` §9）。

用 `scripts/hostlocal_prefill.sh` 预填占位文件，使 Walk 基数固定，与「目录较干净」的关 masq 基线对照：

| 场景 | 路径 |
|------|------|
| 关 printk + ipMasq false（目录未刻意预填） | `profile/..._disable-printk_ip-masq-false` |
| 同上 + **预填 5000** IP 文件 | `profile/..._disable-printk_ip-masq-false_hostlocal-prefill5000` |

同配置：128 workers、containerd 绑核 1–4、`--duration 60`。预填后压测结束时目录约 **5311** 个 IP 占位；prefill 轮目前以 TRACE `profile` 为主（无完整 resources）。

| 指标 | 关 masq 基线 | + prefill 5000 | 变化 |
|------|--------------|----------------|------|
| `cri.sandbox.run` Avg / P95 | 6.92s / 10.3s | **9.26s / 12.8s** | 端到端变慢 |
| `cni.setup_pod_network` Avg / P95 | **386ms** / 835ms | **8.83s** / 12.6s | Avg **约 ×23** |
| `cni.plugin.bridge` Avg | 381ms | **8.83s** | 与 setup 同步暴涨（IPAM 叠在 bridge 插件内） |
| `cni.plugin.loopback` Avg | 166ms | 38ms | 略降（被 bridge 挡住） |
| `client.NewContainer` Avg | 1.95s | 24.5ms | 「变快」：队头在 CNI |
| `container.NewTask` Avg | 2.48s | 167ms | 同上 |

**解读**：

1. **目录有数千文件时，host-local 扫盘是高杠杆真实成本**：`cni.setup` / `cni.plugin.bridge` 从约 **0.4s 拉到约 9s**，再次占满 `cri.sandbox.run`。
2. 与 RTNL / printk / ipMasq **正交**：本对照未改内核与 masq；变的是 IPAM 数据目录规模。关 masq 后「CNI 变轻」的结论在**干净目录**下成立；**脏目录**下 CNI 会再次成为头号阶段。
3. NewContainer / NewTask Avg 骤降是**队头阻塞换位**，不能解读为这两段变快；工作堵在 host-local flock + Walk 上。
4. 复现：

```bash
# 空目录对照（建议补跑并带 --resources 算吞吐）
bash scripts/hostlocal_prefill.sh clear
# … 再跑 multi_single_cold_start …

# 预填 5000
bash scripts/hostlocal_prefill.sh clear
bash scripts/hostlocal_prefill.sh prefill 5000
# … 同配置压测，结果目录带 hostlocal-prefill5000 …
```

5. 优化方向：换带索引的 IPAM / fork host-local；运维上压测前后 `clear`、避免占位泄漏导致目录只增不减。空目录时下一刀仍可看 NewTask；**长期跑满或泄漏后必须正视 Walk**。

### 7.6 火焰图中与 RTNL 相关的量化线索

| 符号 | 约占比（on-CPU 核 1–4） | 含义 |
|------|-------------------------|------|
| `rtnl_setlink` | **~7.3%** | **持锁**改链路（含 `br_add_if`；其下嵌套 `printk`） |
| `printk` / `pl011_console_write` | **~6.7%** | bridge STP `br_info` → 串口（§7.5） |
| `rtnl_newlink` | ~0.3–0.5% | 新建链路（持锁路径） |
| `rtnl_lock` / `rtnl_lock_killable` | 分散累计 | 加锁入口；争用剧烈时与等锁相关 |
| `loopback` / `loopback_net_init` | ~2.3% / ~0.5% | lo：CNI 插件 + netns 内注册 |

off-CPU 上 `loopback_net_init → register_netdev → rtnl_lock_killable` 对应 **等锁睡眠（已让出 CPU）**，这部分时间仍计入端到端延迟（见 §7.3）。

### 7.7 同属 CNI 桶内的其它开销（次要、与配置相关）

本次 CNI 配置曾开启 `ipMasq: true`，perf 中能看到 `xtables-nft-multi` / `iptables`：每沙箱写 `CNI-*` MASQUERADE 链会额外引入 **xtables 全局锁**与大量 nft dump/validate 开销。

**关 `ipMasq` 对照已完成**（§7.5 末）：on-CPU `iptables` **~25%→0%**，`cni.setup` Avg **1.21s→386ms**，吞吐 **15.1→17.3/s**。出网改由节点级 `-s 10.0.0.0/12 ! -o cni0 -j MASQUERADE`（`setup.sh --ip-masq false` 自动 ensure）。这是 **CNI 桶内、与配置相关的叠加因素**，不是「配网慢」的唯一定义，也与 `rtnl_mutex` 不是同一把锁：

| 机制 | 触发 | 与「CNI 时延」关系 |
|------|------|-------------------|
| **`rtnl_mutex`** | 链路/netdev 配置（bridge、loopback、netns lo） | **配网主路径上的结构性串行**；换 CNI 形态也常仍存在 |
| **串口 `printk`**（本机） | bridge `br_set_state` → `br_info` | 拉长 RTNL 持锁；对照已验证（§7.5） |
| **xtables**（本配置） | `ipMasq` 写 nat | 对照已验证：`ipMasq: false` 可去掉（§7.5），**但不取消 RTNL** |
| **host-local Walk** | `GetByID` 全目录 `ReadFile` | 对照已验证：预填 5000 后 `cni.setup` **386ms→8.83s**（§7.5）；与 RTNL 正交 |

对照实验时需分开看：关 masquerade 验证 xtables；`dmesg -n 4` / 关 printk 验证串口日志；`hostlocal_prefill` 验证 IPAM 扫盘；减 veth/bridge 或跳过 CNI（如 ipvlan / hostNetwork）才更直接打到 RTNL 竞争。

### 7.8 小结（瓶颈 A）

**CNI 配网是最大时间阶段；下钻后主因是全局 `rtnl_mutex` 把 netns/lo/bridge/veth 等操作串行化。** 等锁者会让出 CPU，持锁者主要在占核做临界区工作（亦可在持锁期间 sleep，但锁不释放）。持锁路径上 bridge STP 的 **`br_info`→串口 `printk`** 会额外占 CPU 并拉长持锁（§7.5）；**关掉该 `printk` 后，`cni.setup` Avg 从 ~5.2s 降到 ~1.2s、吞吐约 +18%**。其上再关 **`ipMasq`**，`cni.setup` 再降到 **~386ms**、吞吐约 **+14%**，perf 上 iptables 归零——验证 xtables 为同桶叠加项。关 masq 且目录较干净时阶段换位到 **NewTask/shim/runc**；但 **host-local 预填 5000** 后 `cni.setup` 又升到 **~8.8s**（约 ×23），说明 IPAM 扫盘在脏目录下可重新主导 CNI 桶。RTNL 与 loopback 仍在。
---

## 8. 瓶颈 B：shim / NewTask 创建慢

### 8.1 现象

- `container.NewTask` Avg **4.76s**（~41%）；其中 `shim.task.create` Avg **4.12s**。
- perf：`runc` / `containerd-shim` on-CPU 高；off-CPU 大量 futex / schedule。

### 8.2 机制（当前深度）与下钻方式

每沙箱需 fork/exec shim、完成 task 创建握手。高并发下：

- 进程创建与就绪等待叠加；
- 与 CNI、metadata 争用同一批 containerd 核时，等待被进一步拉长。

**`shim.task.create` 只覆盖 containerd 等 ttrpc Create 返回的墙钟时间。** 要拆内部，需使用带细粒度 span 的 shim（`/home/nathan/containerd` 已在 Create 路径增加）：

| Span | 位置 | 含义 |
|------|------|------|
| `shim.container.create` | shim `task.Create` | server 侧整段 Create |
| `shim.rootfs.mount` | `mount.All` | 挂 rootfs |
| `shim.init.create` | `Init.Create` | 准备并创建 init |
| `shim.runc.create` | `go-runc Create` | 真正 `runc create` |

进一步可在 `/home/nathan/runc` 打同格式 TRACE，拆开 `runc.create` 内部（见 §13）。安装带 TRACE 的 **shim + runc** 后，`--profile` 会合并 journal 与 `/tmp/runc-trace.log`，再用 `scripts/trace_analyzer.py --summary-tree` 看子阶段。亦可继续用 `--perf_sandbox` 交叉验证。

### 8.3 小结（瓶颈 B）

**第二大时间桶是 shim 创建路径**；表现为 CPU + 大量 off-CPU 等待。优化方向：预热/复用、减少 per-sandbox 进程成本、或先用降并发观察是否线性改善。

---

## 9. 瓶颈 C：metadata DB 争用

### 9.1 现象

- pprof mutex：**~80%** 落在 `metadata.(*DB).Update`。
- CPU：`bbolt.(*Tx).write` **~12.5%**。
- profile：单次 Create/Update 不高（百毫秒级），但 Update **次数多**（采样窗口内数百次）。

### 9.2 机制

128 路 `RunPodSandbox` 共享 metadata 的全局更新路径；持锁期间还有 bbolt 写盘。结果是用户态侧的另一道串行化，与内核 RTNL 独立，但同样抬高尾延迟。

### 9.3 小结（瓶颈 C）

**containerd 内部主要可见锁是 metadata DB**；对端到端占比低于 CNI/shim，但在高并发下会放大 P95，且与 pprof 证据最直接。

---

## 10. 瓶颈 D：containerd 4 核漏斗

### 10.1 现象

- resources 标记 **`containerd_cpu_saturation`**。
- 配网插件、shim、bbolt、大量 syscall 都挤在 CPU **1–4**。
- `load` / 上下文切换极高；延迟与 CRI 路径 CPU 正相关。

### 10.2 机制

上述 A/B/C 的竞争与工作都汇总到少量核上：持锁线程占核、其它线程在 futex 上睡，形成「锁等待 + CPU 饱和」正反馈。扩核不一定消掉 RTNL/DB 锁，但能缓解调度与 syscall 拥堵。

### 10.3 小结（瓶颈 D）

**4 核是放大器**，不是单独的「业务阶段」，但会让所有瓶颈看起来更严重。

---

## 11. 已排除：磁盘与内存

- 磁盘 util 与 P95 **负相关**，`w_await` 极低 → 不像 IO 等待主导。
- 内存 / NUMA 充足 → 排除容量型瓶颈。

---

# 第四部分：建议与复现

---

## 12. 优化与对照实验

建议按「先验证瓶颈 A 的 RTNL，再拆配置叠加项，再动 B/C/D」设计实验。

| 实验 | 对准 | 预期 |
|------|------|------|
| A. hostNetwork 对照 | 整段跳过 CNI | `cni.setup` 接近消失 → 量化配网（含 RTNL）上限 |
| B. CNI 改为 ipvlan | 减少 veth/bridge 类链路操作 | `cni.setup` 与 `rtnl_*` 帧下降 |
| C. **仅关 `ipMasq`**（已做） | 去掉本配置的 xtables 叠加；出网改节点级 MASQ | 在关 printk 上：吞吐 **15.1→17.3/s**；`cni.setup` **1.21s→386ms**；iptables on-CPU **~25%→0%**；`setup.sh --ip-masq false` 自动加 `-s 10.0.0.0/12 ! -o cni0`（见 §7.5） |
| C2. `dmesg -n 4`（压测前） | 抑制 bridge STP INFO 上串口 | `pl011_console_write` / `printk` 帧大降；`br_info` 仍执行，RTNL 仍在 |
| C3. **内核关 netlink/`br_info` printk**（`0d91342dba12`，已做） | 从源码去掉配网热路径 `printk` | 吞吐 **~12.8→15.1/s**；`cni.setup` Avg **5.15→1.21s**；`rtnl_setlink` **~7.3%→0.4%**（见 §7.5） |
| C4. **host-local 预填 5000**（已做） | 量化 `GetByID` Walk | 关 masq 上：`cni.setup` **386ms→8.83s**（约 ×23）；`scripts/hostlocal_prefill.sh`（见 §7.5） |
| D. workers 32 / 64 / 128 | 锁竞争曲线 | P95 非线性上升 → 确认全局锁/漏斗 |
| E. containerd 核 4 → 16+ | 瓶颈 D | 饱和缓解；锁等待可能仍在 |
| F. 同配置 `--profile` + perf 对比 | 量化 | 分开看 bridge/loopback span 与 `rtnl_*` vs xtables |

中期：减少 `metadata.sandbox.Update` 持锁；snapshotter 预热；shim 路径优化；压测加 `--perf_sandbox`。关 printk + 关 `ipMasq` 且 **目录干净** 时优先 **NewTask / shim / runc.cgroup**；**脏目录 / 长期泄漏** 时优先 **host-local 索引或换 IPAM**。建议补跑 `hostlocal_prefill.sh clear` 空目录对照并带 `--resources`。

不建议优先：只加内存/换盘；未上 K8s 就为「减创建路径配网锁」去部署 Cilium/Calico；指望「关掉 loopback 插件」消除 RTNL（netns 仍会注册 lo，且 CRI 默认仍挂 loopback）。

---

## 13. 带 TRACE / debug 符号的组件编译与安装

本节同时覆盖两类需求：

1. **`[TRACE]` 时延分解**（`--profile` / `trace_analyzer.py`）——containerd / shim / runc
2. **保留 DWARF/Go 符号**，便于 `perf` 火焰图看到函数名（而不是 `elf` / 地址）——以上三者 + CNI

源码与安装路径（本机）：

| 组件 | 源码目录 | 系统安装路径（常见） |
|------|----------|----------------------|
| containerd | `/home/nathan/containerd` | `/usr/local/bin/containerd`（及 `/usr/bin`） |
| containerd-shim-runc-v2 | 同上 | `/usr/local/bin`、`/usr/bin` |
| runc | `/home/nathan/runc` | `/usr/local/sbin/runc`（及 `/usr/sbin`、`/usr/bin`） |
| CNI 插件 | `/home/nathan/plugins` | `/opt/cni/bin/`（bridge、loopback、host-local 等） |

安装前请备份现网二进制。新起的 sandbox 才用新 shim/runc/CNI；替换 **containerd** 后需 `systemctl restart containerd`。

### 13.0 本机构建注意（必读）

发行版 / 默认 `make` 常带 **`-ldflags '-s -w'`**，会剥掉符号表与 DWARF。分析用构建应：

| 做法 | 作用 |
|------|------|
| **不要** `-s -w` | 保留符号表与 DWARF |
| `-gcflags 'all=-N -l'` | 关闭优化与内联，栈更可读（二进制更慢，仅分析用） |
| 不要依赖会覆盖 `-N -l` 的其它 `-gcflags` | 见下方 Makefile 坑 |
| `file` + `go version -m` 自检 | 确认 `not stripped` 且含 `all=-N -l` |

**本机（arm64）链接坑：`undefined reference to res_search`**

| 组件 | 处理 |
|------|------|
| containerd / shim / CNI | **`CGO_ENABLED=0`** |
| runc | 保留 CGO（seccomp），加 build tag **`netgo`** |

**不要盲目信 `make ... GODEBUG=1`：**

1. **containerd**：`GODEBUG=1` 会加 `-gcflags=all="-N -l"`，但 Makefile 还会再传 `-gcflags=-trimpath=...`；多个 `-gcflags` 时后者会盖掉前者，`go version -m` 可能只剩 trimpath、**没有** `-N -l`。
2. **shim**：`bin/containerd-shim-runc-v2` 规则**根本不引用** `DEBUG_GO_GCFLAGS`，`GODEBUG=1` 对 `-N -l` **无效**。

因此分析构建一律用下文的 **显式 `go build`**（已在本机验证通过）。

通用自检：

```bash
file /path/to/binary | grep -Ei 'not stripped|with debug_info'
go version -m /path/to/binary | grep gcflags   # 应含 all=-N -l
```

> **注意**：`-N -l` 会明显降低性能，只用于瓶颈分析；测吞吐时请改回优化构建。

---

### 13.1 containerd（daemon）

daemon 侧 `[TRACE]` 由 `pkg/tracing` 写到 stderr → `journalctl -u containerd`。源码树已带 TRACE，无需额外 build tag。

```bash
cd /home/nathan/containerd
TS=$(date +%Y%m%d%H%M%S)

# 显式 go build：CGO=0 + -N -l；勿用 make GODEBUG=1（见 §13.0）
VER=$(git describe --tags --always)
REV=$(git rev-parse HEAD)
CGO_ENABLED=0 go build -buildmode=pie -gcflags 'all=-N -l' \
  -o bin/containerd \
  -ldflags "-X github.com/containerd/containerd/v2/version.Version=${VER} -X github.com/containerd/containerd/v2/version.Revision=${REV} -X github.com/containerd/containerd/v2/version.Package=github.com/containerd/containerd/v2" \
  -tags "urfave_cli_no_docs static_build" \
  ./cmd/containerd

for p in /usr/local/bin/containerd /usr/bin/containerd; do
  [ -e "$p" ] || continue
  sudo cp -a "$p" "${p}.bak.${TS}"
  sudo install -m 0755 bin/containerd "$p"
done
file "$(command -v containerd)"
go version -m "$(command -v containerd)" | grep gcflags
sudo systemctl restart containerd
containerd --version
```

确认 TRACE：创建沙箱后  
`journalctl -u containerd --since '5 min ago' | grep '\[TRACE\]' | head`。

---

### 13.2 containerd-shim-runc-v2

当前树已默认启用 TRACE（`EnsureTracerProvider` + Create 子 span），**不必** `-tags shim_tracing`。

```bash
cd /home/nathan/containerd
TS=$(date +%Y%m%d%H%M%S)

# Makefile 的 GODEBUG 对 shim 无效；必须显式 -gcflags
VER=$(git describe --tags --always)
REV=$(git rev-parse HEAD)
CGO_ENABLED=0 go build -gcflags 'all=-N -l' \
  -o bin/containerd-shim-runc-v2 \
  -ldflags "-X github.com/containerd/containerd/v2/version.Version=${VER} -X github.com/containerd/containerd/v2/version.Revision=${REV} -X github.com/containerd/containerd/v2/version.Package=github.com/containerd/containerd/v2 -extldflags \"-static\"" \
  -tags "urfave_cli_no_docs static_build no_grpc" \
  ./cmd/containerd-shim-runc-v2

for p in /usr/local/bin/containerd-shim-runc-v2 /usr/bin/containerd-shim-runc-v2; do
  [ -e "$p" ] || continue
  sudo cp -a "$p" "${p}.bak.${TS}"
  sudo install -m 0755 bin/containerd-shim-runc-v2 "$p"
done
file "$(command -v containerd-shim-runc-v2)"
go version -m "$(command -v containerd-shim-runc-v2)" | grep gcflags
containerd-shim-runc-v2 -v
```

Create 相关 TRACE span：

| Span | 含义 |
|------|------|
| `shim.container.create` | shim 侧整段 Create |
| `shim.rootfs.mount` | 挂 rootfs |
| `shim.init.create` | 准备 init |
| `shim.runc.create` | 调用 `runc create`（墙钟） |

shim `[TRACE]` 经 log fifo 进入 containerd stderr / journal。

---

### 13.3 runc

runc 使用 `internal/traceutil` 打 `[TRACE]`。因 shim 常重定向 stderr，TRACE **同时写入** `/tmp/runc-trace.log`（`RUNC_TRACE_FILE` 可改；`RUNC_TRACE=0` 关闭）。源码树已带 TRACE。

分析构建：加 `-gcflags 'all=-N -l'`，**不要** `-s -w`；本机需 **`netgo`**（否则易 `res_search` 链接失败）。runc 保留 CGO 以链接 libseccomp。

```bash
cd /home/nathan/runc
TS=$(date +%Y%m%d%H%M%S)

go build -buildmode=pie \
  -gcflags 'all=-N -l' \
  -tags "seccomp urfave_cli_no_docs netgo" \
  -o runc .

for p in /usr/local/sbin/runc /usr/sbin/runc /usr/bin/runc; do
  [ -e "$p" ] || continue
  sudo cp -a "$p" "${p}.bak.${TS}"
  sudo install -m 0755 runc "$p"
done
file "$(command -v runc)"
go version -m "$(command -v runc)" | grep gcflags
runc --version
```

Create 内部 TRACE span：

| Span | 含义 |
|------|------|
| `runc.create` | 整次 `runc create` |
| `runc.spec.load` | 读 OCI config |
| `runc.container.new` | libcontainer Create |
| `runc.container.start` | `Container.Start` |
| `runc.init.start` | 拉起 / 等待 init |
| `runc.cgroup.apply` | 写 cgroup |
| `runc.init.sync` | 与 init 同步（通常最大） |

---

### 13.4 CNI 插件（`/home/nathan/plugins`）

压测常用 `bridge`、`loopback`、`host-local` 等，安装在 **`/opt/cni/bin`**。`build_linux.sh` 默认不 strip；分析请显式加 debug gcflags，且**不要**自行加 `-ldflags '-s -w'`。本机需 **`CGO_ENABLED=0`**。

```bash
cd /home/nathan/plugins
TS=$(date +%Y%m%d%H%M%S)

# 构建全部插件到 ./bin（带 debug；CGO=0 避免 res_search）
CGO_ENABLED=0 ./build_linux.sh -gcflags 'all=-N -l'

# 或只编关心的插件：
# CGO_ENABLED=0 go build -mod=vendor -gcflags 'all=-N -l' -o bin/bridge ./plugins/main/bridge
# CGO_ENABLED=0 go build -mod=vendor -gcflags 'all=-N -l' -o bin/loopback ./plugins/main/loopback
# CGO_ENABLED=0 go build -mod=vendor -gcflags 'all=-N -l' -o bin/host-local ./plugins/ipam/host-local

sudo cp -a /opt/cni/bin "/opt/cni/bin.bak.${TS}"
sudo mkdir -p /opt/cni/bin
sudo install -m 0755 bin/* /opt/cni/bin/
file /opt/cni/bin/bridge /opt/cni/bin/loopback /opt/cni/bin/host-local
go version -m /opt/cni/bin/bridge | grep gcflags
```

确认 CNI 配置指向该目录（`/etc/cni/net.d`，以及 containerd CRI 的 `bin_dir`）。无需重启 containerd；下一轮 CNI ADD 即用新二进制。

---

### 13.5 一键核对（安装后）

```bash
for b in /usr/local/bin/containerd \
         /usr/local/bin/containerd-shim-runc-v2 \
         /usr/local/sbin/runc \
         /opt/cni/bin/bridge; do
  echo "== $b =="
  file "$b"
  go version -m "$b" | grep -E 'gcflags|CGO_ENABLED'
done
# 期望：with debug_info, not stripped；gcflags 含 all=-N -l
```

---

### 13.6 用 `--profile` / `--perf` 验证

**TRACE：**

```bash
cd /home/nathan/sandbox-tests
./scripts/multi_single_cold_start.sh 128-131 4 1 --profile -- \
  --duration 15 --preconfig 5 --cleanup
```

脚本会清空并合并 `/tmp/runc-trace.log`，预期同时看到 `shim.*` 与 `runc.*`。

**perf 符号：**

二进制需保留 DWARF（§13.0，勿 `-s -w`）。抓取默认仍是 **fp**（`-g`）；Go/aarch64 用户态若大量 `[unknown]`，对 **on-CPU** 改用 dwarf（off-CPU 仍为 fp）：

```bash
# 直接抓取
sudo ./scripts/containerd_perf.sh capture \
  --output-dir /tmp/perf-dwarf --duration 30 --call-graph dwarf,65528

# 压测入口
./scripts/multi_single_cold_start.sh 128-131 4 1 \
  --profile --perf --perf-call-graph dwarf,65528 --perf_sandbox -- \
  --duration 30 --cpuset-cpus 128-131 --cleanup
```

（本机 `perf` 的 dwarf `record_size` **上限为 65528**；写 `65536` 会直接失败。脚本会对超限 SIZE 自动钳制。）
打开 `RESULT/perf/*.svg` 或 `perf report`：应能看到  
`github.com/containernetworking/plugins/...`、`github.com/opencontainers/runc/...`、  
`github.com/containerd/containerd/...` 等符号，而不是大量 `[unknown]` / 无名 `elf`。

若仍无符号：确认安装的是刚编的二进制（`file` 显示 not stripped）、`readlink /proc/<pid>/exe` 指向该路径、且 perf 能读该文件。

---

### 13.7 回滚

用安装时的 `.bak.<时间戳>` 覆盖对应路径（CNI 整目录备份为 `/opt/cni/bin.bak.<TS>`）；回滚 containerd 后执行 `sudo systemctl restart containerd`。CNI 回滚后无需重启 daemon。

---

## 14. 复现与分析命令

```bash
RESULT=tmp/containerd-0-127_workers-cores-128-255_workers-nums-127_sandbox-0-255

cat "$RESULT/profile"
cat "$RESULT/resources/report.md"
python3 scripts/resource_analyzer.py "$RESULT"

less "$RESULT/pprof/pprof_analysis.txt"
scripts/containerd_pprof.sh analyze "$RESULT/pprof"
go tool pprof -http=:8080 "$RESULT/pprof/cpu.pprof"

ls "$RESULT/perf"/*.svg
```

```bash
./scripts/multi_single_cold_start.sh 128-255 128 1 \
  --profile --pprof --perf --resources \
  -- --duration 60 --cpuset-cpus 0-255 --cpuset-mems 0-1 --preconfig 50
```

带 TRACE / debug 符号的编译安装见 **§13**（含 CNI `/home/nathan/plugins`）。

---

## 15. 总结

| 层次 | 结论 |
|------|------|
| 端到端（基线） | 128 并发 P95 ≈ **15.6s**，吞吐约 **12.8** 沙箱/s |
| 端到端（关 printk，`0d91342dba12`） | P95 ≈ **13.1s**，吞吐约 **15.1** 沙箱/s；`cni.setup` Avg **5.15→1.21s** |
| 端到端（关 printk + `ipMasq: false`） | P95 ≈ **10.7s**，吞吐约 **17.3** 沙箱/s；`cni.setup` Avg **1.21s→386ms**；iptables on-CPU **~25%→0%** |
| 端到端（同上 + host-local 预填 5000） | `cni.setup` Avg **386ms→8.83s**（约 ×23）；CNI 再次主导 `cri.sandbox.run` |
| 最大阶段（基线 profile） | **CNI 配网** 与 **shim/NewTask** 为主 |
| 关 printk 后主阶段 | **`client.NewContainer` ~30%**；CNI 降至 ~14%；NewTask/cgroup 也大幅变快 |
| 再关 ipMasq 后主阶段（目录较干净） | **`container.NewTask` ~36%**；CNI 仅 ~6%；iptables 消失 |
| 预填 5000 后主阶段 | **`cni.setup` / bridge ~8.8s**；NewTask/NewContainer Avg 骤降（队头在 IPAM） |
| 关 printk 副作用 | metadata/snapshotter Avg **升约 3–4×**（被暴露）；iptables 相对更显眼；idle↓/usr↑ |
| 瓶颈 A 深挖 | CNI 高时延 → **全局 `rtnl_mutex`**（bridge / loopback / netns 共用） |
| 瓶颈 A 持锁放大 | bridge `br_set_state` → `br_info` → **串口 `printk`**（对照实验已验证，见 §7.5） |
| 瓶颈 A 配置叠加 | **`ipMasq`→xtables**；出网改节点级 MASQ；**host-local Walk**（预填对照已验证） |
| 瓶颈 B / C / D | shim 创建；metadata DB；containerd 4 核放大 |
| 非主因 | 磁盘、内存 |

**一句话**：基线下 CNI 配网最重，perf 下钻到 **`rtnl_mutex` 串行**；持锁路径上 **`br_info`→串口 `printk` 是高杠杆放大器**（关掉后吞吐约 12.8→15.1/s、`cni.setup` 约降到 1/4）。其上再关 **`ipMasq`**，吞吐约 15.1→17.3/s、`cni.setup` 再降到约 386ms。目录较干净时瓶颈换位到 **NewTask**；**host-local 预填 5000** 后 `cni.setup` 又升到约 8.8s，扫盘可重新主导 CNI。带 TRACE / debug 符号的编译安装见 **§13**。

---

## 修订记录

| 日期 | 说明 |
|------|------|
| 2026-07-16 | 基于四类数据初稿 |
| 2026-07-16 | 补充 `rtnl_mutex` 分析 |
| 2026-07-16 | **重构结构**：观测 → 瓶颈候选 → 逐项深挖；以 CNI 时延引出 RTNL，弱化与 iptables 的捆绑叙述 |
| 2026-07-16 | §7.3 补充：`rtnl_mutex` 等锁让出 CPU、持锁跑临界区；让出 CPU ≠ 释放锁 |
| 2026-07-16 | §7.5 补充：火焰图 `printk` 来自 bridge `br_set_state`/`br_info`，经 PL011 串口放大 RTNL 持锁 |
| 2026-07-16 | §8.2：shim Create 子 span 下钻说明（`shim.runc.create` 等） |
| 2026-07-16 | **§13**：补充 containerd / shim / runc 带 TRACE 的编译安装与验证 |
| 2026-07-16 | **§13**：补充 debug 符号构建（`GODEBUG=1` / `-N -l`、禁 `-s -w`）及 CNI（`/home/nathan/plugins` → `/opt/cni/bin`），便于 perf 解析符号 |
| 2026-07-16 | **§13**：按本机实测改写：显式 `go build` + `-N -l`；`CGO_ENABLED=0` / runc `netgo`；注明 Makefile `GODEBUG` 对 containerd/shim 的坑 |
| 2026-07-17 | §7.5：写入内核 `0d91342dba12` 关 printk 对照（吞吐 ~12.8→15.1/s，`cni.setup` 5.15→1.21s） |
| 2026-07-17 | §7.5：补充关 printk 后 containerd 核 idle ~12%→1%、usr↑——等锁空闲被有效工作吃掉 |
| 2026-07-17 | §7.5：补充关 printk 后阶段换位（NewContainer 成头号）、NewTask/cgroup 连带变快、metadata/snapshotter 变慢、iptables 相对更显眼 |
| 2026-07-17 | §7.5：写入 `ipMasq: false` 对照（吞吐 15.1→17.3/s，`cni.setup` 1.21s→386ms，iptables on-CPU ~25%→0%；NewTask 成新头号） |
| 2026-07-17 | §7.5：补充原 CNI per-sandbox 规则 vs 节点级 MASQ；`setup.sh --ip-masq false` 自动 ensure 出网规则 |
| 2026-07-17 | §13：补充 on-CPU `--call-graph dwarf`（默认仍 fp；仅影响 on-CPU）以减少 Go `[unknown]` |
| 2026-07-17 | §7.5：写入 host-local 预填 5000 对照（`cni.setup` 386ms→8.83s；`hostlocal_prefill.sh`） |
