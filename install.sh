#!/bin/bash
set -euo pipefail

APP_NAME="蝉舒宝.app"
ZIP_NAME="ChanShuBao.zip"
REPO="wangziheng2211222/MergeSASE"
EXPECTED_BUNDLE_ID="com.limayao.chanshubao"
EXPECTED_TEAM_ID="APPLE_TEAM_ID_REQUIRED_BEFORE_RELEASE"
VERSION="${VERSION:-}"
INSTALL_DIR="${INSTALL_DIR:-/Applications}"
INSTALL_PATH="${INSTALL_DIR}/${APP_NAME}"
OPEN_APP="${OPEN_APP:-1}"
WORK_DIR=""
INSTALL_NEEDS_SUDO=0
INSTALL_TRANSACTION_ACTIVE=0
INSTALL_HAD_EXISTING=0
STAGED_PATH=""
BACKUP_PATH=""

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

download_release() {
    local dest="$1"
    local checksum_dest="$2"
    local base_url="https://github.com/${REPO}/releases/download/${VERSION}"
    log "下载指定版本安装包: ${VERSION}"
    curl -fL --connect-timeout 15 --max-time 300 -o "$dest" "${base_url}/${ZIP_NAME}"
    curl -fL --connect-timeout 15 --max-time 60 -o "$checksum_dest" "${base_url}/${ZIP_NAME}.sha256"
}

verify_archive() {
    local archive="$1"
    local checksum_file="$2"
    local expected actual
    expected="$(tr -d '[:space:]' < "$checksum_file")"
    actual="$(shasum -a 256 "$archive" | awk '{print $1}')"
    if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
        err "安装包校验失败，未进行安装"
        exit 1
    fi
}

verify_app() {
    local app_path="$1"
    local actual_version actual_bundle_id actual_team_id
    actual_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app_path/Contents/Info.plist")"
    if [ "$actual_version" != "${VERSION#v}" ]; then
        err "版本不一致：需要 ${VERSION#v}，安装包为 ${actual_version}"
        return 1
    fi
    actual_bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app_path/Contents/Info.plist")"
    if [ "$actual_bundle_id" != "$EXPECTED_BUNDLE_ID" ]; then
        err "应用标识不正确: ${actual_bundle_id}"
        return 1
    fi
    if ! /usr/bin/lipo "$app_path/Contents/MacOS/MergeSASE" -verify_arch arm64 x86_64; then
        err "安装包不是 Intel/Apple Silicon 双架构"
        return 1
    fi
    if ! codesign --verify --deep --strict "$app_path"; then
        err "应用签名校验失败"
        return 1
    fi
    actual_team_id="$(codesign -dv --verbose=4 "$app_path" 2>&1 | awk -F= '/^TeamIdentifier=/{print $2; exit}')"
    if [ "$actual_team_id" != "$EXPECTED_TEAM_ID" ]; then
        err "开发者签名团队不正确"
        return 1
    fi
    if ! spctl -a --type execute "$app_path"; then
        err "Gatekeeper 未认可该应用的签名或公证"
        return 1
    fi
}

verify_system() {
    local os_major architecture
    os_major="$(sw_vers -productVersion | cut -d. -f1)"
    architecture="$(uname -m)"
    if ! [[ "$os_major" =~ ^[0-9]+$ ]] || [ "$os_major" -lt 13 ]; then
        err "蝉舒宝需要 macOS 13 或更高版本"
        exit 1
    fi
    if [ "$architecture" != "arm64" ] && [ "$architecture" != "x86_64" ]; then
        err "不支持当前处理器架构: ${architecture}"
        exit 1
    fi
    if [ "$EXPECTED_TEAM_ID" = "APPLE_TEAM_ID_REQUIRED_BEFORE_RELEASE" ]; then
        err "安装器尚未配置正式 Apple Team ID，发布已被阻止"
        exit 1
    fi
}

run_install_command() {
    if [ "$INSTALL_NEEDS_SUDO" = "1" ]; then
        sudo "$@"
    else
        "$@"
    fi
}

restore_install_transaction() {
    [ "$INSTALL_TRANSACTION_ACTIVE" = "1" ] || return 0
    set +e
    if [ -n "$STAGED_PATH" ]; then
        run_install_command rm -rf "$STAGED_PATH"
    fi

    if [ "$INSTALL_HAD_EXISTING" = "1" ] && [ -e "$BACKUP_PATH" ]; then
        run_install_command rm -rf "$INSTALL_PATH"
        if run_install_command mv "$BACKUP_PATH" "$INSTALL_PATH"; then
            warn "安装未完成，已恢复原版本"
        else
            err "自动恢复失败，原版本备份保留在: ${BACKUP_PATH}"
        fi
    elif [ "$INSTALL_HAD_EXISTING" = "0" ]; then
        run_install_command rm -rf "$INSTALL_PATH"
    elif [ ! -e "$INSTALL_PATH" ]; then
        err "自动恢复失败，请检查备份位置: ${BACKUP_PATH}"
    fi
    INSTALL_TRANSACTION_ACTIVE=0
    set -e
}

cleanup_on_exit() {
    local status=$?
    trap - EXIT INT TERM
    restore_install_transaction
    if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
        rm -rf "$WORK_DIR"
    fi
    exit "$status"
}

copy_app() {
    local app_path="$1"
    STAGED_PATH="${INSTALL_DIR}/.${APP_NAME%.app}.installing.$$.app"
    BACKUP_PATH="${INSTALL_DIR}/.${APP_NAME%.app}.backup.$$.app"
    INSTALL_HAD_EXISTING=0
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

    if [ ! -w "$INSTALL_DIR" ]; then
        warn "写入 /Applications 需要管理员权限"
        INSTALL_NEEDS_SUDO=1
    fi

    run_install_command rm -rf "$STAGED_PATH" "$BACKUP_PATH"
    if ! run_install_command ditto "$app_path" "$STAGED_PATH"; then
        err "复制新版本失败，原版本未改动"
        run_install_command rm -rf "$STAGED_PATH"
        exit 1
    fi
    if ! verify_app "$STAGED_PATH"; then
        err "新版本安装前复验失败，原版本未改动"
        run_install_command rm -rf "$STAGED_PATH"
        exit 1
    fi

    if [ -e "$INSTALL_PATH" ]; then
        INSTALL_HAD_EXISTING=1
    fi
    INSTALL_TRANSACTION_ACTIVE=1

    if [ "$INSTALL_HAD_EXISTING" = "1" ]; then
        if ! run_install_command mv "$INSTALL_PATH" "$BACKUP_PATH"; then
            err "无法备份原版本，安装已取消"
            exit 1
        fi
    fi

    if ! run_install_command mv "$STAGED_PATH" "$INSTALL_PATH"; then
        err "替换应用失败，正在恢复原版本"
        exit 1
    fi
    if [ "$INSTALL_NEEDS_SUDO" = "1" ]; then
        if ! run_install_command chown -R root:wheel "$INSTALL_PATH"; then
            err "设置应用权限失败，正在恢复原版本"
            exit 1
        fi
    fi

    if ! verify_app "$INSTALL_PATH"; then
        err "安装后校验失败，正在恢复原版本"
        exit 1
    fi
    INSTALL_TRANSACTION_ACTIVE=0
    if ! run_install_command rm -rf "$BACKUP_PATH"; then
        warn "新版本已安装，但旧版本备份未能删除: ${BACKUP_PATH}"
    fi
}

main() {
    require_command curl
    require_command ditto
    require_command shasum
    require_command codesign
    require_command spctl
    require_command sw_vers
    require_command uname
    if [ -z "$VERSION" ]; then
        err "必须指定 VERSION，例如 VERSION=2.1"
        exit 1
    fi
    verify_system

    trap cleanup_on_exit EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    WORK_DIR="$(mktemp -d)"

    local zip_path="${WORK_DIR}/${ZIP_NAME}"
    local checksum_path="${WORK_DIR}/${ZIP_NAME}.sha256"
    download_release "$zip_path" "$checksum_path"
    verify_archive "$zip_path" "$checksum_path"

    log "解压安装包"
    ditto -x -k "$zip_path" "$WORK_DIR"

    local app_path
    app_path="$(find "$WORK_DIR" -maxdepth 3 -type d -name "$APP_NAME" -print -quit)"
    if [ -z "$app_path" ]; then
        err "安装包中未找到 ${APP_NAME}"
        exit 1
    fi
    if ! verify_app "$app_path"; then
        exit 1
    fi
    copy_app "$app_path"

    if [ "$OPEN_APP" != "0" ]; then
        log "启动 ${APP_NAME}"
        open "$INSTALL_PATH"
    fi

    echo ""
    echo -e "${GREEN}安装完成:${NC} ${INSTALL_PATH}"
}

main "$@"
