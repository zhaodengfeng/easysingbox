#!/usr/bin/env bash
# protocols/hysteria2.sh

prompt_hysteria2() {
    read -rp "请输入域名: " HY2_DOMAIN
    while ! validate_domain "$HY2_DOMAIN"; do
        read -rp "域名格式无效，请重新输入: " HY2_DOMAIN
    done

    ensure_certificate "$HY2_DOMAIN" || return 1

    local port
    port=$(prompt_port "8443")
    HY2_PORT=$port

    # Port hopping option
    echo ""
    echo "是否启用端口跳跃（Port Hopping）？"
    echo "端口跳跃可抗封锁，GFW 需扫描大量 UDP 端口才能检测"
    read -rp "启用端口跳跃？[y/N]: " enable_hop
    if [[ "$enable_hop" =~ ^[Yy]$ ]]; then
        echo ""
        echo "提示: 端口跳跃通过 iptables 将指定范围的 UDP 流量转发到监听端口 $port"
        echo "      客户端将在该范围内随机选择端口连接"
        echo ""
        read -rp "跳跃起始端口 [默认: 20000]: " hop_start
        hop_start="${hop_start:-20000}"
        read -rp "跳跃结束端口 [默认: 30000]: " hop_end
        hop_end="${hop_end:-30000}"

        # Validate port range
        if [[ ! "$hop_start" =~ ^[0-9]+$ ]] || [[ ! "$hop_end" =~ ^[0-9]+$ ]] || \
           (( hop_start < 1 || hop_start > 65535 || hop_end < 1 || hop_end > 65535 || hop_start > hop_end )); then
            echo "无效的端口范围，跳过端口跳跃"
            HY2_HOP_ENABLED=false
        else
            HY2_HOP_START=$hop_start
            HY2_HOP_END=$hop_end
            HY2_HOP_ENABLED=true
        fi
    else
        HY2_HOP_ENABLED=false
    fi

    # Warn about UDP
    echo ""
    echo "注意: Hysteria 2 使用 QUIC (UDP) 协议"
    echo "如果服务器有 UDP 防火墙，可能无法正常连接"
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

    jq -n \
        --argjson port "$HY2_PORT" \
        --arg domain "$HY2_DOMAIN" \
        --arg cert "${TLS_DIR}/${HY2_DOMAIN}.crt" \
        --arg key "${TLS_DIR}/${HY2_DOMAIN}.key" \
        --argjson users "[$default_user]" \
        --argjson api_port "$api_port" \
        '{
            log: { level: "info", timestamp: true },
            inbounds: [{
                type: "hysteria2",
                tag: "hysteria2",
                listen: "::",
                listen_port: $port,
                users: $users,
                tls: {
                    enabled: true,
                    server_name: $domain,
                    certificate_path: $cert,
                    key_path: $key
                },
                ignore_client_bandwidth: false,
                up_mbps: 100,
                down_mbps: 100
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
    wait_service_start "hysteria2" 10
    set_protocol_state "hysteria2" "$HY2_PORT" "running" "$HY2_DOMAIN"

    # Store hop config in state.json
    if [[ "$HY2_HOP_ENABLED" == "true" ]]; then
        jq --argjson start "$HY2_HOP_START" --argjson end "$HY2_HOP_END" \
            '.protocols["hysteria2"].hop_start = $start | .protocols["hysteria2"].hop_end = $end' \
            "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi

    ensure_default_user "hysteria2" "" "$password"

    generate_share_link "hysteria2" "default"
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
