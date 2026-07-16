# 沙箱冷启动性能瓶颈分析

## 1. 文档概述

### 1.1 背景

在 AI Agent / 多租户场景下，Pod 沙箱冷启动延迟直接影响并发创建吞吐。本文基于一次高并发压测结果，结合 **profile（trace）**、**pprof**、**perf**、**resources** 四类数据，定位 containerd + bridge CNI 场景下的主要瓶颈。

### 1.2 分析目标

- 量化 `cri.sandbox.run` 各阶段耗时占比
- 交叉验证用户态（pprof）与内核态（perf）热点
- 排除次要因素（磁盘、内存）
- 给出可复现的优化与对比实验建议

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
| CNI | bridge + **`ipMasq: true`**（`/etc/cni/net.d`） |

### 2.2 端到端延迟（resources）

| 指标 | 数值 |
|------|------|
| 总沙箱数 | 747 |
| P50 / P95 / P99 | **11151 / 15617 / 17139 ms** |
| 资源瓶颈标记 | **`containerd_cpu_saturation`** |
| Spike（约 51s） | P95 ≈ 16.3s，同时约 616 个沙箱活跃 |

**结论（宏观）**：128 路并发下冷启动 P95 约 **15.6s**；系统标记 containerd CPU 饱和。

---

## 3. Profile：阶段耗时分解

来源：`profile` 文件中 `cri.sandbox.run` 树（采样约 145 次完整 run）。

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
├── cni.setup_pod_network ≈ 5.77s   (~49%)   ← bridge（主）+ loopback（同走 RTNL）
├── container.NewTask     ≈ 4.76s   (~41%)   ← shim 创建
├── client.NewContainer   ≈ 0.57s   (~5%)
├── client.task.Start     ≈ 0.33s   (~3%)
└── metadata / status     分散多次
```

**profile 结论**：单次冷启动时间几乎被 **CNI（bridge 为主，loopback 亦占约 1s）** 与 **shim 创建** 平分；metadata 单次不高，但 Update 次数多、高并发下会被锁放大。CNI 阶段内部还受内核全局 **`rtnl_mutex`** 串行化（见 §8）。

---

## 4. pprof：containerd 用户态热点

来源：`pprof/pprof_analysis.txt`、`pprof/svg/`。

### 4.1 CPU Profile

| 热点 | flat% | 含义 |
|------|-------|------|
| `Syscall6` | **36.2%** | 大量系统调用 |
| `bbolt.(*Tx).write` | **12.5%** | metadata BoltDB 写盘 |
| runtime GC / malloc | 若干 | 高并发分配压力 |

### 4.2 Mutex（测试窗口增量）

| 热点 | 占比 | 调用链含义 |
|------|------|------------|
| `sync.(*Mutex).Unlock` 相关等待 | **~80%** | 等在 `metadata.(*DB).Update` |
| `RunPodSandbox` → `metadata.update` | ~80% cum | 128 路 gRPC 抢同一把 DB 锁 |
| `snapshotter.Prepare` | ~19% | 快照路径也争用 DB |
| `gcScheduler` / `GarbageCollect` | ~19% | GC 与创建路径争锁 |

### 4.3 Block / Goroutine

- Block：**~95%** `runtime.selectgo` → 大量 goroutine 在等 CNI / shim / gRPC。
- Goroutine 数：约 **1201 → 6226**，随沙箱数增长。

**pprof 结论**：containerd 内部主要卡在 **metadata 全局锁 + bbolt 写**；CNI/shim 表现为阻塞等待（select），与 profile 中长时间阶段一致。

---

## 5. perf：内核态与 off-CPU

来源：`perf/on_cpu_1-4.svg`、`perf/off_cpu_1-4.svg`（仅采样 **containerd 绑定核 1–4**）。

### 5.1 On-CPU

| 符号 / 进程 | 相对显著 | 含义 |
|-------------|----------|------|
| **`[xtables-nft-multi]` / `iptables`** | 极高 | CNI `ipMasq` 改写 iptables/nft 规则 |
| **`bridge`** | 高 | bridge CNI 数据路径 |
| **`rtnl_setlink` / `rtnl_*` / `rtnl_lock*`** | 高 | 全局 **`rtnl_mutex`** 保护下的链路配置（见 §8） |
| **`loopback`（CNI 插件进程）** | 中高（~2.3%） | `LinkSetUp(lo)`，同样抢 RTNL |
| **`netlink_*` / `rtnetlink_*`** | 高 | 配网、路由、接口操作入口 |
| **`runc` / `containerd-shim`** | 高 | 启动 shim |
| **`bbolt.(*Tx).write`** | 中 | metadata 持久化 |
| `nf_tables_dump_rules` 等 | 中 | 规则表遍历（规则数膨胀时更重） |

火焰图中与 RTNL 直接相关的显著帧（on-CPU，核 1–4）：

| 符号 | 约占比 | 含义 |
|------|--------|------|
| `rtnl_setlink` | **~7.3%** | `RTM_SETLINK` 持锁改链路（veth/lo 起停、master 等） |
| `rtnl_newlink` | ~0.3–0.5% | 新建链路（如 veth） |
| `rtnl_lock` / `rtnl_lock_killable` | 分散累计 | 抢锁本身与持锁前等待路径 |
| `loopback` / `loopback_net_init` | ~2.3% / ~0.5% | lo 相关：CNI 插件 + netns 内注册 lo |

### 5.2 Off-CPU

| 热点 | 含义 |
|------|------|
| **`futex` / `__schedule`** | 等锁、调度、睡眠 |
| **`containerd-shim` 栈** | shim 侧等待 |
| `runc` / `bridge` | 创建与配网过程中的阻塞 |
| **`loopback_net_init` → `register_netdev` → `rtnl_lock_killable`** | 建 netns 注册 `lo` 时等 **`rtnl_mutex`** |

**perf 结论**：与 profile 对齐——**bridge + iptables**、**RTNL（`rtnl_mutex`）** 与 **shim** 是内核侧三大热点；配网路径上 bridge / loopback / netns 创建**共用一把 RTNL 锁**；大量时间处于 **futex 等待**（与 pprof mutex/block 一致）。

> 注意：本次 perf **未覆盖** worker 核 128–255。若要分析沙箱侧 CPU，需加 `--perf_sandbox`。

---

## 6. resources：系统资源与关联

来源：`resources/report.md`、`resources/summary.json`。

### 6.1 关键指标

| 指标 | 观察 | 解读 |
|------|------|------|
| `containerd_cpu_saturation` | 已标记 | containerd 4 核成为漏斗 |
| `k8s_io_cpu_pct` vs P95 | Pearson **r ≈ 0.59** | 延迟升高时 CRI 路径 CPU 也升高 |
| `io_iostat.util_pct` vs P95 | **r ≈ -0.66** | 磁盘利用率与延迟负相关，**非主因** |
| `io_iostat.w_await_ms` | P50 ≈ 0.17ms | 写延迟很低 |
| `load_1m` | 最高 ≈ 112 | 系统调度压力大 |
| `context_switches_per_s` | 最高 ≈ 547 万/s | 极高上下文切换 |
| 内存 / NUMA | 充足 | **排除**内存瓶颈 |

### 6.2 Spike

约 **51s** 处：P95 ≈ 16.3s，沙箱数 ≈ 616，伴随 high_containerd_cpu / high_k8s_io_cpu。符合「高并发叠加 → 锁与 CNI 更慢」的模式。

---

## 7. 瓶颈排序（四类数据交叉）

```
① CNI 创建路径：两把内核全局锁叠在一起
   ├─ iptables/xtables（ipMasq）
   │    profile: cni.setup ≈ 49%；perf: xtables / iptables
   │    机制: 每沙箱写 CNI-* nat 链，xtables 全局锁
   └─ rtnl_mutex（RTNL，影响极大，见 §8）
        profile: bridge + loopback 同属 cni.setup
        perf:    rtnl_setlink ~7%+；loopback / loopback_net_init 等锁
        机制: 每沙箱多次 RTM_NEWLINK/SETLINK；netns 建 lo 也抢同一把锁

② metadata bbolt 全局锁
   pprof:   mutex ~80% 在 DB.Update；CPU 含 bbolt.write
   机制:    128 路 RunPodSandbox 串行化在 metadata DB

③ shim / runc 创建
   profile: NewTask ≈ 41%（shim.task.create 为主）
   perf:    off-CPU futex + shim/runc
   机制:    每沙箱 fork/exec shim，等待重

④ containerd 仅 4 核漏斗
   resources: containerd_cpu_saturation
   机制:    上述竞争全部挤在 CPU 1–4

⑤ 磁盘 / 内存 — 已排除
```

### 7.1 证据链示意

```
profile:  CNI 5.8s（bridge+loopback） + NewTask 4.8s ≈ 11.7s
              │                              │
perf:     xtables + rtnl_mutex           shim/runc/futex
          (bridge / lo / netns)              │
              │                              │
pprof:    setupPodNetwork / selectgo     mutex/DB + selectgo
              │                              │
resources: containerd 4 核饱和 + k8s_io CPU 随延迟升高
```

---

## 8. 内核全局锁：`rtnl_mutex`（影响极大）

CNI 阶段不只是「bridge 慢」或「iptables 慢」——**几乎所有链路配置都串在内核全局 `rtnl_mutex` 上**。高并发下，128 路沙箱的 netns / loopback / bridge / veth 操作互相阻塞，是 `cni.setup_pod_network` P95 拉到 ~10s 的核心机制之一。

### 8.1 锁是什么、谁在拿

| 项 | 说明 |
|----|------|
| 锁 | `net/core/rtnetlink.c` 中的 **`rtnl_mutex`** |
| 入口 | `rtnl_lock()` / `rtnl_lock_killable()`；用户态经 `sendto` → `rtnetlink_rcv_msg` → doit |
| 范围 | **主机全局一把**（不按 netns 分锁）；持锁期间跑 `rtnl_newlink` / `rtnl_setlink` / `register_netdev` 等 |
| 用户态 | CNI 经 `vishvananda/netlink`：`LinkAdd`、`LinkSetMaster`、`LinkSetUp`、`LinkByName` 等 |

### 8.2 本压测中谁在用这把锁（不只是 bridge）

火焰图与源码交叉：**bridge、loopback、建 netns 注册 lo，都抢同一把锁**。

| 调用方 | 典型用户态操作 | 内核路径（示意） | 证据 |
|--------|----------------|------------------|------|
| **建 netns** | 创建沙箱网络命名空间 | `loopback_net_init` → `register_netdev` → **`rtnl_lock_killable`** | off-CPU：`loopback_net_init` / `register_netdev` / `rtnl_lock_killable` |
| **CNI loopback** | `netlink.LinkSetUp(lo)` | `RTM_SETLINK` → `rtnl_setlink` → `dev_change_flags` | profile：`cni.plugin.loopback` Avg **~1.0s**；on-CPU 进程 `loopback` **~2.3%**；IPv6 `init_loopback` 有 `ASSERT_RTNL()` |
| **CNI bridge** | 建 veth、设 master、起停口 | `rtnl_newlink` / `rtnl_setlink` / `do_set_master` → `br_add_if` 等 | on-CPU：`rtnl_setlink` **~7.3%**；`rtnl_newlink` 可见 |
| 其它 | `getlink`、地址/路由 notifier | `rtnl_getlink`、`inetdev_event` / `fib_*`（多在 RTNL 上下文） | 火焰图中 `rtnl_getlink`、netdev notifier 栈 |

因此：**关掉 iptables（`ipMasq: false`）只能去掉 xtables 那条线，不能去掉 RTNL 竞争**；loopback 看似轻量，但每个沙箱必跑，且与 bridge 串在同一把锁上，会放大尾延迟。

### 8.3 与 iptables（xtables）的关系

本场景 CNI 创建路径上有 **两把互不替代的全局锁**：

```
每沙箱 CNI ADD
├── RTNL（rtnl_mutex）     ← netns lo / LinkSetUp(lo) / veth / bridge
└── xtables（ipMasq）      ← 每沙箱 CNI-* MASQUERADE 链
```

| 锁 | 触发条件 | 关 `ipMasq` 后 | 换 ipvlan / 少链路操作后 |
|----|----------|----------------|--------------------------|
| **`rtnl_mutex`** | 凡改链路/注册 netdev | **仍在**（lo + 仍有的链路操作） | 可减轻（少 veth/bridge），lo 仍可能保留 |
| **xtables** | `ipMasq: true` 写 nat | **消失或大减** | 通常一并消失 |

### 8.4 调用链示意（冷启动一次）

```
RunPodSandbox
  └─ cni.setup_pod_network
       ├─ [netns 创建]  loopback_net_init → register_netdev ──┐
       ├─ cni.plugin.loopback  LinkSetUp(lo) ── RTM_SETLINK ─┼─ rtnl_mutex（全局串行）
       └─ cni.plugin.bridge    veth/newlink/setmaster/up ────┘
            └─（另）ipMasq → iptables / xtables 全局锁
```

### 8.5 对优化解读的含义

- 观察 `cni.setup` 下降时，需区分收益来自 **xtables** 还是 **RTNL**（或两者）。
- A/B 建议：`ipMasq: false` 主要打 xtables；**ipvlan / hostNetwork** 才能明显减少 RTNL 上的 veth/bridge 操作；hostNetwork 还可跳过整段 CNI（含 loopback 插件路径）。
- 并发升高时 P95 非线性恶化，除 metadata DB 外，**RTNL + xtables 双串行** 是重要解释。

---

## 9. 关于 CNI / iptables 的专项说明

当前配置为 **bridge + `ipMasq: true`**：

- 每次 CNI ADD 为沙箱 IP 创建 `CNI-*` nat 链并挂 POSTROUTING MASQUERADE。
- 并发创建时触发大量 `iptables`/`xtables-nft-multi` 调用，与 perf on-CPU 热点一致。
- 同时仍受 **`rtnl_mutex`** 约束（§8）；关 ipMasq 后 RTNL 仍在。
- **换 Calico/Cilium eBPF** 可从根本上去掉这类 per-pod iptables，但需 Kubernetes 与完整数据面；对本机纯 crictl 压测，更直接的是：
  - `"ipMasq": false`（先打掉 xtables）
  - 或改用 **ipvlan**（仓库 `scripts/setup.sh` 已支持；减轻 bridge/veth 的 RTNL 压力）
  - 或压测不需出网时用 hostNetwork 做对照（跳过 CNI，RTNL/xtables 创建路径一并消失）

---

## 10. 优化建议

### 10.1 优先验证（对比实验）

| 实验 | 目的 | 预期 |
|------|------|------|
| A. `ipMasq: false` | 去掉每沙箱 iptables / xtables | `cni.setup` 下降；perf 中 xtables 热点消失；**RTNL 仍在** |
| B. CNI 改为 ipvlan | 去掉 bridge+veth+masq | CNI 下降；iptables 热点消失；**RTNL 竞争减轻**（少 newlink/setmaster） |
| C. hostNetwork 对照 | 跳过 CNI / 少建 netns 配网 | `cni.setup` 接近消失，用于量 RTNL+CNI 上限 |
| D. workers 32 / 64 / 128 | 锁竞争曲线 | P95 随并发非线性上升 → 确认 RTNL/xtables/DB 漏斗 |
| E. containerd 核 4 → 16+ | 缓解 4 核漏斗 | containerd 饱和缓解，总吞吐上升（锁等待可能仍在） |
| F. 同配置加 `--profile` + perf 对比 A/B/C | 量化阶段与锁收益 | 看 bridge/loopback span 与 `rtnl_*` / xtables 帧变化 |

### 10.2 中期（源码 / 架构）

1. 减少 `metadata.sandbox.Update` 次数或缩短持锁时间（对准 pprof mutex）。
2. 评估 snapshotter / 预热，降低 `Prepare` 与 DB 争用。
3. shim 启动路径优化（bundle、pause、进程模型）。
4. 压测时增加 `--perf_sandbox`，覆盖 worker/shim 侧 CPU。
5. 若必须保留 bridge：评估共享 MASQUERADE（减 xtables）；RTNL 侧仍需接受每沙箱链路操作的串行成本。

### 10.3 不建议优先

| 方向 | 原因 |
|------|------|
| 仅加内存 / 换高速盘 | resources 已排除主因 |
| 未上 K8s 就部署 Cilium/Calico | 成本高；本场景热点是 bridge `ipMasq` + **RTNL**，不是 kube-proxy |
| 只关 loopback 插件当「优化」 | lo 常由 netns 创建路径注册；且 CRI 默认仍会挂 loopback；收益有限且易破坏预期 |

---

## 11. 复现与分析命令

```bash
RESULT=tmp/containerd-0-127_workers-cores-128-255_workers-nums-127_sandbox-0-255

# 阶段耗时
cat "$RESULT/profile"

# 资源关联
cat "$RESULT/resources/report.md"
python3 scripts/resource_analyzer.py "$RESULT"

# pprof
less "$RESULT/pprof/pprof_analysis.txt"
scripts/containerd_pprof.sh analyze "$RESULT/pprof"
go tool pprof -http=:8080 "$RESULT/pprof/cpu.pprof"

# perf 火焰图（浏览器打开）
ls "$RESULT/perf"/*.svg
```

压测示例（含四类采集）：

```bash
./scripts/multi_single_cold_start.sh 128-255 128 1 \
  --profile --pprof --perf --resources \
  -- --duration 60 --cpuset-cpus 0-255 --cpuset-mems 0-1 --preconfig 50
```

---

## 12. 总结

| 维度 | 结论 |
|------|------|
| 端到端 | 128 并发下 P95 ≈ **15.6s**，严重偏慢 |
| 最大阶段 | **CNI（~49%，bridge + loopback）** + **shim 创建（~41%）** |
| 用户态 | **metadata DB 锁 + bbolt 写** |
| 内核态 | **两把全局锁：`rtnl_mutex`（链路/lo/veth/bridge）+ xtables（ipMasq）**；另有 shim/futex |
| 架构 | **containerd 4 核** 成为全局漏斗 |
| 非瓶颈 | 磁盘延迟、内存容量 |

**一句话**：本次瓶颈是「高并发 + **RTNL（`rtnl_mutex`，含 loopback）** + bridge/ipMasq 的 **xtables** 串行 + metadata 全局锁 + shim 创建」在「containerd 4 核」上叠加；优先用 **关 ipMasq / 换 ipvlan / hostNetwork 对照** 与 **降并发或扩 containerd 核** 做验证，并区分 xtables 与 RTNL 各自贡献。

---

## 修订记录

| 日期 | 说明 |
|------|------|
| 2026-07-16 | 基于 `tmp/containerd-0-127_workers-cores-128-255_workers-nums-127_sandbox-0-255` 四类数据初稿 |
| 2026-07-16 | 补充 **`rtnl_mutex` 专项分析**（§8）：bridge/loopback/netns 共用 RTNL；与 xtables 双锁关系；更新瓶颈排序与实验建议 |
