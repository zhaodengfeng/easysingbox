#!/usr/bin/env bash
# lib/common.sh — 公共函数库

# ─── System Detection ────────────────────────────────────────────────────

detect_arch() {
    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64)  echo "amd64" ;;
        aarch64) echo "arm64" ;;
        *) echo "不支持的架构: $arch"; exit 1 ;;
    esac
}

detect_os() {
    if [[ -f /etc/os-release ]]; then
        grep -E '^ID=' /etc/os-release | head -1 | cut -d= -f2 | tr -d '"'
    elif [[ -f /etc/redhat-release ]]; then
        echo "centos"
    else
        echo "unknown"
    fi
}

get_package_manager() {
    local os
    os=$(detect_os)
    case "$os" in
        ubuntu|debian)              echo "apt" ;;
        fedora)                     echo "dnf" ;;
        centos|rocky|almalinux)     echo "yum" ;;
        alpine)                     echo "apk" ;;
        *) echo "unknown" ;;
    esac
}

# ─── Network Detection ─────────────────────────────────────────────────────

# Detect whether IPv6 is available on this system.
# Returns "::" for dual-stack (IPv6 enabled) or "0.0.0.0" for IPv4-only.
get_listen_address() {
    if [[ -f /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]; then
        local disabled
        disabled=$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)
        if [[ "$disabled" == "0" ]]; then
            echo "::"
            return
        fi
    fi
    echo "0.0.0.0"
}

# ─── Utilities ────────────────────────────────────────────────────────────

gen_uuid() {
    if command -v uuidgen &>/dev/null; then
        uuidgen | tr '[:upper:]' '[:lower:]'
    else
        cat /proc/sys/kernel/random/uuid 2>/dev/null || \
        openssl rand -hex 16 | sed 's/\([a-f0-9]\{8\}\)\([a-f0-9]\{4\}\)\([a-f0-9]\{4\}\)\([a-f0-9]\{4\}\)\([a-f0-9]\{12\}\)/\1-\2-\3-\4-\5/'
    fi
}

gen_password() {
    local len=${1:-16}
    openssl rand -base64 48 | tr -dc 'a-zA-Z0-9' | head -c "$len"
}

gen_port() {
    local min=${1:-10000}
    local max=${2:-65535}
    local i=0
    while (( i < 1000 )); do
        local port=$(( RANDOM % (max - min + 1) + min ))
        if ! ss -tlnp 2>/dev/null | grep -q ":${port} " && \
           ! ss -ulnp 2>/dev/null | grep -q ":${port} "; then
            echo "$port"
            return
        fi
        i=$(( i + 1 ))
    done
    echo ""
    return 1
}

validate_domain() {
    local domain="$1"
    # 域名格式验证：支持子域名，每段 1-63 字符，总长 1-253 字符
    if [[ "$domain" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?)*\.[a-zA-Z]{2,}$ ]]; then
        return 0
    fi
    return 1
}

check_port_available() {
    local port="$1"
    if ss -tlnp 2>/dev/null | grep -q ":${port} " || \
       ss -ulnp 2>/dev/null | grep -q ":${port} "; then
        return 1
    fi
    return 0
}

prompt_port() {
    local default_port="$1"
    local port
    while true; do
        read -rp "请输入端口 [默认: ${default_port}]: " port
        port="${port:-$default_port}"
        if [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 && port <= 65535 )); then
            if check_port_available "$port"; then
                echo "$port"
                return
            else
                echo "端口 $port 已被占用，请更换" >&2
            fi
        else
            echo "无效的端口号" >&2
        fi
    done
}

validate_ip() {
    local ip="$1"
    # IPv4 基础格式验证（不验证每段 0-255 范围）
    [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

validate_email() {
    local email="$1"
    # 邮箱格式基础验证
    [[ "$email" =~ ^[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]
}

# ─── Atomic Write ─────────────────────────────────────────────────────────

atomic_write() {
    local file="$1"
    local content="$2"
    local tmp="${file}.tmp"
    printf '%s\n' "$content" > "$tmp"
    mv "$tmp" "$file"
}

# ─── State Management ─────────────────────────────────────────────────────

init_state() {
    if [[ ! -f "$STATE_FILE" ]]; then
        atomic_write "$STATE_FILE" '{"version":"","installed_at":"","protocols":{},"traffic_snapshot":{}}'
    fi
}

save_state() {
    local tmp="${STATE_FILE}.tmp"
    jq '.' "$STATE_FILE" > "$tmp" 2>/dev/null && mv "$tmp" "$STATE_FILE"
}

get_protocol_port() {
    local protocol="$1"
    if [[ -f "$STATE_FILE" ]]; then
        jq -r ".protocols[\"$protocol\"].port // empty" "$STATE_FILE"
    fi
}

set_protocol_state() {
    local protocol="$1"
    local port="$2"
    local status="${3:-running}"
    local domain="${4:-}"
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

    if [[ ! -f "$STATE_FILE" ]]; then
        init_state
    fi

    # Merge update — preserve existing fields (e.g. public_key)
    if [[ -n "$domain" ]]; then
        jq --arg proto "$protocol" --argjson port "$port" --arg status "$status" --arg domain "$domain" --arg now "$now" \
            '.protocols[$proto] = (.protocols[$proto] // {} | . + {"port": $port, "status": $status, "domain": $domain, "created_at": $now})' \
            "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    else
        jq --arg proto "$protocol" --argjson port "$port" --arg status "$status" --arg now "$now" \
            '.protocols[$proto] = (.protocols[$proto] // {} | . + {"port": $port, "status": $status, "created_at": $now})' \
            "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
}

update_protocol_status() {
    local protocol="$1"
    local status="$2"
    if [[ -f "$STATE_FILE" ]]; then
        jq --arg proto "$protocol" --arg status "$status" \
            '.protocols[$proto].status = $status' \
            "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
}

delete_protocol_state() {
    local protocol="$1"
    if [[ -f "$STATE_FILE" ]]; then
        jq --arg proto "$protocol" \
            'del(.protocols[$proto]) | del(.traffic_snapshot[$proto])' \
            "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    fi
}

# ─── Certificate Management ──────────────────────────────────────────────

check_certificate_status() {
    local domain="$1"
    local cert_path="${TLS_DIR}/${domain}.crt"

    if [[ ! -f "$cert_path" ]]; then
        echo "not_found"
        return
    fi

    if ! openssl x509 -in "$cert_path" -noout 2>/dev/null; then
        echo "invalid"
        return
    fi

    local expiry
    expiry=$(openssl x509 -in "$cert_path" -noout -enddate 2>/dev/null | cut -d= -f2)
    if [[ -z "$expiry" ]]; then
        echo "invalid"
        return
    fi

    local expiry_epoch
    expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || date -j -f "%b %d %T %Y %Z" "$expiry" +%s 2>/dev/null)
    local now_epoch
    now_epoch=$(date +%s)
    local days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

    if (( days_left < 0 )); then
        echo "expired"
        return
    fi

    if (( days_left < 15 )); then
        echo "expiring"
        return
    fi

    # Check domain match
    local cert_cn
    cert_cn=$(openssl x509 -in "$cert_path" -noout -subject 2>/dev/null | sed -n 's/.*CN\s*=\s*//p' | sed 's/\s*\/.*//')
    if [[ -n "$cert_cn" ]] && [[ "$cert_cn" != *"$domain"* ]]; then
        echo "mismatch"
        return
    fi

    echo "valid"
}

request_acme_cert() {
    local domain="$1"
    local email="${2:-}"

    # Check if acme.sh is installed and its directory exists
    if ! command -v acme.sh &>/dev/null || [[ ! -d "$HOME/.acme.sh" ]]; then
        echo "正在安装 acme.sh ..."
        curl -fsSL https://get.acme.sh | sh -s email=test@example.com \
            || { echo "acme.sh 安装失败"; return 1; }
        export PATH="$HOME/.acme.sh:$PATH"
    fi

    if [[ -z "$email" ]]; then
        read -rp "请输入用于申请证书的邮箱地址: " email
        while ! validate_email "$email"; do
            read -rp "邮箱格式无效，请重新输入: " email
        done
    fi

    # Update account email
    acme.sh --update-account -m "$email" 2>/dev/null || true

    echo "正在为 $domain 申请证书 ..."
    local acme_output
    acme_output=$(acme.sh --issue --standalone -d "$domain" --server letsencrypt \
        --force \
        --listen-v4 \
        --keylength ec-256 2>&1) || true

    if [[ -f "${HOME}/.acme.sh/${domain}_ecc/fullchain.cer" ]]; then
        mkdir -p "$TLS_DIR"
        acme.sh --install-cert -d "$domain" --ecc \
            --key-file "${TLS_DIR}/${domain}.key" \
            --fullchain-file "${TLS_DIR}/${domain}.crt" 2>&1 || true
        if [[ -f "${TLS_DIR}/${domain}.crt" ]]; then
            chmod 644 "${TLS_DIR}/${domain}.crt" "${TLS_DIR}/${domain}.key"
            echo "证书申请成功"
            return 0
        fi
    fi

    echo "$acme_output"
    echo ""
    echo "证书申请失败，可能原因:"
    echo "  1. 80 端口被云服务器安全组拦截"
    echo "  2. 域名未正确解析到本服务器"
    echo "  3. 域名通过 CDN（如 Cloudflare）代理，需关闭代理"
    echo ""
    echo "如已有证书，可重新运行并选择「使用已有证书」"
    return 1
}

use_existing_certificate() {
    local domain="$1"
    local cert_path key_path

    read -rp "证书文件路径 (.crt/.pem): " cert_path
    if [[ ! -f "$cert_path" ]]; then
        echo "证书文件不存在: $cert_path"
        return 1
    fi
    read -rp "私钥文件路径 (.key): " key_path
    if [[ ! -f "$key_path" ]]; then
        echo "私钥文件不存在: $key_path"
        return 1
    fi
    mkdir -p "$TLS_DIR"
    cp "$cert_path" "${TLS_DIR}/${domain}.crt"
    cp "$key_path" "${TLS_DIR}/${domain}.key"
    chmod 644 "${TLS_DIR}/${domain}.crt" "${TLS_DIR}/${domain}.key"
    echo "证书已复制到 ${TLS_DIR}/${domain}.{crt,key}"
    return 0
}

ensure_certificate() {
    local domain="$1"
    local email="${2:-}"

    # Check if already exists in our tls dir
    local status
    status=$(check_certificate_status "$domain")

    if [[ "$status" == "valid" ]]; then
        echo "证书已存在且有效"
        return 0
    fi

    # 1. Check if old certificate exists in easysingbox TLS_DIR
    if [[ -f "${TLS_DIR}/${domain}.crt" ]] && [[ -f "${TLS_DIR}/${domain}.key" ]]; then
        echo ""
        echo "检测到 easysingbox 目录下有 ${domain} 的旧证书，是否直接使用？"
        read -rp "使用旧证书？[y/N]: " use_old
        if [[ "$use_old" =~ ^[Yy]$ ]]; then
            return 0
        fi
        # User chose no, fall through to request new cert
    else
        # 2. No old cert in default dir, ask if user wants to specify another path
        echo ""
        echo "未在 easysingbox 目录找到 ${domain} 的证书"
        read -rp "是否使用其他位置的已有证书？[y/N]: " use_other
        if [[ "$use_other" =~ ^[Yy]$ ]]; then
            if use_existing_certificate "$domain"; then
                return 0
            fi
        fi
    fi

    # 3. Request / renew certificate
    case "$status" in
        expiring|expired|mismatch)
            echo "证书状态: $status，正在重新申请 ..."
            if ! request_acme_cert "$domain" "$email"; then
                echo "申请失败"
                return 1
            fi
            return 0
            ;;
        not_found|invalid)
            if [[ "$status" == "invalid" ]]; then
                echo "证书无效，正在重新申请 ..."
            else
                echo "未找到证书，正在申请 ..."
            fi
            if ! request_acme_cert "$domain" "$email"; then
                echo "申请失败"
                return 1
            fi
            return 0
            ;;
    esac
}

# ─── Service Management ───────────────────────────────────────────────────

get_service_name() {
    local protocol="$1"
    echo "singbox-${protocol}"
}

write_service() {
    local protocol="$1"
    local service_name
    service_name=$(get_service_name "$protocol")
    local service_file="${SERVICE_DIR}/${service_name}.service"

    cat > "$service_file" <<EOF
[Unit]
Description=EasySingBox - ${protocol}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=${INSTALL_DIR}/bin/sing-box run -c ${CONFIG_DIR}/${protocol}/inbound.json
Restart=on-failure
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${INSTALL_DIR}
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
RestrictRealtime=true
DevicePolicy=closed
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE

[Install]
WantedBy=multi-user.target
EOF

    # Symlink to systemd
    ln -sf "$service_file" "/etc/systemd/system/${service_name}.service"
    systemctl daemon-reload
}

start_service() {
    local protocol="$1"
    local service_name
    service_name=$(get_service_name "$protocol")
    systemctl enable "$service_name" &>/dev/null || true
    systemctl start "$service_name"
    update_protocol_status "$protocol" "running"
}

stop_service() {
    local protocol="$1"
    local service_name
    service_name=$(get_service_name "$protocol")
    systemctl stop "$service_name" 2>/dev/null || true
    systemctl disable "$service_name" 2>/dev/null || true
    update_protocol_status "$protocol" "stopped"
}

restart_service() {
    local protocol="$1"
    local service_name
    service_name=$(get_service_name "$protocol")
    systemctl restart "$service_name"
    update_protocol_status "$protocol" "running"
}

wait_service_start() {
    local protocol="$1"
    local max_wait=${2:-10}
    local i=0
    while (( i < max_wait )); do
        if systemctl is-active --quiet "$(get_service_name "$protocol")"; then
            return 0
        fi
        sleep 1
        i=$(( i + 1 ))
    done
    return 1
}

check_service_status() {
    local protocol="$1"
    local service_name
    service_name=$(get_service_name "$protocol")
    systemctl is-active "$service_name" 2>/dev/null || echo "inactive"
}

# ─── Protocol config dispatcher ──────────────────────────────────────────

prompt_protocol_config() {
    local protocol="$1"
    case "$protocol" in
        vless-reality) prompt_vless_reality ;;
        vless-ws)      prompt_vless_ws ;;
        vless-grpc)    prompt_vless_grpc ;;
        vmess-ws)      prompt_vmess_ws ;;
        trojan)        prompt_trojan ;;
        shadowsocks)   prompt_shadowsocks ;;
        shadowtls)     prompt_shadowtls ;;
        hysteria2)     prompt_hysteria2 ;;
        tuic)          prompt_tuic ;;
        anytls)        prompt_anytls ;;
    esac
}
