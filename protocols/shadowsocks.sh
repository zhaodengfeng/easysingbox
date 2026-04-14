#!/usr/bin/env bash
# protocols/shadowsocks.sh

prompt_shadowsocks() {
    local port
    port=$(prompt_port "8388")
    SS_PORT=$port

    echo "可选加密方法:"
    echo "  1. 2022-blake3-aes-256-gcm (推荐)"
    echo "  2. 2022-blake3-aes-128-gcm"
    echo "  3. 2022-blake3-chacha20-poly1305"
    read -rp "选择 [默认: 1]: " method_idx
    method_idx="${method_idx:-1}"
    case "$method_idx" in
        1) SS_METHOD="2022-blake3-aes-256-gcm" ;;
        2) SS_METHOD="2022-blake3-aes-128-gcm" ;;
        3) SS_METHOD="2022-blake3-chacha20-poly1305" ;;
        *) SS_METHOD="2022-blake3-aes-256-gcm" ;;
    esac
}

install_shadowsocks() {
    prompt_shadowsocks

    local server_password
    server_password=$(gen_password 32)
    local user_password
    user_password=$(gen_password)
    local default_user
    default_user=$(jq -n --arg pw "$user_password" '{name: "default", password: $pw}')

    local config_file="${CONFIG_DIR}/shadowsocks/inbound.json"
    mkdir -p "${CONFIG_DIR}/shadowsocks"

    local api_port
    api_port=$(get_api_port "shadowsocks")

    jq -n \
        --argjson port "$SS_PORT" \
        --arg method "$SS_METHOD" \
        --arg server_pw "$server_password" \
        --argjson users "[$default_user]" \
        --argjson api_port "$api_port" \
        '{
            log: { level: "info", timestamp: true },
            inbounds: [{
                type: "shadowsocks",
                tag: "shadowsocks",
                listen: "::",
                listen_port: $port,
                method: $method,
                password: $server_pw,
                users: $users
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

    write_service "shadowsocks"
    start_service "shadowsocks"
    wait_service_start "shadowsocks" 10
    set_protocol_state "shadowsocks" "$SS_PORT" "running"

    read -rp "请输入默认用户名 (留空为 default): " default_username
    [[ -z "$default_username" ]] && default_username="default"

    ensure_default_user "shadowsocks" "" "$user_password" "$default_username"

    generate_share_link "shadowsocks" "$default_username"
    setup_traffic_cron

    local server_ip
    server_ip=$(get_server_ip)
    echo ""
    echo "=== Shadowsocks 安装成功 ==="
    echo "服务器: $server_ip"
    echo "端口: $SS_PORT"
    echo "加密: $SS_METHOD"
    echo "密码: $user_password"
    echo ""
    cat "${CONFIG_DIR}/shadowsocks/share-link/default.txt" 2>/dev/null
}
