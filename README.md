# gl-tailscale-fix

Plugin package that fixes and enhances the Tailscale integration on GL.iNet routers. Adds missing
features through GUI controls injected into the existing GL admin Tailscale page
— no GL scripts or binaries are modified from their factory state.

**[Setup Guide & User Documentation](https://remotetohome.io/gl-tailscale-fix)**
— screenshots, step-by-step exit node setup, kill switch verification, DNS configuration,
Tailscale admin console walkthrough.

![Tailscale Enhanced controls](.github/images/tailscale-enhanced.webp)

## Features

- **Routing Kill Switch** — policy routing rules that block LAN/guest→WAN
  traffic at the kernel routing layer, before conntrack and firewall evaluation.
  Prevents even established connections from leaking when the exit node drops.
  Persists through daemon crashes, OOM kills, reboots, and service restarts.
- **Advertise as Exit Node** — GUI toggle for `tailscale set
  --advertise-exit-node`. No SSH or script modification required.
- **Guest Network Access** — bidirectional firewall forwardings between guest
  network (br-guest) and Tailscale interface (tailscale0), guest subnet route
  advertisement, and policy route fixup that ensures guest clients can use exit
  nodes and are covered by the kill switch.
- **Tailscale SSH** — GUI toggle for `tailscale set --ssh`, enabling passwordless
  SSH access from Tailscale peers. Requires an SSH ACL rule in the Tailscale
  admin console (Access Controls → Tailscale SSH tab). Note: Tailscale SSH
  takes over port 22 for Tailscale traffic — LAN clients using subnet routing
  cannot use it. For SSH access from both Tailscale peers and LAN clients,
  consider adding an alternate Dropbear port (e.g. 2222) in
  System → Administration → SSH Access instead.
- **Tailscale Version Manager** — installed vs latest version display, one-click
  update using space-optimized combined binaries, factory restore.

  > **⚠️ Do not run `tailscale update` from SSH or use the Tailscale Web Dashboard
  > update button.** These install the standard upstream binaries (~37MB daemon +
  > ~15MB CLI = ~52MB total). GL routers have limited flash overlay — installing
  > 52MB of binaries can exhaust the overlay filesystem and potentially brick the
  > router. The Version Manager uses [Admonstrator's combined
  > binaries](https://github.com/Admonstrator/glinet-tailscale-updater) (~5.3MB)
  > which actually *free* space compared to GL's factory binary (~23MB). If you
  > accidentally run `tailscale update`, use the **Restore** button to revert to
  > factory, then update through the plugin.

- **Plugin Update Notification** — automatically checks GitHub for newer
  gl-tailscale-fix releases and shows an update badge with download link in the
  admin panel. Version caches expire after 72 hours; a ↻ button provides
  on-demand refresh.
- **Subnet Routing Fix** — automatically enables masquerade on the tailscale0
  firewall zone. Tailscale's built-in SNAT can fail to reinitialize after daemon
  restart, particularly on fw3 (iptables) kernels, causing cross-subnet LAN
  traffic from client devices to break. The masquerade provides defense-in-depth
  SNAT at the firewall layer. Applied automatically — no user action required.
- **Clean integration** — no GL scripts or binaries are altered from their
  factory state. If a modified `gl_tailscale` wrapper is detected during
  installation (e.g. a manual `--advertise-exit-node` modification), the
  original is automatically restored from ROM to prevent conflicts — the
  plugin handles exit node natively. This applies to all installation
  methods (SSH installer, manual opkg, or LuCI upload). All integration
  through standard OpenWrt interfaces (UCI, hotplug, procd, nginx includes).
  Clean install and removal.

## Installation

Download the latest `.ipk` from [Releases](https://github.com/RemoteToHome-io/gl-tailscale-fix/releases).

### Option A: One-command installer (recommended)

SSH into your router and run:

```sh
wget -q https://github.com/RemoteToHome-io/gl-tailscale-fix/releases/latest/download/install-gl-tailscale-fix.sh -O install-gl-tailscale-fix.sh && sh install-gl-tailscale-fix.sh
```

The installer downloads the latest `.ipk`, verifies the sha256 checksum, and
runs `opkg install`. It also automatically restores the stock `gl_tailscale`
wrapper if you previously modified it for exit node support.

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

> **Note:** If you previously modified `/usr/bin/gl_tailscale` to add
> `--advertise-exit-node`, the plugin automatically restores the stock version
> during installation. The plugin handles exit node advertisement natively.

After installation, navigate to **APPLICATIONS → Tailscale** in the GL admin panel.
Controls appear below GL's settings under a "Tailscale Enhanced" divider.

> **After clicking Apply**, it's normal for Tailscale to show a yellow/connecting
> state for 10–20 seconds while settings take effect. Wait for the status to
> return to green before testing your connection.

For the full setup walkthrough — including exit node configuration, Tailscale admin
console approval, DNS setup, and kill switch verification — see the
**[setup guide](https://remotetohome.io/gl-tailscale-fix#setup-guide)**.

## Uninstallation

```bash
ssh root@<router-ip> opkg remove gl-tailscale-fix
```

Clean removal — all injected UI, routing rules, firewall forwardings, and config
files are removed.

## Architecture

Pure Lua, shell, and vanilla JavaScript — no compiled binaries. Single `.ipk`
package under 50KB. Works as a non-invasive overlay — no GL.iNet scripts or
binaries are altered from their factory state. All integration uses standard
OpenWrt interfaces (UCI, hotplug, procd, nginx includes) and GL's existing
extension points. The only GL-managed UCI attribute touched is
`firewall.tailscale0.masq` (masquerade on the Tailscale firewall zone).
Install adds files and one zone attribute; removal leaves the system exactly
as it was.

- **Backend**: Custom Lua RPC module (`ts-fix`) loaded by GL's OpenResty API
  dispatcher. Own UCI config file `/etc/config/ts-fix` — never touches GL's
  `/etc/config/tailscale`.
- **Frontend**: Vanilla JS injected into GL's SPA via nginx
  `body_filter_by_lua_file`. No frameworks, no build tools.
- **Persistence**: Multiple mechanisms ensure settings survive GL's
  `tailscale up --reset` and handle teardown when Tailscale is disabled:
  1. **Hotplug** (priority 20, after GL's 19) — fires on network interface events,
     re-applies settings after GL restart; also triggers teardown when TS disabled
  2. **JS Apply hook** — fast-path re-apply when the admin page is open
  3. **Watchdog daemon** — polls every 5s using lightweight kernel routing queries
     (`ip rule`/`ip route`), detects TS disable (full teardown) and exit node
     removal while kill switch is active (auto-disables KS). Heavy tailscale CLI
     calls are only spawned when the light check detects a potential problem.
- **Kill switch**: Policy routing (`ip rule` + `ip route`) that catches
  forwarded traffic at the routing layer — before conntrack and firewall
  evaluation. Tailscale's exit node uses priority 5270 → table 52; the kill
  switch inserts priority 5280 → table 100 (`unreachable default`). When the
  exit node is active, traffic matches 5270 and never reaches our rule. When the
  exit node drops, traffic falls through to 5280 and gets an ICMP unreachable.
  Works on both fw3 (iptables) and fw4 (nftables) since it uses kernel routing,
  not firewall-specific mechanisms. Router management (admin, SSH, DNS, Tailscale
  control plane) and LAN-to-LAN traffic are unaffected (`iif br-lan`/`br-guest`
  only matches forwarded traffic).

  **Note:** The kill switch covers LAN/guest→WAN forwarding. If a competing VPN
  client (WireGuard, OpenVPN, AmneziaWG) is running on the same VLAN, its
  fwmark-based policy routing (typically priority 6000) intercepts traffic before
  Tailscale's exit node routing (priority 5270). Don't run a VPN client tunnel on
  the same network segment that routes through a Tailscale exit node.

- **Guest routing**: Firewall forwardings (guest↔tailscale0) plus a policy route
  fixup. When Tailscale advertises a subnet, it creates a source-based rule
  (`from <subnet> lookup main`) at priority 0. For the primary LAN, Tailscale
  uses destination-based (`to <subnet>`). The source-based rule catches all
  guest-originated traffic and sends it to the main table → WAN, bypassing both
  the exit node and kill switch. gl-tailscale-fix replaces this with a
  destination-based rule, matching Tailscale's own LAN behavior. This is
  re-applied after every Tailscale restart.
- **Subnet routing masquerade**: Sets `masq=1` on GL's tailscale0 firewall zone
  (`firewall.tailscale0.masq`). When two GL routers share subnets via Tailscale,
  Tailscale's built-in SNAT (`--snat-subnet-routes`) handles return routing.
  However, on fw3 (iptables) kernels, Tailscale's SNAT can fail to reinitialize
  after a daemon restart — the `cleanup: list tables: netlink receive: invalid
  argument` error during tailscaled cleanup correlates with this. Router-to-router
  traffic (SSH, ping from router itself) continues working because it uses the
  OUTPUT chain; only forwarded LAN client traffic breaks. The masquerade rule
  provides defense-in-depth SNAT at the firewall layer, independent of
  Tailscale's internal SNAT state. Applied on both fw3 and fw4, removed on
  teardown.

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
./pkg/build.sh 1.0.17
# Output: build/out/gl-tailscale-fix_1.0.17_all.ipk
```

## Compatibility

**Should work** on any GL.iNet router with native Tailscale support running
firmware 4.x (tested on 4.5.22 through 4.8.5). Both fw3 (iptables) and
fw4 (nftables) are supported — the kill switch uses kernel routing (not
firewall-specific), guest forwardings use GL's UCI abstraction layer.

> **⚠️ Not yet tested with firmware 4.9.x or later.** GL has made changes to the
> Tailscale integration and admin GUI in the 4.9.x series. Do not install on
> 4.9.x firmware until compatibility has been verified — check
> [Releases](https://github.com/RemoteToHome-io/gl-tailscale-fix/releases) for
> updates.

See the [tested models](#tested-models) appendix for the full compatibility matrix.

## Disclaimer

**No warranty**.  The GL.iNet Tailscale implementation is Beta software and subject
to change without notice (including for us).  While we have put extensive effort into
testing, this functionality should also be considered beta and we cannot anticipate
how future GL firmware changes may impact functionality of this plugin.  We recommend
checking here for the latest plugin release before upgrading your GL firmware.
**Use at your own risk** and refer to the testing methodology in our
[User Documentation](https://remotetohome.io/gl-tailscale-fix) to personally verify
your privacy posture before using in production.

## Contributing

Found a bug? Have a feature request? Tested on a new router model?

- **Bug reports and feature requests**:
  [Open an issue](https://github.com/RemoteToHome-io/gl-tailscale-fix/issues)
- **Pull requests**: Welcome. The plugin is pure Lua, shell, and vanilla JS — no
  build toolchain required. See [Architecture](#architecture) for how the pieces
  fit together.
- **Model testing**: If you verify gl-tailscale-fix on a GL.iNet model not in the
  [tested models](#tested-models) table, please open an issue with your model,
  firmware version, and test results.

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
| GL-AXT1800 | Slate AX | 4.8.2 | 23.05 | fw4 | v1.0.17 | 1.80.3 / 1.94.2 |
| GL-MT3000 | Beryl AX | 4.8.2β | 21.02 | fw3 | v1.0.17 | 1.80.3 / 1.94.2 |
| GL-AX1800 | Flint | 4.6.8 | 21.02 | fw3 | v1.0.5 † | 1.66.4 |
| GL-MT2500 | Brume 2 | 4.7.4 | 21.02 | fw3 | v1.0.5 † | 1.66.4 |
| GL-MT6000 | Flint 2 | 4.8.3 | 21.02 | fw3 | v1.0.5 † | 1.80.3 |
| GL-BE3600 | Slate 7 | 4.8.1 | 23.05 | fw4 | v1.0.5 † | 1.80.3 |
| GL-BE6500 | Flint 3 | 4.8.4 | 23.05 | fw4 | v1.0.5 † | 1.92.5 |
| GL-MT5000 | Brume 3 | 4.8.4 | 21.02 | fw4 | v1.0.17 ¶ | 1.80.3 / 1.96.3 |
| GL-MT3600BE | Beryl 7 | 4.8.5 | 21.02 | fw3 | v1.0.17 ‡¶ | 1.94.2 |
| GL-A1300 | Slate Plus | 4.5.22 / 4.7.2β | — | fw3 | v1.0.17 §  | 1.6x |

**†** Install/remove verified only (Tailscale not connected — feature testing pending).
**‡** Community-verified: install/remove, UI injection, kill switch, guest routing ([#1](https://github.com/RemoteToHome-io/gl-tailscale-fix/issues/1)).
**¶** Install + version manager (update to 1.96.3) verified.
**§** Plugin install verified on FW 4.5.22 and 4.7.2β. Exit node client + kill switch verified on 4.7.2β. Version manager not supported — Tailscale's own updater also fails on this model ([#6](https://github.com/RemoteToHome-io/gl-tailscale-fix/issues/6)).

All features verified on AXT1800 and MT3000 with both factory (v1.80.3) and
updated (v1.94.2) Tailscale binaries: exit node advertisement, Tailscale SSH,
routing kill switch, guest network routing, version manager (update + restore),
OOM prevention on 512MB models.
All other models verified for install/remove lifecycle, nginx injection, RPC module
loading, and UCI config management.
