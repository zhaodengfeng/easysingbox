#!/usr/bin/env bash
# lib/traffic.sh — 流量统计与管理

# ─── Traffic Collection ───────────────────────────────────────────────────
#
# sing-box 的 clash_api 不提供直接的每用户统计端点。
# 当前方案：通过 /connections 端点采集活跃连接的上传/下载字节数，
# 计算 delta 增量，均匀分配到该协议下的所有活跃用户。
# 这是近似值，sing-box 未来版本可能提供更精确的 per-user stats。

get_api_port() {
    local protocol="$1"
    local base=$API_SECRET_PORT_BASE
    case "$protocol" in
        vless-reality)  echo $((base + 0)) ;;
        vless-ws)       echo $((base + 1)) ;;
        vless-grpc)     echo $((base + 2)) ;;
        vmess-ws)       echo $((base + 3)) ;;
        trojan)         echo $((base + 4)) ;;
        shadowsocks)    echo $((base + 5)) ;;
        shadowtls)      echo $((base + 6)) ;;
        hysteria2)      echo $((base + 7)) ;;
        tuic)           echo $((base + 8)) ;;
        anytls)         echo $((base + 9)) ;;
        *)              echo $((base + 10)) ;;
    esac
}

collect_all_traffic() {
    [[ -f "$STATE_FILE" ]] || return 0

    local month
    month=$(date +%Y-%m)
    if [[ ! -f "${MONTHLY_DIR}/${month}.json" ]]; then
        atomic_write "${MONTHLY_DIR}/${month}.json" '{"month":"'"$month"'","users":{}}'
    fi
    if [[ ! -f "$TOTAL_FILE" ]]; then
        atomic_write "$TOTAL_FILE" '{}'
    fi

    local protocols
    protocols=$(jq -r '.protocols | to_entries[] | select(.value.status == "running") | .key' "$STATE_FILE" 2>/dev/null)
    [[ -z "$protocols" ]] && return 0

    for protocol in $protocols; do
        local api_port
        api_port=$(get_api_port "$protocol")

        # 获取当前活跃连接总流量
        local connections total_up=0 total_down=0
        connections=$(curl -s --max-time 5 "http://127.0.0.1:${api_port}/connections" 2>/dev/null || echo '{}')

        if [[ "$connections" != "{}" ]] && [[ -n "$connections" ]]; then
            total_up=$(echo "$connections" | jq '[.connections // [] | .[]? | .upload // 0] | add // 0' 2>/dev/null || echo 0)
            total_down=$(echo "$connections" | jq '[.connections // [] | .[]? | .download // 0] | add // 0' 2>/dev/null || echo 0)
        fi

        # 获取上次快照值
        local last_up=0 last_down=0
        last_up=$(jq -r ".traffic_snapshot[\"$protocol\"].total_up // 0" "$STATE_FILE" 2>/dev/null || echo 0)
        last_down=$(jq -r ".traffic_snapshot[\"$protocol\"].total_down // 0" "$STATE_FILE" 2>/dev/null || echo 0)

        # 计算 delta（分别处理，服务重启可能导致单项计数器重置）
        local delta_up=0 delta_down=0
        if (( total_up >= last_up )); then
            delta_up=$(( total_up - last_up ))
        fi
        if (( total_down >= last_down )); then
            delta_down=$(( total_down - last_down ))
        fi

        if (( delta_up > 0 || delta_down > 0 )); then
            # 均匀分配给该协议下的所有活跃用户
            local user_count
            user_count=$(jq --arg proto "$protocol" \
                '[.users[] | select(.enabled == true and .blocked_at == null and (.protocols | index($proto)))] | length' \
                "$USERS_FILE" 2>/dev/null || echo 1)
            (( user_count == 0 )) && user_count=1 || true

            local per_user_up=$(( delta_up / user_count ))
            local per_user_down=$(( delta_down / user_count ))
            local per_user_total=$(( per_user_up + per_user_down ))

            # 获取活跃用户名列表 (JSON array)
            local users_on_proto
            users_on_proto=$(jq -r --arg proto "$protocol" \
                '[.users[] | select(.enabled == true and .blocked_at == null and (.protocols | index($proto))) | .name]' \
                "$USERS_FILE" 2>/dev/null)

            if [[ -n "$users_on_proto" ]] && [[ "$users_on_proto" != "[]" ]] && [[ "$users_on_proto" != "null" ]]; then
                # 更新 monthly JSON — 单次 jq 调用
                jq --argjson per_up "$per_user_up" --argjson per_down "$per_user_down" --argjson names "$users_on_proto" '
                    reduce $names[] as $name (.; .users[$name].up = ((.users[$name].up // 0) + $per_up) | .users[$name].down = ((.users[$name].down // 0) + $per_down))
                ' "${MONTHLY_DIR}/${month}.json" > "${MONTHLY_DIR}/${month}.json.tmp" && \
                    mv "${MONTHLY_DIR}/${month}.json.tmp" "${MONTHLY_DIR}/${month}.json"

                # 更新 total.json — 单次 jq 调用
                jq --argjson per_up "$per_user_up" --argjson per_down "$per_user_down" --argjson names "$users_on_proto" '
                    reduce $names[] as $name (.; .[$name].up = ((.[$name].up // 0) + $per_up) | .[$name].down = ((.[$name].down // 0) + $per_down))
                ' "$TOTAL_FILE" > "${TOTAL_FILE}.tmp" && mv "${TOTAL_FILE}.tmp" "$TOTAL_FILE"

                # 更新 users.json — 单次 jq 调用批量更新
                jq --arg proto "$protocol" --argjson delta "$per_user_total" '
                    (.users[] | select(.enabled == true and .blocked_at == null and (.protocols | index($proto)))) |= (
                        .traffic_used_monthly += $delta |
                        .traffic_used_total += $delta
                    )
                ' "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"
            fi

            # 更新快照
            local snapshot_ts
            snapshot_ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            jq ".traffic_snapshot[\"$protocol\"] = {\"total_up\": $total_up, \"total_down\": $total_down, \"snapshot_at\": \"$snapshot_ts\"}" \
                "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
        fi
    done
}

# ─── Cron Setup ───────────────────────────────────────────────────────────

setup_traffic_cron() {
    local cron_file="/etc/cron.d/easysingbox-traffic"

    # Always rewrite to ensure correctness (idempotent)
    cat > "$cron_file" <<EOF
*/5 * * * * root ${INSTALL_DIR}/easysingbox.sh --collect-traffic
0 0 * * * root ${INSTALL_DIR}/easysingbox.sh --monthly-reset
EOF
    chmod 644 "$cron_file"
}

# ─── Traffic Limits Check ─────────────────────────────────────────────────

check_traffic_limits() {
    [[ -f "$USERS_FILE" ]] || return 0

    # 一次性获取所有需要检查的用户数据
    local check_data
    check_data=$(jq -r '
        .users[] |
        select(.enabled == true and .blocked_at == null) |
        "\(.name)|\(.traffic_used_monthly)|\(.traffic_limit_monthly)|\(.traffic_used_total)|\(.traffic_limit_total)|\(.protocols | join(","))"
    ' "$USERS_FILE" 2>/dev/null)

    [[ -z "$check_data" ]] && return 0

    echo "$check_data" | while IFS='|' read -r username used_month limit_month used_total limit_total protos; do
        local blocked=false
        if [[ "$limit_month" != "0" ]] && (( used_month > limit_month )); then
            blocked=true
            echo "[流量限额] 用户 $username 月度流量超限: $(format_bytes "$used_month") / $(format_bytes "$limit_month")"
        fi
        if [[ "$limit_total" != "0" ]] && (( used_total > limit_total )); then
            blocked=true
            echo "[流量限额] 用户 $username 总流量超限: $(format_bytes "$used_total") / $(format_bytes "$limit_total")"
        fi

        if $blocked; then
            local now
            now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
            jq --arg name "$username" --arg now "$now" \
                '(.users[] | select(.name == $name)).blocked_at = $now' \
                "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

            # 重建受影响的协议
            if [[ -n "$protos" ]]; then
                for proto in $(echo "$protos" | tr ',' ' '); do
                    rebuild_protocol_config "$proto"
                done
            fi
        fi
    done
}

# ─── Monthly Traffic Reset ────────────────────────────────────────────────

monthly_traffic_reset() {
    [[ -f "$USERS_FILE" ]] || return 0

    local day
    day=$(date +%d)
    local month
    month=$(date +%Y-%m)

    # 获取所有用户数据一次性
    local user_data
    user_data=$(jq -r '.users[] | "\(.name)|\(.monthly_reset_day)|\(.last_monthly_reset // "")|\(.blocked_at)|\(.protocols | join(","))"' "$USERS_FILE" 2>/dev/null)
    [[ -z "$user_data" ]] && return 0

    echo "$user_data" | while IFS='|' read -r username reset_day last_reset was_blocked protos; do
        if [[ "$day" == "$reset_day" ]] && [[ "$last_reset" != "$month" ]]; then
            # 重置月度用量
            jq --arg name "$username" --arg month "$month" \
                '(.users[] | select(.name == $name)) |= (.traffic_used_monthly = 0 | .last_monthly_reset = $month)' \
                "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"

            # 如果被封禁，自动解封
            if [[ -n "$was_blocked" ]] && [[ "$was_blocked" != "null" ]]; then
                jq --arg name "$username" \
                    '(.users[] | select(.name == $name)).blocked_at = null' \
                    "$USERS_FILE" > "${USERS_FILE}.tmp" && mv "${USERS_FILE}.tmp" "$USERS_FILE"
                echo "[月度重置] 用户 $username 月度流量已重置，自动解封"

                # 重建协议
                if [[ -n "$protos" ]]; then
                    for proto in $(echo "$protos" | tr ',' ' '); do
                        rebuild_protocol_config "$proto"
                    done
                fi
            else
                echo "[月度重置] 用户 $username 月度流量已重置"
            fi
        fi
    done
}

# ─── View Traffic Stats ───────────────────────────────────────────────────

view_traffic_stats() {
    local month
    month=$(date +%Y-%m)

    echo "流量统计"
    echo "  1. 本月流量 ($month)"
    echo "  2. 累计总流量"
    echo "  3. 历史月份"
    echo "  0. 返回"
    echo ""
    read -rp "请选择: " choice

    case "$choice" in
        1) show_monthly_traffic "$month" ;;
        2) show_total_traffic ;;
        3) show_history_months ;;
        0) ;;
        *) echo "无效选项" ;;
    esac
}

show_monthly_traffic() {
    local month="${1:-$(date +%Y-%m)}"
    local monthly_file="${MONTHLY_DIR}/${month}.json"

    if [[ ! -f "$monthly_file" ]]; then
        echo "暂无 $month 的流量数据"
        return
    fi

    echo ""
    echo "=== $month 月流量统计 ==="
    printf "%-12s %-15s %-15s %-15s\n" "用户名" "上行" "下行" "合计"
    printf "%-12s %-15s %-15s %-15s\n" "--------" "----" "----" "----"

    jq -r '.users | to_entries[] | "\(.key)|\(.value.up)|\(.value.down)"' "$monthly_file" 2>/dev/null | \
    while IFS='|' read -r name up down; do
        local total=$((up + down))
        printf "%-12s %-15s %-15s %-15s\n" "$name" "$(format_bytes "$up")" "$(format_bytes "$down")" "$(format_bytes "$total")"
    done
    echo ""
    read -rp "按回车键继续..." _
}

show_total_traffic() {
    if [[ ! -f "$TOTAL_FILE" ]]; then
        echo "暂无累计流量数据"
        return
    fi

    echo ""
    echo "=== 累计总流量 ==="
    printf "%-12s %-15s %-15s %-15s\n" "用户名" "上行" "下行" "合计"
    printf "%-12s %-15s %-15s %-15s\n" "--------" "----" "----" "----"

    jq -r 'to_entries[] | "\(.key)|\(.value.up)|\(.value.down)"' "$TOTAL_FILE" 2>/dev/null | \
    while IFS='|' read -r name up down; do
        local total=$((up + down))
        printf "%-12s %-15s %-15s %-15s\n" "$name" "$(format_bytes "$up")" "$(format_bytes "$down")" "$(format_bytes "$total")"
    done
    echo ""
    read -rp "按回车键继续..." _
}

show_history_months() {
    echo ""
    echo "=== 历史月份 ==="
    if [[ -d "$MONTHLY_DIR" ]]; then
        ls -1 "$MONTHLY_DIR" | grep -E '^[0-9]{4}-[0-9]{2}\.json$' | sed 's/\.json$//' | sort -r | nl -w2 -s'. '
    else
        echo "暂无历史数据"
    fi
    echo ""
    read -rp "选择要查看的月份编号 (0 返回): " idx
    idx=$(echo "$idx" | tr -d ' ')
    [[ "$idx" == "0" ]] && return

    local month
    month=$(ls -1 "$MONTHLY_DIR" | grep -E '^[0-9]{4}-[0-9]{2}\.json$' | sed 's/\.json$//' | sort -r | sed -n "${idx}p")
    if [[ -n "$month" ]]; then
        show_monthly_traffic "$month"
    fi
}
