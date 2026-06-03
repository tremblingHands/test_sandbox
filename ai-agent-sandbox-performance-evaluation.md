# AI Agent 场景下沙箱性能评估方案

## 1. 文档概述

### 1.1 背景

在 AI Agent 场景中，沙箱（Sandbox）是保障系统安全和隔离性的核心基础设施。Agent 在执行代码、访问文件系统、调用外部工具时，都依赖沙箱提供安全的执行环境。沙箱的性能直接影响 Agent 的响应速度、并发能力和资源利用效率。

### 1.2 评估目标

- 量化沙箱在不同 Agent 工作负载下的性能表现
- 识别性能瓶颈，为沙箱选型和优化提供数据支撑
- 建立可复现、可对比的标准化评估基准

---

## 2. 评估维度

### 2.1 启动延迟（Startup Latency）

衡量沙箱从创建到 ready 状态的时间。

| 指标 | 说明 | 典型采集方式 |
|------|------|-------------|
| 冷启动时间（P50/P95/P99） | 首次创建的完整耗时 | 计时沙箱创建 API 调用 |
| 热启动时间（P50/P95/P99） | 复用已有环境时的耗时 | 计时沙箱复用/快照恢复 |
| 预热池命中率 | 预创建沙箱的复用比例 | 统计命中次数 / 总请求数 |

### 2.2 执行性能（Execution Performance）

衡量沙箱内代码执行相对于裸机/宿主环境的性能损耗。

| 指标 | 说明 | 典型采集方式 |
|------|------|-------------|
| CPU 开销比 | 沙箱内 CPU 密集型任务 vs 宿主环境 | sysbench / 斐波那契等基准 |
| 内存访问开销 | 内存读写延迟差异 | lmbench / 自定义内存基准 |
| I/O 吞吐量 | 文件读写吞吐量对比 | fio / dd 基准测试 |
| 系统调用开销 | 单次 syscall 的额外延迟 | strace 统计 / getpid 循环 |

### 2.3 网络性能（Network Performance）

衡量沙箱网络栈的性能影响。

| 指标 | 说明 | 典型采集方式 |
|------|------|-------------|
| 网络吞吐量 | TCP/UDP 带宽 | iperf3 |
| 网络延迟（RTT） | 额外引入的延迟 | ping / hping3 |
| DNS 解析时间 | 域名解析的额外延迟 | dig / 自定义 DNS 基准 |
| 并发连接数上限 | 最大可建立的连接数 | 压测工具逐步增加连接 |

### 2.4 文件系统性能（Filesystem Performance）

衡量沙箱文件系统的性能特征。

| 指标 | 说明 | 典型采集方式 |
|------|------|-------------|
| 随机读写 IOPS | 小文件随机读写能力 | fio --rw=randread/randwrite |
| 顺序读写带宽 | 大文件顺序读写速度 | fio --rw=read/write |
| 文件创建/删除速率 | 元数据操作能力 | mdtest / 自定义脚本 |
| 写时复制（CoW）开销 | 分层文件系统的额外开销 | 对比写入前后磁盘使用 |

### 2.5 资源限制与隔离（Resource Limits & Isolation）

衡量沙箱对资源限制的精度和隔离的有效性。

| 指标 | 说明 | 典型采集方式 |
|------|------|-------------|
| CPU 限流精度 | 实际 CPU 使用 vs 配置上限 | cgroup 统计 / /proc/stat |
| 内存限制精度 | OOM 触发时机是否准确 | 渐进式内存分配测试 |
| 磁盘配额精度 | 写入上限触发是否准确 | 渐进式写入测试 |
| 隔离逃逸风险 | 是否存在已知的逃逸路径 | 安全审计 + 渗透测试 |
| 进程隔离 | 沙箱内进程是否可见宿主进程 | /proc 遍历检查 |

### 2.6 并发与多租户（Concurrency & Multi-tenancy）

衡量沙箱在大量并发实例下的表现。

| 指标 | 说明 | 典型采集方式 |
|------|------|-------------|
| 最大并发沙箱数 | 单机可同时运行的沙箱上限 | 逐步创建直到资源耗尽 |
| 并发下的性能退化 | N 个并发沙箱时的性能衰减曲线 | 固定负载 + 递增并发数 |
| 资源争抢（noisy neighbor） | 单个高负载沙箱对邻居的影响 | 隔离噪声源 + 观测邻居 |
| 创建/销毁吞吐量 | 每秒可创建和销毁的沙箱数 | 批量创建 + 批量销毁计时 |

### 2.7 生命周期管理（Lifecycle Management）

衡量沙箱快照、迁移、持久化的性能。

| 指标 | 说明 | 典型采集方式 |
|------|------|-------------|
| 快照创建时间 | 制作沙箱状态快照的耗时 | 计时 checkpoint/snapshot 操作 |
| 快照恢复时间 | 从快照恢复沙箱的耗时 | 计时 restore 操作 |
| 快照大小 | 快照文件的存储开销 | 检查快照文件大小 |
| 沙箱暂停/恢复延迟 | 冻结和恢复沙箱的时间 | 计时 pause/resume 操作 |

---

## 3. 评估场景设计

### 3.1 场景一：代码解释与执行

**典型 Agent 行为**：Agent 生成代码片段并在沙箱中执行以验证正确性。

```yaml
场景配置:
  沙箱数量: 1-10 并发
  代码类型: Python / Bash / Node.js
  单次执行时长: 100ms - 5s
  文件操作: 少量临时文件创建
  网络访问: 通常不需要

关键评估指标:
  - 冷启动时间（用户首次等待）
  - 单次代码执行延迟
  - 连续执行 100 次的 P95 延迟
```

### 3.2 场景二：数据处理与文件操作

**典型 Agent 行为**：Agent 需要读写文件、处理数据（CSV、JSON、日志解析等）。

```yaml
场景配置:
  沙箱数量: 1-5 并发
  文件大小: 1KB - 100MB
  操作类型: 读取、写入、追加、删除、遍历目录
  文件数量: 单文件到 10000 个小文件

关键评估指标:
  - 文件 I/O 吞吐量
  - 大量小文件的处理速度
  - 磁盘配额准确性
```

### 3.3 场景三：网络密集型任务

**典型 Agent 行为**：Agent 需要调用外部 API、下载资源、爬取网页。

```yaml
场景配置:
  沙箱数量: 1-20 并发
  请求类型: HTTP/HTTPS GET/POST
  请求频率: 1-100 请求/秒
  数据量: 1KB - 10MB 响应

关键评估指标:
  - 网络延迟（RTT 增加量）
  - 并发连接上限
  - DNS 解析性能
```

### 3.4 场景四：长时间运行任务

**典型 Agent 行为**：Agent 执行模型训练、大规模数据处理等耗时任务。

```yaml
场景配置:
  沙箱数量: 1-5 并发
  运行时长: 10 分钟 - 数小时
  资源使用: 持续高 CPU / 高内存

关键评估指标:
  - 长时间运行的性能稳定性
  - 内存泄漏趋势
  - 资源限制的持续有效性
  - 快照/恢复的可靠性
```

### 3.5 场景五：高并发多租户

**典型 Agent 行为**：SaaS 平台同时服务大量用户，每个用户一个独立沙箱。

```yaml
场景配置:
  沙箱数量: 50 - 500 并发
  生命周期: 短（数秒）到长（数小时）混合
  资源配额: 每个沙箱资源受限

关键评估指标:
  - 最大并发沙箱数
  - 创建/销毁吞吐量
  - Noisy neighbor 影响
  - 资源开销（每沙箱内存/CPU 基础消耗）
```

---

## 4. 评估工具集

### 4.1 通用基准工具

| 工具 | 用途 | 安装方式 |
|------|------|---------|
| sysbench | CPU/内存/文件 I/O/数据库基准 | `apt install sysbench` |
| fio | 灵活的 I/O 基准测试 | `apt install fio` |
| iperf3 | 网络带宽测试 | `apt install iperf3` |
| stress-ng | 压力测试（CPU/内存/IO/网络） | `apt install stress-ng` |
| lmbench | 系统级微基准 | 源码编译 |
| hyperfine | 命令行基准测试 | `cargo install hyperfine` |

### 4.2 自定义测试脚本

```python
#!/usr/bin/env python3
"""
沙箱性能基准测试框架示例
"""

import time
import subprocess
import statistics
import json
from dataclasses import dataclass, asdict
from typing import List


@dataclass
class BenchmarkResult:
    name: str
    runs: int
    mean_ms: float
    median_ms: float
    p95_ms: float
    p99_ms: float
    stddev_ms: float
    min_ms: float
    max_ms: float


class SandboxBenchmark:
    """沙箱性能基准测试器"""

    def __init__(self, sandbox_create_fn, sandbox_exec_fn, sandbox_destroy_fn):
        self.create = sandbox_create_fn
        self.execute = sandbox_exec_fn
        self.destroy = sandbox_destroy_fn

    def measure_startup_latency(self, runs: int = 50) -> BenchmarkResult:
        """测量沙箱启动延迟"""
        latencies = []
        for _ in range(runs):
            start = time.perf_counter()
            sb = self.create()
            latencies.append((time.perf_counter() - start) * 1000)
            self.destroy(sb)
        return self._compute_stats("startup_latency", latencies)

    def measure_execution_latency(self, code: str, runs: int = 100) -> BenchmarkResult:
        """测量代码执行延迟"""
        latencies = []
        sb = self.create()
        for _ in range(runs):
            start = time.perf_counter()
            self.execute(sb, code)
            latencies.append((time.perf_counter() - start) * 1000)
        self.destroy(sb)
        return self._compute_stats("execution_latency", latencies)

    def measure_concurrent_throughput(
        self, code: str, concurrency: int, duration_sec: int = 30
    ) -> dict:
        """测量并发执行吞吐量"""
        # 实现并发测试逻辑
        pass

    def measure_filesystem_perf(self, test_type: str) -> dict:
        """测量文件系统性能（封装 fio）"""
        pass

    def _compute_stats(self, name: str, data: List[float]) -> BenchmarkResult:
        """计算统计指标"""
        sorted_data = sorted(data)
        n = len(sorted_data)
        return BenchmarkResult(
            name=name,
            runs=len(data),
            mean_ms=statistics.mean(data),
            median_ms=statistics.median(data),
            p95_ms=sorted_data[int(n * 0.95)],
            p99_ms=sorted_data[int(n * 0.99)],
            stddev_ms=statistics.stdev(data) if n > 1 else 0,
            min_ms=min(data),
            max_ms=max(data),
        )
```

---

## 5. 评估流程

### 5.1 评估前准备

```
1. 环境标准化
   ├── 确认宿主 OS 版本、内核版本
   ├── 确认沙箱运行时版本（Docker / gVisor / Firecracker / Kata 等）
   ├── 确认硬件配置（CPU 型号/核数、内存、磁盘类型）
   └── 关闭不必要的后台服务，减少干扰

2. 基准采集
   ├── 先在宿主环境运行所有基准测试，作为裸机对照组
   └── 记录宿主环境的各项指标

3. 预热
   ├── 运行 3-5 轮预热测试，排除冷启动缓存影响
   └── 确保文件系统缓存、镜像缓存处于稳定状态
```

### 5.2 执行测试

```
阶段一：微基准测试
├── 启动延迟测试（50-100 次）
├── 系统调用开销测试
├── CPU/内存/IO 微基准
└── 网络微基准

阶段二：场景化测试
├── 场景一：代码解释与执行
├── 场景二：数据处理与文件操作
├── 场景三：网络密集型任务
├── 场景四：长时间运行任务
└── 场景五：高并发多租户

阶段三：压力与稳定性测试
├── 极限并发测试
├── 长时间稳定性测试（24h+）
├── 资源耗尽行为测试
└── 故障恢复测试
```

### 5.3 数据收集与分析

```
原始数据
├── 延迟分布（直方图）
├── 吞吐量时序图
├── 资源使用时序图（CPU/内存/磁盘/网络）
├── 错误率与错误类型分布
└── 与宿主环境对比的损耗百分比

分析产出
├── 性能瓶颈定位
├── 推荐配置参数
├── 与竞争方案对比
└── 优化建议清单
```

---

## 6. 报告模板

### 6.1 执行摘要

```markdown
## 执行摘要

- **评估对象**：[沙箱方案名称及版本]
- **评估日期**：YYYY-MM-DD
- **宿主环境**：[OS / 内核 / CPU / 内存 / 磁盘]
- **核心结论**：
  1. 冷启动延迟：P50=Xms, P95=Xms, P99=Xms
  2. CPU 性能损耗：X%（vs 裸机）
  3. 内存访问额外延迟：X%
  4. 文件 I/O 吞吐损耗：X%
  5. 网络吞吐损耗：X%
  6. 最大稳定并发数：X
  7. 综合推荐场景：[适合/不适合]的场景
```

### 6.2 详细指标

```markdown
## 详细测试结果

### 启动延迟

| 百分位 | 冷启动 (ms) | 热启动 (ms) | 裸机参考 (ms) |
|--------|------------|------------|--------------|
| P50    |            |            | -            |
| P95    |            |            | -            |
| P99    |            |            | -            |

### 执行性能（vs 裸机）

| 测试项       | 沙箱性能 | 裸机性能 | 损耗比 |
|-------------|---------|---------|-------|
| CPU (sysbench) |       |         | X%    |
| 内存读写       |       |         | X%    |
| 随机读 IOPS    |       |         | X%    |
| 随机写 IOPS    |       |         | X%    |
| 顺序读带宽     |       |         | X%    |
| 顺序写带宽     |       |         | X%    |

### 并发测试

| 并发数 | 吞吐量 (ops/s) | P95 延迟 (ms) | 错误率 | 资源使用 (CPU/Mem) |
|--------|---------------|--------------|--------|-------------------|
| 10     |               |              |        |                   |
| 50     |               |              |        |                   |
| 100    |               |              |        |                   |
| 200    |               |              |        |                   |
| 500    |               |              |        |                   |
```

---

## 7. 沙箱方案对比矩阵

| 维度 | Docker | gVisor | Firecracker | Kata Containers | Cloud VM |
|------|--------|--------|-------------|-----------------|----------|
| 启动速度 | 快 (<1s) | 中 (~1s) | 快 (<150ms) | 中 (~2s) | 慢 (10-60s) |
| 隔离级别 | 低（共享内核） | 中（用户态内核） | 高（微虚拟机） | 高（轻量虚拟机） | 高（完整虚拟机） |
| CPU 损耗 | ~0-2% | ~5-15% | ~3-8% | ~5-10% | ~2-5% |
| 内存开销 | 低 | 中 | 低-中 | 中 | 高 |
| I/O 性能 | ~95-100% | ~80-90% | ~85-95% | ~80-90% | ~90-98% |
| 网络性能 | ~95-100% | ~70-85% | ~80-90% | ~75-85% | ~90-98% |
| 快照支持 | 有限 | 支持 | 原生支持 | 支持 | 支持 |
| 适合场景 | 低风险单租户 | 中等安全需求 | 高安全多租户 | 高安全混合负载 | 强隔离需求 |

> 注：以上数据为通用参考值，实际性能取决于具体配置、硬件和负载模式，应以实测为准。

---

## 8. 优化建议

### 8.1 启动优化

- **预热池（Warm Pool）**：维护预创建的沙箱池，消除冷启动延迟
- **镜像优化**：精简沙箱镜像，减少拉取和初始化的时间
- **快照启动**：使用内存快照代替完整启动流程
- **层级缓存**：利用 Copy-on-Write 减少重复的镜像层拉取

### 8.2 运行时优化

- **资源超配**：合理设置 CPU/内存超配比例，提升资源利用率
- **I/O 调度**：选择合适的 I/O 调度器，优化沙箱场景的小文件性能
- **网络优化**：使用 macvlan/ipvlan 代替 bridge 网络，减少 NAT 开销
- **内核参数**：调整 vm.max_map_count, fs.inotify.max_user_instances 等参数

### 8.3 架构建议

- **分级隔离**：根据任务敏感度选择不同隔离级别的沙箱方案
- **弹性伸缩**：基于负载指标自动扩缩沙箱池
- **就近调度**：将沙箱调度到数据所在节点，减少网络延迟
- **熔断与降级**：沙箱资源不足时优雅降级，而非直接拒绝

---

## 9. 附录

### 9.1 常用测试命令速查

```bash
# CPU 基准测试
sysbench cpu --cpu-max-prime=20000 --threads=4 run

# 内存基准测试
sysbench memory --memory-block-size=1M --memory-total-size=10G run

# 文件 I/O 基准测试
sysbench fileio --file-total-size=5G --file-test-mode=rndrw prepare
sysbench fileio --file-total-size=5G --file-test-mode=rndrw run
sysbench fileio cleanup

# 灵活 I/O 测试
fio --name=randwrite --ioengine=libaio --iodepth=16 --rw=randwrite \
    --bs=4k --size=1G --numjobs=4 --runtime=60 --time_based \
    --directory=/mnt/test

# 网络吞吐量测试
iperf3 -s                          # 服务端
iperf3 -c <server_ip> -t 30 -P 4  # 客户端（4 并发，30 秒）

# 压力测试
stress-ng --cpu 4 --io 2 --vm 2 --vm-bytes 512M --timeout 60s

# 系统调用开销
strace -c -f <command>
```

### 9.2 关键内核参数

```bash
# 查看当前值
sysctl vm.max_map_count
sysctl fs.inotify.max_user_instances
sysctl fs.inotify.max_user_watches
sysctl net.core.somaxconn

# 推荐沙箱场景参数
vm.max_map_count = 262144
fs.inotify.max_user_instances = 8192
fs.inotify.max_user_watches = 1048576
net.core.somaxconn = 65535
```

### 9.3 参考资料

- [gVisor 性能文档](https://gvisor.dev/docs/architecture_guide/performance/)
- [Firecracker 设计文档](https://github.com/firecracker-microvm/firecracker/blob/main/docs/design.md)
- [Kata Containers 性能评估指南](https://github.com/kata-containers/kata-containers/tree/main/docs)
- [Docker 运行时性能对比](https://github.com/docker-library/docs)

---

> **文档版本**：v1.0
> **最后更新**：2026-06-03
> **维护者**：[团队/个人名称]
