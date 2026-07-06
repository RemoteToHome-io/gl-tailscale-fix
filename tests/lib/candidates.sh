#!/bin/sh
#
# gl-tailscale-fix test suite — kill-switch CANDIDATE mechanisms (router-side)
#
# Installs/removes competing KS block mechanisms at priority 5279 so the efficacy
# suite can compare them head-to-head ON THE WIRE — and tests GL's own ts_killswitch
# as a suspect, not a template. NOTHING here is assumed to work because GL (or anyone)
# uses it: each candidate must PROVE it actually terminates forwarded LAN/guest->WAN
# traffic when the tunnel is down. The UCI syntax is best-effort and is itself
# validated by `show` after arming (does the rule actually land in `ip rule`?).
#
# Design note: netifd's `config rule` can carry a direct `action` (unreachable/
# blackhole/prohibit) but our PROVEN mechanism is the two-step rule->lookup 100->
# `unreachable default` route, and a table-100 route is awkward to express in UCI
# (`config route` wants an interface). So the UCI candidates are limited to a DIRECT
# action — which is exactly the form our premise found LESS reliable than the
# two-step. That tension is the point of the comparison, not a detail to gloss.
#
# !! STATE-CHANGING. Arming a KS blackholes LAN/guest egress when the tunnel is down.
#    Run only on a test router you are driving — never silently on a gateway you need.
#
# Run ON the router, e.g.:
#   ssh root@<router> 'sh -s' < candidates.sh show
#   ssh root@<router> 'sh -s' < candidates.sh arm raw-lookup
#   ssh root@<router> 'sh -s' < candidates.sh teardown all
#
# Copyright (c) 2026 RemoteToHome Consulting (https://remotetohome.io)
# https://github.com/RemoteToHome-io/gl-tailscale-fix

PRI=5279
TBL=100

show() {
  echo "--- ip -4 rule (5270-5285) ---"; ip -4 rule show 2>/dev/null | awk -F: '{p=$1+0} p>=5270 && p<=5285'
  echo "--- ip -6 rule (5270-5285) ---"; ip -6 rule show 2>/dev/null | awk -F: '{p=$1+0} p>=5270 && p<=5285'
  echo "--- table $TBL (v4/v6) ---"; ip -4 route show table $TBL 2>/dev/null; ip -6 route show table $TBL 2>/dev/null
  echo "--- our UCI network sections ---"; uci -q show network 2>/dev/null | grep "tsfix_ks" || echo "  (none)"
  echo "--- GL ts_block_lan_leak ---"; uci -q show network.ts_block_lan_leak 2>/dev/null || echo "  (none)"
}

arm_raw_lookup() {
  # Our proven two-step: rule -> lookup table 100 -> unreachable default. Raw ip rule.
  for fam in -4 -6; do
    ip $fam route show table $TBL 2>/dev/null | grep -q "unreachable default" || \
      ip $fam route add unreachable default table $TBL 2>/dev/null
    ip $fam rule list priority $PRI 2>/dev/null | grep "iif br-lan " | grep -q "lookup $TBL" || \
      ip $fam rule add iif br-lan priority $PRI lookup $TBL 2>/dev/null
    ip $fam rule list priority $PRI 2>/dev/null | grep "iif br-guest " | grep -q "lookup $TBL" || \
      ip $fam rule add iif br-guest priority $PRI lookup $TBL 2>/dev/null
  done
}
teardown_raw_lookup() {
  for fam in -4 -6; do
    ip $fam rule del iif br-lan priority $PRI lookup $TBL 2>/dev/null
    ip $fam rule del iif br-guest priority $PRI lookup $TBL 2>/dev/null
    ip $fam route del unreachable default table $TBL 2>/dev/null
  done
}

# UCI direct-action candidates. $1 = unreachable | blackhole
# (uci-blackhole is GL's exact action — lets us A/B GL's mechanism vs unreachable.)
arm_uci_action() {
  act="$1"
  uci -q batch <<EOF
set network.tsfix_ks_lan=rule
set network.tsfix_ks_lan.in=lan
set network.tsfix_ks_lan.priority=$PRI
set network.tsfix_ks_lan.action=$act
set network.tsfix_ks_guest=rule
set network.tsfix_ks_guest.in=guest
set network.tsfix_ks_guest.priority=$PRI
set network.tsfix_ks_guest.action=$act
set network.tsfix_ks_lan6=rule6
set network.tsfix_ks_lan6.in=lan
set network.tsfix_ks_lan6.priority=$PRI
set network.tsfix_ks_lan6.action=$act
set network.tsfix_ks_guest6=rule6
set network.tsfix_ks_guest6.in=guest
set network.tsfix_ks_guest6.priority=$PRI
set network.tsfix_ks_guest6.action=$act
EOF
  uci commit network
  /etc/init.d/network reload >/dev/null 2>&1
}
teardown_uci_action() {
  for s in tsfix_ks_lan tsfix_ks_guest tsfix_ks_lan6 tsfix_ks_guest6; do
    uci -q delete network.$s
  done
  uci commit network
  /etc/init.d/network reload >/dev/null 2>&1
}

# GL's own ts_killswitch (4.9). Arm by satisfying its gate then running it; it needs
# an exit node configured (exit_node_ip non-empty) + run_exit_node!=1 to actually arm.
arm_gl_tskillswitch() {
  [ -x /usr/bin/ts_killswitch ] || { echo "  /usr/bin/ts_killswitch absent (not 4.9?)"; return 1; }
  [ -n "$(uci -q get tailscale.settings.exit_node_ip)" ] || \
    echo "  WARN: exit_node_ip empty — GL will NOT arm. Set a Custom Exit Node first."
  uci -q set tailscale.settings.killswitch=1; uci commit tailscale
  /usr/bin/ts_killswitch
}
teardown_gl_tskillswitch() {
  uci -q set tailscale.settings.killswitch=0; uci commit tailscale
  [ -x /usr/bin/ts_killswitch ] && /usr/bin/ts_killswitch
  uci -q delete tailscale.settings.killswitch; uci commit tailscale
}

cmd="${1:-show}"; name="${2:-}"
case "$cmd" in
  show) show ;;
  arm)
    case "$name" in
      raw-lookup)      arm_raw_lookup ;;
      uci-unreachable) arm_uci_action unreachable ;;
      uci-blackhole)   arm_uci_action blackhole ;;
      gl-tskillswitch) arm_gl_tskillswitch ;;
      *) echo "unknown candidate: $name (raw-lookup|uci-unreachable|uci-blackhole|gl-tskillswitch)"; exit 1 ;;
    esac
    echo "=== armed $name ==="; show ;;
  teardown)
    case "$name" in
      raw-lookup)                    teardown_raw_lookup ;;
      uci-unreachable|uci-blackhole) teardown_uci_action ;;
      gl-tskillswitch)               teardown_gl_tskillswitch ;;
      all) teardown_raw_lookup; teardown_uci_action; teardown_gl_tskillswitch ;;
      *) echo "unknown candidate: $name (or 'all')"; exit 1 ;;
    esac
    echo "=== torn down $name ==="; show ;;
  *) echo "usage: candidates.sh show | arm <name> | teardown <name|all>"; exit 1 ;;
esac
