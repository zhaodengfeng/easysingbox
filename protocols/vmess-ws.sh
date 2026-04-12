#!/usr/bin/env bash
# protocols/vmess-ws.sh

prompt_vmess_ws() {
    read -rp "请输入域名: " VMESS_WS_DOMAIN
    while ! validate_domain "$VMESS_WS_DOMAIN"; do
        read -rp "域名格式无效，请重新输入: " VMESS_WS_DOMAIN
    done

    ensure_certificate "$VMESS_WS_DOMAIN" || return 1

    local port
    port=$(prompt_port "443")
    VMESS_WS_PORT=$port

    read -rp "WebSocket 路径 [默认: /vmess]: " VMESS_WS_PATH
    VMESS_WS_PATH="${VMESS_WS_PATH:-/vmess}"
}

install_vmess_ws() {
    prompt_vmess_ws || return 1

    local uuid
    uuid=$(gen_uuid)
    local default_user
    default_user=$(jq -n --arg uuid "$uuid" '{uuid: $uuid, alterId: 0}')

    local config_file="${CONFIG_DIR}/vmess-ws/inbound.json"
    mkdir -p "${CONFIG_DIR}/vmess-ws"

    local api_port
    api_port=$(get_api_port "vmess-ws")

    jq -n \
        --argjson port "$VMESS_WS_PORT" \
        --arg domain "$VMESS_WS_DOMAIN" \
        --arg path "$VMESS_WS_PATH" \
        --arg cert "${TLS_DIR}/${VMESS_WS_DOMAIN}.crt" \
        --arg key "${TLS_DIR}/${VMESS_WS_DOMAIN}.key" \
        --argjson users "[$default_user]" \
        --argjson api_port "$api_port" \
        '{
            log: { level: "info", timestamp: true },
            inbounds: [{
                type: "vmess",
                tag: "vmess-ws",
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

    write_service "vmess-ws"
    start_service "vmess-ws"
    wait_service_start "vmess-ws" 10
    set_protocol_state "vmess-ws" "$VMESS_WS_PORT" "running" "$VMESS_WS_DOMAIN"

    ensure_default_user "vmess-ws" "$uuid" ""

    generate_share_link "vmess-ws" "default"
    setup_traffic_cron

    echo ""
    echo "=== VMess + WebSocket + TLS 安装成功 ==="
    echo "域名: $VMESS_WS_DOMAIN"
    echo "端口: $VMESS_WS_PORT"
    echo "路径: $VMESS_WS_PATH"
    echo "UUID: $uuid"
    echo ""
    cat "${CONFIG_DIR}/vmess-ws/share-link/default.txt" 2>/dev/null
}
