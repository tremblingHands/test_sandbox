# 静态 Go `containerd-shim-kata-v2` / `kata-runtime`

本机 glibc 为 **2.28**，官方 kata-static 自带的 Go shim / `kata-runtime` 需要 **GLIBC_2.32+**，无法直接运行。

用途：

- `stratovirt`：仅 Go runtime（runtime-rs 无后端）
- `--vm-template`：官方 `kata-runtime factory init` 仅 Go qemu 路径
- `--vm-cache N`：VMCache 常驻 server（Go qemu；runtime-rs 已废弃）

## 构建（Kata Containers 4.0.0）

产物放到仓库的 `install/`（gitignore），供 `setup.sh` 安装：

```bash
cd /path/to/kata-containers   # tag/commit 4.0.0
cd src/runtime

# 应用补丁（见下方）
patch -p1 < /path/to/sandbox-tests/config/kata/go-shim-static/patches/0001-factory-nosharedfs-mkdir-sharepath.patch
patch -p1 < /path/to/sandbox-tests/config/kata/go-shim-static/patches/0002-factory-vmcache-default-vmstorepath.patch
patch -p1 < /path/to/sandbox-tests/config/kata/go-shim-static/patches/0003-vmcache-grpc-vsock-contextid.patch

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
- `/opt/kata/bin/kata-runtime-go-static`（factory / VMCache）

## 补丁

### 0001：factory + `shared_fs=none`

`patches/0001-factory-nosharedfs-mkdir-sharepath.patch`：在 `FsSharing` 关闭时仍 `MkdirAll(sharePath)`。

原因：`assignSandbox()` 会把沙箱 `mounts` 软链到 `/run/vc/vm/<vmid>/shared`；不建该目录时软链悬空。

### 0002：VMCache `VMStorePath` 默认值 + FromGrpc agent URL

`patches/0002-factory-vmcache-default-vmstorepath.patch`：

- `NewVM`：`VMStorePath`/`RunStorePath` 为空时填 `/run/vc/vm` 等
- `NewVMFromGrpc`：调用 `setAgentURL()`（否则 agent URL 为空 → `Invalid scheme`）

### 0003：VMCache gRPC 传递 vsock ContextID

`patches/0003-vmcache-grpc-vsock-contextid.patch`：`qemuGrpc` 序列化/恢复 guest CID；`GenerateSocket` 在 hand-off 后复用原 CID。

本机 `--vm-cache 2` smoke：**3/3**，`t_runp` ~0.56–0.75s（优于同机 template ~2s）。

## ARM64 / Kata 4.0 上 `--vm-template` / `--vm-cache`

| 项 | template | vm-cache |
|----|----------|----------|
| `shared_fs` | `none` | `none`（factory 预热无 sharePath） |
| snapshotter | **devmapper** | **devmapper** |
| `sandbox_cgroup_only` | **true** | **true** |
| 常驻进程 | 否（template 文件） | **`kata-vmcache.service`** |

`setup.sh --vm-template` / `--vm-cache N` 会强制上述项。template 本机 smoke 可 3/3 但偏慢；vm-cache 需打 0002 补丁后的静态 `kata-runtime`。
