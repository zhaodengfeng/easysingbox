#!/usr/bin/env bash
set -euo pipefail

# easysingbox installer
# Installs easy-sing-box to /opt/easy-singbox with environment detection

readonly TARGET_DIR="/opt/easy-singbox"

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

echo "easy-sing-box 安装程序"
echo ""

if [[ $EUID -ne 0 ]]; then
    error "请使用 root 用户运行安装脚本"
    exit 1
fi

# ─── Step 1: System Detection ─────────────────────────────────────────────

info "正在检测系统环境 ..."
echo ""

# OS detection
OS="unknown"
OS_VERSION=""
PKG_MGR="unknown"

if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    OS="$ID"
    OS_VERSION="$VERSION_ID"
fi

case "$OS" in
    ubuntu|debian)
        PKG_MGR="apt"
        info "操作系统: $OS $OS_VERSION (Debian 系)"
        ;;
    centos|rocky|almalinux|fedora|rhel)
        PKG_MGR="yum"
        if [[ "$OS" == "fedora" ]]; then
            PKG_MGR="dnf"
        fi
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

# Architecture detection
ARCH=$(uname -m)
case "$ARCH" in
    x86_64)
        SINGBOX_ARCH="amd64"
        ok "CPU 架构: $ARCH (amd64)"
        ;;
    aarch64)
        SINGBOX_ARCH="arm64"
        ok "CPU 架构: $ARCH (arm64)"
        ;;
    *)
        error "不支持的 CPU 架构: $ARCH"
        exit 1
        ;;
esac

# Kernel check
KERNEL=$(uname -r)
ok "内核版本: $KERNEL"

# systemd check
if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
    ok "systemd: 已安装"
else
    error "未检测到 systemd，本脚本需要 systemd 管理服务"
    exit 1
fi

# ─── Step 2: Dependency Check & Install ───────────────────────────────────

echo ""
info "正在检查依赖 ..."
echo ""

# Define required and optional dependencies
declare -A REQUIRED_DEPS=(
    ["jq"]="jq"
    ["openssl"]="openssl"
    ["curl"]="curl"
    ["wget"]="wget"
)

declare -A OPTIONAL_DEPS=(
    ["qrencode"]="qrencode"
    ["git"]="git"
)

# Package name mapping for different distros
get_pkg_name() {
    local cmd="$1"
    case "$OS" in
        alpine)
            case "$cmd" in
                jq)       echo "jq" ;;
                openssl)  echo "openssl" ;;
                curl)     echo "curl" ;;
                wget)     echo "wget" ;;
                qrencode) echo "qrencode" ;;
                git)      echo "git" ;;
                *)        echo "$cmd" ;;
            esac
            ;;
        arch|manjaro)
            case "$cmd" in
                openssl)  echo "openssl" ;;
                curl)     echo "curl" ;;
                wget)     echo "wget" ;;
                qrencode) echo "libqrencode" ;;
                git)      echo "git" ;;
                *)        echo "$cmd" ;;
            esac
            ;;
        opensuse*|sles)
            case "$cmd" in
                qrencode) echo "qrencode" ;;
                *)        echo "$cmd" ;;
            esac
            ;;
        *)
            echo "$cmd"
            ;;
    esac
}

install_package() {
    local pkg="$1"
    case "$PKG_MGR" in
        apt)
            apt-get update -qq &>/dev/null
            apt-get install -y -qq "$pkg" &>/dev/null
            ;;
        yum|dnf)
            $PKG_MGR install -y -q "$pkg" &>/dev/null
            ;;
        apk)
            apk add --quiet "$pkg" &>/dev/null
            ;;
        pacman)
            pacman -Sy --noconfirm --quiet "$pkg" &>/dev/null
            ;;
        zypper)
            zypper -q install -y "$pkg" &>/dev/null
            ;;
        *)
            return 1
            ;;
    esac
}

MISSING_REQUIRED=()
MISSING_OPTIONAL=()

# Check required dependencies
for cmd in "${!REQUIRED_DEPS[@]}"; do
    if command -v "$cmd" &>/dev/null; then
        ok "$cmd: 已安装 ($(command -v "$cmd"))"
    else
        MISSING_REQUIRED+=("$cmd")
        warn "$cmd: 未安装"
    fi
done

# Check optional dependencies
for cmd in "${!OPTIONAL_DEPS[@]}"; do
    if command -v "$cmd" &>/dev/null; then
        ok "$cmd: 已安装"
    else
        MISSING_OPTIONAL+=("$cmd")
        warn "$cmd: 未安装 (可选)"
    fi
done

# Install missing required dependencies
if [[ ${#MISSING_REQUIRED[@]} -gt 0 ]]; then
    echo ""
    info "正在安装缺失的必要依赖 ..."
    for cmd in "${MISSING_REQUIRED[@]}"; do
        pkg
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
    echo ""
    ok "所有必要依赖均已满足"
fi

# Install missing optional dependencies
if [[ ${#MISSING_OPTIONAL[@]} -gt 0 ]]; then
    echo ""
    echo "是否安装可选依赖？(推荐)"
    echo "  qrencode — 生成二维码"
    echo "  git      — 从 GitHub 安装/更新脚本"
    echo ""
    read -rp "安装可选依赖？[Y/n]: " install_optional
    install_optional="${install_optional:-y}"

    if [[ "$install_optional" =~ ^[Yy]$ ]]; then
        for cmd in "${MISSING_OPTIONAL[@]}"; do
            pkg=$(get_pkg_name "$cmd")
            echo -n "  安装 $pkg ... "
            if install_package "$pkg"; then
                ok "安装成功"
            else
                warn "安装 $pkg 失败，跳过"
            fi
        done
    else
        info "跳过可选依赖安装"
    fi
fi

# ─── Step 3: Network Check ────────────────────────────────────────────────

echo ""
info "正在检测网络连通性 ..."

if curl -s --max-time 5 https://github.com &>/dev/null; then
    ok "GitHub 连通性: 正常"
    NETWORK_OK=true
else
    warn "GitHub 连通性: 不通"
    warn "如果服务器在国内，可能需要配置代理或使用镜像源下载 sing-box"
    read -rp "是否继续安装？[y/N]: " continue_install
    if [[ ! "$continue_install" =~ ^[Yy]$ ]]; then
        exit 1
    fi
    NETWORK_OK=false
fi

# ─── Step 4: Firewall Check ───────────────────────────────────────────────

echo ""
info "正在检查防火墙状态 ..."

if command -v firewall-cmd &>/dev/null; then
    warn "检测到 firewalld，安装协议后需要手动放行端口"
    info "示例: firewall-cmd --permanent --add-port=8443/tcp && firewall-cmd --reload"
elif command -v ufw &>/dev/null; then
    ufw_status=$(ufw status 2>/dev/null | head -1)
    if [[ "$ufw_status" == *"active"* ]]; then
        warn "检测到 ufw 已启用，安装协议后需要手动放行端口"
        info "示例: ufw allow 8443/tcp"
    else
        ok "ufw 未启用"
    fi
elif command -v iptables &>/dev/null; then
    rules_count=$(iptables -L -n 2>/dev/null | wc -l)
    if (( rules_count > 5 )); then
        warn "检测到 iptables 规则，请确保代理端口已放行"
    else
        ok "iptables: 无明显拦截规则"
    fi
else
    warn "未检测到常见防火墙工具，请自行确认端口可访问"
fi

# ─── Step 5: Port Check ───────────────────────────────────────────────────

echo ""
info "正在检查常用端口占用 ..."

COMMON_PORTS=(80 443 8443 8388)
for port in "${COMMON_PORTS[@]}"; do
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        process=$(ss -tlnp 2>/dev/null | grep ":${port} " | awk '{print $NF}' | head -1)
        warn "端口 $port 已被占用 ($process)"
    else
        ok "端口 $port: 空闲"
    fi
done

# ─── Step 6: Install Files ────────────────────────────────────────────────

echo ""
info "正在安装 easy-sing-box 到 $TARGET_DIR ..."

# Create target directory
mkdir -p "$TARGET_DIR"

# Detect source directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Copy files
cp -r "$SCRIPT_DIR/lib" "$TARGET_DIR/"
cp -r "$SCRIPT_DIR/protocols" "$TARGET_DIR/"
cp "$SCRIPT_DIR/easysingbox.sh" "$TARGET_DIR/"
cp "$SCRIPT_DIR/README.md" "$TARGET_DIR/" 2>/dev/null || true
chmod +x "$TARGET_DIR/easysingbox.sh"

# Create required directories
mkdir -p "$TARGET_DIR/config"
mkdir -p "$TARGET_DIR/tls"
mkdir -p "$TARGET_DIR/service"
mkdir -p "$TARGET_DIR/traffic/monthly"

# Create initial state
if [[ ! -f "$TARGET_DIR/state.json" ]]; then
    cat > "$TARGET_DIR/state.json" <<EOF
{"version":"","installed_at":"","protocols":{},"traffic_snapshot":{}}
EOF
fi

# Create initial users
if [[ ! -f "$TARGET_DIR/users.json" ]]; then
    cat > "$TARGET_DIR/users.json" <<EOF
{"users":[]}
EOF
fi

# Create symlink
if [[ -f /usr/local/bin/easysingbox ]]; then
    rm -f /usr/local/bin/easysingbox
fi
ln -sf "$TARGET_DIR/easysingbox.sh" /usr/local/bin/easysingbox

# ─── Step 7: Post-Install ─────────────────────────────────────────────────

echo ""
echo "安装完成"
echo ""
echo "安装路径: $TARGET_DIR"
echo "命令:     easysingbox"
echo ""
echo "下一步:"
echo "  1. 运行: sudo easysingbox"
echo "  2. 选择安装需要的协议"
echo "  3. 如果使用防火墙，请放行相应端口"
echo ""

# ─── Step 8: Summary ──────────────────────────────────────────────────────

echo "系统信息摘要:"
echo "  操作系统:  $OS $OS_VERSION"
echo "  包管理器:  $PKG_MGR"
echo "  CPU 架构:  $SINGBOX_ARCH"
echo "  systemd:   已安装"
echo "  必要依赖:  已满足"
echo "  GitHub:    $([ "$NETWORK_OK" = true ] && echo "正常" || echo "不通")"
echo ""
