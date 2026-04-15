#!/usr/bin/env bash
set -euo pipefail

# easysingbox.sh — sing-box 代理协议一键部署方案
# Repo: https://github.com/zhaodengfeng/easysingbox

readonly VERSION="0.3.0"
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

# ─── CLI Subcommands ─────────────────────────────────────────────────────

# Protocol name mapping for CLI
_resolve_protocol() {
    local input="$1"
    case "$input" in
        vless-reality|reality)      echo "vless-reality" ;;
        vless-ws)                   echo "vless-ws" ;;
        vless-grpc|grpc)            echo "vless-grpc" ;;
        vmess-ws|vmess)             echo "vmess-ws" ;;
        trojan)                     echo "trojan" ;;
        shadowsocks|ss)             echo "shadowsocks" ;;
        shadowtls|stls)             echo "shadowtls" ;;
        hysteria2|hy2|hysteria)     echo "hysteria2" ;;
        tuic)                       echo "tuic" ;;
        anytls)                     echo "anytls" ;;
        *) err "未知协议: $input"; return 1 ;;
    esac
}

_list_known_protocols() {
    echo "可用协议: vless-reality, vless-ws, vless-grpc, vmess-ws, trojan, shadowsocks, shadowtls, hysteria2, tuic, anytls"
}

cmd_install() {
    if [[ $# -eq 0 ]]; then
        _list_known_protocols
        return 1
    fi
    local proto
    proto=$(_resolve_protocol "$1") || return 1
    install_protocol "$proto"
}

cmd_restart() {
    local target="${1:-}"
    if [[ -z "$target" ]]; then
        err "用法: easysingbox restart <协议|all>"
        return 1
    fi
    if [[ "$target" == "all" ]]; then
        local protocols
        protocols=$(jq -r '.protocols | keys[]' "$STATE_FILE" 2>/dev/null)
        while IFS= read -r proto; do
            [[ -z "$proto" ]] && continue
            info "重启 $proto ..."
            restart_service "$proto" && ok "$proto 已重启" || err "$proto 重启失败"
        done <<< "$protocols"
    else
        local proto
        proto=$(_resolve_protocol "$target") || return 1
        restart_service "$proto" && ok "$proto 已重启" || err "$proto 重启失败"
    fi
}

cmd_stop() {
    local target="${1:-}"
    if [[ -z "$target" ]]; then
        err "用法: easysingbox stop <协议|all>"
        return 1
    fi
    if [[ "$target" == "all" ]]; then
        local protocols
        protocols=$(jq -r '.protocols | keys[]' "$STATE_FILE" 2>/dev/null)
        while IFS= read -r proto; do
            [[ -z "$proto" ]] && continue
            stop_service "$proto" && ok "$proto 已停止" || err "$proto 停止失败"
        done <<< "$protocols"
    else
        local proto
        proto=$(_resolve_protocol "$target") || return 1
        stop_service "$proto" && ok "$proto 已停止" || err "$proto 停止失败"
    fi
}

cmd_start() {
    local target="${1:-}"
    if [[ -z "$target" ]]; then
        err "用法: easysingbox start <协议|all>"
        return 1
    fi
    if [[ "$target" == "all" ]]; then
        local protocols
        protocols=$(jq -r '.protocols | keys[]' "$STATE_FILE" 2>/dev/null)
        while IFS= read -r proto; do
            [[ -z "$proto" ]] && continue
            start_service "$proto" && ok "$proto 已启动" || err "$proto 启动失败"
        done <<< "$protocols"
    else
        local proto
        proto=$(_resolve_protocol "$target") || return 1
        start_service "$proto" && ok "$proto 已启动" || err "$proto 启动失败"
    fi
}

cmd_user() {
    local action="${1:-}"
    shift 2>/dev/null || true
    case "$action" in
        add)
            local username="${1:-}"
            [[ -z "$username" ]] && { err "用法: easysingbox user add <用户名>"; return 1; }
            add_user "$username"
            ;;
        del|delete|rm)
            local username="${1:-}"
            [[ -z "$username" ]] && { err "用法: easysingbox user del <用户名>"; return 1; }
            remove_user "$username"
            ;;
        list|ls)
            list_users
            ;;
        *)
            echo "用法: easysingbox user <add|del|list> [用户名]"
            return 1
            ;;
    esac
}

cmd_share() {
    local username="${1:-}"
    local proto_filter="${2:-}"

    if [[ -z "$username" ]]; then
        err "用法: easysingbox share <用户名> [协议]"
        return 1
    fi

    if [[ ! -f "$USERS_FILE" ]]; then
        err "用户文件不存在"
        return 1
    fi

    local user_exists
    user_exists=$(jq -e --arg u "$username" '.users[] | select(.username == $u)' "$USERS_FILE" 2>/dev/null)
    if [[ -z "$user_exists" ]]; then
        err "用户 $username 不存在"
        return 1
    fi

    local protocols
    if [[ -n "$proto_filter" ]]; then
        proto_filter=$(_resolve_protocol "$proto_filter") || return 1
        protocols="$proto_filter"
    else
        protocols=$(jq -r '.protocols | keys[]' "$STATE_FILE" 2>/dev/null)
    fi

    while IFS= read -r proto; do
        [[ -z "$proto" ]] && continue
        echo -e "${BOLD}── $proto ──${NC}"
        generate_share_link "$proto" "$username" 2>/dev/null || echo "  (无分享链接)"
        echo ""
    done <<< "$protocols"
}

cmd_traffic() {
    local username="${1:-}"
    if [[ -n "$username" ]]; then
        # Show traffic for specific user
        if [[ ! -f "$USERS_FILE" ]]; then
            err "用户文件不存在"
            return 1
        fi
        local user_data
        user_data=$(jq --arg u "$username" '.users[] | select(.username == $u)' "$USERS_FILE" 2>/dev/null)
        if [[ -z "$user_data" ]]; then
            err "用户 $username 不存在"
            return 1
        fi
        echo -e "${BOLD}用户: $username${NC}"
        local up down total limit
        up=$(echo "$user_data" | jq -r '.traffic.up // 0')
        down=$(echo "$user_data" | jq -r '.traffic.down // 0')
        total=$((up + down))
        limit=$(echo "$user_data" | jq -r '.traffic.limit // 0')
        echo "  上传: $(format_bytes "$up")"
        echo "  下载: $(format_bytes "$down")"
        echo "  总计: $(format_bytes "$total")"
        if [[ "$limit" -gt 0 ]]; then
            echo "  限额: $(format_bytes "$limit")"
        else
            echo "  限额: 无限制"
        fi
    else
        show_monthly_traffic "$(date +%Y-%m)"
    fi
}

# ─── Entry ───────────────────────────────────────────────────────────────

main() {
    # Command-line flags and subcommands
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
            echo "用法: easysingbox [命令] [参数]"
            echo ""
            echo "命令:"
            echo "  install <协议> [--domain <域名>]  安装协议"
            echo "  user add <用户名> [--protocols <协议,协议>]"
            echo "  user del <用户名>                 删除用户"
            echo "  user list                         查看用户列表"
            echo "  restart <协议|all>                重启服务"
            echo "  stop <协议|all>                   停止服务"
            echo "  start <协议|all>                  启动服务"
            echo "  share <用户名> [协议]             查看分享链接"
            echo "  traffic [用户名]                  查看流量统计"
            echo ""
            echo "选项:"
            echo "  --help, -h              显示帮助信息"
            echo "  --version, -v           显示版本号"
            echo "  --status                显示所有协议状态"
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
        install|user|restart|stop|start|share|traffic)
            if [[ $EUID -ne 0 ]]; then
                echo "请使用 root 用户运行此脚本"
                exit 1
            fi
            mkdir -p "$CONFIG_DIR" "$TLS_DIR" "$SERVICE_DIR" "$MONTHLY_DIR"
            local cmd="$1"
            shift
            "cmd_${cmd}" "$@"
            exit $?
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
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

print_main_menu() {
    clear
    echo -e "${BOLD}EasySingBox v${VERSION}${NC}"

    # Status summary
    local proto_count=0 running_count=0 error_count=0
    local user_count=0 blocked_count=0
    local month_up=0 month_down=0

    if [[ -f "$STATE_FILE" ]]; then
        local protocols
        protocols=$(jq -r '.protocols | keys[]' "$STATE_FILE" 2>/dev/null)
        while IFS= read -r proto; do
            [[ -z "$proto" ]] && continue
            proto_count=$((proto_count + 1))
            local svc_status
            svc_status=$(get_real_status "$proto")
            case "$svc_status" in
                运行中) running_count=$((running_count + 1)) ;;
                异常)   error_count=$((error_count + 1)) ;;
            esac
        done <<< "$protocols"
    fi
    if [[ -f "$USERS_FILE" ]]; then
        user_count=$(jq '.users | length' "$USERS_FILE" 2>/dev/null || echo 0)
        blocked_count=$(jq '[.users[] | select(.blocked_at != null and .blocked_at != "null")] | length' "$USERS_FILE" 2>/dev/null || echo 0)
    fi
    local month
    month=$(date +%Y-%m)
    if [[ -f "${MONTHLY_DIR}/${month}.json" ]]; then
        month_up=$(jq '[.users[].up // 0] | add // 0' "${MONTHLY_DIR}/${month}.json" 2>/dev/null || echo 0)
        month_down=$(jq '[.users[].down // 0] | add // 0' "${MONTHLY_DIR}/${month}.json" 2>/dev/null || echo 0)
    fi

    echo -e "${DIM}──────────────────────────────────────${NC}"
    local status_line=" 协议: ${GREEN}${running_count} 运行${NC}"
    [[ $error_count -gt 0 ]] && status_line+=" / ${RED}${error_count} 异常${NC}"
    [[ $((proto_count - running_count - error_count)) -gt 0 ]] && status_line+=" / ${YELLOW}$((proto_count - running_count - error_count)) 停止${NC}"
    status_line+="    用户: ${BOLD}${user_count}${NC}"
    [[ $blocked_count -gt 0 ]] && status_line+=" (${RED}${blocked_count} 封禁${NC})"
    echo -e "$status_line"
    if [[ $proto_count -gt 0 ]]; then
        echo -e " 本月: ${CYAN}↑$(format_bytes "$month_up")  ↓$(format_bytes "$month_down")${NC}"
    fi
    echo -e "${DIM}──────────────────────────────────────${NC}"

    echo ""
    echo -e "  ${BOLD}1.${NC} 安装协议        ${BOLD}4.${NC} 流量统计"
    echo -e "  ${BOLD}2.${NC} 服务状况        ${BOLD}5.${NC} 系统管理"
    echo -e "  ${BOLD}3.${NC} 用户管理        ${BOLD}0.${NC} 退出"
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
    echo -e "${BOLD}┌────────── 安装协议 ──────────┐${NC}"
    echo ""
    local protos=(vless-reality vless-ws vless-grpc vmess-ws trojan shadowsocks shadowtls hysteria2 tuic anytls)
    local labels=(
        "VLESS + Reality     (无需域名)"
        "VLESS + WS + TLS    (需域名+证书)"
        "VLESS + gRPC + TLS  (需域名+证书)"
        "VMess + WS + TLS    (需域名+证书)"
        "Trojan + TLS        (需域名+证书)"
        "Shadowsocks         (无需域名)"
        "ShadowTLS + SS      (需域名+证书)"
        "Hysteria 2          (需域名+证书)"
        "TUIC v5             (需域名+证书)"
        "AnyTLS              (需域名+证书)"
    )
    for i in "${!protos[@]}"; do
        local idx=$((i + 1))
        local mark=""
        if is_protocol_installed "${protos[$i]}"; then
            mark=" ${GREEN}✓ 已安装${NC}"
        fi
        printf "  %2d.  %s%b\n" "$idx" "${labels[$i]}" "$mark"
    done
    echo ""
    echo "  0.  返回主菜单"
    echo -e "${BOLD}└───────────────────────────────────┘${NC}"
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
            pause_continue
            return
        fi

        local protocols
        protocols=$(jq -r '.protocols | keys[]' "$STATE_FILE" 2>/dev/null)
        if [[ -z "$protocols" ]]; then
            echo "尚未安装任何协议"
            pause_continue
            return
        fi

        local singbox_version
        singbox_version=$(jq -r '.version // "unknown"' "$STATE_FILE")

        echo -e "${BOLD}=== 服务状况 (sing-box $singbox_version) ===${NC}"
        echo ""
        printf " %-3s %-18s %-6s %-10s %s\n" "#" "协议" "端口" "状态" "域名"
        printf " %-3s %-18s %-6s %-10s %s\n" "---" "----" "----" "----" "----"
        local i=1
        while IFS= read -r proto; do
            local port domain real_status status_colored
            port=$(jq -r ".protocols[\"$proto\"].port // \"-\"" "$STATE_FILE")
            domain=$(jq -r ".protocols[\"$proto\"].domain // \"-\"" "$STATE_FILE")
            real_status=$(get_real_status "$proto")
            status_colored=$(color_status "$real_status")
            printf " %-3s %-18s %-6s " "$i" "$proto" "$port"
            echo -e "${status_colored}\t${domain}"
            i=$((i + 1))
        done <<< "$protocols"
        echo ""
        echo -e "${DIM}操作: [编号] 详情  r[编号] 重启  s[编号] 启停  0 返回${NC}"
        read -rp "选择: " choice

        choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
        [[ "$choice" == "0" || -z "$choice" ]] && return

        # Parse action prefix
        local action="detail" num=""
        if [[ "$choice" =~ ^r([0-9]+)$ ]]; then
            action="restart"
            num="${BASH_REMATCH[1]}"
        elif [[ "$choice" =~ ^s([0-9]+)$ ]]; then
            action="toggle"
            num="${BASH_REMATCH[1]}"
        elif [[ "$choice" =~ ^[0-9]+$ ]]; then
            action="detail"
            num="$choice"
        else
            warn "无效输入"
            sleep 1
            continue
        fi

        local protocol
        protocol=$(echo "$protocols" | sed -n "${num}p")
        if [[ -z "$protocol" ]]; then
            warn "无效编号"
            sleep 1
            continue
        fi

        case "$action" in
            restart)
                restart_service "$protocol"
                ok "已重启 $protocol"
                sleep 1
                ;;
            toggle)
                if systemctl is-active --quiet "$(get_service_name "$protocol")"; then
                    stop_service "$protocol"
                    ok "已停止 $protocol"
                else
                    start_service "$protocol"
                    ok "已启动 $protocol"
                fi
                sleep 1
                ;;
            detail)
                protocol_action_menu "$protocol"
                ;;
        esac
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
        echo -e "${BOLD}┌────────── 用户管理 ──────────┐${NC}"
        echo ""

        # Show user list inline
        init_users
        local count
        count=$(jq '.users | length' "$USERS_FILE" 2>/dev/null || echo 0)

        if [[ "$count" -gt 0 ]]; then
            local i=1
            jq -r '.users[] | "\(.name)|\(.enabled)|\(.protocols | join(","))|\(.traffic_used_monthly)|\(.traffic_limit_monthly)|\(.blocked_at)"' "$USERS_FILE" 2>/dev/null | \
            while IFS='|' read -r name enabled protos used_month limit_month blocked; do
                local status_icon="${GREEN}●${NC}"
                [[ "$enabled" == "false" ]] && status_icon="${YELLOW}○${NC}"
                [[ -n "$blocked" && "$blocked" != "null" ]] && status_icon="${RED}✗${NC}"

                local traffic_str
                traffic_str=$(format_bytes "$used_month")
                if [[ "$limit_month" != "0" ]]; then
                    traffic_str+="/$(format_bytes "$limit_month")"
                fi

                printf "  %b %2d. %-12s %-25s %s\n" "$status_icon" "$i" "$name" "$protos" "$traffic_str"
                i=$((i + 1))
            done
            echo ""
        else
            echo -e "  ${DIM}暂无用户${NC}"
            echo ""
        fi

        echo -e "${DIM}操作: a 添加  d[编号] 删除  t[编号] 启禁  r[编号] 重置流量  l[编号] 设限额  0 返回${NC}"
        echo -e "${BOLD}└───────────────────────────────────┘${NC}"
        echo ""
        read -rp "选择: " choice

        choice=$(echo "$choice" | tr '[:upper:]' '[:lower:]' | tr -d ' ')

        case "$choice" in
            0|"") return ;;
            a) add_user ; pause_continue ;;
            d[0-9]*)
                local idx="${choice#d}"
                _quick_remove_user "$idx"
                pause_continue
                ;;
            t[0-9]*)
                local idx="${choice#t}"
                _quick_toggle_user "$idx"
                sleep 1
                ;;
            r[0-9]*)
                local idx="${choice#r}"
                _quick_reset_traffic "$idx"
                sleep 1
                ;;
            l[0-9]*)
                local idx="${choice#l}"
                _quick_set_limit "$idx"
                pause_continue
                ;;
            *)
                # Legacy number-based navigation
                if [[ "$choice" =~ ^[0-9]+$ ]]; then
                    add_user ; pause_continue
                else
                    warn "无效输入"
                    sleep 1
                fi
                ;;
        esac
    done
}

# Quick user operations by index
_get_username_by_idx() {
    local idx="$1"
    jq -r ".users[$((idx - 1))].name // empty" "$USERS_FILE" 2>/dev/null
}

_quick_remove_user() {
    local idx="$1"
    local username
    username=$(_get_username_by_idx "$idx")
    if [[ -z "$username" ]]; then
        warn "无效编号"
        return
    fi
    echo -e "确定删除用户 ${BOLD}$username${NC}？[y/N]"
    read -rp "" confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return

    local protos
    protos=$(jq -r --arg name "$username" '.users[] | select(.name == $name) | .protocols[]' "$USERS_FILE")

    jq --arg name "$username" 'del(.users[] | select(.name == $name))' \
        "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

    local month
    month=$(date +%Y-%m)
    if [[ -f "${MONTHLY_DIR}/${month}.json" ]]; then
        jq --arg name "$username" 'del(.users[$name])' "${MONTHLY_DIR}/${month}.json" > "${MONTHLY_DIR}/${month}.json.tmp" && \
            mv "${MONTHLY_DIR}/${month}.json.tmp" "${MONTHLY_DIR}/${month}.json"
    fi

    for proto in $protos; do
        rebuild_protocol_config "$proto"
    done

    ok "用户 $username 已删除"
}

_quick_toggle_user() {
    local idx="$1"
    local username
    username=$(_get_username_by_idx "$idx")
    if [[ -z "$username" ]]; then
        warn "无效编号"
        return
    fi
    local current_enabled
    current_enabled=$(jq -r ".users[$((idx - 1))].enabled" "$USERS_FILE")

    local new_enabled
    if [[ "$current_enabled" == "true" ]]; then
        new_enabled=false
        info "禁用用户 $username"
    else
        new_enabled=true
        info "启用用户 $username"
    fi

    jq --arg name "$username" --argjson enabled "$new_enabled" \
        '(.users[] | select(.name == $name)).enabled = $enabled' \
        "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

    local protos
    protos=$(jq -r --arg name "$username" '.users[] | select(.name == $name) | .protocols[]' "$USERS_FILE")
    for proto in $protos; do
        rebuild_protocol_config "$proto"
    done
}

_quick_reset_traffic() {
    local idx="$1"
    local username
    username=$(_get_username_by_idx "$idx")
    if [[ -z "$username" ]]; then
        warn "无效编号"
        return
    fi

    jq --arg name "$username" \
        '(.users[] | select(.name == $name)) |= (.traffic_used_monthly = 0 | .traffic_used_total = 0 | .blocked_at = null)' \
        "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

    local protos
    protos=$(jq -r --arg name "$username" '.users[] | select(.name == $name) | .protocols[]' "$USERS_FILE")
    for proto in $protos; do
        rebuild_protocol_config "$proto"
    done

    ok "用户 $username 的流量已重置"
}

_quick_set_limit() {
    local idx="$1"
    local username
    username=$(_get_username_by_idx "$idx")
    if [[ -z "$username" ]]; then
        warn "无效编号"
        return
    fi

    local current_limits
    current_limits=$(jq -r --arg name "$username" '.users[] | select(.name == $name) | "月度=\(.traffic_limit_monthly) 总=\(.traffic_limit_total)"' "$USERS_FILE")
    echo "用户: $username  当前限额: $current_limits"
    echo "  注: 1 GB = 1024 MB (二进制单位)"

    local monthly_limit total_limit
    read -rp "月度流量限额 (GB, 0 = 不限制): " monthly_input
    monthly_input="${monthly_input:-0}"
    if [[ "$monthly_input" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        monthly_limit=$(awk -v val="$monthly_input" 'BEGIN {printf "%.0f", val * 1073741824}')
    else
        monthly_limit=0
    fi

    read -rp "总流量限额 (GB, 0 = 不限制): " total_input
    total_input="${total_input:-0}"
    if [[ "$total_input" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        total_limit=$(awk -v val="$total_input" 'BEGIN {printf "%.0f", val * 1073741824}')
    else
        total_limit=0
    fi

    jq --arg name "$username" --argjson ml "$monthly_limit" --argjson tl "$total_limit" \
        '(.users[] | select(.name == $name)) |= (.traffic_limit_monthly = $ml | .traffic_limit_total = $tl)' \
        "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

    ok "用户 $username 的流量限额已更新"
}

# ─── Traffic Management Menu ─────────────────────────────────────

menu_traffic_management() {
    while true; do
        clear
        echo -e "${BOLD}┌────────── 流量统计 ──────────┐${NC}"
        echo ""
        echo "  1.  本月流量"
        echo "  2.  累计总流量"
        echo "  3.  历史月份"
        echo ""
        echo "  0.  返回主菜单"
        echo -e "${BOLD}└───────────────────────────────────┘${NC}"
        echo ""
        read -rp "请选择 [0-3]: " choice
        echo ""

        case "$choice" in
            1) show_monthly_traffic "$(date +%Y-%m)" ; pause_continue ;;
            2) show_total_traffic ; pause_continue ;;
            3) show_history_months ; pause_continue ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
        esac
    done
}

# ─── System Management Menu ──────────────────────────────────────────────

menu_system_management() {
    while true; do
        clear
        echo -e "${BOLD}┌────────── 系统管理 ──────────┐${NC}"
        echo ""
        echo "  1.  更新脚本"
        echo "  2.  升级 sing-box"
        echo -e "  3.  ${RED}彻底卸载所有服务并删除脚本${NC}"
        echo ""
        echo "  0.  返回主菜单"
        echo -e "${BOLD}└───────────────────────────────────┘${NC}"
        echo ""
        read -rp "请选择 [0-3]: " choice
        echo ""

        case "$choice" in
            1) update_self ; pause_continue ;;
            2) upgrade_singbox_menu ; pause_continue ;;
            3) uninstall_all ;;
            0) return ;;
            *) warn "无效选项"; sleep 1 ;;
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
        pause_continue
        return
    fi

    local singbox_version
    singbox_version=$(jq -r '.version // "unknown"' "$STATE_FILE")
    echo ""
    echo -e "${BOLD}=== 协议状态 (sing-box $singbox_version) ===${NC}"
    printf "%-20s %-8s %-10s %-10s\n" "协议" "端口" "状态" "域名"
    printf "%-20s %-8s %-10s %-10s\n" "----" "----" "----" "----"

    local protocols
    protocols=$(jq -r '.protocols | keys[]' "$STATE_FILE" 2>/dev/null)
    while IFS= read -r proto; do
        local port domain real_status status_colored
        port=$(jq -r ".protocols[\"$proto\"].port // \"-\"" "$STATE_FILE")
        domain=$(jq -r ".protocols[\"$proto\"].domain // \"-\"" "$STATE_FILE")
        real_status=$(get_real_status "$proto")
        status_colored=$(color_status "$real_status")
        printf "%-20s %-8s " "$proto" "$port"
        echo -e "${status_colored}\t${domain}"
    done <<< "$protocols"
    echo ""
    pause_continue
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
