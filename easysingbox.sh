#!/usr/bin/env bash
set -euo pipefail

# easysingbox.sh — sing-box 代理协议一键部署方案
# Repo: https://github.com/zhaodengfeng/easysingbox

readonly VERSION="0.1.5"
readonly INSTALL_DIR="/opt/easy-singbox"
readonly CONFIG_DIR="${INSTALL_DIR}/config"
readonly TLS_DIR="${INSTALL_DIR}/tls"
readonly SERVICE_DIR="${INSTALL_DIR}/service"
readonly STATE_FILE="${INSTALL_DIR}/state.json"
readonly USERS_FILE="${INSTALL_DIR}/users.json"
readonly TRAFFIC_DIR="${INSTALL_DIR}/traffic"
readonly MONTHLY_DIR="${TRAFFIC_DIR}/monthly"
readonly TOTAL_FILE="${TRAFFIC_DIR}/total.json"
readonly API_SECRET_PORT_BASE=19090

# Load libraries
source "${INSTALL_DIR}/lib/common.sh"
source "${INSTALL_DIR}/lib/install.sh"
source "${INSTALL_DIR}/lib/users.sh"
source "${INSTALL_DIR}/lib/traffic.sh"
source "${INSTALL_DIR}/lib/rebuild.sh"
source "${INSTALL_DIR}/lib/share-link.sh"
source "${INSTALL_DIR}/protocols/vless-reality.sh"
source "${INSTALL_DIR}/protocols/vless-ws.sh"
source "${INSTALL_DIR}/protocols/vless-grpc.sh"
source "${INSTALL_DIR}/protocols/vmess-ws.sh"
source "${INSTALL_DIR}/protocols/trojan.sh"
source "${INSTALL_DIR}/protocols/shadowsocks.sh"
source "${INSTALL_DIR}/protocols/shadowtls.sh"
source "${INSTALL_DIR}/protocols/hysteria2.sh"
source "${INSTALL_DIR}/protocols/tuic.sh"
source "${INSTALL_DIR}/protocols/anytls.sh"

# ─── Entry ───────────────────────────────────────────────────────────────

main() {
    # If called with --collect-traffic, run silently
    if [[ "${1:-}" == "--collect-traffic" ]]; then
        collect_all_traffic
        check_traffic_limits
        exit 0
    fi
    if [[ "${1:-}" == "--monthly-reset" ]]; then
        monthly_traffic_reset
        exit 0
    fi

    if [[ $EUID -ne 0 ]]; then
        echo "请使用 root 用户运行此脚本"
        exit 1
    fi

    # Ensure directories exist
    mkdir -p "$CONFIG_DIR" "$TLS_DIR" "$SERVICE_DIR" "$MONTHLY_DIR"

    while true; do
        print_menu
        read -rp "请选择 [0-22]: " choice
        echo ""

        case "$choice" in
            1)  install_protocol "vless-reality" ;;
            2)  install_protocol "vless-ws" ;;
            3)  install_protocol "vless-grpc" ;;
            4)  install_protocol "vmess-ws" ;;
            5)  install_protocol "trojan" ;;
            6)  install_protocol "shadowsocks" ;;
            7)  install_protocol "shadowtls" ;;
            8)  install_protocol "hysteria2" ;;
            9)  install_protocol "tuic" ;;
            10) install_protocol "anytls" ;;
            11) add_user ;;
            12) remove_user ;;
            13) toggle_user ;;
            14) reset_user_traffic ;;
            15) set_user_traffic_limit ;;
            16) list_users ;;
            17) show_all_status ;;
            18) manage_service_action ;;
            19) uninstall_protocol ;;
            20) upgrade_singbox_menu ;;
            21) view_share_links ;;
            22) view_traffic_stats ;;
            0)  echo "Bye!"; exit 0 ;;
            *)  echo "无效选项" ;;
        esac

        echo ""
        read -rp "按回车键继续..."
    done
}

print_menu() {
    clear
    echo "easy-sing-box v${VERSION}"
    echo ""
    echo "【协议管理】"
    echo "  1.  安装 VLESS + Reality"
    echo "  2.  安装 VLESS + WebSocket + TLS"
    echo "  3.  安装 VLESS + gRPC + TLS"
    echo "  4.  安装 VMess + WebSocket + TLS"
    echo "  5.  安装 Trojan + TLS"
    echo "  6.  安装 Shadowsocks"
    echo "  7.  安装 ShadowTLS + Shadowsocks"
    echo "  8.  安装 Hysteria 2"
    echo "  9.  安装 TUIC v5"
    echo "  10. 安装 AnyTLS"
    echo ""
    echo "【用户管理】"
    echo "  11. 添加用户"
    echo "  12. 删除用户"
    echo "  13. 启用/禁用用户"
    echo "  14. 重置用户流量"
    echo "  15. 设置用户流量限额"
    echo "  16. 查看用户列表及流量"
    echo ""
    echo "【服务管理】"
    echo "  17. 查看所有协议状态"
    echo "  18. 启动/停止/重启指定协议"
    echo "  19. 卸载指定协议"
    echo "  20. 升级 sing-box"
    echo "  21. 查看分享链接/二维码"
    echo "  22. 查看流量统计（本月/累计）"
    echo "  0. 退出"
    echo ""
}

# ─── Protocol install dispatcher ─────────────────────────────────────────

install_protocol() {
    local protocol="$1"

    # Ensure sing-box is installed
    ensure_singbox_installed

    # Check if already installed
    if is_protocol_installed "$protocol"; then
        echo "协议 $protocol 已安装，是否重新安装？[y/N]"
        read -rp "" confirm
        [[ "$confirm" =~ ^[Yy]$ ]] || return 0
    fi

    case "$protocol" in
        vless-reality) install_vless_reality ;;
        vless-ws)      install_vless_ws ;;
        vless-grpc)    install_vless_grpc ;;
        vmess-ws)      install_vmess_ws ;;
        trojan)        install_trojan ;;
        shadowsocks)   install_shadowsocks ;;
        shadowtls)     install_shadowtls ;;
        hysteria2)     install_hysteria2 ;;
        tuic)          install_tuic ;;
        anytls)        install_anytls ;;
    esac && {
        echo ""
        echo "协议 $protocol 安装完成！"
    }
}

# ─── Helpers ─────────────────────────────────────────────────────────────

is_protocol_installed() {
    local protocol="$1"
    [[ -f "$STATE_FILE" ]] && jq -e --arg proto "$protocol" '.protocols | has($proto)' "$STATE_FILE" &>/dev/null
}

get_server_ip() {
    curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}'
}

# ─── Service Management Menu ──────────────────────────────────────────────

show_all_status() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "尚未安装任何协议"
        return
    fi

    local singbox_version
    singbox_version=$(jq -r '.version // "unknown"' "$STATE_FILE")
    echo ""
    echo "=== 协议状态 (sing-box $singbox_version) ==="
    printf "%-20s %-8s %-8s %-10s\n" "协议" "端口" "状态" "域名"
    printf "%-20s %-8s %-8s %-10s\n" "----" "----" "----" "----"

    jq -r '.protocols | to_entries[] | "\(.key)|\(.value.port)|\(.value.status)|\(.value.domain // "-")"' "$STATE_FILE" | \
    while IFS='|' read -r proto port status domain; do
        printf "%-20s %-8s %-8s %-10s\n" "$proto" "$port" "$status" "$domain"
    done
}

manage_service_action() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "尚未安装任何协议"
        return
    fi

    local protocols
    protocols=$(jq -r '.protocols | keys[]' "$STATE_FILE" 2>/dev/null)
    [[ -z "$protocols" ]] && { echo "尚未安装任何协议"; return; }

    echo "已安装的协议:"
    echo "$protocols" | nl -w2 -s'. '
    echo ""
    read -rp "选择协议编号: " idx
    idx=$(echo "$idx" | tr -d ' ')

    local protocol
    protocol=$(echo "$protocols" | sed -n "${idx}p")
    [[ -z "$protocol" ]] && { echo "无效选择"; return; }

    echo ""
    echo "1. 启动"
    echo "2. 停止"
    echo "3. 重启"
    read -rp "选择操作: " action

    case "$action" in
        1) start_service "$protocol"; echo "已启动 $protocol" ;;
        2) stop_service "$protocol"; echo "已停止 $protocol" ;;
        3) restart_service "$protocol"; echo "已重启 $protocol" ;;
        *) echo "无效操作" ;;
    esac
}

uninstall_protocol() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "尚未安装任何协议"
        return
    fi

    local protocols
    protocols=$(jq -r '.protocols | keys[]' "$STATE_FILE" 2>/dev/null)
    [[ -z "$protocols" ]] && { echo "尚未安装任何协议"; return; }

    echo "已安装的协议:"
    echo "$protocols" | nl -w2 -s'. '
    echo ""
    read -rp "选择要卸载的协议编号: " idx
    idx=$(echo "$idx" | tr -d ' ')

    local protocol
    protocol=$(echo "$protocols" | sed -n "${idx}p")
    [[ -z "$protocol" ]] && { echo "无效选择"; return; }

    echo "确定卸载协议 $protocol？这将删除配置但保留用户数据 [y/N]"
    read -rp "" confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return

    # Stop service
    stop_service "$protocol"

    # Remove port hopping rules if hysteria2
    if [[ "$protocol" == "hysteria2" ]]; then
        local hp_start hp_end hp_port
        hp_start=$(jq -r '.protocols["hysteria2"].hop_start // empty' "$STATE_FILE" 2>/dev/null)
        hp_end=$(jq -r '.protocols["hysteria2"].hop_end // empty' "$STATE_FILE" 2>/dev/null)
        hp_port=$(jq -r '.protocols["hysteria2"].port // empty' "$STATE_FILE" 2>/dev/null)
        if [[ -n "$hp_start" ]] && [[ -n "$hp_end" ]] && [[ -n "$hp_port" ]]; then
            remove_port_hopping "$hp_port" "$hp_start" "$hp_end"
            echo "端口跳跃 iptables 规则已清理"
        fi
    fi

    # Remove service file
    local service_name
    service_name=$(get_service_name "$protocol")
    rm -f "/etc/systemd/system/${service_name}.service"
    rm -f "${SERVICE_DIR}/${service_name}.service"
    systemctl daemon-reload

    # Remove config
    rm -rf "${CONFIG_DIR}/${protocol}"

    # Remove from state
    delete_protocol_state "$protocol"

    # Update users - remove protocol from all users
    jq --arg proto "$protocol" '.users[].protocols |= map(select(. != $proto))' \
        "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

    echo "协议 $protocol 已卸载"
}

main "$@"
