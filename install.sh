#!/usr/bin/env bash
set -euo pipefail

# easysingbox installer — 一键安装
# 用法 1: curl -fsSL URL | sudo bash
# 用法 2: git clone 后 sudo bash install.sh

readonly TARGET_DIR="/opt/easy-singbox"
readonly INSTALLER_VERSION="0.1.5"
REPO_URL="https://raw.githubusercontent.com/zhaodengfeng/easysingbox/main"

# ─── Colors ───────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $1"; }
ok()      { echo -e "${GREEN}[OK]${NC}    $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ─── Header ───────────────────────────────────────────────────────────────

echo "easy-sing-box 一键安装 v${INSTALLER_VERSION}"
echo ""

if [[ $EUID -ne 0 ]]; then
    error "请使用 root 用户运行安装脚本"
    exit 1
fi

# ─── Step 1: System Detection ─────────────────────────────────────────────

info "正在检测系统环境 ..."
echo ""

OS="unknown"
OS_VERSION=""
PKG_MGR="unknown"

if [[ -f /etc/os-release ]]; then
    OS=$(grep -E '^ID=' /etc/os-release | head -1 | cut -d= -f2 | tr -d '"')
    OS_VERSION=$(grep -E '^VERSION_ID=' /etc/os-release | head -1 | cut -d= -f2 | tr -d '"')
fi

case "$OS" in
    ubuntu|debian)
        PKG_MGR="apt"
        info "操作系统: $OS $OS_VERSION (Debian 系)"
        ;;
    centos|rocky|almalinux|fedora|rhel)
        PKG_MGR="yum"
        [[ "$OS" == "fedora" ]] && PKG_MGR="dnf"
        info "操作系统: $OS $OS_VERSION (RHEL 系)"
        ;;
    alpine)
        PKG_MGR="apk"
        info "操作系统: $OS $OS_VERSION (Alpine)"
        ;;
    arch|manjaro)
        PKG_MGR="pacman"
        info "操作系统: $OS $OS_VERSION (Arch 系)"
        ;;
    opensuse*|sles)
        PKG_MGR="zypper"
        info "操作系统: $OS $OS_VERSION (openSUSE 系)"
        ;;
    *)
        warn "未识别的操作系统: $OS，将尝试通用安装方式"
        ;;
esac

ARCH=$(uname -m)
case "$ARCH" in
    x86_64)  SINGBOX_ARCH="amd64"; ok "CPU 架构: $ARCH (amd64)" ;;
    aarch64) SINGBOX_ARCH="arm64";  ok "CPU 架构: $ARCH (arm64)" ;;
    *)       error "不支持的 CPU 架构: $ARCH"; exit 1 ;;
esac

ok "内核版本: $(uname -r)"

if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
    ok "systemd: 已安装"
else
    error "未检测到 systemd，本脚本需要 systemd 管理服务"
    exit 1
fi

# ─── Step 2: Install Dependencies ─────────────────────────────────────────

echo ""
info "正在安装依赖 ..."
echo ""

declare -A REQUIRED_DEPS=(["jq"]="jq" ["openssl"]="openssl" ["curl"]="curl" ["wget"]="wget")
declare -A OPTIONAL_DEPS=(["qrencode"]="qrencode")

get_pkg_name() {
    local cmd="$1"
    case "$OS" in
        alpine)      case "$cmd" in qrencode) echo "qrencode" ;; *) echo "$cmd" ;; esac ;;
        arch|manjaro) case "$cmd" in qrencode) echo "libqrencode" ;; *) echo "$cmd" ;; esac ;;
        opensuse*|sles) case "$cmd" in qrencode) echo "qrencode" ;; *) echo "$cmd" ;; esac ;;
        *)           echo "$cmd" ;;
    esac
}

install_package() {
    local pkg="$1"
    case "$PKG_MGR" in
        apt)  apt-get update -qq &>/dev/null && apt-get install -y -qq "$pkg" &>/dev/null ;;
        yum|dnf) $PKG_MGR install -y -q "$pkg" &>/dev/null ;;
        apk)  apk add --quiet "$pkg" &>/dev/null ;;
        pacman) pacman -Sy --noconfirm --quiet "$pkg" &>/dev/null ;;
        zypper) zypper -q install -y "$pkg" &>/dev/null ;;
        *)    return 1 ;;
    esac
}

MISSING_REQUIRED=()
for cmd in "${!REQUIRED_DEPS[@]}"; do
    if command -v "$cmd" &>/dev/null; then
        ok "$cmd: 已安装"
    else
        MISSING_REQUIRED+=("$cmd")
    fi
done

for cmd in "${!OPTIONAL_DEPS[@]}"; do
    if command -v "$cmd" &>/dev/null; then
        ok "$cmd: 已安装"
    else
        MISSING_REQUIRED+=("$cmd")
    fi
done

if [[ ${#MISSING_REQUIRED[@]} -gt 0 ]]; then
    info "正在安装缺失依赖 ..."
    for cmd in "${MISSING_REQUIRED[@]}"; do
        pkg=$(get_pkg_name "$cmd")
        echo -n "  安装 $pkg ... "
        if install_package "$pkg"; then
            ok "安装成功"
        else
            error "安装 $pkg 失败，请手动安装后重试"
            exit 1
        fi
    done
else
    ok "所有依赖已满足"
fi

# ─── Step 3: Install Files ────────────────────────────────────────────────

echo ""
info "正在安装 easy-sing-box 到 $TARGET_DIR ..."

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
USE_LOCAL=false

# Detect if running from local clone or from curl pipe
if [[ -f "$SCRIPT_DIR/lib/common.sh" ]] && [[ -f "$SCRIPT_DIR/easysingbox.sh" ]]; then
    USE_LOCAL=true
fi

if $USE_LOCAL; then
    info "从本地副本安装 ..."
    cp -r "$SCRIPT_DIR/lib" "$TARGET_DIR/"
    cp -r "$SCRIPT_DIR/protocols" "$TARGET_DIR/"
    cp "$SCRIPT_DIR/easysingbox.sh" "$TARGET_DIR/"
    cp "$SCRIPT_DIR/README.md" "$TARGET_DIR/" 2>/dev/null || true
else
    info "从 GitHub 下载 ..."
    mkdir -p "$TARGET_DIR/lib" "$TARGET_DIR/protocols"

    for f in lib/common.sh lib/install.sh lib/users.sh lib/traffic.sh \
             lib/rebuild.sh lib/share-link.sh \
             protocols/vless-reality.sh protocols/vless-ws.sh \
             protocols/vless-grpc.sh protocols/vmess-ws.sh \
             protocols/trojan.sh protocols/shadowsocks.sh \
             protocols/shadowtls.sh protocols/hysteria2.sh \
             protocols/tuic.sh protocols/anytls.sh \
             easysingbox.sh README.md; do
        echo -n "  下载 $f ... "
        if curl -fsSL --max-time 30 -o "$TARGET_DIR/$f" "$REPO_URL/$f"; then
            ok "成功"
        else
            error "下载 $f 失败"
            exit 1
        fi
    done
fi

chmod +x "$TARGET_DIR/easysingbox.sh"

# Create required directories
mkdir -p "$TARGET_DIR/config" "$TARGET_DIR/tls" "$TARGET_DIR/service" "$TARGET_DIR/traffic/monthly"

# Create initial state and users if not exist
[[ -f "$TARGET_DIR/state.json" ]] || echo '{"version":"","installed_at":"","protocols":{},"traffic_snapshot":{}}' > "$TARGET_DIR/state.json"
[[ -f "$TARGET_DIR/users.json" ]] || echo '{"users":[]}' > "$TARGET_DIR/users.json"

# Create symlink
ln -sf "$TARGET_DIR/easysingbox.sh" /usr/local/bin/easysingbox

# ─── Step 4: Done ─────────────────────────────────────────────────────────

echo ""
echo "=========================================="
echo "  安装完成！"
echo "=========================================="
echo ""
echo "运行: sudo easysingbox"
echo ""
