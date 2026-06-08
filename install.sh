#!/bin/bash
set -euo pipefail

APP_NAME="MergeSASE&OpenVPN.app"
ZIP_NAME="MergeSASE-OpenVPN.zip"
REPO="wangziheng2211222/MergeSASE"
VERSION="${VERSION:-latest}"
ZIP_URL="${ZIP_URL:-}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
INSTALL_PATH="${INSTALL_DIR}/${APP_NAME}"
OPEN_APP="${OPEN_APP:-1}"
WORK_DIR=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err() { echo -e "${RED}[x]${NC} $1" >&2; }

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        err "缺少命令: $1"
        exit 1
    fi
}

download_latest_release() {
    local dest="$1"
    local url
    local fallback_url="https://raw.githubusercontent.com/${REPO}/main/${ZIP_NAME}"
    if [ -n "$ZIP_URL" ]; then
        url="$ZIP_URL"
    elif [ "$VERSION" = "latest" ]; then
        url="https://github.com/${REPO}/releases/latest/download/${ZIP_NAME}"
    else
        url="https://github.com/${REPO}/releases/download/${VERSION}/${ZIP_NAME}"
    fi
    log "下载安装包: ${url}"
    if curl -fL --connect-timeout 15 --max-time 300 -o "$dest" "$url"; then
        return
    fi

    if [ -z "$ZIP_URL" ]; then
        warn "GitHub Releases 下载失败，尝试备用下载源"
        log "下载安装包: ${fallback_url}"
        if curl -fL --connect-timeout 15 --max-time 300 -o "$dest" "$fallback_url"; then
            return
        fi
    fi

    err "下载失败。请稍后重试，或手动下载 https://github.com/${REPO}/raw/main/${ZIP_NAME}"
    exit 1
}

copy_app() {
    local app_path="$1"
    if [ ! -d "$app_path" ]; then
        err "未找到 App: $app_path"
        exit 1
    fi

    log "安装到 ${INSTALL_PATH}"
    if [ ! -d "$INSTALL_DIR" ]; then
        if mkdir -p "$INSTALL_DIR" 2>/dev/null; then
            :
        else
            warn "创建 ${INSTALL_DIR} 需要管理员权限"
            sudo mkdir -p "$INSTALL_DIR"
        fi
    fi

    if [ -w "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_PATH"
        cp -R "$app_path" "$INSTALL_PATH"
    else
        warn "写入 /Applications 需要管理员权限"
        sudo rm -rf "$INSTALL_PATH"
        sudo cp -R "$app_path" "$INSTALL_PATH"
        sudo chown -R root:wheel "$INSTALL_PATH"
    fi

    xattr -cr "$INSTALL_PATH" 2>/dev/null || true
}

main() {
    require_command curl
    require_command ditto

    WORK_DIR="$(mktemp -d)"
    trap 'rm -rf "$WORK_DIR"' EXIT

    local script_dir=""
    local source_path="${BASH_SOURCE[0]:-}"
    if [ -n "$source_path" ] && [ "$source_path" != "bash" ] && [ -f "$source_path" ]; then
        script_dir="$(cd "$(dirname "$source_path")" && pwd)"
    fi

    local zip_path=""
    if [ -n "$script_dir" ] && [ -f "${script_dir}/${ZIP_NAME}" ]; then
        zip_path="${script_dir}/${ZIP_NAME}"
        log "使用本地安装包: ${zip_path}"
    else
        zip_path="${WORK_DIR}/${ZIP_NAME}"
        download_latest_release "$zip_path"
    fi

    log "解压安装包"
    ditto -x -k "$zip_path" "$WORK_DIR"

    local app_path
    app_path="$(find "$WORK_DIR" -maxdepth 3 -type d -name "$APP_NAME" -print -quit)"
    copy_app "$app_path"

    if [ "$OPEN_APP" != "0" ]; then
        log "启动 ${APP_NAME}"
        open "$INSTALL_PATH"
    fi

    echo ""
    echo -e "${GREEN}安装完成:${NC} ${INSTALL_PATH}"
}

main "$@"
