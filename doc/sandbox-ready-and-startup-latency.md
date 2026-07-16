# 沙箱 Ready 语义与启动时延评估

## 1. 文档概述

### 1.1 背景

用 `crictl` 创建 Pod 沙箱时，评估「成功创建沙箱的时延」需要先统一两个问题：

1. **Ready 何时置位？** `crictl pods` / `inspectp` 看到的 READY 含义是什么？
2. **启动成功如何定义？** 若要求「沙箱环境中的程序开始运行后才算启动成功」，终点应落在哪一环？

本文基于 containerd CRI（`/home/nathan/containerd`）、runc（`/home/nathan/runc`）、CNI plugins（`/home/nathan/plugins`）代码路径说明原理，并给出可复现的评估方式。

### 1.2 相关代码路径

| 组件 | 路径 |
|------|------|
| containerd | `/home/nathan/containerd` |
| runc | `/home/nathan/runc` |
| CNI plugins | `/home/nathan/plugins` |
| 创建流程 trace 文档 | `containerd/docs/pod-creation-flow.md` |
| 冷启动瓶颈分析 | `doc/sandbox-cold-start-bottleneck-analysis.md` |
| 性能评估总方案 | `doc/ai-agent-sandbox-performance-evaluation.md` |

---

## 2. Ready 何时置位

### 2.1 CRI 语义

`crictl pods` 里的 **READY** 是 CRI 的 `SANDBOX_READY`，**不是** Kubernetes Pod Ready（无 readinessProbe、无业务容器健康检查）。

内部状态机（`internal/cri/store/sandbox/status.go`）：

```
Create/Run ──► READY ──Stop/Exit──► NOTREADY ──Remove──► DELETED
                 ▲
                 │ Load + Start 成功
```

| 内部状态 | CRI 状态 | 含义 |
|----------|----------|------|
| `StateReady` | `SANDBOX_READY` | **sandbox（pause）容器进程在跑** |
| `StateNotReady` | `SANDBOX_NOTREADY` | sandbox 容器不在跑（网络等资源可能仍在） |
| `StateUnknown` | 对外多为 NOTREADY | 状态加载失败等 |

### 2.2 置 Ready 的时刻

`crictl runp` → `RunPodSandbox` **整条链路成功结束时**立刻置 Ready。关键赋值在 pause 容器 `task.Start` 成功之后：

```go
// internal/cri/server/sandbox_run.go
status.State = sandboxstore.StateReady
// 注释：Set the pod sandbox as ready after successfully start sandbox container.
```

podsandbox controller 侧同样在 `task.Start` 成功后更新：

```go
// internal/cri/server/podsandbox/sandbox_run.go
if err := task.Start(ctx); err != nil { ... }
status.Pid = pid
status.State = sandboxstore.StateReady
```

**结论**：`RunPodSandbox` 返回前即为 Ready；之后 `crictl pods` / `inspectp` 即可看到 `SANDBOX_READY`。

### 2.3 置 Ready 前必须成功的步骤

```
crictl runp
  └─ RunPodSandbox
       ├─ ① 创建 netns
       ├─ ② CNI Setup（bridge/portmap/... 配 veth、IP）
       ├─ ③ StartSandbox
       │     ├─ NewContainer（pause 镜像）
       │     ├─ NewTask（起 shim → runc create）
       │     └─ task.Start（runc start，pause 跑起来）
       ├─ ④ status.State = StateReady   ← 变成 Ready
       └─ ⑤ 挂 exit monitor，后台等 pause 退出
```

- CNI 失败 → 到不了 Ready，`runp` 报错回滚。
- runc/shim 创建或启动 pause 失败 → 不会 Ready。
- Ready **不依赖**业务容器（`create`/`start`）；那些是后续步骤。

### 2.4 Ready 何时变回 NotReady

pause 退出或 `stopp` 时，exit monitor 将状态改为 `StateNotReady`：

```go
// internal/cri/server/events.go — handleSandboxExit
status.State = sandboxstore.StateNotReady
status.Pid = 0
```

注意：`NOTREADY` 只表示 sandbox 容器不在跑；网络等资源往往还在，仍需 `stopp`/`rmp` 清理。

### 2.5 与 K8s Pod Ready 的区别

| | CRI sandbox Ready（crictl） | K8s Pod Ready |
|---|---|---|
| 含义 | pause 在跑 | 容器 Ready + 条件汇总 |
| 何时 | `RunPodSandbox` 成功结束 | kubelet 根据探针等判断 |
| 谁管 | containerd CRI 内存状态 | kubelet |

---

## 3. 「程序开始运行」与 Ready 的对应关系

### 3.1 评估定义（本文采用）

> **沙箱启动成功** = 沙箱运行环境中的用户进程（pause）**已经开始执行**，而不仅是网络/命名空间就绪。

### 3.2 runc create vs start

对 pause 沙箱，containerd 走 **create + start** 两步：

| 阶段 | 操作 | 环境状态 | 进程状态 |
|------|------|----------|----------|
| `NewTask` | `runc create` | netns/cgroup/rootfs 已建好 | init 在等 `exec.fifo`，**还没 exec** |
| `task.Start` | `runc start` | 不变 | 打开 fifo → **execve(pause)** → 进程真正运行 |

runc 标准 init 在 exec 前会阻塞在 exec fifo 上（`libcontainer/standard_init_linux.go`）：

```go
// Wait for the FIFO to be opened on the other side before exec-ing the
// user process.
fifoFile, err := pathrs.Reopen(l.fifoFile, unix.O_WRONLY|unix.O_CLOEXEC)
...
fifoFile.Write([]byte("0"))
// 随后 execve 用户进程（pause）
```

`runc start`（`container.Exec()`）打开该 fifo，init 写完后才 `execve`。containerd 在 `task.Start` 成功后才标 Ready。

### 3.3 等价关系

```
「程序开始跑」≈ task.Start / runc start 成功 ≈ CRI SANDBOX_READY
```

三者基本同一点，仅差 gRPC / 状态写入的微小开销。

**不要**把下列时刻当成「程序已跑」：

| 时刻 | 为何不够 |
|------|----------|
| CNI Setup 完成 | 只有网络，进程未 exec |
| `NewTask` / `runc create` 完成 | 环境就绪，pause 仍在等 fifo |
| `ListPodSandbox` 查到 READY | 是查询结果，不是创建完成时刻本身（可用作校验，不宜作唯一计时终点） |

---

## 4. 启动时延评估方式

### 4.1 指标定义

```
沙箱启动时延 = T(task.Start 成功) − T(RunPodSandbox 请求到达)
等价于：pause 进程 execve 完成时刻 − 请求到达时刻
```

实验条件建议固定：

- pause 镜像已预拉取（不含 pull）
- 同一 CNI 配置、同一 runtime handler（runc）
- 冷启动：每次 `stopp` + `rmp` 后重跑
- 样本量 ≥ 100，报告 **p50 / p95 / p99**

### 4.2 方案 A：端到端（日常首选）

适合 `crictl` 场景，终点与 Ready / 程序已跑一致。

```bash
# 预热，避免 pause 镜像 pull 干扰
crictl pull registry.k8s.io/pause:3.9   # 或环境实际使用的 pause 镜像

for i in $(seq 1 100); do
  /usr/bin/time -f '%e' crictl runp pod.json
  ID=$(crictl pods -q --name <pod-name> | head -1)
  crictl stopp "$ID" 2>/dev/null
  crictl rmp "$ID" 2>/dev/null
done
```

| 项 | 说明 |
|----|------|
| 起点 | `crictl runp` 发起 |
| 终点 | 命令返回（内部已含 CNI + create + start） |
| 统计 | p50 / p95 / p99，去掉首尾异常值 |
| 注意 | 第一次可能含镜像拉取，需预热或剔除 |

本仓库压测脚本（高并发）：`scripts/multi_single_cold_start.sh`。

### 4.3 方案 B：分阶段拆解（定位瓶颈）

用 containerd trace / metrics 拆阶段：

```
T0 ──► T1 ──► T2 ──► T3 ──► T4
请求   CNI完成  create完成  start完成  RunPodSandbox返回
                         ★ 程序已跑
```

| 阶段 | Trace span | Prometheus metric（示意） |
|------|------------|---------------------------|
| 网络 | `cni.setup_pod_network` | `sandbox_create_network` |
| 创建 | `container.NewTask`（含 shim + runc create） | 含在 `sandbox_runtime_create` |
| **启动（程序 exec）** | **`client.task.Start`** | 同上 runtime create 末尾 |
| 全流程 | `cri.sandbox.run` | — |

典型单次冷启动占比（低并发参考，见 `pod-creation-flow.md`）：

| 阶段 | 典型占比 | 说明 |
|------|----------|------|
| CNI | ~50%+ | 插件 binary、iptables 等 |
| NewTask | ~25–40% | shim 启动 + runc create |
| **task.Start** | **~3%** | **runc start，pause 真正 exec** |
| metadata / 其他 | 余量 | BoltDB、NewContainer 等 |

高并发下各阶段会被放大，详见 `sandbox-cold-start-bottleneck-analysis.md`。

若严格对应「程序开始跑」，**终点应选在 `client.task.Start` 结束**，而不是 `NewTask` 结束。

### 4.4 方案 C：内核级验证（严格校验）

在 pause 进程上抓 **execve 完成** 时刻，排除上层状态机误差：

```bash
# bpftrace 示例（按环境过滤 comm / path）
bpftrace -e '
tracepoint:syscalls:sys_exit_execve
{
  printf("execve ret=%d pid=%d comm=%s\n", args->ret, pid, comm);
}'
```

或 `perf trace -e syscalls:sys_enter_execve`，按 sandbox ID / pause 路径过滤。

| 项 | 说明 |
|----|------|
| 起点 | `RunPodSandbox` 请求到达（或 `crictl runp` 发起） |
| 终点 | pause 二进制 `execve` 返回成功 |
| 用途 | 校验「`task.Start` ≈ 真实进程已跑」；一般不做日常监控 |

### 4.5 方案 D：OCI Hook 埋点

在 sandbox OCI spec 中增加 hook，在进程 exec 后打点：

```json
"hooks": {
  "poststart": [{
    "path": "/usr/local/bin/latency-hook",
    "args": ["poststart", "--mark", "sandbox-running"]
  }]
}
```

`poststart` 语义为 **exec 之后**，与「程序开始跑」一致。hook 可将时间戳写入共享文件或 histogram。

### 4.6 方案选型建议

| 场景 | 推荐 |
|------|------|
| 日常 / CI 评估 | **A**（端到端）+ 可选 **B**（trace 拆阶段） |
| 优化前后对比 | **A** 报 p50/p95/p99；**B** 看 CNI vs NewTask vs Start 占比 |
| 论文 / 严格定义校验 | **C** 或 **D**，确认与 `task.Start` 一致 |

---

## 5. 时序总览

```
crictl runp
  └─ RunPodSandbox                          ← 计时起点 T0
       ├─ netns + CNI                       ← 主要耗时，但进程未跑
       ├─ NewTask (runc create)             ← 环境就绪，pause 等 fifo
       ├─ task.Start (runc start)           ← ★ 终点：程序开始跑 / Ready
       └─ State = SANDBOX_READY
  └─ 返回 PodSandboxId
```

**一句话**：用 crictl 评估时，沙箱在 **CNI 配好且 pause 经 shim/runc start 启动成功** 后立刻 Ready；「成功创建时延」应量到 **`task.Start` / Ready**，本质是 infra 容器（pause）已活，不是业务就绪。

---

## 修订记录

| 日期 | 说明 |
|------|------|
| 2026-07-16 | 初稿：Ready 置位原理、create/start 与 exec 语义、四种时延评估方式 |
