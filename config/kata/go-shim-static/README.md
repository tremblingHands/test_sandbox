# 静态 Go `containerd-shim-kata-v2`

本机 glibc 为 **2.28**，官方 kata-static 自带的 Go shim / `kata-runtime` 需要 **GLIBC_2.32+**，无法直接运行。

`stratovirt` 仅存在于 **Go runtime**（runtime-rs 无后端），因此需要用 `CGO_ENABLED=0` 编出静态 shim。

## 构建（Kata Containers 4.0.0）

产物默认放到仓库的 `install/`（gitignore），供 `setup.sh --hypervisor stratovirt` 安装：

```bash
cd /path/to/kata-containers   # tag/commit 4.0.0
cd src/runtime
make pkg/katautils/config-settings.go
mkdir -p /path/to/sandbox-tests/install/go-shim-static
CGO_ENABLED=0 go build -mod=mod -ldflags '-s -w' \
  -o /path/to/sandbox-tests/install/go-shim-static/containerd-shim-kata-v2 \
  ./cmd/containerd-shim-kata-v2/
```

`setup.sh` 会把它安装到 `/opt/kata/bin/containerd-shim-kata-v2-go-static`，并让 containerd 的 `ConfigPath` 指向 Go 侧 `configuration-stratovirt.toml`。
