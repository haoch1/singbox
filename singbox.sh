#!/usr/bin/env bash
# shellcheck disable=SC2015
set -uo pipefail

umask 077
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

SCRIPT_VERSION="0.3.2"
SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/haoch1/singbox/main/singbox.sh}"
SINGBOX_DIR="${SINGBOX_DIR:-/usr/local/etc/sing-box}"
SINGBOX_BIN="${SINGBOX_BIN:-}"
CORE_INSTALL_BIN="/usr/local/bin/sing-box"
REALM_SCRIPT_TARGET="/usr/local/bin/r"
REALM_SCRIPT_URL="https://raw.githubusercontent.com/haoch1/realm/main/realm.sh"
REALM_DIR="/root/realm"
REALM_UNIT="/etc/systemd/system/realm.service"
REALM_SYSTEMD_STARTUP="/etc/systemd/system/multi-user.target.wants/realm.service"
REALM_OPENRC_UNIT="/etc/init.d/realm"
REALM_RUNLEVEL="/etc/runlevels/default/realm"
REALM_LOG="/var/log/realm.log"
REALM_LOCK="/run/lock/realm-manager.lock"
CONFIG_FILE="$SINGBOX_DIR/config.json"
META_FILE="$SINGBOX_DIR/nodes.json"
PID_FILE="${SINGBOX_PID_FILE:-/run/sing-box/sing-box.pid}"
LOG_FILE="${SINGBOX_LOG_FILE:-/var/log/sing-box.log}"
LOCK_FILE="${SINGBOX_LOCK_FILE:-/run/lock/singbox-manager.lock}"
LOCK_PID_FILE="${SINGBOX_LOCK_PID_FILE:-/run/lock/singbox-manager.pid}"
SYSTEMD_UNIT="/etc/systemd/system/sing-box.service"
SYSTEMD_STARTUP="/etc/systemd/system/multi-user.target.wants/sing-box.service"
OPENRC_UNIT="/etc/init.d/sing-box"
OPENRC_STARTUP="/etc/runlevels/default/sing-box"
DEFAULT_PORT=8443
DEFAULT_SNI="www.bing.com"
INIT_SYSTEM="direct"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'; BLUE=$'\033[1;36m'; NC=$'\033[0m'

fail() { printf '  %s[错误] %s%s\n' "$RED" "$*" "$NC" >&2; return 1; }
info() { printf '  %s[信息] %s%s\n' "$CYAN" "$*" "$NC"; }
warn() { printf '  %s[注意] %s%s\n' "$YELLOW" "$*" "$NC"; }
success() { printf '  %s[成功] %s%s\n' "$GREEN" "$*" "$NC"; }
interrupt_exit() { printf '\n'; exit 130; }

clear_terminal() {
    [[ -t 1 ]] || return 0
    command -v clear >/dev/null 2>&1 && clear 2>/dev/null || true
    printf '\033[3J\033[2J\033[H\033[0m'
}

lock_fd_is_inherited() {
    local fd_target lock_target
    [[ -e "/proc/$$/fd/9" ]] || return 1
    command -v readlink >/dev/null 2>&1 || return 1
    fd_target=$(readlink -f "/proc/$$/fd/9" 2>/dev/null || true)
    lock_target=$(readlink -f "$LOCK_FILE" 2>/dev/null || true)
    [[ -n "$fd_target" && -n "$lock_target" && "$fd_target" == "$lock_target" ]]
}

lock_owner_pid() {
    local owner=''
    [[ -r "$LOCK_PID_FILE" ]] && owner=$(cat "$LOCK_PID_FILE" 2>/dev/null || true)
    printf '%s' "$owner"
}

cleanup_lock() {
    local owner; owner=$(lock_owner_pid)
    [[ "$owner" == "$$" ]] && rm -f -- "$LOCK_PID_FILE"
    exec 9>&- 2>/dev/null || true
}

acquire_manager_lock() {
    local owner
    mkdir -p "$(dirname "$LOCK_FILE")" || { fail '无法创建管理锁目录'; return 1; }
    if lock_fd_is_inherited; then
        printf '%s\n' "$$" > "$LOCK_PID_FILE" || { fail '无法写入管理锁 PID'; return 1; }
        trap cleanup_lock EXIT
        return 0
    fi
    exec 9>"$LOCK_FILE" || { fail '无法打开管理锁'; return 1; }
    if ! flock -n 9; then
        owner=$(lock_owner_pid)
        if [[ "$owner" =~ ^[0-9]+$ ]] && ! kill -0 "$owner" 2>/dev/null; then
            exec 9>&-
            exec 9>"$LOCK_FILE" || { fail '无法重新打开管理锁'; return 1; }
            flock -n 9 || {
                owner=$(lock_owner_pid)
                fail '已有 sing-box 管理脚本实例正在运行'
                info "当前实例 PID: ${owner:-未知}"
                exec 9>&-
                return 1
            }
        else
            fail '已有 sing-box 管理脚本实例正在运行'
            info "当前实例 PID: ${owner:-未知}"
            exec 9>&-
            return 1
        fi
    fi
    printf '%s\n' "$$" > "$LOCK_PID_FILE" || { exec 9>&-; fail '无法写入管理锁 PID'; return 1; }
    trap cleanup_lock EXIT
}

read_input() {
    local dest="$1" prompt="$2" value='' status=0
    read -r -p "$prompt" value || status=$?
    (( status == 130 )) && return 130
    (( status != 0 )) && { INPUT_EOF=1; return "$status"; }
    [[ "$value" == [qQ] ]] && { MENU_CANCELLED=1; return 1; }
    printf -v "$dest" '%s' "$value"
}

pause_enter() {
    local prompt="${1:-  按回车返回主菜单...}" status=0
    read -r -p "$prompt" _ || status=$?
    (( status == 130 )) && interrupt_exit
    (( status != 0 )) && INPUT_EOF=1
    return 0
}

install_packages() {
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y bash ca-certificates curl jq tar coreutils util-linux iproute2 procps
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache bash ca-certificates curl jq tar coreutils util-linux iproute2 procps
    elif command -v dnf >/dev/null 2>&1; then
        dnf install -y bash ca-certificates curl jq tar coreutils util-linux iproute procps-ng
    elif command -v yum >/dev/null 2>&1; then
        yum install -y bash ca-certificates curl jq tar coreutils util-linux iproute procps-ng
    else
        fail '无法识别包管理器，需要 apt-get、apk、dnf 或 yum'
        return 1
    fi
}

ensure_dependencies() {
    local required=(curl jq tar sha256sum flock ss timeout)
    local missing=0 cmd
    for cmd in "${required[@]}"; do command -v "$cmd" >/dev/null 2>&1 || missing=1; done
    (( missing == 0 )) || install_packages || return 1
    for cmd in "${required[@]}"; do command -v "$cmd" >/dev/null 2>&1 || { fail "缺少依赖: $cmd"; return 1; }; done
}

detect_init() {
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
        INIT_SYSTEM=systemd
    elif command -v rc-service >/dev/null 2>&1 && command -v rc-update >/dev/null 2>&1 && command -v openrc-run >/dev/null 2>&1; then
        INIT_SYSTEM=openrc
    else
        INIT_SYSTEM=direct
    fi
}

svc_active() {
    case "$INIT_SYSTEM" in
        systemd) systemctl is-active --quiet sing-box ;;
        openrc) rc-service sing-box status >/dev/null 2>&1 ;;
        direct)
            [[ -s "$PID_FILE" ]] || return 1
            local pid; pid=$(cat "$PID_FILE" 2>/dev/null || true)
            [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 1
            [[ -r "/proc/$pid/cmdline" ]] && tr '\0' ' ' < "/proc/$pid/cmdline" | grep -Fq "$SINGBOX_BIN"
            ;;
    esac
}

svc_enabled() {
    case "$INIT_SYSTEM" in
        systemd) systemctl is-enabled --quiet sing-box ;;
        openrc) rc-update show default 2>/dev/null | grep -Eq '(^|[[:space:]])sing-box([[:space:]]|$)' ;;
        direct) return 1 ;;
    esac
}

svc_reload() { [[ "$INIT_SYSTEM" == systemd ]] && systemctl daemon-reload >/dev/null 2>&1 || true; }

svc_enable() {
    case "$INIT_SYSTEM" in
        systemd) systemctl enable sing-box >/dev/null 2>&1 ;;
        openrc) rc-update add sing-box default >/dev/null 2>&1 ;;
        direct) return 0 ;;
    esac
}

svc_disable() {
    case "$INIT_SYSTEM" in
        systemd) systemctl disable sing-box >/dev/null 2>&1 ;;
        openrc) rc-update del sing-box default >/dev/null 2>&1 ;;
        direct) return 0 ;;
    esac
}

svc_start() {
    case "$INIT_SYSTEM" in
        systemd) systemctl start sing-box >/dev/null 2>&1 ;;
        openrc) rc-service sing-box start >/dev/null 2>&1 ;;
        direct)
            mkdir -p "$(dirname "$PID_FILE")" || return 1
            mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
            rm -f "$PID_FILE"
            nohup "$SINGBOX_BIN" run -c "$CONFIG_FILE" >>"$LOG_FILE" 2>&1 </dev/null &
            printf '%s\n' "$!" > "$PID_FILE"
            sleep 1
            svc_active
            ;;
    esac
}

svc_stop() {
    case "$INIT_SYSTEM" in
        systemd) systemctl stop sing-box >/dev/null 2>&1 ;;
        openrc) rc-service sing-box stop >/dev/null 2>&1 ;;
        direct)
            local pid=''
            [[ -s "$PID_FILE" ]] && pid=$(cat "$PID_FILE" 2>/dev/null || true)
            [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null || true
            rm -f "$PID_FILE"
            ;;
    esac
}

svc_restart() {
    case "$INIT_SYSTEM" in
        systemd) systemctl restart sing-box >/dev/null 2>&1 ;;
        openrc) rc-service sing-box restart >/dev/null 2>&1 ;;
        direct) svc_stop; sleep 1; svc_start ;;
    esac
}

write_service_unit() {
    if [[ "$INIT_SYSTEM" == systemd ]]; then
        mkdir -p "${SYSTEMD_UNIT%/*}" || return 1
        printf '%s\n' '[Unit]' 'Description=sing-box service' 'After=network-online.target' 'Wants=network-online.target' '[Service]' "ExecStart=$SINGBOX_BIN run -c $CONFIG_FILE" 'Restart=on-failure' 'RestartSec=3' 'LimitNOFILE=1048576' '[Install]' 'WantedBy=multi-user.target' > "$SYSTEMD_UNIT" || return 1
        chmod 644 "$SYSTEMD_UNIT" || return 1
        svc_reload
    elif [[ "$INIT_SYSTEM" == openrc ]]; then
        printf '%s\n' '#!/sbin/openrc-run' 'description="sing-box service"' "command=\"$SINGBOX_BIN\"" "command_args=\"run -c $CONFIG_FILE\"" 'supervisor="supervise-daemon"' 'respawn_delay=3' "output_log=\"$LOG_FILE\"" "error_log=\"$LOG_FILE\"" 'depend() { use net }' > "$OPENRC_UNIT" || return 1
        chmod 755 "$OPENRC_UNIT" || return 1
    fi
}

get_url() {
    local url="$1" output="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fLsS --retry 2 --connect-timeout 15 --max-time 180 --proto '=https' --proto-redir '=https' "$url" -o "$output"
    elif command -v wget >/dev/null 2>&1; then
        wget -qO "$output" "$url"
    else
        return 1
    fi
}

valid_port() { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_text() { [[ -n "$1" && "$1" != *[[:space:]/\\]* && "$1" != *[[:cntrl:]]* ]]; }
valid_name() { [[ -n "$1" && ${#1} -le 80 && "$1" != *[[:cntrl:]]* ]]; }

uri_escape() { printf '%s' "$1" | jq -sRr @uri; }

format_server_for_uri() {
    local server="$1"
    [[ "$server" == *:* && "$server" != \[*\] ]] && printf '[%s]' "$server" || printf '%s' "$server"
}

server_ip_guess() {
    local ip=''
    ip=$(curl -4fsS --max-time 4 https://api.ipify.org 2>/dev/null || true)
    [[ -n "$ip" ]] || ip=$(curl -4fsS --max-time 4 https://icanhazip.com 2>/dev/null || true)
    [[ -n "$ip" ]] || ip=$(curl -6fsS --max-time 4 https://api64.ipify.org 2>/dev/null || true)
    printf '%s' "${ip//$'\n'/}"
}

resolve_core() {
    local candidate discovered=''
    if [[ -n "$SINGBOX_BIN" && -x "$SINGBOX_BIN" ]]; then return 0; fi
    if discovered=$(command -v sing-box 2>/dev/null); then
        [[ -x "$discovered" ]] && { SINGBOX_BIN="$discovered"; return 0; }
    fi
    for candidate in /usr/local/bin/sing-box /usr/bin/sing-box /usr/local/sbin/sing-box /usr/sbin/sing-box; do
        [[ -x "$candidate" ]] && { SINGBOX_BIN="$candidate"; return 0; }
    done
    SINGBOX_BIN="$CORE_INSTALL_BIN"
    return 1
}

core_version() {
    resolve_core >/dev/null 2>&1 || true
    [[ -x "$SINGBOX_BIN" ]] || { printf '未安装'; return; }
    local v; v=$("$SINGBOX_BIN" version 2>/dev/null | sed -n 's/^sing-box version \([^[:space:]]*\).*/\1/p' | head -n 1)
    [[ -n "$v" ]] && printf 'v%s' "$v" || printf '未知'
}

init_state() {
    mkdir -p "$SINGBOX_DIR" || return 1
    chmod 700 "$SINGBOX_DIR" 2>/dev/null || true
    [[ -s "$CONFIG_FILE" ]] || printf '%s\n' '{"log":{"level":"info","timestamp":true},"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}' > "$CONFIG_FILE"
    [[ -s "$META_FILE" ]] || printf '%s\n' '{"nodes":[]}' > "$META_FILE"
    jq -e 'type == "object" and (.inbounds|type == "array") and (.outbounds|type == "array")' "$CONFIG_FILE" >/dev/null 2>&1 || { fail "配置文件格式无效: $CONFIG_FILE"; return 1; }
    jq -e 'type == "object" and (.nodes|type == "array")' "$META_FILE" >/dev/null 2>&1 || { fail "节点元数据格式无效: $META_FILE"; return 1; }
    chmod 600 "$CONFIG_FILE" "$META_FILE" 2>/dev/null || true
}

node_count() { jq -r '.nodes | length' "$META_FILE"; }

port_conflict() {
    local port="$1" exclude="${2:-}"
    jq -e --argjson p "$port" --arg e "$exclude" '.nodes[]? | select((.port|tonumber) == $p and .tag != $e)' "$META_FILE" >/dev/null 2>&1 && return 0
    if command -v ss >/dev/null 2>&1; then
        ss -H -ltn 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {found=1} END {exit !found}' && return 0
    fi
    return 1
}

generate_credentials() {
    NEW_UUID=$("$SINGBOX_BIN" generate uuid 2>/dev/null) || return 1
    local pair; pair=$("$SINGBOX_BIN" generate reality-keypair 2>/dev/null) || return 1
    NEW_PRIVATE=$(awk '/PrivateKey/ {print $NF}' <<< "$pair")
    NEW_PUBLIC=$(awk '/PublicKey/ {print $NF}' <<< "$pair")
    NEW_SHORT_ID=$("$SINGBOX_BIN" generate rand --hex 8 2>/dev/null) || return 1
    [[ -n "$NEW_UUID" && -n "$NEW_PRIVATE" && -n "$NEW_PUBLIC" && "$NEW_SHORT_ID" =~ ^[0-9a-fA-F]{1,16}$ ]]
}

build_link() {
    local server="$1" port="$2" uuid="$3" sni="$4" public="$5" sid="$6" name="$7"
    local host; host=$(format_server_for_uri "$server")
    printf 'vless://%s@%s:%s?security=reality&encryption=none&pbk=%s&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=%s&sid=%s#%s' \
        "$uuid" "$host" "$port" "$(uri_escape "$public")" "$(uri_escape "$sni")" "$sid" "$(uri_escape "$name")"
}

check_config() {
    local mode="${1:-verbose}"
    resolve_core >/dev/null 2>&1 || true
    [[ -x "$SINGBOX_BIN" ]] || { warn 'sing-box 核心未安装，请先执行菜单 [10] 或 s --update'; return 1; }
    [[ "$mode" == quiet ]] || info '正在检查 config.json'
    local result
    if result=$("$SINGBOX_BIN" check -c "$CONFIG_FILE" 2>&1); then
        [[ "$mode" == quiet ]] || success 'config.json 配置检查通过'
        return 0
    fi
    fail 'config.json 配置检查失败'
    while IFS= read -r line; do
        printf '    %s\n' "$line"
    done <<< "$result"
    return 1
}

apply_transaction() {
    local new_config="$1" new_meta="$2" count="$3" backup active=0
    backup=$(mktemp -d "$SINGBOX_DIR/.transaction.XXXXXX") || return 1
    cp -p "$CONFIG_FILE" "$backup/config" 2>/dev/null || true
    cp -p "$META_FILE" "$backup/meta" 2>/dev/null || true
    svc_active && active=1
    chmod 600 "$new_config" "$new_meta" || { rm -rf "$backup"; return 1; }
    if ! mv -f "$new_config" "$CONFIG_FILE" || ! mv -f "$new_meta" "$META_FILE"; then
        cp -p "$backup/config" "$CONFIG_FILE" 2>/dev/null || true
        cp -p "$backup/meta" "$META_FILE" 2>/dev/null || true
        rm -rf "$backup"
        fail '写入配置失败，已恢复原配置'
        return 1
    fi
    if ! check_config quiet; then
        cp -p "$backup/config" "$CONFIG_FILE" 2>/dev/null || true
        cp -p "$backup/meta" "$META_FILE" 2>/dev/null || true
        rm -rf "$backup"; fail '配置校验失败，未应用修改'; return 1
    fi
    if (( count > 0 )); then
        write_service_unit && svc_enable && { svc_active && svc_restart || svc_start; } || {
            cp -p "$backup/config" "$CONFIG_FILE" 2>/dev/null || true
            cp -p "$backup/meta" "$META_FILE" 2>/dev/null || true
            (( active )) && svc_restart >/dev/null 2>&1 || true
            rm -rf "$backup"; fail '服务启动失败，已恢复原配置'; return 1
        }
    else
        svc_active && svc_stop >/dev/null 2>&1 || true
        svc_enabled && svc_disable >/dev/null 2>&1 || true
    fi
    rm -rf "$backup"
    return 0
}

install_core() (
    local requested="${1:-latest}" temp version arch asset_name asset_url digest binary member current installed=''
    resolve_core >/dev/null 2>&1 || true
    info '正在检查 sing-box 核心更新'
    temp=$(mktemp -d "$SINGBOX_DIR/.core.XXXXXX") || exit 1
    trap 'rm -rf "$temp"' EXIT INT TERM
    get_url 'https://api.github.com/repos/SagerNet/sing-box/releases/latest' "$temp/release.json" || { fail '获取 sing-box 官方版本失败'; exit 1; }
    version=$(jq -er '.tag_name | sub("^v"; "") | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$temp/release.json") || { fail '官方版本信息无效'; exit 1; }
    [[ "$requested" == latest || "$requested" == "$version" ]] || { fail "固定版本不匹配: $requested"; exit 1; }
    if [[ -x "$SINGBOX_BIN" ]]; then
        installed=$("$SINGBOX_BIN" version 2>/dev/null | sed -n 's/^sing-box version \([^[:space:]]*\).*/\1/p' | head -n 1)
        if [[ "$requested" == latest && "$installed" == "$version" ]]; then
            info "sing-box 核心已是最新版本 v$version"
            exit 0
        fi
    fi
    case "$(uname -m)" in
        x86_64|amd64) arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        armv7l|armv7) arch=armv7 ;;
        *) fail "暂不支持架构: $(uname -m)"; exit 1 ;;
    esac
    asset_name=$(jq -er --arg v "$version" --arg a "$arch" '.assets[] | select(.name | test("^sing-box-" + $v + "-linux-" + $a + "(-musl)?\\.tar\\.gz$")) | .name' "$temp/release.json" | head -n 1) || { fail '找不到对应架构安装包'; exit 1; }
    asset_url=$(jq -er --arg n "$asset_name" '.assets[] | select(.name == $n) | .browser_download_url' "$temp/release.json") || exit 1
    digest=$(jq -r --arg n "$asset_name" '.assets[] | select(.name == $n) | .digest // empty' "$temp/release.json")
    get_url "$asset_url" "$temp/package.tar.gz" || { fail '核心下载失败'; exit 1; }
    if [[ "$digest" =~ ^sha256:[0-9a-fA-F]{64}$ ]]; then
        local actual; actual=$(sha256sum "$temp/package.tar.gz" | awk '{print $1}')
        [[ "$actual" == "${digest#sha256:}" ]] || { fail '核心 SHA256 校验失败'; exit 1; }
    fi
    tar -tzf "$temp/package.tar.gz" > "$temp/files" || { fail '核心压缩包无效'; exit 1; }
    member=$(awk '/(^|\/)sing-box$/ {print; exit}' "$temp/files")
    [[ -n "$member" && "$member" != /* && "$member" != *..* ]] || { fail '核心压缩包内容无效'; exit 1; }
    binary="$temp/sing-box"
    tar -xOzf "$temp/package.tar.gz" -- "$member" > "$binary" || exit 1
    chmod 755 "$binary"
    current=$("$binary" version 2>/dev/null | sed -n 's/^sing-box version \([^[:space:]]*\).*/\1/p' | head -n 1)
    [[ "$current" == "$version" ]] || { fail "核心版本不匹配: $current"; exit 1; }
    if [[ -x "$SINGBOX_BIN" ]]; then cp -p "$SINGBOX_BIN" "$temp/old" || exit 1; fi
    mkdir -p "${SINGBOX_BIN%/*}" || exit 1
    mv -f "$binary" "$SINGBOX_BIN" || exit 1
    chmod 755 "$SINGBOX_BIN"
    if [[ -s "$CONFIG_FILE" ]] && ! check_config quiet; then
        [[ -s "$temp/old" ]] && cp -p "$temp/old" "$SINGBOX_BIN" || rm -f "$SINGBOX_BIN"
        fail '新核心无法通过当前配置校验，已恢复旧核心'; exit 1
    fi
    success "sing-box 核心已更新至 v$version"
)

update_core() {
    install_core latest || { fail 'sing-box 核心更新失败'; return 1; }
}

require_core() {
    resolve_core >/dev/null 2>&1 || true
    [[ -x "$SINGBOX_BIN" ]] || { warn 'sing-box 核心未安装，请先执行菜单 [10] 或 s --update'; return 1; }
}

install_realm_script() {
    local temp first
    [[ -x "$REALM_SCRIPT_TARGET" ]] && return 0
    info '正在安装端口转发脚本'
    temp=$(mktemp "$SINGBOX_DIR/.realm-script.XXXXXX") || { fail '端口转发脚本临时文件创建失败'; return 1; }
    if ! get_url "${REALM_SCRIPT_URL}?v=$$-$RANDOM" "$temp"; then
        rm -f -- "$temp"
        fail '端口转发脚本下载失败'
        return 1
    fi
    IFS= read -r first < "$temp" || true
    if [[ "$first" != '#!/bin/sh' ]] || ! bash -n "$temp"; then
        rm -f -- "$temp"
        fail '下载内容不是有效的 Realm 管理脚本'
        return 1
    fi
    chmod 755 "$temp" && mv -f "$temp" "$REALM_SCRIPT_TARGET" || {
        rm -f -- "$temp"
        fail '端口转发脚本安装失败'
        return 1
    }
    success '端口转发脚本安装成功'
}

open_realm() {
    install_realm_script || return 1
    "$REALM_SCRIPT_TARGET"
}

realm_artifacts_exist() {
    [[ -e "$REALM_SCRIPT_TARGET" || -e "$REALM_DIR" || -e "$REALM_UNIT" || -e "$REALM_UNIT.bak" || -e "$REALM_SYSTEMD_STARTUP" || -L "$REALM_SYSTEMD_STARTUP" || -e "$REALM_OPENRC_UNIT" || -e "$REALM_LOG" || -e "$REALM_LOCK" || -e "$REALM_RUNLEVEL" ]] || compgen -G '/var/log/realm.log.*' >/dev/null 2>&1 || compgen -G '/usr/local/bin/.realm-manager.??????' >/dev/null 2>&1
}

stop_realm_service_fallback() {
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
        systemctl is-active --quiet realm && systemctl stop realm >/dev/null 2>&1 || true
        if systemctl is-enabled --quiet realm; then
            systemctl disable realm >/dev/null 2>&1 || { fail 'Realm 取消开机自启失败'; return 1; }
        fi
        systemctl reset-failed realm.service >/dev/null 2>&1 || true
        systemctl daemon-reload >/dev/null 2>&1 || true
    elif command -v rc-service >/dev/null 2>&1; then
        rc-service realm stop >/dev/null 2>&1 || true
        if command -v rc-update >/dev/null 2>&1; then
            rc-update del realm default >/dev/null 2>&1 || true
        fi
    fi
}

remove_realm_files() {
    rm -f -- "$REALM_UNIT" "$REALM_UNIT.bak" "$REALM_SYSTEMD_STARTUP" "$REALM_RUNLEVEL" "$REALM_OPENRC_UNIT" \
        "$REALM_SCRIPT_TARGET" "$REALM_LOG" "$REALM_LOG".* "$REALM_LOCK" \
        /usr/local/bin/.realm-manager.??????
    rm -rf -- "$REALM_DIR"
}

uninstall_realm() {
    if [[ -x "$REALM_SCRIPT_TARGET" ]]; then
        info '正在卸载 Realm 端口转发'
        if ! printf 'Y\n' | "$REALM_SCRIPT_TARGET" --uninstall; then
            fail 'Realm 卸载失败，未继续删除 sing-box'
            return 1
        fi
    elif realm_artifacts_exist; then
        info '正在清理残留 Realm 文件'
        stop_realm_service_fallback || return 1
    else
        return 0
    fi
    remove_realm_files || { fail 'Realm 相关文件清理失败'; return 1; }
    success 'Realm 及其相关文件已清理'
}

add_node() {
    require_core || return 1
    local server port sni name id tag uuid private public sid current_count
    server=$(server_ip_guess)
    read_input server "  服务器地址 (回车使用 ${server:-需手动输入}): " || return 1
    server=${server:-$(server_ip_guess)}
    while [[ -z "$server" ]] || ! valid_text "$server"; do
        fail '请输入有效的 IP 或域名'; read_input server '  服务器地址: ' || return 1
    done
    port="$DEFAULT_PORT"
    while true; do
        read_input port "  监听端口 (默认 $DEFAULT_PORT): " || return 1
        port=${port:-$DEFAULT_PORT}
        valid_port "$port" || { fail '端口应为 1–65535'; continue; }
        port=$((10#$port))
        port_conflict "$port" && { fail "TCP 端口 $port 已被占用"; continue; }
        break
    done
    sni="$DEFAULT_SNI"
    read_input sni "  伪装域名 (默认 $DEFAULT_SNI): " || return 1
    sni=${sni:-$DEFAULT_SNI}
    valid_text "$sni" || { fail '伪装域名格式无效'; return 1; }
    name="VLESS-TCP-REALITY-VISION-$port"
    read_input name "  节点名称 (默认 $name): " || return 1
    name=${name:-"VLESS-TCP-REALITY-VISION-$port"}
    valid_name "$name" || { fail '节点名称不能为空、不能超过 80 字或包含控制字符'; return 1; }
    generate_credentials || { fail '生成节点凭据失败'; return 1; }
    uuid="$NEW_UUID"; private="$NEW_PRIVATE"; public="$NEW_PUBLIC"; sid="$NEW_SHORT_ID"
    id=$("$SINGBOX_BIN" generate rand --hex 8 2>/dev/null || printf '%s' "$(date +%s%N)")
    tag="vless-in-$id"
    local new_config new_meta
    new_config=$(mktemp "$SINGBOX_DIR/.config.XXXXXX") || return 1
    new_meta=$(mktemp "$SINGBOX_DIR/.meta.XXXXXX") || { rm -f "$new_config"; return 1; }
    jq --arg tag "$tag" --arg sni "$sni" --arg private "$private" --arg sid "$sid" --arg uuid "$uuid" --argjson port "$port" \
        '.inbounds += [{type:"vless",tag:$tag,listen:"::",listen_port:$port,users:[{uuid:$uuid,flow:"xtls-rprx-vision"}],tls:{enabled:true,server_name:$sni,reality:{enabled:true,handshake:{server:$sni,server_port:443},private_key:$private,short_id:[$sid]}}}]' "$CONFIG_FILE" > "$new_config" || { rm -f "$new_config" "$new_meta"; return 1; }
    jq --arg id "$id" --arg tag "$tag" --arg name "$name" --arg server "$server" --arg sni "$sni" --arg uuid "$uuid" --arg public "$public" --arg sid "$sid" --argjson port "$port" \
        '.nodes += [{id:$id,tag:$tag,name:$name,server:$server,port:$port,sni:$sni,uuid:$uuid,public_key:$public,short_id:$sid}]' "$META_FILE" > "$new_meta" || { rm -f "$new_config" "$new_meta"; return 1; }
    current_count=$(node_count); current_count=$((current_count + 1))
    if apply_transaction "$new_config" "$new_meta" "$current_count"; then
        success "节点 [$name] 添加成功"
        printf '  VLESS 链接: %s\n' "$(build_link "$server" "$port" "$uuid" "$sni" "$public" "$sid" "$name")"
    else
        rm -f "$new_config" "$new_meta"; return 1
    fi
}

print_nodes() {
    jq -r '.nodes | to_entries[] | [.key+1,.value.name,(.value.port|tostring)] | @tsv' "$META_FILE" | \
        while IFS=$'\t' read -r index name port; do
            printf '  %s[%s]%s %s (vless-reality) @ %s%s%s\n' "$GREEN" "$index" "$NC" "$name" "$BLUE" "$port" "$NC"
        done
}

choose_node() {
    local result="$1" choice count
    count=$(node_count)
    (( count > 0 )) || { warn '当前没有节点'; return 1; }
    print_nodes
    read_input choice '  请输入节点序号 (0 取消): ' || return 1
    [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= count )) || { [[ "$choice" == 0 || -z "$choice" ]] && return 1; fail '无效选择'; return 1; }
    printf -v "$result" '%d' "$((choice - 1))"
}

view_nodes() {
    local count; count=$(node_count)
    printf '\n'; info "=== 当前节点信息（共 ${count} 个） ==="; printf '\n'
    (( count > 0 )) || { warn '暂无节点'; return 0; }
    while IFS=$'\t' read -r index name server port sni uuid public sid; do
        printf '  %s[%s]%s %s%s%s (vless-reality) @ %s%s%s\n' "$GREEN" "$index" "$NC" "$GREEN" "$name" "$NC" "$BLUE" "$port" "$NC"
        printf '  VLESS 链接: %s\n' "$(build_link "$server" "$port" "$uuid" "$sni" "$public" "$sid" "$name")"
        printf '\n'
    done < <(jq -r '.nodes | to_entries[] | [.key+1,.value.name,.value.server,(.value.port|tostring),.value.sni,.value.uuid,.value.public_key,.value.short_id] | @tsv' "$META_FILE")
}

apply_node_update() {
    local index="$1" tag="$2" name="$3" server="$4" port="$5" sni="$6" uuid="$7" public="$8" sid="$9" private="${10}"
    local new_config new_meta count; new_config=$(mktemp "$SINGBOX_DIR/.config.XXXXXX") || return 1; new_meta=$(mktemp "$SINGBOX_DIR/.meta.XXXXXX") || { rm -f "$new_config"; return 1; }
    jq --arg tag "$tag" --arg sni "$sni" --arg private "$private" --arg sid "$sid" --arg uuid "$uuid" --argjson port "$port" \
        '(.inbounds[] | select(.tag==$tag)) |= (.listen_port=$port | .users[0].uuid=$uuid | .tls.server_name=$sni | .tls.reality.handshake.server=$sni | .tls.reality.private_key=$private | .tls.reality.short_id=[$sid])' "$CONFIG_FILE" > "$new_config" || { rm -f "$new_config" "$new_meta"; return 1; }
    jq --arg tag "$tag" --arg name "$name" --arg server "$server" --arg sni "$sni" --arg uuid "$uuid" --arg public "$public" --arg sid "$sid" --argjson port "$port" \
        '(.nodes[] | select(.tag==$tag)) |= (.name=$name | .server=$server | .port=$port | .sni=$sni | .uuid=$uuid | .public_key=$public | .short_id=$sid)' "$META_FILE" > "$new_meta" || { rm -f "$new_config" "$new_meta"; return 1; }
    count=$(node_count)
    if apply_transaction "$new_config" "$new_meta" "$count"; then
        success "节点 [$name] 修改成功"
        printf '  VLESS 链接: %s\n' "$(build_link "$server" "$port" "$uuid" "$sni" "$public" "$sid" "$name")"
    else rm -f "$new_config" "$new_meta"; return 1; fi
}

confirm_node_update() {
    local answer
    read_input answer '  确认保存并应用本次修改？[Y/N]: ' || return 1
    [[ "$answer" =~ ^[nN]$ ]] && { warn '已取消本次修改'; return 1; }
    return 0
}

modify_node() {
    local index tag name server port sni uuid public sid private choice value
    require_core || return 1
    choose_node index || return 1
    tag=$(jq -r --argjson i "$index" '.nodes[$i].tag' "$META_FILE")
    while true; do
        name=$(jq -r --argjson i "$index" '.nodes[$i].name' "$META_FILE")
        server=$(jq -r --argjson i "$index" '.nodes[$i].server' "$META_FILE")
        port=$(jq -r --argjson i "$index" '.nodes[$i].port' "$META_FILE")
        sni=$(jq -r --argjson i "$index" '.nodes[$i].sni' "$META_FILE")
        uuid=$(jq -r --argjson i "$index" '.nodes[$i].uuid' "$META_FILE")
        public=$(jq -r --argjson i "$index" '.nodes[$i].public_key' "$META_FILE")
        sid=$(jq -r --argjson i "$index" '.nodes[$i].short_id' "$META_FILE")
        private=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .tls.reality.private_key' "$CONFIG_FILE")
        printf '\n  当前节点: %s%s%s (vless-reality) @ %s%s%s\n\n' "$GREEN" "$name" "$NC" "$BLUE" "$port" "$NC"
        printf '  %s[1]%s 修改节点名称\n  %s[2]%s 修改客户端连接地址\n  %s[3]%s 修改监听端口\n  %s[4]%s 修改 UUID\n  %s[5]%s 修改伪装域名/SNI\n  %s[6]%s 重新生成 Reality 密钥和 Short ID\n  %s[0]%s 返回\n' \
            "$GREEN" "$NC" "$GREEN" "$NC" "$GREEN" "$NC" "$GREEN" "$NC" "$GREEN" "$NC" "$GREEN" "$NC" "$GREEN" "$NC"
        read_input choice '  请选择修改项: ' || return 1
        case "$choice" in
            0) return 0 ;;
            1)
                read_input value "  请输入新节点名称 (回车保持 $name): " || return 1
                value=${value:-$name}; valid_name "$value" || { fail '节点名称无效'; continue; }
                confirm_node_update || { (( MENU_CANCELLED )) && return 1; continue; }
                apply_node_update "$index" "$tag" "$value" "$server" "$port" "$sni" "$uuid" "$public" "$sid" "$private" || return 1
                return 0
                ;;
            2)
                read_input value "  请输入新的客户端连接地址 (回车保持 $server): " || return 1
                value=${value:-$server}; valid_text "$value" || { fail '客户端连接地址无效'; continue; }
                confirm_node_update || { (( MENU_CANCELLED )) && return 1; continue; }
                apply_node_update "$index" "$tag" "$name" "$value" "$port" "$sni" "$uuid" "$public" "$sid" "$private" || return 1
                return 0
                ;;
            3)
                read_input value "  请输入新的监听端口 (回车保持 $port): " || return 1
                value=${value:-$port}; valid_port "$value" || { fail '端口应为 1–65535'; continue; }
                value=$((10#$value))
                if (( value != port )) && port_conflict "$value" "$tag"; then
                    fail "TCP 端口 $value 已被占用"
                    continue
                fi
                confirm_node_update || { (( MENU_CANCELLED )) && return 1; continue; }
                apply_node_update "$index" "$tag" "$name" "$server" "$value" "$sni" "$uuid" "$public" "$sid" "$private" || return 1
                return 0
                ;;
            4)
                read_input value '  请输入新 UUID (回车随机生成): ' || return 1
                value=${value:-$($SINGBOX_BIN generate uuid 2>/dev/null)}
                [[ "$value" =~ ^[0-9a-fA-F-]{36}$ ]] || { fail 'UUID 格式无效'; continue; }
                confirm_node_update || { (( MENU_CANCELLED )) && return 1; continue; }
                apply_node_update "$index" "$tag" "$name" "$server" "$port" "$sni" "$value" "$public" "$sid" "$private" || return 1
                return 0
                ;;
            5)
                read_input value "  请输入新的伪装域名/SNI (回车保持 $sni): " || return 1
                value=${value:-$sni}; valid_text "$value" || { fail '伪装域名格式无效'; continue; }
                confirm_node_update || { (( MENU_CANCELLED )) && return 1; continue; }
                apply_node_update "$index" "$tag" "$name" "$server" "$port" "$value" "$uuid" "$public" "$sid" "$private" || return 1
                return 0
                ;;
            6)
                generate_credentials || { fail '生成新凭据失败'; continue; }
                confirm_node_update || { (( MENU_CANCELLED )) && return 1; continue; }
                apply_node_update "$index" "$tag" "$name" "$server" "$port" "$sni" "$NEW_UUID" "$NEW_PUBLIC" "$NEW_SHORT_ID" "$NEW_PRIVATE" || return 1
                return 0
                ;;
            *) fail '无效选择' ;;
        esac
    done
}

delete_node() {
    local index tag name answer new_config new_meta count
    choose_node index || return 1
    tag=$(jq -r --argjson i "$index" '.nodes[$i].tag' "$META_FILE"); name=$(jq -r --argjson i "$index" '.nodes[$i].name' "$META_FILE")
    read_input answer "  确认删除节点 [$name]？(Y/N): " || return 1
    [[ "$answer" == [yY] ]] || return 1
    new_config=$(mktemp "$SINGBOX_DIR/.config.XXXXXX") || return 1; new_meta=$(mktemp "$SINGBOX_DIR/.meta.XXXXXX") || { rm -f "$new_config"; return 1; }
    jq --arg tag "$tag" 'del(.inbounds[] | select(.tag==$tag))' "$CONFIG_FILE" > "$new_config" || return 1
    jq --arg tag "$tag" 'del(.nodes[] | select(.tag==$tag))' "$META_FILE" > "$new_meta" || return 1
    count=$(node_count); count=$((count - 1))
    apply_transaction "$new_config" "$new_meta" "$count" && success "节点 [$name] 已删除"
}

clear_nodes() {
    local count answer new_config new_meta
    count=$(node_count); (( count > 0 )) || { warn '暂无节点'; return 0; }
    read_input answer "  确认清空全部 $count 个节点？(Y/N): " || return 1
    [[ "$answer" == [yY] ]] || return 1
    new_config=$(mktemp "$SINGBOX_DIR/.config.XXXXXX") || return 1; new_meta=$(mktemp "$SINGBOX_DIR/.meta.XXXXXX") || { rm -f "$new_config"; return 1; }
    jq '.inbounds=[]' "$CONFIG_FILE" > "$new_config" || return 1; jq '.nodes=[]' "$META_FILE" > "$new_meta" || return 1
    apply_transaction "$new_config" "$new_meta" 0 && success '所有节点已清空'
}

start_service() {
    (( $(node_count) > 0 )) || { warn '暂无节点，无法启动 sing-box'; return 1; }
    require_core || return 1; write_service_unit || return 1
    if ! svc_enabled; then
        svc_enable || { fail '设置开机自启失败'; return 1; }
    fi
    svc_active && { success 'sing-box 已在运行'; return 0; }
    svc_start && success 'sing-box 已启动，开机自启已开启' || { fail 'sing-box 启动失败，请查看日志'; return 1; }
}
stop_service() {
    svc_stop || { fail 'sing-box 停止失败'; return 1; }
    svc_disable >/dev/null 2>&1 || true
    success 'sing-box 已停止，开机自启已关闭'
}
restart_service() {
    (( $(node_count) > 0 )) || { warn '暂无节点，无法重启 sing-box'; return 1; }
    require_core || return 1
    write_service_unit || return 1
    if ! svc_enabled; then
        svc_enable || { fail '设置开机自启失败，未执行重启'; return 1; }
    fi
    svc_restart && success 'sing-box 已重启，开机自启已开启' || { fail 'sing-box 重启失败'; return 1; }
}
view_logs() {
    info '按 Ctrl+C 退出日志查看'
    local status=0
    trap 'MENU_CANCELLED=1' INT
    if [[ "$INIT_SYSTEM" == systemd ]]; then
        journalctl -u sing-box -n 20 -f --no-pager || status=$?
    else
        [[ -f "$LOG_FILE" ]] || { trap interrupt_exit INT; warn "日志文件不存在: $LOG_FILE"; return 1; }
        tail -n 20 -f "$LOG_FILE" || status=$?
    fi
    trap interrupt_exit INT
    (( MENU_CANCELLED || status == 130 || status == 143 )) && { MENU_CANCELLED=1; return 0; }
    return "$status"
}

update_script() (
    local temp first version old_hash new_hash target
    info '正在检查管理脚本更新'
    temp=$(mktemp "${SINGBOX_DIR}/.script.XXXXXX") || exit 1
    trap 'rm -f "$temp"' EXIT INT TERM
    get_url "${SCRIPT_URL}?v=$$-$RANDOM" "$temp" || { fail '管理脚本下载失败'; exit 1; }
    IFS= read -r first < "$temp" || true
    [[ "$first" == '#!/usr/bin/env bash' || "$first" == '#!/bin/bash' ]] || { fail '下载内容不是有效 Bash 脚本'; exit 1; }
    bash -n "$temp" || { fail '新版管理脚本语法检查失败'; exit 1; }
    version=$(sed -n 's/^SCRIPT_VERSION="\([0-9][0-9.]*\)"$/\1/p' "$temp" | head -n 1)
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { fail '新版脚本缺少有效版本号'; exit 1; }
    target="${SCRIPT_TARGET:-/usr/local/bin/s}"
    old_hash=$(sha256sum "$target" 2>/dev/null | awk '{print $1}' || true); new_hash=$(sha256sum "$temp" | awk '{print $1}')
    [[ -n "$old_hash" && "$old_hash" == "$new_hash" ]] && { info "管理脚本已是最新版本 v$version"; exit 0; }
    chmod 755 "$temp" && mv -f "$temp" "$target" || { fail '管理脚本替换失败'; exit 1; }
    trap - EXIT INT TERM
    success "管理脚本已更新至 v$version"
)

update_management_script() {
    update_script || { fail '管理脚本更新失败'; return 1; }
}

uninstall() {
    local answer
    read_input answer '  确认卸载 sing-box、Realm、全部节点、端口转发规则和管理脚本？(Y/N): ' || return 1
    [[ "$answer" == [yY] ]] || return 1
    uninstall_realm || return 1
    svc_stop >/dev/null 2>&1 || true; svc_disable >/dev/null 2>&1 || true
    rm -f -- "$SYSTEMD_UNIT" "$SYSTEMD_STARTUP" "$OPENRC_UNIT" "$OPENRC_STARTUP"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 || true
        systemctl reset-failed sing-box.service >/dev/null 2>&1 || true
    fi
    rm -rf "$SINGBOX_DIR" "$PID_FILE" "$LOG_FILE" "$LOG_FILE".*
    [[ "$SINGBOX_BIN" == "$CORE_INSTALL_BIN" ]] && rm -f -- "$CORE_INSTALL_BIN"
    rm -f -- "${SCRIPT_TARGET:-/usr/local/bin/s}" "$LOCK_FILE" "$LOCK_PID_FILE"
    rmdir "$(dirname "$PID_FILE")" >/dev/null 2>&1 || true
    success 'sing-box、Realm 及其相关文件已卸载'
}

menu_row() {
    local text="$1" plain width pad
    plain=$(printf '%s' "$text" | sed $'s/\033\\[[0-9;]*m//g')
    width=$(printf '%s' "$plain" | wc -L)
    pad=$((39-width)); (( pad > 0 )) || pad=0
    printf '  %s║%s%*s%s║%s\n' "$BLUE" "$text" "$pad" '' "$BLUE" "$NC"
}

menu() {
    local count choice state core
    while true; do
        MENU_CANCELLED=0
        INPUT_EOF=0
        clear_terminal
        count=$(node_count) || return 1
        core=$(core_version)
        if [[ ! -x "$SINGBOX_BIN" ]]; then state='未安装'; elif svc_active; then state='运行中'; else state='已停止'; fi
        printf '\n%s  ╔═══════════════════════════════════════╗\n' "$BLUE"
        menu_row "    ${BLUE}sing-box 管理（当前节点：${GREEN}${count}${BLUE} 个）${NC}"
        menu_row "    ${BLUE}sing-box 状态：${GREEN}${state}${BLUE}${NC}"
        menu_row "    ${BLUE}sing-box 版本：${GREEN}${core}${BLUE}${NC}"
        menu_row "    ${BLUE}管理脚本版本：${GREEN}v${SCRIPT_VERSION}${BLUE}${NC}"
        printf '%s  ╠═══════════════════════════════════════╣%s\n' "$BLUE" "$NC"
        menu_row "  ${BLUE}基础功能${NC}"
        menu_row "  ${GREEN}[1]${BLUE}  添加节点${NC}"
        menu_row "  ${GREEN}[2]${BLUE}  查看节点${NC}"
        menu_row "  ${GREEN}[3]${BLUE}  修改节点${NC}"
        menu_row "  ${GREEN}[4]${BLUE}  删除节点${NC}"
        menu_row "  ${GREEN}[5]${BLUE}  清空所有节点${NC}"
        menu_row "  ${GREEN}[6]${BLUE}  端口转发${NC}"
        printf '%s  ║%39s║%s\n' "$BLUE" '' "$NC"
        menu_row "  ${BLUE}服务管理${NC}"
        menu_row "  ${GREEN}[7]${BLUE}  启动 sing-box${NC}"
        menu_row "  ${GREEN}[8]${BLUE}  停止 sing-box${NC}"
        menu_row "  ${GREEN}[9]${BLUE}  重启 sing-box${NC}"
        printf '%s  ║%39s║%s\n' "$BLUE" '' "$NC"
        menu_row "  ${BLUE}更新与维护${NC}"
        menu_row "  ${GREEN}[10]${BLUE} 安装/更新核心${NC}"
        menu_row "  ${GREEN}[11]${BLUE} 更新管理脚本${NC}"
        menu_row "  ${GREEN}[12]${BLUE} 查看实时日志${NC}"
        menu_row "  ${GREEN}[13]${BLUE} 检查配置${NC}"
        menu_row "  ${GREEN}[14]${BLUE} 一键卸载${NC}"
        printf '%s  ║%39s║%s\n' "$BLUE" '' "$NC"
        menu_row "  ${GREEN}[0]${BLUE}  退出脚本${NC}"
        printf '%s  ╚═══════════════════════════════════════╝%s\n\n' "$BLUE" "$NC"
        local status=0
        read -r -p '  请输入选项 [0-14]: ' choice || status=$?
        (( status == 130 )) && interrupt_exit
        (( status != 0 )) && return 0
        case "$choice" in
            1) add_node ;; 2) view_nodes ;; 3) modify_node ;; 4) delete_node ;; 5) clear_nodes ;;
            6) open_realm ;;
            7) printf '\n'; info '启动 sing-box'; start_service ;;
            8) printf '\n'; info '停止 sing-box'; stop_service ;;
            9) printf '\n'; info '重启 sing-box'; restart_service ;;
            10) update_core ;;
            11)
                if update_management_script; then
                    pause_enter '  按回车加载最新脚本...'
                    (( INPUT_EOF )) && return 0
                    exec bash "${SCRIPT_TARGET:-$0}"
                fi
                ;;
            12) view_logs ;;
            13) check_config ;;
            14) uninstall && return 0 ;; 0) return 0 ;;
            *) fail '无效选项' ;;
        esac
        (( MENU_CANCELLED )) || pause_enter
        (( INPUT_EOF )) && return 0
    done
}

main() {
    [[ "$(uname -s)" == Linux && "$EUID" == 0 ]] || { fail '请在 Linux VPS/容器中以 root 或 sudo 运行'; return 1; }
    detect_init; ensure_dependencies || return 1; mkdir -p /run/lock || return 1; mkdir -p "$SINGBOX_DIR" || return 1
    acquire_manager_lock || return 1
    init_state || return 1
    resolve_core >/dev/null 2>&1 || true
    SCRIPT_TARGET="${SCRIPT_TARGET:-/usr/local/bin/s}"
    case "${1:-}" in
        --version|-v) printf 'singbox 管理脚本 v%s\n' "$SCRIPT_VERSION"; return 0 ;;
        --help|-h) printf '用法: s [--update|--update-script|--uninstall|--version]\n'; return 0 ;;
        --update) update_core; return $? ;;
        --update-script) update_management_script; return $? ;;
        --uninstall) uninstall; return $? ;;
        '') menu; return $? ;;
        *) fail "未知参数: $1"; return 1 ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    trap interrupt_exit INT
    main "$@"
fi
