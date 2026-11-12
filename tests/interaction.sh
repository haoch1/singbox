#!/usr/bin/env bash
# Run with Bash and jq; all service and transaction effects are replaced below.
set -uo pipefail
exec 3>&2
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." || exit 1
source ./singbox.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/interaction.XXXXXX") || exit 1
test_pid=$BASHPID
trap 'if [[ $BASHPID == "$test_pid" ]]; then rm -f -- "$work"/* "$work"/.[!.]*; rmdir -- "$work"; fi' EXIT
if [[ -n ${JQ_BIN:-} ]]; then
    jq() { "$JQ_BIN" --binary "$@"; }
fi
command -v jq >/dev/null || { printf 'jq is required\n' >&2; exit 1; }
passed=0
bad() { printf 'FAIL: %s\n' "$*" >&3; cat "$work/output" >&3; exit 1; }
check() { "$@" || bad "$*"; }
pass() { passed=$((passed + 1)); printf 'PASS %s\n' "$1"; }
read() {
    local arg prompt_next=0
    for arg in "$@"; do
        if ((prompt_next)); then printf '%s\n' "$arg" >> "$work/prompts"; break; fi
        [[ $arg != -p ]] || prompt_next=1
    done
    builtin read "$@"
}
reset_case() { MENU_CANCELLED=0 INPUT_EOF=0; : > "$work/prompts"; : > "$work/output"; }
prompt_count() { check test "$(wc -l < "$work/prompts")" -eq "$1"; }
for reply in '' n N q Q; do
    reset_case
    confirm_action 'confirm' <<< "$reply" > "$work/output" 2>&1 && bad 'destructive action accepted cancellation'
    check test "$MENU_CANCELLED" -eq 1
    prompt_count 1
done
for reply in y Y; do
    reset_case
    check confirm_action 'confirm' <<< "$reply" > "$work/output" 2>&1
    prompt_count 1
done
reset_case
check confirm_action 'confirm' <<< $'invalid\ny' > "$work/output" 2>&1
prompt_count 2
check grep -q '请输入 y 或 n' "$work/output"
reset_case
confirm_action 'confirm' < /dev/null > "$work/output" 2>&1 && bad 'EOF confirmed action'
check test "$INPUT_EOF" -eq 1
pass 'confirmation defaults, invalid input, q/Q and EOF'

# Menu effects use markers; reading a result must never consume the next option.
menu_effect() { printf '%s\n' "$1" >> "$work/actions"; printf 'result:%s\n' "$1"; }
setup_menu_stubs() {
    core_version() { printf '1.14.0'; }
    node_count() { printf '1'; }
    svc_active() { return 1; }
    view_nodes() { menu_effect view; }
    start_service() { menu_effect start; }
    stop_service() { menu_effect stop; }
    restart_service() { menu_effect restart; }
    update_core() { menu_effect core; }
    update_management_script() { menu_effect script; }
    uninstall() { menu_effect uninstall; }
}
(
    setup_menu_stubs
    : > "$work/actions"
    reset_case
    menu <<< $'2\n6\n7\n8\n9\nq' > "$work/output" 2>&1 || bad 'menu failed'
    check test "$(cat "$work/actions")" = $'view\nstart\nstop\nrestart\ncore'
    prompt_count 6
    check grep -q 'result:view' "$work/output"
    if grep -q $'\033\\[' "$work/output"; then
        # Colour is fine; erase-screen and erase-scrollback escape codes are not.
        grep -qE $'\033\\[(2J|3J|H)' "$work/output" && bad 'result was cleared'
    fi
    reset_case
    menu < /dev/null > "$work/output" 2>&1 || bad 'menu EOF failed'
    prompt_count 1
    reset_case
    menu <<< Q > "$work/output" 2>&1 || bad 'Q did not exit'
    prompt_count 1
    reset_case
    menu <<< $'invalid\n0' > "$work/output" 2>&1 || bad 'invalid menu input failed'
    prompt_count 2
    pass 'consecutive actions, visible results, invalid menu input and exit'
) || exit 1

# Reload is intercepted here so no installed command or real service is touched.
(
    setup_menu_stubs
    exec() { touch "$work/reloaded"; INPUT_EOF=1; }; SCRIPT_TARGET=$work/unused
    reset_case
    menu <<< 10 > "$work/output" 2>&1 || bad 'script update failed'
    prompt_count 1
    check test -f "$work/reloaded"
    pass 'script updates reload without another read'
) || exit 1

SINGBOX_DIR=$work
CONFIG_FILE=$work/config.json
META_FILE=$work/nodes.json
SINGBOX_BIN=$work/core
cat > "$SINGBOX_BIN" <<'CORE'
#!/usr/bin/env bash
if [[ $2 == uuid ]]; then printf '22222222-2222-2222-2222-222222222222\n'; else printf 'new-secret\n'; fi
CORE
chmod +x "$SINGBOX_BIN"
require_core() { return 0; }
port_conflict() { return 1; }
generate_credentials() { NEW_PRIVATE=new-private NEW_PUBLIC=new-public NEW_SHORT_ID=abcd; }
apply_transaction() {
    jq -e --argjson count "$3" '.nodes | length == $count' "$2" >/dev/null || return 1
    mv -f "$1" "$CONFIG_FILE" && mv -f "$2" "$META_FILE" || return 1
    printf 'applied\n' >> "$work/transactions"
}
fixture() {
    : > "$work/transactions"
    jq -n --arg protocol "${1:-vless-reality}" '{nodes:[{protocol:$protocol,tag:"test",name:"original",server:"example.com",port:1080,
        uuid:"11111111-1111-1111-1111-111111111111",sni:"old.example",public_key:"old-public",short_id:"1234",password:"old-secret",psk:"old-secret",version:5}]}' > "$META_FILE"
    jq -n --arg protocol "${1:-vless-reality}" '{inbounds:[{tag:"test",type:(if $protocol=="vless-reality" then "vless" elif $protocol=="ss2022" then "shadowsocks" else $protocol end),
        version:5,listen_port:1080,password:"old-secret",psk:"old-secret",users:[{uuid:"11111111-1111-1111-1111-111111111111",password:"old-secret"}],
        tls:{server_name:"old.example",reality:{handshake:{server:"old.example"},private_key:"old-private",short_id:["1234"]}}}]}' > "$CONFIG_FILE"
}
for protocol in vless-reality ss2022 anytls hysteria2 snell; do
    fixture "$protocol"
    reset_case
    edit_input=$'1\nnew-name\n2\nnew.example\n3\n20000\n4'
    case $protocol in
        vless-reality) edit_input+=$'\n22222222-2222-2222-2222-222222222222\n5\nnew.sni\n6\n0'; expected=6; reads=12 ;;
        ss2022) edit_input+=$'\n0'; expected=4; reads=8 ;;
        *) edit_input+=$'\nnew-secret\n0'; expected=4; reads=9 ;;
    esac
    check modify_node <<< $'1\n'"$edit_input" > "$work/output" 2>&1
    prompt_count "$((reads + 1))"
    check test "$(wc -l < "$work/transactions")" -eq "$expected"
    check jq -e '.nodes[0] | .name=="new-name" and .server=="new.example" and .port==20000' "$META_FILE" >/dev/null
    check jq -e '.inbounds[0].listen_port==20000' "$CONFIG_FILE" >/dev/null
    if [[ $protocol == vless-reality ]]; then
        check jq -e '.nodes[0] | .sni=="new.sni" and .uuid=="22222222-2222-2222-2222-222222222222" and .public_key=="new-public"' "$META_FILE" >/dev/null
    else
        check jq -e '.nodes[0] | (if .protocol=="snell" then .psk else .password end)=="new-secret"' "$META_FILE" >/dev/null
    fi
    pass "$protocol edits apply each selected field without confirmation or pause"
done
for reply in q Q; do
    fixture
    reset_case
    modify_node <<< $'1\n1\n'"$reply" > "$work/output" 2>&1 && bad 'cancelled edit succeeded'
    prompt_count 3
    check test ! -s "$work/transactions"
done
fixture
reset_case
modify_node <<< $'1\n1' > "$work/output" 2>&1 && bad 'EOF edit succeeded'
check test "$INPUT_EOF" -eq 1
check test ! -s "$work/transactions"
reset_case
check modify_node <<< $'1\n1\n\n0' > "$work/output" 2>&1
prompt_count 4
check test ! -s "$work/transactions"
pass 'cancelled, unchanged and incomplete edits do not save'

for reply in '' 0 00 q Q; do
    fixture
    reset_case
    delete_node <<< "$reply" > "$work/output" 2>&1 && bad 'cancelled deletion succeeded'
    check test ! -s "$work/transactions"
done
fixture
reset_case
check delete_node <<< 1 > "$work/output" 2>&1
prompt_count 1
check grep -q '选中即删除' "$work/prompts"
check jq -e '.nodes|length==0' "$META_FILE" >/dev/null
check jq -e '.inbounds|length==0' "$CONFIG_FILE" >/dev/null
pass 'single deletion uses only the explicit selector'

for reply in '' n q; do
    fixture
    reset_case
    clear_nodes <<< "$reply" > "$work/output" 2>&1 && bad 'clear accepted cancellation'
    prompt_count 1
    check test ! -s "$work/transactions"
    reset_case
    uninstall <<< "$reply" > "$work/output" 2>&1 && bad 'uninstall accepted cancellation'
    prompt_count 1
done
fixture
reset_case
check clear_nodes <<< y > "$work/output" 2>&1
prompt_count 1
check jq -e '.nodes|length==0' "$META_FILE" >/dev/null
pass 'clear requires one confirmation and uninstall cancels before service effects'
printf 'All sing-box interaction checks passed.\n'
