#!/usr/bin/env bash
# lib/users.sh — 用户管理

# ─── Init ─────────────────────────────────────────────────────────────────

init_users() {
    if [[ ! -f "$USERS_FILE" ]]; then
        atomic_write "$USERS_FILE" '{"users":[]}'
    fi
}

# ─── Default User Helper ──────────────────────────────────────────────────

ensure_default_user() {
    local protocol="$1"
    local uuid="${2:-}"
    local password="${3:-}"

    init_users

    if jq -e '.users[] | select(.name == "default")' "$USERS_FILE" &>/dev/null; then
        # Update existing: add protocol, refresh credentials
        jq --arg proto "$protocol" \
           --arg uuid "$uuid" \
           --arg password "$password" \
           '(.users[] | select(.name == "default")) |= (
               .protocols = ([.protocols[], $proto] | unique) |
               if $uuid != "" then .uuid = $uuid else . end |
               if $password != "" then .password = $password else . end
           )' "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"
    else
        local now
        now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        local user_json
        user_json=$(jq -n \
            --arg proto "$protocol" \
            --arg uuid "$uuid" \
            --arg password "$password" \
            --arg created_at "$now" \
            '{
                name: "default",
                uuid: (if $uuid == "" then null else $uuid end),
                password: (if $password == "" then null else $password end),
                protocols: [$proto],
                enabled: true,
                created_at: $created_at,
                traffic_limit_monthly: 0,
                traffic_limit_total: 0,
                traffic_used_monthly: 0,
                traffic_used_total: 0,
                monthly_reset_day: 1,
                blocked_at: null
            }')
        jq --argjson user "$user_json" '.users += [$user]' \
            "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"
    fi
}

# ─── Add User ─────────────────────────────────────────────────────────────

add_user() {
    init_users

    local username
    read -rp "请输入用户名: " username
    while [[ -z "$username" ]]; do
        read -rp "用户名不能为空，请重新输入: " username
    done

    # Check duplicate
    if jq -e --arg name "$username" '.users[] | select(.name == $name)' "$USERS_FILE" &>/dev/null; then
        echo "用户 $username 已存在"
        return
    fi

    # Select protocols
    local installed_protocols
    installed_protocols=$(jq -r '.protocols | keys[]' "$STATE_FILE" 2>/dev/null)
    if [[ -z "$installed_protocols" ]]; then
        echo "尚未安装任何协议，请先安装协议后再添加用户"
        return
    fi

    echo "已安装的协议:"
    echo "$installed_protocols" | nl -w2 -s'. '
    echo ""
    echo "请选择用户可用的协议（逗号分隔，如 1,3）: "
    read -rp "选择: " proto_selection

    local selected_protocols=()
    IFS=',' read -ra indices <<< "$proto_selection"
    local all_protocols
    all_protocols=$(echo "$installed_protocols" | tr '\n' ' ')
    local idx=0
    for proto in $all_protocols; do
        (( idx++ ))
        for i in "${indices[@]}"; do
            i=$(echo "$i" | tr -d ' ')
            if [[ "$i" == "$idx" ]]; then
                selected_protocols+=("$proto")
            fi
        done
    done

    if [[ ${#selected_protocols[@]} -eq 0 ]]; then
        echo "未选择任何协议"
        return
    fi

    # Generate credentials
    local uuid="" password=""
    local has_uuid_proto=false
    local has_pass_proto=false

    for proto in "${selected_protocols[@]}"; do
        case "$proto" in
            vless-*|vmess-*|tuic) has_uuid_proto=true ;;
            trojan|shadowsocks|hysteria2|shadowtls|anytls) has_pass_proto=true ;;
        esac
    done

    if $has_uuid_proto; then
        uuid=$(gen_uuid)
    fi
    if $has_pass_proto; then
        password=$(gen_password)
    fi

    # Traffic limits
    local monthly_limit=0 total_limit=0
    echo ""
    echo "设置流量限额（0 = 不限制）:"
    read -rp "月度流量限额 (GB, 默认 0): " monthly_input
    monthly_input="${monthly_input:-0}"
    if [[ "$monthly_input" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        monthly_limit=$(awk "BEGIN {printf \"%d\", $monthly_input * 1073741824}")
    fi

    read -rp "总流量限额 (GB, 默认 0): " total_input
    total_input="${total_input:-0}"
    if [[ "$total_input" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        total_limit=$(awk "BEGIN {printf \"%d\", $total_input * 1073741824}")
    fi

    read -rp "每月重置日 (1-28, 默认 1): " reset_day
    reset_day="${reset_day:-1}"

    # Build protocol list JSON
    local proto_json
    proto_json=$(printf '%s\n' "${selected_protocols[@]}" | jq -R . | jq -s .)

    # Add user
    local now
    now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local user_json
    user_json=$(jq -n \
        --arg name "$username" \
        --arg uuid "$uuid" \
        --arg password "$password" \
        --argjson protocols "$proto_json" \
        --arg created_at "$now" \
        --argjson monthly_limit "${monthly_limit:-0}" \
        --argjson total_limit "${total_limit:-0}" \
        --argjson reset_day "${reset_day:-1}" \
        '{
            name: $name,
            uuid: (if $uuid == "" then null else $uuid end),
            password: (if $password == "" then null else $password end),
            protocols: $protocols,
            enabled: true,
            created_at: $created_at,
            traffic_limit_monthly: $monthly_limit,
            traffic_limit_total: $total_limit,
            traffic_used_monthly: 0,
            traffic_used_total: 0,
            monthly_reset_day: $reset_day,
            blocked_at: null
        }')

    jq --argjson user "$user_json" '.users += [$user]' \
        "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

    # Rebuild all affected protocol configs
    for proto in "${selected_protocols[@]}"; do
        rebuild_protocol_config "$proto"
    done

    echo ""
    echo "用户 $username 添加成功！"
    echo "UUID: ${uuid:--}"
    echo "密码: ${password:--}"
    echo "协议: $(IFS=', '; echo "${selected_protocols[*]}")"

    # Generate share links
    for proto in "${selected_protocols[@]}"; do
        generate_share_link "$proto" "$username"
    done
}

# ─── Remove User ──────────────────────────────────────────────────────────

remove_user() {
    init_users

    local users_list
    users_list=$(jq -r '.users[] | "\(.name) (enabled=\(.enabled))"' "$USERS_FILE" 2>/dev/null)
    if [[ -z "$users_list" ]]; then
        echo "暂无用户"
        return
    fi

    echo "现有用户:"
    echo "$users_list" | nl -w2 -s'. '
    echo ""
    read -rp "选择要删除的用户编号: " idx
    idx=$(echo "$idx" | tr -d ' ')

    local username
    username=$(jq -r ".users[$((idx - 1))].name" "$USERS_FILE")

    if [[ -z "$username" ]] || [[ "$username" == "null" ]]; then
        echo "无效的用户编号"
        return
    fi

    echo "确定删除用户 $username？[y/N]"
    read -rp "" confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return

    # Get protocols before removal
    local protos
    protos=$(jq -r --arg name "$username" '.users[] | select(.name == $name) | .protocols[]' "$USERS_FILE")

    # Remove user
    jq --arg name "$username" 'del(.users[] | select(.name == $name))' \
        "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

    # Clean traffic data
    local month
    month=$(date +%Y-%m)
    if [[ -f "${MONTHLY_DIR}/${month}.json" ]]; then
        jq --arg name "$username" 'del(.users[$name])' "${MONTHLY_DIR}/${month}.json" > "${MONTHLY_DIR}/${month}.json.tmp" && \
            mv "${MONTHLY_DIR}/${month}.json.tmp" "${MONTHLY_DIR}/${month}.json"
    fi

    # Rebuild affected protocols
    for proto in $protos; do
        rebuild_protocol_config "$proto"
    done

    echo "用户 $username 已删除"
}

# ─── Toggle User ──────────────────────────────────────────────────────────

toggle_user() {
    init_users

    local users_list
    users_list=$(jq -r '.users[] | "\(.name) (enabled=\(.enabled))"' "$USERS_FILE" 2>/dev/null)
    if [[ -z "$users_list" ]]; then
        echo "暂无用户"
        return
    fi

    echo "现有用户:"
    echo "$users_list" | nl -w2 -s'. '
    echo ""
    read -rp "选择要切换的用户编号: " idx
    idx=$(echo "$idx" | tr -d ' ')

    local username current_enabled
    username=$(jq -r ".users[$((idx - 1))].name" "$USERS_FILE")
    current_enabled=$(jq -r ".users[$((idx - 1))].enabled" "$USERS_FILE")

    if [[ -z "$username" ]] || [[ "$username" == "null" ]]; then
        echo "无效的用户编号"
        return
    fi

    local new_enabled
    if [[ "$current_enabled" == "true" ]]; then
        new_enabled=false
        echo "禁用用户 $username"
    else
        new_enabled=true
        echo "启用用户 $username"
    fi

    jq --arg name "$username" --argjson enabled "$new_enabled" \
        '(.users[] | select(.name == $name)).enabled = $enabled' \
        "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

    # Rebuild affected protocols
    local protos
    protos=$(jq -r --arg name "$username" '.users[] | select(.name == $name) | .protocols[]' "$USERS_FILE")
    for proto in $protos; do
        rebuild_protocol_config "$proto"
    done
}

# ─── Reset User Traffic ───────────────────────────────────────────────────

reset_user_traffic() {
    init_users

    local users_list
    users_list=$(jq -r '.users[] | "\(.name) (used_monthly=\(.traffic_used_monthly), used_total=\(.traffic_used_total))"' "$USERS_FILE" 2>/dev/null)
    if [[ -z "$users_list" ]]; then
        echo "暂无用户"
        return
    fi

    echo "现有用户:"
    echo "$users_list" | nl -w2 -s'. '
    echo ""
    read -rp "选择要重置流量的用户编号: " idx
    idx=$(echo "$idx" | tr -d ' ')

    local username
    username=$(jq -r ".users[$((idx - 1))].name" "$USERS_FILE")

    if [[ -z "$username" ]] || [[ "$username" == "null" ]]; then
        echo "无效的用户编号"
        return
    fi

    echo "确定重置用户 $username 的流量？[y/N]"
    read -rp "" confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return

    jq --arg name "$username" \
        '(.users[] | select(.name == $name)) |= (.traffic_used_monthly = 0 | .traffic_used_total = 0 | .blocked_at = null)' \
        "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

    # Rebuild if was blocked
    local protos
    protos=$(jq -r --arg name "$username" '.users[] | select(.name == $name) | .protocols[]' "$USERS_FILE")
    for proto in $protos; do
        rebuild_protocol_config "$proto"
    done

    echo "用户 $username 的流量已重置"
}

# ─── Set Traffic Limit ────────────────────────────────────────────────────

set_user_traffic_limit() {
    init_users

    local users_list
    users_list=$(jq -r '.users[] | "\(.name) (monthly_limit=\(.traffic_limit_monthly), total_limit=\(.traffic_limit_total))"' "$USERS_FILE" 2>/dev/null)
    if [[ -z "$users_list" ]]; then
        echo "暂无用户"
        return
    fi

    echo "现有用户:"
    echo "$users_list" | nl -w2 -s'. '
    echo ""
    read -rp "选择要设置流量限额的用户编号: " idx
    idx=$(echo "$idx" | tr -d ' ')

    local username
    username=$(jq -r ".users[$((idx - 1))].name" "$USERS_FILE")

    if [[ -z "$username" ]] || [[ "$username" == "null" ]]; then
        echo "无效的用户编号"
        return
    fi

    local monthly_limit total_limit current_limits
    current_limits=$(jq -r --arg name "$username" '.users[] | select(.name == $name) | "月度=\(.traffic_limit_monthly) 总=\(.traffic_limit_total)"' "$USERS_FILE")
    echo "当前限额: $current_limits"
    echo ""

    read -rp "月度流量限额 (GB, 0 = 不限制): " monthly_input
    monthly_input="${monthly_input:-0}"
    if [[ "$monthly_input" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        monthly_limit=$(awk "BEGIN {printf \"%d\", $monthly_input * 1073741824}")
    else
        monthly_limit=0
    fi

    read -rp "总流量限额 (GB, 0 = 不限制): " total_input
    total_input="${total_input:-0}"
    if [[ "$total_input" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        total_limit=$(awk "BEGIN {printf \"%d\", $total_input * 1073741824}")
    else
        total_limit=0
    fi

    jq --arg name "$username" --argjson ml "$monthly_limit" --argjson tl "$total_limit" \
        '(.users[] | select(.name == $name)) |= (.traffic_limit_monthly = $ml | .traffic_limit_total = $tl)' \
        "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

    echo "用户 $username 的流量限额已更新"
}

# ─── List Users ───────────────────────────────────────────────────────────

list_users() {
    init_users

    local count
    count=$(jq '.users | length' "$USERS_FILE" 2>/dev/null)
    if [[ "$count" == "0" ]] || [[ -z "$count" ]]; then
        echo "暂无用户"
        return
    fi

    local month
    month=$(date +%Y-%m)

    printf "%-12s %-8s %-30s %-15s %-15s %-10s\n" "用户名" "状态" "协议" "月使用" "总使用" "月限额"
    printf "%-12s %-8s %-30s %-15s %-15s %-10s\n" "--------" "----" "----" "-------" "------" "------"

    jq -r '.users[] | "\(.name)|\(.enabled)|\(.protocols | join(","))|\(.traffic_used_monthly)|\(.traffic_used_total)|\(.traffic_limit_monthly)|\(.blocked_at)"' "$USERS_FILE" | \
    while IFS='|' read -r name enabled protos used_month used_total limit_month blocked; do
        local status="启用"
        [[ "$enabled" == "false" ]] && status="禁用"
        [[ -n "$blocked" ]] && [[ "$blocked" != "null" ]] && status="封禁"

        local used_m_str
        used_m_str=$(format_bytes "$used_month")
        local used_t_str
        used_t_str=$(format_bytes "$used_total")
        local limit_m_str
        if [[ "$limit_month" == "0" ]]; then
            limit_m_str="不限制"
        else
            limit_m_str=$(format_bytes "$limit_month")
        fi

        printf "%-12s %-8s %-30s %-15s %-15s %-10s\n" "$name" "$status" "$protos" "$used_m_str" "$used_t_str" "$limit_m_str"
    done
}

format_bytes() {
    local bytes="$1"
    if (( bytes >= 1073741824 )); then
        awk "BEGIN {printf \"%.2f GB\", $bytes / 1073741824}"
    elif (( bytes >= 1048576 )); then
        awk "BEGIN {printf \"%.2f MB\", $bytes / 1048576}"
    elif (( bytes >= 1024 )); then
        awk "BEGIN {printf \"%.2f KB\", $bytes / 1024}"
    else
        echo "${bytes} B"
    fi
}
