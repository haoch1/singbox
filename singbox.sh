#!/usr/bin/env bash
# shellcheck disable=SC2015
set -uo pipefail

umask 077
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

SCRIPT_VERSION="1.1.2"
SCRIPT_URL="${SCRIPT_URL:-https://raw.githubusercontent.com/haoch1/singbox/main/singbox.sh}"
SINGBOX_DIR="${SINGBOX_DIR:-/usr/local/etc/sing-box}"
SINGBOX_BIN="${SINGBOX_BIN:-}"
CORE_INSTALL_BIN="/usr/local/bin/sing-box"
CONFIG_FILE="$SINGBOX_DIR/config.json"
META_FILE="$SINGBOX_DIR/nodes.json"
PID_FILE="${SINGBOX_PID_FILE:-/run/sing-box/sing-box.pid}"
LOG_FILE="${SINGBOX_LOG_FILE:-/var/log/sing-box.log}"
LOCK_FILE="${SINGBOX_LOCK_FILE:-/run/lock/singbox-manager.lock}"
LOCK_PID_FILE="${SINGBOX_LOCK_PID_FILE:-/run/lock/singbox-manager.pid}"
LOG_MAX_BYTES=10485760
LOG_KEEP_BYTES=5242880
LOG_ROTATIONS=3
TEMP_RETENTION_MINUTES=1440
SYSTEMD_UNIT="/etc/systemd/system/sing-box.service"
SYSTEMD_STARTUP="/etc/systemd/system/multi-user.target.wants/sing-box.service"
OPENRC_UNIT="/etc/init.d/sing-box"
OPENRC_STARTUP="/etc/runlevels/default/sing-box"
DEFAULT_PORT=8443
DEFAULT_SS_PORT=8388
DEFAULT_SNI="www.bing.com"
ACME_DIR="$SINGBOX_DIR/acme"
SS2022_METHOD="2022-blake3-aes-128-gcm"
ACME_ALTERNATIVE_HTTP_PORT=0
ACME_PROVIDER_TAG=''
ACME_PROVIDER_DIR=''
ACME_PROVIDER_NEW=0
ACME_PROVIDER_CREATED=0
INIT_SYSTEM="direct"

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[0;33m'
CYAN=$'\033[0;36m'; BLUE=$'\033[1;36m'; NC=$'\033[0m'

fail() { printf '  %s[错误] %s%s\n' "$RED" "$*" "$NC" >&2; return 1; }
info() { printf '  %s[信息] %s%s\n' "$CYAN" "$*" "$NC"; }
warn() { printf '  %s[注意] %s%s\n' "$YELLOW" "$*" "$NC"; }
success() { printf '  %s[成功] %s%s\n' "$GREEN" "$*" "$NC"; }
interrupt_exit() { printf '\n'; exit 130; }

reset_acme_state() {
    ACME_DISABLE_HTTP=false
    ACME_DISABLE_TLS=false
    ACME_ALTERNATIVE_HTTP_PORT=0
    ACME_PROVIDER_TAG=''
    ACME_PROVIDER_DIR=''
    ACME_PROVIDER_NEW=0
    ACME_PROVIDER_CREATED=0
}

cleanup_new_acme_dir() {
    if (( ACME_PROVIDER_NEW && ACME_PROVIDER_CREATED )) && [[ -n "$ACME_PROVIDER_DIR" && "$ACME_PROVIDER_DIR" == "$ACME_DIR/"* ]]; then
        rm -rf -- "$ACME_PROVIDER_DIR"
    fi
    reset_acme_state
}

clear_terminal() {
    [[ -t 1 ]] || return 0
    command -v clear >/dev/null 2>&1 && clear 2>/dev/null || true
    printf '\033[3J\033[2J\033[H\033[0m'
}

file_size_bytes() {
    local file=$1 size
    size=$(stat -c '%s' "$file" 2>/dev/null || true)
    if [[ $size =~ ^[0-9]+$ ]]; then
        printf '%s' "$size"
    else
        wc -c < "$file" 2>/dev/null | tr -d '[:space:]' || printf '0'
    fi
}

rotate_file_log() {
    local file=$1 size temp index
    [[ -f $file ]] || return 0
    size=$(file_size_bytes "$file")
    [[ $size =~ ^[0-9]+$ ]] || return 0
    (( size > LOG_MAX_BYTES )) || return 0
    rm -f -- "$file.$((LOG_ROTATIONS + 1))"
    for (( index=LOG_ROTATIONS; index > 1; index-- )); do
        [[ -e "$file.$((index - 1))" ]] && mv -f -- "$file.$((index - 1))" "$file.$index" 2>/dev/null || true
    done
    cp -p -- "$file" "$file.1" 2>/dev/null || return 0
    temp=$(mktemp "${file}.trim.XXXXXX") || return 0
    if tail -c "$LOG_KEEP_BYTES" "$file" > "$temp" 2>/dev/null && cat "$temp" > "$file"; then
        chmod 640 "$file" 2>/dev/null || true
    fi
    rm -f -- "$temp"
}

cleanup_stale_temp_files() {
    local directory=$1 pattern
    shift
    [[ -d $directory ]] || return 0
    for pattern in "$@"; do
        find "$directory" -mindepth 1 -maxdepth 1 -name "$pattern" -mmin +"$TEMP_RETENTION_MINUTES" -exec rm -rf -- {} + 2>/dev/null || true
    done
}

maintenance_cleanup() {
    [[ $INIT_SYSTEM == systemd ]] || rotate_file_log "$LOG_FILE"
    cleanup_stale_temp_files "$SINGBOX_DIR" \
        '.transaction.*' '.core.*' '.config.*' '.meta.*' '.script.*'
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
    local owner='' lock_target='' fd pid fd_target
    [[ -r "$LOCK_PID_FILE" ]] && owner=$(cat "$LOCK_PID_FILE" 2>/dev/null || true)
    lock_target=$(readlink -f "$LOCK_FILE" 2>/dev/null || true)
    if [[ "$owner" =~ ^[0-9]+$ ]] && kill -0 "$owner" 2>/dev/null; then
        fd_target=$(readlink -f "/proc/$owner/fd/9" 2>/dev/null || true)
        if [[ -z "$lock_target" || "$fd_target" == "$lock_target" ]]; then
            printf '%s' "$owner"
            return 0
        fi
    fi
    [[ -n "$lock_target" ]] || { printf '%s' "$owner"; return 0; }
    for fd in /proc/[0-9]*/fd/9; do
        [[ -e "$fd" ]] || continue
        pid=${fd#/proc/}; pid=${pid%%/*}
        [[ "$pid" == "$$" ]] && continue
        fd_target=$(readlink -f "$fd" 2>/dev/null || true)
        if [[ -n "$fd_target" && "$fd_target" == "$lock_target" ]]; then
            printf '%s' "$pid"
            return 0
        fi
    done
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
    local dest="$1" prompt="$2" input_value='' status=0
    read -r -p "$prompt" input_value || status=$?
    (( status == 130 )) && return 130
    (( status != 0 )) && { INPUT_EOF=1; return "$status"; }
    [[ "$input_value" == [qQ] ]] && { MENU_CANCELLED=1; return 1; }
    printf -v "$dest" '%s' "$input_value"
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
    local required=(curl jq tar sha256sum flock ss timeout base64)
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
        systemd) systemctl is-active --quiet sing-box 9>&- ;;
        openrc) rc-service sing-box status >/dev/null 2>&1 9>&- ;;
        direct)
            [[ -s "$PID_FILE" ]] || return 1
            local pid; pid=$(cat "$PID_FILE" 2>/dev/null || true)
            [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || return 1
            [[ -r "/proc/$pid/cmdline" ]] && tr '\0' ' ' < "/proc/$pid/cmdline" 9>&- | grep -Fq "$SINGBOX_BIN" 9>&-
            ;;
    esac
}

svc_enabled() {
    case "$INIT_SYSTEM" in
        systemd) systemctl is-enabled --quiet sing-box 9>&- ;;
        openrc) rc-update show default 2>/dev/null 9>&- | grep -Eq '(^|[[:space:]])sing-box([[:space:]]|$)' 9>&- ;;
        direct) return 1 ;;
    esac
}

svc_reload() { [[ "$INIT_SYSTEM" == systemd ]] && systemctl daemon-reload >/dev/null 2>&1 9>&- || true; }

svc_enable() {
    case "$INIT_SYSTEM" in
        systemd) systemctl enable sing-box >/dev/null 2>&1 9>&- ;;
        openrc) rc-update add sing-box default >/dev/null 2>&1 9>&- ;;
        direct) return 0 ;;
    esac
}

svc_disable() {
    case "$INIT_SYSTEM" in
        systemd) systemctl disable sing-box >/dev/null 2>&1 9>&- ;;
        openrc) rc-update del sing-box default >/dev/null 2>&1 9>&- ;;
        direct) return 0 ;;
    esac
}

svc_start() {
    [[ $INIT_SYSTEM == systemd ]] || rotate_file_log "$LOG_FILE"
    case "$INIT_SYSTEM" in
        systemd) systemctl start sing-box >/dev/null 2>&1 9>&- && svc_active ;;
        openrc)
            rc-service sing-box start >/dev/null 2>&1 9>&- || return 1
            svc_active
            ;;
        direct)
            mkdir -p "$(dirname "$PID_FILE")" || return 1
            mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
            rm -f "$PID_FILE"
            nohup "$SINGBOX_BIN" run -c "$CONFIG_FILE" >>"$LOG_FILE" 2>&1 </dev/null 9>&- &
            printf '%s\n' "$!" > "$PID_FILE"
            sleep 1
            svc_active
            ;;
    esac
}

svc_stop() {
    case "$INIT_SYSTEM" in
        systemd) systemctl stop sing-box >/dev/null 2>&1 9>&- ;;
        openrc) rc-service sing-box stop >/dev/null 2>&1 9>&- ;;
        direct)
            local pid=''
            [[ -s "$PID_FILE" ]] && pid=$(cat "$PID_FILE" 2>/dev/null || true)
            [[ "$pid" =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null || true
            rm -f "$PID_FILE"
            ;;
    esac
}

svc_restart() {
    [[ $INIT_SYSTEM == systemd ]] || rotate_file_log "$LOG_FILE"
    case "$INIT_SYSTEM" in
        systemd) systemctl restart sing-box >/dev/null 2>&1 9>&- && svc_active ;;
        openrc)
            rc-service sing-box restart >/dev/null 2>&1 9>&- || return 1
            svc_active
            ;;
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
        printf '%s\n' '#!/sbin/openrc-run' 'description="sing-box service"' "command=\"$SINGBOX_BIN\"" "command_args=\"run -c $CONFIG_FILE\"" 'supervisor="supervise-daemon"' 'respawn_delay=3' "output_log=\"$LOG_FILE\"" "error_log=\"$LOG_FILE\"" 'depend() { use net; }' > "$OPENRC_UNIT" || return 1
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

valid_ip_literal() {
    local value="$1" part count=0
    if [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IFS='.' read -r -a parts <<< "$value"
        for part in "${parts[@]}"; do (( 10#$part <= 255 )) || return 1; done
        return 0
    fi
    [[ "$value" == *:* && "$value" =~ ^[0-9a-fA-F:.]+$ ]] || return 1
    [[ "$value" != *:::* ]] || return 1
    [[ "$value" != *.* ]] || return 1
    IFS=':' read -r -a parts <<< "$value"
    for part in "${parts[@]}"; do
        [[ -z "$part" || "$part" =~ ^[0-9a-fA-F]{1,4}$ ]] || return 1
        [[ -n "$part" ]] && count=$((count + 1))
    done
    (( count >= 1 && count <= 8 )) || return 1
    if [[ "$value" != *::* ]]; then (( count == 8 )) || return 1; fi
}

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
    local output v
    output=$("$SINGBOX_BIN" version 2>/dev/null || true)
    v=$(awk '/^sing-box version[[:space:]]/{print $3; exit}' <<< "$output")
    [[ -n "$v" ]] && printf 'v%s' "$v" || printf '未知'
}

init_state() {
    mkdir -p "$SINGBOX_DIR" || return 1
    chmod 700 "$SINGBOX_DIR" 2>/dev/null || true
    [[ -s "$CONFIG_FILE" ]] || printf '%s\n' '{"log":{"level":"info","timestamp":true},"certificate_providers":[],"inbounds":[],"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}' > "$CONFIG_FILE"
    [[ -s "$META_FILE" ]] || printf '%s\n' '{"nodes":[]}' > "$META_FILE"
    jq -e 'type == "object" and (.inbounds|type == "array") and (.outbounds|type == "array")' "$CONFIG_FILE" >/dev/null 2>&1 || { fail "配置文件格式无效: $CONFIG_FILE"; return 1; }
    jq -e 'type == "object" and (.nodes|type == "array")' "$META_FILE" >/dev/null 2>&1 || { fail "节点元数据格式无效: $META_FILE"; return 1; }
    chmod 600 "$CONFIG_FILE" "$META_FILE" 2>/dev/null || true
}

node_count() { jq -r '.nodes | length' "$META_FILE"; }

port_conflict() {
    local port="$1" exclude="${2:-}" mode="${3:-tcp}"
    jq -e --argjson p "$port" --arg e "$exclude" '.nodes[]? | select((.port|tonumber) == $p and ($e == "" or (.tag // "") != $e))' "$META_FILE" >/dev/null 2>&1 && return 0
    jq -e --argjson p "$port" --arg e "$exclude" '.inbounds[]? | select((.listen_port|tonumber?) == $p and ($e == "" or (.tag // "") != $e))' "$CONFIG_FILE" >/dev/null 2>&1 && return 0
    if command -v ss >/dev/null 2>&1; then
        ss -H -ltn 2>/dev/null | awk -v p=":$port" '$4 ~ p"$" {found=1} END {exit !found}' && return 0
        if [[ "$mode" == tcp_udp ]]; then
            ss -H -lun 2>/dev/null | awk -v p=":$port" '$5 ~ p"$" || $4 ~ p"$" {found=1} END {exit !found}' && return 0
        fi
    fi
    return 1
}

core_version_number() {
    local output
    output=$("$SINGBOX_BIN" version 2>/dev/null || true)
    awk '/^sing-box version[[:space:]]/{print $3; exit}' <<< "$output"
}

version_at_least() {
    local current="$1" required="$2" current_part required_part index
    current="${current#v}"
    IFS='.' read -r -a current_parts <<< "${current%%-*}"
    IFS='.' read -r -a required_parts <<< "$required"
    for index in 0 1 2; do
        current_part=${current_parts[$index]:-0}; required_part=${required_parts[$index]:-0}
        [[ "$current_part" =~ ^[0-9]+$ && "$required_part" =~ ^[0-9]+$ ]] || return 1
        (( 10#$current_part > 10#$required_part )) && return 0
        (( 10#$current_part < 10#$required_part )) && return 1
    done
    return 0
}

require_anytls_core() {
    local version
    require_core || return 1
    version=$(core_version_number)
    version_at_least "$version" 1.14.0 || { warn 'AnyTLS 需要 sing-box 1.14.0 或更高版本，请先执行菜单 [9] 安装/更新核心'; return 1; }
}

select_acme_challenge() {
    local exclude="${1:-}"
    ACME_ALTERNATIVE_HTTP_PORT=0
    if ! port_conflict 80 "$exclude" tcp; then
        ACME_DISABLE_HTTP=false
        ACME_DISABLE_TLS=true
    elif ! port_conflict 443 "$exclude" tcp; then
        ACME_DISABLE_HTTP=true
        ACME_DISABLE_TLS=false
    else
        if port_conflict 9080 "$exclude" tcp; then
            fail 'ACME 备用端口 9080 已被占用'
            return 1
        fi
        ACME_DISABLE_HTTP=false
        ACME_DISABLE_TLS=true
        ACME_ALTERNATIVE_HTTP_PORT=9080
    fi
}

prepare_acme_provider() {
    local server="$1" exclude="${2:-}" provider_id
    reset_acme_state
    ACME_PROVIDER_TAG=$(jq -r --arg server "$server" \
        '[.certificate_providers[]? | select(.type=="acme" and (.domain // []) == [$server])] | first | .tag // empty' "$CONFIG_FILE" 2>/dev/null || true)
    if [[ -n "$ACME_PROVIDER_TAG" ]]; then
        ACME_PROVIDER_DIR=$(jq -r --arg tag "$ACME_PROVIDER_TAG" '.certificate_providers[]? | select(.tag==$tag) | .data_directory // empty' "$CONFIG_FILE")
        [[ -n "$ACME_PROVIDER_DIR" ]] || { fail '现有 ACME 证书提供者缺少数据目录'; return 1; }
        ACME_DISABLE_HTTP=$(jq -r --arg tag "$ACME_PROVIDER_TAG" '.certificate_providers[]? | select(.tag==$tag) | .disable_http_challenge // false' "$CONFIG_FILE")
        ACME_DISABLE_TLS=$(jq -r --arg tag "$ACME_PROVIDER_TAG" '.certificate_providers[]? | select(.tag==$tag) | .disable_tls_alpn_challenge // false' "$CONFIG_FILE")
        ACME_ALTERNATIVE_HTTP_PORT=$(jq -r --arg tag "$ACME_PROVIDER_TAG" '.certificate_providers[]? | select(.tag==$tag) | .alternative_http_port // 0' "$CONFIG_FILE")
        ACME_PROVIDER_NEW=0
        ACME_PROVIDER_CREATED=0
        if [[ ! -d "$ACME_PROVIDER_DIR" ]]; then
            mkdir -p "$ACME_PROVIDER_DIR" && chmod 700 "$ACME_PROVIDER_DIR" || { fail '创建 ACME 证书目录失败'; return 1; }
            ACME_PROVIDER_CREATED=1
        fi
        return 0
    fi
    select_acme_challenge "$exclude" || return 1
    provider_id=$("$SINGBOX_BIN" generate rand --hex 8 2>/dev/null) || return 1
    [[ "$provider_id" =~ ^[0-9a-fA-F]{16}$ ]] || { fail '生成 ACME 证书提供者标识失败'; return 1; }
    ACME_PROVIDER_TAG="anytls-acme-$provider_id"
    ACME_PROVIDER_DIR="$ACME_DIR/$provider_id"
    ACME_PROVIDER_NEW=1
    ACME_PROVIDER_CREATED=0
    if [[ ! -d "$ACME_PROVIDER_DIR" ]]; then
        mkdir -p "$ACME_PROVIDER_DIR" && chmod 700 "$ACME_PROVIDER_DIR" || { fail '创建 ACME 证书目录失败'; return 1; }
        ACME_PROVIDER_CREATED=1
    fi
}

validate_anytls_acme_port() {
    local port="$1" challenge_port=0
    if [[ "$ACME_DISABLE_HTTP" == false ]]; then
        challenge_port=$ACME_ALTERNATIVE_HTTP_PORT
        (( challenge_port > 0 )) || challenge_port=80
    elif [[ "$ACME_DISABLE_TLS" == false ]]; then
        challenge_port=443
    fi
    if (( challenge_port > 0 && port == challenge_port )); then
        fail "AnyTLS 监听端口 $port 与 ACME 验证端口冲突"
        return 1
    fi
}

generate_credentials() {
    NEW_UUID=$("$SINGBOX_BIN" generate uuid 2>/dev/null) || return 1
    local pair; pair=$("$SINGBOX_BIN" generate reality-keypair 2>/dev/null) || return 1
    NEW_PRIVATE=$(awk '/PrivateKey/ {print $NF}' <<< "$pair")
    NEW_PUBLIC=$(awk '/PublicKey/ {print $NF}' <<< "$pair")
    NEW_SHORT_ID=$("$SINGBOX_BIN" generate rand --hex 8 2>/dev/null) || return 1
    [[ -n "$NEW_UUID" && -n "$NEW_PRIVATE" && -n "$NEW_PUBLIC" && "$NEW_SHORT_ID" =~ ^[0-9a-fA-F]{1,16}$ ]]
}

build_vless_link() {
    local server="$1" port="$2" uuid="$3" sni="$4" public="$5" sid="$6" name="$7"
    local host; host=$(format_server_for_uri "$server")
    printf 'vless://%s@%s:%s?security=reality&encryption=none&pbk=%s&fp=chrome&type=tcp&flow=xtls-rprx-vision&sni=%s&sid=%s#%s' \
        "$uuid" "$host" "$port" "$(uri_escape "$public")" "$(uri_escape "$sni")" "$sid" "$(uri_escape "$name")"
}

build_anytls_link() {
    local server="$1" port="$2" password="$3" name="$4" host
    host=$(format_server_for_uri "$server")
    printf 'anytls://%s@%s:%s/?sni=%s#%s' "$(uri_escape "$password")" "$host" "$port" "$(uri_escape "$server")" "$(uri_escape "$name")"
}

build_ss2022_link() {
    local server="$1" port="$2" password="$3" name="$4" host userinfo
    host=$(format_server_for_uri "$server")
    userinfo=$(printf '%s' "$SS2022_METHOD:$password" | base64 | tr '+/' '-_' | tr -d '=\r\n')
    printf 'ss://%s@%s:%s#%s' "$userinfo" "$host" "$port" "$(uri_escape "$name")"
}

build_node_link() {
    local index="$1" protocol server port name
    protocol=$(jq -r --argjson i "$index" '.nodes[$i].protocol // "vless-reality"' "$META_FILE")
    server=$(jq -r --argjson i "$index" '.nodes[$i].server' "$META_FILE")
    port=$(jq -r --argjson i "$index" '.nodes[$i].port' "$META_FILE")
    name=$(jq -r --argjson i "$index" '.nodes[$i].name' "$META_FILE")
    case "$protocol" in
        vless-reality)
            build_vless_link "$server" "$port" \
                "$(jq -r --argjson i "$index" '.nodes[$i].uuid' "$META_FILE")" \
                "$(jq -r --argjson i "$index" '.nodes[$i].sni' "$META_FILE")" \
                "$(jq -r --argjson i "$index" '.nodes[$i].public_key' "$META_FILE")" \
                "$(jq -r --argjson i "$index" '.nodes[$i].short_id' "$META_FILE")" "$name"
            ;;
        anytls) build_anytls_link "$server" "$port" "$(jq -r --argjson i "$index" '.nodes[$i].password' "$META_FILE")" "$name" ;;
        ss2022) build_ss2022_link "$server" "$port" "$(jq -r --argjson i "$index" '.nodes[$i].password' "$META_FILE")" "$name" ;;
        *) return 1 ;;
    esac
}

check_config() {
    local mode="${1:-verbose}"
    resolve_core >/dev/null 2>&1 || true
    [[ -x "$SINGBOX_BIN" ]] || { warn 'sing-box 核心未安装，请先执行菜单 [9] 或 s --update'; return 1; }
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
    local requested="${1:-latest}" temp version arch libc asset_name asset_url digest binary member current installed='' output
    resolve_core >/dev/null 2>&1 || true
    info '正在检查 sing-box 核心更新'
    temp=$(mktemp -d "$SINGBOX_DIR/.core.XXXXXX") || exit 1
    trap 'rm -rf "$temp"' EXIT INT TERM
    get_url 'https://api.github.com/repos/SagerNet/sing-box/releases/latest' "$temp/release.json" || { fail '获取 sing-box 官方版本失败'; exit 1; }
    version=$(jq -er '.tag_name | sub("^v"; "") | select(test("^[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$temp/release.json") || { fail '官方版本信息无效'; exit 1; }
    [[ "$requested" == latest || "$requested" == "$version" ]] || { fail "固定版本不匹配: $requested"; exit 1; }
    if [[ -x "$SINGBOX_BIN" ]]; then
        output=$("$SINGBOX_BIN" version 2>/dev/null || true)
        installed=$(awk '/^sing-box version[[:space:]]/{print $3; exit}' <<< "$output")
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
    output=$(ldd --version 2>&1 || true)
    if [[ "$output" == *musl* || "$output" == *Musl* ]]; then
        libc=musl
    else
        libc=glibc
    fi
    if [[ "$libc" == musl ]]; then
        asset_name=$(jq -er --arg v "$version" --arg a "$arch" '
            [.assets[] | .name | select(. == ("sing-box-" + $v + "-linux-" + $a + "-musl.tar.gz"))][0]
            // error("对应架构的 musl 安装包不存在")' "$temp/release.json") || { fail '找不到对应架构安装包'; exit 1; }
    else
        asset_name=$(jq -er --arg v "$version" --arg a "$arch" '
            ([.assets[] | .name | select(. == ("sing-box-" + $v + "-linux-" + $a + "-glibc.tar.gz"))][0]
             // [.assets[] | .name | select(. == ("sing-box-" + $v + "-linux-" + $a + ".tar.gz"))][0]
             // error("对应架构的 glibc 安装包不存在"))' "$temp/release.json") || { fail '找不到对应架构安装包'; exit 1; }
    fi
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
    output=$("$binary" version 2>/dev/null || true)
    current=$(awk '/^sing-box version[[:space:]]/{print $3; exit}' <<< "$output")
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
    [[ -x "$SINGBOX_BIN" ]] || { warn 'sing-box 核心未安装，请先执行菜单 [9] 或 s --update'; return 1; }
}

add_vless_node() {
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
        '.nodes += [{protocol:"vless-reality",id:$id,tag:$tag,name:$name,server:$server,port:$port,sni:$sni,uuid:$uuid,public_key:$public,short_id:$sid}]' "$META_FILE" > "$new_meta" || { rm -f "$new_config" "$new_meta"; return 1; }
    current_count=$(node_count); current_count=$((current_count + 1))
    if apply_transaction "$new_config" "$new_meta" "$current_count"; then
        success "节点 [$name] 添加成功"
        printf '  %s节点链接:%s %s%s%s\n' "$YELLOW" "$NC" "$GREEN" "$(build_vless_link "$server" "$port" "$uuid" "$sni" "$public" "$sid" "$name")" "$NC"
    else
        rm -f "$new_config" "$new_meta"; return 1
    fi
}

add_anytls_node() {
    require_anytls_core || return 1
    local server port name id tag password
    reset_acme_state
    server=$(server_ip_guess)
    read_input server "  服务器地址 (回车使用 ${server:-需手动输入}): " || return 1
    server=${server:-$(server_ip_guess)}
    while ! valid_ip_literal "$server"; do
        fail 'AnyTLS 服务器地址必须是 IPv4 或 IPv6 地址'; read_input server '  服务器地址: ' || return 1
    done
    port="$DEFAULT_PORT"
    while true; do
        read_input port "  监听端口 (默认 $DEFAULT_PORT): " || return 1
        port=${port:-$DEFAULT_PORT}
        valid_port "$port" || { fail '端口应为 1–65535'; continue; }
        port=$((10#$port))
        port_conflict "$port" tcp && { fail "TCP 端口 $port 已被占用"; continue; }
        break
    done
    name="AnyTLS-$port"
    read_input name "  节点名称 (默认 $name): " || return 1
    name=${name:-"AnyTLS-$port"}
    valid_name "$name" || { fail '节点名称不能为空、不能超过 80 字或包含控制字符'; return 1; }
    password=$("$SINGBOX_BIN" generate rand --hex 32 2>/dev/null) || { fail '生成 AnyTLS 密码失败'; return 1; }
    [[ "$password" =~ ^[0-9a-fA-F]{64}$ ]] || { fail '生成 AnyTLS 密码格式无效'; return 1; }
    id=$("$SINGBOX_BIN" generate rand --hex 8 2>/dev/null || printf '%s' "$(date +%s%N)")
    tag="anytls-in-$id"
    prepare_acme_provider "$server" || { cleanup_new_acme_dir; return 1; }
    validate_anytls_acme_port "$port" || { cleanup_new_acme_dir; return 1; }
    apply_anytls_node_update '' "$name" "$server" "$port" "$password" "$ACME_PROVIDER_TAG" "$ACME_PROVIDER_DIR" "$ACME_PROVIDER_NEW" "$ACME_DISABLE_HTTP" "$ACME_DISABLE_TLS" "$ACME_ALTERNATIVE_HTTP_PORT" "$tag" "$id" '' '' || {
        cleanup_new_acme_dir
        return 1
    }
    reset_acme_state
}

add_ss2022_node() {
    require_core || return 1
    local server port name id tag password current_count new_config new_meta
    server=$(server_ip_guess)
    read_input server "  服务器地址 (回车使用 ${server:-需手动输入}): " || return 1
    server=${server:-$(server_ip_guess)}
    while [[ -z "$server" ]] || ! valid_text "$server"; do
        fail '请输入有效的 IP 或域名'; read_input server '  服务器地址: ' || return 1
    done
    port="$DEFAULT_SS_PORT"
    while true; do
        read_input port "  监听端口 (默认 $DEFAULT_SS_PORT): " || return 1
        port=${port:-$DEFAULT_SS_PORT}
        valid_port "$port" || { fail '端口应为 1–65535'; continue; }
        port=$((10#$port))
        port_conflict "$port" tcp_udp && { fail "TCP/UDP 端口 $port 已被占用"; continue; }
        break
    done
    name="SS2022-$port"
    read_input name "  节点名称 (默认 $name): " || return 1
    name=${name:-"SS2022-$port"}
    valid_name "$name" || { fail '节点名称不能为空、不能超过 80 字或包含控制字符'; return 1; }
    password=$("$SINGBOX_BIN" generate rand --base64 16 2>/dev/null) || { fail '生成 Shadowsocks 2022 密码失败'; return 1; }
    [[ -n "$password" ]] || { fail '生成 Shadowsocks 2022 密码失败'; return 1; }
    id=$("$SINGBOX_BIN" generate rand --hex 8 2>/dev/null || printf '%s' "$(date +%s%N)")
    tag="ss-in-$id"
    new_config=$(mktemp "$SINGBOX_DIR/.config.XXXXXX") || return 1
    new_meta=$(mktemp "$SINGBOX_DIR/.meta.XXXXXX") || { rm -f "$new_config"; return 1; }
    jq --arg tag "$tag" --arg password "$password" --argjson port "$port" \
        '.inbounds += [{type:"shadowsocks",tag:$tag,listen:"::",listen_port:$port,method:"2022-blake3-aes-128-gcm",password:$password}]' "$CONFIG_FILE" > "$new_config" || { rm -f "$new_config" "$new_meta"; return 1; }
    jq --arg id "$id" --arg tag "$tag" --arg name "$name" --arg server "$server" --arg password "$password" --argjson port "$port" \
        '.nodes += [{protocol:"ss2022",id:$id,tag:$tag,name:$name,server:$server,port:$port,method:"2022-blake3-aes-128-gcm",password:$password}]' "$META_FILE" > "$new_meta" || { rm -f "$new_config" "$new_meta"; return 1; }
    current_count=$(node_count); current_count=$((current_count + 1))
    if apply_transaction "$new_config" "$new_meta" "$current_count"; then
        success "节点 [$name] 添加成功"
        printf '  %s节点链接:%s %s%s%s\n' "$YELLOW" "$NC" "$GREEN" "$(build_ss2022_link "$server" "$port" "$password" "$name")" "$NC"
    else
        rm -f "$new_config" "$new_meta"; return 1
    fi
}

add_node() {
    local protocol
    require_core || return 1
    printf '\n  请选择协议:\n\n  %s[1]%s VLESS + Reality + Vision\n  %s[2]%s AnyTLS\n  %s[3]%s Shadowsocks 2022\n  %s[0]%s 返回\n' \
        "$GREEN" "$NC" "$GREEN" "$NC" "$GREEN" "$NC" "$GREEN" "$NC"
    read_input protocol '  请选择协议: ' || return 1
    case "$protocol" in
        1) add_vless_node ;;
        2) add_anytls_node ;;
        3) add_ss2022_node ;;
        0|'') return 0 ;;
        *) fail '无效选择'; return 1 ;;
    esac
}

print_nodes() {
    jq -r '.nodes | to_entries[] | [.key+1,.value.name,(.value.protocol // "vless-reality"),(.value.port|tostring)] | @tsv' "$META_FILE" | \
        while IFS=$'\t' read -r index name protocol port; do
            printf '  %s[%s]%s %s (%s) @ %s%s%s\n' "$GREEN" "$index" "$NC" "$name" "$protocol" "$BLUE" "$port" "$NC"
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
    while IFS=$'\t' read -r index name protocol port; do
        printf '  %s[%s]%s %s%s%s (%s) @ %s%s%s\n' "$GREEN" "$index" "$NC" "$GREEN" "$name" "$NC" "$protocol" "$BLUE" "$port" "$NC"
        printf '  %s节点链接:%s %s%s%s\n' "$YELLOW" "$NC" "$GREEN" "$(build_node_link "$((index - 1))")" "$NC"
        printf '\n'
    done < <(jq -r '.nodes | to_entries[] | [.key+1,.value.name,(.value.protocol // "vless-reality"),(.value.port|tostring)] | @tsv' "$META_FILE")
}

apply_vless_node_update() {
    local index="$1" tag="$2" name="$3" server="$4" port="$5" sni="$6" uuid="$7" public="$8" sid="$9" private="${10}"
    local new_config new_meta count config_matches meta_matches
    new_config=$(mktemp "$SINGBOX_DIR/.config.XXXXXX") || return 1
    new_meta=$(mktemp "$SINGBOX_DIR/.meta.XXXXXX") || { rm -f "$new_config"; return 1; }
    config_matches=$(jq -r --arg tag "$tag" '[.inbounds[]? | select(.tag==$tag)] | length' "$CONFIG_FILE" 2>/dev/null) || { rm -f "$new_config" "$new_meta"; fail '目标节点配置读取失败'; return 1; }
    meta_matches=$(jq -r --arg tag "$tag" '[.nodes[]? | select(.tag==$tag)] | length' "$META_FILE" 2>/dev/null) || { rm -f "$new_config" "$new_meta"; fail '目标节点元数据读取失败'; return 1; }
    if [[ "$config_matches" != 1 || "$meta_matches" != 1 ]]; then
        rm -f "$new_config" "$new_meta"
        fail '目标节点信息不一致，未应用修改，请重新进入菜单'
        return 1
    fi
    jq --arg tag "$tag" --arg sni "$sni" --arg private "$private" --arg sid "$sid" --arg uuid "$uuid" --argjson port "$port" \
        '(.inbounds[] | select(.tag==$tag)) |= (.listen_port=$port | .users[0].uuid=$uuid | .tls.server_name=$sni | .tls.reality.handshake.server=$sni | .tls.reality.private_key=$private | .tls.reality.short_id=[$sid])' "$CONFIG_FILE" > "$new_config" || { rm -f "$new_config" "$new_meta"; return 1; }
    jq --arg tag "$tag" --arg name "$name" --arg server "$server" --arg sni "$sni" --arg uuid "$uuid" --arg public "$public" --arg sid "$sid" --argjson port "$port" \
        '(.nodes[] | select(.tag==$tag)) |= (.protocol=(.protocol // "vless-reality") | .name=$name | .server=$server | .port=$port | .sni=$sni | .uuid=$uuid | .public_key=$public | .short_id=$sid)' "$META_FILE" > "$new_meta" || { rm -f "$new_config" "$new_meta"; return 1; }
    if ! jq -e --arg tag "$tag" --arg sni "$sni" --arg private "$private" --arg sid "$sid" --arg uuid "$uuid" --argjson port "$port" \
        'any(.inbounds[]?; .tag==$tag and (.listen_port|tonumber?)==$port and .users[0].uuid==$uuid and .tls.server_name==$sni and .tls.reality.handshake.server==$sni and .tls.reality.private_key==$private and ((.tls.reality.short_id // []) | index($sid)) != null)' "$new_config" >/dev/null 2>&1; then
        rm -f "$new_config" "$new_meta"
        fail '节点配置修改结果校验失败'
        return 1
    fi
    if ! jq -e --arg tag "$tag" --arg name "$name" --arg server "$server" --arg sni "$sni" --arg uuid "$uuid" --arg public "$public" --arg sid "$sid" --argjson port "$port" \
        'any(.nodes[]?; .tag==$tag and .name==$name and .server==$server and (.port|tonumber?)==$port and .sni==$sni and .uuid==$uuid and .public_key==$public and .short_id==$sid)' "$new_meta" >/dev/null 2>&1; then
        rm -f "$new_config" "$new_meta"
        fail '节点元数据修改结果校验失败'
        return 1
    fi
    count=$(node_count)
    if apply_transaction "$new_config" "$new_meta" "$count"; then
        success "节点 [$name] 修改成功"
        printf '  %s节点链接:%s %s%s%s\n' "$YELLOW" "$NC" "$GREEN" "$(build_vless_link "$server" "$port" "$uuid" "$sni" "$public" "$sid" "$name")" "$NC"
    else rm -f "$new_config" "$new_meta"; return 1; fi
}

confirm_node_update() {
    local answer
    read_input answer '  确认保存并应用本次修改？[Y/N]: ' || return 1
    [[ "$answer" =~ ^[nN]$ ]] && { warn '已取消本次修改'; return 1; }
    return 0
}

modify_vless_node() {
    local index="$1" tag name server port sni uuid public sid private choice value
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
                if [[ -z "$value" ]]; then
                    printf '  节点名称：%s\n' "$name"
                    pause_enter '  按回车返回修改节点菜单...'
                    continue
                fi
                valid_name "$value" || { fail '节点名称无效'; continue; }
                printf '  节点名称：%s\n' "$value"
                if [[ "$value" == "$name" ]]; then
                    pause_enter '  按回车返回修改节点菜单...'
                    continue
                fi
                confirm_node_update || { (( MENU_CANCELLED )) && return 1; continue; }
                apply_vless_node_update "$index" "$tag" "$value" "$server" "$port" "$sni" "$uuid" "$public" "$sid" "$private" || return 1
                pause_enter '  按回车返回修改节点菜单...'
                continue
                ;;
            2)
                read_input value "  请输入新的客户端连接地址 (回车保持 $server): " || return 1
                if [[ -z "$value" ]]; then
                    printf '  客户端连接地址：%s\n' "$server"
                    pause_enter '  按回车返回修改节点菜单...'
                    continue
                fi
                valid_text "$value" || { fail '客户端连接地址无效'; continue; }
                printf '  客户端连接地址：%s\n' "$value"
                if [[ "$value" == "$server" ]]; then
                    pause_enter '  按回车返回修改节点菜单...'
                    continue
                fi
                confirm_node_update || { (( MENU_CANCELLED )) && return 1; continue; }
                apply_vless_node_update "$index" "$tag" "$name" "$value" "$port" "$sni" "$uuid" "$public" "$sid" "$private" || return 1
                pause_enter '  按回车返回修改节点菜单...'
                continue
                ;;
            3)
                read_input value "  请输入新的监听端口 (回车保持 $port): " || return 1
                if [[ -z "$value" ]]; then
                    printf '  监听端口：%s\n' "$port"
                    pause_enter '  按回车返回修改节点菜单...'
                    continue
                fi
                valid_port "$value" || { fail '端口应为 1–65535'; continue; }
                value=$((10#$value))
                if (( value != port )) && port_conflict "$value" "$tag"; then
                    fail "TCP 端口 $value 已被占用"
                    continue
                fi
                printf '  监听端口：%s\n' "$value"
                if (( value == port )); then
                    pause_enter '  按回车返回修改节点菜单...'
                    continue
                fi
                confirm_node_update || { (( MENU_CANCELLED )) && return 1; continue; }
                apply_vless_node_update "$index" "$tag" "$name" "$server" "$value" "$sni" "$uuid" "$public" "$sid" "$private" || return 1
                pause_enter '  按回车返回修改节点菜单...'
                continue
                ;;
            4)
                read_input value '  请输入新 UUID (回车随机生成): ' || return 1
                if [[ -z "$value" ]]; then
                    value=$($SINGBOX_BIN generate uuid 2>/dev/null)
                    [[ -n "$value" ]] || { fail 'UUID 自动生成失败'; continue; }
                fi
                [[ "$value" =~ ^[0-9a-fA-F-]{36}$ ]] || { fail 'UUID 格式无效'; continue; }
                printf '  UUID：%s\n' "$value"
                if [[ "$value" == "$uuid" ]]; then
                    pause_enter '  按回车返回修改节点菜单...'
                    continue
                fi
                confirm_node_update || { (( MENU_CANCELLED )) && return 1; continue; }
                apply_vless_node_update "$index" "$tag" "$name" "$server" "$port" "$sni" "$value" "$public" "$sid" "$private" || return 1
                pause_enter '  按回车返回修改节点菜单...'
                continue
                ;;
            5)
                read_input value "  请输入新的伪装域名/SNI (回车保持 $sni): " || return 1
                if [[ -z "$value" ]]; then
                    printf '  伪装域名/SNI：%s\n' "$sni"
                    pause_enter '  按回车返回修改节点菜单...'
                    continue
                fi
                valid_text "$value" || { fail '伪装域名格式无效'; continue; }
                printf '  伪装域名/SNI：%s\n' "$value"
                if [[ "$value" == "$sni" ]]; then
                    pause_enter '  按回车返回修改节点菜单...'
                    continue
                fi
                confirm_node_update || { (( MENU_CANCELLED )) && return 1; continue; }
                apply_vless_node_update "$index" "$tag" "$name" "$server" "$port" "$value" "$uuid" "$public" "$sid" "$private" || return 1
                pause_enter '  按回车返回修改节点菜单...'
                continue
                ;;
            6)
                generate_credentials || { fail '生成新凭据失败'; continue; }
                printf '  Reality 私钥：%s\n  Reality 公钥：%s\n  Short ID：%s\n' \
                    "$NEW_PRIVATE" "$NEW_PUBLIC" "$NEW_SHORT_ID"
                confirm_node_update || { (( MENU_CANCELLED )) && return 1; continue; }
                apply_vless_node_update "$index" "$tag" "$name" "$server" "$port" "$sni" "$uuid" "$NEW_PUBLIC" "$NEW_SHORT_ID" "$NEW_PRIVATE" || return 1
                pause_enter '  按回车返回修改节点菜单...'
                continue
                ;;
            *) fail '无效选择' ;;
        esac
    done
}

apply_anytls_node_update() {
    local old_tag="$1" name="$2" server="$3" port="$4" password="$5" provider_tag="$6" provider_dir="$7" provider_new="$8"
    local disable_http="$9" disable_tls="${10}" alternative_http_port="${11}" new_tag="${12:-}" node_id="${13:-}" old_dir="${14:-}" old_provider_tag="${15:-}"
    local new_config new_meta count config_matches meta_matches acme_backup=''
    new_tag=${new_tag:-$old_tag}
    new_config=$(mktemp "$SINGBOX_DIR/.config.XXXXXX") || return 1
    new_meta=$(mktemp "$SINGBOX_DIR/.meta.XXXXXX") || { rm -f "$new_config"; return 1; }
    if [[ -n "$old_tag" ]]; then
        config_matches=$(jq -r --arg tag "$old_tag" '[.inbounds[]? | select(.tag==$tag)] | length' "$CONFIG_FILE" 2>/dev/null) || { rm -f "$new_config" "$new_meta"; fail '目标节点配置读取失败'; return 1; }
        meta_matches=$(jq -r --arg tag "$old_tag" '[.nodes[]? | select(.tag==$tag)] | length' "$META_FILE" 2>/dev/null) || { rm -f "$new_config" "$new_meta"; fail '目标节点元数据读取失败'; return 1; }
        if [[ "$config_matches" != 1 || "$meta_matches" != 1 ]]; then
            rm -f "$new_config" "$new_meta"; fail '目标节点信息不一致，未应用修改，请重新进入菜单'; return 1
        fi
    fi
    if [[ -z "$old_tag" ]]; then
        jq --arg tag "$new_tag" --arg id "$node_id" --arg server "$server" --arg password "$password" --arg provider "$provider_tag" --arg dir "$provider_dir" --argjson port "$port" --argjson provider_new "$provider_new" --argjson disable_http "$disable_http" --argjson disable_tls "$disable_tls" --argjson alternative_http_port "$alternative_http_port" --arg name "$name" \
            'if $provider_new == 1 then .certificate_providers=((.certificate_providers // []) + [{type:"acme",tag:$provider,domain:[$server],default_server_name:$server,provider:"letsencrypt",profile:"shortlived",key_type:"p256",data_directory:$dir,disable_http_challenge:$disable_http,disable_tls_alpn_challenge:$disable_tls,alternative_http_port:$alternative_http_port}]) else . end | .inbounds += [{type:"anytls",tag:$tag,listen:"::",listen_port:$port,users:[{name:"default",password:$password}],tls:{enabled:true,certificate_provider:$provider}}]' "$CONFIG_FILE" > "$new_config" || { rm -f "$new_config" "$new_meta"; return 1; }
        jq --arg tag "$new_tag" --arg id "$node_id" --arg name "$name" --arg server "$server" --arg password "$password" --arg provider "$provider_tag" --arg dir "$provider_dir" --argjson port "$port" '.nodes += [{protocol:"anytls",id:$id,tag:$tag,name:$name,server:$server,port:$port,password:$password,certificate_provider:$provider,acme_dir:$dir}]' "$META_FILE" > "$new_meta" || { rm -f "$new_config" "$new_meta"; return 1; }
    else
        jq --arg old "$old_tag" --arg provider "$provider_tag" --arg server "$server" --arg password "$password" --argjson port "$port" --argjson provider_new "$provider_new" --argjson disable_http "$disable_http" --argjson disable_tls "$disable_tls" --argjson alternative_http_port "$alternative_http_port" --arg dir "$provider_dir" \
            'if $provider_new == 1 then .certificate_providers=((.certificate_providers // []) + [{type:"acme",tag:$provider,domain:[$server],default_server_name:$server,provider:"letsencrypt",profile:"shortlived",key_type:"p256",data_directory:$dir,disable_http_challenge:$disable_http,disable_tls_alpn_challenge:$disable_tls,alternative_http_port:$alternative_http_port}]) else . end | (.inbounds[] | select(.tag==$old)) |= (.listen_port=$port | .users[0].password=$password | .tls.enabled=true | .tls.certificate_provider=$provider)' "$CONFIG_FILE" > "$new_config" || { rm -f "$new_config" "$new_meta"; return 1; }
        jq --arg old "$old_tag" --arg name "$name" --arg server "$server" --arg password "$password" --arg provider "$provider_tag" --arg dir "$provider_dir" --argjson port "$port" '(.nodes[] | select(.tag==$old)) |= (.protocol="anytls" | .name=$name | .server=$server | .port=$port | .password=$password | .certificate_provider=$provider | .acme_dir=$dir)' "$META_FILE" > "$new_meta" || { rm -f "$new_config" "$new_meta"; return 1; }
        if [[ -n "$old_provider_tag" && "$old_provider_tag" != "$provider_tag" ]]; then
            jq --arg old "$old_provider_tag" '. as $root | if any(.certificate_providers[]?; .tag==$old and any($root.inbounds[]?; .tls.certificate_provider==$old)) then . else .certificate_providers |= map(select(.tag != $old)) end' "$new_config" > "${new_config}.clean" && mv -f "${new_config}.clean" "$new_config" || { rm -f "$new_config" "${new_config}.clean" "$new_meta"; return 1; }
        fi
    fi
    jq -e --arg tag "$new_tag" --arg provider "$provider_tag" --arg password "$password" --argjson port "$port" 'any(.inbounds[]?; .tag==$tag and .type=="anytls" and (.listen_port|tonumber?)==$port and .users[0].password==$password and .tls.certificate_provider==$provider)' "$new_config" >/dev/null 2>&1 || { rm -f "$new_config" "$new_meta"; fail 'AnyTLS 配置修改结果校验失败'; return 1; }
    jq -e --arg tag "$new_tag" --arg name "$name" --arg server "$server" --arg password "$password" --arg provider "$provider_tag" --arg dir "$provider_dir" --argjson port "$port" 'any(.nodes[]?; .tag==$tag and (.protocol // "vless-reality")=="anytls" and .name==$name and .server==$server and (.port|tonumber?)==$port and .password==$password and .certificate_provider==$provider and .acme_dir==$dir)' "$new_meta" >/dev/null 2>&1 || { rm -f "$new_config" "$new_meta"; fail 'AnyTLS 元数据修改结果校验失败'; return 1; }
    if [[ -n "$old_dir" && "$old_dir" == "$ACME_DIR/"* && -d "$old_dir" && "$old_dir" == "$provider_dir" ]]; then
        acme_backup=$(mktemp -d "$SINGBOX_DIR/.transaction.XXXXXX") || { rm -f "$new_config" "$new_meta"; return 1; }
        cp -a "$old_dir/." "$acme_backup/" 2>/dev/null || { rm -rf "$acme_backup" "$new_config" "$new_meta"; return 1; }
    fi
    count=$(node_count); (( count == 0 )) && count=1
    if apply_transaction "$new_config" "$new_meta" "$count"; then
        [[ -n "$acme_backup" ]] && rm -rf "$acme_backup"
        if [[ -n "$old_dir" && "$old_dir" == "$ACME_DIR/"* && "$old_dir" != "$provider_dir" ]] && ! jq -e --arg dir "$old_dir" 'any(.nodes[]?; (.protocol // "vless-reality")=="anytls" and .acme_dir==$dir)' "$META_FILE" >/dev/null 2>&1; then rm -rf -- "$old_dir"; fi
        success "节点 [$name] $(if [[ -z "$old_tag" ]]; then printf 添加成功; else printf 修改成功; fi)"
        printf '  %s节点链接:%s %s%s%s\n' "$YELLOW" "$NC" "$GREEN" "$(build_anytls_link "$server" "$port" "$password" "$name")" "$NC"
    else
        rm -f "$new_config" "$new_meta"
        if [[ -n "$acme_backup" ]]; then rm -rf "$old_dir"; mkdir -p "$old_dir"; cp -a "$acme_backup/." "$old_dir/" 2>/dev/null || true; rm -rf "$acme_backup"; fi
        return 1
    fi
}

modify_anytls_node() {
    local index="$1" tag name server port password old_dir old_provider_tag provider_tag provider_dir provider_new disable_http disable_tls alternative_http_port choice value
    tag=$(jq -r --argjson i "$index" '.nodes[$i].tag' "$META_FILE")
    reset_acme_state
    while true; do
        reset_acme_state
        name=$(jq -r --argjson i "$index" '.nodes[$i].name' "$META_FILE")
        server=$(jq -r --argjson i "$index" '.nodes[$i].server' "$META_FILE")
        port=$(jq -r --argjson i "$index" '.nodes[$i].port' "$META_FILE")
        password=$(jq -r --argjson i "$index" '.nodes[$i].password' "$META_FILE")
        old_dir=$(jq -r --argjson i "$index" '.nodes[$i].acme_dir // empty' "$META_FILE")
        provider_tag=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .tls.certificate_provider | if type=="string" then . else empty end' "$CONFIG_FILE")
        old_provider_tag="$provider_tag"
        if [[ -n "$provider_tag" ]]; then
            provider_dir=$(jq -r --arg tag "$provider_tag" '.certificate_providers[]? | select(.tag==$tag) | .data_directory // empty' "$CONFIG_FILE")
            [[ -n "$old_dir" ]] || old_dir="$provider_dir"
            disable_http=$(jq -r --arg tag "$provider_tag" '.certificate_providers[]? | select(.tag==$tag) | .disable_http_challenge // false' "$CONFIG_FILE")
            disable_tls=$(jq -r --arg tag "$provider_tag" '.certificate_providers[]? | select(.tag==$tag) | .disable_tls_alpn_challenge // false' "$CONFIG_FILE")
            alternative_http_port=$(jq -r --arg tag "$provider_tag" '.certificate_providers[]? | select(.tag==$tag) | .alternative_http_port // 0' "$CONFIG_FILE")
            provider_new=0
        else
            provider_dir="$old_dir"
            disable_http=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .tls.certificate_provider.disable_http_challenge // false' "$CONFIG_FILE")
            disable_tls=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .tls.certificate_provider.disable_tls_alpn_challenge // false' "$CONFIG_FILE")
            alternative_http_port=$(jq -r --arg tag "$tag" '.inbounds[] | select(.tag==$tag) | .tls.certificate_provider.alternative_http_port // 0' "$CONFIG_FILE")
            provider_new=1
        fi
        printf '\n  当前节点: %s%s%s (anytls) @ %s%s%s\n\n' "$GREEN" "$name" "$NC" "$BLUE" "$port" "$NC"
        printf '  %s[1]%s 修改节点名称\n  %s[2]%s 修改服务器公网 IP\n  %s[3]%s 修改监听端口\n  %s[4]%s 重新生成密码\n  %s[0]%s 返回\n' "$GREEN" "$NC" "$GREEN" "$NC" "$GREEN" "$NC" "$GREEN" "$NC" "$GREEN" "$NC"
        read_input choice '  请选择修改项: ' || return 1
        case "$choice" in
            0) return 0 ;;
            1)
                read_input value "  请输入新节点名称 (回车保持 $name): " || return 1; value=${value:-$name}; valid_name "$value" || { fail '节点名称无效'; continue; }
                printf '  节点名称：%s\n' "$value"; [[ "$value" == "$name" ]] && { pause_enter '  按回车返回修改节点菜单...'; continue; }
                if [[ -z "$provider_tag" ]]; then prepare_acme_provider "$server" "$tag" || { cleanup_new_acme_dir; continue; }; provider_tag="$ACME_PROVIDER_TAG"; provider_dir="$ACME_PROVIDER_DIR"; provider_new="$ACME_PROVIDER_NEW"; disable_http="$ACME_DISABLE_HTTP"; disable_tls="$ACME_DISABLE_TLS"; alternative_http_port="$ACME_ALTERNATIVE_HTTP_PORT"; fi
                confirm_node_update || { cleanup_new_acme_dir; (( MENU_CANCELLED )) && return 1; continue; }
                apply_anytls_node_update "$tag" "$value" "$server" "$port" "$password" "$provider_tag" "$provider_dir" "$provider_new" "$disable_http" "$disable_tls" "$alternative_http_port" "$tag" '' "$old_dir" "$old_provider_tag" || { cleanup_new_acme_dir; return 1; }; reset_acme_state; pause_enter '  按回车返回修改节点菜单...';;
            2)
                read_input value "  请输入新的服务器公网 IP (回车保持 $server): " || return 1; value=${value:-$server}; valid_ip_literal "$value" || { fail '服务器地址必须是 IPv4 或 IPv6 地址'; continue; }
                printf '  服务器公网 IP：%s\n' "$value"; [[ "$value" == "$server" ]] && { pause_enter '  按回车返回修改节点菜单...'; continue; }
                prepare_acme_provider "$value" "$tag" || { cleanup_new_acme_dir; continue; }; provider_tag="$ACME_PROVIDER_TAG"; provider_dir="$ACME_PROVIDER_DIR"; provider_new="$ACME_PROVIDER_NEW"; disable_http="$ACME_DISABLE_HTTP"; disable_tls="$ACME_DISABLE_TLS"; alternative_http_port="$ACME_ALTERNATIVE_HTTP_PORT"
                validate_anytls_acme_port "$port" || { cleanup_new_acme_dir; continue; }
                confirm_node_update || { cleanup_new_acme_dir; (( MENU_CANCELLED )) && return 1; continue; }
                apply_anytls_node_update "$tag" "$name" "$value" "$port" "$password" "$provider_tag" "$provider_dir" "$provider_new" "$disable_http" "$disable_tls" "$alternative_http_port" "$tag" '' "$old_dir" "$old_provider_tag" || { cleanup_new_acme_dir; return 1; }; reset_acme_state; pause_enter '  按回车返回修改节点菜单...';;
            3)
                read_input value "  请输入新的监听端口 (回车保持 $port): " || return 1; value=${value:-$port}; valid_port "$value" || { fail '端口应为 1–65535'; continue; }; value=$((10#$value));
                if (( value != port )) && port_conflict "$value" "$tag" tcp; then fail "TCP 端口 $value 已被占用"; continue; fi
                printf '  监听端口：%s\n' "$value"; (( value == port )) && { pause_enter '  按回车返回修改节点菜单...'; continue; }
                if [[ -z "$provider_tag" ]]; then prepare_acme_provider "$server" "$tag" || { cleanup_new_acme_dir; continue; }; provider_tag="$ACME_PROVIDER_TAG"; provider_dir="$ACME_PROVIDER_DIR"; provider_new="$ACME_PROVIDER_NEW"; disable_http="$ACME_DISABLE_HTTP"; disable_tls="$ACME_DISABLE_TLS"; alternative_http_port="$ACME_ALTERNATIVE_HTTP_PORT"; fi
                validate_anytls_acme_port "$value" || { cleanup_new_acme_dir; continue; }
                confirm_node_update || { cleanup_new_acme_dir; (( MENU_CANCELLED )) && return 1; continue; }
                apply_anytls_node_update "$tag" "$name" "$server" "$value" "$password" "$provider_tag" "$provider_dir" "$provider_new" "$disable_http" "$disable_tls" "$alternative_http_port" "$tag" '' "$old_dir" "$old_provider_tag" || { cleanup_new_acme_dir; return 1; }; reset_acme_state; pause_enter '  按回车返回修改节点菜单...';;
            4)
                value=$("$SINGBOX_BIN" generate rand --hex 32 2>/dev/null) || { fail '生成 AnyTLS 密码失败'; continue; }; [[ "$value" =~ ^[0-9a-fA-F]{64}$ ]] || { fail '生成 AnyTLS 密码格式无效'; continue; }
                printf '  密码：%s\n' "$value"; confirm_node_update || { cleanup_new_acme_dir; (( MENU_CANCELLED )) && return 1; continue; }
                if [[ -z "$provider_tag" ]]; then prepare_acme_provider "$server" "$tag" || { cleanup_new_acme_dir; continue; }; provider_tag="$ACME_PROVIDER_TAG"; provider_dir="$ACME_PROVIDER_DIR"; provider_new="$ACME_PROVIDER_NEW"; disable_http="$ACME_DISABLE_HTTP"; disable_tls="$ACME_DISABLE_TLS"; alternative_http_port="$ACME_ALTERNATIVE_HTTP_PORT"; fi
                validate_anytls_acme_port "$port" || { cleanup_new_acme_dir; continue; }
                apply_anytls_node_update "$tag" "$name" "$server" "$port" "$value" "$provider_tag" "$provider_dir" "$provider_new" "$disable_http" "$disable_tls" "$alternative_http_port" "$tag" '' "$old_dir" "$old_provider_tag" || { cleanup_new_acme_dir; return 1; }; reset_acme_state; pause_enter '  按回车返回修改节点菜单...';;
            *) fail '无效选择' ;;
        esac
    done
}

apply_ss2022_node_update() {
    local tag="$1" name="$2" server="$3" port="$4" password="$5" method="$SS2022_METHOD"
    local new_config new_meta count config_matches meta_matches
    new_config=$(mktemp "$SINGBOX_DIR/.config.XXXXXX") || return 1; new_meta=$(mktemp "$SINGBOX_DIR/.meta.XXXXXX") || { rm -f "$new_config"; return 1; }
    config_matches=$(jq -r --arg tag "$tag" '[.inbounds[]? | select(.tag==$tag)] | length' "$CONFIG_FILE") || { rm -f "$new_config" "$new_meta"; return 1; }
    meta_matches=$(jq -r --arg tag "$tag" '[.nodes[]? | select(.tag==$tag)] | length' "$META_FILE") || { rm -f "$new_config" "$new_meta"; return 1; }
    [[ "$config_matches" == 1 && "$meta_matches" == 1 ]] || { rm -f "$new_config" "$new_meta"; fail '目标节点信息不一致，未应用修改，请重新进入菜单'; return 1; }
    jq --arg tag "$tag" --arg password "$password" --argjson port "$port" '(.inbounds[] | select(.tag==$tag)) |= (.listen_port=$port | .method="2022-blake3-aes-128-gcm" | .password=$password)' "$CONFIG_FILE" > "$new_config" || { rm -f "$new_config" "$new_meta"; return 1; }
    jq --arg tag "$tag" --arg name "$name" --arg server "$server" --arg password "$password" --argjson port "$port" '(.nodes[] | select(.tag==$tag)) |= (.protocol="ss2022" | .name=$name | .server=$server | .port=$port | .method="2022-blake3-aes-128-gcm" | .password=$password)' "$META_FILE" > "$new_meta" || { rm -f "$new_config" "$new_meta"; return 1; }
    jq -e --arg tag "$tag" --arg password "$password" --argjson port "$port" 'any(.inbounds[]?; .tag==$tag and .type=="shadowsocks" and (.listen_port|tonumber?)==$port and .method=="2022-blake3-aes-128-gcm" and .password==$password)' "$new_config" >/dev/null 2>&1 || { rm -f "$new_config" "$new_meta"; fail 'Shadowsocks 配置修改结果校验失败'; return 1; }
    jq -e --arg tag "$tag" --arg name "$name" --arg server "$server" --arg password "$password" --argjson port "$port" 'any(.nodes[]?; .tag==$tag and (.protocol // "vless-reality")=="ss2022" and .name==$name and .server==$server and (.port|tonumber?)==$port and .method=="2022-blake3-aes-128-gcm" and .password==$password)' "$new_meta" >/dev/null 2>&1 || { rm -f "$new_config" "$new_meta"; fail 'Shadowsocks 元数据修改结果校验失败'; return 1; }
    count=$(node_count); if apply_transaction "$new_config" "$new_meta" "$count"; then
        success "节点 [$name] 修改成功"; printf '  %s节点链接:%s %s%s%s\n' "$YELLOW" "$NC" "$GREEN" "$(build_ss2022_link "$server" "$port" "$password" "$name")" "$NC"
    else rm -f "$new_config" "$new_meta"; return 1; fi
}

modify_ss2022_node() {
    local index="$1" tag name server port password choice value
    tag=$(jq -r --argjson i "$index" '.nodes[$i].tag' "$META_FILE")
    while true; do
        name=$(jq -r --argjson i "$index" '.nodes[$i].name' "$META_FILE"); server=$(jq -r --argjson i "$index" '.nodes[$i].server' "$META_FILE"); port=$(jq -r --argjson i "$index" '.nodes[$i].port' "$META_FILE"); password=$(jq -r --argjson i "$index" '.nodes[$i].password' "$META_FILE")
        printf '\n  当前节点: %s%s%s (ss2022) @ %s%s%s\n\n' "$GREEN" "$name" "$NC" "$BLUE" "$port" "$NC"
        printf '  %s[1]%s 修改节点名称\n  %s[2]%s 修改客户端连接地址\n  %s[3]%s 修改监听端口\n  %s[4]%s 重新生成密码\n  %s[0]%s 返回\n' "$GREEN" "$NC" "$GREEN" "$NC" "$GREEN" "$NC" "$GREEN" "$NC" "$GREEN" "$NC"
        read_input choice '  请选择修改项: ' || return 1
        case "$choice" in
            0) return 0 ;;
            1) read_input value "  请输入新节点名称 (回车保持 $name): " || return 1; value=${value:-$name}; valid_name "$value" || { fail '节点名称无效'; continue; }; printf '  节点名称：%s\n' "$value"; [[ "$value" == "$name" ]] && { pause_enter '  按回车返回修改节点菜单...'; continue; }; confirm_node_update || { (( MENU_CANCELLED )) && return 1; continue; }; apply_ss2022_node_update "$tag" "$value" "$server" "$port" "$password" || return 1; pause_enter '  按回车返回修改节点菜单...' ;;
            2) read_input value "  请输入新的客户端连接地址 (回车保持 $server): " || return 1; value=${value:-$server}; valid_text "$value" || { fail '客户端连接地址无效'; continue; }; printf '  客户端连接地址：%s\n' "$value"; [[ "$value" == "$server" ]] && { pause_enter '  按回车返回修改节点菜单...'; continue; }; confirm_node_update || { (( MENU_CANCELLED )) && return 1; continue; }; apply_ss2022_node_update "$tag" "$name" "$value" "$port" "$password" || return 1; pause_enter '  按回车返回修改节点菜单...' ;;
            3) read_input value "  请输入新的监听端口 (回车保持 $port): " || return 1; value=${value:-$port}; valid_port "$value" || { fail '端口应为 1–65535'; continue; }; value=$((10#$value)); if (( value != port )) && port_conflict "$value" "$tag" tcp_udp; then fail "TCP/UDP 端口 $value 已被占用"; continue; fi; printf '  监听端口：%s\n' "$value"; (( value == port )) && { pause_enter '  按回车返回修改节点菜单...'; continue; }; confirm_node_update || { (( MENU_CANCELLED )) && return 1; continue; }; apply_ss2022_node_update "$tag" "$name" "$server" "$value" "$password" || return 1; pause_enter '  按回车返回修改节点菜单...' ;;
            4) value=$("$SINGBOX_BIN" generate rand --base64 16 2>/dev/null) || { fail '生成 Shadowsocks 2022 密码失败'; continue; }; [[ -n "$value" ]] || { fail '生成 Shadowsocks 2022 密码失败'; continue; }; printf '  密码：%s\n' "$value"; confirm_node_update || { (( MENU_CANCELLED )) && return 1; continue; }; apply_ss2022_node_update "$tag" "$name" "$server" "$port" "$value" || return 1; pause_enter '  按回车返回修改节点菜单...' ;;
            *) fail '无效选择' ;;
        esac
    done
}

modify_node() {
    local index protocol
    require_core || return 1
    choose_node index || return 1
    protocol=$(jq -r --argjson i "$index" '.nodes[$i].protocol // "vless-reality"' "$META_FILE")
    case "$protocol" in
        vless-reality) modify_vless_node "$index" ;;
        anytls) require_anytls_core || return 1; modify_anytls_node "$index" ;;
        ss2022) modify_ss2022_node "$index" ;;
        *) fail '节点协议不受支持'; return 1 ;;
    esac
}

delete_node() {
    local index tag name answer new_config new_meta count protocol acme_dir provider_tag
    choose_node index || return 1
    tag=$(jq -r --argjson i "$index" '.nodes[$i].tag' "$META_FILE"); name=$(jq -r --argjson i "$index" '.nodes[$i].name' "$META_FILE")
    protocol=$(jq -r --argjson i "$index" '.nodes[$i].protocol // "vless-reality"' "$META_FILE")
    acme_dir=$(jq -r --argjson i "$index" '.nodes[$i].acme_dir // empty' "$META_FILE")
    provider_tag=$(jq -r --arg tag "$tag" '.inbounds[]? | select(.tag==$tag) | .tls.certificate_provider | if type=="string" then . else empty end' "$CONFIG_FILE")
    if [[ -z "$acme_dir" && -n "$provider_tag" ]]; then
        acme_dir=$(jq -r --arg provider "$provider_tag" '.certificate_providers[]? | select(.tag==$provider) | .data_directory // empty' "$CONFIG_FILE")
    fi
    read_input answer "  确认删除节点 [$name]？(Y/N): " || return 1
    [[ "$answer" == [yY] ]] || return 1
    new_config=$(mktemp "$SINGBOX_DIR/.config.XXXXXX") || return 1; new_meta=$(mktemp "$SINGBOX_DIR/.meta.XXXXXX") || { rm -f "$new_config"; return 1; }
    jq --arg tag "$tag" 'del(.inbounds[] | select(.tag==$tag))' "$CONFIG_FILE" > "$new_config" || return 1
    jq --arg tag "$tag" 'del(.nodes[] | select(.tag==$tag))' "$META_FILE" > "$new_meta" || return 1
    if [[ -n "$provider_tag" ]]; then
        jq --arg provider "$provider_tag" '. as $root | if any($root.inbounds[]?; .tls.certificate_provider==$provider) then . else .certificate_providers |= map(select(.tag != $provider)) end' "$new_config" > "${new_config}.clean" && mv -f "${new_config}.clean" "$new_config" || { rm -f "$new_config" "${new_config}.clean" "$new_meta"; return 1; }
    fi
    count=$(node_count); count=$((count - 1))
    if apply_transaction "$new_config" "$new_meta" "$count"; then
        if [[ "$protocol" == anytls && -n "$acme_dir" && "$acme_dir" == "$ACME_DIR/"* ]] && ! jq -e --arg dir "$acme_dir" 'any(.nodes[]?; (.protocol // "vless-reality")=="anytls" and .acme_dir==$dir)' "$META_FILE" >/dev/null 2>&1; then
            rm -rf -- "$acme_dir"
        fi
        success "节点 [$name] 已删除"
    else
        rm -f "$new_config" "$new_meta"
        return 1
    fi
}

clear_nodes() {
    local count answer new_config new_meta
    count=$(node_count); (( count > 0 )) || { warn '暂无节点'; return 0; }
    read_input answer "  确认清空全部 $count 个节点？(Y/N): " || return 1
    [[ "$answer" == [yY] ]] || return 1
    new_config=$(mktemp "$SINGBOX_DIR/.config.XXXXXX") || return 1; new_meta=$(mktemp "$SINGBOX_DIR/.meta.XXXXXX") || { rm -f "$new_config"; return 1; }
    jq '.inbounds=[] | .certificate_providers=[]' "$CONFIG_FILE" > "$new_config" || return 1; jq '.nodes=[]' "$META_FILE" > "$new_meta" || return 1
    if apply_transaction "$new_config" "$new_meta" 0; then
        rm -rf -- "$ACME_DIR"
        success '所有节点已清空'
    else
        rm -f "$new_config" "$new_meta"
        return 1
    fi
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
update_script() (
    local temp first version old_hash new_hash target
    info '正在检查管理脚本更新'
    temp=$(mktemp "${SINGBOX_DIR}/.script.XXXXXX") || exit 1
    trap 'rm -f "$temp"' EXIT INT TERM
    get_url "${SCRIPT_URL}?v=$$-$RANDOM" "$temp" || { fail '管理脚本下载失败'; exit 1; }
    IFS= read -r first < "$temp" || true
    [[ "$first" == '#!/usr/bin/env bash' || "$first" == '#!/bin/bash' ]] || { fail '下载内容不是有效 Bash 脚本'; exit 1; }
    bash -n "$temp" || { fail '新版管理脚本语法检查失败'; exit 1; }
    version=$(awk -F'"' '/^SCRIPT_VERSION=/{print $2; exit}' "$temp")
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
    read_input answer '  确认卸载 sing-box、全部节点和管理脚本？(Y/N): ' || return 1
    [[ "$answer" == [yY] ]] || return 1
    svc_stop >/dev/null 2>&1 || true; svc_disable >/dev/null 2>&1 || true
    rm -f -- "$SYSTEMD_UNIT" "$SYSTEMD_STARTUP" "$OPENRC_UNIT" "$OPENRC_STARTUP"
    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload >/dev/null 2>&1 9>&- || true
        systemctl reset-failed sing-box.service >/dev/null 2>&1 9>&- || true
    fi
    rm -rf "$SINGBOX_DIR" "$PID_FILE" "$LOG_FILE" "$LOG_FILE".*
    [[ "$SINGBOX_BIN" == "$CORE_INSTALL_BIN" ]] && rm -f -- "$CORE_INSTALL_BIN"
    rm -f -- "${SCRIPT_TARGET:-/usr/local/bin/s}" "$LOCK_FILE" "$LOCK_PID_FILE"
    rmdir "$(dirname "$PID_FILE")" >/dev/null 2>&1 || true
    success 'sing-box 及其相关文件已卸载'
}

display_width() {
    printf '%s' "$1" | LC_ALL=C awk '
        BEGIN { for (i = 0; i < 256; i++) ord[sprintf("%c", i)] = i }
        {
            width = 0
            bytes = length($0)
            for (i = 1; i <= bytes; i++) {
                code = ord[substr($0, i, 1)]
                if (code < 128) { width += 1; continue }
                if (code >= 192 && code < 224) { i += 1; width += 1; continue }
                if (code >= 224 && code < 240) {
                    unicode = (code - 224) * 4096 \
                        + (ord[substr($0, i + 1, 1)] - 128) * 64 \
                        + (ord[substr($0, i + 2, 1)] - 128)
                    if ((unicode >= 4352 && unicode <= 4447) ||
                        (unicode >= 11904 && unicode <= 12351) ||
                        (unicode >= 12352 && unicode <= 13311) ||
                        (unicode >= 13312 && unicode <= 19903) ||
                        (unicode >= 19968 && unicode <= 40959) ||
                        (unicode >= 40960 && unicode <= 42191) ||
                        (unicode >= 44032 && unicode <= 55203) ||
                        (unicode >= 63744 && unicode <= 64255) ||
                        (unicode >= 65040 && unicode <= 65103) ||
                        (unicode >= 65280 && unicode <= 65376) ||
                        (unicode >= 65504 && unicode <= 65510)) width += 2
                    else width += 1
                    i += 2
                    continue
                }
                if (code >= 240) { i += 3; width += 2; continue }
                width += 1
            }
            printf "%d", width
        }'
}

menu_row() {
    local text="$1" plain width pad
    plain=$(printf '%s' "$text" | sed $'s/\033\\[[0-9;]*m//g')
    width=$(display_width "$plain")
    [[ "$width" =~ ^[0-9]+$ ]] || width=0
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
        printf '%s  ║%39s║%s\n' "$BLUE" '' "$NC"
        menu_row "  ${BLUE}服务管理${NC}"
        menu_row "  ${GREEN}[6]${BLUE}  启动 sing-box${NC}"
        menu_row "  ${GREEN}[7]${BLUE}  停止 sing-box${NC}"
        menu_row "  ${GREEN}[8]${BLUE}  重启 sing-box${NC}"
        printf '%s  ║%39s║%s\n' "$BLUE" '' "$NC"
        menu_row "  ${BLUE}更新与维护${NC}"
        menu_row "  ${GREEN}[9]${BLUE}  安装/更新核心${NC}"
        menu_row "  ${GREEN}[10]${BLUE} 更新管理脚本${NC}"
        menu_row "  ${GREEN}[11]${BLUE} 一键卸载${NC}"
        printf '%s  ║%39s║%s\n' "$BLUE" '' "$NC"
        menu_row "  ${GREEN}[0]${BLUE}  退出脚本${NC}"
        printf '%s  ╚═══════════════════════════════════════╝%s\n\n' "$BLUE" "$NC"
        local status=0
        read -r -p '  请输入选项 [0-11]: ' choice || status=$?
        (( status == 130 )) && interrupt_exit
        (( status != 0 )) && return 0
        case "$choice" in
            1) add_node ;; 2) view_nodes ;; 3) modify_node ;; 4) delete_node ;; 5) clear_nodes ;;
            6) printf '\n'; info '启动 sing-box'; start_service ;;
            7) printf '\n'; info '停止 sing-box'; stop_service ;;
            8) printf '\n'; info '重启 sing-box'; restart_service ;;
            9) update_core ;;
            10)
                if update_management_script; then
                    pause_enter '  按回车加载最新脚本...'
                    (( INPUT_EOF )) && return 0
                    exec bash "${SCRIPT_TARGET:-$0}"
                fi
                ;;
            11) uninstall && return 0 ;; 0) return 0 ;;
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
    maintenance_cleanup
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
