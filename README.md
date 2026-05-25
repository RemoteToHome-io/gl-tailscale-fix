# gl-tailscale-fix

Plugin package that fixes and enhances the Tailscale integration on GL.iNet routers. Adds missing features through GUI controls injected into the existing GL admin Tailscale page — no GL scripts or binaries are modified from their factory state.

**[Setup Guide & User Documentation](https://remotetohome.io/gl-tailscale-fix)** — screenshots, step-by-step exit node setup, kill switch verification, DNS configuration, Tailscale admin console walkthrough.

![Tailscale Enhanced controls](.github/images/gl-tailscale-fix-v1020.webp)

## Features

- **Routing Kill Switch** — policy routing rules that block LAN/guest→WAN traffic at the kernel routing layer, before conntrack and firewall evaluation. Prevents even established connections from leaking when the exit node drops. Persists through daemon crashes, OOM kills, reboots, and service restarts. Covers both IPv4 and IPv6 (v1.0.20+).
- **Advertise as Exit Node** — GUI toggle for `tailscale set --advertise-exit-node`. No SSH or script modification required.
- **Guest Network Access** — bidirectional firewall forwardings between guest network (br-guest) and Tailscale interface (tailscale0), guest subnet route advertisement, and policy route fixup that ensures guest clients can use exit nodes and are covered by the kill switch.
- **Tailscale SSH** — GUI toggle for `tailscale set --ssh`, which enables Tailscale's ACL-based SSH authentication. Most users don't need this — SSH to the router's tailscale IP already works via the normal SSH daemon (Dropbear) without any extra setup. Enable this only if you specifically want identity-based access controlled by a Tailscale SSH ACL rule (Access Controls → Tailscale SSH tab). While enabled, `tailscaled` takes over port 22 for tailnet-origin traffic, which breaks SSH from LAN clients that reach the router via Tailscale subnet routing; in that case, run Dropbear on an alternate port (System → Administration → SSH Access) to keep a path open for both Tailscale and LAN clients.
- **Tailscale Version Manager** — installed vs latest version display, one-click update using space-optimized combined binaries, factory restore.

  > **⚠️ Do not run `tailscale update` from SSH or use the Tailscale Web Dashboard update button.** These install the standard upstream binaries (~37MB daemon + ~15MB CLI = ~52MB total). GL routers have limited flash overlay — installing 52MB of binaries can exhaust the overlay filesystem and potentially brick the router. The Version Manager uses [Admonstrator's combined binaries](https://github.com/Admonstrator/glinet-tailscale-updater) (~5.3MB) which actually *free* space compared to GL's factory binary (~23MB). If you accidentally run `tailscale update`, use the **Restore** button to revert to factory, then update through the plugin.

- **Plugin Update Notification** — automatically checks GitHub for newer gl-tailscale-fix releases and shows an update badge with download link in the admin panel. Version caches expire after 72 hours; a ↻ button provides on-demand refresh.
- **Subnet Routing Fix** — automatically enables masquerade on the tailscale0 firewall zone (`masq` for IPv4 and, since v1.0.20, `masq6` for IPv6). Tailscale's built-in SNAT can fail to reinitialize after daemon restart, particularly on fw3 (iptables) kernels, causing cross-subnet LAN traffic from client devices to break. The plugin's masquerade provides defense-in-depth SNAT at the firewall layer. On pre-4.9 firmware where the router is advertising as a Tailscale exit node, the plugin also ensures `wan.masq6` is set as a defense-in-depth backstop — Tailscale's own IPv6 SNAT chain (`ts-postrouting` in `ip6 nat`) is empty on iptables-based firmware, so IPv6 egress for tailnet clients using this router as an exit node depends entirely on GL's `wan.masq6` setting. GL generally sets this on its own; the plugin guarantees it as a safety net in case GL's defaults vary by model or firmware variant. On firmware 4.9+, GL owns the IP Masquerading toggle natively and the plugin defers to it entirely. Applied automatically — no user action required.
- **Clean integration** — no GL scripts or binaries are altered from their factory state. If a modified `gl_tailscale` wrapper is detected during installation (e.g. a manual `--advertise-exit-node` modification), the original is automatically restored from ROM to prevent conflicts — the plugin handles exit node natively. This applies to all installation methods (SSH installer, manual opkg, or LuCI upload). All integration through standard OpenWrt interfaces (UCI, hotplug, procd, nginx includes). Clean install and removal.

## Installation

Download the latest `.ipk` from [Releases](https://github.com/RemoteToHome-io/gl-tailscale-fix/releases).

### Option A: One-command installer (recommended)

SSH into your router and run:

```sh
wget -q https://github.com/RemoteToHome-io/gl-tailscale-fix/releases/latest/download/install-gl-tailscale-fix.sh -O install-gl-tailscale-fix.sh && sh install-gl-tailscale-fix.sh
```

The installer downloads the latest `.ipk`, verifies the sha256 checksum, and runs `opkg install`. It also automatically restores the stock `gl_tailscale` wrapper if you previously modified it for exit node support.

### Option B: Manual installation via SSH

From your computer, copy the `.ipk` to the router and install:

```bash
scp -O gl-tailscale-fix_*.ipk root@<router-ip>:/tmp/
ssh root@<router-ip> opkg install /tmp/gl-tailscale-fix_*.ipk
```

### Option C: LuCI web interface

1. Download the `.ipk` file from [Releases](https://github.com/RemoteToHome-io/gl-tailscale-fix/releases) to your computer
2. Open **LuCI** (Advanced Settings) → **System** → **Software**
3. Click **Upload Package** and select the `.ipk` file

> **Note:** If you previously modified `/usr/bin/gl_tailscale` to add `--advertise-exit-node`, the plugin automatically restores the stock version during installation. The plugin handles exit node advertisement natively.

After installation, navigate to **APPLICATIONS → Tailscale** in the GL admin panel. Controls appear below GL's settings under a "Tailscale Enhanced" divider.

> **After clicking Apply**, it's normal for Tailscale to show a yellow/connecting state for 10–20 seconds while settings take effect. Wait for the status to return to green before testing your connection.

For the full setup walkthrough — including exit node configuration, Tailscale admin console approval, DNS setup, and kill switch verification — see the **[setup guide](https://remotetohome.io/gl-tailscale-fix#setup-guide)**.

## Uninstallation

```bash
ssh root@<router-ip> opkg remove gl-tailscale-fix
```

Clean removal — all injected UI, routing rules, firewall forwardings, and config files are removed.

## Architecture

Pure Lua, shell, and vanilla JavaScript — no compiled binaries. Single `.ipk` package under 50KB. Works as a non-invasive overlay — no GL.iNet scripts or binaries are altered from their factory state. All integration uses standard OpenWrt interfaces (UCI, hotplug, procd, nginx includes) and GL's existing extension points. GL-managed UCI attributes touched on pre-4.9 firmware: `firewall.tailscale0.masq` and `firewall.tailscale0.masq6` (masquerade on the Tailscale firewall zone), and `firewall.wan.masq6` when advertising as exit node (backstop for IPv6 SNAT, tracked via sidecar UCI flag so teardown only undoes what we set). On firmware 4.9+ the plugin defers all masquerade management to GL. Install adds files and these attributes; removal leaves the system exactly as it was.

- **Backend**: Custom Lua RPC module (`ts-fix`) loaded by GL's OpenResty API dispatcher. Own UCI config file `/etc/config/ts-fix` — never touches GL's `/etc/config/tailscale`.
- **Frontend**: Vanilla JS injected into GL's SPA via nginx `body_filter_by_lua_file`. No frameworks, no build tools.
- **Persistence**: Multiple mechanisms ensure settings survive GL's `tailscale up --reset` and handle teardown when Tailscale is disabled:
  1. **Hotplug** (priority 20, after GL's 19) — fires on network interface events, re-applies settings after GL restart; also triggers teardown when TS disabled
  2. **JS Apply hook** — fast-path re-apply when the admin page is open
  3. **Watchdog daemon** — polls every 5s using lightweight kernel routing queries (`ip rule`/`ip route`), detects TS disable (full teardown) and exit node removal while kill switch is active (auto-disables KS). Heavy tailscale CLI calls are only spawned when the light check detects a potential problem.
- **Kill switch**: Policy routing (`ip rule` + `ip route`) that catches forwarded traffic at the routing layer — before conntrack and firewall evaluation. Tailscale's exit node uses priority 5270 → table 52; the kill switch inserts priority 5280 → table 100 (`unreachable default`) for both IPv4 and IPv6 (v1.0.20+). When the exit node is active, traffic matches 5270 and never reaches our rule. When the exit node drops, traffic falls through to 5280 and gets an ICMP unreachable. Works on both fw3 (iptables) and fw4 (nftables) since it uses kernel routing, not firewall-specific mechanisms. Router management (admin, SSH, DNS, Tailscale control plane) and LAN-to-LAN traffic are unaffected (`iif br-lan`/`br-guest` only matches forwarded traffic).

  **Note:** The kill switch covers LAN/guest→WAN forwarding. If a competing VPN client (WireGuard, OpenVPN, AmneziaWG) is running on the same VLAN, its fwmark-based policy routing (typically priority 6000) intercepts traffic before Tailscale's exit node routing (priority 5270). Don't run a VPN client tunnel on the same network segment that routes through a Tailscale exit node.

- **Guest routing**: Firewall forwardings (guest↔tailscale0) plus a policy route fixup. When Tailscale advertises a subnet, it creates a source-based rule (`from <subnet> lookup main`) at priority 0. For the primary LAN, Tailscale uses destination-based (`to <subnet>`). The source-based rule catches all guest-originated traffic and sends it to the main table → WAN, bypassing both the exit node and kill switch. gl-tailscale-fix replaces this with a destination-based rule, matching Tailscale's own LAN behavior. This is re-applied after every Tailscale restart.
- **Subnet routing masquerade**: Sets `masq=1` and (since v1.0.20) `masq6=1` on GL's tailscale0 firewall zone (`firewall.tailscale0.masq` / `masq6`). When two GL routers share subnets via Tailscale, Tailscale's built-in SNAT (`--snat-subnet-routes`) handles return routing. However, on fw3 (iptables) kernels, Tailscale's SNAT can fail to reinitialize after a daemon restart — the `cleanup: list tables: netlink receive: invalid argument` error during tailscaled cleanup correlates with this. Router-to-router traffic (SSH, ping from router itself) continues working because it uses the OUTPUT chain; only forwarded LAN client traffic breaks. The plugin's masquerade provides defense-in-depth SNAT at the firewall layer for both IPv4 and IPv6, independent of Tailscale's internal SNAT state. Applied on pre-4.9 firmware (both fw3 and fw4); on firmware 4.9+, GL owns the IP Masquerading toggle natively and the plugin defers to it. Removed on teardown.
- **Exit-node-server IPv6 SNAT backstop** (v1.0.20+, pre-4.9 only): When this router is advertising as a Tailscale exit node, the plugin ensures `firewall.wan.masq6=1`. Tailscale's own `ts-postrouting` IPv6 chain is empty on iptables-based firmware (verified empirically — likely a Tailscale-side iptables-backend gap), so the wan-zone IPv6 masquerade is the only SNAT path for tailnet IPv6 traffic egressing through this router. GL generally sets this on its own; the plugin guarantees it as a safety net in case GL's defaults vary by model or firmware variant. A sidecar UCI flag (`ts-fix.settings.wan_masq6_set_by_plugin`) tracks ownership so teardown only undoes what we set — user or GL-set values are never trampled. On firmware 4.9+ the plugin defers entirely; GL owns this surface.

### File layout

```
/usr/lib/oui-httpd/rpc/ts-fix              Lua RPC module (backend API)
/etc/init.d/ts-fix                         Procd service (runs watchdog daemon)
/etc/hotplug.d/iface/20-ts-fix             Hotplug script (ifup reapply + teardown)
/usr/bin/ts-fix-reapply                    Shared reapply/teardown logic
/usr/bin/ts-fix-watchdog                   Watchdog daemon (TS disable + exit node removal)
/etc/nginx/gl-conf.d/ts-fix.conf           Nginx location + filter config
/usr/share/ts-fix/ts-fix-body-filter.lua   Nginx body filter (script injection)
/usr/share/ts-fix/ts-fix-header-filter.lua Nginx header filter (content-length)
/usr/share/ts-fix/www/ts-fix.js.gz         Frontend JS (gzip_static)
/usr/bin/ts-fix-update                     Tailscale updater script
/etc/config/ts-fix.default                 UCI default config template
/etc/config/ts-fix                         Active UCI config
/lib/upgrade/keep.d/gl-tailscale-fix       Sysupgrade persistence list
```

## Building from source

Requires standard Linux tools (tar, gzip, install). No OpenWrt SDK needed.

```bash
./pkg/build.sh 1.0.20
# Output: build/out/gl-tailscale-fix_1.0.20_all.ipk
```

## Firmware upgrades (sysupgrade)

The plugin survives GL.iNet firmware upgrades automatically on both minor (4.8.x → 4.8.y) and major (4.8.x → 4.9.x) releases. All plugin files, configuration, and any updated Tailscale binary are preserved through sysupgrade via `/lib/upgrade/keep.d/gl-tailscale-fix`. After reboot, settings, kill switch, guest routing, and exit node configuration are restored automatically by the watchdog and hotplug handlers.

On **firmware 4.9+**, the plugin detects the newer firmware and adapts its UI: the Advertise as Exit Node toggle is hidden (GL provides this natively via "Run Exit Node"), and an informational banner explains what the plugin continues to handle on top of GL's native Tailscale integration — Kill Switch, Guest routing through the exit node, Tailscale SSH toggle, and Version Manager. See the [blog post](https://remotetohome.io/blog/gl-tailscale-fix/) for the full rationale.

## Compatibility

**Should work** on any GL.iNet router with native Tailscale support running firmware 4.x (tested on 4.5.22 through 4.9.0). Both fw3 (iptables) and fw4 (nftables) are supported — the kill switch uses kernel routing (not firewall-specific), guest forwardings use GL's UCI abstraction layer.

Starting with **v1.0.19** the plugin coexists with firmware 4.9's native Tailscale enhancements. On 4.9+ the plugin auto-detects the firmware, hides UI for features GL now provides natively (Advertise as Exit Node, WAN subnet advertisement, IP Masquerading), and keeps its own features active — most importantly the daemon-independent kernel-level Kill Switch, which survives `tailscaled` crashes that Tailscale's built-in kill switch cannot. See the [blog post](https://remotetohome.io/blog/gl-tailscale-fix/) for the kill-switch rationale.

Starting with **v1.0.20** the kill switch and the tailscale0 masquerade fixes apply to IPv6 as well as IPv4. On firmware 4.9+ the plugin no longer overrides GL's masquerade settings — if you have both **IP Masquerading** and **Allow Remote Access LAN** turned off on the Tailscale page, GL may leave the tailscale0 zone without IPv6 masquerade, in which case LAN-side IPv6 will not traverse the exit-node tunnel. Enable either setting and IPv6 works. The kill switch still protects on 4.9 regardless of masquerade state.

See the [tested models](#tested-models) appendix for the full compatibility matrix.

## Disclaimer

**No warranty**.  The GL.iNet Tailscale implementation is Beta software and subject to change without notice (including for us).  While we have put extensive effort into testing, this functionality should also be considered beta and we cannot anticipate how future GL firmware changes may impact functionality of this plugin.  We recommend checking here for the latest plugin release before upgrading your GL firmware.  **Use at your own risk** and refer to the testing methodology in our [User Documentation](https://remotetohome.io/gl-tailscale-fix) to personally verify your privacy posture before using in production.

## Contributing

Found a bug? Have a feature request? Tested on a new router model?

- **Bug reports and feature requests**: [Open an issue](https://github.com/RemoteToHome-io/gl-tailscale-fix/issues)
- **Pull requests**: Welcome. The plugin is pure Lua, shell, and vanilla JS — no build toolchain required. See [Architecture](#architecture) for how the pieces fit together.
- **Model testing**: If you verify gl-tailscale-fix on a GL.iNet model not in the [tested models](#tested-models) table, please open an issue with your model, firmware version, and test results.

## Attribution

- Tailscale combined binaries from [glinet-tailscale-updater](https://github.com/Admonstrator/glinet-tailscale-updater) by @Admonstrator
- [TheWiredNomad](https://thewirednomad.com/) for feedback and testing
- Beta testers and feedback from the GL.iNet community
- Claude for hashing out the Lua/frontend, readme docs and code reviews

## License

GPL-3.0. See [LICENSE](LICENSE).

Commercial licensing available for closed source use — contact [remotetohome.io/contact](https://remotetohome.io/contact/).

## Appendix

### Tested Models

| Model | Device | FW | OpenWrt | Firewall | Plugin | Tailscale |
|-------|--------|----|--------|----------|--------|-----------|
| GL-AXT1800 | Slate AX | 4.8.4 | 23.05 | fw4 | v1.0.20 ✓✓✓ | 1.80.3 / 1.96.4 |
| GL-MT3000 | Beryl AX | 4.9.0 | 21.02-SNAPSHOT | fw3 | v1.0.20 ✓✓✓ | 1.92.5 / 1.96.4 |
| GL-MT3000 | Beryl AX | 4.8.2 | 21.02 | fw3 | v1.0.18 | 1.80.3 / 1.94.2 |
| GL-AX1800 | Flint | 4.6.8 | 21.02 | fw3 | v1.0.5 † | 1.66.4 |
| GL-MT2500 | Brume 2 | 4.7.4 | 21.02 | fw3 | v1.0.5 † | 1.66.4 |
| GL-MT6000 | Flint 2 | 4.8.4 | 21.02 | fw3 | v1.0.19 ⊕ | — |
| GL-MT6000 | Flint 2 | 4.8.3 | 24 snapshot | fw4 | v1.0.18 ‡ | — |
| GL-BE3600 | Slate 7 | 4.8.1 | 23.05 | fw4 | v1.0.5 † | 1.80.3 |
| GL-BE6500 | Flint 3 | 4.8.4 | 23.05 | fw4 | v1.0.5 † | 1.92.5 |
| GL-MT5000 | Brume 3 | 4.8.4 | 21.02 | fw4 | v1.0.18 ¶ | 1.80.3 / 1.96.3 |
| GL-MT3600BE | Beryl 7 | 4.8.5 | 21.02 | fw3 | v1.0.18 ‡¶ | 1.94.2 |
| GL-XE3000 | Puli AX | 4.8.3 | 21.02 | fw3 | v1.0.18 ✓ | 1.80.3 / 1.96.3 |
| GL-A1300 | Slate Plus | 4.5.22 / 4.7.2β | — | fw3 | v1.0.18 §  | 1.6x |

**†** Install/remove only.
**‡** Community: install + kill switch + guest ([#1](https://github.com/RemoteToHome-io/gl-tailscale-fix/issues/1)).
**¶** Install + version manager verified.
**✓** Full e2e: exit node server + client, kill switch, version manager.
**✓✓** Full e2e on v1.0.19, including 4.9.0 daemon-stopped leak-block test (zero leak).
**✓✓✓** Full e2e on v1.0.20, adding IPv6 KS leak-block test (zero leak both families) and exit-node-server SNAT for both IPv4 and IPv6.
**⊕** Community install + functional confirmation ([forum](https://forum.gl-inet.com/t/enhanced-tailscale-for-gl-inet-routers-proper-ts-killswitch-one-click-exit-node/67565)).
**§** Install on 4.5.22 + 4.7.2β; KS verified on 4.7.2β; version manager unsupported ([#6](https://github.com/RemoteToHome-io/gl-tailscale-fix/issues/6)).

AXT1800 and MT3000 verified end-to-end across factory and ts-tiny Tailscale binaries; other models verified for install lifecycle and UI injection.
