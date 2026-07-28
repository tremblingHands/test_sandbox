# runc × cgroup v2：`CONFIG_CGROUP_BPF` 与设备控制分析

## 1. 文档概述

### 1.1 背景

将主机切到 **cgroup v2**（`systemd.unified_cgroup_hierarchy=1`）后，矩阵压测冷启动失败，错误从：

```text
openat2 .../cpu.weight: no such file or directory
```

在启用 `cpu` controller（`DefaultCPUAccounting=yes` + reboot）后变为：

```text
bpf_prog_query(BPF_CGROUP_DEVICE) failed: invalid argument
```

本文结合本机源码树：

| 树 | 路径 |
|----|------|
| runc | `/home/nathan/runc` |
| 内核 | `/home/nathan/linux` |

说明 **为何 cgroup v2 下 runc 依赖 `CONFIG_CGROUP_BPF`**，以及该配置在内核与用户态中的具体用途。

### 1.2 结论摘要

| 问题 | 结论 |
|------|------|
| `CONFIG_CGROUP_BPF` 是干什么的？ | 允许通过 `bpf(2)` 把 eBPF 程序 **attach 到 cgroup**；对容器而言，关键是 **`BPF_CGROUP_DEVICE`**（设备 open/mknod 鉴权） |
| 为何 cgroup v2 需要它？ | v2 **没有** `devices` 控制器；runc 用 eBPF device filter **替代** v1 的 `devices.allow` / `devices.deny` |
| 与 `cpu.weight` 的关系？ | **无关**。`cpu.weight` 属 `cpu` controller；本次第二阶段报错属 **设备子系统** |
| 本机失败根因 | 运行内核 **`# CONFIG_CGROUP_BPF is not set`**，`bpf_prog_query(BPF_CGROUP_DEVICE)` 固定返回 `-EINVAL` |

---

## 2. 现象与环境

### 2.1 运行时证据

- 挂载：`cgroup2 on /sys/fs/cgroup ... nsdelegate`
- cmdline 曾含：`systemd.unified_cgroup_hierarchy=1`
- containerd：`SystemdCgroup = false`（cgroupfs，路径形如 `/k8s.io/<id>`）
- runc：1.4.3（由 `scripts/setup/build_install_runtime.sh` 安装）

### 2.2 本机内核配置对照

| 来源 | `CONFIG_CGROUP_DEVICE` | `CONFIG_CGROUP_BPF` |
|------|------------------------|---------------------|
| 运行内核参考 `/boot/config-5.10.0` | `=y` | **未开启** |
| `/home/nathan/linux/.config` | `=y` | `=y` |

即：源码树可编出带 BPF cgroup 的内核，但当前启动的内核没有该能力。

---

## 3. 内核：两套设备控制能力

### 3.1 Kconfig

```text
# /home/nathan/linux/init/Kconfig

config CGROUP_DEVICE
	bool "Device controller"
	help
	  Provides a cgroup controller implementing whitelists for
	  devices which a process in the cgroup can mknod or open.

config CGROUP_BPF
	bool "Support for eBPF programs attached to cgroups"
	depends on BPF_SYSCALL
	select SOCK_CGROUP_DATA
	help
	  Allow attaching eBPF programs to a cgroup using the bpf(2)
	  syscall command BPF_PROG_ATTACH.
```

| 选项 | 主要服务 | 用户可见接口 |
|------|----------|--------------|
| `CONFIG_CGROUP_DEVICE` | cgroup **v1** devices 控制器 | `devices.allow` / `devices.deny` / `devices.list` |
| `CONFIG_CGROUP_BPF` | 向 cgroup attach eBPF（含 device、socket、sysctl 等） | `bpf(BPF_PROG_ATTACH/QUERY/DETACH)` |

cgroup v2 统一层级中 **不再挂载独立的 `devices` 子系统**；容器运行时若仍要限制设备节点，必须走 BPF。

### 3.2 未开启 `CONFIG_CGROUP_BPF` 时的 stub

`/home/nathan/linux/include/linux/bpf-cgroup.h` 在 `#else /* !CONFIG_CGROUP_BPF */` 分支：

```c
static inline int cgroup_bpf_prog_attach(...)
{
	return -EINVAL;
}

static inline int cgroup_bpf_prog_query(...)
{
	return -EINVAL;
}
```

因此用户态一旦对任意 cgroup 做 `BPF_PROG_QUERY` + `BPF_CGROUP_DEVICE`，得到的就是 **`EINVAL`**——与 runc 报错文案一致。

开启后，真正实现位于：

- `kernel/cgroup/cgroup.c`：`cgroup_bpf_attach` / `cgroup_bpf_detach` / `cgroup_bpf_query`
- `kernel/bpf/cgroup.c`：inherit、effective prog array、`__cgroup_bpf_check_dev_permission`
- `kernel/bpf/syscall.c`：`BPF_PROG_QUERY` 分发到 `cgroup_bpf_prog_query`（`case BPF_CGROUP_DEVICE:`）

### 3.3 设备访问热路径

`/home/nathan/linux/security/device_cgroup.c`：

```c
#if defined(CONFIG_CGROUP_DEVICE) || defined(CONFIG_CGROUP_BPF)

int devcgroup_check_permission(short type, u32 major, u32 minor, short access)
{
	int rc = BPF_CGROUP_RUN_PROG_DEVICE_CGROUP(type, major, minor, access);

	if (rc)
		return -EPERM;

	#ifdef CONFIG_CGROUP_DEVICE
	return devcgroup_legacy_check_permission(type, major, minor, access);
	#else
	return 0;
	#endif
}
#endif
```

开启 BPF 时的宏（同头文件）：

```c
#define BPF_CGROUP_RUN_PROG_DEVICE_CGROUP(type, major, minor, access)	\
({									\
	int __ret = 0;							\
	if (cgroup_bpf_enabled)						\
		__ret = __cgroup_bpf_check_dev_permission(type, major,	\
			minor, access, BPF_CGROUP_DEVICE);		\
	__ret;								\
})
```

`__cgroup_bpf_check_dev_permission`（`kernel/bpf/cgroup.c`）构造 `bpf_cgroup_dev_ctx`，在当前任务所属 cgroup 的 effective 数组上 `BPF_PROG_RUN`；返回非 0 表示拒绝。

```c
struct bpf_cgroup_dev_ctx ctx = {
	.access_type = (access << 16) | dev_type,
	.major = major,
	.minor = minor,
};
allow = BPF_PROG_RUN_ARRAY(cgrp->bpf.effective[type], &ctx, BPF_PROG_RUN);
return !allow;
```

**含义**：`CONFIG_CGROUP_BPF` 不仅是「能 load 程序」，而是把 **设备权限检查接到 cgroup 生命周期与 open/mknod 路径上**。

> 说明：`CONFIG_CGROUP_BPF` 还覆盖 `INET_INGRESS/EGRESS`、`SOCK_OPS`、`SYSCTL` 等；对 **runc 创建容器** 而言，硬依赖的是其中的 **`BPF_CGROUP_DEVICE`**。

---

## 4. runc：如何把 OCI devices 落到 cgroup v2

源码以 vendored 包为准：  
`/home/nathan/runc/vendor/github.com/opencontainers/cgroups/devices/`。

### 4.1 注册 v1 / v2 实现

`devices.go`：

```go
func init() {
	cgroups.DevicesSetV1 = setV1
	cgroups.DevicesSetV2 = setV2
	systemd.GenerateDeviceProps = systemdProperties
}
```

`main.go` / libcontainer 通过 blank import `_ "github.com/opencontainers/cgroups/devices"` 启用设备管理；否则 manager 会认为不支持设 device rules。

### 4.2 cgroup v1：`setV1` → 写文件

`v1.go` 对规则做 emulator 差分后写入：

```go
file := "devices.deny"
if rule.Allow {
	file = "devices.allow"
}
```

依赖内核 **`CONFIG_CGROUP_DEVICE`** 与 v1 层级上的 `devices` 子系统。**不需要** `CONFIG_CGROUP_BPF`。

### 4.3 cgroup v2：`setV2` → eBPF

`v2.go`：

```go
func setV2(dirPath string, r *cgroups.Resources) error {
	if r.SkipDevices {
		return nil
	}
	insts, license, err := deviceFilter(r.Devices)
	// ...
	dirFD, err := unix.Open(dirPath, unix.O_DIRECTORY|unix.O_RDONLY, 0o600)
	// ...
	if _, err := loadAttachCgroupDeviceFilter(insts, license, dirFD); err != nil {
		if !canSkipEBPFError(r) {
			return err
		}
	}
	return nil
}
```

要点：

1. `deviceFilter`（`devicefilter.go`）把 OCI/cgroupv1 风格规则 **编译成 eBPF 指令**，读 `bpf_cgroup_dev_ctx` 的 type/access/major/minor，与内核 ctx 布局一致。
2. `canSkipEBPFError`：仅在 user namespace，或规则全是「允许且 rwm」时可忽略 eBPF 失败；**普通 root + 默认 deny 列表不能跳过**——压测路径会严格失败。

### 4.4 `loadAttachCgroupDeviceFilter` 与报错点

`ebpf_linux.go` 注释：

```go
// loadAttachCgroupDeviceFilter installs eBPF device filter program to /sys/fs/cgroup/<foo> directory.
//
// Requires the system to be running in cgroup2 unified-mode with kernel >= 4.15 .
```

流程：

1. `findAttachedCgroupDeviceFilters(dirFd)`  
   → `bpf(BPF_PROG_QUERY, attach_type=BPF_CGROUP_DEVICE)`  
   → 失败则：`bpf_prog_query(BPF_CGROUP_DEVICE) failed: %w`
2. `ebpf.NewProgram`（`Type: CGroupDevice`）→ `BPF_PROG_LOAD`
3. `link.RawAttachProgram` → `BPF_PROG_ATTACH` + `BPF_F_ALLOW_MULTI`
4. 必要时 detach 旧程序

**本机卡在第 1 步**：内核 stub 直接 `-EINVAL`，尚未进入 load/attach。

### 4.5 官方文档要求

`/home/nathan/runc/docs/cgroup-v2.md`：

- 推荐内核 ≥ 5.2，最低 4.15  
- 明确：过旧内核 **缺乏设备权限控制能力**（即无可用的 cgroup BPF device）

---

## 5. 端到端调用链

```text
crictl runp / cold_start
        │
        ▼
containerd → runc create（cgroup v2，SystemdCgroup=false → /sys/fs/cgroup/k8s.io/<id>）
        │
        ▼
cgroups manager Apply
        │
        ├─ cpu / memory / pids / cpuset …（写 cgroup 文件；cpu.weight 需 cpu controller）
        │
        └─ DevicesSetV2 / setV2
                │
                ├─ deviceFilter(rules)     // 用户态生成 eBPF 指令
                │
                └─ loadAttachCgroupDeviceFilter
                        │
                        ├─ bpf PROG_QUERY  BPF_CGROUP_DEVICE   ← 本机 EINVAL
                        ├─ bpf PROG_LOAD   CGROUP_DEVICE
                        └─ bpf PROG_ATTACH BPF_CGROUP_DEVICE
                                │
                                ▼
                     内核 cgrp->bpf.effective[BPF_CGROUP_DEVICE]
                                │
                     open/mknod → devcgroup_check_permission
                                → __cgroup_bpf_check_dev_permission
```

对照表：

```text
                 cgroup v1                            cgroup v2
            ┌──────────────────┐                ┌─────────────────────────┐
设备策略     │ CONFIG_CGROUP_   │                │ CONFIG_CGROUP_BPF       │
            │ DEVICE           │                │ + BPF_CGROUP_DEVICE     │
            └────────┬─────────┘                └────────────┬────────────┘
                     │                                       │
              devices.allow/deny                      eBPF attach 到 cgroup
                     │                                       │
              runc setV1                              runc setV2
                                                      bpf_prog_query/attach
```

---

## 6. 与 `cpu.weight` 问题的关系（同一次切 v2）

切到 cgroup v2 后压测曾先后碰到两类独立问题：

| 阶段 | 报错 | 子系统 | 条件 |
|------|------|--------|------|
| 1 | `.../cpu.weight: no such file` | `cpu` controller | root `cgroup.subtree_control` 未含 `cpu`（常因 `DefaultCPUAccounting=no`） |
| 2 | `bpf_prog_query(BPF_CGROUP_DEVICE)` | 设备 eBPF | **`CONFIG_CGROUP_BPF` 未开启** |

`setup.sh` 中的 `check_cgroup_v2_cpu` 已覆盖：检测 `cpu` 是否在 `subtree_control`，并用用户态 `bpf(BPF_PROG_QUERY)` 探测 `BPF_CGROUP_DEVICE` 是否可用。

**脚本不会配置 `cpu.weight`**：冷启动路径一般不写 CPU weight；是 runc/containerd 在 apply cgroup 时触及 CPU 文件。设备侧同理：脚本不写 BPF，是 runc `setV2` 的默认行为。

---

## 7. 修复选项

| 方案 | 做法 | 适用 |
|------|------|------|
| A. 回 cgroup v1 | 去掉 cmdline / BLS `options` 中的 `systemd.unified_cgroup_hierarchy=1` 后 reboot | 当前运行内核无 `CGROUP_BPF` 时的务实选择 |
| B. 启用 BPF cgroup | 使用/重编 `CONFIG_CGROUP_BPF=y`（及 `BPF_SYSCALL`）的内核 | 必须留在 cgroup v2 时 |
| C. 仅改 SystemdCgroup | 本栈曾试 `SystemdCgroup=true`，仍生成 `/k8s.io/...` 路径导致格式错误；且 **仍需要** 内核支持 `BPF_CGROUP_DEVICE` | 不能单独解决缺 `CGROUP_BPF` |

验证：

```bash
# 是否在 cgroup v2
stat -fc %T /sys/fs/cgroup    # cgroup2fs → v2

# cpu controller
cat /sys/fs/cgroup/cgroup.subtree_control   # 应含 cpu

# 内核是否编了 CGROUP_BPF
grep CGROUP_BPF /boot/config-$(uname -r)   # 或 /boot/config-5.10.0

# 与 runc 相同的 query 是否成功（setup.sh 内亦有探测）
# 成功或仅缓冲区类错误 → 支持；EINVAL → 不支持
```

---

## 8. 参考路径速查

| 主题 | 路径 |
|------|------|
| runc 文档 | `/home/nathan/runc/docs/cgroup-v2.md` |
| v2 设设备 | `/home/nathan/runc/vendor/github.com/opencontainers/cgroups/devices/v2.go` |
| eBPF attach | `/home/nathan/runc/vendor/github.com/opencontainers/cgroups/devices/ebpf_linux.go` |
| 指令生成 | `/home/nathan/runc/vendor/github.com/opencontainers/cgroups/devices/devicefilter.go` |
| v1 写 allow/deny | `/home/nathan/runc/vendor/github.com/opencontainers/cgroups/devices/v1.go` |
| Kconfig | `/home/nathan/linux/init/Kconfig`（`CGROUP_DEVICE` / `CGROUP_BPF`） |
| BPF stub / 宏 | `/home/nathan/linux/include/linux/bpf-cgroup.h` |
| 设备鉴权 | `/home/nathan/linux/security/device_cgroup.c` |
| BPF 运行 | `/home/nathan/linux/kernel/bpf/cgroup.c` |
| 环境检查 | `scripts/setup/setup.sh` → `check_cgroup_v2_cpu` / `_cgroup_bpf_device_ok` |

---

## 9. 一句话

**`CONFIG_CGROUP_BPF` 让内核支持「把 eBPF 挂到 cgroup」；在 cgroup v2 上，runc 正是用其中的 `BPF_CGROUP_DEVICE` 程序实现容器设备白名单。没有该配置，就没有 v2 设备控制器的替代实现，`bpf_prog_query` 会直接失败，容器无法创建。**
