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

### 6.2 perf（绑核 1–4）

| 类型 | 观察 |
|------|------|
| on-CPU | 样本稀、几乎看不到 ipvlan/loopback 热路径 |
| off-CPU | containerd 大量 **futex 等待** |

符合模型：**CNI 插件在其它核上跑 / 在内核 RTNL 上睡，containerd 在等子进程退出**。若要继续下钻 ipvlan，应对 **ipvlan / loopback 插件进程** 做 `--perf_sandbox` 或按 PID 采样，而不是只看 containerd 的 1–4 核火焰图。

---

## 7. 机制小结

```text
128 并发 RunPodSandbox
        │
        ├─► attach loopback  ──┐
        │                      ├──► 争用 RTNL / netlink（全局串行）
        └─► attach ipvlan L3 ──┘         │
                                         ▼
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
| 已健康 | NewContainer / NewTask / runc / cgroup / bbolt wait |
| 相对 bridge+v2 | 配网从 **0.1s 级回到数秒级**；其它阶段反而更轻 |
| 根因类属 | 高并发建网的 **RTNL 类全局争用**，换 ipvlan **未消除** |

---

## 8. 优化方向（按杠杆）

1. **对 ipvlan / loopback 进程做 perf**  
   确认是否仍是 `rtnl_mutex`、设备创建、地址/路由配置；检查 printk / 串口日志是否回潮放大持锁。

2. **量化 / 裁剪 loopback**  
   对照「仅 ipvlan」与「ipvlan+loopback」；评估测试场景能否去掉默认 lo，或走 CRI 内部 `bringUpLoopback`。

3. **降并发验证锁模型**  
   降低 worker 数看 `cni.setup` 是否近似线性下降；若是，则坐实全局串行，而非单次 ipvlan 用户态过重。

4. **保持 host-local 干净**  
   避免 `/12` 大网段 Walk / 无索引回潮叠在 RTNL 之上。

5. **非 CNI 优化暂缓**  
   本轮不必优先 bbolt `no_sync`、runc mounts、`CLONE_EMPTY_MNTNS`；等 CNI 回到百毫秒级后再打。

6. **若必须坚持 ipvlan**  
   考虑建网限流 / 批量 / 预热 netns，或评估其它不依赖每沙箱 RTNL 热路径的方案（需单独设计，超出本 profile 范围）。

---

## 9. 复现要点

```bash
# CNI：/etc/cni/net.d/10-mynet.conf 使用本文 §2.2 的 ipvlan-l3
# 压测（示例参数与本轮一致）
scripts/multi_single_cold_start.sh \
  --profile --pprof --perf --resources \
  --duration 60 --preconfig 50 \
  # workers 128 @ 128-255，containerd @ 1-4（以脚本实际参数为准）
```

结果目录命名约定：`profile/ipvlan-l3-containerd-1-4_workers-cores-128-255_workers-nums-128_sandbox-0-255`。

---

## 10. 修订记录

| 日期 | 说明 |
|------|------|
| 2026-07-22 | 初版：基于 `profile/ipvlan-l3-...` 的 TRACE / resources / pprof / perf 分析 |
