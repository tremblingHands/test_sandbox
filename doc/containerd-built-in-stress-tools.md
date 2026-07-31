# containerd 代码中的现成压测工具

## 1. 概述

本文梳理 [containerd](https://github.com/containerd/containerd) 源码树（本机参考路径：`/home/nathan/containerd`）内**现成**的性能/压测相关能力，以及官方文档明确推荐的外部工具。

结论先行：

| 类别 | 工具 | 是否仓库内二进制 | 定位 |
|------|------|------------------|------|
| 端到端加压 | `containerd-stress` | 是（`cmd/containerd-stress`） | 对运行中 daemon 做并发生命周期加压 |
| 组件微基准 | `make benchmark` / `go test -bench` | 否（测试代码） | 测 Create/Start、snapshot、GC 等热点 |
| Snapshotter 环境 | `contrib/aws/snapshotter_bench_*` | 辅助脚本/模板 | 在 AWS 上跑 snapshotter benchsuite |
| 外部（文档推荐） | [bucketbench](https://github.com/estesp/bucketbench) | 否 | 跨引擎生命周期对比，偏逐步耗时统计 |

**没有**类似本仓库 `config_matrix_sweep.sh` 的 CNI × runtime × hypervisor × 绑核冷启动吞吐矩阵。

官方说明见 containerd 的 `BUILDING.md`（Additional tools 一节）。

---

## 2. `containerd-stress`（主推压测工具）

### 2.1 用途

对**已经运行**的 containerd daemon，在指定时长与并发度下反复创建/启动/销毁容器（或 CRI Pod），用于：

- 稳定性加压（能否长时间扛住）
- 粗粒度吞吐（containers/sec、seconds/container）
- 错误率观察

源码：`cmd/containerd-stress/`  
构建：`make binaries` / `make install`（`Makefile` 中 `COMMANDS` 含 `containerd-stress`）

### 2.2 测试机制

默认路径（client API，`ctrWorker`）：

1. `NewContainer`（snapshot + OCI spec，进程多为 `true`）
2. `NewTask` → `Wait` → `Start`
3. 等待进程退出
4. 删除 task / container（含 snapshot cleanup）
5. 多 worker 循环，直到 `--duration` 结束

仅成功样本计入耗时，避免失败路径把吞吐“虚高”。结束时汇总：

- `total` / `failures`
- `containersPerSecond`
- `secondsPerContainer`

可选 Prometheus 风格 metrics（`--metrics`）：run/exec 耗时、错误计数等。

### 2.3 模式与常用参数

| 模式 / 参数 | 含义 |
|-------------|------|
| 默认 | client API 生命周期循环 |
| `--cri` | 走 CRI 创建 Pod 加压（需匹配的 runtime handler） |
| `--exec` | 非 CRI 路径上额外做 exec |
| `density` 子命令 | 同时拉起 `--count` 个容器，测密度 |
| `-c` / `--concurrent` | 并发 worker 数（默认 1） |
| `-d` / `--duration` | 压测时长（默认 1m） |
| `-a` / `--address` | containerd socket（默认系统默认路径） |
| `-i` / `--image` | 测试镜像（默认 `alpine:latest`） |
| `--runtime` | runtime（默认 `io.containerd.runc.v2`） |
| `--snapshotter` | 默认 `overlayfs` |
| `-j` / `--json` | JSON 结果输出 |

### 2.4 示例

```bash
# 构建
cd /home/nathan/containerd
make binaries
# 或：go build -o bin/containerd-stress ./cmd/containerd-stress

# 确保 containerd 已启动，再加压：5 并发，跑 2 小时
./bin/containerd-stress -c 5 -d 120m

# CRI 路径
./bin/containerd-stress --cri --runtime runc -c 4 -d 30m

# 密度：同时跑 100 个容器
./bin/containerd-stress density --count 100

# 帮助
./bin/containerd-stress --help
```

### 2.5 适用边界

适合：daemon 加压、粗吞吐、稳定性。  
不适合：逐步生命周期明细对比、跨 Docker/runc 公平对比、CNI/绑核矩阵冷启动。

---

## 3. Go 微基准（`make benchmark`）

### 3.1 用途

组件级 / 集成级 `testing.B` 基准，用于热点优化与回归对比（ns/op、MB/s），**不是**长时间压测工具。

入口：

```bash
make benchmark
# 等价于大致：
go test ${TESTFLAGS} -bench . -run Benchmark -test.root
```

### 3.2 主要基准一览

| 位置 | 代表 Benchmark | 测什么 |
|------|----------------|--------|
| `integration/client/benchmark_test.go` | `ContainerCreate` / `ContainerStart` | 客户端创建容器；预创建后 NewTask+Start |
| `core/snapshots/benchsuite/` | `Native` / `Overlay` / `DeviceMapper` | 多层 Prepare / 写层 / Commit（需 root 路径或 thin-pool 参数） |
| `core/snapshots/storage/` | `BenchmarkSuite`（BoltDB MetaStore） | Stat/Create/Commit/Remove、读写事务 |
| `plugins/content/local/` | `BenchmarkIngests` | content store 写入不同大小 blob |
| `pkg/archive/compression/` | `BenchmarkDecompression` | gzip/zstd（及 igzip/unpigz）解压 |
| `core/metadata/` | `BenchmarkGarbageCollect` | 元数据 GC 在不同对象规模下的耗时 |
| `pkg/gc/` | `BenchmarkTricolor` | GC 三色标记算法本身 |
| `core/unpack/` | `UnpackWithChainID(s)` | unpack 路径上 chainID 计算新旧对比 |
| `core/mount/` | `GetUsernsFD_Concurrent*` | idmapped mount 获取 userns FD |
| `plugins/snapshots/overlay/overlayutils/` | `OverlaySupportedOn*` | overlay 能力探测在不同文件系统上的开销 |

### 3.3 示例

```bash
# 仅客户端集成基准
go test -bench=. -benchmem ./integration/client/

# snapshotter suite（需按 README/flag 提供 root 或设备）
go test -bench=. ./core/snapshots/benchsuite/ \
  -overlay.rootPath=/tmp/overlay-bench
```

---

## 4. AWS Snapshotter 基准环境（contrib）

路径：`contrib/aws/snapshotter_bench_readme.md`、`snapshotter_bench_cf.yml`

用途：用 CloudFormation 起一台适合 snapshotter 对比的 EC2（EBS、thin-pool 等），再在其上跑 `core/snapshots/benchsuite`（native / overlay / devmapper）。

这是**环境与流程辅助**，不是独立压测二进制；依赖 AWS 资源，有费用。

---

## 5. 文档推荐的外部工具：bucketbench

containerd `BUILDING.md` 明确推荐，但**不在** containerd 仓库内：

- 仓库：<https://github.com/estesp/bucketbench>
- 驱动：Docker / containerd / runc / crun / youki / CRI 等
- 输入：YAML 定义 `commands`（run/stop/remove/pause/…）+ `threads` × `iterations`
- 输出：逐步耗时统计（min/max/avg/median/stddev）与吞吐

与 `containerd-stress` 的差异（官方表述）：

- bucketbench 更偏**性能明细**；stress 更偏**诱导负载**
- bucketbench 可跨多个引擎、可配置生命周期序列

示例：

```bash
sudo bucketbench run -b examples/ctrd.yaml
```

---

## 6. 与本仓库压测体系的关系

| 能力 | containerd 现成工具 | 本仓库（`scripts/bench/`） |
|------|-------------------|---------------------------|
| daemon 长时间加压 | `containerd-stress` | 可互补 |
| 跨引擎生命周期对比 | bucketbench（外部） | 部分重叠（本仓偏沙箱冷启动） |
| 组件微基准 | `make benchmark` | 无对等需求 |
| CNI × runtime × hypervisor × 绑核 | **无** | `config_matrix_sweep.sh` + `throughput_sweep.sh` + `cold_start_bench.py` |

选型建议：

1. **只压 containerd daemon / 看吞吐与稳定性** → `containerd-stress`
2. **对比 create/start/stop 逐步耗时（可含 runc）** → bucketbench
3. **优化某一库函数/子系统** → `go test -bench`
4. **沙箱冷启动矩阵（含 CNI、kata、绑核）** → 继续用本仓库矩阵脚本

---

## 7. 参考路径速查

| 项 | 路径 |
|----|------|
| stress 源码 | `/home/nathan/containerd/cmd/containerd-stress/` |
| 构建说明 | `/home/nathan/containerd/BUILDING.md`（Additional tools） |
| Makefile 目标 | `binaries`、`benchmark` |
| 客户端集成基准 | `integration/client/benchmark_test.go` |
| Snapshot benchsuite | `core/snapshots/benchsuite/` |
| AWS 辅助 | `contrib/aws/snapshotter_bench_*` |
| 本仓库矩阵入口 | `scripts/bench/config_matrix_sweep.sh` |
