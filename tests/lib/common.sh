#!/bin/bash
#
# gl-tailscale-fix test suite — shared config + helpers (laptop side).
# Sourced by the per-failure-mode orchestration scripts; not executed directly.
#
# Copyright (c) 2026 RemoteToHome Consulting (https://remotetohome.io)
# https://github.com/RemoteToHome-io/gl-tailscale-fix

TSFX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TSFX_LIB="$TSFX_DIR/lib"
TSFX_RESULTS="$TSFX_DIR/results"
mkdir -p "$TSFX_RESULTS"

: "${MAXTIME:=3}"
: "${CONNTIME:=2}"
: "${V4_URLS:=https://v4.ident.me https://api.ipify.org}"
: "${V6_URLS:=https://v6.ident.me https://api6.ipify.org}"
: "${SSH_OPTS:=-o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new -o BatchMode=yes}"

# Always pass TARGET explicitly per run (your router's LAN IP). The suite was
# validated on fw4/4.8.x and fw3/4.9.x GL routers, including runs where the
# monitored laptop sat behind the router under test.

# Capture the laptop's current public egress for a family (the tunnel baseline).
#   $1 = -4|-6 ; prints IP or empty
tsfx_curl_ip() {
  local fam="$1" url out urls
  [ "$fam" = "-4" ] && urls="$V4_URLS" || urls="$V6_URLS"
  for url in $urls; do
    out="$(curl "$fam" -s --connect-timeout "$CONNTIME" --max-time "$MAXTIME" "$url" 2>/dev/null | tr -d '[:space:]')"
    case "$out" in "" | *[!0-9a-fA-F:.]*) ;; *) printf '%s' "$out"; return 0 ;; esac
  done
  printf ''
}

# Router clock minus laptop clock, in seconds (for cross-device correlation).
#   $1 = target ; prints integer offset, or "NA" if unreachable (read-only).
tsfx_clock_offset() {
  local t="$1" r l
  r="$(ssh $SSH_OPTS "root@$t" 'date +%s' 2>/dev/null)"
  l="$(date +%s)"
  if [ -n "$r" ]; then echo $(( r - l )); else echo "NA"; fi
}

# Launch the laptop egress monitor fully detached (survives this shell AND a
# WAN/KS blackhole). Honors DURATION INTERVAL LABEL TUNNEL_V4 TUNNEL_V6.
# Prints the artifact base path (".csv"/".json"/".log" share it).
# NOTE: every honored variable must be passed explicitly in the child env below.
# They arrive here as UNEXPORTED shell vars (fm2's `VAR=x base="$(...)"` prefix
# assigns in the caller's shell without exporting), so the setsid'd external
# script cannot see them unless they're re-stated on its command line — the
# 2026-07-02 dry run shipped an empty TUNNEL_V4 to the monitor this way and
# every healthy tunnel sample was misclassified as LEAK.
tsfx_launch_egress() {
  local stamp base
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  base="$TSFX_RESULTS/${stamp}-${LABEL:-egress}"
  CSV="$base-egress.csv" JSON="$base-egress.json" OUTDIR="$TSFX_RESULTS" \
  DURATION="${DURATION:-180}" INTERVAL="${INTERVAL:-1}" LABEL="${LABEL:-egress}" \
  TUNNEL_V4="${TUNNEL_V4:-}" TUNNEL_V6="${TUNNEL_V6:-}" \
    setsid "$TSFX_LIB/egress-monitor.sh" > "$base-egress.log" 2>&1 < /dev/null &
  echo "$base"
}

# Print the SSH one-liner for the operator to start the router-side sampler.
#   $1 = target ; $2 = duration ; $3 = label
tsfx_router_cmd() {
  local t="$1" d="$2" l="$3"
  cat <<CMD
  # On the router (READ-ONLY, safe on the gateway), in your own terminal:
  ssh $SSH_OPTS root@$t 'DURATION=$d INTERVAL=1 LABEL=$l sh -s' < "$TSFX_LIB/router-sampler.sh"
  # afterwards harvest with:
  ssh $SSH_OPTS root@$t 'ls -t /tmp/ts-fix-test/*-$l.csv | head -1'
CMD
}

# Harvest a router sampler CSV to results/.  $1 = target ; $2 = label
tsfx_harvest_router() {
  local t="$1" l="$2" remote
  remote="$(ssh $SSH_OPTS "root@$t" "ls -t /tmp/ts-fix-test/*-$l.csv 2>/dev/null | head -1" 2>/dev/null)"
  [ -z "$remote" ] && { echo "no router CSV found for label $l" >&2; return 1; }
  scp -O $SSH_OPTS "root@$t:$remote" "$TSFX_RESULTS/" >/dev/null 2>&1 \
    && echo "$TSFX_RESULTS/$(basename "$remote")"
}
