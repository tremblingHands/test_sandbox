# containerd 代码中的现成压测工具

## 1. 概述

本文梳理 containerd 源码内**现成**的性能/压测相关能力，以及官方文档（`BUILDING.md`）明确推荐的外部工具。

| 类别 | 工具 | 定位 |
|------|------|------|
| 端到端加压 | `containerd-stress`（`cmd/containerd-stress`） | 对运行中 daemon 做并发生命周期加压 |
| 组件微基准 | `make benchmark` / `go test -bench` | Create/Start、snapshot、GC 等热点 |
| Snapshotter 环境 | `contrib/aws/snapshotter_bench_*` | 在 AWS 上跑 snapshotter benchsuite |
| 外部（文档推荐） | [bucketbench](https://github.com/estesp/bucketbench) | 跨引擎生命周期对比，偏逐步耗时统计 |

构建：`make binaries` 会产出 `containerd-stress`；`make benchmark` 跑 Go 微基准。

---

## 2. `containerd-stress`

### 2.1 用途

对**已经运行**的 containerd daemon，在指定时长与并发度下反复创建/启动/销毁容器（或 CRI Pod），用于稳定性加压、粗粒度吞吐（containers/sec）与错误率观察。

### 2.2 入口与分支逻辑

`main.go` 解析 CLI 后分支：

1. 若 `--metrics` 非空：先起 HTTP metrics 服务，再进入压测（`serve`）
2. 若 `--cri`：走 `criTest`（CRI RuntimeService）
3. 否则：走 `test`（containerd client API）

另有子命令 `density`（`density.go`）：不按时长循环销毁，而是同时拉起 `--count` 个长跑容器，采样 shim 进程 PSS/RSS。

公共准备：

- namespace 固定为 `stress`（client）或 CRI label `pod.namespace=stress`
- 压测前 `cleanup` / `criCleanup` 清掉同 namespace残留
- `context.WithTimeout(..., Duration)`，SIGTERM/SIGINT 取消

### 2.3 默认路径压测逻辑（client API）

实现：`test()` + `ctrWorker`（`worker.go`）。

**准备（不计吞吐分子）：**

1. `containerd.New(address, WithDefaultRuntime(runtime))`
2. `Pull(image, WithPullUnpack, WithPullSnapshotter(snapshotter))`
3. 起 `Concurrency` 个 `ctrWorker` 共享同一 `Client` 与已拉取的 `Image`

**每个 worker 的循环（`ctrWorker.run`）：**

```
while 未超时:
    count++
    id = "{workerId}-{count}"
    t0 = now
    runContainer(id)   # 见下
    成功则 ct.UpdateSince(t0)   # 仅成功计入 metrics 计时
    失败则 failures++（超时 Deadline 不记失败）
```

**单次生命周期（`runContainer`）：**

1. `NewContainer(id, WithSnapshotter, WithNewSnapshot(id, image), WithNewSpec(ImageConfig + Username("games") + ProcessArgs("true")))`
2. defer：`Delete(..., WithSnapshotCleanup)`
3. `NewTask(..., NullIO)`，defer：`task.Delete(..., WithProcessKill)`
4. `task.Wait` → `task.Start` → 阻塞等到 `true` 退出
5. 返回后由 defer 清理 task/container/snapshot

设计要点：进程固定为快速退出的 `true`，从而测的是「create → start → 等退出 → delete」整链，而非长驻业务负载；失败路径故意不计入耗时，避免失败过快抬高吞吐。

**汇总（`run.gather`）：**

- `Total` = 各 worker `count` 之和  
- `ContainersPerSecond = Total / Seconds`  
- `SecondsPerContainer = Seconds / Total`

### 2.4 `--exec` 路径

在默认 `ctrWorker` 之外，再起同等数量的 `execWorker`（`exec_worker.go`）：

1. 每个 worker **先**创建一个长驻容器：`sleep 30d`
2. 循环：`task.Exec(id, Process{Args: ["true"]}, NullIO)` → Wait → Start → 等退出 → Delete process
3. 成功记入 `execTimer`；结果里额外输出 `ExecTotal` / `ExecFailures`

即：生命周期 worker 与 exec worker **并行**加压，exec 测的是已运行 task 上的二次进程创建开销。

### 2.5 `--cri` 路径

实现：`criTest()` + `criWorker`（`cri_worker.go`）。

1. `remote.NewRuntimeService(address)` 连 CRI
2. 每个 worker 循环：
   - 构造 `PodSandboxConfig`（Name=id, Namespace=`stress`, Label）
   - `RunPodSandbox(sbConfig, runtimeHandler)` —— 此处的 `runtimeHandler` 即 CLI `--runtime`
   - defer：`StopPodSandbox` + `RemovePodSandbox`
   - 后台 ticker 轮询 `PodSandboxStatus`（实现上主要用于观测；函数在创建成功后即返回）
3. 成功同样只对成功样本计时

注意：CRI 模式下 `--runtime` 语义是 **CRI RuntimeHandler 名**（配置里 `runtimes` 表的 key，如 `runc`、`kata`），不是直接的 `io.containerd.runc.v2` 字符串（除非你的 handler 就叫这个名字）。

### 2.6 `density` 子命令

1. Pull + unpack（指定 snapshotter）
2. 顺序创建 `count+1` 个容器，进程为 `sleep 120m`，全部 Start 并保持存活
3. 对每个容器 task PID 找父进程（shim），读 `/proc/<shim>/smaps` 累加 `Rss` / `Pss`
4. 输出 JSON：`pss`、`rss`、`pssPerContainer`、`rssPerContainer`

测的是**同时存活**时的 shim 内存密度，不是吞吐循环。

### 2.7 `--runtime` 可配置选项

CLI 默认值来自 `plugins.RuntimeRuncV2`，即 **`io.containerd.runc.v2`**。

| 使用场景 | `--runtime` 含义 | 典型取值 |
|----------|------------------|----------|
| 默认 / client API（`test`） | 传给 `WithDefaultRuntime`，作为容器默认 OCI runtime 类型 | **`io.containerd.runc.v2`**（Linux 默认，见 `defaults.DefaultRuntime`） |
| | Windows 对应常量 | **`io.containerd.runhcs.v1`**（`plugins.RuntimeRunhcsV1`） |
| `--cri` | CRI **RuntimeHandler** 名称 | 须与 daemon `config.toml` 里 `[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.<name>]` 的 **`<name>`** 一致，例如常见配置：`runc`、`kata`、自定义 handler；空字符串则用 CRI 的 `default_runtime_name` |

说明：

- client API 路径下，值必须是 containerd 已注册的 **runtime type**（shim 插件 ID）。仓库内内置常量主要是 `io.containerd.runc.v2` / `io.containerd.runhcs.v1`；第三方 shim（如 kata）需已安装并可被解析，才能用对应 type / 通过 CRI handler 间接指定。
- CRI 路径下**不要**把 handler 名和 `runtime_type` 混淆：handler 是 map key；`runtime_type` 才是类似 `io.containerd.runc.v2` 的字段。

### 2.8 `--snapshotter` 可配置选项

CLI 默认：**`overlayfs`**（与 Linux `defaults.DefaultSnapshotter` 一致）。

该字符串作为 snapshotter **插件 ID**，用于：

- `Pull(..., WithPullSnapshotter(snapshotter))`
- `NewContainer(..., WithSnapshotter(snapshotter), WithNewSnapshot(...))`

仓库内 Linux 相关内置插件（`plugins/snapshots/*/plugin` 的 `ID`）：

| ID | 说明 |
|----|------|
| **`overlayfs`** | 默认；基于 overlay |
| **`native`** | 目录拷贝式 |
| **`devmapper`** | device-mapper thin-pool |
| **`btrfs`** | btrfs |
| **`erofs`** | EROFS |
| **`blockfile`** | blockfile |

另有平台相关：`windows`、`lcow` 等（非 Linux 主路径）。

选用前提：对应插件已在 daemon 中启用，且底层环境就绪（如 `devmapper` 需 thin-pool）。未启用或不存在时 Pull/NewContainer 会失败。

### 2.9 常用参数速查

| 参数 | 含义 | 默认 |
|------|------|------|
| `-c` / `--concurrent` | worker 并发数 | 1 |
| `-d` / `--duration` | 压测时长 | 1m |
| `-a` / `--address` | containerd/CRI socket | 系统默认 socket |
| `-i` / `--image` | 测试镜像 | `docker.io/library/alpine:latest` |
| `--runtime` | 见 §2.7 | `io.containerd.runc.v2` |
| `--snapshotter` | 见 §2.8 | `overlayfs` |
| `--cri` | 走 CRI | false |
| `--exec` | 额外 exec worker | false |
| `-j` / `--json` | JSON 输出结果 | false |
| `-m` / `--metrics` | metrics HTTP 监听地址 | 空 |

示例：

```bash
containerd-stress -c 5 -d 120m
containerd-stress --cri --runtime runc -c 4 -d 30m
containerd-stress --snapshotter native -c 2 -d 10m
containerd-stress density --count 100
```

---

## 3. Go 微基准（`make benchmark`）

### 3.1 用途与跑法

组件级 / 集成级 `testing.B` 基准，产出 ns/op、MB/s 等，用于热点优化与回归对比，**不是**长时间 daemon 加压。

```bash
make benchmark
# 等价于：go test … -bench . -run Benchmark -test.root
```

### 3.2 客户端集成：`integration/client/benchmark_test.go`

**`BenchmarkContainerCreate`**

1. 连上已运行的 containerd，`GetImage(testImage)`，预生成 OCI `spec`（含 `withTrue()`）
2. `b.ResetTimer()` 后循环 `b.N` 次：`NewContainer(id, WithNewSnapshot(id, image), WithSpec(spec))`
3. 结束后统一 `Delete(..., WithSnapshotCleanup)`

计时段覆盖：**元数据创建 + 新 snapshot**，**不含** `NewTask`/`Start`。用于衡量「空容器对象+根快照」创建成本。

**`BenchmarkContainerStart`**

1. 同样准备 image/spec
2. **计时外**先循环创建 `b.N` 个 container（含 snapshot）
3. `ResetTimer()` 后对每个容器：`NewTask` → `Start`

计时段覆盖：**task 创建与启动**。与 Create 基准刻意拆开，避免创建成本混进启动数字。

### 3.3 Snapshotter 套件：`core/snapshots/benchsuite`

**入口：** `BenchmarkNative` / `BenchmarkOverlay` / `BenchmarkDeviceMapper`  
分别 `NewSnapshotter` 后调用同一套 `benchmarkSnapshotter`；未传 root/设备 flag 则 `Skip`。

**机制（`benchmarkSnapshotter`）：**

1. 构造 **16 层** `fstest.Applier`：按层索引交替「全新建文件 / 局部改中段 4 字节 / 删除」——刻意制造 overlay 全文件 copy-up 与 block-based（devmapper）局部写的差异
2. 每层文件约 **1MiB**；`b.SetBytes` 按总写入量报告吞吐
3. 每轮 `b.N`：对 16 层依次  
   - `Prepare(current, parent)` → 累加 `prepareDuration`  
   - `mount.WithTempMount` + Apply 写数据 → `writeDuration`  
   - `Commit(parent', current)` → `commitDuration`
4. 除整体 `BenchmarkResult` 外，额外打印 prepare/write/commit 分段耗时

用途：对比不同 snapshotter 在多层增删改下的 Prepare/IO/Commit 成本。

### 3.4 MetaStore：`core/snapshots/storage`

`bolt_test.go` 的 `BenchmarkSuite` 调用 `Benchmarks(...)`，在可写事务里跑子基准：

| 子项 | 机制 |
|------|------|
| `StatActive` / `StatCommitted` | 预先 Create/Commit 出 active 或 committed，循环 `GetInfo` |
| `CreateActive` | 循环 `CreateSnapshot(KindActive)`，计时外 `Remove` |
| `Remove` | 计时外 Create，计时内 Remove |
| `Commit` | active → `CommitActive` |
| `GetActive` | 查询 active 快照 |
| `WriteTransaction` / `ReadTransaction` | 反复开事务 Commit / Rollback |

测的是 **snapshot 元数据（BoltDB）** 路径，不经过真实文件系统层实现。

### 3.5 Content ingest：`plugins/content/local`

**`BenchmarkIngests`：**

1. 对 blob 大小 `1KiB / 4KiB / 512KiB / 1MiB` 分子基准
2. 计时外 `generateBlobs`（随机内容，SHA256+SHA512 digest）
3. `SetBytes` 后循环 `checkWrite` 写入 content store

注释写明存在约数毫秒级插入开销（syscall/文件协调），用于衡量 **content store 写入吞吐**。

### 3.6 解压：`pkg/archive/compression`

**`BenchmarkDecompression`：**

1. 下载样本数据，扩展到 32/64/128/256 MiB
2. 预先压成 gzip / zstd
3. 子基准：`zstd`、`gzipPureGo`，若系统有 `igzip`/`unpigz` 再测外部分解压器

对比不同解压实现在镜像层解压场景下的吞吐。

### 3.7 元数据 GC：`core/metadata`

**`BenchmarkGarbageCollect`：** 子规模 `10/100/1000/10000-Sets`。

每「套」预置：1 blob + 1 image + 7 层 snapshot 链 + 1 container，全部写入 Bolt 元数据后 `ResetTimer`，循环调用 `mdb.GarbageCollect(ctx)`。

测 **GC 扫描/回收** 随对象规模的耗时（当前实现未在循环内掺删除对象，主要压全量扫描路径）。

### 3.8 其它微基准

| 位置 | 机制要点 |
|------|----------|
| `pkg/gc` `BenchmarkTricolor` | 构造引用图，循环跑三色标记 `Tricolor`，测 GC 图算法本身 |
| `core/unpack` `BenchmarkUnpackWithChainID(s)` | 模拟 unpack 时 chainID：旧路径每层反复 `identity.ChainID`；新路径一次 `ChainIDs`；层数 5/10/25/50 |
| `core/mount` `BenchmarkBatchRunGetUsernsFD_Concurrent{1,10}` | 并发调用 `getUsernsFD`（固定 UID/GID map），测 idmapped mount 获取 userns FD |
| `plugins/snapshots/overlay/overlayutils` `BenchmarkOverlaySupportedOn*` | 在临时 mkfs（ext4 / XFS ftype0/1 / FAT）上循环探测 overlay 是否支持 |

### 3.9 示例

```bash
go test -bench=. -benchmem ./integration/client/
go test -bench=. ./core/snapshots/benchsuite/ -overlay.rootPath=/tmp/ovl
go test -bench=BenchmarkGarbageCollect ./core/metadata/
```

---

## 4. AWS Snapshotter 基准环境（contrib）

`contrib/aws/snapshotter_bench_readme.md` + CloudFormation 模板：起带 EBS/thin-pool 的实例，再跑 §3.3 的 benchsuite。属于环境辅助，不是独立压测二进制。

---

## 5. 文档推荐的外部工具：bucketbench

`BUILDING.md` 推荐，不在 containerd 仓库内：

- YAML 配置 lifecycle（run/stop/remove/…）与 threads×iterations
- 支持 Docker / containerd / runc / crun / youki / CRI 等
- 输出逐步耗时统计；官方称其比 `containerd-stress` 更偏性能明细

与 `containerd-stress`：前者可配置命令序列、跨引擎；后者专注给运行中的 containerd 诱导负载并报 containers/sec。

---

## 6. 选型小结

| 目标 | 选用 |
|------|------|
| daemon 长时间加压 / 粗吞吐 | `containerd-stress` |
| 已运行 task 上的 exec 加压 | `containerd-stress --exec` |
| CRI Pod 加压 | `containerd-stress --cri`（`--runtime`=handler 名） |
| 同时存活内存密度 | `containerd-stress density` |
| 创建 vs 启动拆分微基准 | `integration/client` 的 Create/Start |
| snapshotter / content / GC 热点 | 对应包内 `Benchmark*` |
| 跨引擎生命周期明细 | bucketbench（外部） |
