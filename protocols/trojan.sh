#!/usr/bin/env bash
# protocols/trojan.sh

prompt_trojan() {
    read -rp "请输入域名: " TROJAN_DOMAIN
    while ! validate_domain "$TROJAN_DOMAIN"; do
        read -rp "域名格式无效，请重新输入: " TROJAN_DOMAIN
    done

    ensure_certificate "$TROJAN_DOMAIN" || return 1

    local port
    port=$(prompt_port "443")
    TROJAN_PORT=$port
}

install_trojan() {
    prompt_trojan || return 1

    local password
    password=$(gen_password)
    local default_user
    default_user=$(jq -n --arg pw "$password" '{password: $pw}')

    local config_file="${CONFIG_DIR}/trojan/inbound.json"
    mkdir -p "${CONFIG_DIR}/trojan"

    local api_port
    api_port=$(get_api_port "trojan")

    local listen_addr
    listen_addr=$(get_listen_address)

    jq -n \
        --argjson port "$TROJAN_PORT" \
        --arg domain "$TROJAN_DOMAIN" \
        --arg cert "${TLS_DIR}/${TROJAN_DOMAIN}.crt" \
        --arg key "${TLS_DIR}/${TROJAN_DOMAIN}.key" \
        --argjson users "[$default_user]" \
        --argjson api_port "$api_port" \
        --arg listen_addr "$listen_addr" \
        '{
            log: { level: "info", timestamp: true },
            inbounds: [{
                type: "trojan",
                tag: "trojan",
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
                    secret: ""
                }
            }
        }' > "$config_file"

    write_service "trojan"
    start_service "trojan"
    wait_service_start "trojan" 10
    set_protocol_state "trojan" "$TROJAN_PORT" "running" "$TROJAN_DOMAIN"

    read -rp "请输入默认用户名 (留空为 default): " default_username
    [[ -z "$default_username" ]] && default_username="default"

    ensure_default_user "trojan" "" "$password" "$default_username"

    generate_share_link "trojan" "$default_username"
    setup_traffic_cron

    echo ""
    echo "=== Trojan + TLS 安装成功 ==="
    echo "域名: $TROJAN_DOMAIN"
    echo "端口: $TROJAN_PORT"
    echo "密码: $password"
    echo ""
    cat "${CONFIG_DIR}/trojan/share-link/default.txt" 2>/dev/null
}
