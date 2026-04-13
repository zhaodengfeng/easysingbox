#!/usr/bin/env bash
# lib/rebuild.sh — 用户变更后重建协议配置

# Rebuild a protocol's inbound.json based on current users
rebuild_protocol_config() {
    local protocol="$1"
    local config_file="${CONFIG_DIR}/${protocol}/inbound.json"

    [[ -f "$config_file" ]] || return 0
    [[ -f "$USERS_FILE" ]] || return 0

    # Get active users for this protocol
    local active_users
    active_users=$(jq --arg proto "$protocol" \
        '[.users[] | select(.enabled == true and .blocked_at == null and (.protocols | index($proto)))]' "$USERS_FILE")

    local user_count
    user_count=$(echo "$active_users" | jq 'length')

    if (( user_count == 0 )); then
        echo "[rebuild] 协议 $protocol 无活跃用户，跳过重建"
        return 0
    fi

    # Build users array based on protocol type
    local users_json="[]"
    case "$protocol" in
        vless-reality)
            users_json=$(echo "$active_users" | jq \
                '[.[] | select(.uuid != null) | {uuid: .uuid, flow: "xtls-rprx-vision"}]')
            ;;
        vless-ws|vless-grpc)
            users_json=$(echo "$active_users" | jq \
                '[.[] | select(.uuid != null) | {uuid: .uuid}]')
            ;;
        vmess-ws)
            users_json=$(echo "$active_users" | jq \
                '[.[] | select(.uuid != null) | {uuid: .uuid, alterId: 0}]')
            ;;
        trojan)
            users_json=$(echo "$active_users" | jq \
                '[.[] | select(.password != null) | {password: .password}]')
            ;;
        shadowsocks)
            users_json=$(echo "$active_users" | jq \
                '[.[] | select(.password != null) | {name: .name, password: .password}]')
            ;;
        shadowtls)
            users_json=$(echo "$active_users" | jq \
                '[.[] | select(.password != null) | {password: .password}]')
            ;;
        hysteria2)
            users_json=$(echo "$active_users" | jq \
                '[.[] | select(.password != null) | {name: .name, password: .password}]')
            ;;
        tuic)
            users_json=$(echo "$active_users" | jq \
                '[.[] | select(.uuid != null and .password != null) | {uuid: .uuid, password: .password}]')
            ;;
        anytls)
            users_json=$(echo "$active_users" | jq \
                '[.[] | select(.password != null) | {password: .password}]')
            ;;
    esac

    # Update the inbound.json users field
    local tmp="${config_file}.tmp"
    case "$protocol" in
        shadowtls)
            # shadowtls has 2 inbounds: [0]=shadowtls, [1]=shadowsocks
            # inbound[0] users list is the ST password list (1:1 mapping from SS users)
            jq --argjson users "$users_json" '
                .inbounds[0].users = ($users | map({password: .password})) |
                .inbounds[1].users = $users
            ' "$config_file" > "$tmp" && mv "$tmp" "$config_file"
            ;;
        *)
            jq --argjson users "$users_json" '
                .inbounds[0].users = $users
            ' "$config_file" > "$tmp" && mv "$tmp" "$config_file"
            ;;
    esac

    echo "[rebuild] 协议 $protocol 配置已重建 ($user_count 个用户)"

    # Restart service
    if is_protocol_installed "$protocol"; then
        restart_service "$protocol"
        wait_service_start "$protocol" 10 || echo "[rebuild] 警告: 服务 $protocol 重启后未正常启动"
    fi
}
