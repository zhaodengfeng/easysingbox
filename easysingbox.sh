#!/usr/bin/env bash
set -euo pipefail

# easysingbox.sh — sing-box 代理协议一键部署方案
# Repo: https://github.com/zhaodengfeng/easysingbox

readonly VERSION="0.2.5"
readonly INSTALL_DIR="/opt/easysingbox"
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
    # Command-line flags
    case "${1:-}" in
        --collect-traffic)
            collect_all_traffic
            check_traffic_limits
            exit 0
            ;;
        --monthly-reset)
            monthly_traffic_reset
            exit 0
            ;;
        --version|-v)
            echo "EasySingBox v${VERSION}"
            exit 0
            ;;
        --help|-h)
            echo "EasySingBox v${VERSION} — sing-box 代理协议一键部署"
            echo ""
            echo "用法: easysingbox [选项]"
            echo ""
            echo "选项:"
            echo "  --help, -h              显示帮助信息"
            echo "  --version, -v           显示版本号"
            echo "  --status                显示所有协议状态"
            echo "  --collect-traffic       采集流量 (cron 调用)"
            echo "  --monthly-reset         月度流量重置 (cron 调用)"
            echo ""
            echo "无参数运行进入交互菜单。"
            exit 0
            ;;
        --status)
            if [[ $EUID -ne 0 ]]; then
                echo "请使用 root 用户运行此脚本"
                exit 1
            fi
            show_all_status
            exit 0
            ;;
    esac

    if [[ $EUID -ne 0 ]]; then
        echo "请使用 root 用户运行此脚本"
        exit 1
    fi

    # Ensure directories exist
    mkdir -p "$CONFIG_DIR" "$TLS_DIR" "$SERVICE_DIR" "$MONTHLY_DIR"

    while true; do
        print_main_menu
        read -rp "请选择 [0-5]: " choice
        echo ""

        # 快捷字母处理
        choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]')

        case "$choice" in
            1) menu_install_protocol ;;
            2) protocol_control_menu ;;
            3) menu_user_management ;;
            4) menu_traffic_management ;;
            5) menu_system_management ;;
            0) echo "Bye!"; exit 0 ;;
            *) echo "无效选项"; sleep 1 ;;
        esac
    done
}

print_main_menu() {
    clear
    echo "EasySingBox v${VERSION}"
    echo ""
    echo "┌─────────────────────────────────────┐"
    echo "│  【1】安装协议                      │"
    echo "│  【2】服务状况                      │"
    echo "│  【3】用户管理                      │"
    echo "│  【4】流量统计                      │"
    echo "│  【5】系统管理                      │"
    echo "│  【0】退出                          │"
    echo "└─────────────────────────────────────┘"
    echo ""
}

# ─── Install Protocol Menu ─────────────────────────────────────

menu_install_protocol() {
    while true; do
        print_install_protocol_menu
        read -rp "请选择 [0-10]: " choice
        echo ""

        choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]')

        case "$choice" in
            1)  install_protocol "vless-reality" ; read -rp "按回车键继续..." _ ;;
            2)  install_protocol "vless-ws" ; read -rp "按回车键继续..." _ ;;
            3)  install_protocol "vless-grpc" ; read -rp "按回车键继续..." _ ;;
            4)  install_protocol "vmess-ws" ; read -rp "按回车键继续..." _ ;;
            5)  install_protocol "trojan" ; read -rp "按回车键继续..." _ ;;
            6)  install_protocol "shadowsocks" ; read -rp "按回车键继续..." _ ;;
            7)  install_protocol "shadowtls" ; read -rp "按回车键继续..." _ ;;
            8)  install_protocol "hysteria2" ; read -rp "按回车键继续..." _ ;;
            9)  install_protocol "tuic" ; read -rp "按回车键继续..." _ ;;
            10) install_protocol "anytls" ; read -rp "按回车键继续..." _ ;;
            0) return ;;
            *) echo "无效选项"; sleep 1 ;;
        esac
    done
}

print_install_protocol_menu() {
    clear
    echo "┌────────── 安装协议 ──────────┐"
    echo ""
    echo "  1.  VLESS + Reality     (无需域名)"
    echo "  2.  VLESS + WS + TLS    (需域名+证书)"
    echo "  3.  VLESS + gRPC + TLS  (需域名+证书)"
    echo "  4.  VMess + WS + TLS    (需域名+证书)"
    echo "  5.  Trojan + TLS        (需域名+证书)"
    echo "  6.  Shadowsocks         (无需域名)"
    echo "  7.  ShadowTLS + SS      (需域名+证书)"
    echo "  8.  Hysteria 2         (需域名+证书)"
    echo "  9.  TUIC v5            (需域名+证书)"
    echo " 10.  AnyTLS            (需域名+证书)"
    echo ""
    echo "  0.  返回主菜单"
    echo "└───────────────────────────────────┘"
    echo ""
}

# ─── Service Status Menu ─────────────────────────────────────

# Get human-readable status from actual systemctl
get_real_status() {
    local protocol="$1"
    local service_name
    service_name=$(get_service_name "$protocol")
    local raw
    raw=$(systemctl is-active "$service_name" 2>/dev/null || echo "inactive")
    case "$raw" in
        active)        echo "运行中" ;;
        activating)    echo "启动中" ;;
        inactive)      echo "已停止" ;;
        failed)        echo "异常" ;;
        *)             echo "未知" ;;
    esac
}

protocol_control_menu() {
    while true; do
        clear
        if [[ ! -f "$STATE_FILE" ]]; then
            echo "尚未安装任何协议"
            read -rp "按回车键返回..." _
            return
        fi

        local protocols
        protocols=$(jq -r '.protocols | keys[]' "$STATE_FILE" 2>/dev/null)
        if [[ -z "$protocols" ]]; then
            echo "尚未安装任何协议"
            read -rp "按回车键返回..." _
            return
        fi

        local singbox_version
        singbox_version=$(jq -r '.version // "unknown"' "$STATE_FILE")

        echo "=== 服务状况 (sing-box $singbox_version) ==="
        echo ""
        printf " %-3s %-18s %-6s %-8s %s\n" "#" "协议" "端口" "状态" "域名"
        printf " %-3s %-18s %-6s %-8s %s\n" "---" "----" "----" "----" "----"
        local i=1
        while IFS= read -r proto; do
            local port domain real_status
            port=$(jq -r ".protocols[\"$proto\"].port // \"-\"" "$STATE_FILE")
            domain=$(jq -r ".protocols[\"$proto\"].domain // \"-\"" "$STATE_FILE")
            real_status=$(get_real_status "$proto")
            printf " %-3s %-18s %-6s %-8s %s\n" "$i" "$proto" "$port" "$real_status" "$domain"
            i=$((i + 1))
        done <<< "$protocols"
        echo ""
        echo "输入编号进入协议管理  |  0 返回"
        read -rp "选择: " choice

        # Strip spaces and convert to lowercase
        choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
        [[ "$choice" == "0" || -z "$choice" ]] && return

        # Must be a pure number
        if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
            echo "无效选择"
            sleep 1
            continue
        fi

        local protocol
        protocol=$(echo "$protocols" | sed -n "${choice}p")
        if [[ -z "$protocol" ]]; then
            echo "无效选择"
            sleep 1
            continue
        fi

        protocol_action_menu "$protocol"
    done
}

protocol_action_menu() {
    local protocol="$1"
    while true; do
        clear

        local port domain real_status
        port=$(jq -r ".protocols[\"$protocol\"].port // \"-\"" "$STATE_FILE")
        domain=$(jq -r ".protocols[\"$protocol\"].domain // \"-\"" "$STATE_FILE")
        real_status=$(get_real_status "$protocol")

        echo "=== $protocol ==="
        echo "  端口: $port  状态: $real_status"
        [[ "$domain" != "-" && "$domain" != "null" && -n "$domain" ]] && echo "  域名: $domain"

        # Protocol-specific fields (read from inbound.json config)
        local config_file="${CONFIG_DIR}/${protocol}/inbound.json"
        case "$protocol" in
            vless-reality)
                [[ -f "$config_file" ]] && {
                    echo "  SNI: $(jq -r '.inbounds[0].tls.reality.handshake.server // "-"' "$config_file")"
                    echo "  Public Key: $(jq -r '.protocols["vless-reality"].public_key // "-"' "$STATE_FILE")"
                    echo "  Short ID: $(jq -r '.inbounds[0].tls.reality.short_id[0] // "-"' "$config_file")"
                }
                ;;
            vless-ws)
                [[ -f "$config_file" ]] && echo "  路径: $(jq -r '.inbounds[0].transport.path // "-"' "$config_file")"
                ;;
            vless-grpc)
                [[ -f "$config_file" ]] && echo "  Service Name: $(jq -r '.inbounds[0].transport.service_name // "-"' "$config_file")"
                ;;
            vmess-ws)
                [[ -f "$config_file" ]] && echo "  路径: $(jq -r '.inbounds[0].transport.path // "-"' "$config_file")"
                ;;
            shadowsocks)
                [[ -f "$config_file" ]] && echo "  加密: $(jq -r '.inbounds[0].method // "-"' "$config_file")"
                ;;
            hysteria2)
                local hp_start hp_end
                hp_start=$(jq -r '.protocols["hysteria2"].hop_start // empty' "$STATE_FILE")
                hp_end=$(jq -r '.protocols["hysteria2"].hop_end // empty' "$STATE_FILE")
                [[ -n "$hp_start" && -n "$hp_end" ]] && echo "  端口跳跃: $hp_start-$hp_end"
                ;;
        esac

        # Per-user: credentials + share link + QR
        echo ""
        if [[ -f "$USERS_FILE" ]] && jq -e --arg proto "$protocol" '(.users // [])[] | select(.protocols | index($proto))' "$USERS_FILE" &>/dev/null; then
            local user_names
            user_names=$(jq -r --arg proto "$protocol" '.users[] | select(.protocols | index($proto)) | .name' "$USERS_FILE")
            while IFS= read -r username; do
                echo "--- $username ---"
                local uuid password
                uuid=$(jq -r --arg proto "$protocol" --arg name "$username" '.users[] | select(.protocols | index($proto)) | select(.name == $name) | .uuid // empty' "$USERS_FILE")
                password=$(jq -r --arg proto "$protocol" --arg name "$username" '.users[] | select(.protocols | index($proto)) | select(.name == $name) | .password // empty' "$USERS_FILE")
                # Only show fields relevant to this protocol
                case "$protocol" in
                    vless-reality|vless-ws|vless-grpc|vmess-ws)
                        [[ -n "$uuid" ]] && echo "  UUID: $uuid"
                        ;;
                    tuic)
                        [[ -n "$uuid" ]] && echo "  UUID: $uuid"
                        [[ -n "$password" ]] && echo "  密码: $password"
                        ;;
                    *)
                        [[ -n "$password" ]] && echo "  密码: $password"
                        ;;
                esac
                # Share link + QR
                local share_file="${CONFIG_DIR}/${protocol}/share-link/${username}.txt"
                if [[ -f "$share_file" ]]; then
                    echo ""
                    cat "$share_file"
                    echo ""
                    if command -v qrencode &>/dev/null; then
                        qrencode -t ANSIUTF8 -s 3 -m 1 < "$share_file"
                        echo ""
                    fi
                fi
                echo ""
            done <<< "$user_names"
        else
            echo "暂无用户"
            echo ""
        fi

        echo "───────────────────────────────────"
        echo "  1. 启动/停止"
        echo "  2. 重启"
        echo "  3. 卸载"
        echo ""
        echo "  0. 返回"
        echo ""
        read -rp "选择 [0-3]: " action

        case "$action" in
            1)
                if systemctl is-active --quiet "$(get_service_name "$protocol")"; then
                    stop_service "$protocol"; echo "已停止 $protocol"
                else
                    start_service "$protocol"; echo "已启动 $protocol"
                fi
                sleep 1
                ;;
            2) restart_service "$protocol"; echo "已重启 $protocol"; sleep 1 ;;
            3) do_uninstall_protocol "$protocol"; return ;;
            0|*) return ;;
        esac
    done
}

# ─── User Management Menu ───────────────────────────────────────

menu_user_management() {
    while true; do
        clear
        echo "┌────────── 用户管理 ──────────┐"
        echo ""
        echo "  1.  添加用户"
        echo "  2.  删除用户"
        echo "  3.  启用/禁用用户"
        echo "  4.  重置用户流量"
        echo "  5.  设置流量限额"
        echo "  6.  查看用户列表"
        echo ""
        echo "  0.  返回主菜单"
        echo "└───────────────────────────────────┘"
        echo ""
        read -rp "请选择 [0-6]: " choice
        echo ""

        case "$choice" in
            1) add_user ;;
            2) remove_user ;;
            3) toggle_user ;;
            4) reset_user_traffic ;;
            5) set_user_traffic_limit ;;
            6) list_users ;;
            0) return ;;
            *) echo "无效选项"; sleep 1 ;;
        esac
    done
}

# ─── Traffic Management Menu ─────────────────────────────────────

menu_traffic_management() {
    while true; do
        clear
        echo "┌────────── 流量统计 ──────────┐"
        echo ""
        echo "  1.  本月流量"
        echo "  2.  累计总流量"
        echo "  3.  历史月份"
        echo ""
        echo "  0.  返回主菜单"
        echo "└───────────────────────────────────┘"
        echo ""
        read -rp "请选择 [0-3]: " choice
        echo ""

        case "$choice" in
            1) show_monthly_traffic "$(date +%Y-%m)" ;;
            2) show_total_traffic ;;
            3) show_history_months ;;
            0) return ;;
            *) echo "无效选项"; sleep 1 ;;
        esac
    done
}

# ─── System Management Menu ──────────────────────────────────────────────

menu_system_management() {
    while true; do
        clear
        echo "┌────────── 系统管理 ──────────┐"
        echo ""
        echo "  1.  更新脚本"
        echo "  2.  升级 sing-box"
        echo "  3.  彻底卸载所有服务并删除脚本"
        echo ""
        echo "  0.  返回主菜单"
        echo "└───────────────────────────────────┘"
        echo ""
        read -rp "请选择 [0-3]: " choice
        echo ""

        case "$choice" in
            1) update_self ;;
            2) upgrade_singbox_menu ;;
            3) uninstall_all ;;
            0) return ;;
            *) echo "无效选项"; sleep 1 ;;
        esac
    done
}

# ─── Uninstall All ───────────────────────────────────────────────────────

uninstall_all() {
    echo "⚠️  确定要彻底卸载所有服务并删除 easysingbox 脚本吗？"
    echo "   这将删除所有协议配置、用户数据、流量记录和脚本文件，不可恢复！"
    echo ""
    read -rp "请输入 yes 确认卸载: " confirm
    [[ "$confirm" == "yes" ]] || { echo "已取消"; sleep 1; return; }
    echo ""

    echo "正在停止所有 sing-box 服务 ..."
    if [[ -f "$STATE_FILE" ]]; then
        for protocol in $(jq -r '.protocols | keys[]' "$STATE_FILE" 2>/dev/null); do
            stop_service "$protocol"
        done
    fi

    # Remove hysteria2 port hopping rules if present
    if [[ -f "$STATE_FILE" ]]; then
        local hp_start hp_end hp_port
        hp_start=$(jq -r '.protocols["hysteria2"].hop_start // empty' "$STATE_FILE" 2>/dev/null)
        hp_end=$(jq -r '.protocols["hysteria2"].hop_end // empty' "$STATE_FILE" 2>/dev/null)
        hp_port=$(jq -r '.protocols["hysteria2"].port // empty' "$STATE_FILE" 2>/dev/null)
        if [[ -n "$hp_start" && -n "$hp_end" && -n "$hp_port" ]]; then
            remove_port_hopping "$hp_port" "$hp_start" "$hp_end"
            echo "Hysteria2 端口跳跃规则已清理"
        fi
    fi

    echo "正在删除 systemd 服务 ..."
    rm -f /etc/systemd/system/singbox-*.service
    rm -f "${SERVICE_DIR}/"singbox-*.service
    systemctl daemon-reload

    echo "正在删除 cron 任务 ..."
    rm -f /etc/cron.d/easysingbox-traffic

    echo "正在删除安装目录和命令 ..."
    rm -rf "$INSTALL_DIR"
    rm -f /usr/local/bin/easysingbox

    echo ""
    echo "✅ easysingbox 已彻底卸载完毕！"
    echo ""
    read -rp "按回车键退出 ..." _
    exit 0
}

# ─── Update Self ────────────────────────────────────────────────────────

update_self() {
    local REPO_URL="https://raw.githubusercontent.com/zhaodengfeng/easysingbox/main"
    local updated=0
    local failed=0

    echo "正在检查更新 ..."
    echo ""

    # 备份当前文件
    echo "备份当前文件 ..."
    mkdir -p "${INSTALL_DIR}/.backup"
    local backup_time=$(date +%Y%m%d_%H%M%S)

    cp "${INSTALL_DIR}/easysingbox.sh" "${INSTALL_DIR}/.backup/easysingbox.sh.${backup_time}" 2>/dev/null || true

    # 定义要更新的文件列表
    declare -a FILES=(
        "easysingbox.sh:easysingbox.sh"
        "lib/common.sh:lib/common.sh"
        "lib/install.sh:lib/install.sh"
        "lib/users.sh:lib/users.sh"
        "lib/traffic.sh:lib/traffic.sh"
        "lib/rebuild.sh:lib/rebuild.sh"
        "lib/share-link.sh:lib/share-link.sh"
        "protocols/vless-reality.sh:protocols/vless-reality.sh"
        "protocols/vless-ws.sh:protocols/vless-ws.sh"
        "protocols/vless-grpc.sh:protocols/vless-grpc.sh"
        "protocols/vmess-ws.sh:protocols/vmess-ws.sh"
        "protocols/trojan.sh:protocols/trojan.sh"
        "protocols/shadowsocks.sh:protocols/shadowsocks.sh"
        "protocols/shadowtls.sh:protocols/shadowtls.sh"
        "protocols/hysteria2.sh:protocols/hysteria2.sh"
        "protocols/tuic.sh:protocols/tuic.sh"
        "protocols/anytls.sh:protocols/anytls.sh"
    )

    for file_info in "${FILES[@]}"; do
        local remote_file="${file_info%%:*}"
        local local_file="${file_info##*:}"
        local local_path="${INSTALL_DIR}/${local_file}"

        echo -n "更新 ${local_file} ... "

        if curl -fsSL --connect-timeout 10 --max-time 30 \
            "${REPO_URL}/${remote_file}" -o "${local_path}.tmp"; then
            mv "${local_path}.tmp" "${local_path}"
            chmod +x "${local_path}" 2>/dev/null || true
            echo "✓"
            ((updated++))
        else
            rm -f "${local_path}.tmp" 2>/dev/null
            echo "✗ (跳过)"
            ((failed++))
        fi
    done

    echo ""
    echo "更新完成！"
    echo "  成功: ${updated} 个文件"
    [[ $failed -gt 0 ]] && echo "  失败: ${failed} 个文件"
    echo ""
    echo "按回车键重新启动菜单..."
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

_SERVER_IP=""
get_server_ip() {
    if [[ -z "$_SERVER_IP" ]]; then
        _SERVER_IP=$(curl -s --max-time 5 ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    fi
    echo "$_SERVER_IP"
}

# ─── Service Management Functions ──────────────────────────────────────────────

show_all_status() {
    if [[ ! -f "$STATE_FILE" ]]; then
        echo "尚未安装任何协议"
        read -rp "按回车键继续..." _
        return
    fi

    local singbox_version
    singbox_version=$(jq -r '.version // "unknown"' "$STATE_FILE")
    echo ""
    echo "=== 协议状态 (sing-box $singbox_version) ==="
    printf "%-20s %-8s %-8s %-10s\n" "协议" "端口" "状态" "域名"
    printf "%-20s %-8s %-8s %-10s\n" "----" "----" "----" "----"

    local protocols
    protocols=$(jq -r '.protocols | keys[]' "$STATE_FILE" 2>/dev/null)
    while IFS= read -r proto; do
        local port domain real_status
        port=$(jq -r ".protocols[\"$proto\"].port // \"-\"" "$STATE_FILE")
        domain=$(jq -r ".protocols[\"$proto\"].domain // \"-\"" "$STATE_FILE")
        real_status=$(get_real_status "$proto")
        printf "%-20s %-8s %-8s %-10s\n" "$proto" "$port" "$real_status" "$domain"
    done <<< "$protocols"
    echo ""
    read -rp "按回车键继续..." _
}

do_uninstall_protocol() {
    local protocol="$1"
    echo "确定卸载协议 $protocol？这将删除配置但保留用户数据 [y/N]"
    read -rp "" confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return

    stop_service "$protocol"

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

    local service_name
    service_name=$(get_service_name "$protocol")
    rm -f "/etc/systemd/system/${service_name}.service"
    rm -f "${SERVICE_DIR}/${service_name}.service"
    systemctl daemon-reload

    rm -rf "${CONFIG_DIR}/${protocol}"
    delete_protocol_state "$protocol"

    jq --arg proto "$protocol" '.users[].protocols |= map(select(. != $proto))' \
        "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

    echo "协议 $protocol 已卸载"
}

main "$@"
