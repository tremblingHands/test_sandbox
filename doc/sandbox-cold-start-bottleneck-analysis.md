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

本次 CNI 配置开启了 `ipMasq: true`，perf 中还能看到 `xtables-nft-multi` / `iptables`：每沙箱写 `CNI-*` MASQUERADE 链会额外引入 **xtables 全局锁**。

这是 **CNI 桶内、与当前配置相关的叠加因素**，不是「配网慢」的唯一定义，也与 `rtnl_mutex` 不是同一把锁：

| 机制 | 触发 | 与「CNI 时延」关系 |
|------|------|-------------------|
| **`rtnl_mutex`** | 链路/netdev 配置（bridge、loopback、netns lo） | **配网主路径上的结构性串行**；换 CNI 形态也常仍存在 |
| **串口 `printk`**（本机） | bridge `br_set_state` → `br_info` | 拉长 RTNL 持锁；调低 console_loglevel 可验证 |
| **xtables**（本配置） | `ipMasq` 写 nat | 可叠加恶化；`ipMasq: false` 可去掉，**但不取消 RTNL** |

对照实验时需分开看：关 masquerade 主要验证 xtables；`dmesg -n 4` 验证串口日志；减 veth/bridge 或跳过 CNI（如 ipvlan / hostNetwork）才更直接打到 RTNL 竞争。

### 7.8 小结（瓶颈 A）

**CNI 配网是最大时间阶段；下钻后主因是全局 `rtnl_mutex` 把 netns/lo/bridge/veth 等操作串行化。** 等锁者会让出 CPU，持锁者主要在占核做临界区工作（亦可在持锁期间 sleep，但锁不释放）。持锁路径上 bridge STP 的 **`br_info`→串口 `printk`** 会额外占 CPU 并拉长持锁（§7.5）。本配置下的 masquerade/iptables 是同桶内的额外开销，应与 RTNL / 日志开销分开评估。
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

安装新 shim 后，将 **containerd + shim** 的 `[TRACE]` 合并进同一日志，再用 `scripts/trace_analyzer.py --summary-tree` 即可看到子阶段占比。亦可继续用 `--perf_sandbox` 交叉验证。

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
| C. 仅关 `ipMasq` | 去掉本配置的 xtables 叠加 | `cni.setup` 可能下降；**`rtnl_*` / loopback 仍在** |
| C2. `dmesg -n 4`（压测前） | 抑制 bridge STP INFO 上串口 | `pl011_console_write` / `printk` 帧大降；`br_info` 仍执行，RTNL 仍在 |
| D. workers 32 / 64 / 128 | 锁竞争曲线 | P95 非线性上升 → 确认全局锁/漏斗 |
| E. containerd 核 4 → 16+ | 瓶颈 D | 饱和缓解；锁等待可能仍在 |
| F. 同配置 `--profile` + perf 对比 | 量化 | 分开看 bridge/loopback span 与 `rtnl_*` vs xtables |

中期：减少 `metadata.sandbox.Update` 持锁；snapshotter 预热；shim 路径优化；压测加 `--perf_sandbox`。

不建议优先：只加内存/换盘；未上 K8s 就为「减创建路径配网锁」去部署 Cilium/Calico；指望「关掉 loopback 插件」消除 RTNL（netns 仍会注册 lo，且 CRI 默认仍挂 loopback）。

---

## 13. 复现与分析命令

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

---

## 14. 总结

| 层次 | 结论 |
|------|------|
| 端到端 | 128 并发 P95 ≈ **15.6s** |
| 最大阶段（profile） | **CNI 配网 ~49%**，**shim/NewTask ~41%** |
| 瓶颈 A 深挖 | CNI 高时延 → **全局 `rtnl_mutex`**（bridge / loopback / netns 共用） |
| 瓶颈 A 持锁放大 | bridge `br_set_state` → `br_info` → **串口 `printk`**（~6.7%，见 §7.5） |
| 瓶颈 A 配置叠加 | 本环境 `ipMasq` 额外引入 xtables（与 RTNL 分开看） |
| 瓶颈 B / C / D | shim 创建；metadata DB；containerd 4 核放大 |
| 非主因 | 磁盘、内存 |

**一句话**：先由 profile 看到 CNI 配网最重，再由 perf 下钻到 **`rtnl_mutex` 全局串行**（含 loopback）；持锁路径上还有 bridge STP 日志打到串口的 **`printk` 放大**；shim、metadata DB 与 4 核漏斗是并列的其它瓶颈；iptables/masquerade 只是当前 CNI 配置下的叠加项，不是整篇分析的主线。

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
