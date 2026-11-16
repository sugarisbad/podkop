#!/bin/ash
# Integration checks using real OpenWrt UCI in an isolated directory.
# The runner supplies a library with filesystem/service paths redirected here.
set -eu
root="$1"
library="$2"
mkdir -p "$root/config" "$root/delta"
cat > "$root/config/podkop" <<EOF
config settings 'settings'
    option config_path '$root/sing-box.json'
config section 'main'
    option connection_type 'proxy'
    option proxy_config_type 'selector'
    option subscription_enabled '1'
    option subscription_url 'https://example.invalid/subscription'
    list selector_proxy_links 'socks5://127.0.0.1:1080#Old'
EOF
echo '{"old":true}' > "$root/sing-box.json"
cat > "$root/service" <<EOF
#!/bin/ash
echo "\$1" >> "$root/service.calls"
exit 0
EOF
chmod 700 "$root/service"
PODKOP_CONFIG=podkop
config_load() { :; }
config_get() {
    local value
    value=$(command uci -c "$root/config" -t "$root/delta" -q get "podkop.$2.$3") || value="${4:-}"
    export "$1=$value"
}
config_set() { :; }
uci() {
    case "$1" in
        -c) command uci "$@" ;;
        *) command uci -c "$root/config" -t "$root/delta" "$@" ;;
    esac
}
curl() {
    [ "$download_ok" = 1 ] || return 1
    while [ "$#" -gt 0 ]; do
        if [ "$1" = --output ]; then
            cp "$root/response" "$2"
            return
        fi
        shift
    done
    return 1
}
sing_box_init_config() {
    [ "$candidate_ok" = 1 ] || return 1
    printf '{"candidate":true}\n' > "$SUBSCRIPTION_CHECK_PATH"
}
. "$library"
subscription_wait_running() { [ "$startup_ok" = 1 ]; }
download_ok=1
candidate_ok=1
startup_ok=1
cp "$root/config/podkop" "$root/original.uci"
cp "$root/sing-box.json" "$root/original.json"
printf '%s\n' 'socks5://127.0.0.2:1080#New' > "$root/response"

assert_unchanged() {
    cmp "$root/config/podkop" "$root/original.uci"
    cmp "$root/sing-box.json" "$root/original.json"
}
download_ok=0
if subscription_update main; then exit 1; fi
assert_unchanged
download_ok=1
candidate_ok=0
if subscription_update main; then exit 1; fi
assert_unchanged
candidate_ok=1
startup_ok=0
if subscription_update main; then exit 1; fi
assert_unchanged
startup_ok=1
subscription_update main
[ "$(uci get podkop.main.selector_proxy_links)" = 'socks5://127.0.0.2:1080#New' ]
[ "$(subscription_status main | jq -r .state)" = updated ]
calls=$(wc -l < "$root/service.calls")
subscription_update main
[ "$(subscription_status main | jq -r .state)" = unchanged ]
[ "$(wc -l < "$root/service.calls")" = "$calls" ]
echo 'Download failure, validation failure, rollback, import and no-op checks passed'
