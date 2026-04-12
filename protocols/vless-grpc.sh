#!/usr/bin/env bash
# protocols/vless-grpc.sh

prompt_vless_grpc() {
    read -rp "请输入域名: " VLESS_GRPC_DOMAIN
    while ! validate_domain "$VLESS_GRPC_DOMAIN"; do
        read -rp "域名格式无效，请重新输入: " VLESS_GRPC_DOMAIN
    done

    ensure_certificate "$VLESS_GRPC_DOMAIN" || return 1

    local port
    port=$(prompt_port "443")
    eval "VLESS_GRPC_PORT=$port"

    read -rp "gRPC 服务名 [默认: /grpc]: " VLESS_GRPC_SERVICE
    VLESS_GRPC_SERVICE="${VLESS_GRPC_SERVICE:-/grpc}"
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

    jq -n \
        --argjson port "$VLESS_GRPC_PORT" \
        --arg domain "$VLESS_GRPC_DOMAIN" \
        --arg service_name "$VLESS_GRPC_SERVICE" \
        --arg cert "${TLS_DIR}/${VLESS_GRPC_DOMAIN}.crt" \
        --arg key "${TLS_DIR}/${VLESS_GRPC_DOMAIN}.key" \
        --argjson users "[$default_user]" \
        --argjson api_port "$api_port" \
        '{
            log: { level: "info", timestamp: true },
            inbounds: [{
                type: "vless",
                tag: "vless-grpc",
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
                    type: "grpc",
                    service_name: $service_name
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

    write_service "vless-grpc"
    start_service "vless-grpc"
    wait_service_start "vless-grpc" 10
    set_protocol_state "vless-grpc" "$VLESS_GRPC_PORT" "running" "$VLESS_GRPC_DOMAIN"

    init_users
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jq ".users += [{
        name: \"default\", uuid: \"$uuid\", password: null,
        protocols: [\"vless-grpc\"], enabled: true, created_at: \"$now\",
        traffic_limit_monthly: 0, traffic_limit_total: 0,
        traffic_used_monthly: 0, traffic_used_total: 0,
        monthly_reset_day: 1, blocked_at: null
    }]" "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

    generate_share_link "vless-grpc" "default"
    setup_traffic_cron

    echo ""
    echo "=== VLESS + gRPC + TLS 安装成功 ==="
    echo "域名: $VLESS_GRPC_DOMAIN"
    echo "端口: $VLESS_GRPC_PORT"
    echo "gRPC 服务: $VLESS_GRPC_SERVICE"
    echo "UUID: $uuid"
    echo ""
    cat "${CONFIG_DIR}/vless-grpc/share-link/default.txt" 2>/dev/null
}
