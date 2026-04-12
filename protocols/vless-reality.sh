#!/usr/bin/env bash
# protocols/vless-reality.sh

REALITY_DESTS=(
    "www.microsoft.com"
    "www.apple.com"
    "cloudflare.com"
    "www.amazon.com"
    "github.com"
)

prompt_vless_reality() {
    local port
    port=$(prompt_port "8443")
    eval "VLESS_REALITY_PORT=$port"

    echo ""
    echo "可选 Reality 伪装目标:"
    for i in "${!REALITY_DESTS[@]}"; do
        echo "  $((i+1)). ${REALITY_DESTS[$i]}"
    done
    echo "  6. 自定义"
    read -rp "选择 [默认: 1]: " dest_idx
    dest_idx="${dest_idx:-1}"
    if [[ "$dest_idx" -ge 1 ]] && [[ "$dest_idx" -le 5 ]]; then
        VLESS_REALITY_DEST="${REALITY_DESTS[$((dest_idx - 1))]}"
    else
        read -rp "自定义目标域名: " VLESS_REALITY_DEST
    fi
}

install_vless_reality() {
    prompt_vless_reality

    # Generate reality keypair
    echo "正在生成 Reality 密钥对 ..."
    local keypair
    keypair=$("${INSTALL_DIR}/bin/sing-box" generate reality-keypair 2>/dev/null) || {
        echo "生成密钥失败"
        return 1
    }

    local private_key public_key
    private_key=$(echo "$keypair" | awk '/PrivateKey:/{print $2}')
    public_key=$(echo "$keypair" | awk '/PublicKey:/{print $2}')

    if [[ -z "$private_key" ]] || [[ -z "$public_key" ]]; then
        # Fallback: try JSON output
        private_key=$(echo "$keypair" | jq -r '.private_key // empty' 2>/dev/null)
        public_key=$(echo "$keypair" | jq -r '.public_key // empty' 2>/dev/null)
    fi

    local short_id
    short_id=$(openssl rand -hex 8)

    # Create default user
    local uuid
    uuid=$(gen_uuid)
    local default_user
    default_user=$(jq -n \
        --arg uuid "$uuid" \
        '{uuid: $uuid, flow: "xtls-rprx-vision"}')

    # Generate config
    local config_file="${CONFIG_DIR}/vless-reality/inbound.json"
    mkdir -p "${CONFIG_DIR}/vless-reality"

    local api_port
    api_port=$(get_api_port "vless-reality")

    jq -n \
        --argjson port "$VLESS_REALITY_PORT" \
        --arg dest "$VLESS_REALITY_DEST" \
        --arg private_key "$private_key" \
        --arg short_id "$short_id" \
        --argjson users "[$default_user]" \
        --argjson api_port "$api_port" \
        '{
            log: { level: "info", timestamp: true },
            inbounds: [{
                type: "vless",
                tag: "vless-reality",
                listen: "::",
                listen_port: $port,
                users: $users,
                tls: {
                    enabled: true,
                    server_name: $dest,
                    reality: {
                        enabled: true,
                        handshake: { server: $dest, server_port: 443 },
                        private_key: $private_key,
                        short_id: [$short_id]
                    }
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

    # Write service
    write_service "vless-reality"

    # Start
    start_service "vless-reality"
    wait_service_start "vless-reality" 10

    # Update state
    set_protocol_state "vless-reality" "$VLESS_REALITY_PORT" "running"

    # Add default user to users.json
    init_users
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    jq ".users += [{
        name: \"default\",
        uuid: \"$uuid\",
        password: null,
        protocols: [\"vless-reality\"],
        enabled: true,
        created_at: \"$now\",
        traffic_limit_monthly: 0,
        traffic_limit_total: 0,
        traffic_used_monthly: 0,
        traffic_used_total: 0,
        monthly_reset_day: 1,
        blocked_at: null
    }]" "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

    # Generate share link
    generate_share_link "vless-reality" "default"

    # Setup traffic cron
    setup_traffic_cron

    # Display info
    local server_ip
    server_ip=$(get_server_ip)
    echo ""
    echo "=== VLESS + Reality 安装成功 ==="
    echo "服务器: $server_ip"
    echo "端口: $VLESS_REALITY_PORT"
    echo "UUID: $uuid"
    echo "Reality SNI: $VLESS_REALITY_DEST"
    echo "Public Key: $public_key"
    echo "Short ID: $short_id"
    echo ""
    echo "分享链接:"
    cat "${CONFIG_DIR}/vless-reality/share-link/default.txt" 2>/dev/null
}
