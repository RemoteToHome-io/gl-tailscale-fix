# gl-tailscale-fix — kill-switch leak test suite

A formalized, repeatable suite for confirming **which mechanism catches each
failure mode** (Tailscale's built-in KS, either layer of our plugin KS, GL's 9920, or nothing)
and for proving our kill switch never leaks the real IP. Built to stop us
re-inventing the test procedure every release, and to produce diffable artifacts
we can compare version-to-version.

> ⚠️ The "catcher" column in the matrix below is a **hypothesis** until a run
> confirms it. The whole point of the suite is to verify these, not assume them.

## Mechanisms

| ID | Mechanism | Survives daemon death? | Notes |
|----|-----------|------------------------|-------|
| M1 | Tailscale's built-in KS (daemon-level) | No | Documented "fail close" for expired keys; sudden-offline unverified |
| M2 | Our plugin KS — two layers, both owned by the engine `ts-fix-ks`. **Firewall layer:** lan/guest/iot → uplink and VPN-client forwardings disabled in `/etc/config/firewall`, recorded in `ts-fix.settings.ks_severed`. **Routing layer:** `ip rule` 5279 on br-lan/br-guest/br-iot → table 100 `unreachable` | **Yes** (saved config + kernel FIB) | A firewall restart clears the firewall layer for a moment; starting the network service clears the routing layer. Protected = either layer holds, per zone and family |
| M3 | GL's 9920 blackhole | Yes | Inconsistent; absent on 4.9.0 |

## Failure-mode → catcher matrix (to verify)

| FM | Scenario | Hypothesized catcher | Status |
|----|----------|----------------------|--------|
| 1  | Exit-node server offline / upstream interrupt (client daemon alive) | M1 (M2 backstop if table 52 default drops) | open |
| 2  | WAN iface change / multi-WAN autoswitch / reconnect → `up --reset` window | **M2** — its routing layer while GL's restart flushes the firewall (M1 down during reset) | open — the known fw3 clobber |
| 3  | Daemon crash / OOM → procd respawn (no `--reset`, no ifup) | **M2** (M1 dead) | open — watchdog re-arm window |
| 4  | User changes / disables Custom Exit Node (v21 independent KS) | **M2 stays armed → blocked (fail-secure)** | open — fw3 + tiny binary |
| 5a | Reboot / cold boot | M2 — its firewall layer from boot (re-closed by the pre-firewall pass on the first boot after a keep-settings firmware upgrade), its routing layer from the first interface-up event | open — Shox's reboot report |
| 5d | Any GL UI Apply (commits tailscale → `gl_tailscale restart` → `up --reset`) | **M2** (= FM2 window, no WAN change) | open |
| 5f | DNS leak during any window (resolver egress, not just IP) | separate vector | open |

**Dimensions every test runs across:** family `{v4, v6}` · ingress path
`{br-lan, br-guest, br-iot}` · firmware `{fw3/4.8, fw3/4.9, fw4/4.8, fw4/4.9}` · binary
`{OEM 1.80.3, Admon tiny}` · link `{fast wired, slow/hotspot}`. The fw3 br-lan
clobber and the slow-link watchdog timing are exactly why family/path/fw/link
are not optional.

## Safety model (how a run works without stranding you)

The monitored client is the **laptop**, which sits behind the router under test,
so arming the KS blackholes it. The choreography keeps that safe:

1. The **laptop egress monitor** is time-boxed and fully detached (`setsid`). It
   keeps recording through a blackhole (curls just time out = "blocked") and
   self-stops after `DURATION`. The artifact is local, so it survives even if the
   laptop loses WAN (and any remote session on it drops) during the window.
2. A **router-side sampler** (read-only) records the actual state of both
   kill-switch layers. Safe to run on the gateway — it changes nothing.
3. **The operator drives the event and the recovery by hand**, on the printed
   timeline: trigger the failure once (~T+20s), watch, then recover (disable the
   KS or disable TS) before the window ends. No failure-mode script issues a
   state-changing command on the router.

This generalizes the standing rule: on the laptop's own gateway, the tooling is
read-only; the human performs every state change and the recovery.

`prerm-drain.sh` is the exception by design: it removes and reinstalls the package, arms the kill
switch, bounces wan6 and stops Tailscale on the router, so run it only against a test router that is
not the laptop's gateway. It refuses an AXT1800 unless `ALLOW_AXT1800=1`, and it arms a router-local
dead-man (900 s) that reinstalls the package if it is missing and restores the as-found kill-switch
setting and services if the run is abandoned.

## Layout

```
tests/
  README.md                  this file
  fm2-wan-bounce.sh          FM2 orchestrator, the template for the other FMs (read-only on the router)
  prerm-drain.sh             package-removal gate (STATE-CHANGING on the router)
  lib/
    common.sh                shared config + helpers (sourced by FM scripts)
    egress-monitor.sh        laptop-side leak monitor (v4+v6 concurrent, time-boxed)
    router-sampler.sh        router-side two-layer state sampler (READ-ONLY, busybox-safe)
    candidates.sh            v1.0.21 candidate block mechanisms (router-side, STATE-CHANGING)
    boot-sampler.sh          retired boot-window sampler (kept for the record; do not deploy)
    awk-busybox-lint.py      finds the BusyBox 1.33.2 awk call trap in source (laptop, python3)
  unit/                      laptop-only unit suites (no router)
    test-ks-armdisarm.sh     kill-switch engine
    test-ks-classify.sh      the engine's zone classifier
    test-guest-net.sh        Route Guest helper and advertisement block in ts-fix-reapply
    test-iot-net.sh          Route IoT helper and advertisement block in ts-fix-reapply
    test-domain-clean.sh     search-domain cleaner in ts-fix-reapply
    test-sampler-parse.sh    router-sampler parsers + fm2's arming probe and analyze
    test-postinst-config.sh  postinst's config restore
    test-awk-busybox.sh      the BusyBox 1.33.2 awk trap, over every file whose awk runs on a router
    test-prerm-drain-probes.sh  prerm-drain's probes: an unreachable router never scores clean
    test-wd-masq.sh          the watchdog's tailscale0 masquerade repair
    test-wd-guest.sh         the watchdog's Route Guest enforcement and IPv6 isolate backstop
    test-keep-binary.sh      keeping a Version Manager Tailscale binary across firmware upgrades
    test-acc-switch.sh       the side-switch accessory, accessories/gl-switch.d/tailscale.sh
    test-isolate6.sh         ts-fix-isolate6, its hotplug, and the postrm/packaging around it
    test-ts-state.sh         the shared fail-secure Tailscale-state read, in four scripts
```

## Unit suites (laptop only, no router)

| Suite | Covers |
|-------|--------|
| `test-ks-armdisarm.sh` | The kill-switch engine, `src/scripts/ts-fix-ks`, with `uci`, `ip` and the other commands it calls replaced by fakes that are linted before any engine case relies on them: the firewall layer (arm, disarm, check, iot, the Router-mode gate, failed writes and commits; the runtime invariant skipping `dead`/`linkdown` default routes and warning once per distinct set of unmapped default-route devices, cases 7d–7f), the routing layer (ensure and removal, `[detached]` bridges, foreign `lookup 1002` rules), the guest/iot source-rule swap (case SR8: its undo never deletes a `to` rule whose network is now another bridge's, such as the LAN's after a renumber), the pre-firewall `preboot` pass, and the engine lock. Also static checks on `ts-fix-reapply` and `ts-fix-watchdog`: every call into the tailscale CLI runs under `timeout 10` and reapply's `tailscale set` failures are logged (case TS), and the `timeout` fallback line in reapply, the watchdog and the updater defines a pass-through function only where no `timeout` exists (case TF) |
| `test-ks-classify.sh` | The engine's zone classifier (`ks_zone_class`, `ks_pair_in`): which firewall zones count as an internet uplink, a VPN client, or neither |
| `test-guest-net.sh` | Route Guest's helper in `src/scripts/ts-fix-reapply` (`guest_net`, `route_list_drop`) with `ip` and `ipcalc.sh` faked, plus static checks on reapply and the RPC module, and reapply's Route Guest advertisement block with the tailscale CLI, `timeout` and `jsonfilter` faked (the RGA cases: a read of the advertised routes that fails or times out writes nothing and leaves the daemon-pending flag). With the argument `legacy` it runs the pre-fix code of the helpers as a negative control: every DEFECT case must fail there |
| `test-iot-net.sh` | Route IoT's helpers in `src/scripts/ts-fix-reapply` (`iot_net`, and `route_list_drop` paired with the IoT subnet as `test-guest-net.sh` pairs it with the guest subnet) with `ip` and `ipcalc.sh` faked, plus static checks on reapply and the RPC module, and reapply's Route IoT advertisement block with the tailscale CLI, `timeout` and `jsonfilter` faked (the RIA cases: a read of the advertised routes that fails or times out writes nothing and leaves the daemon-pending flag). With the argument `legacy` it runs the pre-fix code of the helper as a negative control: every DEFECT case must fail there |
| `test-domain-clean.sh` | `ts_domain_clean` in `src/scripts/ts-fix-reapply` (Hide Tailscale Search Domain): removing the tailnet suffix from the advertised domain while leaving look-alike domains alone |
| `test-sampler-parse.sh` | The parsers in `lib/router-sampler.sh` (both layers, per zone and family), the whole sampler fed to `sh -s` as on a router, and `fm2-wan-bounce.sh`'s arming probe and `analyze` predicate — all against fixtures |
| `test-postinst-config.sh` | The config-restore block in `pkg/postinst`, run against a throwaway fake root after its paths are rewritten and the rewrite is linted: the live config wins over prerm's saved copy, the saved copy is used only when the live file is gone, and the default only when both are. Takes another postinst as its argument, for a run against an older one |
| `test-awk-busybox.sh` | The BusyBox 1.33.2 awk trap — `name (expr)` read as a call to a function `name` when the line runs: `lib/awk-busybox-lint.py` on the fixtures in `unit/fixtures/awk-busybox/` in both directions, then over every repo file whose awk runs on a router, with a canary line proving each awk program was read to its end. `--files F...` lints the files given instead. Needs `python3` |
| `test-prerm-drain-probes.sh` | The probe helpers of `prerm-drain.sh`, taken out by name and run by `bash` with a fake `rssh`: with an unreachable router the residue enumeration is `RES PROBE-ERROR` lines and its count FAILs, and the sidecar, `ts_fix_lan2ts` and pair-restore reads come back `probe-dead` / `unread` rather than empty; with a router that answers, a clean one PASSes and a leftover file FAILs with its line logged. Needs `bash` |
| `test-wd-masq.sh` | The watchdog's tailscale0 masquerade repair (`ensure_ts0_masq`), its copy of `is_fw49_plus`, the library guard (`TS_FIX_WD_LIB=1`), where the poll loop calls the repair, and its log text. Takes another watchdog as its argument, for a run against an older one |
| `test-wd-guest.sh` | The watchdog's Route Guest enforcement (`ensure_route_guest_swap`: GL's priority-0 `from <guest net> lookup main` replaced by `to <guest net> lookup main` when Route Guest is on, quiet polls write nothing) and its every-sixth-poll `ts-fix-isolate6 sync` backstop (`iso6_backstop`), with `uci`, `ip`, `logger` and `ipcalc` faked. Takes another watchdog as its argument; the version before Route Guest enforcement fails it |
| `test-keep-binary.sh` | Keeping a Version Manager Tailscale binary across a firmware upgrade: the static keep list no longer names the binaries, `ts-fix-update` writes and removes `/lib/upgrade/keep.d/gl-tailscale-fix-tailscale` on install, restore and `--sync-keep`, and `pkg/postinst` / `pkg/postrm` around it |
| `test-acc-switch.sh` | The side-switch accessory, `accessories/gl-switch.d/tailscale.sh`, in library mode with GL's RPC, `uci`, `ip` and the kill-switch engine faked: the ON path (lockdown, arm before GL's restart, exit node, lockdown removal) and the OFF path |
| `test-isolate6.sh` | `src/scripts/ts-fix-isolate6`, the IPv6 half of GL's "Block WAN Subnets": its parsers over `uci show` and `ip -6 route` text, `sync` against a fake `uci` / `ubus` / `ip` / `flock` / firewall (create, update, remove, idempotence, the whole-rule comparison, read-back before commit, commit and reload retries, read failure kept apart from absence, invalid names and prefixes never reaching uci), `remove`, the `98-ts-fix-isolate6` hotplug, the `pkg/postrm` block, and the packaging lines. Takes another tree root as its argument; the tree without the script fails it |
| `test-ts-state.sh` | The fail-secure Tailscale-state read (a failed read of the plugin's own or GL's Tailscale settings must not be taken as "turned off"): the shared read helper is byte-identical in `ts-fix-watchdog`, `ts-fix-reapply`, the `20-ts-fix` hotplug and `pkg/postinst`, and agrees with the engine on every read combination; also that the watchdog runs one poll at a time. 155 checks; 72 of them fail against the RC8 sources |

Run each suite from the repository root under both shells, for example:

```sh
sh tests/unit/test-ks-classify.sh
busybox ash tests/unit/test-ks-classify.sh
```

Each prints an `ok` or `FAIL` line per case and a summary line, and exits non-zero if any case
failed. `test-ks-classify.sh`, `test-guest-net.sh`, `test-domain-clean.sh`,
`test-sampler-parse.sh` and `test-postinst-config.sh` extract the code they test from the shipping
source between `---8<---` marker comments, so they test what ships, and a moved or renamed marker
fails the run loudly.
`test-sampler-parse.sh` also needs `bash` (for its fm2 cases) and `busybox` on the laptop: it runs
the sampler and the arming probe under both shells itself.

## Router tests (run from the laptop against a router over SSH)

### `fm2-wan-bounce.sh` — FM2, and the template for the other failure modes

Proves the kill switch holds through a WAN bounce, uplink autoswitch or reconnect — the
`gl_tailscale restart` → `tailscale up --reset` window, in which GL can also restart the firewall.
`start` captures the laptop's tunnel baseline and the router's clock offset, refuses a router on
which either kill-switch layer is not armed, launches the detached egress monitor, and prints the
router-sampler command and an operator timeline. `analyze` correlates the laptop's egress artifact
with the router's (see Artifacts). **Read-only on the router**: every probe it sends is a query, and
the operator triggers the event and the recovery by hand.

#### Running a failure mode (FM2 example)

Preconditions (operator sets via the GL UI / SSH): TS enabled, Custom Exit Node
set, KS ON with both layers armed (`start` checks and refuses otherwise), laptop on
this router's LAN, tunnel up (egress = exit-node IP).

```bash
# 1. Start — captures the tunnel baseline and clock offset, checks both kill-switch layers,
#    launches the monitor, and prints the router-sampler command + the operator timeline.
./fm2-wan-bounce.sh start --target <router-ip> --duration 180 --label fm2-fw4

# 2. In a second terminal, start the router sampler (command is printed by step 1).

# 3. Follow the printed timeline: trigger the WAN bounce once, watch, then recover.

# 4. When connectivity returns, harvest + analyze:
router_csv=$(./fm2-wan-bounce.sh _harvest --target <router-ip> --label fm2-fw4)
./fm2-wan-bounce.sh analyze --egress <printed-base> --router "$router_csv" --offset <printed-offset>
```

### `prerm-drain.sh` — package removal is atomic against the plugin's own writers

Certifies that `opkg remove` leaves nothing behind that the plugin's own writers — the two hotplug
handlers, an orphaned reapply, the watchdog and the kill-switch engine — could write after the
teardown. Legs:

- **0 preflight** — identity, the installed prerm carries the removal fix, posture preconditions,
  as-found capture, the dead-man;
- **A control** — no stragglers: removal is fast and leaves zero residue;
- **B′ armed removal** — every forwarding the kill switch closed comes back enabled, and its record,
  the plugin's own lan → tailscale0 forwarding and the config file are gone;
- **C hotplug-born** — an interface event landing inside the removal window spawns no writer;
- **D parked writer** — a reapply parked in its daemon wait at removal time is drained, not left to
  write after teardown.

Every leg that removes an armed package first asserts that both layers are armed, so a zero residue
count cannot be earned by a router that never had them. After every removal it enumerates each
surviving plugin object — both layers, the source-rule swap, UCI sections, files, init links, live
processes — and requires zero, then reinstalls the package and, after an armed leg, requires it to
re-arm unaided. A probe that did not complete (an unreachable router, a shell that died) scores as
`RES PROBE-ERROR` residue or reads `probe-dead`, never as zero or empty.

```bash
TARGET=<router-ip> IPK=build/out/gl-tailscale-fix_<ver>_all.ipk ./tests/prerm-drain.sh
```

Optional: `ROUTER_JUMP=user@host:port` (ssh -J). The router must start disarmed, with Tailscale
enabled and Running and wan6 up. **State-changing** — see the Safety model above.

## Shared libraries (`tests/lib/`)

- `common.sh` — laptop-side config and helpers sourced by the FM scripts (bash): the tunnel
  baseline, the router↔laptop clock offset, the detached launch of the egress monitor, the printed
  router-sampler command, and the harvest of the router's CSV over `scp -O`.
- `egress-monitor.sh` — runs on the monitored laptop (bash), observation only. Every `INTERVAL`
  seconds for `DURATION` seconds it fetches the public IPv4 and IPv6 egress concurrently and
  classifies each sample `ok` (the tunnel's address), `blocked` (no usable answer) or `LEAK` (any
  other public address).
- `router-sampler.sh` — runs on the router, fed over SSH as `sh -s`; **read-only**, safe on the
  laptop's gateway. Every `INTERVAL` seconds for `DURATION` seconds it records both kill-switch
  layers per zone and family, raw, plus the context needed to interpret a leak. It reads the zone
  classifier out of the installed engine (`/usr/bin/ts-fix-ks`) rather than re-implementing it, and
  falls back, loudly, to watching every zone but lan/guest/iot/tailscale0 when the engine is
  unreadable. On fw4 its netfilter columns read `NA`: only the UCI half of the firewall layer is
  sampled there.
- `candidates.sh` — runs on the router, **state-changing**: arms and removes the kill-switch
  candidate mechanisms compared for v1.0.21 (see below). Only on a test router you are driving.
- `boot-sampler.sh` — retired. It sampled the boot window of the earlier routing-only kill switch
  from the priority-5279 rules alone, and per its own header it would report a false failure on a
  current build. Kept for the record; do not deploy it.

## Artifacts

- `<ts>-<label>-egress.csv` — laptop: `ts_epoch,ts_iso,v4_ip,v4_class,v6_ip,v6_class`
  (class ∈ `ok` | `blocked` | `LEAK`).
- `<ts>-<label>-egress.json` — summary + `verdict` (below), plus the laptop's default routes at the
  start and the end of the run: a change between them makes the verdict suspect.
- `<ts>-<label>.csv` — router: per-sample columns, named in the header row, for both layers per zone
  (lan, guest, iot) and family, GL's guest/iot source rule and its replacement, GL's own blackholes
  (the 5280 `ts_killswitch` and 9920), and daemon/exit-node context — with a `.raw` file beside it
  holding the raw lines behind every change of those columns.
- `<ts>-<label>-meta.json` — target, baseline, clock offset, arming state at start, paths.
- `<ts>-prerm-drain.log` — `prerm-drain.sh`'s log: every assert, and the objects behind any
  non-zero residue count.

Run artifacts land in `tests/results/`, which is git-ignored — they contain router and real egress
IP addresses — and are never committed.

A run **PASSES** only if the laptop recorded zero `LEAK` samples on both families for the whole
window, saw the tunnel working (at least one IPv4 `ok` sample) and saw it go down (an IPv4 sample
that is not `ok`); a run missing either is `INCONCLUSIVE`, not a pass. `analyze` prints the first
router sample at or after each leak instant (offset-aligned) and reports the armed samples in which,
for some zone and family, both layers failed at once — so a failure points straight at the missing
layer. It says so in a NOTE when an artifact from an earlier sampler cannot show both layers, and
prints an attribution caveat whenever GL's own blackholes were present, since a blocked sample then
cannot be credited to our kill switch alone.

## Candidate mechanism comparison (v1.0.21 redesign — settled)

We do **not** assume a block mechanism works because GL uses it. Each candidate must prove
*on the wire* that it terminates forwarded LAN/guest→WAN traffic when the tunnel is down.
`lib/candidates.sh` (router-side) arms/removes each at priority **5279**:

| Candidate | Mechanism | Note |
|---|---|---|
| `raw-lookup` | raw `ip rule` → `lookup 100` → `unreachable default` | our proven two-step; chosen, and kept in v1.0.22 as the kill switch's routing layer |
| `uci-unreachable` | UCI `config rule`/`rule6` `action=unreachable` | declarative/persistent; direct action |
| `uci-blackhole` | UCI `config rule`/`rule6` `action=blackhole` | GL's exact action — A/B vs unreachable |
| `gl-tskillswitch` | GL's own `/usr/bin/ts_killswitch` | tested as a suspect, not a template |

**Efficacy procedure** (per candidate; NON-gateway test router, laptop = monitored client):
1. Set a Custom Exit Node, confirm laptop egress = exit-node IP. Arm:
   `ssh root@<r> 'sh -s' < lib/candidates.sh arm <candidate>`; confirm with `... show` (did it land?).
2. Launch the laptop egress monitor + the router sampler.
3. Drop the tunnel: `/etc/init.d/tailscale stop` (sustained daemon-down = the crash/OOM scenario;
   leaves `enabled=1`). Watch: `blocked` = candidate holds; real IP = **LEAK (defect)**.
4. Recover: `/etc/init.d/tailscale start` (or re-enable in GL UI); `... teardown <candidate>`.
5. Next candidate. Compare block-vs-leak, the reload window, and boot timing.

GL-`ts_killswitch` efficacy needs a 4.9 router (MT3000) with a Custom Exit Node set and the
laptop behind it. **To verify (unconfirmed):** netifd honors `action`/`rule6` on fw3+fw4;
`in=lan`/`guest` → `iif br-lan`/`br-guest` (check `show` — the guest UCI iface name may differ);
whether `/etc/init.d/network reload` opens a transient gap.

## Status

Only FM2 has a script of its own (`fm2-wan-bounce.sh`, the template); FM1, FM3, FM4, FM5a, FM5d
and FM5f have none yet. Before `prerm-drain.sh`'s first scored run, its dead-man needs the
two-state on-device lint described in its header.
