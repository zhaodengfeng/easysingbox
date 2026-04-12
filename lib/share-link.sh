#!/usr/bin/env bash
# lib/share-link.sh — 分享链接生成

generate_share_link() {
    local protocol="$1"
    local username="$2"
    local share_dir="${CONFIG_DIR}/${protocol}/share-link"
    mkdir -p "$share_dir"

    local user_data
    user_data=$(jq --arg name "$username" '.users[] | select(.name == $name)' "$USERS_FILE")
    [[ -z "$user_data" ]] || [[ "$user_data" == "null" ]] && return

    local uuid password
    uuid=$(echo "$user_data" | jq -r '.uuid // empty')
    password=$(echo "$user_data" | jq -r '.password // empty')

    local server_ip
    server_ip=$(get_server_ip)

    local port
    port=$(get_protocol_port "$protocol")
    [[ -z "$port" ]] && return

    local link=""

    case "$protocol" in
        vless-reality)
            local sni pbk sid
            sni=$(jq -r '.inbounds[0].tls.server_name // ""' "${CONFIG_DIR}/${protocol}/inbound.json")
            pbk=$(jq -r --arg key "vless-reality" '.protocols[$key].public_key // ""' "$STATE_FILE")
            sid=$(jq -r '.inbounds[0].tls.reality.short_id[0] // ""' "${CONFIG_DIR}/${protocol}/inbound.json")
            link="vless://${uuid}@${server_ip}:${port}?security=reality&flow=xtls-rprx-vision&sni=${sni}&pbk=${pbk}&sid=${sid}#${username}"
            ;;
        vless-ws)
            local domain path
            domain=$(jq -r '.inbounds[0].tls.server_name // ""' "${CONFIG_DIR}/${protocol}/inbound.json")
            path=$(jq -r '.inbounds[0].transport.path // "/"' "${CONFIG_DIR}/${protocol}/inbound.json")
            link="vless://${uuid}@${domain}:${port}?security=tls&type=ws&path=${path}&host=${domain}#${username}"
            ;;
        vless-grpc)
            local domain service_name
            domain=$(jq -r '.inbounds[0].tls.server_name // ""' "${CONFIG_DIR}/${protocol}/inbound.json")
            service_name=$(jq -r '.inbounds[0].transport.service_name // ""' "${CONFIG_DIR}/${protocol}/inbound.json")
            link="vless://${uuid}@${domain}:${port}?security=tls&type=grpc&serviceName=${service_name}#${username}"
            ;;
        vmess-ws)
            local domain path
            domain=$(jq -r '.inbounds[0].tls.server_name // ""' "${CONFIG_DIR}/${protocol}/inbound.json")
            path=$(jq -r '.inbounds[0].transport.path // "/"' "${CONFIG_DIR}/${protocol}/inbound.json")
            local vmess_json
            vmess_json=$(jq -n \
                --arg v "2" --arg ps "$username" --arg add "$domain" --arg port "$port" \
                --arg id "$uuid" --arg aid "0" --arg net "ws" --arg type "none" \
                --arg path "$path" --arg tls "tls" --arg sni "$domain" \
                '{v:$v, ps:$ps, add:$add, port:$port, id:$id, aid:$aid, net:$net, type:$type, path:$path, tls:$tls, sni:$sni}' \
                | base64 -w0)
            link="vmess://${vmess_json}"
            ;;
        trojan)
            local domain
            domain=$(jq -r '.inbounds[0].tls.server_name // ""' "${CONFIG_DIR}/${protocol}/inbound.json")
            link="trojan://${password}@${domain}:${port}?security=tls#${username}"
            ;;
        shadowsocks)
            local method server_pw
            method=$(jq -r '.inbounds[0].method // "2022-blake3-aes-256-gcm"' "${CONFIG_DIR}/${protocol}/inbound.json")
            server_pw=$(jq -r '.inbounds[0].password // ""' "${CONFIG_DIR}/${protocol}/inbound.json")
            local encoded
            encoded=$(echo -n "${method}:${server_pw}:${password}" | base64 -w0)
            link="ss://${encoded}@${server_ip}:${port}#${username}"
            ;;
        shadowtls)
            local domain st_pass
            domain=$(jq -r '.inbounds[0].tls.server_name // ""' "${CONFIG_DIR}/${protocol}/inbound.json")
            st_pass=$(jq -r '.inbounds[0].users[0].password // ""' "${CONFIG_DIR}/${protocol}/inbound.json")
            local ss_method
            ss_method=$(jq -r '.inbounds[1].method // "2022-blake3-aes-128-gcm"' "${CONFIG_DIR}/${protocol}/inbound.json")
            link="ss://${ss_method}:${password}@${server_ip}:${port}?shadow-tls=${st_pass}&shadow-tls-sni=${domain}#${username}"
            ;;
        hysteria2)
            local domain
            domain=$(jq -r '.inbounds[0].tls.server_name // ""' "${CONFIG_DIR}/${protocol}/inbound.json")
            link="hysteria2://${password}@${domain}:${port}?sni=${domain}&insecure=0#${username}"
            ;;
        tuic)
            local domain
            domain=$(jq -r '.inbounds[0].tls.server_name // ""' "${CONFIG_DIR}/${protocol}/inbound.json")
            link="tuic://${uuid}:${password}@${domain}:${port}?sni=${domain}#${username}"
            ;;
        anytls)
            local domain
            domain=$(jq -r '.inbounds[0].tls.server_name // ""' "${CONFIG_DIR}/${protocol}/inbound.json")
            link="anytls://${password}@${domain}:${port}?sni=${domain}#${username}"
            ;;
    esac

    if [[ -n "$link" ]]; then
        echo "$link" > "${share_dir}/${username}.txt"
        echo "$link"
    fi
}

view_share_links() {
    [[ -f "$STATE_FILE" ]] || { echo "尚未安装任何协议"; return; }

    local protocols
    protocols=$(jq -r '.protocols | keys[]' "$STATE_FILE" 2>/dev/null)
    [[ -z "$protocols" ]] && { echo "尚未安装任何协议"; return; }

    [[ -f "$USERS_FILE" ]] || { echo "暂无用户"; return; }
    local users
    users=$(jq -r '.users[].name' "$USERS_FILE" 2>/dev/null)
    [[ -z "$users" ]] && { echo "暂无用户"; return; }

    echo "分享链接 / 二维码"
    echo ""
    echo ""

    echo "选择用户:"
    echo "$users" | nl -w2 -s'. '
    echo ""
    read -rp "选择用户编号: " user_idx
    user_idx=$(echo "$user_idx" | tr -d ' ')

    local username
    username=$(jq -r --argjson idx "$((user_idx - 1))" '.users[$idx].name // empty' "$USERS_FILE")
    [[ -z "$username" ]] && { echo "无效用户编号"; return; }

    echo ""
    echo "用户: $username"
    echo ""

    for protocol in $protocols; do
        local link_file="${CONFIG_DIR}/${protocol}/share-link/${username}.txt"
        if [[ -f "$link_file" ]]; then
            echo "=== $protocol ==="
            cat "$link_file"
            echo ""
            # Generate QR code
            if command -v qrencode &>/dev/null; then
                qrencode -t ANSIUTF8 -s 3 -m 1 < "$link_file"
                echo ""
            fi
        fi
    done
}
