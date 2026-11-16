#!/bin/sh
# Run from the repository root with ash or bash.
set -eu
. ./podkop/files/usr/lib/subscriptions.sh
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

a='vless://00000000-0000-0000-0000-000000000001@example.org:443?security=tls#A'
b='trojan://test@example.net:443?security=tls#B'
printf '%s\n%s\n%s\n' "$b" "$a" "$a" > "$work/plain"
subscription_parse "$work/plain" "$work/result"
[ "$(wc -l < "$work/result")" -eq 2 ]
base64 < "$work/plain" > "$work/encoded"
subscription_parse "$work/encoded" "$work/decoded"
cmp "$work/result" "$work/decoded"
tr -d '=\n' < "$work/encoded" > "$work/unpadded"
subscription_parse "$work/unpadded" "$work/decoded"
cmp "$work/result" "$work/decoded"
printf '%s\r\n%s\r\n' "$a" "$b" > "$work/crlf"
subscription_parse "$work/crlf" "$work/decoded"
cmp "$work/result" "$work/decoded"

reject() {
    cp "$work/result" "$work/untouched"
    if subscription_parse "$work/bad" "$work/untouched"; then
        echo "Unexpectedly accepted: $1" >&2
        exit 1
    fi
    cmp "$work/result" "$work/untouched"
}
: > "$work/bad"
reject empty
printf '<html>Sign in</html>' > "$work/bad"
reject html
printf '{"outbounds":[]}' > "$work/bad"
reject json
printf '%s\nvmess://unsupported\n' "$a" > "$work/bad"
reject mixed-unsupported
printf '%s\nnot a proxy\n' "$a" > "$work/bad"
reject partial
printf 'a===' > "$work/bad"
reject broken-base64
i=0
: > "$work/bad"
while [ "$i" -lt 257 ]; do
    printf '%s\n' "$a" >> "$work/bad"
    i=$((i + 1))
done
reject too-many-nodes
config_get() { enabled=1; }
first=$(subscription_node_section main "$a" 1)
second=$(subscription_node_section main "${a%#*}#Renamed" 9)
[ "$first" = "$second" ]
[ "$first" != "$(subscription_node_section main "$b" 1)" ]
config_get() { enabled=0; }
[ "$(subscription_node_section main "$a" 3)" = main-3 ]
echo 'Subscription parser and stable identity checks passed'
