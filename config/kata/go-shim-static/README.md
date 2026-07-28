# 静态 Go `containerd-shim-kata-v2` / `kata-runtime`

本机 glibc 为 **2.28**，官方 kata-static 自带的 Go shim / `kata-runtime` 需要 **GLIBC_2.32+**，无法直接运行。

用途：

- `stratovirt`：仅 Go runtime（runtime-rs 无后端）
- `--vm-template`：官方 `kata-runtime factory init` 仅 Go qemu 路径

## 构建（Kata Containers 4.0.0）

产物放到仓库的 `install/`（gitignore），供 `setup.sh` 安装：

```bash
cd /path/to/kata-containers   # tag/commit 4.0.0
cd src/runtime

# 可选：VM template + shared_fs=none 需要（见下方补丁）
patch -p1 < /path/to/sandbox-tests/config/kata/go-shim-static/patches/0001-factory-nosharedfs-mkdir-sharepath.patch

make pkg/katautils/config-settings.go
mkdir -p /path/to/sandbox-tests/install/go-shim-static
CGO_ENABLED=0 go build -mod=mod -ldflags '-s -w' \
  -o /path/to/sandbox-tests/install/go-shim-static/containerd-shim-kata-v2 \
  ./cmd/containerd-shim-kata-v2/
CGO_ENABLED=0 go build -mod=mod -ldflags '-s -w' \
  -o /path/to/sandbox-tests/install/go-shim-static/kata-runtime \
  ./cmd/kata-runtime/
```

`setup.sh` 安装到：

- `/opt/kata/bin/containerd-shim-kata-v2-go-static`
- `/opt/kata/bin/kata-runtime-go-static`（`--vm-template` 时 `factory init/destroy`）

## 补丁：factory + `shared_fs=none`

`patches/0001-factory-nosharedfs-mkdir-sharepath.patch`：在 `FsSharing` 关闭时仍 `MkdirAll(sharePath)`。

原因：`assignSandbox()` 会把沙箱 `mounts` 软链到 `/run/vc/vm/<vmid>/shared`；不建该目录时软链悬空，后续 `mkdir .../mounts` 报 `file exists`。

## ARM64 / Kata 4.0 上 `--vm-template`

官方 Go template 测试在 **arm64 skip**。本机可行组合：

| 项 | 要求 |
|----|------|
| `shared_fs` | `none`（virtio-fs 互斥；9p 已从 agent 移除） |
| snapshotter | **devmapper**（块 rootfs） |
| `sandbox_cgroup_only` | **true**（否则 qemu+devmapper 报 `cgroup.procs EINVAL`，kata#6977） |

`setup.sh --vm-template` 会强制上述项。本机 smoke **3/3**，但 `t_runp` ~2.05s，同条件直启 ~1.04s——template 迁移开销大于收益。最短冷启动仍用 **clh/qemu + virtio-fs**（~0.8–1.0s）。
