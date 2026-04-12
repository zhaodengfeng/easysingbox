#!/usr/bin/env bash
# protocols/anytls.sh

prompt_anytls() {
    read -rp "请输入域名: " ANYTLS_DOMAIN
    while ! validate_domain "$ANYTLS_DOMAIN"; do
        read -rp "域名格式无效，请重新输入: " ANYTLS_DOMAIN
    done

    ensure_certificate "$ANYTLS_DOMAIN" || return 1

    local port
    port=$(prompt_port "443")
    eval "ANYTLS_PORT=$port"
}

install_anytls() {
    prompt_anytls || return 1

    local password
    password=$(gen_password)
    local default_user
    default_user=$(jq -n --arg pw "$password" '{password: $pw}')

    local config_file="${CONFIG_DIR}/anytls/inbound.json"
    mkdir -p "${CONFIG_DIR}/anytls"

    local api_port
    api_port=$(get_api_port "anytls")

    jq -n \
        --argjson port "$ANYTLS_PORT" \
        --arg domain "$ANYTLS_DOMAIN" \
        --arg cert "${TLS_DIR}/${ANYTLS_DOMAIN}.crt" \
        --arg key "${TLS_DIR}/${ANYTLS_DOMAIN}.key" \
        --argjson users "[$default_user]" \
        --argjson api_port "$api_port" \
        '{
            log: { level: "info", timestamp: true },
            inbounds: [{
                type: "anytls",
                tag: "anytls",
                listen: "::",
                listen_port: $port,
                users: $users,
                tls: {
                    enabled: true,
                    server_name: $domain,
                    certificate_path: $cert,
                    key_path: $key
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

    write_service "anytls"
    start_service "anytls"
    wait_service_start "anytls" 10
    set_protocol_state "anytls" "$ANYTLS_PORT" "running" "$ANYTLS_DOMAIN"

    init_users
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jq ".users += [{
        name: \"default\", uuid: null, password: \"$password\",
        protocols: [\"anytls\"], enabled: true, created_at: \"$now\",
        traffic_limit_monthly: 0, traffic_limit_total: 0,
        traffic_used_monthly: 0, traffic_used_total: 0,
        monthly_reset_day: 1, blocked_at: null
    }]" "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

    generate_share_link "anytls" "default"
    setup_traffic_cron

    echo ""
    echo "=== AnyTLS 安装成功 ==="
    echo "域名: $ANYTLS_DOMAIN"
    echo "端口: $ANYTLS_PORT"
    echo "密码: $password"
    echo ""
    cat "${CONFIG_DIR}/anytls/share-link/default.txt" 2>/dev/null
}
