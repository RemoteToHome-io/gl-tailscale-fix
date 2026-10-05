#!/bin/sh
# Unit test for iot_net() and route_list_drop() in src/scripts/ts-fix-reapply (Route IoT), and
# for reapply's Route IoT advertisement block (the RIA cases at the end, helper mode only).
# Runs on the dev laptop, no router required:
#   sh tests/unit/test-iot-net.sh           the shipping helper, extracted from reapply
#   sh tests/unit/test-iot-net.sh legacy    negative control: the pre-fix code copied below,
#                                            run against the cases it can answer — every DEFECT
#                                            case must FAIL there, every GUARD case pass
#
# The helper is extracted from the real source between its marker comments rather than duplicated
# here, so this tests shipping code. If the markers or the names change, extraction yields nothing
# and the run fails loudly — which is the intended signal.
#
# `ip` is shimmed by a function that answers only "ip -4 addr show br-iot"; any other call fails
# the run. IPCALC points at a fake in a temp dir that logs its calls. For the addresses below it
# prints the lines GL's /bin/ipcalc.sh prints for them; for an empty or prefix-less argument it
# prints NETWORK=0.0.0.0 and PREFIX=0, which is what the real script answers there too — so a
# helper that ever handed ipcalc such an argument would fail the no-address cases.

MODE=${1:-helper}
SRC="$(dirname "$0")/../../src/scripts/ts-fix-reapply"
RPC="$(dirname "$0")/../../src/rpc/ts-fix"

T=$(mktemp -d) || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$T"' EXIT
FAKE_IPCALC_LOG="$T/ipcalc.calls"
export FAKE_IPCALC_LOG

cat > "$T/ipcalc.sh" <<'EOF'
#!/bin/sh
printf '%s:%s\n' "$#" "$*" >> "$FAKE_IPCALC_LOG"
case "$#:$1" in
    1:192.168.11.1/23)
        printf 'IP=192.168.11.1\nNETMASK=255.255.254.0\nBROADCAST=192.168.11.255\n'
        printf 'NETWORK=192.168.10.0\nPREFIX=23\n' ;;
    1:192.168.10.1/24)
        printf 'IP=192.168.10.1\nNETMASK=255.255.255.0\nBROADCAST=192.168.10.255\n'
        printf 'NETWORK=192.168.10.0\nPREFIX=24\n' ;;
    1:10.76.0.1/24) echo "ipcalc: simulated failure" >&2; exit 1 ;;
    1:10.77.0.1/24) ;;
    1:10.78.0.1/24) printf 'NETWORK=10.78.0.0\nPREFIX=24\n'; exit 1 ;;
    1:10.79.0.1/24) printf 'NETWORK=10.79.0.0\n' ;;
    1:10.80.0.1/24) printf 'NETWORK=10.80.0.0 x\nPREFIX=24\n' ;;
    1:*/*) exit 1 ;;
    *) printf 'NETWORK=0.0.0.0\nPREFIX=0\n' ;;
esac
EOF
chmod +x "$T/ipcalc.sh"

INET=""
ip() {
    if [ "$*" != "-4 addr show br-iot" ]; then
        printf 'ip %s\n' "$*" >> "$T/unexpected"
        return 1
    fi
    printf '7: br-iot: <BROADCAST,MULTICAST,UP,LOWER_UP> mtu 1500 qdisc noqueue state UP\n'
    [ -z "$INET" ] || printf '%s\n' "$INET"
}
line() { printf '    inet %s scope global br-iot' "$1"; }
extract() {
    awk '/^# ---8<--- route_list_drop/,/^# ---8<--- end route_list_drop/' "$SRC"
    awk '/^# ---8<--- iot_net/,/^# ---8<--- end iot_net/' "$SRC"
}

if [ "$MODE" = legacy ]; then
    # The pre-fix code, copied from ts-fix-reapply as it stood before this change: the derivation
    # used at its three sites, and the route removal (the second removal site is the same
    # expression over _cur/_iot).
    iot_impl() {
        ip -4 addr show br-iot 2>/dev/null | awk '/inet /{print $2}' | sed 's|\.[0-9]*/|.0/|'
    }
    drop_impl() {
        echo "$1" | sed "s/${2},//;s/,${2}//;s/^${2}$//;s/,$//"
    }
else
    IPCALC="$T/ipcalc.sh"
    eval "$(extract)"
    if ! command -v iot_net >/dev/null 2>&1 || ! command -v route_list_drop >/dev/null 2>&1
    then
        echo "FAIL: could not extract iot_net/route_list_drop from $SRC (markers missing?)"
        exit 1
    fi
    iot_impl() { iot_net; }
    drop_impl() { route_list_drop "$1" "$2"; }
fi

fails=0
report() {  # $1 = class, $2 = description, $3 = want, $4 = got
    if [ "$3" = "$4" ]; then
        printf 'ok   %-6s %s\n' "$1" "$2"
    else
        printf 'FAIL %-6s %s\n     want=[%s]\n     got =[%s]\n' "$1" "$2" "$3" "$4"
        fails=$((fails + 1))
    fi
}
net() {  # $1 = class, $2 = description, $3 = br-iot inet line(s), $4 = expected output
    INET=$3
    rm -f "$FAKE_IPCALC_LOG"
    report "$1" "$2" "$4" "$(iot_impl)"
}
not_called() {  # after a net case: the fake must not have been invoked at all
    got="no ipcalc call"
    [ -e "$FAKE_IPCALC_LOG" ] && got=$(cat "$FAKE_IPCALC_LOG")
    report GUARD "$1" "no ipcalc call" "$got"
}
drop() {  # $1 = class, $2 = description, $3 = route list, $4 = entry to drop, $5 = expected
    report "$1" "$2" "$5" "$(drop_impl "$3" "$4")"
}
default_ipcalc() {  # run in a subshell: what IPCALC is when nothing overrides it
    unset IPCALC
    eval "$(extract)"
    printf '%s' "$IPCALC"
}

net DEFECT "/23 iot -> true network, not a.b.c.0" "$(line 192.168.11.1/23)" "192.168.10.0/23"
net GUARD  "/24 iot -> network unchanged"          "$(line 192.168.10.1/24)"  "192.168.10.0/24"
net GUARD  "no IPv4 address on br-iot -> nothing"  ""                          ""
[ "$MODE" = legacy ] || not_called "  ...and ipcalc is not called without an address"
net DEFECT "two IPv4 addresses -> the first one's network, as the RPC reads it" \
    "$(line 192.168.10.1/24)
$(line 10.99.0.1/16)" "192.168.10.0/24"

drop DEFECT "drop the IoT route from the middle" \
    "192.168.8.0/24,192.168.10.0/24,0.0.0.0/0," "192.168.10.0/24" "192.168.8.0/24,0.0.0.0/0"
drop DEFECT "drop it from the end (where the add path puts it)" \
    "192.168.8.0/24,0.0.0.0/0,::/0,192.168.10.0/24," "192.168.10.0/24" "192.168.8.0/24,0.0.0.0/0,::/0"
drop DEFECT "drop it from the front" "192.168.10.0/24,::/0," "192.168.10.0/24" "::/0"
drop GUARD  "drop the only route -> empty (the caller then clears)" \
    "192.168.10.0/24," "192.168.10.0/24" ""
drop DEFECT "dots are literal: 192.168.10.0/24 never matches 192x168x10x0/24" \
    "192x168x10x0/24,10.0.0.0/8," "192.168.10.0/24" "192x168x10x0/24,10.0.0.0/8"
drop DEFECT "whole entries only: dropping 192.168.10.0/2 leaves 192.168.10.0/24" \
    "10.0.0.0/8,192.168.10.0/24," "192.168.10.0/2" "10.0.0.0/8,192.168.10.0/24"

if [ "$MODE" != legacy ]; then
    net GUARD "ipcalc fails -> nothing"                  "$(line 10.76.0.1/24)" ""
    net GUARD "ipcalc prints nothing -> nothing"         "$(line 10.77.0.1/24)" ""
    net GUARD "ipcalc prints, then fails -> nothing"     "$(line 10.78.0.1/24)" ""
    net GUARD "ipcalc prints NETWORK only -> nothing"    "$(line 10.79.0.1/24)" ""
    net GUARD "ipcalc prints a malformed NETWORK -> nothing" "$(line 10.80.0.1/24)" ""
    net GUARD "address without a prefix -> nothing"      "$(line 192.168.10.1)"  ""
    not_called "  ...and a prefix-less address never reaches ipcalc (it would answer 0.0.0.0/0)"
    _saved=$IPCALC; IPCALC="$T/missing"
    net GUARD "ipcalc missing -> nothing"                "$(line 192.168.11.1/23)" ""
    IPCALC=$_saved
    report GUARD "IPCALC defaults to /bin/ipcalc.sh" "/bin/ipcalc.sh" "$(default_ipcalc)"

    # Static checks on the source files.
    report GUARD "the /24 sed shortcut no longer appears in reapply" "" \
        "$(grep -nF 's|\.[0-9]*/|.0/|' "$SRC")"
    report GUARD "reapply reads br-iot's address in one place (the helper)" "1" \
        "$(grep -c 'ip -4 addr show br-iot' "$SRC")"
    report GUARD "no sed program in reapply interpolates the IoT subnet" "" \
        "$(grep -nE 'sed .*\$\{?(_iot|iot_subnet)' "$SRC")"
    report GUARD "RPC no longer builds a.b.c.0/<prefix>" "" "$(grep -nF '".0/"' "$RPC")"
    report GUARD "RPC derives the network with /bin/ipcalc.sh" "1" \
        "$(awk '/^local function get_iot_subnet/,/^end/' "$RPC" | grep -cF '"/bin/ipcalc.sh ')"

    # Route IoT's advertisement block, extracted between its markers. --advertise-routes REPLACES
    # the whole list, so the add reads the current routes first — and a read that fails or times
    # out prints nothing, which must not pass for "no routes": the add would drop every other
    # route. The block's tailscale path is rewritten to the ts_cli fake; timeout, jsonfilter and
    # logger are fakes too. timeout records its arguments and plays a call cut off at its bound
    # (rc 124, nothing run, no output) when the command contains FAKE_EXPIRE — only that call, so
    # a bounded write after an expired read still shows. ts_cli's debug prefs prints a JSON
    # stand-in, or fails with FAKE_PREFS_FAIL set; jsonfilter prints FAKE_ROUTES one per line, as
    # jsonfilter prints an array, and nothing for empty input. Each case runs in a subshell.
    RIA=$(awk '/^# ---8<--- route iot advertise/,/^# ---8<--- end route iot advertise/' "$SRC")
    ria=$(printf '%s\n' "$RIA" | sed 's|/usr/sbin/tailscale |ts_cli |g')
    report GUARD "RIA the block was extracted, and all 5 tailscale calls (2 reads, 3 sets) now go to the fake" "5 0" \
        "$(printf '%s\n' "$ria" | grep -c 'ts_cli ') $(printf '%s\n' "$ria" | grep -c '/usr/sbin/tailscale')"
    timeout() {
        printf '%s\n' "$*" >> "$T/timeout.calls"
        shift
        if [ -n "$FAKE_EXPIRE" ]; then
            case "$*" in *"$FAKE_EXPIRE"*) return 124 ;; esac
        fi
        "$@"
    }
    ts_cli() {
        case "$1 $2" in
            "debug prefs") [ -n "$FAKE_PREFS_FAIL" ] && return 1; printf '{"stand-in":1}\n' ;;
            set\ *) printf '%s\n' "$*" >> "$T/set.calls" ;;
            *) printf 'ts_cli %s\n' "$*" >> "$T/unexpected"; return 1 ;;
        esac
    }
    jsonfilter() {
        _in=$(cat)
        [ -n "$_in" ] || return 1
        [ "$*" = "-e @.AdvertiseRoutes[*]" ] || { printf 'jsonfilter %s\n' "$*" >> "$T/unexpected"; return 1; }
        for _r in $FAKE_ROUTES; do printf '%s\n' "$_r"; done
    }
    logger() { printf '%s\n' "$*" >> "$T/log"; }
    fakes=""
    for f in timeout ts_cli jsonfilter logger; do
        case "$(type "$f" 2>&1)" in *function*) fakes="$fakes $f" ;; esac
    done
    report GUARD "RIA instrument lint: every fake resolves to its function in this shell" \
        " timeout ts_cli jsonfilter logger" "$fakes"
    report GUARD "RIA instrument lint: jsonfilter prints the routes one per line, nothing for no input" \
        "a/1
b/2|" "$(printf 'x' | FAKE_ROUTES='a/1 b/2' jsonfilter -e '@.AdvertiseRoutes[*]')|$(printf '' | jsonfilter -e '@.AdvertiseRoutes[*]')"
    : > "$T/timeout.calls"; : > "$T/set.calls"
    report GUARD "RIA instrument lint: the expiring call is rc 124 and runs nothing" "124" \
        "$(FAKE_EXPIRE='debug prefs' timeout 10 ts_cli debug prefs; echo "$?")"
    report GUARD "RIA instrument lint: any other call still runs" "0 set --x" \
        "$(FAKE_EXPIRE='debug prefs' timeout 10 ts_cli set --x; echo "$?") $(cat "$T/set.calls")"
    # ria_run <route_iot> <routes> <ok|fail|expire> -> "<set calls>|<routes_unread>"
    # routes_unread is seeded here because in reapply it is Route Guest's block that initializes it
    # (Route Guest runs first); this block only ever raises it to 1, so that a guest read failure
    # is not cleared by the IoT pass that follows.
    ria_run() {
        : > "$T/set.calls"; : > "$T/timeout.calls"; : > "$T/log"
        _u=$(
            route_iot=$1; iot_subnet=192.168.10.0/24; FAKE_ROUTES=$2; routes_unread=0
            case "$3" in fail) FAKE_PREFS_FAIL=1 ;; expire) FAKE_EXPIRE='debug prefs' ;; esac
            eval "$ria"
            printf '%s' "$routes_unread"
        )
        printf '%s|%s' "$(cat "$T/set.calls")" "$_u"
    }
    lan_up="192.168.50.0/24 0.0.0.0/0 ::/0"
    got=$(ria_run 1 "$lan_up" ok)
    report GUARD "RIA on, read ok: the IoT subnet is appended to every route already there" \
        "set --advertise-routes=192.168.50.0/24,0.0.0.0/0,::/0,192.168.10.0/24" "${got%|*}"
    report DEFECT "RIA ... nothing is left pending" "0" "${got##*|}"
    report DEFECT "RIA ... and both tailscale calls ran under timeout 10" "10 ts_cli debug prefs
10 ts_cli set --advertise-routes=192.168.50.0/24,0.0.0.0/0,::/0,192.168.10.0/24" "$(cat "$T/timeout.calls")"
    got=$(ria_run 1 "" ok)
    report GUARD "RIA on, read ok with no routes at all: the IoT subnet alone is right" \
        "set --advertise-routes=192.168.10.0/24" "${got%|*}"
    got=$(ria_run 1 "$lan_up" fail)
    report DEFECT "RIA on, the read fails: no write (the add would drop every other route)" "" "${got%|*}"
    report DEFECT "RIA ... left pending for the watchdog, and logged" "1 1" \
        "${got##*|} $(grep -c 'route iot: tailscale debug prefs failed or timed out' "$T/log")"
    got=$(ria_run 1 "$lan_up" expire)
    report DEFECT "RIA on, the read times out: no write, left pending" "|1" "$got"
    got=$(ria_run 1 "$lan_up 192.168.10.0/24" ok)
    report GUARD "RIA on, the IoT subnet already advertised: no write" "" "${got%|*}"
    got=$(ria_run 0 "$lan_up 192.168.10.0/24" ok)
    report GUARD "RIA off, read ok: the IoT subnet is dropped, the rest kept" \
        "set --advertise-routes=192.168.50.0/24,0.0.0.0/0,::/0" "${got%|*}"
    got=$(ria_run 0 "192.168.10.0/24" ok)
    report GUARD "RIA off, the IoT subnet the only route: the list is cleared" "set --advertise-routes=" "${got%|*}"
    got=$(ria_run 0 "$lan_up 192.168.10.0/24" fail)
    report GUARD "RIA off, the read fails: no write" "" "${got%|*}"
    report DEFECT "RIA ... and nothing is left pending (the flag is Route IoT's add only)" "0" "${got##*|}"
    got=$(ria_run 0 "$lan_up 192.168.10.0/24" expire)
    report DEFECT "RIA off, the read times out: no write" "" "${got%|*}"
    unset -f timeout ts_cli jsonfilter logger
fi

if [ -e "$T/unexpected" ]; then
    printf 'FAIL unexpected ip calls:\n%s\n' "$(cat "$T/unexpected")"
    fails=$((fails + 1))
fi

[ "$fails" -eq 0 ] && { echo "PASS (all cases, mode: $MODE)"; exit 0; }
echo "$fails case(s) failed (mode: $MODE)"; exit 1
