# 仓库配置目录

与 `install/`（下载的静态包、编译产物，已 gitignore）分离：这里放**需要纳入版本库**的配置与说明。

```
config/kata/
  configuration-clh-runtime-rs.toml   # Kata 4.0 runtime-rs Cloud Hypervisor（段名 clh）
  go-shim-static/README.md            # 静态 Go shim 构建说明（stratovirt）
```

- `setup.sh` 通过 `KATA_CONFIG_DIR`（默认 `<repo>/config/kata`）读取上述 toml。
- Go shim **二进制**仍放在 `install/go-shim-static/containerd-shim-kata-v2`（体积大、gitignore）。
