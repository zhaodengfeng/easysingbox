#!/usr/bin/env bash
# protocols/shadowtls.sh

prompt_shadowtls() {
    prompt_domain SHADOWTLS_DOMAIN "shadowtls"

    ensure_certificate "$SHADOWTLS_DOMAIN" || return 1

    local port
    port=$(prompt_port "443")
    SHADOWTLS_PORT=$port
}

install_shadowtls() {
    prompt_shadowtls || return 1

    local st_password ss_password
    st_password=$(gen_password)
    ss_password=$(gen_password)

    local default_user
    default_user=$(jq -n --arg pw "$ss_password" '{name: "default", password: $pw}')

    local config_file="${CONFIG_DIR}/shadowtls/inbound.json"
    mkdir -p "${CONFIG_DIR}/shadowtls"

    local api_port
    api_port=$(get_api_port "shadowtls")

    local api_secret
    api_secret=$(gen_api_secret)

    local listen_addr
    listen_addr=$(get_listen_address)

    jq -n \
        --argjson port "$SHADOWTLS_PORT" \
        --arg domain "$SHADOWTLS_DOMAIN" \
        --arg st_pass "$st_password" \
        --arg ss_method "2022-blake3-aes-128-gcm" \
        --arg ss_pass "$ss_password" \
        --arg cert "${TLS_DIR}/${SHADOWTLS_DOMAIN}.crt" \
        --arg key "${TLS_DIR}/${SHADOWTLS_DOMAIN}.key" \
        --argjson users "[$default_user]" \
        --argjson api_port "$api_port" \
        --arg api_secret "$api_secret" \
        --arg listen_addr "$listen_addr" \
        '{
            log: { level: "info", timestamp: true },
            inbounds: [
                {
                    type: "shadowtls",
                    tag: "shadowtls",
                    listen: $listen_addr,
                    listen_port: $port,
                    detour: "shadowsocks-in",
                    users: [{ password: $st_pass }],
                    tls: {
                        enabled: true,
                        server_name: $domain,
                        certificate_path: $cert,
                        key_path: $key,
                        strict_mode: true
                    }
                },
                {
                    type: "shadowsocks",
                    tag: "shadowsocks-in",
                    listen: "127.0.0.1",
                    network: "tcp",
                    method: $ss_method,
                    password: $ss_pass,
                    users: $users
                }
            ],
            outbounds: [{ type: "direct", tag: "direct" }],
            experimental: {
                clash_api: {
                    external_controller: ("127.0.0.1:" + ($api_port | tostring)),
                    external_ui: "",
                    secret: $api_secret
                }
            }
        }' > "$config_file"

    write_service "shadowtls"
    start_service "shadowtls"
    if ! wait_service_start "shadowtls" 10; then
        echo "警告: ShadowTLS 服务启动失败，请使用 journalctl -u singbox-shadowtls -n 50 查看日志"
    fi
    set_protocol_state "shadowtls" "$SHADOWTLS_PORT" "running" "$SHADOWTLS_DOMAIN"

    read -rp "请输入默认用户名 (留空为 default): " default_username
    [[ -z "$default_username" ]] && default_username="default"

    ensure_default_user "shadowtls" "" "$ss_password" "$default_username"

    generate_share_link "shadowtls" "$default_username"
    setup_traffic_cron

    local server_ip
    server_ip=$(get_server_ip)
    echo ""
    echo "=== ShadowTLS + Shadowsocks 安装成功 ==="
    echo "域名: $SHADOWTLS_DOMAIN"
    echo "端口: $SHADOWTLS_PORT"
    echo "SS 密码: $ss_password"
    echo "ST 密码: $st_password"
    echo ""
    cat "${CONFIG_DIR}/shadowtls/share-link/${default_username}.txt" 2>/dev/null
}
