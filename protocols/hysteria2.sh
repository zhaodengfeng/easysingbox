#!/usr/bin/env bash
# protocols/hysteria2.sh

prompt_hysteria2() {
    # Accept optional positional params for one-command install
    # $1 domain  $2 port  $3 email  $4 hop (y/N)  $5 hop_start  $6 hop_end
    local input_domain="${1:-}"
    local input_port="${2:-}"
    local input_email="${3:-}"
    local input_hop="${4:-}"

    if [[ -n "$input_domain" ]]; then
        if ! validate_domain "$input_domain"; then
            echo "域名格式无效: $input_domain"
            return 1
        fi
        HY2_DOMAIN="$input_domain"
        HY2_PORT="${input_port:-8443}"
        HY2_EMAIL="$input_email"
    else
        # Menu mode: one-command style, only domain is required
        read -rp "请输入域名: " HY2_DOMAIN
        while ! validate_domain "$HY2_DOMAIN"; do
            read -rp "域名格式无效，请重新输入: " HY2_DOMAIN
        done
        HY2_PORT=8443
        # Check if port is in use, if so pick a random available port
        if ! check_port_available "$HY2_PORT"; then
            local picked
            picked=$(gen_port)
            if [[ -z "$picked" ]]; then
                echo "无可用端口"
                return 1
            fi
            HY2_PORT="$picked"
        fi
        HY2_EMAIL=""
    fi

    ensure_certificate "$HY2_DOMAIN" "$HY2_EMAIL" || return 1

    # Port hopping: default enabled, range 20000-30000
    if [[ -n "$input_hop" ]]; then
        if [[ "$input_hop" =~ ^[Yy]$ ]]; then
            HY2_HOP_START="${5:-20000}"
            HY2_HOP_END="${6:-30000}"
            HY2_HOP_ENABLED=true
        else
            HY2_HOP_ENABLED=false
        fi
    else
        HY2_HOP_ENABLED=true
        HY2_HOP_START=20000
        HY2_HOP_END=30000
    fi

    # Validate port range if hopping enabled
    if [[ "$HY2_HOP_ENABLED" == "true" ]]; then
        if [[ ! "$HY2_HOP_START" =~ ^[0-9]+$ ]] || [[ ! "$HY2_HOP_END" =~ ^[0-9]+$ ]] || \
           (( HY2_HOP_START < 1 || HY2_HOP_START > 65535 || HY2_HOP_END < 1 || HY2_HOP_END > 65535 || HY2_HOP_START > HY2_HOP_END )); then
            echo "无效的端口范围，跳过端口跳跃"
            HY2_HOP_ENABLED=false
        fi
    fi
}

# Setup iptables rules for port hopping
setup_port_hopping() {
    local port="$1"
    local start="$2"
    local end="$3"

    # Detect network interface
    local iface
    iface=$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [[ -z "$iface" ]]; then
        iface=$(ip link show 2>/dev/null | awk -F: '/state UP/ {print $2; exit}' | tr -d ' ')
    fi

    echo "正在配置端口跳跃规则 (iptables) ..."

    # Remove existing rules for this port (idempotent)
    iptables -t nat -D PREROUTING -i "${iface}" -p udp --dport "${start}:${end}" -j REDIRECT --to-port "${port}" 2>/dev/null || true
    ip6tables -t nat -D PREROUTING -i "${iface}" -p udp --dport "${start}:${end}" -j REDIRECT --to-port "${port}" 2>/dev/null || true

    # Add new rules
    if [[ -n "$iface" ]]; then
        iptables -t nat -A PREROUTING -i "${iface}" -p udp --dport "${start}:${end}" -j REDIRECT --to-port "${port}"
        ip6tables -t nat -A PREROUTING -i "${iface}" -p udp --dport "${start}:${end}" -j REDIRECT --to-port "${port}" 2>/dev/null || true
    else
        # Fallback: no interface restriction
        iptables -t nat -A PREROUTING -p udp --dport "${start}:${end}" -j REDIRECT --to-port "${port}"
        ip6tables -t nat -A PREROUTING -p udp --dport "${start}:${end}" -j REDIRECT --to-port "${port}" 2>/dev/null || true
    fi

    # Persist rules
    if command -v iptables-save &>/dev/null && command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save 2>/dev/null || true
    elif command -v iptables-save &>/dev/null; then
        iptables-save > /etc/iptables.rules 2>/dev/null || true
    fi

    echo "端口跳跃规则已添加: UDP ${start}:${end} → ${port}"
}

# Remove port hopping iptables rules
remove_port_hopping() {
    local port="$1"
    local start="$2"
    local end="$3"

    local iface
    iface=$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    if [[ -z "$iface" ]]; then
        iface=$(ip link show 2>/dev/null | awk -F: '/state UP/ {print $2; exit}' | tr -d ' ')
    fi

    if [[ -n "$iface" ]]; then
        iptables -t nat -D PREROUTING -i "${iface}" -p udp --dport "${start}:${end}" -j REDIRECT --to-port "${port}" 2>/dev/null || true
    else
        iptables -t nat -D PREROUTING -p udp --dport "${start}:${end}" -j REDIRECT --to-port "${port}" 2>/dev/null || true
    fi
}

install_hysteria2() {
    prompt_hysteria2 || return 1

    # Clean up old port hopping rules if reinstalling
    local old_hp_start old_hp_end old_hp_port
    old_hp_start=$(jq -r '.protocols["hysteria2"].hop_start // empty' "$STATE_FILE" 2>/dev/null)
    old_hp_end=$(jq -r '.protocols["hysteria2"].hop_end // empty' "$STATE_FILE" 2>/dev/null)
    old_hp_port=$(jq -r '.protocols["hysteria2"].port // empty' "$STATE_FILE" 2>/dev/null)
    if [[ -n "$old_hp_start" ]] && [[ -n "$old_hp_end" ]] && [[ -n "$old_hp_port" ]]; then
        remove_port_hopping "$old_hp_port" "$old_hp_start" "$old_hp_end"
    fi

    local password
    password=$(gen_password)
    local default_user
    default_user=$(jq -n --arg pw "$password" '{name: "default", password: $pw}')

    local config_file="${CONFIG_DIR}/hysteria2/inbound.json"
    mkdir -p "${CONFIG_DIR}/hysteria2"

    local api_port
    api_port=$(get_api_port "hysteria2")

    local listen_addr
    listen_addr=$(get_listen_address)

    jq -n \
        --argjson port "$HY2_PORT" \
        --arg domain "$HY2_DOMAIN" \
        --arg cert "${TLS_DIR}/${HY2_DOMAIN}.crt" \
        --arg key "${TLS_DIR}/${HY2_DOMAIN}.key" \
        --argjson users "[$default_user]" \
        --argjson api_port "$api_port" \
        --arg listen_addr "$listen_addr" \
        '{
            log: { level: "info", timestamp: true },
            inbounds: [{
                type: "hysteria2",
                tag: "hysteria2",
                listen: $listen_addr,
                listen_port: $port,
                users: $users,
                tls: {
                    enabled: true,
                    server_name: $domain,
                    certificate_path: $cert,
                    key_path: $key
                },
                ignore_client_bandwidth: true
            }],
            outbounds: [{ type: "direct", tag: "direct" }],
            experimental: {
                clash_api: {
                    external_controller: ("127.0.0.1:" + ($api_port | tostring)),
                    external_ui: "",
                    secret: ""
                }
            }
        }' > "$config_file"

    # Setup port hopping if enabled
    if [[ "$HY2_HOP_ENABLED" == "true" ]]; then
        setup_port_hopping "$HY2_PORT" "$HY2_HOP_START" "$HY2_HOP_END"
    fi

    write_service "hysteria2"
    start_service "hysteria2"
    if ! wait_service_start "hysteria2" 10; then
        echo "警告: Hysteria 2 服务启动失败，请使用 journalctl -u singbox-hysteria2 -n 50 查看日志"
    fi
    set_protocol_state "hysteria2" "$HY2_PORT" "running" "$HY2_DOMAIN"

    # Store hop config in state.json
    if [[ "$HY2_HOP_ENABLED" == "true" ]]; then
        jq --argjson start "$HY2_HOP_START" --argjson end "$HY2_HOP_END" \
            '.protocols["hysteria2"].hop_start = $start | .protocols["hysteria2"].hop_end = $end' \
            "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi

    read -rp "请输入默认用户名 (留空为 default): " default_username
    [[ -z "$default_username" ]] && default_username="default"

    ensure_default_user "hysteria2" "" "$password" "$default_username"

    if [[ "$(check_service_status "hysteria2")" != "active" ]]; then
        echo "警告: Hysteria 2 服务当前未运行，请使用 journalctl -u singbox-hysteria2 -n 50 查看日志"
    fi

    generate_share_link "hysteria2" "$default_username"
    setup_traffic_cron

    echo ""
    echo "=== Hysteria 2 安装成功 ==="
    echo "域名: $HY2_DOMAIN"
    echo "端口: $HY2_PORT"
    echo "密码: $password"
    if [[ "$HY2_HOP_ENABLED" == "true" ]]; then
        echo "端口跳跃: ${HY2_HOP_START}-${HY2_HOP_END}"
    fi
    echo ""
    cat "${CONFIG_DIR}/hysteria2/share-link/default.txt" 2>/dev/null
}
