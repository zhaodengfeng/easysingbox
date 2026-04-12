#!/usr/bin/env bash
# protocols/vless-ws.sh

prompt_vless_ws() {
    read -rp "请输入域名: " VLESS_WS_DOMAIN
    while ! validate_domain "$VLESS_WS_DOMAIN"; do
        read -rp "域名格式无效，请重新输入: " VLESS_WS_DOMAIN
    done

    ensure_certificate "$VLESS_WS_DOMAIN" || return 1

    local port
    port=$(prompt_port "443")
    eval "VLESS_WS_PORT=$port"

    read -rp "WebSocket 路径 [默认: /ws]: " VLESS_WS_PATH
    VLESS_WS_PATH="${VLESS_WS_PATH:-/ws}"
}

install_vless_ws() {
    prompt_vless_ws || return 1

    local uuid
    uuid=$(gen_uuid)
    local default_user
    default_user=$(jq -n --arg uuid "$uuid" '{uuid: $uuid}')

    local config_file="${CONFIG_DIR}/vless-ws/inbound.json"
    mkdir -p "${CONFIG_DIR}/vless-ws"

    local api_port
    api_port=$(get_api_port "vless-ws")

    jq -n \
        --argjson port "$VLESS_WS_PORT" \
        --arg domain "$VLESS_WS_DOMAIN" \
        --arg path "$VLESS_WS_PATH" \
        --arg cert "${TLS_DIR}/${VLESS_WS_DOMAIN}.crt" \
        --arg key "${TLS_DIR}/${VLESS_WS_DOMAIN}.key" \
        --argjson users "[$default_user]" \
        --argjson api_port "$api_port" \
        '{
            log: { level: "info", timestamp: true },
            inbounds: [{
                type: "vless",
                tag: "vless-ws",
                listen: "::",
                listen_port: $port,
                users: $users,
                tls: {
                    enabled: true,
                    server_name: $domain,
                    certificate_path: $cert,
                    key_path: $key
                },
                transport: {
                    type: "ws",
                    path: $path
                }
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

    write_service "vless-ws"
    start_service "vless-ws"
    wait_service_start "vless-ws" 10
    set_protocol_state "vless-ws" "$VLESS_WS_PORT" "running" "$VLESS_WS_DOMAIN"

    init_users
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jq ".users += [{
        name: \"default\", uuid: \"$uuid\", password: null,
        protocols: [\"vless-ws\"], enabled: true, created_at: \"$now\",
        traffic_limit_monthly: 0, traffic_limit_total: 0,
        traffic_used_monthly: 0, traffic_used_total: 0,
        monthly_reset_day: 1, blocked_at: null
    }]" "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

    generate_share_link "vless-ws" "default"
    setup_traffic_cron

    local server_ip
    server_ip=$(get_server_ip)
    echo ""
    echo "=== VLESS + WebSocket + TLS 安装成功 ==="
    echo "域名: $VLESS_WS_DOMAIN"
    echo "端口: $VLESS_WS_PORT"
    echo "路径: $VLESS_WS_PATH"
    echo "UUID: $uuid"
    echo ""
    cat "${CONFIG_DIR}/vless-ws/share-link/default.txt" 2>/dev/null
}
