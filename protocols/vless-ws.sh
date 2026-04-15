#!/usr/bin/env bash
# protocols/vless-ws.sh

prompt_vless_ws() {
    prompt_domain VLESS_WS_DOMAIN "vless-ws"

    ensure_certificate "$VLESS_WS_DOMAIN" || return 1

    local port
    port=$(prompt_port "443")
    VLESS_WS_PORT=$port

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

    local api_secret
    api_secret=$(gen_api_secret)

    local listen_addr
    listen_addr=$(get_listen_address)

    jq -n \
        --argjson port "$VLESS_WS_PORT" \
        --arg domain "$VLESS_WS_DOMAIN" \
        --arg path "$VLESS_WS_PATH" \
        --arg cert "${TLS_DIR}/${VLESS_WS_DOMAIN}.crt" \
        --arg key "${TLS_DIR}/${VLESS_WS_DOMAIN}.key" \
        --argjson users "[$default_user]" \
        --argjson api_port "$api_port" \
        --arg api_secret "$api_secret" \
        --arg listen_addr "$listen_addr" \
        '{
            log: { level: "info", timestamp: true },
            inbounds: [{
                type: "vless",
                tag: "vless-ws",
                listen: $listen_addr,
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
                    secret: $api_secret
                }
            }
        }' > "$config_file"

    write_service "vless-ws"
    start_service "vless-ws"
    if ! wait_service_start "vless-ws" 10; then
        echo "警告: VLESS WS 服务启动失败，请使用 journalctl -u singbox-vless-ws -n 50 查看日志"
    fi
    set_protocol_state "vless-ws" "$VLESS_WS_PORT" "running" "$VLESS_WS_DOMAIN"

    read -rp "请输入默认用户名 (留空为 default): " default_username
    [[ -z "$default_username" ]] && default_username="default"

    ensure_default_user "vless-ws" "$uuid" "" "$default_username"

    generate_share_link "vless-ws" "$default_username"
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
    cat "${CONFIG_DIR}/vless-ws/share-link/${default_username}.txt" 2>/dev/null
}
