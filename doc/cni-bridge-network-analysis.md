# containerd CNI Bridge 网络行为分析

## 1. 文档概述

### 1.1 背景

用 `crictl` / CRI 创建 Pod 沙箱时，非 hostNetwork 路径会走 CNI。本环境业务网配置为 **bridge + host-local**，配置文件为 `/etc/cni/net.d/10-mynet.conf`。

本文说明：**containerd 如何加载该配置、在 RunPodSandbox 中何时调用 CNI、bridge/host-local 插件实际做了什么、`isGateway` / `ipMasq` / **host-local** / **loopback** 的完整代码路径、结果如何回写到沙箱状态**。containerd **不实现** bridge / IPAM / 网关 / MASQUERADE 语义（loopback 默认也走 CNI 插件；可选内部 `bringUpLoopback`），只负责建 netns、按 CNI 规范 exec 插件、消费 Result。

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

### 6.4 与 loopback / IPAM / 网关 / NAT 的衔接

| 字段 / 能力 | 本机 | 作用摘要 | 详节 |
|-------------|------|----------|------|
| CNI **loopback** | ✓（`use_internal_loopback=false`） | 把 Pod netns 内 `lo` 设为 UP | **§10** |
| `ipam.type: host-local` | ✓ | 本机分配 Pod IP、默认 Gateway、落盘占位 | **§9** |
| `isGateway` | **true** | 在 `cni0` 上配网关 IP + 开 IP forwarding | **§7** |
| `ipMasq` | **false** | 是否每沙箱写 MASQUERADE | **§8** |

分工：loopback 管 **本 netns 的 lo**；host-local **选出** eth0 地址；isGateway 把网关 **落到 cni0**；ipMasq 管出网 SNAT。

---

## 7. `isGateway` 行为深入分析

### 7.1 谁管、字段含义

| 组件 | 是否解析 |
|------|----------|
| containerd / go-cni | **否** |
| bridge 插件 | **是** |

```go
IsGW        bool `json:"isGateway"`
IsDefaultGW bool `json:"isDefaultGateway"`  // 为 true 时会强制 IsGW=true
ForceAddress bool `json:"forceAddress"`     // cni0 已有不同地址时是否强制替换
```

本机 conf：**`"isGateway": true`**，未写 `isDefaultGateway`（默认 false）。

`cmdAdd` 开头：

```go
if n.IsDefaultGW {
    n.IsGW = true
}
```

### 7.2 在 ADD 路径中的位置

```
bridge cmdAdd
  ├─ setupBridge(cni0)
  ├─ setupVeth → eth0
  ├─ ipam.ExecAdd(host-local)     ← 得到 Pod IP；Gateway 常由 IPAM 填 .1
  ├─ calcGateways(result, n)      ← ★ 若 IsGW：补全/收集网关
  ├─ netns 内 ConfigureIface      ← 给 eth0 设 IP；按 Routes 加路由（含默认路由）
  ├─ if n.IsGW:                   ← ★ 本节主体
  │     ensureAddr(cni0, gateway) ← 把网关 IP 配到 bridge
  │     enableIPForward()         ← 写 /proc/sys/.../ip_forward=1
  └─ if n.IPMasq: ...             ← 与网关无关，见 §8
```

`isGateway` **不参与** DEL 的专门 teardown：bridge 上的网关地址通常 **跨沙箱复用**，删一个 Pod 不会清掉 `cni0` 的 IP。

### 7.3 网关地址从哪来：`calcGateways` + host-local

#### 7.3.1 host-local（IPAM）

本机未在 conf 里写 `"gateway"`。`host-local` 的 `Range.Canonicalize()`：

```go
// gateway 为空时默认用子网网络地址的下一个 IP → 即 .1
if r.Gateway == nil {
    r.Gateway = ip.NextIP(r.Subnet.IP)
}
```

对 `10.0.0.0/12` → 网关 **`10.0.0.1`**。  
分配结果里 `IPConfig.Gateway = 10.0.0.1`，且 conf 的 `routes: [{dst: 0.0.0.0/0}]` 进入 `result.Routes`（GW 可在 ConfigureIface 时用 `ipc.Gateway` 补全）。

#### 7.3.2 bridge 的 `calcGateways`

```go
// IPAM 未给 Gateway 且 IsGW：用 Pod 地址所在子网算 .1
if ipc.Gateway == nil && n.IsGW {
    ipc.Gateway = calcGatewayIP(&ipc.Address)  // nid = IP.Mask(mask); return NextIP(nid)
}

// IsDefaultGW：若还没有默认路由，则追加 0.0.0.0/0 via Gateway
if n.IsDefaultGW && !gws.defaultRouteFound { ... }

// IsGW：把 Gateway/Mask 记入 gws.gws，供后面 ensureAddr(cni0)
if n.IsGW {
    gws.gws = append(gws.gws, net.IPNet{IP: ipc.Gateway, Mask: ipc.Address.Mask})
}
```

`calcGatewayIP`：`子网网络地址 + 1`，与 host-local 默认一致。

对本机：

| 项 | 值 |
|----|-----|
| Pod 例 | `10.a.b.c/12` |
| Gateway | `10.0.0.1`（host-local 已提供；即使为空也会被 IsGW 算出） |
| 默认路由 | conf 已有 `0.0.0.0/0`；**不依赖** `isDefaultGateway` |
| `gws.gws` | `{10.0.0.1, mask /12}` → 随后 `ensureAddr(cni0, ...)` |

若 **`isGateway: false`**：

- 仍可给 eth0 配 IP、装 conf 里的 routes（若 IPAM 提供了 Gateway）  
- **不会**把地址配到 `cni0`，**不会**由 bridge 强制 `ip_forward=1`  
- 容器默认路由若指向 `.1`，但 `cni0` 无该地址 → 出网/跨网不通（除非别处配了网关）

### 7.4 容器内：`ConfigureIface`（与 IsGW 间接相关）

在 `IsGW` 块 **之前**执行，使用 `calcGateways` 可能改过的 `result`：

1. `AddrAdd(eth0, podIP/mask)`  
2. `LinkSetUp(eth0)`  
3. 遍历 `result.Routes`：`RouteAdd`；若 route.GW 为空，用 `ipc.Gateway`（即 `.1`）

因此：**Pod 里的「下一跳是 10.0.0.1」** 来自 IPAM/routes + ConfigureIface；  
**宿主机上「10.0.0.1 落在 cni0」** 来自后面的 `IsGW` → `ensureAddr`。

### 7.5 `ensureAddr`：把网关配到 bridge

```go
func ensureAddr(br, family, ipn *net.IPNet, forceAddress bool) error {
    // 已有完全相同地址 → 直接返回（多沙箱复用，幂等）
    // IPv4 或重叠的 IPv6：已有不同地址
    //   forceAddress=true  → 删旧加新
    //   false              → 报错
    netlink.AddrAdd(br, addr)
    // 固定 bridge MAC，避免随 veth 加入而漂移
    netlink.LinkSetHardwareAddr(br, br.HardwareAddr)
}
```

含义：

- **第一个**需要网关的沙箱：给 `cni0` 加上 `10.0.0.1/12`  
- **后续**沙箱：地址已存在 → no-op（仍走这段逻辑，但很快返回）  
- 与 vlan 配置时：地址加在 vlan 子接口而非裸 bridge（本机未配 vlan）

这是 **RTNL / netlink** 路径（`AddrAdd`、`LinkSetHardwareAddr`），和 `ipMasq` 的 xtables **不是同一把锁**，但同属 bridge ADD 墙钟时间。

### 7.6 `enableIPForward`：打开转发

```go
func enableIPForward(family int) error {
    if family == FAMILY_V4 {
        return echo1("/proc/sys/net/ipv4/ip_forward")  // 已是 1 则跳过
    }
    return echo1("/proc/sys/net/ipv6/conf/all/forwarding")
}
```

- 节点级 sysctl，**不是** per-sandbox 状态  
- 多沙箱并发 ADD 时反复写同一文件（已为 1 则快速返回）  
- **只解决「内核是否转发」**；不解决「外网是否认 Pod IP」→ 那是 `ipMasq` / 节点级 MASQUERADE

### 7.7 `isGateway` vs `isDefaultGateway` vs conf `routes`

| 能力 | `isGateway` | `isDefaultGateway` | conf `routes: 0.0.0.0/0` |
|------|-------------|--------------------|-------------------------|
| 补全 `ipc.Gateway`（若空） | ✓ | （隐含 IsGW） | — |
| 把 Gateway 配到 cni0 | ✓ | ✓ | — |
| 开 ip_forward | ✓ | ✓ | — |
| 向 result **追加**默认路由 | — | ✓（若尚无） | 已在 IPAM routes 里则 ConfigureIface 会装 |

本机：**`isGateway: true` + routes 已含默认路由** → 不需要 `isDefaultGateway` 也能在 Pod 内装上 `default via 10.0.0.1`。

### 7.8 拓扑与数据包路径（本机）

```
Pod netns                          Host
  eth0 10.x.y.z/12
  default via 10.0.0.1
         │
         │ veth
         ▼
      cni0 10.0.0.1/12     ← isGateway: ensureAddr
         │
         │ ip_forward=1    ← isGateway: enableIPForward
         ▼
    其它网段 / 外网出口
         │
         └─ SNAT？ 本机 ipMasq:false → 靠节点级 MASQUERADE（§8）
```

### 7.9 若关闭 `isGateway` 会怎样

| 现象 | 原因 |
|------|------|
| `cni0` 可能无 `10.0.0.1` | 不再 `ensureAddr` |
| Pod 仍可能有 default via `.1` | routes / IPAM Gateway 仍在 |
| 出 Pod 网段失败（ARP 无应答等） | 网关地址不在 bridge 上 |
| 跨接口转发可能失败 | 未由插件置 `ip_forward`（若主机原先为 0） |

### 7.10 与性能的关系

- **不是**每沙箱新建一套 iptables；网关 IP 与 forwarding 多为 **幂等复用**。  
- 仍有每沙箱一次 `calcGateways` +（多数情况下快速）`ensureAddr`/`enableIPForward` 调用；相对 veth/RTNL/masq，通常不是主瓶颈。  
- 真正贵的仍是：建 veth、挂 bridge、IPAM、以及（若开启）ipMasq。

---

## 8. `ipMasq` 行为深入分析

### 8.1 谁管 `ipMasq`

| 组件 | 是否解析 `ipMasq` |
|------|-------------------|
| containerd CRI / go-cni | **否**，只把 conf stdin 交给 `/opt/cni/bin/bridge` |
| bridge 插件 | **是**，`NetConf.IPMasq` / `IPMasqBackend` |
| `pkg/ip`（plugins 库） | **是**，真正写 iptables / nftables |

配置字段（`bridge.go`）：

```go
IPMasq        bool    `json:"ipMasq"`
IPMasqBackend *string `json:"ipMasqBackend,omitempty"` // "iptables" | "nftables"；nil 则自动选
```

前置条件：仅在 **L3**（配置了 `ipam`）且 `IPMasq==true` 时执行。本机有 `host-local`，属于 L3。

### 8.2 在 bridge ADD / DEL 中的位置

**ADD**（`cmdAdd`，在 IPAM + 配 eth0 + `isGateway` 之后）：

```go
if n.IPMasq {
    ipns := []*net.IPNet{}
    for _, ipc := range result.IPs {
        ipns = append(ipns, &ipc.Address)  // 例如 10.x.y.z/12
    }
    ip.SetupIPMasqForNetworks(n.IPMasqBackend, ipns, n.Name, args.IfName, args.ContainerID)
}
```

注意：传入的是 **带掩码的 Pod 地址**（`ipc.Address`，如 `10.1.2.3/12`），不是整池网段字面量；后续规则里「同网段不伪装」用的是该 IP 所在子网。

**DEL**（`cmdDel`，在删容器侧接口、IPAM DEL 之后）：

```go
if isLayer3 && n.IPMasq {
    ip.TeardownIPMasqForNetworks(ipnets, n.Name, args.IfName, args.ContainerID)
}
```

`ipMasq: false` 时上述两段 **整段跳过**，冷启动路径不碰 nat 表。

### 8.3 后端选择：`SetupIPMasqForNetworks`

代码：`plugins/pkg/ip/ipmasq_linux.go`。

```go
if backend == nil {
    defaultBackend := "iptables"
    if !SupportsIPTables() && SupportsNFTables() {
        defaultBackend = "nftables"
    }
    backend = &defaultBackend
}
switch *backend {
case "iptables":  setupIPMasqIPTables(...)
case "nftables":  setupIPMasqNFTables(...)
}
```

| 条件 | 默认后端 |
|------|----------|
| 未写 `ipMasqBackend`，且主机支持 iptables | **iptables**（优先） |
| 仅有 nftables | nftables |
| 显式 `"ipMasqBackend": "nftables"` | nftables |

DEL 时 `TeardownIPMasqForNetworks` 会 **同时尝试** iptables 与 nftables 清理（兼容配置/版本切换残留）。

### 8.4 iptables 后端：每沙箱一套链

代码：`plugins/pkg/ip/ipmasq_iptables_linux.go`。

链名：`FormatChainName(network, containerID)` → 形如 `CNI-<hash>`（最长 28 字符，前缀 `CNI-`）。  
comment：`name: "<network>" id: "<containerID>"`。  
历史原因：**忽略 ifName**。

对每个 Pod IP（`SetupIPMasq`）执行：

```text
# 1) 若无则 NewChain
iptables -t nat -N CNI-<hash>

# 2) 目的在「该 IP 所在子网」内 → 不伪装（池内/同网段直达）
-A CNI-<hash> -d <ipn>/mask -m comment --comment "..." -j ACCEPT

# 3) 目的不是组播 → MASQUERADE（出网 SNAT）
-A CNI-<hash> ! -d 224.0.0.0/4 -m comment --comment "..." -j MASQUERADE
# IPv6: ! -d ff00::/8

# 4) POSTROUTING：源为该 Pod IP → 跳进专用链
-A POSTROUTING -s <pod-ip> -m comment --comment "..." -j CNI-<hash>
```

语义：

```
Pod 发出的包（源 = pod IP）
  → POSTROUTING 命中 -s podIP → CNI-<hash>
       ├─ 目的在同 subnet → ACCEPT（不改源地址）
       └─ 目的非组播     → MASQUERADE（改成宿主机出口地址）
```

**N 个沙箱 → N 条 POSTROUTING 跳转 + N 条 `CNI-*` 链 + 每链至少 2 条规则。**  
每次 ADD 都要：`ListChains`、可能 `NewChain`、多次 `AppendUnique`——走 xtables 用户态/内核路径，高并发下与全局锁争用，成为 CNI 桶内叠加成本。

DEL：`Delete` POSTROUTING 跳转 → `ClearChain` → `DeleteChain`。

### 8.5 nftables 后端（对照）

代码：`plugins/pkg/ip/ipmasq_nftables_linux.go`。

- 表：`cni_plugins_masquerade`（inet family）
- 链：`masq_checks`；`postrouting` hook（SNAT priority）
- 每条映射一条 rule，comment 含 `network+ifname+containerID` 的 hash（修了 iptables 忽略 ifname 的问题，并便于 GC）
- 规则语义等价：`saddr == podIP && daddr != subnet → masquerade`；组播在 postrouting 里先 return

本机默认未指定 backend 时优先 iptables；压测火焰图里常见 `iptables` / `xtables-nft-multi`。

### 8.6 `ipMasq: false` 时的行为

| 步骤 | `ipMasq: true` | `ipMasq: false`（本机） |
|------|----------------|-------------------------|
| bridge ADD 末尾 | `SetupIPMasqForNetworks` | **跳过** |
| bridge DEL | `TeardownIPMasqForNetworks` | **跳过** |
| 冷启动写 nat | 每沙箱 | **不写** |
| Pod 出网 SNAT | CNI 提供 | **需其它规则**，否则仅靠路由/转发可能无法访问外网 |

`isGateway: true` **只负责**：

- 给 `cni0` 配网关 IP  
- `enableIPForward`  

**不负责** SNAT。因此：

```
转发（isGateway）≠ 出网伪装（ipMasq）
```

关 `ipMasq` 后若仍要出网，本仓库用 **节点级一条** 规则替代 per-sandbox 链（`scripts/setup.sh --ip-masq false`）：

```text
-A POSTROUTING -s 10.0.0.0/12 ! -o cni0 -j MASQUERADE
```

| | CNI per-sandbox（ipMasq true） | 节点级一条（ipMasq false + setup.sh） |
|--|--|--|
| 粒度 | 每沙箱 `/32` + `CNI-*` 链 | 整池 `10.0.0.0/12` |
| 谁写 | bridge ADD/DEL | `setup.sh` 一次 ensure |
| 冷启动 | 每次改 nat | **不碰** |
| 出网 SNAT | 有 | 有（本场景对齐） |
| 池内互访 | 链内 `-d 子网 ACCEPT` | 走 `cni0`，不命中 `! -o cni0` |
| 组播 | `! -d 224/4` 才 MASQ | 节点级规则未单独排除组播（若需可再收紧） |

### 8.7 与 containerd 路径的关系

```
setupPodNetwork
  └─ bridge ADD
       ├─ RTNL：cni0 / veth / IP …     ← rtnl_mutex
       ├─ isGateway：ensureAddr(cni0) + ip_forward   ← §7
       └─ ipMasq? ──true──► iptables/nft 写 nat       ← 本节
                  └─false─► 无
```

containerd 侧 **看不到** `ipMasq` 开关；trace 上只表现为 `cni.plugin.bridge` / `cni.setup_pod_network` 变长。要确认是否在做 masq：查 conf、或 `iptables -t nat -L -n` / perf 是否出现 `iptables`。

### 8.8 性能含义（本仓库对照摘要）

在关 printk 之上，仅切 `ipMasq: true → false`（详见 `sandbox-cold-start-bottleneck-analysis.md`）：

| 指标 | ipMasq true | ipMasq false |
|------|-------------|--------------|
| `cni.setup` Avg | ~1.21s | **~386ms** |
| on-CPU `iptables` | ~25% | **~0%** |
| 吞吐 | ~15.1/s | **~17.3/s（+14%）** |
| `loopback` span | 几乎不变 | 几乎不变（无 masq） |

结论：

1. **`ipMasq` 是 CNI 桶内、与 bridge 主路径（RTNL）及 `isGateway` 独立的叠加项。**  
2. 关 masq **不消除** `rtnl_mutex`，也不取消网关/转发。  
3. 出网可用节点级 MASQUERADE 在冷启动外一次性配置。

复现：

```bash
bash scripts/setup.sh --cni-type bridge --snapshotter overlayfs --ip-masq false
# 或改回 per-sandbox：
bash scripts/setup.sh --cni-type bridge --ip-masq true
```

---


## 9. host-local 行为深入分析

> 本机 `ipam.type` 就是 **host-local**。本节在 §6 总览之上，按插件源码拆开：**谁调用它、如何解析 conf、如何加锁/落盘、如何 round-robin 分配与释放、和 bridge/isGateway 的边界、高并发含义**。

### 9.1 定位：独立二进制，由 bridge 二次 exec

| 角色 | 做什么 |
|------|--------|
| containerd | 不认识 host-local |
| go-cni | `AddNetworkList` → exec **bridge** |
| bridge | `ipam.ExecAdd("host-local", stdin)` → `invoke.DelegateAdd` → 再 exec **`/opt/cni/bin/host-local`** |
| host-local | 只负责 IP 逻辑与磁盘占位，**不**建 veth、**不**改 cni0 |

stdin 仍是 **整份** bridge 网络 JSON（含 `"name":"mynet"`、`"type":"bridge"`、`"ipam":{...}`），host-local 用 `LoadIPAMConfig` 只取 `ipam` + 顶层 `name`。

环境变量（CNI 惯例）：

| 变量 | 沙箱场景典型值 |
|------|----------------|
| `CNI_COMMAND` | `ADD` / `DEL` / `CHECK` |
| `CNI_CONTAINERID` | sandbox ID（= PodSandboxId） |
| `CNI_IFNAME` | `eth0`（go-cni 默认前缀） |
| `CNI_NETNS` | `/var/run/netns/...`（host-local **几乎不用** netns，只做分配） |
| `CNI_PATH` | `/opt/cni/bin` |

代码入口：`plugins/ipam/host-local/main.go` → `cmdAdd` / `cmdDel` / `cmdCheck`。

### 9.2 本机配置如何被理解

```json
"ipam": {
  "type": "host-local",
  "subnet": "10.0.0.0/12",
  "routes": [{ "dst": "0.0.0.0/0" }]
}
```

`LoadIPAMConfig`（`backend/allocator/config.go`）：

1. 反序列化整网 conf → 取 `ipam`。  
2. 旧式单字段 `subnet`（嵌在 `IPAMConfig` 匿名 `*Range`）→ **prepend** 成 `Ranges: []RangeSet{{one Range}}`。  
3. `Ranges[i].Canonicalize()`。  
4. `IPAM.Name = Net.Name` → **`mynet`**（决定数据目录子路径）。  
5. `routes` 原样保留到 ADD 结果。

`Canonicalize` 默认值（subnet = `10.0.0.0/12`）：

| 字段 | 值 | 说明 |
|------|-----|------|
| Gateway | **`10.0.0.1`** | `NextIP(网络地址)`；conf 未写 gateway |
| RangeStart | `10.0.0.1` | 与 Gateway 相同，但迭代会 **跳过** Gateway |
| RangeEnd | 子网 last usable | `lastIP(subnet)` |
| 过小网段 | `/31` `/32` | 直接 error |

可分配集合：约 **`10.0.0.2` … 广播前**，**永不分配** `10.0.0.1`。

可选但本机未用的字段：`dataDir`、`rangeStart`/`rangeEnd`、`gateway`、`resolvConf`、`ranges`（多段）、CNI_ARGS 请求固定 IP。

### 9.3 ADD：完整步骤

```go
// cmdAdd 摘要
ipamConf, _ := LoadIPAMConfig(stdin, args)
store, _ := disk.New(ipamConf.Name, ipamConf.DataDir)  // mynet + 默认 dataDir
defer store.Close()

for idx, rangeset := range ipamConf.Ranges {
    alloc := NewIPAllocator(&rangeset, store, idx)
    ipConf, err := alloc.Get(ContainerID, IfName, requestedIP) // 本机 requestedIP=nil
    result.IPs = append(result.IPs, ipConf)
}
result.Routes = ipamConf.Routes
return PrintResult(result)
```

`IPAllocator.Get`（持锁全程；本机 `requestedIP == nil`）：

```go
a.store.Lock()   // → /var/lib/cni/networks/mynet/lock 上 flock
defer a.store.Unlock()

// ★ 1) GetByID：防重复分配（CNI SPEC）—— 火焰图常见热点，见 §9.4 / §9.9
allocatedIPs := a.store.GetByID(id, ifname)
for _, allocatedIP := range allocatedIPs {
    if _, err := a.rangeset.RangeFor(allocatedIP); err == nil {
        return nil, fmt.Errorf("%s has been allocated to %s, duplicate allocation ...", ...)
    }
}

// 2) round-robin 迭代 + Reserve
iter, _ := a.GetIter()  // 从 last_reserved_ip.0 + 1 开始
for {
    reservedIP, gw = iter.Next()  // 跳过 Gateway；扫完一圈 → nil
    if reservedIP == nil { break }
    if a.store.Reserve(id, ifname, reservedIP.IP, rangeID) {
        break  // O_EXCL 创建成功
    }
}
```

| 分支 | 条件 | 是否调 `GetByID` |
|------|------|------------------|
| **自动分配（本机）** | `requestedIP == nil` | **是**，每次 Get 一次 |
| 指定 IP | `CNI_ARGS` / IPArgs 有请求 | **否**，直接 `Reserve` |

成功返回：

```go
IPConfig{ Address: <ip>/12, Gateway: 10.0.0.1 }
```

### 9.4 磁盘后端：目录、锁、文件语义

代码：`backend/disk/backend.go`、`lock.go`。

**默认路径**（`dataDir` 空）：

```
/var/lib/cni/networks/mynet/
├── lock                 # FileLock → flock 互斥
├── last_reserved_ip.0   # rangeID=0 的游标（纯 IP 字符串）
├── 10.0.0.2             # 文件名=IP；内容见下
├── 10.0.0.3
└── ...
```

**锁**：

```go
// NewFileLock：若 path 是目录，锁文件为 path+"/lock"
l.f.Lock()   // 排他 flock；跨 host-local 进程
```

所有 `Get` / `Release` / `FindByID` 在业务逻辑外包一层 `store.Lock()`，故 **同一 network name 上 ADD/DEL 全局串行**。  
注意：`GetByID` 本身在 `Get` 的 `Lock` **之内**调用，扫盘时间全部算进持锁窗口。

**`GetByID`（读路径，火焰图热点）**：

```go
// disk.Store.GetByID — 无按 ID 的索引，只能全目录扫描
func (s *Store) GetByID(id string, ifname string) []net.IP {
    match := id + "\r\n" + ifname   // 另兼容旧格式：仅 id
    filepath.Walk(s.dataDir, func(path string, info os.FileInfo, err error) error {
        if info.IsDir() { return nil }
        data, _ := os.ReadFile(path)          // ★ 每个 IP 占位文件都读
        if trim(data) == match || trim(data) == id {
            // 文件名 ParseIP → 加入结果
        }
        return nil
    })
    return ips
}
```

语义与成本：

| 项 | 说明 |
|----|------|
| **目的** | 同一 `(ContainerID, ifname)` 若已有落在本 range 的 IP → 拒绝再分配（SPEC 禁止 duplicate） |
| **索引** | **无**；文件名是 IP，内容才是 id/ifname → 只能 Walk + 读内容匹配 |
| **复杂度** | 对 dataDir 内 **每个** 非目录文件 `ReadFile` → **O(已占用 IP 数)** |
| **持锁** | 发生在 flock 临界区内 → 拉长其它沙箱等锁时间 |
| **冷/热** | 池空时几乎只碰到 `lock`/`last_reserved_ip.*`；池内文件上千时，**每次 ADD 先扫一遍全目录** |

`FindByID`（CHECK 用）同样 Walk+读内容，逻辑类似。

**Reserve（占 IP）**：

```go
f, err := os.OpenFile(fname, os.O_RDWR|os.O_EXCL|os.O_CREATE, 0600)
// 已存在 → return false, nil（换下一个 IP）
f.WriteString(id + "\r\n" + ifname)
WriteFile("last_reserved_ip."+rangeID, ip.String())
```

双重保险：flock 串行化进程；`O_EXCL` 防止异常并发下同 IP 双开。  
相对 `GetByID`：成功路径通常 **一次** create+write；失败换 IP 时才多次 `OpenFile`（一般远少于全目录 ReadFile）。

**ReleaseByID（DEL）**：

```go
// 同样 Walk 目录，内容匹配 "id\r\nifname" 则 os.Remove
// 兼容旧格式：仅匹配 id
```

DEL 也是 **O(已占用 IP 数)** 的 Walk；与 ADD 侧 `GetByID` 同类磁盘模式。  
注意：DEL **不**回退 `last_reserved_ip`（游标只前进），符合「尽量不立刻复用刚释放 IP」的 round-robin 意图。

**CHECK**：`FindByID` 只要该容器还有任一占位文件即成功（不校验地址是否仍在网卡上）。

### 9.5 Round-robin 细节

`GetIter`：

- 读 `last_reserved_ip.<rangeID>`  
- 若该 IP 仍落在当前 Ranges 内 → 从它开始（`Next` 先 +1）  
- 否则从 `RangeStart` 起  

`Next`：

- 跳过 `Gateway`  
- 到 `RangeEnd` 后切到下一 Range（本机只有一段）并绕回  
- `cur == startIP` → 池耗尽，返回 nil  

设计意图（代码注释）：崩溃循环的容器不会一直拿到同一 IP，直到扫过整池。

### 9.6 DEL 与 bridge 的配合

```
bridge cmdDel
  ├─ 在 netns 内 DelLinkByName(eth0)  （可能已空）
  ├─ ipam.ExecDel("host-local")       ← host-local cmdDel
  │     └─ 对每个 rangeset：Release(containerID, ifName)
  └─ （若 ipMasq）TeardownIPMasq …
```

host-local `cmdDel`：即使某 range Release 失败也继续其它 range，最后汇总 error。  
**泄漏场景**：进程被 kill、磁盘满、手动删 netns 但未走 CNI DEL → IP 文件残留 → 地址无法再分配，需删文件或重建 dataDir。  
源码对 **GC** 标注 `FIXME`（无自动回收孤儿文件）。

### 9.7 分配结果如何进入 Pod（非 host-local 职责，但闭环）

host-local **只 PrintResult**；真正配网卡的是 bridge：

1. `calcGateways`（§7）：若 Gateway 空且 isGateway，再算 `.1`（本机 IPAM 已填）  
2. `ConfigureIface(eth0)`：`AddrAdd` + `RouteAdd(0.0.0.0/0 via Gateway)`  
3. `ensureAddr(cni0, 10.0.0.1)`：宿主机侧网关  

故：host-local 决定 **「谁拿到哪个 IP」**；bridge+isGateway 决定 **「IP/路由是否生效、网关是否在 cni0」**。

### 9.8 边界与常见故障

| 现象 | 机制 |
|------|------|
| `duplicate allocation is not allowed` | 同一 sandboxID+eth0 再次 ADD 且旧文件仍在 |
| `no IP addresses available` | 池满或大量孤儿文件占满 |
| `requested ip is subnet's gateway` | 显式请求 `.1` |
| 多节点 IP 冲突 | host-local **仅本机**；不能靠共享 NFS dataDir 当集群 IPAM（锁非集群锁） |
| CHECK 过但 Pod 无 IP | CHECK 只看磁盘文件，不看 netns |

```
host-local     → PodIP + Gateway + Routes + 磁盘占位
ConfigureIface → eth0 配置
isGateway      → cni0 上 Gateway + ip_forward
ipMasq         → 出网 SNAT（本机 false）
```

### 9.9 高并发与性能（含火焰图：`GetByID`）

#### 9.9.1 串行拓扑

```
沙箱1 bridge ──► host-local ──► flock(mynet/lock)
                                    │
                                    ├─ GetByID: Walk + ReadFile × N   ← 持锁读盘
                                    ├─ GetIter / Reserve               ← 通常很快
                                    └─ unlock
沙箱2 bridge ──► host-local ──► 等待 flock ……………………………
沙箱N …
```

| 点 | 说明 |
|----|------|
| **串行点** | `/var/lib/cni/networks/mynet/lock`（用户态 flock） |
| **与 RTNL** | 不同锁；但都在 `cni.plugin.bridge` 墙钟内串起来 |
| **与 xtables** | ipMasq 关闭后主剩 RTNL + 本锁 |
| **进程成本** | 每沙箱额外 fork/exec 一次 `host-local` |
| **观测** | profile 通常 **无** 独立 `host-local` span，叠在 `cni.plugin.bridge` / `ipam.ExecAdd` 下 |

#### 9.9.2 为何火焰图里 `GetByID` / 读文件偏高

对照源码，自动分配路径上 **每次** `IPAllocator.Get` 固定先调 `store.GetByID`（§9.3），实现是 **全目录 Walk + 逐文件 `os.ReadFile`**（§9.4），且在 **flock 内**。

因此火焰图里常见：

| 符号 / 模式 | 对应代码 | 为何占比高 |
|-------------|----------|------------|
| `(*Store).GetByID` | `disk/backend.go` | 每沙箱 ADD 必经（无 requestedIP 时） |
| `filepath.Walk` / `os.ReadFile` / `syscall.read` | Walk 回调 | 对 dataDir 下 **每个** IP 文件读一遍内容 |
| 等锁 / `flock` off-CPU | `store.Lock` | 前一沙箱的 GetByID 扫盘拖长临界区 → 后人阻塞 |

关键放大因子：**目录里已有的 IP 占位文件数量 N**（含活跃沙箱 + **孤儿文件**）。

```
单次 ADD 持锁成本 ≈
    O(N) × (stat + open + read + 内容比较)   // GetByID
  + O(1)~O(k) × O_EXCL create                // Reserve，k 为碰撞次数，通常很小
```

对比：

| 操作 | 随 N 增长 | 持锁？ |
|------|-----------|--------|
| **GetByID** | **线性** | 是 |
| Reserve 成功 | 近似常数 | 是 |
| round-robin Next | 池很满且碎片时变长，一般次于全目录读 | 是 |

所以：**不是「分配算法本身很复杂」，而是「无 ID→IP 索引，用全表扫描做重复分配检查」**；N 大或并发高时，火焰图上读盘 / GetByID / 等锁会一起抬高，并拖慢整条 bridge ADD。

额外注意：

1. **DEL 的 `ReleaseByID` 同样 Walk** → 删沙箱高峰时也会扫盘，与 ADD 抢同一把 flock。  
2. **孤儿文件**（未走 CNI DEL）只增不减 → N 单调上升，GetByID 越来越贵，且假「池满」。  
3. `/12` 可分配空间极大，但 **真正贵的是磁盘上已有文件数**，不是理论地址空间。  
4. 指定 IP 的 ADD **跳过** GetByID，本机 CRI 路径用不到。

#### 9.9.3 对照与缓解（运维侧）

```bash
# 占位规模（N 的代理）
ls /var/lib/cni/networks/mynet/ | wc -l
cat /var/lib/cni/networks/mynet/last_reserved_ip.0
# 某 IP 归属：
cat /var/lib/cni/networks/mynet/10.0.0.2
# 强制回收孤儿（慎用，确认无对应沙箱后）：
# rm /var/lib/cni/networks/mynet/<orphan-ip>
```

| 手段 | 作用 |
|------|------|
| 保证 Stop/Remove 走完整 CNI DEL | 控制 N，直接缩短 GetByID |
| 定期清理确认无主的孤儿 IP 文件 | 同上 |
| 火焰图对上 `GetByID`/`ReadFile` | 与「纯 flock 空转」区分：是 **持锁读盘** 而非仅排队 |
| 换带索引/集中式的 IPAM | 避开 host-local 这种「文件名=IP、内容=ID」模型（超出本 conf） |

### 9.10 小结

**host-local = 本机、基于磁盘文件与目录 flock 的 IPAM。**  
对本 conf：从 `10.0.0.0/12` 跳过 `.1` round-robin 分配，结果带 `Gateway=10.0.0.1` 与默认路由；占位在 `/var/lib/cni/networks/mynet/`。自动分配时 **`Get` → `GetByID` 全目录读文件查重**，复杂度随已占用文件数增长且占满 flock，是火焰图上 host-local/bridge 路径常见热点；它不创建网络设备，高并发下与 RTNL 并列构成 CNI 串行来源。

---


## 10. loopback 行为深入分析

### 10.1 为什么每个沙箱都要弄 lo

Linux `CLONE_NEWNET` 新建的 netns 里会有 **`lo` 接口，默认常为 DOWN**。  
若不 UP：

- 进程无法用 `127.0.0.1` / `::1`
- 依赖 localhost 的健康检查、DNS stub、部分 runtime 逻辑会失败

CRI 约定：非 hostNetwork 沙箱必须有可用 loopback。containerd 提供两条路（互斥）：

| 配置 `use_internal_loopback` | 本机 | 行为 |
|------------------------------|------|------|
| **`false`（默认）** | ✓ | Load 时 `WithLoNetwork` → Setup 时 exec `/opt/cni/bin/loopback` |
| `true` | — | `setupPodNetwork` 开头直接 `bringUpLoopback(netns)`，**不**加载 CNI loopback |

`config.toml`：`use_internal_loopback = false`。

### 10.2 containerd 如何挂上 loopback 网络

`service_linux.go`：

```go
networkAttachCount := 2                    // lo + 业务网；内部 lo 时为 1
cni.New(..., WithMinNetworkCount(2), ...)

cniLoadOptions():
  return []cni.Opt{cni.WithLoNetwork, cni.WithDefaultConf}
```

`WithLoNetwork`（go-cni）**不读磁盘**，注入内嵌 conflist：

```json
{
  "cniVersion": "0.3.1",
  "name": "cni-loopback",
  "plugins": [{ "type": "loopback" }]
}
```

内存中 networks 顺序：

```
[0] cni-loopback  ifName="lo"
[1] mynet/bridge  ifName="eth0"   ← 10-mynet.conf
```

**不是** `/etc/cni/net.d` 里的文件；与 `max_conf_num` 无关。

### 10.3 Setup 时如何调用（与 bridge 并行）

本机 `setup_serially = false` → `attachNetworks` **并行**：

```
go-cni Setup
  ├─ goroutine: Network[cni-loopback].Attach
  │     └─ AddNetworkList → exec /opt/cni/bin/loopback ADD
  │           CNI_IFNAME=lo, CNI_NETNS=/var/run/netns/...
  └─ goroutine: Network[mynet].Attach
        └─ exec bridge ADD → host-local …
```

注释（CRI config）：lo 在创建 netns 时已存在，与 eth0 **并行安全**。  
失败任一网络 → Setup 失败（firstError）。

Remove/Stop：`netPlugin.Remove` 会对 **每个** network 调 DEL（含 loopback `LinkSetDown`）。

### 10.4 插件 ADD：几乎只做一件事

代码：`plugins/main/loopback/loopback.go`。

```go
func cmdAdd(args *skel.CmdArgs) error {
    args.IfName = "lo"   // 强制 lo，忽略 CNI_IFNAME 其它值
    ns.WithNetNSPath(args.Netns, func(...) {
        link, _ := LinkByName("lo")
        netlink.LinkSetUp(link)          // ★ 唯一关键副作用

        // 读已有 IPv4/IPv6 地址（内核通常已有 127.0.0.1、::1）
        // 若存在非 loopback 地址 → error
        ...
    })
    // 构造 Result 并 PrintResult（或透传 PrevResult）
}
```

要点：

| 行为 | 说明 |
|------|------|
| **不创建** `lo` | 内核随 netns 已创建 |
| **不分配** IP | 不跑 IPAM；沿用内核 loopback 地址 |
| **只 UP** | `LinkSetUp(lo)` |
| **强制 ifName=lo** | 配置里写别的接口名也无效 |
| Result | 报告 `lo` + 已有 127.0.0.1/`::1`（若有）；CRI **不用** 这些 IP 当 Pod IP |

### 10.5 DEL / CHECK

**DEL**：

```go
LinkSetDown(lo)   // 在 netns 内
// netns 路径已不存在 → 视为成功（幂等）
```

随后 containerd 还会 `NetNS.Remove()` 拆掉整个命名空间；DEL 里 Down 更多是 CNI 语义完整。

**CHECK**：`lo` 必须存在且 `FlagUp`，否则 `"loopback interface is down"`。

### 10.6 内部路径：`bringUpLoopback`（对照）

`use_internal_loopback=true` 时（本机未开）：

```go
// sandbox_run_linux.go
ns.WithNetNSPath(netns, func() {
    link, _ := LinkByName("lo")
    return LinkSetUp(link)
})
```

语义与插件 ADD **等价**（只 UP），但：

- **少一次** fork/exec `loopback`  
- Load 时 **不** `WithLoNetwork`；`networkAttachCount=1`  
- Setup **之前**同步调用，不进 go-cni 并行 Attach  

压测若 loopback span 可观，可对照开内部路径（换的是插件进程开销，不是 RTNL 本身）。

### 10.7 与 RTNL / 性能

| 点 | 说明 |
|----|------|
| netlink | `LinkSetUp(lo)` / DEL 时 `LinkSetDown` 走内核，可能触及 **`rtnl_mutex`** |
| 每沙箱一次 | 与 bridge 并行时仍占一次插件进程 + 一次（或几次）netlink |
| profile | 常见独立 span `cni.plugin.loopback`（冷启动分析里曾有 ~1s / 百毫秒级 Avg，视争用而定） |
| 关 ipMasq/printk 后 | loopback span **几乎不变**（无 masq 路径）→ 说明成本在 lo 自身/RTNL，不在 NAT |
| 与 bridge | **不同插件、可并行**；但抢同一把（或相关）内核锁时仍互相拖慢 |

```
新建 netns → lo 存在且 DOWN
     │
     ├─（默认）CNI loopback ADD → LinkSetUp(lo) → 127.0.0.1 可用
     └─（可选）bringUpLoopback → 同上，无额外进程
     │
     └─ 并行/先后：bridge + host-local → eth0
```

### 10.8 边界与注意

1. **Pod IP 不是 lo 上的 127.0.0.1**；CRI 看 `eth0`。  
2. hostNetwork 沙箱 **不跑** 本段 CNI（用宿主机 lo）。  
3. loopback 插件 **不管** eth0 / cni0 / IPAM。  
4. 若只关 bridge、误删 WithLoNetwork 且未开 internal → netns 内 lo 可能一直 DOWN。  
5. 调试：`nsenter --net=/var/run/netns/<x> ip link show lo`。

### 10.9 小结

**loopback = 把新 netns 里已存在的 `lo` 设为 UP。**  
本机通过 go-cni 内嵌 `cni-loopback` 配置，在 Setup 时与 bridge **并行** exec `/opt/cni/bin/loopback`；不做 IPAM、不创建接口。成本主要是每沙箱一次插件进程 + `LinkSetUp` 的 netlink；高并发下会体现在 `cni.plugin.loopback` span，并与其它配网操作争用 RTNL。

---

## 11. Result 如何回到 CRI

1. go-cni 合并各 network 的 Result。  
2. CRI 检查 **`eth0`**（默认前缀 `eth` + index 0）是否有 IP。  
3. `selectPodIPs` 按 `ip_preference` 选主 IP / 附加 IP。  
4. 写入 `sandbox.IP`、`sandbox.CNIResult`（后续 Status 可直接用，避免反复进 netns 查 IP）。  
5. pause / 业务容器 OCI spec：`linux.namespaces` 中 network 的 `path = NetNSPath`；**runc 只 setns，不再配网**。

`PodSandboxStatus` 对外暴露的 Pod IP 即来自此缓存（及必要时的 netns 查询逻辑）。

---

## 12. 端到端时序（本机 bridge 配置）

```
crictl runp / RunPodSandbox
  │
  ├─ 创建 netns @ /var/run/netns/...
  │
  ├─ go-cni Setup（并行；use_internal_loopback=false）
  │    ├─ loopback ADD  →  LinkSetUp(lo)，无 IPAM
  │    └─ bridge ADD
  │         ├─ 确保 / 复用 cni0
  │         ├─ 建 veth，容器端为 eth0
  │         ├─ host-local 分配 10.0.0.0/12 地址
  │         ├─ host-local ADD：锁 mynet/、分配 10.x/12、写 IP 文件（Gateway=10.0.0.1）
  │         ├─ ConfigureIface：eth0 IP + default via 10.0.0.1
  │         ├─ isGateway:true → ensureAddr(cni0, 10.0.0.1) + ip_forward=1
  │         └─ ipMasq:false → 不写 MASQUERADE
  │
  ├─ 缓存 sandbox.IP = eth0 地址
  ├─ NewTask / Start pause（加入该 netns）
  └─ SANDBOX_READY
```

Stop：`CNI DEL` → host-local 删 IP 文件释放地址；`ipMasq:true` 时 Teardown masq；**不会**清掉 cni0 网关地址 → 删 netns。

---

## 13. 与性能/瓶颈的关系（摘要）

| 现象 | 机制 |
|------|------|
| profile 中 `cni.setup_pod_network` 占比高 | 每沙箱插件 exec + 大量 netlink |
| 高并发下 bridge 时延膨胀 | 多沙箱争用内核 **`rtnl_mutex`** |
| `isGateway` | 幂等配 cni0 IP + sysctl；通常非主瓶颈（§7） |
| `ipMasq: true` | 每沙箱 xtables/nft；本机 **false**（§8） |
| **host-local IPAM** | 目录 **flock** 串行；自动分配时 **`GetByID` 全目录 ReadFile**（O(已占文件数)，§9.9） |
| **loopback** | 每沙箱 `LinkSetUp(lo)` + 插件进程；可与 bridge 并行，仍争 RTNL（§10） |

详见 `sandbox-cold-start-bottleneck-analysis.md`；本文件 §7–§10 为代码语义。

---

## 14. 常见注意点

1. **containerd 不解析 `bridge`/`isGateway`/`ipMasq`**，只把 JSON 交给插件。  
2. **`isGateway` ≠ `ipMasq`**：前者转发/网关，后者出网 SNAT。  
3. **`max_conf_num=1`** 时只认字典序第一个 conf。  
4. **hostNetwork** 沙箱完全跳过 CNI（也就没有 masq）。  
5. **业务容器**不重新跑 CNI；共享沙箱 netns。  
6. 出网失败时区分：无转发（isGateway/sysctl）、无 SNAT（ipMasq/节点级规则）、路由/firewall。  
7. 调试：`iptables -t nat -L -n -v`、`nft list table inet cni_plugins_masquerade`、CNI result、`/var/lib/cni/networks/mynet/`。

---

## 15. 一句话总结

本机配置下，containerd 建 netns 后 **并行**跑 **loopback**（`lo` UP）与 **bridge**；bridge 内 **host-local** 分配 `10.0.0.0/12`；**isGateway** 把 `10.0.0.1` 落到 `cni0` 并开转发；**ipMasq:false** 不做 per-sandbox MASQUERADE。loopback / IPAM / 网关 / SNAT 职责分离。

---

## 修订记录

| 日期 | 说明 |
|------|------|
| 2026-07-17 | 初稿：基于本机 `10-mynet.conf` 与 containerd/go-cni/bridge 代码路径的 CNI 行为分析 |
| 2026-07-17 | 新增 `ipMasq` 代码路径（现 §8） |
| 2026-07-17 | 新增 §7 `isGateway`（calcGateways / ensureAddr / ip_forward / 与 IPAM、isDefaultGateway、ipMasq 关系） |
| 2026-07-17 | 新增 §9 IPAM host-local 初稿 |
| 2026-07-17 | 加深 §9 host-local：二次 exec、flock/O_EXCL、Reserve/Release/CHECK、round-robin、泄漏与并发串行 |
| 2026-07-17 | 新增 §10 loopback：WithLoNetwork、插件 LinkSetUp、并行 Setup、internal 对照、RTNL/性能 |
| 2026-07-17 | §9 加深 `GetByID`：自动分配必经、Walk+ReadFile、持锁 O(N)、火焰图热点与孤儿文件放大 |
