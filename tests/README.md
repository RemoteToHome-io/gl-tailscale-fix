# gl-tailscale-fix — kill-switch leak test suite

A formalized, repeatable suite for confirming **which mechanism catches each
failure mode** (Tailscale's built-in KS, our plugin KS, GL's 9920, or nothing)
and for proving our kill switch never leaks the real IP. Built to stop us
re-inventing the test procedure every release, and to produce diffable artifacts
we can compare version-to-version.

> ⚠️ The "catcher" column in the matrix below is a **hypothesis** until a run
> confirms it. The whole point of the suite is to verify these, not assume them.

## Mechanisms

| ID | Mechanism | Survives daemon death? | Notes |
|----|-----------|------------------------|-------|
| M1 | Tailscale's built-in KS (daemon-level) | No | Documented "fail close" for expired keys; sudden-offline unverified |
| M2 | Our plugin KS — `ip rule` 5279 → table 100 `unreachable` | **Yes** (kernel FIB) | Installed/maintained by reapply + watchdog |
| M3 | GL's 9920 blackhole | Yes | Inconsistent; absent on 4.9.0 |

## Failure-mode → catcher matrix (to verify)

| FM | Scenario | Hypothesized catcher | Status |
|----|----------|----------------------|--------|
| 1  | Exit-node server offline / upstream interrupt (client daemon alive) | M1 (M2 backstop if table 52 default drops) | open |
| 2  | WAN iface change / multi-WAN autoswitch / reconnect → `up --reset` window | **M2** (M1 down during reset) | open — the known fw3 clobber |
| 3  | Daemon crash / OOM → procd respawn (no `--reset`, no ifup) | **M2** (M1 dead) | open — watchdog re-arm window |
| 4  | User changes / disables Custom Exit Node (v21 independent KS) | **M2 stays armed → blocked (fail-secure)** | open — fw3 + tiny binary |
| 5a | Reboot / cold boot | M2 once installed; gap = boot window | open — Shox's reboot report |
| 5d | Any GL UI Apply (commits tailscale → `gl_tailscale restart` → `up --reset`) | **M2** (= FM2 window, no WAN change) | open |
| 5f | DNS leak during any window (resolver egress, not just IP) | separate vector | open |

**Dimensions every test runs across:** family `{v4, v6}` · ingress path
`{br-lan, br-guest}` · firmware `{fw3/4.8, fw3/4.9, fw4/4.8, fw4/4.9}` · binary
`{OEM 1.80.3, Admon tiny}` · link `{fast wired, slow/hotspot}`. The fw3 br-lan
clobber and the slow-link watchdog timing are exactly why family/path/fw/link
are not optional.

## Safety model (how a run works without stranding you)

The monitored client is the **laptop**, which sits behind the router under test,
so arming the KS blackholes it. The choreography keeps that safe:

1. The **laptop egress monitor** is time-boxed and fully detached (`setsid`). It
   keeps recording through a blackhole (curls just time out = "blocked") and
   self-stops after `DURATION`. The artifact is local, so it survives even if the
   laptop loses WAN (and Claude loses API) during the window.
2. A **router-side sampler** (read-only) records the actual rule state. Safe to
   run on the gateway — it changes nothing.
3. **The operator drives the event and the recovery by hand**, on the printed
   timeline: trigger the failure once (~T+20s), watch, then recover (disable the
   KS or disable TS) before the window ends. No script issues a state-changing
   command on the router.

This generalizes the standing rule: on the laptop's own gateway, the tooling is
read-only; the human performs every state change and the recovery.

## Layout

```
tests/
  README.md                  this file
  lib/
    egress-monitor.sh        laptop-side leak monitor (v4+v6 concurrent, time-boxed)
    router-sampler.sh        router-side rule/state sampler (READ-ONLY, busybox-safe)
    common.sh                shared config + helpers (sourced by FM scripts)
  fm2-wan-bounce.sh          FM2 orchestrator — the template for the other FMs
  results/                   run artifacts (gitignored — contain real IPs)
```

## Running a failure mode (FM2 example)

Preconditions (operator sets via the GL UI / SSH): TS enabled, Custom Exit Node
set, KS ON, laptop on this router's LAN, tunnel up (egress = exit-node IP).

```bash
# 1. Start — captures the tunnel baseline, clock offset, launches the monitor,
#    and prints the router-sampler command + the operator timeline.
./fm2-wan-bounce.sh start --target 192.168.71.1 --duration 180 --label fm2-fw4

# 2. In a second terminal, start the router sampler (command is printed by step 1).

# 3. Follow the printed timeline: trigger the WAN bounce once, watch, then recover.

# 4. When connectivity returns, harvest + analyze:
router_csv=$(./fm2-wan-bounce.sh _harvest --target 192.168.71.1 --label fm2-fw4)
./fm2-wan-bounce.sh analyze --egress <printed-base> --router "$router_csv" --offset <printed-offset>
```

## Artifacts

- `results/<ts>-<label>-egress.csv` — laptop: `ts_epoch,ts_iso,v4_ip,v4_class,v6_ip,v6_class`
  (class ∈ `ok` | `blocked` | `LEAK`).
- `results/<ts>-<label>-egress.json` — summary + `verdict` (PASS = zero LEAK samples).
- `results/<ts>-<label>.csv` — router: per-sample `br-lan`/`br-guest` 5279 presence
  (both families), table-100/52 state, daemon/BackendState/ExitNodeID, UCI, and the
  `bh4`/`bh6` **GL ts_killswitch (blackhole-at-5280)** flags.
- `results/<ts>-<label>-meta.json` — target, baseline, clock offset, paths.

A run **PASSES** only if the laptop recorded zero `LEAK` samples on BOTH families
for the whole window (during a working KS, every sample is `ok` or `blocked`).
`analyze` correlates each leak instant with the router rule state at that moment
(offset-aligned) so a failure points straight at the missing rule.

## Candidate mechanism comparison (v1.0.21 redesign)

We do **not** assume a block mechanism works because GL uses it. Each candidate must prove
*on the wire* that it terminates forwarded LAN/guest→WAN traffic when the tunnel is down.
`lib/candidates.sh` (router-side) arms/removes each at priority **5279**:

| Candidate | Mechanism | Note |
|---|---|---|
| `raw-lookup` | raw `ip rule` → `lookup 100` → `unreachable default` | our proven two-step; favorite going in |
| `uci-unreachable` | UCI `config rule`/`rule6` `action=unreachable` | declarative/persistent; direct action |
| `uci-blackhole` | UCI `config rule`/`rule6` `action=blackhole` | GL's exact action — A/B vs unreachable |
| `gl-tskillswitch` | GL's own `/usr/bin/ts_killswitch` | **suspect under test**; resolves TODO #14 |

**Design tension to settle empirically:** netifd's `config rule` can't cleanly express our
two-step (a table-100 route wants an interface), so the UCI candidates are limited to a DIRECT
action — the form our premise found *less* reliable than the two-step. If the efficacy test
confirms that, the **hybrid** (proven raw two-step + bulletproof re-assertion) beats a UCI
redesign. Don't pre-commit to UCI.

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

Built: `egress-monitor.sh`, `router-sampler.sh`, `common.sh`, `fm2-wan-bounce.sh`
(template), this README. **Pending harness validation** (one dry run) before the
remaining FM scripts (1, 3, 4, 5a, 5d, 5f) are generated from the FM2 template.
