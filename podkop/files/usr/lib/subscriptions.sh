#!/bin/ash
# Subscription data is imported into the existing selector/URLTest list.
# Never print download responses, URLs, or parser diagnostics (they contain keys).

subscription_parse() (
    local input="$1" output="$2" work line scheme count=0
    umask 077
    work=$(mktemp -d) || exit 1
    trap 'rm -rf "$work"' EXIT
    [ "$(wc -c < "$input")" -le 1048576 ] || exit 1
    tr -d '\r' < "$input" > "$work/text"
    if ! grep -q '://' "$work/text"; then
        tr -d ' \t\r\n' < "$work/text" | tr '_-' '/+' > "$work/base64"
        case $(($(wc -c < "$work/base64") % 4)) in
            1) exit 1 ;;
            2) printf '==' >> "$work/base64" ;;
            3) printf '=' >> "$work/base64" ;;
        esac
        base64 -d "$work/base64" > "$work/text" 2>/dev/null || exit 1
    fi
    : > "$work/links"
    while IFS= read -r line || [ -n "$line" ]; do
        [ -z "$line" ] && continue
        [ "${#line}" -le 16384 ] || exit 1
        case "$line" in *[[:space:][:cntrl:]]*) exit 1 ;; esac
        scheme=${line%%://*}
        case "$scheme" in
            vless|ss|trojan|socks4|socks4a|socks5|hy2|hysteria2) ;;
            *) exit 1 ;;
        esac
        [ "$line" != "$scheme" ] || exit 1
        printf '%s\n' "$line" >> "$work/links"
        count=$((count + 1))
        [ "$count" -le 256 ] || exit 1
    done < "$work/text"
    [ "$count" -gt 0 ] || exit 1
    # Sorting makes a server-side reorder a no-op. Exact duplicates are removed.
    LC_ALL=C sort -u "$work/links" > "$output"
)

subscription_node_section() {
    local section="$1" link="$2" index="$3" enabled
    config_get enabled "$section" "subscription_enabled" 0
    if [ "$enabled" = 1 ]; then
        # The display name is not part of node identity.
        printf '%s-sub-%s' "$section" "$(printf '%s' "${link%%#*}" | md5sum | cut -d ' ' -f 1)"
    else
        printf '%s-%s' "$section" "$index"
    fi
}

subscription_status_write() {
    local section="$1" state="$2" count="${3:-0}" last=0
    mkdir -p /tmp/podkop-subscriptions
    chmod 700 /tmp/podkop-subscriptions
    [ -f "/tmp/podkop-subscriptions/$section.json" ] &&
        last=$(jq -r '.last_success // 0' "/tmp/podkop-subscriptions/$section.json")
    case "$state" in updated|unchanged) last=$(date +%s) ;; esac
    jq -n --arg state "$state" --argjson count "$count" --argjson last "$last" \
        '{state:$state,count:$count,last_success:$last}' > "/tmp/podkop-subscriptions/$section.json"
}

subscription_status() {
    case "$1" in ''|*[!a-zA-Z0-9_]*) return 1 ;; esac
    if [ -f "/tmp/podkop-subscriptions/$1.json" ]; then
        cat "/tmp/podkop-subscriptions/$1.json"
    else
        echo '{"state":"never","count":0,"last_success":0}'
    fi
}

subscription_update() (
    local section="$1" mode="${2:-}" enabled type url option work links count current now last interval path line
    set -f
    config_load "$PODKOP_CONFIG"
    case "$section" in ''|*[!a-zA-Z0-9_]*) return 1 ;; esac
    config_get enabled "$section" subscription_enabled 0
    config_get type "$section" proxy_config_type
    config_get url "$section" subscription_url
    [ "$enabled" = 1 ] || return 1
    case "$type" in selector|urltest) option="${type}_proxy_links" ;; *) return 1 ;; esac
    if [ "$mode" = scheduled ]; then
        config_get interval "$section" subscription_interval 12
        case "$interval" in 6|12|24) ;; *) return 0 ;; esac
        last=$(subscription_status "$section" | jq -r '.last_success')
        now=$(date +%s)
        [ "$((now - last))" -ge "$((interval * 3600))" ] || return 0
    fi
    umask 077
    mkdir /tmp/podkop-subscription.lock 2>/dev/null || return 1
    work=$(mktemp -d) || { rmdir /tmp/podkop-subscription.lock; return 1; }
    trap 'rm -rf "$work"; rmdir /tmp/podkop-subscription.lock' EXIT
    trap 'exit 1' HUP INT TERM
    # Do not commit or overwrite pending LuCI edits.
    [ -z "$(uci changes podkop)" ] || {
        subscription_status_write "$section" pending_changes
        return 1
    }
    case "$url" in https://*) ;; *)
        subscription_status_write "$section" invalid_url
        return 1 ;;
    esac
    case "$url" in *[[:space:][:cntrl:]]*|*\"*|*\\*)
        subscription_status_write "$section" invalid_url
        return 1 ;;
    esac
    cp /etc/config/podkop "$work/uci.before" || return 1
    # Keep the bearer URL out of the process command line.
    printf 'url = "%s"\n' "$url" > "$work/curl"
    if ! curl --config "$work/curl" --silent --fail --location --max-redirs 3 \
        --proto '=https' --proto-redir '=https' --connect-timeout 10 --max-time 45 \
        --max-filesize 1048576 --user-agent 'Podkop/Subscription' \
        --output "$work/body" 2>/dev/null; then
        subscription_status_write "$section" download_failed
        return 1
    fi
    if ! subscription_parse "$work/body" "$work/links"; then
        subscription_status_write "$section" invalid_subscription
        return 1
    fi
    links=$(cat "$work/links")
    count=$(wc -l < "$work/links")
    config_get current "$section" "$option"
    printf '%s\n' $current | LC_ALL=C sort -u > "$work/current"
    if cmp -s "$work/current" "$work/links"; then
        subscription_status_write "$section" unchanged "$count"
        return 0
    fi
    config_get path settings config_path
    [ -n "$path" ] || return 1
    # Build the whole candidate using in-memory UCI values, without touching
    # firewall/DNS/service state. Parser failures exit only the child subshell.
    if ! (
        log() { :; }
        config_set "$section" "$option" "$links"
        SUBSCRIPTION_CHECK_PATH="$work/candidate.json"
        sing_box_init_config
    ) > "$work/check.log" 2>&1; then
        subscription_status_write "$section" validation_failed
        return 1
    fi
    [ -f "$work/candidate.json" ] || return 1
    # Recheck after the download/build, which can take several seconds.
    if ! cmp -s /etc/config/podkop "$work/uci.before" || [ -n "$(uci changes podkop)" ]; then
        subscription_status_write "$section" pending_changes
        return 1
    fi
    # Use an isolated UCI staging directory: no partially edited live lists.
    mkdir "$work/config" "$work/delta"
    cp "$work/uci.before" "$work/config/podkop"
    uci -c "$work/config" -t "$work/delta" -q delete "podkop.$section.$option"
    while IFS= read -r line; do
        uci -c "$work/config" -t "$work/delta" add_list "podkop.$section.$option=$line" || return 1
    done < "$work/links"
    uci -c "$work/config" -t "$work/delta" commit podkop || return 1
    # The last working generated config is retained until restart succeeds.
    [ -f "$path" ] && cp "$path" "$work/previous.json"
    cp "$work/candidate.json" "$path.subscription-new" || return 1
    mv "$path.subscription-new" "$path" || return 1
    if ! /etc/init.d/sing-box restart > /dev/null 2>&1 || ! subscription_wait_running; then
        [ -f "$work/previous.json" ] && cp "$work/previous.json" "$path"
        /etc/init.d/sing-box restart > /dev/null 2>&1
        subscription_status_write "$section" apply_failed
        return 1
    fi
    if ! cp "$work/config/podkop" /etc/config/podkop.subscription-new ||
        ! mv /etc/config/podkop.subscription-new /etc/config/podkop; then
        [ -f "$work/previous.json" ] && cp "$work/previous.json" "$path"
        /etc/init.d/sing-box restart > /dev/null 2>&1
        subscription_status_write "$section" apply_failed
        return 1
    fi
    subscription_status_write "$section" updated "$count"
)

subscription_wait_running() {
    local attempt=0
    while [ "$attempt" -lt 5 ]; do
        sleep 1
        if /etc/init.d/sing-box running && pidof sing-box >/dev/null; then
            return 0
        fi
        attempt=$((attempt + 1))
    done
    return 1
}

subscription_update_scheduled() {
    subscription_update "$1" scheduled
}

subscription_cron_install() {
    (crontab -l 2>/dev/null | grep -v '/usr/bin/podkop subscription_update_all'
        echo '23 * * * * /usr/bin/podkop subscription_update_all') | crontab -
}
