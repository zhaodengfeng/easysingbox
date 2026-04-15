#!/usr/bin/env bash
# protocols/vless-grpc.sh

prompt_vless_grpc() {
    prompt_domain VLESS_GRPC_DOMAIN "vless-grpc"

    ensure_certificate "$VLESS_GRPC_DOMAIN" || return 1

    local port
    port=$(prompt_port "443")
    VLESS_GRPC_PORT=$port

    read -rp "gRPC 服务名 [默认: grpc]: " VLESS_GRPC_SERVICE
    VLESS_GRPC_SERVICE="${VLESS_GRPC_SERVICE:-grpc}"
}

install_vless_grpc() {
    prompt_vless_grpc || return 1

    local uuid
    uuid=$(gen_uuid)
    local default_user
    default_user=$(jq -n --arg uuid "$uuid" '{uuid: $uuid}')

    local config_file="${CONFIG_DIR}/vless-grpc/inbound.json"
    mkdir -p "${CONFIG_DIR}/vless-grpc"

    local api_port
    api_port=$(get_api_port "vless-grpc")

    local api_secret
    api_secret=$(gen_api_secret)

    local listen_addr
    listen_addr=$(get_listen_address)

    jq -n \
        --argjson port "$VLESS_GRPC_PORT" \
        --arg domain "$VLESS_GRPC_DOMAIN" \
        --arg service_name "$VLESS_GRPC_SERVICE" \
        --arg cert "${TLS_DIR}/${VLESS_GRPC_DOMAIN}.crt" \
        --arg key "${TLS_DIR}/${VLESS_GRPC_DOMAIN}.key" \
        --argjson users "[$default_user]" \
        --argjson api_port "$api_port" \
        --arg api_secret "$api_secret" \
        --arg listen_addr "$listen_addr" \
        '{
            log: { level: "info", timestamp: true },
            inbounds: [{
                type: "vless",
                tag: "vless-grpc",
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
                    type: "grpc",
                    service_name: $service_name
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

    write_service "vless-grpc"
    start_service "vless-grpc"
    if ! wait_service_start "vless-grpc" 10; then
        echo "警告: VLESS gRPC 服务启动失败，请使用 journalctl -u singbox-vless-grpc -n 50 查看日志"
    fi
    set_protocol_state "vless-grpc" "$VLESS_GRPC_PORT" "running" "$VLESS_GRPC_DOMAIN"

    read -rp "请输入默认用户名 (留空为 default): " default_username
    [[ -z "$default_username" ]] && default_username="default"

    ensure_default_user "vless-grpc" "$uuid" "" "$default_username"

    generate_share_link "vless-grpc" "$default_username"
    setup_traffic_cron

    echo ""
    echo "=== VLESS + gRPC + TLS 安装成功 ==="
    echo "域名: $VLESS_GRPC_DOMAIN"
    echo "端口: $VLESS_GRPC_PORT"
    echo "gRPC 服务: $VLESS_GRPC_SERVICE"
    echo "UUID: $uuid"
    echo ""
    cat "${CONFIG_DIR}/vless-grpc/share-link/${default_username}.txt" 2>/dev/null
}
