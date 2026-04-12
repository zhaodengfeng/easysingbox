#!/usr/bin/env bash
# protocols/tuic.sh

prompt_tuic() {
    read -rp "请输入域名: " TUIC_DOMAIN
    while ! validate_domain "$TUIC_DOMAIN"; do
        read -rp "域名格式无效，请重新输入: " TUIC_DOMAIN
    done

    ensure_certificate "$TUIC_DOMAIN" || return 1

    local port
    port=$(prompt_port "443")
    eval "TUIC_PORT=$port"

    echo ""
    echo "注意: TUIC 使用 QUIC (UDP) 协议"
    echo "如果服务器有 UDP 防火墙，可能无法正常连接"
}

install_tuic() {
    prompt_tuic || return 1

    local uuid password
    uuid=$(gen_uuid)
    password=$(gen_password)
    local default_user
    default_user=$(jq -n --arg uuid "$uuid" --arg pw "$password" '{uuid: $uuid, password: $pw}')

    local config_file="${CONFIG_DIR}/tuic/inbound.json"
    mkdir -p "${CONFIG_DIR}/tuic"

    local api_port
    api_port=$(get_api_port "tuic")

    jq -n \
        --argjson port "$TUIC_PORT" \
        --arg domain "$TUIC_DOMAIN" \
        --arg cert "${TLS_DIR}/${TUIC_DOMAIN}.crt" \
        --arg key "${TLS_DIR}/${TUIC_DOMAIN}.key" \
        --argjson users "[$default_user]" \
        --argjson api_port "$api_port" \
        '{
            log: { level: "info", timestamp: true },
            inbounds: [{
                type: "tuic",
                tag: "tuic",
                listen: "::",
                listen_port: $port,
                users: $users,
                tls: {
                    enabled: true,
                    server_name: $domain,
                    certificate_path: $cert,
                    key_path: $key
                },
                congestion_control: "bbr",
                auth_timeout: "3s"
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

    write_service "tuic"
    start_service "tuic"
    wait_service_start "tuic" 10
    set_protocol_state "tuic" "$TUIC_PORT" "running" "$TUIC_DOMAIN"

    init_users
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jq ".users += [{
        name: \"default\", uuid: \"$uuid\", password: \"$password\",
        protocols: [\"tuic\"], enabled: true, created_at: \"$now\",
        traffic_limit_monthly: 0, traffic_limit_total: 0,
        traffic_used_monthly: 0, traffic_used_total: 0,
        monthly_reset_day: 1, blocked_at: null
    }]" "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

    generate_share_link "tuic" "default"
    setup_traffic_cron

    echo ""
    echo "=== TUIC v5 安装成功 ==="
    echo "域名: $TUIC_DOMAIN"
    echo "端口: $TUIC_PORT"
    echo "UUID: $uuid"
    echo "密码: $password"
    echo ""
    cat "${CONFIG_DIR}/tuic/share-link/default.txt" 2>/dev/null
}
