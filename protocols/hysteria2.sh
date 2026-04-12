#!/usr/bin/env bash
# protocols/hysteria2.sh

prompt_hysteria2() {
    read -rp "请输入域名: " HY2_DOMAIN
    while ! validate_domain "$HY2_DOMAIN"; do
        read -rp "域名格式无效，请重新输入: " HY2_DOMAIN
    done

    ensure_certificate "$HY2_DOMAIN" || return 1

    local port
    port=$(prompt_port "443")
    eval "HY2_PORT=$port"

    # Warn about UDP
    echo ""
    echo "注意: Hysteria 2 使用 QUIC (UDP) 协议"
    echo "如果服务器有 UDP 防火墙，可能无法正常连接"
}

install_hysteria2() {
    prompt_hysteria2 || return 1

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

    write_service "hysteria2"
    start_service "hysteria2"
    wait_service_start "hysteria2" 10
    set_protocol_state "hysteria2" "$HY2_PORT" "running" "$HY2_DOMAIN"

    init_users
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jq ".users += [{
        name: \"default\", uuid: null, password: \"$password\",
        protocols: [\"hysteria2\"], enabled: true, created_at: \"$now\",
        traffic_limit_monthly: 0, traffic_limit_total: 0,
        traffic_used_monthly: 0, traffic_used_total: 0,
        monthly_reset_day: 1, blocked_at: null
    }]" "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

    generate_share_link "hysteria2" "default"
    setup_traffic_cron

    echo ""
    echo "=== Hysteria 2 安装成功 ==="
    echo "域名: $HY2_DOMAIN"
    echo "端口: $HY2_PORT"
    echo "密码: $password"
    echo ""
    cat "${CONFIG_DIR}/hysteria2/share-link/default.txt" 2>/dev/null
}
