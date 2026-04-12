#!/usr/bin/env bash
set -euo pipefail

# easysingbox installer
# Installs easy-sing-box to /opt/easy-singbox

readonly TARGET_DIR="/opt/easy-singbox"

echo "╔══════════════════════════════════════╗"
echo "║    easy-sing-box 安装程序            ║"
echo "╚══════════════════════════════════════╝"
echo ""

if [[ $EUID -ne 0 ]]; then
    echo "请使用 root 用户运行安装脚本"
    exit 1
fi

# Create target directory
mkdir -p "$TARGET_DIR"

# Detect source directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "正在安装 easy-sing-box 到 $TARGET_DIR ..."

# Copy files
cp -r "$SCRIPT_DIR/lib" "$TARGET_DIR/"
cp -r "$SCRIPT_DIR/protocols" "$TARGET_DIR/"
cp "$SCRIPT_DIR/easysingbox.sh" "$TARGET_DIR/"
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

echo ""
echo "安装完成！"
echo ""
echo "使用方法:"
echo "  easysingbox              # 运行管理面板"
echo "  或: $TARGET_DIR/easysingbox.sh"
echo ""
