# containerd CNI Bridge 网络行为分析

## 1. 文档概述

### 1.1 背景

用 `crictl` / CRI 创建 Pod 沙箱时，非 hostNetwork 路径会走 CNI。本环境业务网配置为 **bridge + host-local**，配置文件为 `/etc/cni/net.d/10-mynet.conf`。

本文说明：**containerd 如何加载该配置、在 RunPodSandbox 中何时调用 CNI、bridge/host-local 插件实际做了什么、结果如何回写到沙箱状态**。containerd **不实现** bridge 语义，只负责建 netns、按 CNI 规范 exec 插件、消费 Result。

### 1.2 相关路径

| 组件 | 路径 |
|------|------|
| containerd | `/home/nathan/containerd` |
| CNI plugins（bridge / host-local / loopback） | `/home/nathan/plugins` |
| CNI 配置目录 | `/etc/cni/net.d` |
| CNI 二进制目录 | `/opt/cni/bin` |
| containerd 主配置 | `/etc/containerd/config.toml` |
| Ready / 启动时延 | `doc/sandbox-ready-and-startup-latency.md` |
| 冷启动瓶颈（含 CNI/RTNL） | `doc/sandbox-cold-start-bottleneck-analysis.md` |

---

## 2. 本机配置现状

### 2.1 `/etc/cni/net.d/10-mynet.conf`

```json
{
  "cniVersion": "0.3.1",
  "name": "mynet",
  "type": "bridge",
  "bridge": "cni0",
  "isGateway": true,
  "ipMasq": false,
  "ipam": {
    "type": "host-local",
    "subnet": "10.0.0.0/12",
    "routes": [
      { "dst": "0.0.0.0/0" }
    ]
  }
}
```

字段含义（由 **bridge 插件**解释，containerd 原样 stdin 传入）：

| 字段 | 含义 |
|------|------|
| `type: bridge` | 执行 `/opt/cni/bin/bridge` |
| `bridge: cni0` | 宿主机 Linux bridge 名 |
| `isGateway: true` | 在 cni0 上配置网关地址并开启 IP forwarding |
| `ipMasq: false` | **不**配置 MASQUERADE（无 CNI 自带 NAT） |
| `ipam.type: host-local` | 本机分配 IP，子网 `10.0.0.0/12` |
| `routes: 0.0.0.0/0` | 容器内默认路由（经 bridge 网关） |

同目录还有 `nerdctl-bridge.conflist`（nerdctl 用）。

### 2.2 containerd CRI CNI 段

```toml
[plugins.'io.containerd.cri.v1.runtime'.cni]
  bin_dirs = ['/opt/cni/bin']
  conf_dir = '/etc/cni/net.d'
  max_conf_num = 1
  setup_serially = false
```

| 配置项 | 本机值 | 效果 |
|--------|--------|------|
| `conf_dir` | `/etc/cni/net.d` | 扫描该目录下 `.conf` / `.conflist` / `.json` |
| `max_conf_num` | `1` | **只加载字典序第一个**配置文件 |
| 文件排序 | `10-mynet.conf` < `nerdctl-bridge.conflist` | **实际只用 `10-mynet.conf`** |
| `bin_dirs` | `/opt/cni/bin` | 查找 `bridge` / `host-local` / `loopback` |
| `setup_serially` | `false` | 多个 network **并行** Attach |

`.conf` 单文件不是 conflist：go-cni 会通过 `ConfListFromConf` **升成**只含一个插件的 NetworkConfigList。

---

## 3. containerd 如何初始化 CNI

### 3.1 启动时创建 go-cni 实例

代码：`internal/cri/server/service_linux.go` → `initPlatform()`。

```go
// 默认至少挂 2 个网络：loopback + 业务网
networkAttachCount := 2
i, err := cni.New(
    cni.WithMinNetworkCount(networkAttachCount),
    cni.WithPluginConfDir(dir),          // /etc/cni/net.d
    cni.WithPluginMaxConfNum(max),       // 1
    cni.WithPluginDir(binDirs),          // /opt/cni/bin
)
```

默认 `UseInternalLoopback=false` 时的 Load 选项：

```go
// cniLoadOptions()
return []cni.Opt{cni.WithLoNetwork, cni.WithDefaultConf}
```

因此内存中的网络列表为：

```
networks[0] = cni-loopback   ifName = "lo"     ← 代码内嵌，不来自磁盘文件
networks[1] = mynet (bridge) ifName = "eth0"   ← 来自 10-mynet.conf
```

`WithLoNetwork` 注入的内嵌 JSON：

```json
{
  "cniVersion": "0.3.1",
  "name": "cni-loopback",
  "plugins": [{ "type": "loopback" }]
}
```

`WithDefaultConf` → `loadFromConfDir`：列出 conf 文件 → `sort.Strings` → 最多取 `max_conf_num` 个 → 单 `.conf` 转 conflist，接口名 `eth` + index → `eth0`。

### 3.2 配置热更新

`cni_conf_syncer` watch `conf_dir`，文件变化时重新 `Load(cniLoadOptions()...)`，无需重启 containerd 即可换网（视插件与残留资源而定）。

### 3.3 职责边界

| 角色 | 做什么 |
|------|--------|
| containerd CRI | 建/删 netns；调 go-cni Setup/Remove；缓存 Pod IP；OCI 挂 NetNSPath |
| go-cni | 组装 CNI 环境变量与 stdin；exec 插件；合并 Result |
| bridge / host-local / loopback | 真正改内核网络状态 |

---

## 4. RunPodSandbox 中的网络路径

### 4.1 总览

```
RunPodSandbox
  │
  ├─ hostNetwork? ──是──► 跳过建网与 CNI
  │
  └─ 否
       ├─ ① netns.NewNetNS(/var/run/netns/...)   ← containerd 创建空 netns
       ├─ ② setupPodNetwork(id, NetNSPath)       ← 调 CNI
       ├─ ③ StartSandbox（pause + runc）         ← OCI network.namespace.path = NetNSPath
       └─ ④ State = SANDBOX_READY
```

相关代码：`internal/cri/server/sandbox_run.go`。

失败时 defer：`teardownPodNetwork` + 删除 netns（资源清理顺序有专门 defer 保证）。

### 4.2 setupPodNetwork

```go
netPlugin = c.getNetworkPlugin(runtimeHandler)  // 默认全局 CNI
opts = cniNamespaceOpts(id, config)
  // K8S_POD_NAME / NAMESPACE / UID、portmap、bandwidth、DNS、cgroupPath 等
result = netPlugin.Setup(ctx, id, NetNSPath, opts...)
  // 或 SetupSerially（本机 setup_serially=false → Setup）

// 要求默认接口 eth0 有 IP
sandbox.IP, sandbox.AdditionalIPs = selectPodIPs(result.Interfaces["eth0"].IPConfigs, ...)
sandbox.CNIResult = result
```

若 `eth0` 无 IP → 直接报错，RunPodSandbox 失败。

### 4.3 Stop / Remove

`teardownPodNetwork`（`sandbox_stop.go`）：

```go
netPlugin.Remove(ctx, id, path, opts...)  // CNI DEL
// 随后 sandbox.NetNS.Remove()
```

DEL 会触发 bridge / loopback DEL，以及 host-local 释放 IP。

---

## 5. go-cni Setup：一次沙箱 exec 什么

### 5.1 调用链

```
setupPodNetwork
  └─ go-cni Setup(id, netnsPath)
       └─ attachNetworks（并行，因 setup_serially=false）
            ├─ Network[lo].Attach
            │    └─ AddNetworkList → exec /opt/cni/bin/loopback  ADD
            └─ Network[mynet].Attach
                 └─ AddNetworkList → exec /opt/cni/bin/bridge   ADD
                      └─ bridge 再 exec /opt/cni/bin/host-local ADD（IPAM）
```

`Network.Attach`（`vendor/github.com/containerd/go-cni/namespace.go`）：

```go
r, err := n.cni.AddNetworkList(ctx, n.config, ns.config(n.ifName))
```

### 5.2 传给插件的环境（示意）

| 变量 | 示例 |
|------|------|
| `CNI_COMMAND` | `ADD` / `DEL` |
| `CNI_CONTAINERID` | sandbox ID |
| `CNI_NETNS` | `/var/run/netns/<...>` |
| `CNI_IFNAME` | `eth0` 或 `lo` |
| `CNI_PATH` | `/opt/cni/bin` |
| stdin | 网络 JSON（含 bridge 配置 + runtime args/capabilities） |

### 5.3 并行 vs 串行

- `setup_serially=false` → `attachNetworks`：每个 network 一个 goroutine 并行 Attach。
- `setup_serially=true` → `attachNetworksSerially`：按 networks 顺序串行。

本机 lo 与 bridge **可并行** exec；bridge **内部**（建 veth、IPAM、等端口 Up）仍是单插件内串行。高并发下大量 bridge ADD 仍会在内核 `rtnl_mutex` 上串行化（见冷启动瓶颈文档）。

---

## 6. bridge 插件对本配置的具体行为

代码：`/home/nathan/plugins/plugins/main/bridge/bridge.go` → `cmdAdd`。

### 6.1 ADD 主路径

```
1. setupBridge("cni0")
     └─ 不存在则创建 Linux bridge；存在则复用
2. 打开 Pod netns（CNI_NETNS）
3. setupVeth：
     - 宿主机端 veth → LinkSetMaster(cni0)
     - 容器端移入 netns，改名为 eth0
4. ipam.ExecAdd("host-local", stdin)
     └─ 从 10.0.0.0/12 分配地址；落盘占位（如 /var/lib/cni/networks/mynet/）
5. 在 netns 内 ConfigureIface(eth0)：设 IP、路由（含默认路由）
6. isGateway=true：
     - ensureAddr(cni0, gateway)   // 通常为子网 .1
     - enableIPForward()
7. ipMasq=false → 跳过 SetupIPMasqForNetworks（无 MASQUERADE）
8. 等待 bridge 端口 OperUp（可能重试/sleep；与 STP 状态切换相关）
9. 返回 Result：cni0 / host-veth / eth0 + IPs/Routes
```

### 6.2 与配置字段的对应

| 配置 | 代码行为 |
|------|----------|
| `bridge: cni0` | `ensureBridge("cni0")` |
| `isGateway: true` | bridge 上设网关 IP + forwarding |
| `ipMasq: false` | **不**写 iptables/nft MASQUERADE |
| `host-local` + `10.0.0.0/12` | 本机 IPAM |
| `routes: 0.0.0.0/0` | 容器默认路由经网关 |

### 6.3 拓扑示意

```
[Pod netns]                      [Host]
  lo (up)                          …
  eth0 10.x.y.z/12  ←──veth──►  vethXXXX
                                   │
                                cni0 (gateway, e.g. 10.0.0.1)
                                   │
                              宿主机转发（isGateway）
                              无 CNI 自带 NAT（ipMasq:false）
```

### 6.4 `ipMasq: false` 的影响

- Pod → 同节点其它网段 / 外网：依赖宿主机已有转发与 NAT，**本 CNI 配置不提供 MASQUERADE**。
- 若需要 CNI 自动 NAT，需改 `ipMasq: true`（会引入 xtables/nft 写规则，高并发下另有锁竞争；见冷启动分析）。

---

## 7. Result 如何回到 CRI

1. go-cni 合并各 network 的 Result。  
2. CRI 检查 **`eth0`**（默认前缀 `eth` + index 0）是否有 IP。  
3. `selectPodIPs` 按 `ip_preference` 选主 IP / 附加 IP。  
4. 写入 `sandbox.IP`、`sandbox.CNIResult`（后续 Status 可直接用，避免反复进 netns 查 IP）。  
5. pause / 业务容器 OCI spec：`linux.namespaces` 中 network 的 `path = NetNSPath`；**runc 只 setns，不再配网**。

`PodSandboxStatus` 对外暴露的 Pod IP 即来自此缓存（及必要时的 netns 查询逻辑）。

---

## 8. 端到端时序（本机 bridge 配置）

```
crictl runp / RunPodSandbox
  │
  ├─ 创建 netns @ /var/run/netns/...
  │
  ├─ go-cni Setup（并行）
  │    ├─ loopback ADD  →  lo up
  │    └─ bridge ADD
  │         ├─ 确保 / 复用 cni0
  │         ├─ 建 veth，容器端为 eth0
  │         ├─ host-local 分配 10.0.0.0/12 地址
  │         ├─ eth0 配 IP + 默认路由；cni0 作网关
  │         └─ 不开 ipMasq
  │
  ├─ 缓存 sandbox.IP = eth0 地址
  ├─ NewTask / Start pause（加入该 netns）
  └─ SANDBOX_READY
```

Stop：`CNI DEL`（bridge + loopback + 释放 host-local IP）→ 删 netns。

---

## 9. 与性能/瓶颈的关系（摘要）

| 现象 | 机制 |
|------|------|
| profile 中 `cni.setup_pod_network` 占比高 | 每沙箱一次（或并行两次）插件 exec + 大量 netlink |
| 高并发下 bridge 时延膨胀 | 多沙箱争用内核 **`rtnl_mutex`**（建 veth、挂 bridge、设地址等） |
| `ipMasq: true` 时额外开销 | xtables/nft 全局锁（本机当前为 **false**，无此项） |
| loopback 不可忽视 | 默认每个沙箱仍跑 loopback ADD，与 bridge 共用 RTNL |

更细的 RTNL / printk / 对照实验见 `sandbox-cold-start-bottleneck-analysis.md`。

---

## 10. 常见注意点

1. **containerd 不解析 `bridge`/`isGateway`/`ipMasq`**，只把 JSON 交给插件。  
2. **`max_conf_num=1`** 时，目录里多个 conf 只认字典序第一个；改网时注意文件名排序。  
3. **hostNetwork** 沙箱完全跳过 CNI。  
4. **业务容器**不重新跑 CNI；共享沙箱 netns。  
5. 出网失败时先查：`ipMasq`、宿主机转发、路由、firewall，再查 CNI Result / `cni0` / veth。  
6. 调试可看：containerd 日志中的 CNI result、`ip link`/`bridge link`、`/var/lib/cni/networks/mynet/`、插件 stderr。

---

## 11. 一句话总结

配置 `/etc/cni/net.d/10-mynet.conf` 且 `max_conf_num=1` 时，containerd 对每个非 hostNetwork 沙箱：先建 netns，再经 go-cni **并行**执行 loopback + bridge；bridge 负责 `cni0`、veth、`host-local` 分配 `10.0.0.0/12`、网关与转发，**不做 MASQUERADE**；containerd 只缓存 `eth0` IP，并把该 netns 交给后续 pause/容器使用。

---

## 修订记录

| 日期 | 说明 |
|------|------|
| 2026-07-17 | 初稿：基于本机 `10-mynet.conf` 与 containerd/go-cni/bridge 代码路径的 CNI 行为分析 |
