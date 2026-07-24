#!/bin/bash
# ============================================================
# 从本地源码编译并安装 containerd / shim / runc / CNI
#
# 方法对齐 doc/sandbox-cold-start-bottleneck-analysis.md §13：
#   debug   — profile 分支 + -gcflags 'all=-N -l'（perf / 分析用，更慢）
#   release — 正式 commit + -ldflags '-s -w'（吞吐压测用）
#
# 源码 ref:
#   debug:   containerd:profile  runc:profile_cgroup-misc  plugins:profile
#   release: containerd:b4ab8c05… runc:bb14dabe… plugins:33cc6bd6…
#
# 默认开源仓库（缺失时自动 git clone）:
#   https://gitee.com/omnihorizon/containerd.git
#   https://gitee.com/omnihorizon/runc.git
#   https://gitee.com/omnihorizon/plugins.git
#
# 用法:
#   ./scripts/setup/build_install_runtime.sh --mode debug
#   ./scripts/setup/build_install_runtime.sh --mode release
#   ./scripts/setup/build_install_runtime.sh --mode debug --only cni
#   ./scripts/setup/build_install_runtime.sh --mode release --only containerd,runc
#   ./scripts/setup/build_install_runtime.sh --mode debug --no-restart
#   ./scripts/setup/build_install_runtime.sh --mode release --no-backup
#
# 默认源码根: /home/nathan/{containerd,runc,plugins}
#
# Go 缺失时：优先 <repo>/install/ 下的官方包，没有再下载
#   arm64: go1.26.3.linux-arm64.tar.gz
#   amd64: go1.26.3.linux-amd64.tar.gz
#
# 脚本运行依赖：优先 <repo>/install/build-deps/*.rpm，
# 缺失则 yum/dnf 下载后再本地安装：
#   make gcc pkg-config libseccomp-devel
# ============================================================
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "${SCRIPT_DIR}/../.." && pwd)
INSTALL_FILES_DIR="${INSTALL_FILES_DIR:-${REPO_ROOT}/install}"

SRC_ROOT="${SRC_ROOT:-/home/nathan}"
CONTAINERD_SRC="${CONTAINERD_SRC:-$SRC_ROOT/containerd}"
RUNC_SRC="${RUNC_SRC:-$SRC_ROOT/runc}"
CNI_SRC="${CNI_SRC:-$SRC_ROOT/plugins}"
CNI_BIN_DIR="${CNI_BIN_DIR:-/opt/cni/bin}"

# Go 默认版本与安装前缀（解压后为 $GO_PREFIX/go/bin/go，即 /opt/go/bin/go）
GO_VERSION="${GO_VERSION:-1.26.3}"
GO_PREFIX="${GO_PREFIX:-/opt}"

# 脚本运行依赖（yum 包名；pkg-config 由 pkgconf-pkg-config 提供）
BUILD_DEP_PKGS=(make gcc pkg-config libseccomp-devel)
BUILD_DEPS_DIR="${BUILD_DEPS_DIR:-${INSTALL_FILES_DIR}/build-deps}"

# 默认开源仓库（可用环境变量覆盖）
CONTAINERD_REPO="${CONTAINERD_REPO:-https://gitee.com/omnihorizon/containerd.git}"
RUNC_REPO="${RUNC_REPO:-https://gitee.com/omnihorizon/runc.git}"
CNI_REPO="${CNI_REPO:-https://gitee.com/omnihorizon/plugins.git}"

# profile（debug）：分支；正式（release）：钉死 commit
CONTAINERD_REF_PROFILE="${CONTAINERD_REF_PROFILE:-profile}"
RUNC_REF_PROFILE="${RUNC_REF_PROFILE:-profile_cgroup-misc}"
CNI_REF_PROFILE="${CNI_REF_PROFILE:-profile}"
CONTAINERD_REF_RELEASE="${CONTAINERD_REF_RELEASE:-b4ab8c0537d3178a4b88cbafb9eab8218606f337}"
RUNC_REF_RELEASE="${RUNC_REF_RELEASE:-bb14dabeb7185bb72c8c86735d090dcb20f36587}"
CNI_REF_RELEASE="${CNI_REF_RELEASE:-33cc6bd63968280b330b00468afbb66161aaa6bd}"

MODE=""
ONLY="containerd,shim,runc,cni"
DO_RESTART=true
DO_BACKUP=true
FORCE_CHECKOUT=false
TS="$(date +%Y%m%d%H%M%S)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
fail() { echo -e "${RED}✗${NC} $1"; }

usage() {
    cat <<'EOF'
从本地源码编译并安装 containerd / shim / runc / CNI
方法对齐 doc/sandbox-cold-start-bottleneck-analysis.md §13

默认仓库（目录不存在时自动 clone）:
  https://gitee.com/omnihorizon/containerd.git
  https://gitee.com/omnihorizon/runc.git
  https://gitee.com/omnihorizon/plugins.git

用法:
  ./scripts/setup/build_install_runtime.sh --mode debug     # profile 分支
  ./scripts/setup/build_install_runtime.sh --mode release   # 正式 commit
  ./scripts/setup/build_install_runtime.sh debug
  ./scripts/setup/build_install_runtime.sh --mode debug --only cni
  ./scripts/setup/build_install_runtime.sh --mode release --only containerd,runc,shim
  ./scripts/setup/build_install_runtime.sh --mode debug --no-restart
  ./scripts/setup/build_install_runtime.sh --mode release --no-backup
  ./scripts/setup/build_install_runtime.sh --mode debug --force-checkout

模式与源码 ref:
  debug   → containerd:profile  runc:profile_cgroup-misc  plugins:profile
  release → containerd:b4ab8c05…  runc:bb14dabe…  plugins:33cc6bd6…

选项:
  --mode debug|release   编译模式（必填，或用位置参数）
  --only LIST            逗号分隔: containerd,shim,runc,cni（默认全开）
  --src-root DIR         默认 /home/nathan
  --no-restart           装完不重启 containerd
  --no-backup            不备份将被覆盖的二进制
  --force-checkout       工作区有改动时仍强制 checkout（git checkout -f）

环境变量（可选覆盖）:
  CONTAINERD_REPO / RUNC_REPO / CNI_REPO
  CONTAINERD_SRC / RUNC_SRC / CNI_SRC / SRC_ROOT
  CONTAINERD_REF_PROFILE / RUNC_REF_PROFILE / CNI_REF_PROFILE
  CONTAINERD_REF_RELEASE / RUNC_REF_RELEASE / CNI_REF_RELEASE
  INSTALL_FILES_DIR / GO_VERSION / GO_PREFIX / BUILD_DEPS_DIR
  （无 go 时优先从 INSTALL_FILES_DIR 安装 go\${GO_VERSION}.linux-\${arch}.tar.gz）
  （启动时优先从 BUILD_DEPS_DIR 装 RPM，缺失再 yum 下载）
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            MODE="$2"
            shift 2 ;;
        debug|release)
            MODE="$1"
            shift ;;
        --only)
            ONLY="$2"
            shift 2 ;;
        --src-root)
            SRC_ROOT="$2"
            CONTAINERD_SRC="$SRC_ROOT/containerd"
            RUNC_SRC="$SRC_ROOT/runc"
            CNI_SRC="$SRC_ROOT/plugins"
            shift 2 ;;
        --no-restart)
            DO_RESTART=false
            shift ;;
        --no-backup)
            DO_BACKUP=false
            shift ;;
        --force-checkout)
            FORCE_CHECKOUT=true
            shift ;;
        -h|--help)
            usage ;;
        *)
            echo "ERROR: 未知参数: $1"
            usage ;;
    esac
done

case "$MODE" in
    debug|release) ;;
    "")
        echo "ERROR: 必须指定 --mode debug|release（或位置参数 debug|release）"
        usage ;;
    *)
        echo "ERROR: --mode 必须是 debug 或 release，收到: $MODE"
        exit 1 ;;
esac

# 按模式选定各仓 ref
if [ "$MODE" = "debug" ]; then
    CONTAINERD_REF="$CONTAINERD_REF_PROFILE"
    RUNC_REF="$RUNC_REF_PROFILE"
    CNI_REF="$CNI_REF_PROFILE"
else
    CONTAINERD_REF="$CONTAINERD_REF_RELEASE"
    RUNC_REF="$RUNC_REF_RELEASE"
    CNI_REF="$CNI_REF_RELEASE"
fi

want() {
    # $1 = component name
    [[ ",${ONLY}," == *",$1,"* ]]
}

need_cmd() {
    if ! command -v "$1" &>/dev/null; then
        fail "缺少命令: $1"
        exit 1
    fi
}

ensure_install_dir() {
    mkdir -p "$INSTALL_FILES_DIR"
}

# 优先从 INSTALL_FILES_DIR 取包；没有则下载并保存。stdout 仅路径。
fetch_pkg() {
    local name=$1
    local url=$2
    local dest="${INSTALL_FILES_DIR}/${name}"
    local tmp

    ensure_install_dir
    if [[ -f "$dest" && -s "$dest" ]]; then
        echo "  使用本地包: $dest" >&2
        printf '%s\n' "$dest"
        return 0
    fi

    echo "  本地未找到 ${name}，下载: $url" >&2
    echo "  保存到: $dest" >&2
    need_cmd curl
    tmp="${dest}.partial.$$"
    if ! curl -fsSL "$url" -o "$tmp"; then
        rm -f "$tmp"
        fail "下载失败: $url"
        return 1
    fi
    mv "$tmp" "$dest"
    printf '%s\n' "$dest"
}

detect_go_arch() {
    case "$(uname -m)" in
        x86_64)  echo "amd64" ;;
        aarch64|arm64) echo "arm64" ;;
        *)
            fail "不支持的架构: $(uname -m)（Go 安装仅支持 amd64/arm64）"
            exit 1
            ;;
    esac
}

# 脚本运行依赖是否已就绪（make / gcc / pkg-config / libseccomp 头文件）
build_deps_ready() {
    command -v make >/dev/null 2>&1 || return 1
    command -v gcc >/dev/null 2>&1 || return 1
    command -v pkg-config >/dev/null 2>&1 || return 1
    if pkg-config --exists libseccomp 2>/dev/null; then
        return 0
    fi
    [ -f /usr/include/seccomp.h ]
}

# 将 make/gcc/pkg-config/libseccomp-devel 下载到 BUILD_DEPS_DIR，再本地安装
ensure_build_deps() {
    echo ""
    echo "=== 脚本运行依赖 ==="
    if build_deps_ready; then
        pass "已具备 make / gcc / pkg-config / libseccomp"
        return 0
    fi

    local yum_cmd=""
    if command -v yum >/dev/null 2>&1; then
        yum_cmd=yum
    elif command -v dnf >/dev/null 2>&1; then
        yum_cmd=dnf
    else
        fail "缺少脚本运行依赖，且未找到 yum/dnf"
        echo "  请手动安装: ${BUILD_DEP_PKGS[*]}"
        exit 1
    fi

    ensure_install_dir
    mkdir -p "$BUILD_DEPS_DIR"
    echo "  依赖包目录: $BUILD_DEPS_DIR"

    local rpms=()
    shopt -s nullglob
    rpms=("$BUILD_DEPS_DIR"/*.rpm)
    shopt -u nullglob

    if [ ${#rpms[@]} -eq 0 ]; then
        echo "  本地无 RPM，下载: ${BUILD_DEP_PKGS[*]}"
        if command -v yumdownloader >/dev/null 2>&1; then
            yumdownloader --resolve --destdir="$BUILD_DEPS_DIR" \
                "${BUILD_DEP_PKGS[@]}"
        elif command -v dnf >/dev/null 2>&1; then
            dnf download --resolve --destdir="$BUILD_DEPS_DIR" \
                "${BUILD_DEP_PKGS[@]}"
        else
            # 无 yumdownloader 时：只下载不安装到系统
            sudo "$yum_cmd" install -y --downloadonly \
                --downloaddir="$BUILD_DEPS_DIR" \
                "${BUILD_DEP_PKGS[@]}"
        fi
        shopt -s nullglob
        rpms=("$BUILD_DEPS_DIR"/*.rpm)
        shopt -u nullglob
        if [ ${#rpms[@]} -eq 0 ]; then
            fail "下载后仍无 RPM: $BUILD_DEPS_DIR"
            exit 1
        fi
        pass "已下载 ${#rpms[@]} 个 RPM → $BUILD_DEPS_DIR"
    else
        echo "  使用本地包: ${#rpms[@]} 个 RPM"
    fi

    echo "  从本地 RPM 安装: ${BUILD_DEP_PKGS[*]}"
    sudo "$yum_cmd" install -y "${rpms[@]}"

    if ! build_deps_ready; then
        fail "安装后仍缺少 make/gcc/pkg-config/libseccomp，请检查 $BUILD_DEPS_DIR"
        exit 1
    fi
    pass "脚本运行依赖已安装"
}

# 确保 go 可用：已有则用；否则从 install/ 装官方包（缺则下载）到 $GO_PREFIX/go
ensure_go() {
    # 本机常见路径优先
    if [ -x /opt/go/bin/go ]; then
        export PATH="/opt/go/bin:$PATH"
    fi
    if [ -x /usr/local/go/bin/go ]; then
        export PATH="/usr/local/go/bin:$PATH"
    fi
    if command -v go &>/dev/null; then
        pass "已有 Go: $(go version)"
        return 0
    fi

    local goarch pkg url tarball
    goarch=$(detect_go_arch)
    pkg="go${GO_VERSION}.linux-${goarch}.tar.gz"
    url="https://go.dev/dl/${pkg}"

    warn "未找到 go，准备安装 ${pkg} → ${GO_PREFIX}/go"
    echo "  安装包目录: $INSTALL_FILES_DIR"
    tarball=$(fetch_pkg "$pkg" "$url")

    need_cmd sudo
    need_cmd tar
    echo "  解压到 ${GO_PREFIX}/（将创建 ${GO_PREFIX}/go）..."
    # 官方 tarball 顶层目录名为 go/
    sudo rm -rf "${GO_PREFIX}/go"
    sudo tar -C "$GO_PREFIX" -xzf "$tarball"
    if [ ! -x "${GO_PREFIX}/go/bin/go" ]; then
        fail "解压后未找到 ${GO_PREFIX}/go/bin/go"
        exit 1
    fi
    export PATH="${GO_PREFIX}/go/bin:$PATH"
    pass "Go 安装完成: $(go version)"
}

# 若本地目录不存在或为空，则从默认 Gitee 仓库 clone
# $1=显示名 $2=目标目录 $3=仓库 URL $4=用于判定源码就绪的相对路径（如 cmd/containerd）
ensure_src() {
    local name="$1" dest="$2" repo="$3" marker="$4"
    local parent

    if [ -e "$dest/$marker" ]; then
        pass "已有源码: $name → $dest"
        return 0
    fi

    if [ -d "$dest" ]; then
        # 目录存在但不是有效源码树
        if [ -n "$(ls -A "$dest" 2>/dev/null)" ]; then
            fail "$name 目录存在但缺少 $marker: $dest"
            echo "  请清空该目录，或设置正确的 *_SRC / 仓库地址后重试"
            exit 1
        fi
        # 空目录：删掉后 clone（git clone 要求目标不存在或为空，空目录可直接 clone）
        rmdir "$dest" 2>/dev/null || true
    fi

    parent=$(dirname "$dest")
    mkdir -p "$parent"
    echo "  clone $name:"
    echo "    $repo"
    echo "    → $dest"
    if ! git clone "$repo" "$dest"; then
        fail "git clone 失败: $repo"
        exit 1
    fi
    if [ ! -e "$dest/$marker" ]; then
        fail "clone 完成但缺少 $marker: $dest"
        exit 1
    fi
    pass "已 clone: $name → $dest"
}

# 先尝试本地 checkout；本地没有对应 ref 时再 fetch，然后重试
# $1=显示名 $2=目录 $3=ref
checkout_ref() {
    local name="$1" dest="$2" ref="$3"
    local head short
    local co_flags=()

    if [ ! -d "$dest/.git" ]; then
        fail "$name 不是 git 仓库: $dest"
        exit 1
    fi

    echo "  checkout $name → $ref"

    if ! $FORCE_CHECKOUT; then
        # 只拦已跟踪文件的改动；忽略未跟踪构建产物（如 runc / runc.new）
        if [ -n "$(git -C "$dest" status --porcelain -uno 2>/dev/null)" ]; then
            fail "$name 工作区有未提交改动（已跟踪文件）: $dest"
            echo "  请提交/贮藏，或加 --force-checkout"
            git -C "$dest" status --short -uno | head -20
            exit 1
        fi
        local untracked
        untracked=$(git -C "$dest" ls-files --others --exclude-standard 2>/dev/null | head -5 || true)
        if [ -n "$untracked" ]; then
            warn "$name 存在未跟踪文件（忽略，不阻止 checkout），例如:"
            echo "$untracked" | sed 's/^/    /'
        fi
    fi
    $FORCE_CHECKOUT && co_flags+=(-f)

    # 尝试用当前本地已有对象/分支完成 checkout；成功返回 0
    try_local_checkout() {
        # 1) 本地分支或 commit / tag
        if git -C "$dest" rev-parse --verify -q "$ref" >/dev/null; then
            git -C "$dest" checkout "${co_flags[@]}" "$ref"
            return $?
        fi
        # 2) 已有远端跟踪引用 origin/<ref>（此前 fetch 过）
        if git -C "$dest" rev-parse --verify -q "origin/$ref" >/dev/null; then
            git -C "$dest" checkout "${co_flags[@]}" -B "$ref" "origin/$ref"
            return $?
        fi
        return 1
    }

    if try_local_checkout; then
        pass "$name 本地已有 ref，跳过 fetch"
    else
        echo "  本地无 $ref，fetch origin ..."
        if ! git -C "$dest" fetch --tags origin 2>/dev/null; then
            warn "git fetch --tags origin 失败，继续尝试 fetch $ref"
        fi
        git -C "$dest" fetch origin "$ref" 2>/dev/null || true

        if ! try_local_checkout; then
            fail "找不到 ref: $name $ref（本地无且 fetch 后仍无）"
            echo "  仓库: $(git -C "$dest" remote get-url origin 2>/dev/null || echo '?')"
            exit 1
        fi
        pass "$name fetch 后 checkout 成功"
    fi

    head=$(git -C "$dest" rev-parse HEAD)
    short=$(git -C "$dest" rev-parse --short HEAD)
    pass "$name 已在 $short ($head)"
    # 若期望是 commit SHA，核对 HEAD 是否指向该对象
    if [[ "$ref" =~ ^[0-9a-fA-F]{7,40}$ ]]; then
        local want
        want=$(git -C "$dest" rev-parse --verify "${ref}^{commit}" 2>/dev/null || true)
        if [ -z "$want" ]; then
            fail "$name 无法解析期望 commit: $ref"
            exit 1
        fi
        if [ "$head" != "$want" ]; then
            fail "$name HEAD($head) 与期望 commit($want) 不一致"
            exit 1
        fi
    fi
}

ensure_needed_sources() {
    echo ""
    echo "=== 检查 / 拉取源码 ==="
    mkdir -p "$SRC_ROOT"
    if want containerd || want shim; then
        ensure_src "containerd" "$CONTAINERD_SRC" "$CONTAINERD_REPO" "cmd/containerd"
        checkout_ref "containerd" "$CONTAINERD_SRC" "$CONTAINERD_REF"
    fi
    if want runc; then
        ensure_src "runc" "$RUNC_SRC" "$RUNC_REPO" "main.go"
        checkout_ref "runc" "$RUNC_SRC" "$RUNC_REF"
    fi
    if want cni; then
        ensure_src "plugins (CNI)" "$CNI_SRC" "$CNI_REPO" "build_linux.sh"
        checkout_ref "plugins" "$CNI_SRC" "$CNI_REF"
    fi
}

backup_file() {
    local path="$1"
    if ! $DO_BACKUP; then
        return 0
    fi
    if [ -e "$path" ]; then
        sudo cp -a "$path" "${path}.bak.${TS}"
        echo "  备份: ${path}.bak.${TS}"
    fi
}

install_bin() {
    # $1=src $2=dest
    local src="$1" dest="$2"
    sudo mkdir -p "$(dirname "$dest")"
    backup_file "$dest"
    sudo install -m 0755 "$src" "$dest"
    pass "已安装: $dest"
}

containerd_version_ldflags() {
    # 输出 -ldflags 内容（不含外层引号）；$1 可选额外 ldflags（如 -s -w）
    local extra="${1:-}"
    local ver rev pkg
    ver=$(git -C "$CONTAINERD_SRC" describe --tags --always 2>/dev/null || echo unknown)
    rev=$(git -C "$CONTAINERD_SRC" rev-parse HEAD 2>/dev/null || echo unknown)
    pkg="github.com/containerd/containerd/v2"
    echo "-X ${pkg}/version.Version=${ver} -X ${pkg}/version.Revision=${rev} -X ${pkg}/version.Package=${pkg} ${extra}"
}

verify_binary() {
    local path="$1"
    echo "  file: $(file -b "$path" 2>/dev/null || echo '?')"
    if [ "$MODE" = "debug" ]; then
        if go version -m "$path" 2>/dev/null | grep -q -- '-N -l'; then
            pass "  gcflags 含 all=-N -l"
        else
            warn "  未在 go version -m 中看到 -N -l（请人工检查）"
            go version -m "$path" 2>/dev/null | grep -E 'gcflags|CGO' || true
        fi
        if file "$path" 2>/dev/null | grep -qiE 'not stripped|with debug_info'; then
            pass "  符号/DWARF 保留"
        else
            warn "  file 未显示 not stripped / debug_info"
        fi
    else
        if go version -m "$path" 2>/dev/null | grep -q -- '-N -l'; then
            warn "  release 构建仍含 -N -l？"
        else
            pass "  无 -N -l（优化构建）"
        fi
    fi
}

build_containerd() {
    echo ""
    echo "=== containerd ($MODE) ==="
    [ -d "$CONTAINERD_SRC/cmd/containerd" ] || { fail "源码不存在: $CONTAINERD_SRC"; exit 1; }
    mkdir -p "$CONTAINERD_SRC/bin"
    local ldflags out="$CONTAINERD_SRC/bin/containerd"
    pushd "$CONTAINERD_SRC" >/dev/null
    if [ "$MODE" = "debug" ]; then
        # §13.1：勿用 make GODEBUG=1（trimpath 会盖掉 -N -l）
        ldflags=$(containerd_version_ldflags)
        echo "  CGO_ENABLED=0 go build -buildmode=pie -gcflags 'all=-N -l' ..."
        CGO_ENABLED=0 go build -buildmode=pie -gcflags 'all=-N -l' \
            -o "$out" \
            -ldflags "$ldflags" \
            -tags "urfave_cli_no_docs static_build" \
            ./cmd/containerd
    else
        ldflags=$(containerd_version_ldflags "-s -w")
        echo "  CGO_ENABLED=0 go build -buildmode=pie -ldflags '... -s -w' ..."
        CGO_ENABLED=0 go build -buildmode=pie \
            -o "$out" \
            -ldflags "$ldflags" \
            -tags "urfave_cli_no_docs static_build" \
            ./cmd/containerd
    fi
    popd >/dev/null
    pass "编译完成: $out"
    for p in /usr/local/bin/containerd /usr/bin/containerd; do
        [ -e "$p" ] || [ "$p" = /usr/local/bin/containerd ] || continue
        install_bin "$out" "$p"
    done
    # 若 /usr/bin 尚无且未安装过，至少保证 /usr/local/bin
    if [ ! -e /usr/local/bin/containerd ]; then
        install_bin "$out" /usr/local/bin/containerd
    fi
    verify_binary "$(command -v containerd)"
}

build_shim() {
    echo ""
    echo "=== containerd-shim-runc-v2 ($MODE) ==="
    [ -d "$CONTAINERD_SRC/cmd/containerd-shim-runc-v2" ] || { fail "源码不存在 shim: $CONTAINERD_SRC"; exit 1; }
    mkdir -p "$CONTAINERD_SRC/bin"
    local ldflags out="$CONTAINERD_SRC/bin/containerd-shim-runc-v2"
    pushd "$CONTAINERD_SRC" >/dev/null
    if [ "$MODE" = "debug" ]; then
        # §13.2：Makefile GODEBUG 对 shim 的 -N -l 无效
        ldflags=$(containerd_version_ldflags '-extldflags "-static"')
        echo "  CGO_ENABLED=0 go build -gcflags 'all=-N -l' ..."
        CGO_ENABLED=0 go build -gcflags 'all=-N -l' \
            -o "$out" \
            -ldflags "$ldflags" \
            -tags "urfave_cli_no_docs static_build no_grpc" \
            ./cmd/containerd-shim-runc-v2
    else
        ldflags=$(containerd_version_ldflags '-extldflags "-static" -s -w')
        echo "  CGO_ENABLED=0 go build -ldflags '... -s -w' ..."
        CGO_ENABLED=0 go build \
            -o "$out" \
            -ldflags "$ldflags" \
            -tags "urfave_cli_no_docs static_build no_grpc" \
            ./cmd/containerd-shim-runc-v2
    fi
    popd >/dev/null
    pass "编译完成: $out"
    local installed=false
    for p in /usr/local/bin/containerd-shim-runc-v2 /usr/bin/containerd-shim-runc-v2; do
        if [ -e "$p" ] || [ "$p" = /usr/local/bin/containerd-shim-runc-v2 ]; then
            install_bin "$out" "$p"
            installed=true
        fi
    done
    $installed || install_bin "$out" /usr/local/bin/containerd-shim-runc-v2
    verify_binary "$(command -v containerd-shim-runc-v2)"
}

build_runc() {
    echo ""
    echo "=== runc ($MODE) ==="
    [ -f "$RUNC_SRC/main.go" ] || { fail "源码不存在: $RUNC_SRC"; exit 1; }
    local out="$RUNC_SRC/runc"
    pushd "$RUNC_SRC" >/dev/null
    # 保留 CGO（seccomp）；加 netgo 避免本机 res_search 链接失败（§13.0）
    if [ "$MODE" = "debug" ]; then
        echo "  go build -buildmode=pie -gcflags 'all=-N -l' -tags 'seccomp ... netgo' ..."
        go build -buildmode=pie \
            -gcflags 'all=-N -l' \
            -tags "seccomp urfave_cli_no_docs netgo" \
            -o "$out" .
    else
        echo "  go build -buildmode=pie -ldflags '-s -w' -tags 'seccomp ... netgo' ..."
        go build -buildmode=pie \
            -ldflags '-s -w' \
            -tags "seccomp urfave_cli_no_docs netgo" \
            -o "$out" .
    fi
    popd >/dev/null
    pass "编译完成: $out"
    local installed=false
    for p in /usr/local/sbin/runc /usr/sbin/runc /usr/bin/runc; do
        if [ -e "$p" ] || [ "$p" = /usr/local/sbin/runc ]; then
            install_bin "$out" "$p"
            installed=true
        fi
    done
    $installed || install_bin "$out" /usr/local/sbin/runc
    verify_binary "$(command -v runc)"
}

build_cni() {
    echo ""
    echo "=== CNI plugins ($MODE) ==="
    [ -x "$CNI_SRC/build_linux.sh" ] || { fail "源码不存在: $CNI_SRC/build_linux.sh"; exit 1; }
    pushd "$CNI_SRC" >/dev/null
    if [ "$MODE" = "debug" ]; then
        echo "  CGO_ENABLED=0 ./build_linux.sh -gcflags 'all=-N -l' ..."
        CGO_ENABLED=0 ./build_linux.sh -gcflags 'all=-N -l'
    else
        echo "  CGO_ENABLED=0 ./build_linux.sh -ldflags '-s -w' ..."
        CGO_ENABLED=0 ./build_linux.sh -ldflags '-s -w'
    fi
    popd >/dev/null
    pass "编译完成: $CNI_SRC/bin/"

    if $DO_BACKUP && [ -d "$CNI_BIN_DIR" ]; then
        sudo cp -a "$CNI_BIN_DIR" "${CNI_BIN_DIR}.bak.${TS}"
        echo "  备份目录: ${CNI_BIN_DIR}.bak.${TS}"
    fi
    sudo mkdir -p "$CNI_BIN_DIR"
    # 只安装构建产物中的可执行文件，跳过 tarball / LICENSE 等
    local f base
    for f in "$CNI_SRC"/bin/*; do
        [ -f "$f" ] && [ -x "$f" ] || continue
        base=$(basename "$f")
        case "$base" in
            *.tgz|*.tar|*.gz|LICENSE|README*) continue ;;
        esac
        sudo install -m 0755 "$f" "$CNI_BIN_DIR/$base"
    done
    pass "已安装到 $CNI_BIN_DIR"
    for sample in bridge loopback host-local ipvlan; do
        if [ -x "$CNI_BIN_DIR/$sample" ]; then
            verify_binary "$CNI_BIN_DIR/$sample"
            break
        fi
    done
}

print_containerd_cpus() {
    echo ""
    echo "--- containerd CPU 亲和性 ---"
    local pid affinity
    pid=$(pgrep -nx containerd 2>/dev/null || true)
    if [ -z "$pid" ]; then
        warn "未找到运行中的 containerd 进程"
        return 0
    fi
    affinity=$(taskset -pc "$pid" 2>/dev/null | awk -F': ' '{print $NF}')
    if [ -z "$affinity" ]; then
        warn "无法读取 containerd(pid=$pid) 的 CPU 亲和性"
        return 0
    fi
    pass "containerd pid=$pid 所在 CPU 核心: $affinity"
}

restart_containerd() {
    if ! $DO_RESTART; then
        warn "跳过重启 containerd（--no-restart）"
        return 0
    fi
    # 仅当装了 daemon 或 shim 时重启；纯 CNI 可不重启
    if want containerd || want shim; then
        echo ""
        echo "=== 重启 containerd ==="
        if sudo systemctl restart containerd; then
            sleep 2
            if systemctl is-active --quiet containerd; then
                pass "containerd 已重启"
            else
                fail "containerd 重启后未处于 active"
                return 1
            fi
        else
            fail "systemctl restart containerd 失败"
            return 1
        fi
    else
        warn "未安装 containerd/shim，跳过重启（CNI 下一轮 ADD 即生效）"
    fi
}

print_versions() {
    echo ""
    echo "=== 版本 ==="
    command -v containerd >/dev/null && containerd --version || true
    command -v containerd-shim-runc-v2 >/dev/null && containerd-shim-runc-v2 -v 2>/dev/null || true
    command -v runc >/dev/null && runc --version | head -1 || true
    if [ -d "$CNI_BIN_DIR" ]; then
        echo "CNI: $CNI_BIN_DIR ($(ls "$CNI_BIN_DIR" 2>/dev/null | wc -l) entries)"
    fi
}

main() {
    need_cmd git
    need_cmd sudo
    need_cmd install
    need_cmd file
    ensure_build_deps
    ensure_go

    echo "=============================================="
    echo "  编译安装 runtime 组件"
    echo "=============================================="
    echo "  mode:        $MODE"
    echo "  only:        $ONLY"
    echo "  install dir: $INSTALL_FILES_DIR"
    echo "  build deps:  $BUILD_DEPS_DIR"
    echo "  containerd:  $CONTAINERD_SRC"
    echo "               repo $CONTAINERD_REPO"
    echo "               ref  $CONTAINERD_REF"
    echo "  runc:        $RUNC_SRC"
    echo "               repo $RUNC_REPO"
    echo "               ref  $RUNC_REF"
    echo "  cni:         $CNI_SRC → $CNI_BIN_DIR"
    echo "               repo $CNI_REPO"
    echo "               ref  $CNI_REF"
    echo "  backup:      $DO_BACKUP (ts=$TS)"
    echo "  restart:     $DO_RESTART"
    echo "  force-co:    $FORCE_CHECKOUT"
    echo "  go:          $(go version)"
    echo "=============================================="

    ensure_needed_sources

    if want containerd; then build_containerd; fi
    if want shim; then build_shim; fi
    # --only containerd 时常也需要 shim；若用户只写 containerd，仍编 shim
    if want containerd && ! want shim; then
        warn "--only 含 containerd 但未含 shim；建议同时更新 shim"
    fi
    if want runc; then build_runc; fi
    if want cni; then build_cni; fi

    restart_containerd
    print_versions
    print_containerd_cpus

    echo ""
    if [ "$MODE" = "debug" ]; then
        echo "提示: debug 构建含 -N -l，适合 perf/TRACE 分析，不适合测吞吐。"
        echo "      吞吐压测请改用: $0 --mode release"
    else
        echo "提示: release 已 strip（-s -w），perf 可能看不到 Go 符号。"
        echo "      分析请改用: $0 --mode debug"
    fi
    echo "完成。"
}

main
