#!/usr/bin/env bash
# lib/install.sh — sing-box 安装与升级

install_singbox() {
    local version="${1:-latest}"
    local arch
    arch=$(detect_arch)
    local os
    os=$(detect_os)

    echo "正在获取 sing-box 最新版本 ..."

    local api_url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    local tag
    tag=$(curl -s --connect-timeout 10 "$api_url" | jq -r '.tag_name' 2>/dev/null)

    if [[ -z "$tag" ]] || [[ "$tag" == "null" ]]; then
        echo "获取 sing-box 版本失败"
        return 1
    fi

    # Remove leading 'v' if present
    local clean_version="${tag#v}"

    echo "最新版本: $clean_version，正在下载 ..."

    local filename="sing-box-${clean_version}-linux-${arch}.tar.gz"
    local download_url="https://github.com/SagerNet/sing-box/releases/download/${tag}/${filename}"
    local tmp_dir
    tmp_dir=$(mktemp -d) || { echo "创建临时目录失败"; return 1; }

    # 下载 tar.gz 文件
    if ! curl -fSL --connect-timeout 10 --max-time 120 \
         -o "${tmp_dir}/${filename}" "$download_url"; then
        echo "下载失败: $download_url"
        rm -rf "$tmp_dir"
        return 1
    fi

    echo "正在解压 ..."
    if ! tar -xzf "${tmp_dir}/${filename}" -C "$tmp_dir"; then
        echo "解压失败"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Create directories
    mkdir -p "${INSTALL_DIR}/bin"

    # Find and copy binary
    local binary
    binary=$(find "$tmp_dir" -name "sing-box" -type f 2>/dev/null | head -1)
    if [[ -z "$binary" ]]; then
        # Try direct path
        binary="${tmp_dir}/sing-box-${clean_version}-linux-${arch}/sing-box"
    fi

    if [[ -z "$binary" ]] || [[ ! -f "$binary" ]]; then
        echo "找不到 sing-box 二进制文件"
        ls -la "$tmp_dir"
        rm -rf "$tmp_dir"
        return 1
    fi

    chmod +x "$binary"
    mv "$binary" "${INSTALL_DIR}/bin/sing-box"

    # 验证二进制文件可执行
    if ! "${INSTALL_DIR}/bin/sing-box" version &>/dev/null; then
        echo "错误: sing-box 二进制文件验证失败"
        rm -rf "$tmp_dir"
        return 1
    fi

    # Update state
    if [[ -f "$STATE_FILE" ]]; then
        jq --arg version "$clean_version" '.version = $version' \
            "$STATE_FILE" > "${STATE_FILE}.tmp" && mv "${STATE_FILE}.tmp" "$STATE_FILE"
    else
        local now
        now=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
        atomic_write "$STATE_FILE" "{\"version\":\"${clean_version}\",\"installed_at\":\"${now}\",\"protocols\":{},\"traffic_snapshot\":{}}"
    fi

    rm -rf "$tmp_dir"
    echo "sing-box $clean_version 安装成功"
    return 0
}

upgrade_singbox() {
    local current_version
    if [[ -f "$STATE_FILE" ]]; then
        current_version=$(jq -r '.version // "unknown"' "$STATE_FILE")
    else
        current_version="unknown"
    fi

    echo "当前版本: $current_version"

    local api_url="https://api.github.com/repos/SagerNet/sing-box/releases/latest"
    local tag
    tag=$(curl -s "$api_url" | jq -r '.tag_name' 2>/dev/null)

    if [[ -z "$tag" ]] || [[ "$tag" == "null" ]]; then
        echo "获取最新版本失败"
        return 1
    fi

    local latest="${tag#v}"

    if [[ "$current_version" == "$latest" ]]; then
        echo "已是最新版本: $current_version"
        return 0
    fi

    echo "发现新版本: $latest，是否升级？[y/N]"
    read -rp "" confirm
    [[ "$confirm" =~ ^[Yy]$ ]] || return 0

    # Stop all services
    echo "正在停止所有服务 ..."
    for protocol in $(jq -r '.protocols | keys[]' "$STATE_FILE" 2>/dev/null); do
        stop_service "$protocol"
    done

    # Backup binary
    if [[ -f "${INSTALL_DIR}/bin/sing-box" ]]; then
        cp "${INSTALL_DIR}/bin/sing-box" "${INSTALL_DIR}/bin/sing-box.bak"
    fi

    # Install new version (config is preserved)
    if ! install_singbox "$latest"; then
        echo "升级失败，回滚到旧版本 ..."
        if [[ -f "${INSTALL_DIR}/bin/sing-box.bak" ]]; then
            mv "${INSTALL_DIR}/bin/sing-box.bak" "${INSTALL_DIR}/bin/sing-box"
        fi
        # Restart services with rolled-back binary
        echo "正在重启所有服务 ..."
        for protocol in $(jq -r '.protocols | keys[]' "$STATE_FILE" 2>/dev/null); do
            if [[ -d "${CONFIG_DIR}/${protocol}" ]]; then
                start_service "$protocol"
            fi
        done
        return 1
    fi

    # Clean backup
    rm -f "${INSTALL_DIR}/bin/sing-box.bak"

    # Restart all services
    echo "正在重启所有服务 ..."
    for protocol in $(jq -r '.protocols | keys[]' "$STATE_FILE" 2>/dev/null); do
        if [[ -d "${CONFIG_DIR}/${protocol}" ]]; then
            start_service "$protocol"
        fi
    done

    echo "升级完成: $current_version → $latest"
}

upgrade_singbox_menu() {
    upgrade_singbox
}

ensure_singbox_installed() {
    if [[ ! -f "${INSTALL_DIR}/bin/sing-box" ]]; then
        echo "sing-box 未安装，正在安装 ..."
        install_singbox
    fi

    # Ensure IPv6 kernel support is enabled (sing-box route monitor requires AF_INET6)
    ensure_ipv6

    # Check dependencies
    for cmd in jq openssl curl; do
        if ! command -v "$cmd" &>/dev/null; then
            echo "正在安装 $cmd ..."
            local pkg_mgr
            pkg_mgr=$(get_package_manager)
            case "$pkg_mgr" in
                apt)  apt-get update -qq && apt-get install -y -qq "$cmd" ;;
                yum)  yum install -y -q "$cmd" ;;
                dnf)  dnf install -y -q "$cmd" ;;
                apk)  apk add --quiet "$cmd" ;;
                *)    echo "无法安装 $cmd，请手动安装"; exit 1 ;;
            esac
        fi
    done

    # Optional: qrencode for QR codes
    if ! command -v qrencode &>/dev/null; then
        local pkg_mgr
        pkg_mgr=$(get_package_manager)
        case "$pkg_mgr" in
            apt)  apt-get install -y -qq qrencode 2>/dev/null || true ;;
            yum)  yum install -y -q qrencode 2>/dev/null || true ;;
            dnf)  dnf install -y -q qrencode 2>/dev/null || true ;;
            apk)  apk add --quiet qrencode 2>/dev/null || true ;;
        esac
    fi
}
