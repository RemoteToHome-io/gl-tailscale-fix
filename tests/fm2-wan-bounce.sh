#!/bin/bash
#
# FM2 — WAN interface change / multi-WAN autoswitch / temp disconnect-reconnect.
#
# This is the reset-window failure mode: an ifup (WAN reconnect, eth->repeater->
# tether autoswitch, or roam) makes GL run "gl_tailscale restart" -> "tailscale
# up --reset". During that window Tailscale's own KS is briefly down and GL
# rebuilds its routing rules; OUR kill switch (ip rule 5279 -> table 100) must
# hold throughout. The known fw3 bug is that GL's IPv4 rule rebuild clobbers our
# br-lan 5279 rule and nothing re-adds it -> LAN leak while the KS shows "on".
#
# This script is a TEMPLATE for the other failure modes: a "start" phase that
# launches the monitors and prints the operator runbook, and an "analyze" phase
# that correlates the laptop egress artifact with the router rule artifact.
#
# SAFETY: arming the KS blackholes the laptop. The egress monitor is time-boxed
# and fully detached, so it keeps recording through the blackhole and self-stops.
# Claude/this script issue NO state-changing commands on the router — the
# operator triggers the WAN event and the recovery (disable KS, or disable TS)
# by hand, per the printed timeline.
#
# Usage:
#   ./fm2-wan-bounce.sh start   --target <router-ip> [--duration 180] [--label fm2-<fw>]
#   ./fm2-wan-bounce.sh analyze --egress <base> --router <router.csv> \
#                               [--offset <sec>] [--trigger <epoch>] [--recover <epoch>]
#
# Copyright (c) 2026 RemoteToHome Consulting (https://remotetohome.io)
# https://github.com/RemoteToHome-io/gl-tailscale-fix

set -u
source "$(cd "$(dirname "$0")" && pwd)/lib/common.sh"

FM="fm2"
FM_DESC="WAN bounce / autoswitch / reconnect (the up --reset window)"

usage() { grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

cmd_start() {
  local target="" duration=180
  LABEL="${LABEL:-fm2}"
  while [ $# -gt 0 ]; do
    case "$1" in
      --target)   target="$2"; shift 2 ;;
      --duration) duration="$2"; shift 2 ;;
      --label)    LABEL="$2"; shift 2 ;;
      *) echo "unknown arg: $1" >&2; usage ;;
    esac
  done
  [ -z "$target" ] && { echo "ERROR: --target <router-ip> required" >&2; usage; }

  echo "=== FM2 START — $FM_DESC ==="
  echo "target router : $target"
  echo

  echo "[1/4] Capturing tunnel baseline (current laptop egress — should be the EXIT NODE IP)..."
  local b4 b6; b4="$(tsfx_curl_ip -4)"; b6="$(tsfx_curl_ip -6)"
  echo "      tunnel_v4 = ${b4:-<none>}"
  echo "      tunnel_v6 = ${b6:-<none>}"
  if [ -z "$b4" ] && [ -z "$b6" ]; then
    echo "      WARNING: no egress on either family. Confirm TS is enabled, the Custom"
    echo "      Exit Node is set, and the KS is ON before continuing. (A baseline of"
    echo "      <none> means every later response is treated as a LEAK.)"
  fi
  echo

  echo "[2/4] Measuring router<->laptop clock offset (read-only)..."
  local offset; offset="$(tsfx_clock_offset "$target")"
  echo "      offset (router_epoch - laptop_epoch) = $offset s"
  echo

  echo "[3/4] Launching detached laptop egress monitor (${duration}s, v4+v6 concurrent)..."
  local base
  DURATION="$duration" INTERVAL=1 LABEL="$LABEL" TUNNEL_V4="$b4" TUNNEL_V6="$b6" base="$(tsfx_launch_egress)"
  sleep 3
  if [ -f "$base-egress.csv" ]; then
    echo "      OK  egress artifact: $base-egress.csv"
  else
    echo "      ERROR: monitor did not start; check $base-egress.log" >&2; exit 1
  fi
  # Stash run metadata for analyze.
  cat > "$base-meta.json" <<META
{ "fm": "$FM", "target": "$target", "duration_s": $duration, "label": "$LABEL",
  "tunnel_v4": "$b4", "tunnel_v6": "$b6", "clock_offset_s": "$offset",
  "egress_base": "$base", "started_epoch": $(date +%s) }
META
  echo "      metadata: $base-meta.json"
  echo

  echo "[4/4] Start the router-side sampler in YOUR terminal now:"
  tsfx_router_cmd "$target" "$duration" "$LABEL"
  echo
  echo "=== OPERATOR RUNBOOK (relative to NOW) ==="
  echo "  T+0s        monitors running. Confirm both show baseline (v4/v6 = tunnel IP)."
  echo "  ~T+20s      TRIGGER the WAN event ONCE (pick the realistic one):"
  echo "                - unplug/replug the WAN cable, OR"
  echo "                - SSH: ifdown wan; sleep 3; ifup wan, OR"
  echo "                - switch the active uplink (eth -> repeater -> tether) in the GL UI"
  echo "              Note the wall-clock you triggered it (for --trigger)."
  echo "  watch       laptop monitor: 'blocked' = KS holding (good); any non-tunnel IP = LEAK."
  echo "  ~T+$((duration-20))s  RECOVER: disable the KS (or disable TS) so the laptop regains WAN."
  echo "  T+${duration}s     monitor self-stops and writes its JSON verdict."
  echo
  echo "When connectivity is back, harvest + analyze:"
  echo "  router_csv=\$(./fm2-wan-bounce.sh _harvest --target $target --label $LABEL)"
  echo "  ./fm2-wan-bounce.sh analyze --egress $base --router \"\$router_csv\" --offset $offset"
}

cmd_harvest() {
  local target="" label="fm2"
  while [ $# -gt 0 ]; do case "$1" in
    --target) target="$2"; shift 2 ;; --label) label="$2"; shift 2 ;; *) shift ;;
  esac; done
  tsfx_harvest_router "$target" "$label"
}

cmd_analyze() {
  local base="" router="" offset=0 trigger="" recover=""
  while [ $# -gt 0 ]; do case "$1" in
    --egress)  base="$2"; shift 2 ;;
    --router)  router="$2"; shift 2 ;;
    --offset)  offset="$2"; shift 2 ;;
    --trigger) trigger="$2"; shift 2 ;;
    --recover) recover="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; usage ;;
  esac; done
  [ -z "$base" ] && { echo "ERROR: --egress <base> required" >&2; usage; }
  local egress_csv="$base-egress.csv" egress_json="$base-egress.json"
  [ -f "$egress_csv" ] || { echo "ERROR: $egress_csv not found" >&2; exit 1; }
  [ "$offset" = "NA" ] && offset=0

  echo "=== FM2 ANALYZE — $FM_DESC ==="
  echo "egress csv : $egress_csv"
  echo "router csv : ${router:-<none provided>}  (offset ${offset}s)"
  echo

  # Egress leaks (laptop truth).
  local leaks; leaks="$(awk -F, 'NR>1 && ($4=="LEAK" || $6=="LEAK")' "$egress_csv")"
  if [ -z "$leaks" ]; then
    echo "EGRESS: no LEAK samples. (v4/v6 were tunnel or blocked throughout.)  -> PASS candidate"
  else
    echo "EGRESS: LEAK samples detected:"
    echo "  ts_epoch            v4_ip            v4 / v6_ip                 v6"
    echo "$leaks" | awk -F, '{printf "  %s  %-15s %-4s %-25s %-4s\n",$1,$3,$4,$5,$6}'
  fi
  echo

  # Router rule state at the leak instants (rule truth), aligned by clock offset.
  if [ -n "$router" ] && [ -f "$router" ] && [ -n "$leaks" ]; then
    echo "ROUTER rule state at each leak instant (br-lan/br-guest 5279, table52, gl-ks@5280):"
    echo "$leaks" | awk -F, '{print $1}' | while read -r lt; do
      local rt=$(( lt + offset ))
      # nearest router sample at/just after rt
      awk -F, -v rt="$rt" 'NR>1 && $1>=rt {print; exit}' "$router" | \
        awk -F, '{printf "  @router %s  lan4=%s guest4=%s lan6=%s guest6=%s t52_4=%s t52_6=%s bh4=%s bh6=%s ks=%s enid=%s\n",$1,$2,$3,$4,$5,$8,$9,$10,$11,$16,$14}'
    done
    echo
    echo "GL ts_killswitch check (blackhole at 5280 ever present):"
    awk -F, 'NR>1 && ($10=="1" || $11=="1"){print "  @"$1" bh4="$10" bh6="$11}' "$router" | head -20
  fi
  echo

  if [ -f "$egress_json" ]; then
    echo "MONITOR verdict:"
    grep -E '"(samples|leak_v4_count|leak_v6_count|first_leak_epoch|verdict)"' "$egress_json" | sed 's/^/  /'
  fi
}

case "${1:-}" in
  start)    shift; cmd_start "$@" ;;
  analyze)  shift; cmd_analyze "$@" ;;
  _harvest) shift; cmd_harvest "$@" ;;
  *) usage ;;
esac
