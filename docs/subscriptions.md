# Subscriptions (fork)

In **Sections**, select **Selector** (manual choice) or **URLTest** (automatic
latency testing), enable **Subscription**, and enter an HTTPS subscription URL.
Save and apply, then press **Update now**. Reload the page after updating to read
the imported links. The existing Dashboard displays and selects these nodes.

The saved subscription replaces the selected mode's proxy list. Keep a copy of
hand-written links before enabling it. The last successfully imported list is
stored in UCI and survives reboot; an empty or invalid response does not erase it.
For a new empty section, save the settings and run the first import before
starting Podkop. Downloads use the router's normal network route.

Supported input: UTF-8 plaintext links or Base64 (including unpadded and URL-safe
Base64). Supported schemes: VLESS, Shadowsocks, Trojan, SOCKS4/4a/5 and Hysteria2.
All links must be supported and accepted by the installed sing-box. JSON, YAML,
HTML login pages and mixed unsupported lists are rejected as a whole.

Limits: HTTPS with certificate verification, 45 seconds, 1 MiB, 256 links, three
HTTPS redirects. Tokens and responses are excluded from status output and masked
in Podkop configuration diagnostics.

## Refresh and recovery

- Manual refresh or 6/12/24-hour scheduling; cron checks due sections hourly.
- Download and parse in a private temporary directory.
- Deduplicate and sort; reordering alone does not restart sing-box.
- Build a complete candidate from the existing Podkop settings, then run
  `sing-box check` before applying.
- Refuse an update while UCI has uncommitted edits.
- Keep the old generated config during application; restore it if restart fails.
- Stable outbound tags ignore display names and list positions. An existing
  selection can be restored by sing-box's cache. If the selected node disappears,
  the selector's default is used (first node or URLTest).
- Status and refresh timestamps are in RAM; reboot resets the schedule timestamp.

Commands:

```sh
podkop subscription_update main
podkop subscription_status main
podkop subscription_update_all
```

Initial scope does not include quota/expiry display, an explicit download proxy,
or a connectivity probe proving that a node passes real traffic. Successful
configuration validation and process startup do not guarantee remote reachability.

Parser checks: `sh tests/subscriptions.sh` from the repository root.
