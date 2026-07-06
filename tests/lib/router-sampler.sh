#!/bin/sh
#
# gl-tailscale-fix test suite — router-side kill-switch rule/state sampler
#
# Runs ON the GL router. READ-ONLY: it only queries kernel routing, UCI, and
# tailscale state — it never changes anything, so it is safe to run on the router
# that is also the laptop's gateway. Time-boxed: every INTERVAL seconds for
# DURATION seconds it records whether OUR exact kill-switch rules are present
# (iif br-lan / iif br-guest at priority 5279 -> lookup 100, both families), the
# table-100 unreachable default, the table-52 exit-node default, the daemon
# state, ExitNodeID, and the relevant UCI. It also samples any "blackhole" rule
# at priority 5280 — that is GL 4.9's own ts_killswitch (IPv4 + br-lan only),
# which no longer collides with ours now that we sit at 5279; recorded as an
# informational signal of whether GL's partial KS is armed during the run.
#
# Heavy tailscale probes (BackendState + ExitNodeID) cost ~10MB RSS each; set
# TS_PROBE=0 to sample kernel/UCI only on RAM-constrained (512MB) routers.
#
# Harvest the CSV afterwards:  scp -O root@<router>:/tmp/ts-fix-test/<file> .
#
# Copyright (c) 2026 RemoteToHome Consulting (https://remotetohome.io)
# https://github.com/RemoteToHome-io/gl-tailscale-fix

DURATION="${DURATION:-180}"
INTERVAL="${INTERVAL:-1}"
LABEL="${LABEL:-router}"
OUT="${OUT:-/tmp/ts-fix-test}"
TS_PROBE="${TS_PROBE:-1}"

mkdir -p "$OUT"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
csv="$OUT/${stamp}-${LABEL}.csv"

rule_has() {
  # $1 = -4|-6 ; $2 = iface ; 1 if "iif <iface> ... lookup 100" present at pri 5279
  if ip "$1" rule list priority 5279 2>/dev/null | grep "iif $2 " | grep -q "lookup 100"; then
    echo 1; else echo 0; fi
}
bh_present() {
  # $1 = -4|-6 ; 1 if ANY blackhole rule at priority 5280 (GL's native ts_killswitch)
  if ip "$1" rule list priority 5280 2>/dev/null | grep -q "blackhole"; then echo 1; else echo 0; fi
}
t100_def() {
  if ip "$1" route show table 100 2>/dev/null | grep -q "unreachable default"; then echo 1; else echo 0; fi
}
t52_def() {
  if ip "$1" route show table 52 2>/dev/null | grep -q "default"; then echo 1; else echo 0; fi
}
wan_def() {
  # 1 if a v4 default route exists in main — netifd removes it when the uplink drops,
  # so this column records whether the WAN-bounce trigger actually took, router-side.
  if ip -4 route show default 2>/dev/null | grep -q "^default"; then echo 1; else echo 0; fi
}

printf 'ts_epoch,lan4,guest4,lan6,guest6,t100_4,t100_6,t52_4,t52_6,bh4,bh6,daemon,backend,exitnodeid,uci_exit_ip,uci_ks,wan_def\n' > "$csv"
echo "[router-sampler] start=$stamp duration=${DURATION}s interval=${INTERVAL}s ts_probe=$TS_PROBE csv=$csv" >&2

end=$(( $(date +%s) + DURATION ))
while [ "$(date +%s)" -lt "$end" ]; do
  now="$(date +%s)"
  lan4="$(rule_has -4 br-lan)"; guest4="$(rule_has -4 br-guest)"
  lan6="$(rule_has -6 br-lan)"; guest6="$(rule_has -6 br-guest)"
  t1004="$(t100_def -4)"; t1006="$(t100_def -6)"
  t524="$(t52_def -4)"; t526="$(t52_def -6)"
  bh4="$(bh_present -4)"; bh6="$(bh_present -6)"
  if pgrep tailscaled >/dev/null 2>&1; then daemon=1; else daemon=0; fi
  backend=""; enid=""
  if [ "$daemon" = "1" ] && [ "$TS_PROBE" = "1" ]; then
    backend="$(/usr/sbin/tailscale status --json 2>/dev/null | jsonfilter -e '@.BackendState' 2>/dev/null)"
    enid="$(/usr/sbin/tailscale debug prefs 2>/dev/null | jsonfilter -e '@.ExitNodeID' 2>/dev/null)"
  fi
  uci_exit="$(uci -q get tailscale.settings.exit_node_ip)"
  uci_ks="$(uci -q get ts-fix.settings.kill_switch)"
  wandef="$(wan_def)"
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$now" "$lan4" "$guest4" "$lan6" "$guest6" "$t1004" "$t1006" "$t524" "$t526" \
    "$bh4" "$bh6" "$daemon" "${backend:-}" "${enid:-}" "${uci_exit:-}" "${uci_ks:-}" "$wandef" >> "$csv"
  printf '[%s] lan4=%s guest4=%s lan6=%s guest6=%s t52_4=%s backend=%s enid=%s ks=%s bh4=%s bh6=%s wan=%s\n' \
    "$now" "$lan4" "$guest4" "$lan6" "$guest6" "$t524" "${backend:-?}" "${enid:-none}" "${uci_ks:-?}" "$bh4" "$bh6" "$wandef" >&2
  sleep "$INTERVAL"
done
echo "[router-sampler] done csv=$csv" >&2
