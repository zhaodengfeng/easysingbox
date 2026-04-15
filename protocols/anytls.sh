#!/usr/bin/env bash
# protocols/anytls.sh

prompt_anytls() {
    prompt_domain ANYTLS_DOMAIN "anytls"

    ensure_certificate "$ANYTLS_DOMAIN" || return 1

    local port
    port=$(prompt_port "443")
    ANYTLS_PORT=$port
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

    local api_secret
    api_secret=$(gen_api_secret)

    local listen_addr
    listen_addr=$(get_listen_address)

    jq -n \
        --argjson port "$ANYTLS_PORT" \
        --arg domain "$ANYTLS_DOMAIN" \
        --arg cert "${TLS_DIR}/${ANYTLS_DOMAIN}.crt" \
        --arg key "${TLS_DIR}/${ANYTLS_DOMAIN}.key" \
        --argjson users "[$default_user]" \
        --argjson api_port "$api_port" \
        --arg api_secret "$api_secret" \
        --arg listen_addr "$listen_addr" \
        '{
            log: { level: "info", timestamp: true },
            inbounds: [{
                type: "anytls",
                tag: "anytls",
                listen: $listen_addr,
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
                    secret: $api_secret
                }
            }
        }' > "$config_file"

    write_service "anytls"
    start_service "anytls"
    if ! wait_service_start "anytls" 10; then
        echo "警告: AnyTLS 服务启动失败，请使用 journalctl -u singbox-anytls -n 50 查看日志"
    fi
    set_protocol_state "anytls" "$ANYTLS_PORT" "running" "$ANYTLS_DOMAIN"

    read -rp "请输入默认用户名 (留空为 default): " default_username
    [[ -z "$default_username" ]] && default_username="default"

    ensure_default_user "anytls" "" "$password" "$default_username"

    generate_share_link "anytls" "$default_username"
    setup_traffic_cron

    echo ""
    echo "=== AnyTLS 安装成功 ==="
    echo "域名: $ANYTLS_DOMAIN"
    echo "端口: $ANYTLS_PORT"
    echo "密码: $password"
    echo ""
    cat "${CONFIG_DIR}/anytls/share-link/${default_username}.txt" 2>/dev/null
}
