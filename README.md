# gl-tailscale-fix

Plugin package that fixes and enhances the Tailscale integration on GL.iNet routers. Adds missing features through GUI controls injected into the existing GL admin Tailscale page — no GL scripts or binaries are modified from their factory state.

**[Setup Guide & User Documentation](https://remotetohome.io/gl-tailscale-fix)** — screenshots, step-by-step exit node setup, kill switch verification, DNS configuration, Tailscale admin console walkthrough.

![Tailscale Enhanced controls](.github/images/gl-tailscale-fix-v1020.webp)

## Features

- **Firewall + Routing Kill Switch** — two layers, each surviving the event that clears the other
  (v1.0.22+). While armed, the firewall layer disables every firewall forwarding from the LAN, guest
  and iot networks into an internet uplink or a VPN client (GL's WireGuard, OpenVPN and AmneziaWG
  clients, and ZeroTier) in the router's saved configuration: the firewall applies it during boot,
  before any internet connection comes up, and a network restart — which clears every routing rule —
  does not touch it. The routing layer — policy routing rules that block LAN/guest/iot→WAN traffic at
  the kernel routing layer, before conntrack and firewall evaluation — prevents even established
  connections from leaking when the exit node drops, and a firewall restart — which clears the
  firewall layer for a moment — does not touch it. Persists through daemon crashes, OOM kills,
  reboots, and service restarts. Covers both IPv4 and IPv6 (v1.0.20+). Devices on a GL 4.11 custom
  VLAN subnet are **not** protected (coverage is planned for v1.0.23; see the Kill switch note under
  [Architecture](#architecture)). Stays armed until you turn it off or disable Tailscale — removing
  the exit node does not disarm it; traffic stays blocked instead of leaking (v1.0.21+). The toggle
  stays operable even while `tailscaled` is down (v1.0.22+) — the kill switch lives in the router's
  firewall configuration and kernel routing, not in the daemon, so disarming (or arming) it does not
  require a working daemon, instead of being stranded behind a blocked LAN.

  > **⚠️ While a Custom Exit Node is in use, run no other routing on the router** — no VPN client
  > (GL's WireGuard, OpenVPN or AmneziaWG), no ZeroTier routing (ZeroTier only as an overlay for
  > management and remote access), and no Tor.

  > **⚠️ While the kill switch is armed, devices on the LAN, guest and iot networks cannot reach the
  > router's own upstream network** — the network the router itself is connected through, such as a
  > hotel or office network. That includes a hotel or venue captive-portal sign-in page and the
  > upstream router's admin page. To sign in to a captive portal, turn the kill switch off briefly,
  > sign in, then turn it back on. This is new in v1.0.22; in v1.0.21 the upstream network stayed
  > reachable while armed.

- **Kill Switch Follows Exit Node** (v1.0.22+, optional) — off by default. When enabled, the kill switch automatically arms whenever a Custom Exit Node is configured and disarms when the selection is cleared, tracking GL's stored setting (not the daemon's live state, so restart transients can't flap it). Useful with the side-switch accessory and for users who only ever want the kill switch active alongside an exit node. Leave it off to control the kill switch manually — the default fail-secure lifecycle (armed until you disarm it) is unchanged.
  With it on, turning Custom Exit Node off also turns the kill switch off, and traffic uses your
  normal connection until you pick a new exit node — to switch exit nodes without that gap, leave it
  off.
- **Advertise as Exit Node** — GUI toggle for `tailscale set --advertise-exit-node`. No SSH or script modification required.
- **Guest Network Access** — bidirectional firewall forwardings between guest network (br-guest) and
  Tailscale interface (tailscale0), guest subnet route advertisement, and policy route fixup that
  replaces the source rule GL's own `gl_tailscale` script adds for the guest network whenever a
  Custom Exit Node is set and the guest network is enabled, so guest clients can use exit nodes.
  Route Guest via Tailscale now also applies when the exit node is chosen from the GL mobile app or
  GoodCloud, not only when it is applied from the router's web page (v1.0.22+). GL adds its guest
  rule several seconds after the exit node is chosen, and the watchdog replaces it on its next pass,
  normally within about 5 seconds of GL adding it (longer if the watchdog is busy with a full
  re-apply). While the kill switch is off, guest traffic can use the real internet connection,
  around the exit node, from when GL adds its rule until the watchdog replaces it. Before this fix,
  guest traffic could keep using the real internet connection, around the exit node, until the next
  network event while the kill switch was off.
  Since v1.0.22 the kill switch covers the guest network — and GL's `iot` network, which the firmware
  creates (disabled by default) since 4.9.0 — whether or not this feature is on (a change from
  v1.0.21, which did not cover iot and, with a Custom Exit Node set and this feature off, let guest
  IPv4 get around the kill switch). While the kill switch is armed, guest and iot traffic can no
  longer reach the internet directly. It can still use the exit node while Tailscale's own firewall
  rules are in place, and is blocked, not leaked, when they are not — for example after a firewall
  restart that Tailscale did not trigger, until Tailscale restarts (a Tailscale Apply can lose them
  too), so guest and iot devices may be without internet at times while armed. Turn this feature on
  for guest devices that should use the exit node reliably.
- **Block WAN Subnets now covers IPv6** (v1.0.22+) — GL's own "Block WAN Subnets" setting (on
  firmware 4.8 and 4.9, Network → Guest Network, plus Network → IoT Network on 4.9; on 4.10, each
  network's card under Network → Subnet; on 4.11, each network's card under Network → LAN, custom
  VLANs included) blocks those networks from reaching the network the router itself is connected
  through, such as a hotel or office network, but only its IPv4 subnet. A guest device could still
  reach the upstream network over IPv6 (observed on GL firmware 4.8.4, 4.9.0 and 4.11.0). The plugin
  now adds the matching IPv6 block for every network GL isolates, following GL's own decision for
  each internet connection: it is added only where GL's IPv4 block is in place, and removed again
  when GL's block goes away — including when the setting is turned off; turning it back on adds the
  IPv6 block again. The IPv6 rules are also removed when the plugin is uninstalled. It works whether
  or not Tailscale or the kill switch is on, and is kept current as internet connections change — on
  every connection event, and re-checked by the watchdog about every 30 seconds. Applied
  automatically — no user action required beyond GL's own setting.
- **IoT Network Access** — bidirectional firewall forwardings between IoT network (br-iot) and Tailscale interface (tailscale0), IoT subnet route advertisement, and policy route fixup that ensure IoT clients can use exit nodes and are covered by the kill switch. Requires the IoT Network feature, which the firmware creates since 4.9.0; the toggle is hidden on older firmware, which has no iot network. The kill switch has covered iot since v1.0.22; this adds the remote-access side (route advertisement and the forwardings), which v1.0.22 does not do.
- **Tailscale SSH** — GUI toggle for `tailscale set --ssh`, which enables Tailscale's ACL-based SSH authentication. Most users don't need this — SSH to the router's tailscale IP already works via the normal SSH daemon (Dropbear) without any extra setup. Enable this only if you specifically want identity-based access controlled by a Tailscale SSH ACL rule (Access Controls → Tailscale SSH tab). While enabled, `tailscaled` takes over port 22 for tailnet-origin traffic, which breaks SSH from LAN clients that reach the router via Tailscale subnet routing; in that case, run Dropbear on an alternate port (System → Administration → SSH Access) to keep a path open for both Tailscale and LAN clients.
- **Hide Tailscale Search Domain** (v1.0.22+, optional) — off by default. GL writes your tailnet's MagicDNS suffix (`x.ts.net`) into dnsmasq's advertised domain, so every LAN client receives it over DHCP as its domain/search suffix. On firmware 4.9 GL *replaces* your local domain rather than appending to it, which also breaks `.lan` name resolution. When enabled, the plugin keeps your own local domain as the advertised value and re-asserts it whenever GL writes the suffix back — including against the background re-assert loop 4.9 runs for up to a minute after an interface comes up. Tailnet name resolution is deliberately left intact: the router's split-DNS entry for `ts.net` is untouched, so an explicit `host.x.ts.net` still resolves and only the broadcast hint goes away. This removes one passive indicator that a device sits behind a Tailscale node — it does not hide Tailscale generally, since the router still holds a tailnet address and still answers `ts.net` queries. Turning it off restores GL's behavior at the next network event rather than instantly.
- **Tailscale Version Manager** — installed vs latest version display, one-click update using space-optimized combined binaries, factory restore. Since v1.0.22, versions are compared as full build strings, so an upstream *rebuild* — same Tailscale version re-released with a new build suffix, as happened with the 2026-06-04 `ipnbus` fix — is detected and offered as "(rebuild)" instead of reporting "already at latest" forever. Downloads are bounded by connect and overall timeouts with a guaranteed terminal status, so a dead or crawling network path produces a clean error instead of a stuck "Downloading..." spinner.

  > **⚠️ Do not run `tailscale update` from SSH or use the Tailscale Web Dashboard update button.** These install the standard upstream binaries (~37MB daemon + ~15MB CLI = ~52MB total). GL routers have limited flash overlay — installing 52MB of binaries can exhaust the overlay filesystem and potentially brick the router. The Version Manager uses [Admonstrator's combined binaries](https://github.com/Admonstrator/glinet-tailscale-updater) (~5.3MB) which actually *free* space compared to GL's factory binary (~23MB). If you accidentally run `tailscale update`, use the **Restore** button to revert to factory, then update through the plugin.

- **Plugin Update Notification** — automatically checks GitHub for newer gl-tailscale-fix releases and shows an update badge with download link in the admin panel. Version caches expire after 72 hours; a ↻ button provides on-demand refresh.
- **Subnet Routing Fix** — automatically enables masquerade on the tailscale0 firewall zone (`masq` for IPv4 and, since v1.0.20, `masq6` for IPv6). Tailscale's built-in SNAT can fail to reinitialize after daemon restart, particularly on fw3 (iptables) kernels, causing cross-subnet LAN traffic from client devices to break. The plugin's masquerade provides defense-in-depth SNAT at the firewall layer. On pre-4.9 firmware where the router is advertising as a Tailscale exit node, the plugin also ensures `wan.masq6` is set as a defense-in-depth backstop — Tailscale's own IPv6 SNAT chain (`ts-postrouting` in `ip6 nat`) is empty on iptables-based firmware, so IPv6 egress for tailnet clients using this router as an exit node depends entirely on GL's `wan.masq6` setting. GL generally sets this on its own; the plugin guarantees it as a safety net in case GL's defaults vary by model or firmware variant. On firmware 4.9+, GL owns the IPv4 `masq` toggle natively so the plugin defers IPv4 to GL — but GL's toggle never sets IPv6 `masq6`, so the plugin sets that itself on all firmware (v1.0.21+) to keep exit-node IPv6 working. Applied automatically — no user action required.
- **Clean integration** — no GL scripts or binaries are altered from their factory state. If a modified `gl_tailscale` wrapper is detected during installation (e.g. a manual `--advertise-exit-node` modification, or the community workaround that comments out its dnsmasq `domain` writes), the original is automatically restored from ROM to prevent conflicts — the plugin handles exit node natively, and the search-domain toggle above is the supported replacement for that DNS workaround. This applies to all installation methods (SSH installer, manual opkg, or LuCI upload). All integration through standard OpenWrt interfaces (UCI, hotplug, procd, nginx includes). Clean install and removal.

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

> **Note:** For upgrades and recovery, use the installer (Option A) or a plain `opkg install` as shown — both preserve your settings and keep the kill switch installed throughout.
> Avoid `opkg install --force-reinstall`: it runs a full removal first, so both kill-switch layers
> are down for a few seconds until the post-install step re-arms them.

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

Clean removal — the kill switch is disarmed first: its routing rules and the guest/iot rule
replacement come off, and every forwarding it closed is restored, except any that GL 4.11's
per-network internet-access setting has switched off in the meantime: those stay off and are named
in the router's log (see Kill switch under Architecture). Then all injected UI, the plugin's own
firewall forwardings, and config files are removed.

## Architecture

Pure Lua, shell, and vanilla JavaScript — no compiled binaries. Single `.ipk` package under 120KB. Works as a non-invasive overlay — no GL.iNet scripts or binaries are altered from their factory state. All integration uses standard OpenWrt interfaces (UCI, hotplug, procd, nginx includes) and GL's existing extension points. GL-managed UCI attributes touched: `firewall.tailscale0.masq` (pre-4.9 only — GL's IP Masquerading toggle owns it on 4.9+), `firewall.tailscale0.masq6` (all firmware — GL's toggle is IPv4-only and never sets it), `firewall.wan.masq6` when advertising as exit node on pre-4.9 (backstop for IPv6 SNAT, tracked via sidecar UCI flag so teardown only undoes what we set),
and, while the kill switch is armed, the `enabled` option of every forwarding from the lan, guest or
iot zone into an uplink or VPN-client zone (each recorded in `ts-fix.settings.ks_severed`;
disarming re-enables them by zone pair, written as `enabled '1'` — which is also what a
missing option means).
On firmware 4.9+ the plugin defers IPv4 masquerade management to GL and continues to manage IPv6 `masq6` itself. Install adds files and these attributes; removal leaves the system as it was, apart from that explicit `enabled '1'`, the duplicate-forwarding case under Kill switch, and any forwarding that GL 4.11's per-network internet-access setting has switched off while the kill switch was armed, which stays off as GL set it.

- **Backend**: Custom Lua RPC module (`ts-fix`) loaded by GL's OpenResty API dispatcher. Own UCI config file `/etc/config/ts-fix` — never touches GL's `/etc/config/tailscale`.
- **Frontend**: Vanilla JS injected into GL's SPA via nginx `body_filter_by_lua_file`. No frameworks, no build tools.
- **Persistence**: Multiple mechanisms ensure settings survive GL's `tailscale up --reset` and handle teardown when Tailscale is disabled:
  1. **Hotplug** (priority 20, after GL's 19) — fires on network interface events, re-applies settings after GL restart; also triggers teardown when TS disabled.
     A second handler at priority 10 (before GL's 19) re-adds the kill switch's routing layer each
     time a network interface comes up.
  2. **JS Apply hook** — fast-path re-apply when the admin page is open
  3. **Watchdog daemon** — polls every 5s: detects TS disable (full teardown), runs the kill-switch
     consistency check, which re-adds the routing layer within one poll if the kill switch is armed
     but its rules have gone missing, reconciles a stuck daemon exit node (see below), and enforces
     the optional Kill Switch Follows Exit Node preference. It never disarms the kill switch on
     exit-node changes — only the KS toggle, disabling Tailscale, or the opt-in follow mode removes
     it.
- **Kill switch**: Two layers, each surviving the event that clears the other (v1.0.22+).

  **Firewall layer** — while armed, every firewall forwarding from the lan, guest or iot zone to an
  internet-uplink zone or a VPN-client zone (GL's WireGuard, OpenVPN and AmneziaWG clients, and
  ZeroTier) is disabled in the router's saved configuration (`/etc/config/firewall`), each one
  recorded in `ts-fix.settings.ks_severed`; a lan → tailscale0 forwarding is ensured so the LAN can
  use the exit node. Because it is saved configuration, the firewall applies it during boot, before
  the network brings any internet connection up. Disarming re-enables the forwardings it disabled,
  matched by zone pair, except any that GL 4.11's per-network setting for turning off internet
  access on the guest or iot network has switched off in the meantime: those stay off, and each one
  is named in the router's log. The same applies when disabling Tailscale disarms the kill switch,
  and when the plugin is uninstalled. Both firewall generations (fw3 and fw4) honour a forwarding's
  address-family option, so two forwardings between the same two zones can differ — for example one
  for IPv4 and one for IPv6 — and because disarming matches by zone pair, if you had disabled one of
  them by hand, it re-enables both (per-forwarding tracking is planned for v1.0.23).

  **Routing layer** (the v1.0.21 mechanism, kept) — policy routing (`ip rule` + `ip route`) that
  catches forwarded traffic at the routing layer, before conntrack and firewall evaluation.
  Tailscale's exit node uses priority 5270 → table 52; the kill switch inserts priority 5279 → table
  100 (`unreachable default`) for traffic arriving on br-lan, br-guest and br-iot, for both IPv4 and
  IPv6. When the exit node is active, traffic matches 5270 and never reaches our rule. When the exit
  node drops, traffic falls through to 5279 and gets an ICMP unreachable.

  **What clears each layer** — a firewall restart clears netfilter for a moment (measured up to
  about 1.6 seconds on fw3) and does not touch routing rules. GL's `gl_tailscale restart`, which runs
  on every Tailscale Apply and at every network interface event while Tailscale is enabled, performs
  one whenever IP Masquerading is on, and also whenever it has been on before (GL then finds its
  firewall option present and resets it with a restart). Starting the network service (boot,
  `network restart`) clears every routing rule and does not touch saved firewall configuration; the
  plugin re-adds the routing layer each time a network interface comes up and on its 5-second
  watchdog pass.

  **Guest and iot source rule** — whenever a Custom Exit Node is set and the guest (or iot) network
  is enabled, GL's own `gl_tailscale` script — not Tailscale — adds a source rule
  (`from <guest subnet> table main`, priority 0) that routes that network's traffic straight to the
  internet, around the exit node and ahead of the kill switch. While the kill switch is armed the
  plugin replaces it with a destination rule (`to <subnet> table main`), so guest and iot traffic
  follows the exit node's routing table and reaches the kill switch when the exit node is down;
  disarming puts GL's rule back when GL would have it. Whether that traffic then enters the tunnel is
  up to the firewall: while `tailscaled` runs, Tailscale's own rules (`-A FORWARD -j ts-forward`,
  ahead of the zone rules, and `-A ts-forward -o tailscale0 -j ACCEPT`, in both families) accept it;
  a firewall restart that Tailscale did not trigger removes them until `tailscaled` restarts (a
  Tailscale Apply can lose them too), and the traffic is blocked meanwhile, never leaked.

  Both layers are keyed purely on user intent (KS toggle on + Tailscale enabled), never on live
  exit-node state, so they stay armed through `tailscale up --reset` transients, daemon crashes, and
  exit-node removal — fail-secure: blocked, not leaked (v1.0.21+; earlier versions disarmed when the
  exit node was removed). The kill switch refuses to arm when the router is in a non-Router mode
  (Access Point, Extender, WDS — any set `glconfig.general.mode` other than `router`); an unreadable
  mode arms anyway, since refusing would fail open. It logs a warning, without changing anything,
  when a firewall setting would carry traffic around the firewall layer: a global forward policy of
  ACCEPT, or an enabled ACCEPT rule from lan, guest or iot into an uplink or VPN-client zone.
  Priority 5279 sits clear of the native `ts_killswitch` rule GL introduced on firmware 4.9 at 5280,
  so the two coexist without collision; upgrading from an earlier plugin version migrates the old
  5280 rules to 5279 with no unprotected gap. Works on both fw3 (iptables) and fw4 (nftables): the
  routing layer is kernel routing on both, and the firewall layer uses GL's UCI forwarding sections,
  which both firewall generations apply. Router management (admin, SSH, DNS, Tailscale control
  plane) and LAN-to-LAN traffic are unaffected (`iif br-lan`/`br-guest`/`br-iot` only matches
  forwarded traffic).

  **Note:** The kill switch covers LAN/guest/iot→WAN forwarding, and while it is armed its firewall
  layer also closes their forwardings into VPN-client zones.
  **Upstream network:** while the kill switch is armed, devices on the LAN, guest and iot networks
  cannot reach the router's own upstream network — the network the router itself is connected
  through, such as a hotel or office network — including a captive-portal sign-in page and the
  upstream router's admin page. To sign in to a captive portal, turn the kill switch off briefly,
  sign in, then turn it back on. In v1.0.21 the upstream network stayed reachable while armed.
  **Custom VLAN subnets:** devices on a GL 4.11 custom VLAN subnet are **not** protected by the kill
  switch. It does not close that subnet's path to the internet, adds no routing rule for it, and
  logs no warning about it, so when the exit node is not set or not working, those devices use your
  normal internet connection. Measured on a GL-MT3000 running GL firmware 4.11.0, with the kill
  switch armed and no exit node set: a device on a custom VLAN subnet reached the internet with the
  router's real ISP address on every probe, while a LAN device in the same test was blocked on
  every probe. Coverage is planned for v1.0.23.
  **Hardware offload:** on MediaTek routers with hardware NAT offload and a wired internet
  connection, a connection that was already running directly before the kill switch was turned on
  can keep flowing in the offload engine until it ends. New connections are blocked, connections
  through the exit node are never offloaded, and a reboot clears it — in practice this only matters
  if the kill switch is turned on in the middle of a direct session.
  **No other routing with a Custom Exit Node:** while a Custom Exit Node is in use, run no other routing on the router — no VPN client (GL's WireGuard, OpenVPN, AmneziaWG), no ZeroTier routing (ZeroTier only as an overlay for management and remote access), and no Tor. For a VPN client, the reason is that its fwmark-based policy routing (typically priority 6000) intercepts traffic before Tailscale's exit node routing (priority 5270).

- **Exit-node reconcile** (v1.0.22+): GL's stored Custom Exit Node setting (`tailscale.settings.exit_node_ip`) is treated as the authoritative exit-node intent, and the plugin pushes it to the daemon when the two disagree — in both directions. Background: tiny combined Tailscale builds published before 2026-06-04 were compiled without the IPN bus (`ts_omit_ipnbus`), so the `tailscale up --reset` GL runs on every Apply could exit before the exit-node change was dispatched — most visibly leaving the daemon routing through an exit node the user had just disabled ([fixed upstream](https://github.com/Admonstrator/glinet-tailscale-updater/commit/5b1d166c), but affected binaries remain installed in the field, and Version Manager users run exactly these builds). The reconcile runs on every reapply event and RPC apply — set pushes are gated on the stored value actually changing, while a daemon found routing with no exit node configured is cleared whenever seen — with watchdog backstops that detect both stuck states directly (setting empty while table 52 still carries a default route, or setting present while it doesn't) and retry until the daemon matches the configuration. Consequence, by design: an exit node set manually via `tailscale set --exit-node=<ip>` from SSH, bypassing GL's UI, is reconciled away; use GL's Custom Exit Node UI (which is also what makes LAN clients actually route through the exit node). This also clears the known stale-exit-node startup blackout where a CLI-set exit node persisted in the daemon state file across reboots.
- **Guest routing**: Firewall forwardings (guest↔tailscale0) plus a policy route fixup. Whenever a
  Custom Exit Node is set and the guest network is enabled, GL's own `gl_tailscale` script — not
  Tailscale — adds a source rule (`from <guest subnet> table main`) at priority 0. The source rule
  catches all guest-originated traffic and sends it to the main table → WAN, bypassing both the exit
  node and kill switch. While Route Guest is on, gl-tailscale-fix replaces it with a destination rule
  (`to <subnet> table main`), so guest traffic can use the exit node. This is re-applied after every
  Tailscale restart. The kill switch makes the same replacement for guest and iot while it is armed,
  whether or not Route Guest is on (see Kill switch above). Since v1.0.22 the replacement also
  applies when the exit node is chosen from the GL mobile app or GoodCloud, not only when it is
  applied from the router's web page: GL adds its rule several seconds after the exit node is chosen,
  and the watchdog replaces it on its next pass, normally within about 5 seconds of GL adding it
  (longer if the watchdog is busy with a full re-apply). While the kill switch is off, guest traffic
  can use the real internet connection, around the exit node, from when GL adds its rule until the
  watchdog replaces it. Before this fix, guest traffic could keep using the real internet
  connection, around the exit node, until the next network event while the kill switch was off.
- **Block WAN Subnets, IPv6** (v1.0.22+): GL's "Block WAN Subnets" setting keeps a network (guest;
  iot from firmware 4.9; custom VLANs on 4.11) from reaching the network the router itself is
  connected through, but GL's rule covers only that network's IPv4 subnet. For every network GL
  isolates, the plugin adds the matching IPv6 block (`/usr/bin/ts-fix-isolate6`), following GL's own
  decision for each internet connection: it is added only where GL's IPv4 block is in place and
  removed when GL's block goes away — including when the setting is turned off; turning it back on
  adds the IPv6 block again. The IPv6 rules are also removed when the plugin is uninstalled. It is
  independent of Tailscale and of the kill switch, runs on every connection event, and is re-checked
  by the watchdog about every 30 seconds.
- **Subnet routing masquerade**: Sets `masq=1` and (since v1.0.20) `masq6=1` on GL's tailscale0 firewall zone (`firewall.tailscale0.masq` / `masq6`). When two GL routers share subnets via Tailscale, Tailscale's built-in SNAT (`--snat-subnet-routes`) handles return routing. However, on fw3 (iptables) kernels, Tailscale's SNAT can fail to reinitialize after a daemon restart — the `cleanup: list tables: netlink receive: invalid argument` error during tailscaled cleanup correlates with this. Router-to-router traffic (SSH, ping from router itself) continues working because it uses the OUTPUT chain; only forwarded LAN client traffic breaks. The plugin's masquerade provides defense-in-depth SNAT at the firewall layer for both IPv4 and IPv6, independent of Tailscale's internal SNAT state. The IPv4 `masq` is applied on pre-4.9 (GL owns the toggle on 4.9+); the IPv6 `masq6` is applied on all firmware (v1.0.21+), since GL's toggle is IPv4-only and never sets it. Removed on teardown.
- **Exit-node-server IPv6 SNAT backstop** (v1.0.20+, pre-4.9 only): When this router is advertising as a Tailscale exit node, the plugin ensures `firewall.wan.masq6=1`. Tailscale's own `ts-postrouting` IPv6 chain is empty on iptables-based firmware (verified empirically — likely a Tailscale-side iptables-backend gap), so the wan-zone IPv6 masquerade is the only SNAT path for tailnet IPv6 traffic egressing through this router. GL generally sets this on its own; the plugin guarantees it as a safety net in case GL's defaults vary by model or firmware variant. A sidecar UCI flag (`ts-fix.settings.wan_masq6_set_by_plugin`) tracks ownership so teardown only undoes what we set — user or GL-set values are never trampled. On firmware 4.9+ the plugin defers entirely; GL owns this surface.

### File layout

```
/usr/lib/oui-httpd/rpc/ts-fix              Lua RPC module (backend API)
/etc/init.d/ts-fix                         Procd service (boot consistency pass + watchdog daemon)
/etc/init.d/ts-fix-preboot                 Pre-firewall kill-switch pass (boot order 18)
/etc/hotplug.d/iface/10-ts-fix-ks          Hotplug script (ifup: KS routing layer, before GL's 19)
/etc/hotplug.d/iface/20-ts-fix             Hotplug script (ifup reapply + teardown)
/etc/hotplug.d/iface/98-ts-fix-isolate6    Hotplug script (connection events: IPv6 Block WAN Subnets)
/usr/bin/ts-fix-ks                         Kill-switch engine (both layers + guest/iot rule swap)
/usr/bin/ts-fix-isolate6                   IPv6 half of GL's Block WAN Subnets
/usr/bin/ts-fix-reapply                    Shared reapply/teardown logic
/usr/bin/ts-fix-watchdog                   Watchdog daemon (TS disable, KS check, exit-node reconcile)
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
./pkg/build.sh 1.0.22
# Output: build/out/gl-tailscale-fix_1.0.22_all.ipk
```

## Firmware upgrades (sysupgrade)

The plugin survives GL.iNet firmware upgrades automatically on both minor (4.8.x → 4.8.y) and major (4.8.x → 4.9.x) releases. All plugin files and configuration are preserved through sysupgrade via `/lib/upgrade/keep.d/gl-tailscale-fix`. A Tailscale binary installed with the Version Manager is preserved too (it is listed in a second file, `/lib/upgrade/keep.d/gl-tailscale-fix-tailscale`, which Restore removes); the firmware's own Tailscale is not carried over, so a firmware upgrade brings its own, newer Tailscale. Plugin versions before v1.0.22 kept the old firmware's Tailscale binary across an upgrade — on a router upgraded that way, use Restore in the Version Manager to switch to the firmware's own.
After reboot, the kill switch's firewall layer is part of the saved firewall configuration, so the
firewall applies it during boot, before the network brings any internet connection up; its routing
layer and the remaining settings — guest routing, exit node configuration — are restored by the
watchdog and hotplug handlers. On the first boot after an upgrade that keeps settings, GL's
first-boot defaults set every LAN and guest → WAN forwarding back to enabled, the ones the kill
switch had closed among them. A pre-firewall pass (`/etc/init.d/ts-fix-preboot`, boot order 18:
after the first-boot defaults, before the firewall starts at 19) closes them again, so the firewall
comes up closed. It runs only at boot; the engine refuses it on a running router.

**After a firmware upgrade:**
- The plugin keeps running, but the package lists — opkg, LuCI's Software page and GL's Plug-ins page — no longer show it, because the new firmware brings its own package list. Run the installer again (Option A) to list it again: it reinstalls the same version over the kept files, with your settings and the kill switch left as they were.
- **Upgrading from 4.8.x to 4.9 or later:** turn on **IP Masquerading** on GL's Tailscale page and Apply. From 4.9, GL manages IPv4 masquerade itself with that toggle, which is off after the upgrade, and it switches off the masquerade the plugin had set up on 4.8.x. Until you turn it on, LAN devices get no IPv4 internet through the exit node — IPv6 keeps working, and nothing leaks.

On **firmware 4.9+**, the plugin detects the newer firmware and adapts its UI: the Advertise as Exit Node toggle is hidden (GL provides this natively via "Run Exit Node"), and an informational banner explains what the plugin continues to handle on top of GL's native Tailscale integration — Kill Switch, Guest routing through the exit node, Tailscale SSH toggle, and Version Manager. See the [blog post](https://remotetohome.io/blog/gl-tailscale-fix/) for the full rationale.

**Downgrading the plugin** to v1.0.21 or earlier: turn the kill switch off first. An older build
knows nothing of the firewall layer, so the LAN stays blocked (fail-closed) until the forwardings
are re-enabled.

## Compatibility

**Should work** on any GL.iNet router with native Tailscale support running firmware 4.x (tested on 4.5.22 through 4.11.0).
Both fw3 (iptables) and fw4 (nftables) are supported — the kill switch's routing layer is kernel
routing on both, and its firewall layer, like the guest forwardings, uses GL's UCI forwarding
sections, which both firewall generations apply.

Starting with **v1.0.19** the plugin coexists with firmware 4.9's native Tailscale enhancements. On 4.9+ the plugin auto-detects the firmware, hides UI for features GL now provides natively (Advertise as Exit Node, WAN subnet advertisement, IP Masquerading), and keeps its own features active — most importantly the daemon-independent kernel-level Kill Switch, which survives `tailscaled` crashes that Tailscale's built-in kill switch cannot. See the [blog post](https://remotetohome.io/blog/gl-tailscale-fix/) for the kill-switch rationale.

Starting with **v1.0.20** the kill switch and the tailscale0 masquerade fixes apply to IPv6 as well as IPv4. On firmware 4.9+, GL's native **IP Masquerading** toggle only covers IPv4 — it never sets IPv6 masquerade on the Tailscale zone — so LAN-side IPv6 would not traverse the exit-node tunnel. **v1.0.21** closes this: the plugin sets `tailscale0.masq6` itself on all firmware to keep LAN-side IPv6 flowing through the exit node, while still leaving the IPv4 `masq` toggle to GL on 4.9. The kill switch protects both families on 4.9 regardless of masquerade state.

Starting with **v1.0.21** the kill switch is fully independent of exit-node state: it stays armed until you turn it off or disable Tailscale, so a dropped, changed, or removed exit node blocks traffic instead of leaking it. Its rules moved from priority 5280 to 5279 to sit clear of the native `ts_killswitch` rule GL introduced on firmware 4.9 — GL's rule covers only IPv4 on the LAN bridge, so the plugin's kill switch remains the only protection covering IPv6 and the guest network, although in v1.0.21 guest IPv4 could get around it when a Custom Exit Node was set and Route Guest was off (closed in v1.0.22; see "A potential leak in v1.0.21, now closed" in the v1.0.22 release notes on the [Releases](https://github.com/RemoteToHome-io/gl-tailscale-fix/releases) page). Upgrades migrate the old rules automatically with no unprotected window, and the watchdog now verifies and re-asserts the kill switch per address family.

### Tiny Tailscale binaries (Version Manager)

The Version Manager installs [Admonstrator's combined "tiny" binaries](https://github.com/Admonstrator/glinet-tailscale-updater). Tiny builds published **before 2026-06-04** were compiled without the IPN bus (`ts_omit_ipnbus`), which made GL's `tailscale up --reset` exit before pref changes were dispatched — the visible symptom was a Custom Exit Node that kept routing after being disabled in GL's UI. The build flag was [fixed upstream on 2026-06-04](https://github.com/Admonstrator/glinet-tailscale-updater/commit/5b1d166c) via an in-place rebuild of the same release version. **v1.0.22** handles both halves of the aftermath: the exit-node reconcile (see Architecture) corrects the stuck daemon state the affected builds leave behind, and the Version Manager's full-build-string comparison detects the in-place rebuild so routers stuck on a pre-fix binary are offered the fixed build instead of reporting "already at latest".

See the [tested models](#tested-models) appendix for the full compatibility matrix.

## Disclaimer

**No warranty**.  The GL.iNet Tailscale implementation is Beta software and subject to change without notice (including for us).  While we have put extensive effort into testing, this functionality should also be considered beta and we cannot anticipate how future GL firmware changes may impact functionality of this plugin.  We recommend checking here for the latest plugin release before upgrading your GL firmware.  **Use at your own risk** and refer to the testing methodology in our [User Documentation](https://remotetohome.io/gl-tailscale-fix) to personally verify your privacy posture before using in production.

## Accessories

Companion scripts and sidecar utilities live in the [`accessories/`](accessories/) directory. These are add-on functionality that customers can deploy on their gl-tailscale-fix enhanced routers.

### Side switch toggle (physical switch on Beryl AX, Slate AX, etc.)

[`accessories/gl-switch.d/tailscale.sh`](accessories/gl-switch.d/tailscale.sh) toggles GL's native Tailscale and the plugin's Kill Switch together when you flip the physical side switch on supported GL.iNet routers.

**Prerequisites**: Tailscale should already be configured and working in the GL admin UI before deploying this script — plugin installed, Tailscale bound to your account, at least one Custom Exit Node selected, and exit node + subnet routes approved in the [Tailscale admin console](https://login.tailscale.com/admin/machines). See the [setup guide](https://remotetohome.io/gl-tailscale-fix#setup-guide) for the full walkthrough. The script header lists the full prerequisite checklist.

**What the slider does on "on"**: The script first installs a temporary lockdown that blocks forwarding from the LAN and guest networks — and GL's IoT network, with plugin v1.0.22 or later — for the whole transition. It then defensively disables GL's stock WireGuard, OpenVPN, and Tor clients to prevent routing-priority conflicts that would otherwise leave Tailscale unable to actually route through the exit node (details in [Architecture](#architecture)). With plugin v1.0.22 or later and the kill switch enabled in the script's configuration, it arms the plugin's kill switch next and only then asks GL to start Tailscale, so the routing rules GL adds for the guest and IoT networks as Tailscale starts land on paths the kill switch already blocks. If the kill switch cannot be armed, the script does not start Tailscale and the lockdown stays until you flip the switch off. Once the kill switch is confirmed, the lockdown releases and traffic flows through the exit node as soon as Tailscale has connected. In our tests, LAN traffic was flowing through the exit node about 12–17 seconds after the flip when Tailscale was already running, and about 25–36 seconds after it when Tailscale had been off; guest and IoT traffic took up to about 11 seconds longer.

**Tested**: with v1.0.22 on the GL-MT3000 (Beryl AX) running firmware 4.11.0, the GL-MT3600BE (Beryl 7) running firmware 4.9.0 and the GL-AXT1800 (Slate AX) running firmware 4.8.4 — see the firmware compatibility notes in the script header.

**Note on custom routing**: The defensive disable covers GL's stock VPN clients only. If you have ZeroTier managed routes, third-party VPN apps, proxy clients, custom iptables rules, or any other non-GL-OEM routing on the router, disable that yourself before enabling the slider — the script can't auto-detect arbitrary user-installed routing.

Install on the router:

```sh
wget -q https://raw.githubusercontent.com/RemoteToHome-io/gl-tailscale-fix/main/accessories/gl-switch.d/tailscale.sh -O /etc/gl-switch.d/tailscale.sh
chmod +x /etc/gl-switch.d/tailscale.sh
```

Bind the physical slider to this script. The GL admin UI Toggle Button Settings dropdown does not list Tailscale as an option, so the binding must be set via UCI:

```sh
uci set switch-button.@main[0].func='tailscale'
uci commit switch-button
```

This replaces any prior side-switch binding. **Do not open System → Toggle Button Settings in the GL admin UI after this** — that page only knows about its hardcoded function list, so it will display "No Function" (or a stale prior selection) and clicking Apply would overwrite the UCI binding. To unbind cleanly, run `uci set switch-button.@main[0].func='' && uci commit switch-button` from SSH.

Then edit the Configuration block at the top of the file to dial in your preferred posture (LAN/WAN access, kill switch, guest routing, etc.). Every "on" flip applies that posture in full and defensively disables any active WireGuard, OpenVPN, or Tor client. See comments in the file for the rationale on each setting and for instructions on inverting the switch logic if you prefer.

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
| GL-MT3000 | Beryl AX | 4.11.0 | 21.02-SNAPSHOT | fw3 | v1.0.22 ✓✓✓✓✓ | 1.92.5 |
| GL-MT3600BE | Beryl 7 | 4.9.0 | 21.02-SNAPSHOT | fw3 | v1.0.22 ◇ | 1.92.5 |
| GL-AXT1800 | Slate AX | 4.8.4 | 23.05 | fw4 | v1.0.22 ▲ | 1.80.3 / 1.96.4 |
| GL-MT3000 | Beryl AX | 4.9.0 | 21.02-SNAPSHOT | fw3 | v1.0.21 ✓✓✓✓ | 1.92.5 / 1.98.8 |
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
| GL-E5800 | Mudi 7 | 4.8.5 | 23.05.4 (5.15-kernel) | fw4 | v1.0.20 ✓✓✓ | 1.80.3 / 1.98.5 |

**†** Install/remove only.
**‡** Community: install + kill switch + guest ([#1](https://github.com/RemoteToHome-io/gl-tailscale-fix/issues/1)).
**¶** Install + version manager verified.
**✓** Full e2e: exit node server + client, kill switch, version manager.
**✓✓** Full e2e on v1.0.19, including 4.9.0 daemon-stopped leak-block test (zero leak).
**✓✓✓** Full e2e on v1.0.20 or later, adding IPv6 KS leak-block test (zero leak both families) and exit-node-server SNAT for both IPv4 and IPv6.
**✓✓✓✓** Adds the v1.0.21 failure-mode leak suite: WAN bounce, daemon death, exit-node removal (fail-secure), and exit-node-server outage — zero leaks on both address families, with GL's native 4.9 kill-switch rule coexisting.
**✓✓✓✓✓** Adds the v1.0.22 two-layer suite: GL's Tailscale restart and a plain firewall restart, a network restart, two armed reboots and a simulated firmware-upgrade boot, guest and iot clients, arming and disarming with Tailscale stopped, and an in-place upgrade from an armed v1.0.21 — zero leaks on both address families; package removal while armed restores every forwarding it closed.
**◇** v1.0.22 two-layer checks on GL 4.9.0: GL's Tailscale restart, a plain firewall restart with a guest client, and arming and disarming with Tailscale stopped — zero leaks on both address families (reboot checks not run on this model).
**▲** v1.0.22 two-layer checks on GL 4.8.4 (fw4): a firewall restart while armed, the guest network's rule swap, guest traffic through the exit node (including across a firewall restart), an already-open connection being stopped, an armed reboot (watched from the router for the whole boot, and from the Wi-Fi client once it rejoined), the side switch in both orders, and arming with the exit node up and then disarming and clearing it — zero leaks on both address families (network restart, simulated firmware-upgrade boot, iot checks (GL 4.8.4 has no iot network), arming and disarming with Tailscale stopped, and an in-place upgrade from v1.0.21 not run on this model).
**⊕** Community install + functional confirmation ([forum](https://forum.gl-inet.com/t/enhanced-tailscale-for-gl-inet-routers-proper-ts-killswitch-one-click-exit-node/67565)).
**§** Install on 4.5.22 + 4.7.2β; KS verified on 4.7.2β; version manager unsupported ([#6](https://github.com/RemoteToHome-io/gl-tailscale-fix/issues/6)).

AXT1800 and MT3000 verified end-to-end across factory and ts-tiny Tailscale binaries; other models verified for install lifecycle and UI injection.
