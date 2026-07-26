# scripts/

按职责分类。按「测什么 / 干什么」分目录，不按语言分。

| 目录 | 用途 |
|------|------|
| [setup/](setup/) | 环境安装、编译 runtime、清理 kata |
| [bench/](bench/) | 沙箱冷启动 / 吞吐 / 规模压测 |
| [profile/](profile/) | 通用剖析：perf / pprof / 资源 / TRACE 解析 |
| [net/](net/) | 网络与 CNI 微基准（ipvlan、host-local IPAM） |

`bench` 可调用 `profile`；`net` 微基准也可接 `profile/containerd_perf.sh`。

---

## setup/ — 环境

| 脚本 | 说明 |
|------|------|
| `setup.sh` | 安装 containerd / crictl / pause / CNI 等 |
| `build_install_runtime.sh` | 从本地源码编译安装 containerd/shim/runc/CNI |
| `remove_kata.sh` | 清理 kata 二进制与配置 |

```bash
./scripts/setup/setup.sh
./scripts/setup/setup.sh --cni-type bridge --ip-masq false
./scripts/setup/build_install_runtime.sh --mode release
```

## bench/ — 沙箱压测

| 脚本 | 说明 |
|------|------|
| `cold_start_bench.py` | 单发冷启动时延 |
| `single_cold_start.py` | 单 worker 串行冷启动 |
| `concurrent_cold_start.py` | 多线程并发冷启动 |
| `multi_single_cold_start.sh` | 多进程绑核冷启动（可挂 perf/pprof/resources） |
| `throughput_sweep.sh` | 自动划核扫吞吐参数 |
| `scale_bench.py` | 并发扩展性评估 |
| `max_concurrency.py` | 最大同时存活沙箱数 |
| `bbolt_metadata_bench.sh` | metadata 风格 bbolt 场景微基准（sync/no_sync × update/merged/batch） |

```bash
python3 scripts/bench/cold_start_bench.py --runs 50
./scripts/bench/multi_single_cold_start.sh 128-255 128 1 --profile --perf
./scripts/bench/throughput_sweep.sh --help
./scripts/bench/bbolt_metadata_bench.sh --goroutines 128 --rounds 200 --mode sync --tx update
./scripts/bench/bbolt_metadata_bench.sh --cpus 128 --goroutines 128 --mode no_sync --tx merged
```

## profile/ — 剖析与资源

| 脚本 | 说明 |
|------|------|
| `containerd_perf.sh` | on/off-CPU 火焰图（含 `capture-live`） |
| `containerd_pprof.sh` | containerd pprof |
| `system_resources.sh` | 系统资源 metadata/capture/summarize |
| `resource_sampler.py` | 资源时序采样 |
| `resource_analyzer.py` | 资源与 bench 结果关联分析 |
| `trace_analyzer.py` | containerd `[TRACE]` 日志解析 |

```bash
sudo ./scripts/profile/containerd_perf.sh capture --output-dir /tmp/perf --duration 30 --cpus 0
python3 scripts/profile/trace_analyzer.py trace.log --summary-tree
```

## net/ — 网络微基准

| 脚本 | 说明 |
|------|------|
| `hostlocal_prefill.sh` | host-local IPAM 目录预填 |
| `ipvlan/ipvlan_l3_bench.py` | ipvlan-l3 CNI 热路径 bench |
| `ipvlan/ipvlan_host_netlink_add_bench.sh` | 宿主机 `ip link add` 耗时（可 `--perf` / `--ktrace`） |
| `ipvlan/ipvlan_host_netlink_bench.sh` | 宿主机 add+addr+up 耗时 |
| `ipvlan/ipvlan_kfunc_trace.sh` | ftrace function_graph 内核函数时延 |

```bash
sudo ./scripts/net/ipvlan/ipvlan_host_netlink_add_bench.sh 200 eth0 --cpus 128 --ktrace
python3 scripts/net/ipvlan/ipvlan_l3_bench.py -c 32 --duration 30 --no-netns --mode netlink
```
