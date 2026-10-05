#!/bin/sh
# Unit test for the arm / disarm / check / rules-clean / rules-ensure / preboot subcommands of
# src/scripts/ts-fix-ks.
#
# Laptop-only, no router involved: uci, ip, ubus, jsonfilter, tailscale and logger are replaced with
# shell functions backed by flat state files, and the engine's one-line firewall-reload wrapper is
# replaced after sourcing (a shell function name cannot contain slashes, so /etc/init.d/firewall
# cannot be faked directly). The source-rule swap adds three more: /bin/ipcalc.sh is an executable
# fake the engine is pointed at after sourcing (KS_IPCALC), and mktemp and mv are pass-through
# wrappers that record, and can fail, the calls that write the swap marker.
#   sh tests/unit/test-ks-armdisarm.sh          (also runs under: busybox ash)
#
# The engine is SOURCED, not copied, so these cases bind to shipping code. TS_FIX_KS_NO_MAIN=1
# suppresses the script's own dispatcher call so the cases can drive ks_main directly; if that
# guard or a subcommand name changes, the run aborts loudly, which is the intended signal.
#
# Case 0 lints the instrument itself: the fakes are asserted against the real uci behaviours the
# engine depends on (missing key -> empty + rc 1, list get space-joined, empty set acts as a
# delete, `uci show` section/option formatting) before any engine case is trusted. Case 0b does the
# same for the ip fake's model of policy rules and table-100 routes, and case 0c checks that every
# faked name really resolves to its fake in the shell running the suite, and that each recorder
# records — the "zero calls" assertions below are vacuous otherwise. Case 0d lints the model's
# priority-0 rules and its `ip -4 -br addr` listing, case 0e the ipcalc, mktemp and mv fakes.

# ---8<--- root-guard
# Never as root. Some cases plant things at the marker path — a symlink, a directory, a file the
# engine must treat as another user's — and root would let a mistake there read or remove a file
# that belongs to the system. Nothing in this suite needs privilege. Case 0f lints this block.
if [ "$(id -u)" = "0" ]; then
    echo "FAIL: this suite must not run as root (uid 0)"
    exit 1
fi
# ---8<--- end root-guard

SRC="$(dirname "$0")/../../src/scripts/ts-fix-ks"
T="${TMPDIR:-/tmp}/ts-fix-ks-test.$$"
mkdir -p "$T" || { echo "FAIL: cannot create $T"; exit 1; }
trap 'rm -rf "$T"' EXIT
STATE="$T/uci.state"
: > "$STATE"
fails=0

# ------------------------------------------------------------------------- assertion helpers
ok()    { printf 'ok   %s\n' "$1"; }
nok()   { printf 'FAIL %s\n       want: [%s]\n       got:  [%s]\n' "$1" "$2" "$3"; fails=$((fails + 1)); }
is()    { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "$2" "$3"; fi; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) nok "$1" "text containing: $2" "$3" ;; esac; }
hasnt() { case "$3" in *"$2"*) nok "$1" "text NOT containing: $2" "$3" ;; *) ok "$1" ;; esac; }

# ------------------------------------------------------------------------------- the uci fake
# State records, one per line:
#   S|<pkg>.<section>|<type>            section declaration
#   O|<pkg>.<section>.<option>|<value>  option (list options are stored space-joined, which is
#                                       exactly what `uci get` prints for them)
_uci_get() {
    local k p v rc=1
    while IFS='|' read -r k p v; do
        if [ "$k" = "O" ] && [ "$p" = "$1" ]; then printf '%s\n' "$v"; rc=0; fi
    done < "$STATE"
    [ "$rc" = "0" ] && return 0
    # `uci get <pkg>.<section>` prints the section type
    while IFS='|' read -r k p v; do
        if [ "$k" = "S" ] && [ "$p" = "$1" ]; then printf '%s\n' "$v"; rc=0; fi
    done < "$STATE"
    return $rc
}

_uci_put() {    # kind key value — replaces in place, preserving record order
    local k p v wrote=0
    : > "$STATE.tmp"
    while IFS='|' read -r k p v; do
        if [ "$k" = "$1" ] && [ "$p" = "$2" ]; then
            printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$STATE.tmp"
            wrote=1
        else
            printf '%s|%s|%s\n' "$k" "$p" "$v" >> "$STATE.tmp"
        fi
    done < "$STATE"
    [ "$wrote" = "0" ] && printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$STATE.tmp"
    mv "$STATE.tmp" "$STATE"
}

_uci_del() {    # key — an option, or a section plus every option under it
    local k p v rc=1
    : > "$STATE.tmp"
    while IFS='|' read -r k p v; do
        if [ "$p" = "$1" ]; then rc=0; continue; fi
        case "$p" in "$1".*) rc=0; continue ;; esac
        printf '%s|%s|%s\n' "$k" "$p" "$v" >> "$STATE.tmp"
    done < "$STATE"
    mv "$STATE.tmp" "$STATE"
    return $rc
}

# <pkg> or <pkg>.<section> — section lines with the type unquoted, option lines single-quoted, as a
# router prints them (device-verified 2026-10-04 on GL 4.8.4, 4.9.0 and 4.11.0:
# "tailscale.settings=settings", then "tailscale.settings.enabled='1'"). A package or section with
# nothing to print is rc 1 and prints nothing, as on the device.
_uci_show() {
    local k p v k2 p2 v2 rc=1
    while IFS='|' read -r k p v; do
        [ "$k" = "S" ] || continue
        case "$1" in
            *.*) [ "$p" = "$1" ] || continue ;;
            *)   case "$p" in "$1".*) ;; *) continue ;; esac ;;
        esac
        rc=0
        printf '%s=%s\n' "$p" "$v"
        while IFS='|' read -r k2 p2 v2; do
            [ "$k2" = "O" ] || continue
            case "$p2" in "$p".*) printf "%s='%s'\n" "$p2" "$v2" ;; esac
        done < "$STATE"
    done < "$STATE"
    return $rc
}

uci() {
    local cmd arg key val cur
    printf 'uci %s\n' "$*" >> "$T/uci-calls"
    printf 'uci %s\n' "$*" >> "$T/seq"
    while [ $# -gt 0 ]; do
        case "$1" in -*) shift ;; *) break ;; esac
    done
    cmd="$1"; shift
    arg="$1"
    # Fault injection: UCI_READ_FAIL names packages (space separated) whose reads fail — a show or
    # get of one prints nothing and returns 1, as a read of an unreadable config does. That is also
    # exactly what a get of an ABSENT option does, which is why the engine reads intent with show.
    case "$cmd" in
        show|get)
            case " $UCI_READ_FAIL " in *" ${arg%%.*} "*) return 1 ;; esac
            ;;
    esac
    case "$cmd" in
        show) _uci_show "$arg" ;;
        get)  _uci_get "$arg" ;;
        set)
            # Fault injection: UCI_SET_FAIL is a substring; a matching assignment fails.
            if [ -n "$UCI_SET_FAIL" ]; then
                case "$arg" in *"$UCI_SET_FAIL"*) return 1 ;; esac
            fi
            key="${arg%%=*}"; val="${arg#*=}"
            [ "$key" = "$arg" ] && val=""
            # The real trap: `uci set key=''` creates NO option, i.e. it acts as a delete.
            if [ -z "$val" ]; then _uci_del "$key"; return 0; fi
            case "${key#*.}" in
                *.*) _uci_put O "$key" "$val" ;;
                *)   _uci_put S "$key" "$val" ;;
            esac
            ;;
        add_list)
            [ -n "$UCI_ADDLIST_FAIL" ] && return 1
            key="${arg%%=*}"; val="${arg#*=}"
            cur="$(_uci_get "$key")" || cur=""
            if [ -n "$cur" ]; then _uci_put O "$key" "$cur $val"; else _uci_put O "$key" "$val"; fi
            ;;
        delete) _uci_del "$arg" ;;
        commit)
            # Fault injection: UCI_COMMIT_FAIL=1 models a commit that cannot land (full or
            # read-only overlay). The staged value stays visible to later gets, exactly as an
            # uncommitted /tmp/.uci delta would be.
            if [ -n "$UCI_COMMIT_FAIL" ]; then
                printf '%s\n' "$arg" >> "$T/commit-attempts"
                return 1
            fi
            printf '%s\n' "$arg" >> "$T/commits"
            ;;
        *) return 1 ;;
    esac
}

# --------------------------------------------------------------- ip / ubus / jsonfilter / logger
# The ip fake is a small STATEFUL model of the things the engine's rule layer touches, per
# family, one record per line in $IPSTATE:
#   R|<family>|<priority>|<iif>|<action>   a policy rule: R|-4|5279|br-lan|lookup 100, or GL's
#                                          own kind, R|-4|5280|br-lan|blackhole
#   U|<family>|<table>                     an "unreachable default" route in that table
#   S|<family>|<priority>|<from>|<to>|<action>[|<iif>]
#                                          a selector rule, "all" for a selector it does not have:
#                                          GL's LAN and uplink rules and the swap's own
#                                          (S|-4|0|all|192.168.50.0/24|lookup main), GL's guest/iot
#                                          source rule (S|-4|0|192.168.160.0/24|all|lookup main);
#                                          the optional seventh field is an input device, for a
#                                          foreign rule such as "from <net> iif lo lookup main"
# `rule add` and `route add` append, except that an add identical to a record already present is
# refused as the kernel refuses it: rc 2, "RTNETLINK answers: File exists" on stderr, nothing
# appended. `rule del` and `route del` remove exactly ONE exactly-matching record (rc 1 when there
# is none). `rule list priority N` prints iproute2's format — a TAB after "N:", and "[detached]"
# after the name of a device listed in IP_ABSENT_DEVS — and `route show table N` prints each
# family's line as iproute2 does (v4 with its trailing space), or rc 2 and an error on stderr for
# an empty table. The default-route queries return fixture text instead (IP4_DEFAULT /
# IP6_DEFAULT). Twins, which a kernel that accepts identical rules could hold, are seeded directly.
#
# S records: only the four priority-0 "lookup main" forms the engine issues are understood (add
# "to"/"from" ... priority 0, del priority 0 "to"/"from" ...). They follow the kernel, which
# compares only the selectors a request GIVES: an add is refused with EEXIST when any rule at that
# priority and table matches it that way, and a delete removes the FIRST such rule in list order —
# so `del ... from X` also takes "from X to Y", and `add from X` collides with it. A delete that
# finds nothing is rc 2 with "RTNETLINK answers: No such file or directory", as iproute2 prints it.
# A record with an input device is taken by a delete that gives no device the same way: on kernel
# 5.4 with iproute2 6.3.0 (device-verified 2026-10-04) a delete that omits a selector removes the
# FIRST rule in list order matching the selectors it gives, so a foreign "from N iif lo lookup
# main" listed before GL's "from N lookup main" is the one deleted. Whether an add collides with
# such a record is not modelled: an add that meets one lands in $T/ip-unsupported, failing the run.
# `rule list priority 0` prints the kernel's own "from all lookup local" first (it is not a record,
# so nothing can delete it), then the records in insertion order. `ip -4 -br addr` prints lo, then
# the IP4_BR_ADDR fixture lines verbatim (see br_line for their exact layout).
#
# Fault and race injection, all substrings of the invocation: IP_ADD_FAIL makes a matching add
# fail and change nothing; IP_ADD_RACE plays a concurrent ensure that wins the race — the fake
# inserts the item just before refusing the engine's own add of it with EEXIST. For S deletes,
# IP_DEL_FAIL fails a matching delete and changes nothing, and IP_DEL_RACE plays a concurrent pass
# that deleted the rule first: the fake removes it, then the engine's own delete finds nothing.
# IP_READ_FAIL fails a matching read (a rule list, route show or brief address listing: rc 2, a
# "Cannot send dump request" text of our own on stderr) after letting IP_READ_FAIL_SKIP matching
# reads through. A kernel with no IPv6 stack is the harness's KS_IPV6_PROC pointing at a missing
# directory: every `ip -6` call then fails (rc 2, "Address family not supported" on stderr, a
# modelling assumption not checked against such a kernel).
#
# Checked against real iproute2 6.1.0 on a 6.8 kernel in a scratch network namespace (2026-09-30):
# both list/show formats, [detached] for a missing device, EEXIST for an identical rule or route
# add, and a lookup-qualified delete leaving a blackhole or lookup-1002 rule at the same priority
# alone. One simplification, not load-bearing because the engine treats every nonzero status
# alike: a delete of an R or U record that finds nothing is rc 2 there, not 1. Extended the same
# way for the swap (2026-09-30, tests/results/20260929-build/u3-runs/netns-probe*.out): the
# priority-0 list format and its insertion order after "local", GL's un-prioritised
# `ip rule add from <net> table main` landing at 0 and being the same rule as the swap's explicit
# re-add (EEXIST), the "to" and "from" deletes never taking each other's rule, the selector
# wildcard on both delete and EEXIST, rc 2 and the ENOENT text for a delete that finds nothing,
# and the `ip -4 -br addr` layout (name and state padded to 16 and 14, one space after each
# address, so a trailing space). What the fake does NOT model: a failing read's real error text.
#
# Every invocation is recorded in $T/ip-calls, and in $T/seq, which the uci fake and the reload
# wrapper also write, so ordering across the two layers can be asserted. An invocation the model
# does not understand is an instrument failure, not a silent success: it lands in
# $T/ip-unsupported, which the run asserts empty at the very end.
IPSTATE="$T/ip.state"
: > "$IPSTATE"
: > "$T/ip-unsupported"

_ip_del() {         # <record> — remove exactly one exactly-matching record; rc 1 when there is none
    local r gone=0
    : > "$IPSTATE.tmp"
    while IFS= read -r r; do
        if [ "$gone" = "0" ] && [ "$r" = "$1" ]; then gone=1; continue; fi
        printf '%s\n' "$r" >> "$IPSTATE.tmp"
    done < "$IPSTATE"
    mv "$IPSTATE.tmp" "$IPSTATE"
    [ "$gone" = "1" ]
}

_ip_rule_list() {   # <family> <priority>
    local k f p x y z w sel
    [ "$2" = "0" ] && printf '0:\tfrom all lookup local\n'
    while IFS='|' read -r k f p x y z w; do
        if [ "$f" != "$1" ] || [ "$p" != "$2" ]; then continue; fi
        case "$k" in
            R)
                case " $IP_ABSENT_DEVS " in
                    *" $x "*) printf '%s:\tfrom all iif %s [detached] %s\n' "$p" "$x" "$y" ;;
                    *)        printf '%s:\tfrom all iif %s %s\n' "$p" "$x" "$y" ;;
                esac
                ;;
            S)
                sel="from $x"
                [ "$y" = "all" ] || sel="$sel to $y"
                [ -n "$w" ] && sel="$sel iif $w"
                printf '%s:\t%s %s\n' "$p" "$sel" "$z"
                ;;
        esac
    done < "$IPSTATE"
}

# <family> <from> <to> [del] — is there a priority-0 "lookup main" S record the kernel would match
# for a request giving these selectors ("all" = not given, which matches any value)? With "del",
# the FIRST such record is removed. rc 0 when one matched.
_ip_smatch() {
    local fam="$1" src="$2" dst="$3" del="$4" r hit=1 IFS
    : > "$IPSTATE.m"
    while IFS= read -r r; do
        if [ "$hit" = "1" ]; then
            IFS='|'
            set -- $r
            IFS=' 	'
            if [ "$1" = "S" ] && [ "$2" = "$fam" ] && [ "$3" = "0" ] && [ "$6" = "lookup main" ] &&
               { [ "$src" = "all" ] || [ "$4" = "$src" ]; } &&
               { [ "$dst" = "all" ] || [ "$5" = "$dst" ]; }; then
                hit=0
                [ "$del" = "del" ] && continue
                [ -n "$7" ] && printf 'add meeting an iif rule: %s\n' "$r" >> "$T/ip-unsupported"
            fi
        fi
        printf '%s\n' "$r" >> "$IPSTATE.m"
    done < "$IPSTATE"
    if [ "$del" = "del" ]; then mv "$IPSTATE.m" "$IPSTATE"; else rm -f "$IPSTATE.m"; fi
    return $hit
}

_ip_sadd() {        # <invocation> <family> <from> <to>
    _ip_add_fails "$1" && return 2
    if [ -n "$IP_ADD_RACE" ]; then
        case "$1" in
            *"$IP_ADD_RACE"*) _ip_smatch "$2" "$3" "$4" || printf 'S|%s|0|%s|%s|lookup main\n' "$2" "$3" "$4" >> "$IPSTATE" ;;
        esac
    fi
    if _ip_smatch "$2" "$3" "$4"; then
        echo "RTNETLINK answers: File exists" >&2
        return 2
    fi
    printf 'S|%s|0|%s|%s|lookup main\n' "$2" "$3" "$4" >> "$IPSTATE"
}

_ip_sdel() {        # <invocation> <family> <from> <to>
    if [ -n "$IP_DEL_FAIL" ]; then
        case "$1" in *"$IP_DEL_FAIL"*) echo "RTNETLINK answers: Operation not permitted" >&2; return 2 ;; esac
    fi
    if [ -n "$IP_DEL_RACE" ]; then
        case "$1" in *"$IP_DEL_RACE"*) _ip_smatch "$2" "$3" "$4" del ;; esac
    fi
    _ip_smatch "$2" "$3" "$4" del && return 0
    echo "RTNETLINK answers: No such file or directory" >&2
    return 2
}

# <invocation> — the IP_READ_FAIL fault injection. The count of matching reads lives in a file:
# the engine runs every read inside a command substitution, a subshell of its own.
_ip_read_fails() {
    [ -n "$IP_READ_FAIL" ] || return 1
    case "$1" in *"$IP_READ_FAIL"*) ;; *) return 1 ;; esac
    printf 'x\n' >> "$T/ip-readfail-count"
    [ "$(grep -c . "$T/ip-readfail-count")" -gt "${IP_READ_FAIL_SKIP:-0}" ] || return 1
    echo "Cannot send dump request: Operation not permitted" >&2
    return 0
}

_ip_route_show() {  # <family> <table>
    local k f t n=0
    while IFS='|' read -r k f t; do
        if [ "$k" != "U" ] || [ "$f" != "$1" ] || [ "$t" != "$2" ]; then continue; fi
        n=$((n + 1))
        if [ "$1" = "-4" ]; then
            printf 'unreachable default \n'
        else
            printf 'unreachable default dev lo metric 1024 pref medium\n'
        fi
    done < "$IPSTATE"
    [ "$n" -gt 0 ] && return 0
    printf 'Error: ipv%s: FIB table does not exist.\nDump terminated\n' "${1#-}" >&2
    return 2
}

_ip_add_fails() {   # <invocation> — the IP_ADD_FAIL fault injection
    [ -n "$IP_ADD_FAIL" ] || return 1
    case "$1" in
        *"$IP_ADD_FAIL"*) echo "RTNETLINK answers: Operation not permitted" >&2; return 0 ;;
    esac
    return 1
}

_ip_has() { grep -qxF -e "$1" "$IPSTATE"; }     # <record> — is it in the model?

# <invocation> <record> — append the record unless it is already there (EEXIST, as the kernel
# refuses it). IP_ADD_RACE first inserts it on behalf of the concurrent winner.
_ip_add() {
    if [ -n "$IP_ADD_RACE" ]; then
        case "$1" in *"$IP_ADD_RACE"*) _ip_has "$2" || printf '%s\n' "$2" >> "$IPSTATE" ;; esac
    fi
    if _ip_has "$2"; then
        echo "RTNETLINK answers: File exists" >&2
        return 2
    fi
    printf '%s\n' "$2" >> "$IPSTATE"
}

ip() {
    printf '%s\n' "$*" >> "$T/ip-calls"
    printf 'ip %s\n' "$*" >> "$T/seq"
    case "$1" in
        -4|-6) ;;
        *) printf '%s\n' "$*" >> "$T/ip-unsupported"; return 1 ;;
    esac
    if [ "$1" = "-6" ] && [ ! -d "$KS_IPV6_PROC" ]; then
        echo "RTNETLINK answers: Address family not supported by protocol" >&2
        return 2
    fi
    case "$2 $3" in
        "rule list"|"route show"|"-br addr") _ip_read_fails "$*" && return 2 ;;
    esac
    case "$2 $3 $#" in
        "-br addr 3")
            if [ "$1" = "-4" ]; then
                printf '%-16s %-14s %s \n' lo UNKNOWN 127.0.0.1/8
                [ -n "$IP4_BR_ADDR" ] && printf '%s\n' "$IP4_BR_ADDR"
                return 0
            fi
            ;;
        "route show 4")
            if [ "$4" = "default" ]; then
                if [ "$1" = "-4" ]; then
                    [ -n "$IP4_DEFAULT" ] && printf '%s\n' "$IP4_DEFAULT"
                else
                    [ -n "$IP6_DEFAULT" ] && printf '%s\n' "$IP6_DEFAULT"
                fi
                return 0
            fi
            ;;
        "route show 5")
            if [ "$4" = "table" ]; then _ip_route_show "$1" "$5"; return $?; fi
            ;;
        "rule list 5")
            if [ "$4" = "priority" ]; then _ip_rule_list "$1" "$5"; return 0; fi
            ;;
        "rule add 9"|"rule del 9")
            if [ "$4 $6 $8" = "iif priority lookup" ]; then
                if [ "$3" = "del" ]; then _ip_del "R|$1|$7|$5|lookup $9"; return $?; fi
                _ip_add_fails "$*" && return 2
                _ip_add "$*" "R|$1|$7|$5|lookup $9"
                return $?
            fi
            # The source-rule swap's four forms, verbatim.
            if [ "$3 $4 $6 $7 $8 $9" = "add to lookup main priority 0" ]; then
                _ip_sadd "$*" "$1" all "$5"; return $?
            fi
            if [ "$3 $4 $6 $7 $8 $9" = "add from lookup main priority 0" ]; then
                _ip_sadd "$*" "$1" "$5" all; return $?
            fi
            if [ "$3 $4 $5 $6 $8 $9" = "del priority 0 to lookup main" ]; then
                _ip_sdel "$*" "$1" all "$7"; return $?
            fi
            if [ "$3 $4 $5 $6 $8 $9" = "del priority 0 from lookup main" ]; then
                _ip_sdel "$*" "$1" "$7" all; return $?
            fi
            ;;
        "route add 7"|"route del 7")
            if [ "$4 $5 $6" = "unreachable default table" ]; then
                if [ "$3" = "del" ]; then _ip_del "U|$1|$7"; return $?; fi
                _ip_add_fails "$*" && return 2
                _ip_add "$*" "U|$1|$7"
                return $?
            fi
            ;;
    esac
    printf '%s\n' "$*" >> "$T/ip-unsupported"
    return 1
}

# ubus, jsonfilter and tailscale record every invocation in $T/other-calls, so a pass that must make
# none of them (preboot) can be held to that. The engine never calls tailscale at all; that fake is
# a trap, and it fails.
#
# UBUS_DUMP holds fixture lines of "<l3_device> <interface>".
ubus() {
    printf 'ubus %s\n' "$*" >> "$T/other-calls"
    [ -n "$UBUS_DUMP" ] && printf '%s\n' "$UBUS_DUMP"
    return 0
}

tailscale() { printf 'tailscale %s\n' "$*" >> "$T/other-calls"; return 1; }

# Only the one expression the engine builds is understood: the device is pulled back out of
# @.interface[@.l3_device="<dev>"].interface and matched against the fixture lines on stdin. This
# asserts that the engine asks the right question and consumes the answer; it does not
# reimplement jsonfilter.
jsonfilter() {
    local expr="$2" dev d i
    printf 'jsonfilter %s\n' "$*" >> "$T/other-calls"
    dev="${expr#*l3_device=\"}"; dev="${dev%%\"*}"
    while read -r d i; do
        [ "$d" = "$dev" ] && printf '%s\n' "$i"
    done
    return 0
}

logger() { printf '%s\n' "$*" >> "$T/log"; }

# /bin/ipcalc.sh prints NETWORK= and PREFIX= lines for its one argument "<addr>/<prefix>" on all
# three lab targets (e.g. 192.168.161.1/23 -> NETWORK=192.168.160.0, PREFIX=23). The fake is a real
# executable, not a function: the engine runs "$KS_IPCALC" by path, and cases 17/17b hand the same
# path to a child engine. It answers from a lookup table of the fixture addresses, with the lines
# test-guest-net.sh's fake prints for them, and exits 1 for anything else — an address the table
# does not know, or any argument count but one. Every call is recorded as "<argc>:<args>" in
# $T/ipcalc/calls. $T/ipcalc/inject substitutes other output for ONE address: its first line names
# the address, and every later line is printed instead of the table's answer (rc 0).
mkdir -p "$T/ipcalc"
cat > "$T/ipcalc/ipcalc.sh" <<'EOF'
#!/bin/sh
d=${0%/*}
printf '%s:%s\n' "$#" "$*" >> "$d/calls"
[ "$#" = 1 ] || exit 1
if [ -f "$d/inject" ] && [ "$(head -n 1 "$d/inject")" = "$1" ]; then
    sed 1d "$d/inject"
    exit 0
fi
case "$1" in
    192.168.160.1/24) n=192.168.160.0 p=24 m=255.255.255.0 b=192.168.160.255 ;;
    192.168.161.1/23) n=192.168.160.0 p=23 m=255.255.254.0 b=192.168.161.255 ;;
    192.168.176.1/24) n=192.168.176.0 p=24 m=255.255.255.0 b=192.168.176.255 ;;
    192.168.150.1/24) n=192.168.150.0 p=24 m=255.255.255.0 b=192.168.150.255 ;;
    192.168.10.1/24)  n=192.168.10.0  p=24 m=255.255.255.0 b=192.168.10.255 ;;
    192.168.50.1/24)  n=192.168.50.0  p=24 m=255.255.255.0 b=192.168.50.255 ;;
    *) exit 1 ;;
esac
printf 'IP=%s\nNETMASK=%s\nBROADCAST=%s\nNETWORK=%s\nPREFIX=%s\n' "${1%/*}" "$m" "$b" "$n" "$p"
EOF
chmod +x "$T/ipcalc/ipcalc.sh"

# The swap marker is written as `mktemp "$KS_SWAP_MARK.XXXXXX"`, a printf into that file, then
# `mv -f` onto the marker. Both wrappers pass EVERY call through to the real command; the calls
# that name the marker — which the harness's own state-file moves never do — are also recorded in
# $T/mark-calls and $T/seq, so a pass that must not rewrite the marker can be held to that.
# MKTEMP_FAIL and MV_FAIL fail such a call and change nothing. MKTEMP_RET makes mktemp answer that
# path without creating anything, which gives the engine a temp file its write cannot open.
mktemp() {
    if [ -n "$KS_SWAP_MARK" ]; then
        case " $* " in
            *" $KS_SWAP_MARK."*)
                printf 'mktemp %s\n' "$*" >> "$T/mark-calls"
                printf 'mktemp %s\n' "$*" >> "$T/seq"
                [ -n "$MKTEMP_FAIL" ] && return 1
                if [ -n "$MKTEMP_RET" ]; then printf '%s\n' "$MKTEMP_RET"; return 0; fi
                ;;
        esac
    fi
    command mktemp "$@"
}
mv() {
    if [ -n "$KS_SWAP_MARK" ]; then
        case " $* " in
            *" $KS_SWAP_MARK "*|*" $KS_SWAP_MARK."*)
                printf 'mv %s\n' "$*" >> "$T/mark-calls"
                printf 'mv %s\n' "$*" >> "$T/seq"
                [ -n "$MV_FAIL" ] && return 1
                ;;
        esac
    fi
    command mv "$@"
}

# ------------------------------------------------------------------------------ load the engine
TS_FIX_KS_NO_MAIN=1
. "$SRC"
if ! command -v ks_main >/dev/null 2>&1; then
    echo "FAIL: $SRC did not define ks_main (dispatcher missing, or the TS_FIX_KS_NO_MAIN guard changed)"
    exit 1
fi
# /etc/init.d/firewall cannot be a shell function, so replace the engine's wrapper instead. Every
# attempt is recorded; FW_RELOAD_FAIL=1 makes it fail, as `/etc/init.d/firewall reload` returns the
# reload's own status.
_fw_reload() {
    printf 'reload\n' >> "$T/reloads"; printf 'reload\n' >> "$T/seq"
    [ "$FW_RELOAD_FAIL" != "1" ]
}
# Keep the engine's commit-failure flag, its serialization lock and its swap marker inside the case
# sandbox rather than on the real /tmp, and point it at the ipcalc fake. Cases 17 and 17b run the
# engine as a separate process, from a copy whose lock, marker and ipcalc lines point into $T too.
KS_COMMIT_FAIL="$T/commit-failed"
KS_RELOAD_FAIL="$T/reload-failed"
KS_INTENTWARN="$T/intentwarn"
KS_LOCK="$T/ks.lock"
KS_SCOPEWARN="$T/scopewarn"
KS_DEFROUTEWARN="$T/defroutewarn"
KS_SWAP_MARK="$T/ts-fix-ks.srcswap"
KS_IPCALC="$T/ipcalc/ipcalc.sh"
# GL's Tor script, which disarm only reads: absent unless a G case writes one there (tor_sh).
KS_TOR_SCRIPT="$T/tor.sh"
# preboot runs only when TS_FIX_KS_BOOT=1; the suite must not inherit that from its environment.
unset TS_FIX_KS_BOOT

# The engine reads, acts on or removes the marker only when _ks_swap_mark_ours says it may: a
# regular file, not a symlink, owned by the effective uid. A file owned by ANOTHER user cannot be
# made here without privilege, so MARK_FOREIGN=1 plays that case: the harness's _ks_swap_mark_ours
# then answers "not ours". Otherwise it runs the shipping predicate, copied out of the engine source
# under the name _ks_swap_mark_ours_real — so no case ever points the engine at a system file.
eval "$(sed -n '/^_ks_swap_mark_ours() {$/,/^}$/p' "$SRC" | sed '1s/^_ks_swap_mark_ours()/_ks_swap_mark_ours_real()/')"
_ks_swap_mark_ours() {
    [ -n "$MARK_FOREIGN" ] && return 1
    _ks_swap_mark_ours_real
}
# The engine's "does this kernel have an IPv6 stack" probe, pointed at a sandbox directory so the
# answer is the fixture's, never the laptop's. Present by default; case R17 takes it away.
KS_IPV6_PROC_PRESENT="$T/proc-sys-net-ipv6"
mkdir -p "$KS_IPV6_PROC_PRESENT"
KS_IPV6_PROC="$KS_IPV6_PROC_PRESENT"

# awk is a real external (the scope-hole scan is the engine's only use of it); wrap it so the
# quiet-poll cost claim can be counted rather than asserted by eye.
awk() { printf 'awk\n' >> "$T/ext-calls"; command awk "$@"; }

# ------------------------------------------------------------------------------------- fixtures
counters_reset() {
    : > "$T/commits"; : > "$T/reloads"; : > "$T/log"; : > "$T/ip-calls"; : > "$T/commit-attempts"
    : > "$T/uci-calls"; : > "$T/ext-calls"; : > "$T/seq"; : > "$T/other-calls"
    : > "$T/mark-calls"; : > "$T/ipcalc/calls"; : > "$T/ip-readfail-count"
}

reset() {   # $1 = fixture function
    counters_reset
    : > "$STATE"
    # The kernel side starts empty too: no policy rules, nothing in table 100, and no bridge with
    # an IPv4 address, so the swap has nothing to do unless a case gives it something.
    : > "$IPSTATE"
    # Clear the engine's per-invocation capture so no case can pass on a stale one.
    _ks_show=""; _ks_fwd=""
    # The swap marker goes, its temp files do not: one left behind by any case must still be there
    # for the end-of-run hygiene check to find.
    rm -f "$KS_COMMIT_FAIL" "$KS_SCOPEWARN" "$KS_DEFROUTEWARN" "$KS_SWAP_MARK" "$T/ipcalc/inject"
    rm -f "$KS_RELOAD_FAIL" "$KS_INTENTWARN"
    UCI_COMMIT_FAIL=""; UCI_SET_FAIL=""; UCI_ADDLIST_FAIL=""; UCI_READ_FAIL=""; FW_RELOAD_FAIL=""
    IP4_DEFAULT=""; IP6_DEFAULT=""; UBUS_DUMP=""; IP_ABSENT_DEVS=""; IP_ADD_FAIL=""; IP_ADD_RACE=""
    IP4_BR_ADDR=""; IP_READ_FAIL=""; IP_READ_FAIL_SKIP=""; IP_DEL_FAIL=""; IP_DEL_RACE=""
    MKTEMP_FAIL=""; MKTEMP_RET=""; MV_FAIL=""; MARK_FOREIGN=""
    KS_IPV6_PROC="$KS_IPV6_PROC_PRESENT"
    "$1"
}

g()   { _uci_get "$1" || true; }
sev() { _uci_get ts-fix.settings.ks_severed || true; }
commits() { cat "$T/commits"; }
reloads() { wc -l < "$T/reloads" | tr -d ' '; }
logtext() { cat "$T/log"; }
ipcalls() { cat "$T/ip-calls"; }
othercalls() { cat "$T/other-calls"; }
seed()    { printf '%s\n' "$@" >> "$IPSTATE"; }    # ip model records, verbatim
ipstate() { sort "$IPSTATE"; }
# The first / last line number in the shared sequence log that matches an ERE; empty when none does.
seqline() { grep -n -E -e "$1" "$T/seq" | head -n 1 | cut -d: -f1; }
seqlast() { grep -n -E -e "$1" "$T/seq" | tail -n 1 | cut -d: -f1; }

# ---- source-rule swap helpers
# One `ip -4 -br addr` line exactly as iproute2 lays it out: the name padded to 16 and the state to
# 14, each followed by one space, then every address followed by one space (so a trailing space).
br_line() { printf '%-16s %-14s ' "$1" "$2"; shift 2; printf '%s ' "$@"; printf '\n'; }
# addrs "<bridge> <addr>..." ... — the IP4_BR_ADDR fixture, one UP line per bridge (the 4.11 shape).
addrs() {
    local spec
    IP4_BR_ADDR=$(for spec; do br_line ${spec%% *} UP ${spec#* }; done)
}
gl_rule()  { printf 'S|-4|0|%s|all|lookup main\n' "$1"; }   # GL's "from <net> lookup main"
iif_rule() { printf 'S|-4|0|%s|all|lookup main|%s\n' "$1" "$2"; }   # "from <net> iif <dev> lookup main"
to_rule()  { printf 'S|-4|0|all|%s|lookup main\n' "$1"; }   # "to <net> lookup main": the swap's
                                                              # own, and GL's LAN/uplink rules
seed_gl_lan() { seed "$(to_rule 192.168.50.0/24)" "$(to_rule 192.168.200.0/24)"; }
prio0()    { grep '^S|' "$IPSTATE"; }                         # the priority-0 records, in order
marker()   { cat "$KS_SWAP_MARK" 2>/dev/null; }
markcalls() { cat "$T/mark-calls"; }
ipcalcs()  { cat "$T/ipcalc/calls"; }
swapcalls() { grep -e ' priority 0' -e '-br addr' "$T/ip-calls"; }   # the swap's ip calls, in order
# Temp files of the marker write left anywhere under $T (the engine copy of 17/17b included).
tmpleft()  { find "$T" -name 'ts-fix-ks.srcswap.*' | sed "s|^$T/||" | sort; }
inode()    { set -- $(ls -i "$1" 2>/dev/null); printf '%s\n' "$1"; }   # set -f is on (sourced engine)
ipcalc_inject() { printf '%s\n' "$@" > "$T/ipcalc/inject"; }    # <addr> <output line>...
# GL's own condition for its source rule, beyond Tailscale enabled in Router mode (fixture_mt3000,
# which every caller starts from, has both): an exit node set, and network.<zone>.disabled='0'.
gl_cond()  { uci set tailscale.settings.exit_node_ip=100.101.102.103; for z; do uci set "network.$z.disabled=0"; done; }
# preboot runs only with TS_FIX_KS_BOOT=1, which /etc/init.d/ts-fix-preboot's boot() passes. Assign,
# call, unset: `VAR=value function` is not a safe way to hand a variable to a function in ash/dash.
preboot_run() {
    TS_FIX_KS_BOOT=1
    ks_main preboot > "$T/out" 2>&1
    _pb_rc=$?
    unset TS_FIX_KS_BOOT
    return $_pb_rc
}

# The live MT3000 snapshot shape: GL mixes anonymous and named sections in one config, ships its
# own iot zone (created from ROM defaults since 4.9.0, and covered by the kill switch like guest),
# a VPN SERVER zone (awg, wgserver) and VPN CLIENT zones (awgclient, zerotier), and has no
# lan -> tailscale0 forwarding while "Allow Remote Access LAN" is off.
fixture_mt3000() {
    cat >> "$STATE" <<'EOF'
S|firewall.@zone[0]|zone
O|firewall.@zone[0].name|lan
O|firewall.@zone[0].network|lan
S|firewall.@zone[1]|zone
O|firewall.@zone[1].name|wan
O|firewall.@zone[1].network|wan wwan tethering wan6 wwan6 tethering6
S|firewall.@zone[2]|zone
O|firewall.@zone[2].name|guest
O|firewall.@zone[2].network|guest
S|firewall.awg|zone
O|firewall.awg.name|awg
O|firewall.awg.network|awg
S|firewall.awgclient|zone
O|firewall.awgclient.name|awgclient
O|firewall.awgclient.network|awgclient
S|firewall.zerotier|zone
O|firewall.zerotier.name|zerotier
O|firewall.zerotier.network|zerotier
S|firewall.iot|zone
O|firewall.iot.name|iot
O|firewall.iot.network|iot
S|firewall.wgserver|zone
O|firewall.wgserver.name|wgserver
O|firewall.wgserver.network|wgserver
S|firewall.tailscale0|zone
O|firewall.tailscale0.name|tailscale0
O|firewall.tailscale0.network|tailscale0
S|firewall.@forwarding[0]|forwarding
O|firewall.@forwarding[0].src|lan
O|firewall.@forwarding[0].dest|wan
O|firewall.@forwarding[0].enabled|1
S|firewall.lan_zerotier|forwarding
O|firewall.lan_zerotier.src|lan
O|firewall.lan_zerotier.dest|zerotier
S|firewall.@forwarding[7]|forwarding
O|firewall.@forwarding[7].src|guest
O|firewall.@forwarding[7].dest|awgclient
S|firewall.lan2wgserver|forwarding
O|firewall.lan2wgserver.src|lan
O|firewall.lan2wgserver.dest|wgserver
S|firewall.@forwarding[11]|forwarding
O|firewall.@forwarding[11].src|iot
O|firewall.@forwarding[11].dest|wan
S|firewall.@forwarding[14]|forwarding
O|firewall.@forwarding[14].src|guest
O|firewall.@forwarding[14].dest|wan
S|firewall.awgclient2wan|forwarding
O|firewall.awgclient2wan.src|awgclient
O|firewall.awgclient2wan.dest|wan
S|ts-fix.settings|settings
O|ts-fix.settings.kill_switch|1
O|ts-fix.settings.route_guest|0
S|tailscale.settings|settings
O|tailscale.settings.enabled|1
S|glconfig.general|general
O|glconfig.general.mode|router
EOF
}

# Same, plus GL's own enabled lan -> tailscale0 forwarding ("Allow Remote Access LAN" on).
fixture_mt3000_gl_lan_ts() {
    fixture_mt3000
    cat >> "$STATE" <<'EOF'
S|firewall.lan_ts|forwarding
O|firewall.lan_ts.src|lan
O|firewall.lan_ts.dest|tailscale0
EOF
}

# The other layout GL ships: a separate NAMED wan6 zone alongside the v4 wan zone.
fixture_wan6() {
    cat >> "$STATE" <<'EOF'
S|firewall.@zone[0]|zone
O|firewall.@zone[0].name|lan
O|firewall.@zone[0].network|lan
S|firewall.@zone[1]|zone
O|firewall.@zone[1].name|wan
O|firewall.@zone[1].network|wan wwan tethering
S|firewall.wan6|zone
O|firewall.wan6.name|wan6
O|firewall.wan6.family|ipv6
O|firewall.wan6.network|wan6 usbwan6 modem_cpu_6 secondwan6
S|firewall.tailscale0|zone
O|firewall.tailscale0.name|tailscale0
O|firewall.tailscale0.network|tailscale0
S|firewall.@forwarding[0]|forwarding
O|firewall.@forwarding[0].src|lan
O|firewall.@forwarding[0].dest|wan
O|firewall.@forwarding[0].enabled|1
S|firewall.lan_ts|forwarding
O|firewall.lan_ts.src|lan
O|firewall.lan_ts.dest|tailscale0
S|ts-fix.settings|settings
O|ts-fix.settings.kill_switch|1
S|tailscale.settings|settings
O|tailscale.settings.enabled|1
S|glconfig.general|general
O|glconfig.general.mode|router
EOF
}

# Already armed, plus an uplink zone the seed vocabulary does NOT recognise (networks "usb0"),
# reachable from lan through an enabled forwarding — only the runtime invariant can catch it.
fixture_unseeded_uplink() {
    cat >> "$STATE" <<'EOF'
S|firewall.@zone[0]|zone
O|firewall.@zone[0].name|lan
O|firewall.@zone[0].network|lan
S|firewall.@zone[1]|zone
O|firewall.@zone[1].name|wan
O|firewall.@zone[1].network|wan
S|firewall.usbzone|zone
O|firewall.usbzone.name|usbzone
O|firewall.usbzone.network|usb0
S|firewall.tailscale0|zone
O|firewall.tailscale0.name|tailscale0
O|firewall.tailscale0.network|tailscale0
S|firewall.@forwarding[0]|forwarding
O|firewall.@forwarding[0].src|lan
O|firewall.@forwarding[0].dest|wan
O|firewall.@forwarding[0].enabled|0
S|firewall.lan_usb|forwarding
O|firewall.lan_usb.src|lan
O|firewall.lan_usb.dest|usbzone
O|firewall.lan_usb.enabled|1
S|firewall.lan_ts|forwarding
O|firewall.lan_ts.src|lan
O|firewall.lan_ts.dest|tailscale0
S|ts-fix.settings|settings
O|ts-fix.settings.kill_switch|1
O|ts-fix.settings.ks_severed|lan:wan
S|tailscale.settings|settings
O|tailscale.settings.enabled|1
S|glconfig.general|general
O|glconfig.general.mode|router
EOF
}

# Armed intent, but the firewall config yields nothing at all — corrupt, truncated, or uci itself
# unavailable. A GL router running Tailscale always has forwardings, so this is never a real
# "nothing to do".
fixture_no_firewall() {
    cat >> "$STATE" <<'EOF'
S|ts-fix.settings|settings
O|ts-fix.settings.kill_switch|1
S|tailscale.settings|settings
O|tailscale.settings.enabled|1
S|glconfig.general|general
O|glconfig.general.mode|router
EOF
}

# The 4.8.4 shape: no iot network (GL adds one from 4.9.0), so no iot zone and no iot forwarding
# at all. GL's own lan -> tailscale0 forwarding is present and every other forwarding carries an
# explicit enabled='1', so an arm/disarm round trip can be compared byte for byte.
fixture_484() {
    cat >> "$STATE" <<'EOF'
S|firewall.@zone[0]|zone
O|firewall.@zone[0].name|lan
O|firewall.@zone[0].network|lan
S|firewall.@zone[1]|zone
O|firewall.@zone[1].name|wan
O|firewall.@zone[1].network|wan wan6
S|firewall.@zone[2]|zone
O|firewall.@zone[2].name|guest
O|firewall.@zone[2].network|guest
S|firewall.tailscale0|zone
O|firewall.tailscale0.name|tailscale0
O|firewall.tailscale0.network|tailscale0
S|firewall.@forwarding[0]|forwarding
O|firewall.@forwarding[0].src|lan
O|firewall.@forwarding[0].dest|wan
O|firewall.@forwarding[0].enabled|1
S|firewall.@forwarding[1]|forwarding
O|firewall.@forwarding[1].src|guest
O|firewall.@forwarding[1].dest|wan
O|firewall.@forwarding[1].enabled|1
S|firewall.lan_ts|forwarding
O|firewall.lan_ts.src|lan
O|firewall.lan_ts.dest|tailscale0
S|ts-fix.settings|settings
O|ts-fix.settings.kill_switch|1
S|tailscale.settings|settings
O|tailscale.settings.enabled|1
S|glconfig.general|general
O|glconfig.general.mode|router
EOF
}

# The flash state the first boot after a keep-settings firmware upgrade hands to preboot: the
# router was armed before the upgrade, then GL's ROM uci-default 99-vpn-client set the recorded
# lan -> wan and guest -> wan forwardings back to enabled='1' at boot step 10. No policy rule exists
# yet (netifd has not started). $T/armed keeps the armed config for comparison. Run it after
# `reset fixture_mt3000`.
first_boot_state() {
    ks_main arm > "$T/out" 2>&1
    cp "$STATE" "$T/armed"
    uci set 'firewall.@forwarding[0].enabled=1'
    uci set 'firewall.@forwarding[14].enabled=1'
    : > "$IPSTATE"
}

# The exact removal call list against an EMPTY model, where every delete misses on its first attempt
# (a delete that hits is retried until it misses, so a populated model issues more calls than this).
rules_clean_expect() {
    cat <<'EOF'
-4 rule del iif br-lan priority 5279 lookup 100
-4 rule del iif br-guest priority 5279 lookup 100
-4 rule del iif br-iot priority 5279 lookup 100
-4 rule del iif br-lan priority 5280 lookup 100
-4 rule del iif br-guest priority 5280 lookup 100
-4 rule del iif br-iot priority 5280 lookup 100
-4 route del unreachable default table 100
-6 rule del iif br-lan priority 5279 lookup 100
-6 rule del iif br-guest priority 5279 lookup 100
-6 rule del iif br-iot priority 5279 lookup 100
-6 rule del iif br-lan priority 5280 lookup 100
-6 rule del iif br-guest priority 5280 lookup 100
-6 rule del iif br-iot priority 5280 lookup 100
-6 route del unreachable default table 100
EOF
}

# The complete rule layer as model records; layer_state is the same set as ipstate prints it.
layer_records() {
    cat <<'EOF'
R|-4|5279|br-lan|lookup 100
R|-4|5279|br-guest|lookup 100
R|-4|5279|br-iot|lookup 100
U|-4|100
R|-6|5279|br-lan|lookup 100
R|-6|5279|br-guest|lookup 100
R|-6|5279|br-iot|lookup 100
U|-6|100
EOF
}
layer_state() { layer_records | sort; }
seed_layer()  { layer_records >> "$IPSTATE"; }

# The exact ensure call list against an empty model: per family one rule list, an add per bridge,
# one route show, the route add; then the source-rule swap's two reads, which find no bridge with
# an address (the default fixture) and so change nothing.
ensure_expect_empty() {
    cat <<'EOF'
-4 rule list priority 5279
-4 rule add iif br-lan priority 5279 lookup 100
-4 rule add iif br-guest priority 5279 lookup 100
-4 rule add iif br-iot priority 5279 lookup 100
-4 route show table 100
-4 route add unreachable default table 100
-6 rule list priority 5279
-6 rule add iif br-lan priority 5279 lookup 100
-6 rule add iif br-guest priority 5279 lookup 100
-6 rule add iif br-iot priority 5279 lookup 100
-6 route show table 100
-6 route add unreachable default table 100
-4 -br addr
-4 rule list priority 0
EOF
}

# ... and against a complete layer: the six reads and nothing else (the watchdog-poll budget).
ensure_expect_present() {
    cat <<'EOF'
-4 rule list priority 5279
-4 route show table 100
-6 rule list priority 5279
-6 route show table 100
-4 -br addr
-4 rule list priority 0
EOF
}

# =============================================================================================
echo "--- case 0: instrument lint (the fakes behave like uci before any engine case is trusted)"
reset fixture_mt3000
is "0 get missing key is empty"        ""     "$(g firewall.nope.nothing)"
uci -q get firewall.nope.nothing >/dev/null 2>&1; is "0 get missing key rc 1" 1 "$?"
is "0 get section prints its type"     forwarding "$(g firewall.lan_zerotier)"
is "0 get list is space-joined"        "wan wwan tethering wan6 wwan6 tethering6" "$(g 'firewall.@zone[1].network')"
uci set firewall.lan_zerotier.enabled=0
is "0 set writes"                      0      "$(g firewall.lan_zerotier.enabled)"
uci set firewall.lan_zerotier.enabled=''
is "0 empty set acts as a delete"      ""     "$(g firewall.lan_zerotier.enabled)"
uci add_list ts-fix.settings.ks_severed=a:b
uci add_list ts-fix.settings.ks_severed=c:d
is "0 add_list joins with a space"     "a:b c:d" "$(sev)"
uci -q delete ts-fix.settings.ks_severed
is "0 delete removes"                  ""     "$(sev)"
has "0 show prints section lines unquoted" "firewall.@forwarding[0]=forwarding" "$(uci show firewall)"
has "0 show quotes option values"          "firewall.@forwarding[0].src='lan'"  "$(uci show firewall)"
hasnt "0 show is package-scoped"           "ts-fix.settings"                    "$(uci show firewall)"
uci set firewall.zap=forwarding
uci set firewall.zap.src=lan
uci -q delete firewall.zap
is "0 section delete removes its options" "" "$(g firewall.zap.src)"
# The section form of show, which the engine's intent reads use, against the device format
# (2026-10-04, GL 4.8.4/4.9.0/4.11.0): the section line first, then each option single-quoted; a
# missing section or package is rc 1 with nothing printed.
is "0 show of a section: its line, then its options, quoted" "ts-fix.settings=settings
ts-fix.settings.kill_switch='1'
ts-fix.settings.route_guest='0'" "$(uci -q show ts-fix.settings)"
is "0 ... and tailscale.settings the same way" "tailscale.settings=settings
tailscale.settings.enabled='1'" "$(uci -q show tailscale.settings)"
uci -q show ts-fix.settings >/dev/null; is "0 ... rc 0" 0 "$?"
x=$(uci -q show ts-fix.nosuch); rc=$?
is "0 show of a missing section: nothing, rc 1" ":1" "$x:$rc"
x=$(uci -q show nosuch.settings); rc=$?
is "0 show of a section in a missing package: nothing, rc 1" ":1" "$x:$rc"
x=$(uci -q show nosuch); rc=$?
is "0 show of a missing package: nothing, rc 1" ":1" "$x:$rc"
hasnt "0 the section form is section-scoped (no other section's options)" "firewall" "$(uci -q show ts-fix.settings)"
UCI_READ_FAIL="tailscale"
x=$(uci -q show tailscale.settings); r1=$?
y=$(uci -q get tailscale.settings.enabled); r2=$?
z=$(uci -q show ts-fix.settings | head -n 1); r3=$?
UCI_READ_FAIL=""
is "0 UCI_READ_FAIL fails a show and a get of that package (nothing, rc 1), and only that package" \
    ":1 :1 ts-fix.settings=settings:0" "$x:$r1 $y:$r2 $z:$r3"
UCI_READ_FAIL="ts-fix tailscale"
x="$(uci -q show ts-fix.settings; echo "rc $?")|$(uci -q show tailscale.settings; echo "rc $?")|$(g glconfig.general.mode)"
UCI_READ_FAIL=""
is "0 ... several packages, space separated; a third still reads" "rc 1|rc 1|router" "$x"
is "0 ... and nothing else changed: a later read works" "1" "$(g tailscale.settings.enabled)"

echo "--- case 0b: instrument lint for the ip fake (format, detached variant, single-entry delete)"
# Every expected string here was read from real iproute2 (see the fake's header comment).
reset fixture_mt3000
tab=$(printf '\t')
is "0b empty list prints nothing"      "" "$(ip -4 rule list priority 5279)"
ip -4 rule add iif br-lan priority 5279 lookup 100
is "0b list: a TAB after the colon"    "5279:${tab}from all iif br-lan lookup 100" "$(ip -4 rule list priority 5279)"
IP_ABSENT_DEVS="br-lan"
is "0b a missing device lists [detached]" "5279:${tab}from all iif br-lan [detached] lookup 100" "$(ip -4 rule list priority 5279)"
IP_ABSENT_DEVS=""
is "0b list is family-scoped"          "" "$(ip -6 rule list priority 5279)"
is "0b list is priority-scoped"        "" "$(ip -4 rule list priority 5280)"
ip -4 rule add iif br-lan priority 5279 lookup 100 2>"$T/err"; rc=$?
is "0b an identical add is refused: rc 2" 2 "$rc"
is "0b ... with the kernel's EEXIST text" "RTNETLINK answers: File exists" "$(cat "$T/err")"
is "0b ... and nothing is appended"    1 "$(ip -4 rule list priority 5279 | grep -c .)"
seed 'R|-4|5279|br-lan|lookup 100'      # a twin, as a kernel that accepts identical rules could hold
ip -4 rule del iif br-lan priority 5279 lookup 100; rc=$?
is "0b del hits: rc 0"                 0 "$rc"
is "0b del removes exactly ONE entry"  1 "$(ip -4 rule list priority 5279 | grep -c .)"
ip -4 rule del iif br-lan priority 5279 lookup 100
ip -4 rule del iif br-lan priority 5279 lookup 100; rc=$?
is "0b del misses: rc 1"               1 "$rc"
IP_ADD_RACE="-4 rule add iif br-guest"
ip -4 rule add iif br-guest priority 5279 lookup 100 2>"$T/err"; rc=$?
IP_ADD_RACE=""
is "0b race: the engine's own add is refused with EEXIST" "2 RTNETLINK answers: File exists" "$rc $(cat "$T/err")"
is "0b race: the winner's rule is there, exactly once" 1 "$(grep -cxF -e 'R|-4|5279|br-guest|lookup 100' "$IPSTATE")"
ip -4 rule del iif br-guest priority 5279 lookup 100
KS_IPV6_PROC="$T/no-ipv6-stack"
ip -6 rule list priority 5279 >/dev/null 2>&1; r1=$?
ip -4 rule list priority 5279 >/dev/null 2>&1; r2=$?
KS_IPV6_PROC="$KS_IPV6_PROC_PRESENT"
is "0b no IPv6 stack: a -6 call fails, a -4 call does not" "2 0" "$r1 $r2"
seed 'R|-4|5280|br-lan|blackhole' 'R|-4|5279|br-lan|lookup 1002'
is "0b a blackhole rule prints as iproute2 does" "5280:${tab}from all iif br-lan blackhole" "$(ip -4 rule list priority 5280)"
ip -4 rule del iif br-lan priority 5280 lookup 100; r1=$?
ip -4 rule del iif br-lan priority 5279 lookup 100; r2=$?
is "0b lookup 100 matches neither a blackhole nor lookup 1002" "1 1" "$r1 $r2"
is "0b ... both still there"           2 "$(grep -c . "$IPSTATE")"
is "0b empty table: nothing on stdout" "" "$(ip -4 route show table 100 2>/dev/null)"
ip -4 route show table 100 >/dev/null 2>&1; is "0b empty table: rc 2" 2 "$?"
ip -4 route add unreachable default table 100
ip -6 route add unreachable default table 100
ip -6 route add unreachable default table 100 2>/dev/null; rc=$?
is "0b an identical route add is refused: rc 2" 2 "$rc"
is "0b v4 route line, trailing space included" "unreachable default " "$(ip -4 route show table 100)"
is "0b v6 route line, and only one" "unreachable default dev lo metric 1024 pref medium" "$(ip -6 route show table 100)"
ip -4 route del unreachable default table 100; r1=$?
ip -4 route del unreachable default table 100; r2=$?
is "0b route del hits once, then misses" "0 1" "$r1 $r2"
IP_ADD_FAIL="-6 rule add"
ip -6 rule add iif br-guest priority 5279 lookup 100 2>/dev/null; rc=$?
IP_ADD_FAIL=""
is "0b fault injection fails the add"  2 "$rc"
is "0b ... and changes nothing"        "" "$(ip -6 rule list priority 5279)"
ip link show >/dev/null 2>&1; rc=$?
is "0b an unmodelled invocation fails" 1 "$rc"
is "0b ... and is recorded"            "link show" "$(cat "$T/ip-unsupported")"
: > "$T/ip-unsupported"     # that one was deliberate
# 31 invocations above, several of them inside command substitutions and pipelines (subshells):
# the record must not lose any of them.
is "0b every call recorded in ip-calls" 31 "$(grep -c . "$T/ip-calls")"

echo "--- case 0c: instrument lint — every faked name resolves to its fake, and every recorder records"
# BusyBox ash runs some applets (ip, logger and sh among them) as its own built-ins. A fake that lost
# to one would let the real command run and turn every "zero calls" assertion into a vacuous pass,
# so each faked name must resolve to a shell function in the shell running this suite — "is a shell
# function" in dash, "is a function" in BusyBox ash — and a real external must not (the lint's own
# check in the other direction). _fw_reload is the engine's wrapper, replaced after sourcing.
for n in uci ip ubus jsonfilter tailscale logger awk _fw_reload mktemp mv; do
    case "$(type "$n" 2>&1)" in
        *function*) ok "0c $n resolves to the fake" ;;
        *)          nok "0c $n resolves to the fake" "a shell function" "$(type "$n" 2>&1)" ;;
    esac
done
case "$(type sed 2>&1)" in
    *function*) nok "0c the lint discriminates: sed is not a function" "not a function" "$(type sed 2>&1)" ;;
    *)          ok "0c the lint discriminates: sed is not a function" ;;
esac
counters_reset
_fw_reload
ubus call network.interface dump > /dev/null
jsonfilter -e '@.x' < /dev/null > /dev/null
tailscale status > /dev/null
printf 'x\n' | awk '{ print }' > /dev/null
is "0c the reload fake counts"         1 "$(reloads)"
_fw_reload; r1=$?
FW_RELOAD_FAIL=1
_fw_reload; r2=$?
FW_RELOAD_FAIL=""
is "0c the reload fake: rc 0, and rc 1 under FW_RELOAD_FAIL=1, each attempt counted" "0 1 3" "$r1 $r2 $(reloads)"
is "0c ubus, jsonfilter and tailscale are recorded" "ubus call network.interface dump
jsonfilter -e @.x
tailscale status" "$(othercalls)"
is "0c awk is recorded"                1 "$(grep -c . "$T/ext-calls")"
counters_reset

echo "--- case 0d: instrument lint for the swap's half of the ip fake (priority 0, brief addresses)"
# Every expected string here was read from real iproute2 6.1.0 in a scratch network namespace
# (u3-runs/netns-probe*.out; with these addresses, fw1-runs/r3-evidence/netns/; see the fake's
# header comment).
reset fixture_mt3000
is "0d a pristine priority 0 lists the kernel's local rule" "0:${tab}from all lookup local" "$(ip -4 rule list priority 0)"
is "0d ... in both families"           "0:${tab}from all lookup local" "$(ip -6 rule list priority 0)"
is "0d ... and at no other priority"   "" "$(ip -4 rule list priority 5279)"
seed_gl_lan
seed "$(gl_rule 192.168.160.0/23)"
ip -4 rule add to 192.168.160.0/23 lookup main priority 0; rc=$?
is "0d the swap's add: rc 0"           0 "$rc"
is "0d list format, local first, then insertion order" "0:${tab}from all lookup local
0:${tab}from all to 192.168.50.0/24 lookup main
0:${tab}from all to 192.168.200.0/24 lookup main
0:${tab}from 192.168.160.0/23 lookup main
0:${tab}from all to 192.168.160.0/23 lookup main" "$(ip -4 rule list priority 0)"
ip -4 rule add to 192.168.160.0/23 lookup main priority 0 2>"$T/err"; rc=$?
is "0d an identical add is refused with EEXIST" "2 RTNETLINK answers: File exists" "$rc $(cat "$T/err")"
ip -4 rule add from 192.168.160.0/23 lookup main priority 0 2>"$T/err"; rc=$?
is "0d GL's un-prioritised rule IS the priority-0 re-add (EEXIST)" "2 RTNETLINK answers: File exists" "$rc $(cat "$T/err")"
ip -4 rule del priority 0 to 192.168.160.0/23 lookup main; rc=$?
is "0d the to-delete hits: rc 0"       0 "$rc"
is "0d ... and takes only the to-rule: GL's from-rule and the LAN rules stay" "$(to_rule 192.168.50.0/24)
$(to_rule 192.168.200.0/24)
$(gl_rule 192.168.160.0/23)" "$(prio0)"
ip -4 rule del priority 0 to 192.168.160.0/23 lookup main 2>"$T/err"; rc=$?
is "0d a delete that finds nothing: rc 2 and ENOENT" "2 RTNETLINK answers: No such file or directory" "$rc $(cat "$T/err")"
ip -4 rule add to 192.168.160.0/23 lookup main priority 0
ip -4 rule del priority 0 from 192.168.160.0/23 lookup main; rc=$?
is "0d the from-delete hits: rc 0"     0 "$rc"
is "0d ... and takes only GL's from-rule" "$(to_rule 192.168.50.0/24)
$(to_rule 192.168.200.0/24)
$(to_rule 192.168.160.0/23)" "$(prio0)"
ip -4 rule del priority 0 from 192.168.160.0/23 lookup main 2>/dev/null; rc=$?
is "0d ... and misses once it is gone" 2 "$rc"
ip -4 rule add from 192.168.160.0/23 lookup main priority 0
is "0d a re-added GL rule lists last" "0:${tab}from 192.168.160.0/23 lookup main" "$(ip -4 rule list priority 0 | tail -n 1)"
echo "  0d-w: the kernel compares only the selectors a request gives — both directions"
reset fixture_mt3000
seed 'S|-4|0|192.168.160.0/24|10.0.0.0/8|lookup main' "$(gl_rule 10.20.0.0/16)"
is "0d-w a from+to rule lists as iproute2 prints it" "0:${tab}from 192.168.160.0/24 to 10.0.0.0/8 lookup main" "$(ip -4 rule list priority 0 | sed -n 2p)"
ip -4 rule add from 192.168.160.0/24 lookup main priority 0 2>/dev/null; rc=$?
is "0d-w adding 'from X' collides with 'from X to Y' (EEXIST)" 2 "$rc"
ip -4 rule del priority 0 from 192.168.160.0/24 lookup main; rc=$?
is "0d-w deleting 'from X' takes 'from X to Y'" "0 $(gl_rule 10.20.0.0/16)" "$rc $(prio0)"
ip -4 rule del priority 0 from 192.168.176.0/24 lookup main 2>/dev/null; rc=$?
is "0d-w ... but never a rule for another network" "2 $(gl_rule 10.20.0.0/16)" "$rc $(prio0)"
ip -4 rule add to 10.20.0.0/16 lookup main priority 0; rc=$?
is "0d-w 'to X' does not collide with 'from X'" "0 $(gl_rule 10.20.0.0/16)
$(to_rule 10.20.0.0/16)" "$rc $(prio0)"
echo "  0d-iif: a foreign rule with an input device, listed before GL's (the kernel's first-match delete)"
reset fixture_mt3000
seed "$(iif_rule 192.168.160.0/24 lo)" "$(gl_rule 192.168.160.0/24)"
is "0d-iif it lists as iproute2 prints it, ahead of GL's" "0:${tab}from all lookup local
0:${tab}from 192.168.160.0/24 iif lo lookup main
0:${tab}from 192.168.160.0/24 lookup main" "$(ip -4 rule list priority 0)"
ip -4 rule del priority 0 from 192.168.160.0/24 lookup main; rc=$?
is "0d-iif a delete giving no iif takes the FIRST match, the foreign rule (device fact, 2026-10-04)" \
    "0 $(gl_rule 192.168.160.0/24)" "$rc $(prio0)"
ip -4 rule del priority 0 from 192.168.160.0/24 lookup main; rc=$?
is "0d-iif ... the next delete takes GL's" "0 " "$rc $(prio0)"
reset fixture_mt3000
seed "$(gl_rule 192.168.160.0/24)" "$(iif_rule 192.168.160.0/24 lo)"
ip -4 rule del priority 0 from 192.168.160.0/24 lookup main
is "0d-iif listed the other way round, GL's goes first" "$(iif_rule 192.168.160.0/24 lo)" "$(prio0)"
ip -4 rule add from 192.168.160.0/24 lookup main priority 0 2>/dev/null
is "0d-iif an add meeting an iif rule is not modelled: it is recorded as unsupported" \
    "add meeting an iif rule: $(iif_rule 192.168.160.0/24 lo)" "$(cat "$T/ip-unsupported")"
: > "$T/ip-unsupported"     # that one was deliberate
echo "  0d-a: the brief address listing"
reset fixture_mt3000
lo_line='lo               UNKNOWN        127.0.0.1/8 '
is "0d no fixture: lo alone, in iproute2's layout (trailing space)" "$lo_line" "$(ip -4 -br addr)"
is "0d br_line reproduces a line iproute2 printed, byte for byte" \
    "br-guest         UNKNOWN        192.168.161.1/23 10.99.0.1/16 " \
    "$(br_line br-guest UNKNOWN 192.168.161.1/23 10.99.0.1/16)"
addrs "br-lan 192.168.50.1/24" "br-guest 192.168.150.1/24"
# printf, so no expected line ends in whitespace an editor could strip from the source.
is "0d the fixture follows lo, one UP line per bridge" "$(printf '%s\n%s\n%s' "$lo_line" \
    'br-lan           UP             192.168.50.1/24 ' 'br-guest         UP             192.168.150.1/24 ')" \
    "$(ip -4 -br addr)"
ip -6 -br addr >/dev/null 2>&1; rc=$?
is "0d -6 -br addr is not modelled (the engine never asks)" 1 "$rc"
: > "$T/ip-unsupported"     # that one was deliberate
echo "  0d-i: the new injections, both directions"
reset fixture_mt3000
IP_READ_FAIL="-4 rule list priority 0"
ip -4 rule list priority 0 >/dev/null 2>"$T/err"; r1=$?
ip -4 rule list priority 5279 >/dev/null 2>&1; r2=$?
is "0d IP_READ_FAIL fails a matching read, and only that" "2 0" "$r1 $r2"
has "0d ... with an error on stderr"   "Cannot send dump request" "$(cat "$T/err")"
: > "$T/ip-readfail-count"
IP_READ_FAIL_SKIP=2
r=""
for i in 1 2 3; do ip -4 rule list priority 0 >/dev/null 2>&1; r="$r$?"; done
is "0d IP_READ_FAIL_SKIP lets that many matching reads through first" "002" "$r"
IP_READ_FAIL="-br addr"; IP_READ_FAIL_SKIP=""
x=$(ip -4 -br addr 2>/dev/null); rc=$?
is "0d ... and fails the brief address listing too" "2:" "$rc:$x"
IP_READ_FAIL=""
seed "$(gl_rule 192.168.160.0/24)"
IP_DEL_RACE="-4 rule del priority 0 from 192.168.160.0/24"
ip -4 rule del priority 0 from 192.168.160.0/24 lookup main 2>"$T/err"; rc=$?
IP_DEL_RACE=""
is "0d IP_DEL_RACE: the winner deleted it, so ours finds nothing" "2 RTNETLINK answers: No such file or directory" "$rc $(cat "$T/err")"
is "0d ... and it is gone"             "" "$(prio0)"
seed "$(gl_rule 192.168.160.0/24)"
IP_DEL_FAIL="-4 rule del priority 0 from"
ip -4 rule del priority 0 from 192.168.160.0/24 lookup main 2>/dev/null; rc=$?
IP_DEL_FAIL=""
is "0d IP_DEL_FAIL fails the delete and changes nothing" "2 $(gl_rule 192.168.160.0/24)" "$rc $(prio0)"
IP_ADD_RACE="-4 rule add to 192.168.160.0/24"
ip -4 rule add to 192.168.160.0/24 lookup main priority 0 2>"$T/err"; rc=$?
IP_ADD_RACE=""
is "0d IP_ADD_RACE on a swap add: EEXIST" "2 RTNETLINK answers: File exists" "$rc $(cat "$T/err")"
is "0d ... the winner's rule is there, exactly once" 1 "$(grep -cxF -e "$(to_rule 192.168.160.0/24)" "$IPSTATE")"
IP_ADD_FAIL="-4 rule add to 192.168.176.0/24"
ip -4 rule add to 192.168.176.0/24 lookup main priority 0 2>/dev/null; rc=$?
IP_ADD_FAIL=""
is "0d IP_ADD_FAIL fails a swap add and adds nothing" "2 0" "$rc $(grep -cF '192.168.176.0/24' "$IPSTATE")"
ip -4 rule del from 192.168.160.0/24 lookup main 2>/dev/null; rc=$?
is "0d a delete without 'priority 0' is not modelled" 1 "$rc"
: > "$T/ip-unsupported"     # that one was deliberate

echo "--- case 0e: instrument lint for the ipcalc, mktemp and mv fakes"
reset fixture_mt3000
if [ -x "$KS_IPCALC" ]; then x=yes; else x=no; fi
is "0e the ipcalc fake is an executable at KS_IPCALC" yes "$x"
is "0e a /23 address: NETWORK=192.168.160.0, PREFIX=23" "IP=192.168.161.1
NETMASK=255.255.254.0
BROADCAST=192.168.161.255
NETWORK=192.168.160.0
PREFIX=23" "$("$KS_IPCALC" 192.168.161.1/23)"
"$KS_IPCALC" 192.168.99.1/24 > "$T/err" 2>&1; rc=$?
is "0e an address the table does not know: rc 1, no output" "1:" "$rc:$(cat "$T/err")"
"$KS_IPCALC" 192.168.160.1 24 > /dev/null 2>&1; rc=$?
is "0e two arguments: rc 1"            1 "$rc"
is "0e every call recorded as argc:args" "1:192.168.161.1/23
1:192.168.99.1/24
2:192.168.160.1 24" "$(ipcalcs)"
ipcalc_inject 192.168.160.1/24 NETWORK=0.0.0.0 PREFIX=0
is "0e an injection answers for its address" "NETWORK=0.0.0.0
PREFIX=0" "$("$KS_IPCALC" 192.168.160.1/24)"
is "0e ... and for no other"           "NETWORK=192.168.10.0" "$("$KS_IPCALC" 192.168.10.1/24 | grep NETWORK)"
rm -f "$T/ipcalc/inject"
is "0e ... until it is removed"        "NETWORK=192.168.160.0" "$("$KS_IPCALC" 192.168.160.1/24 | grep NETWORK)"
is "0e the LAN's fixture address, which the undo's guard derives" "NETWORK=192.168.50.0
PREFIX=24" "$("$KS_IPCALC" 192.168.50.1/24 | grep -e '^NETWORK=' -e '^PREFIX=')"
counters_reset
tmp=$(mktemp "$KS_SWAP_MARK.XXXXXX"); rc=$?
if [ "$rc" = "0" ] && [ -f "$tmp" ]; then ok "0e mktemp on the marker template creates the file"
else nok "0e mktemp on the marker template creates the file" "rc 0 and a file" "rc $rc [$tmp]"; fi
is "0e ... mode 0600"                  "-rw-------" "$(ls -l "$tmp" | cut -c1-10)"
mv -f "$tmp" "$KS_SWAP_MARK"; rc=$?
if [ "$rc" = "0" ] && [ -f "$KS_SWAP_MARK" ] && [ ! -e "$tmp" ]; then ok "0e mv onto the marker moves it"
else nok "0e mv onto the marker moves it" "rc 0, marker present, temp gone" "rc $rc"; fi
is "0e both marker calls are recorded" "mktemp $KS_SWAP_MARK.XXXXXX
mv -f $tmp $KS_SWAP_MARK" "$(markcalls)"
counters_reset
uci set firewall.lan_zerotier.enabled=0            # the uci fake moves its own state file
x=$(mktemp "$T/other.XXXXXX"); rm -f "$x"
is "0e calls that do not name the marker pass through unrecorded" "" "$(markcalls)"
MKTEMP_FAIL=1
x=$(mktemp "$KS_SWAP_MARK.XXXXXX"); rc=$?
MKTEMP_FAIL=""
is "0e MKTEMP_FAIL fails it and creates nothing" "1::" "$rc:$x:$(tmpleft)"
MKTEMP_RET="$T/no-such-dir/x"
x=$(mktemp "$KS_SWAP_MARK.XXXXXX"); rc=$?
MKTEMP_RET=""
is "0e MKTEMP_RET answers that path and creates nothing" "0:$T/no-such-dir/x:" "$rc:$x:$(tmpleft)"
printf 'moved\n' > "$T/mv-src"
MV_FAIL=1
mv -f "$T/mv-src" "$KS_SWAP_MARK"; rc=$?
MV_FAIL=""
if [ "$rc" = "1" ] && [ -f "$T/mv-src" ] && [ ! -s "$KS_SWAP_MARK" ]; then ok "0e MV_FAIL fails it and changes nothing"
else nok "0e MV_FAIL fails it and changes nothing" "rc 1, source kept, marker still empty" "rc $rc"; fi
rm -f "$T/mv-src" "$KS_SWAP_MARK"

echo "--- case 0f: instrument lint — the root guard, and the marker-trust predicate the SM cases drive"
# The guard block at the top of this file, run on its own under the pinned /bin/sh with a fake `id`
# first in PATH, in both directions. BusyBox ash may run `id` as its own applet, which is why the
# shell is pinned (see case 17).
mkdir -p "$T/fakeid"
printf '#!/bin/sh\necho "$FAKE_UID"\n' > "$T/fakeid/id"
chmod +x "$T/fakeid/id"
command awk '/^# ---8<--- root-guard$/,/^# ---8<--- end root-guard$/' "$0" > "$T/root-guard.sh"
has "0f the guard block was extracted" 'if [ "$(id -u)" = "0" ]; then' "$(cat "$T/root-guard.sh")"
is "0f the pinned shell resolves id to the fake" "$T/fakeid/id" "$(PATH="$T/fakeid:$PATH" /bin/sh -c 'command -v id')"
out=$(FAKE_UID=0 PATH="$T/fakeid:$PATH" /bin/sh "$T/root-guard.sh" 2>&1); rc=$?
is "0f uid 0: the suite stops, rc 1, and says why" "1 FAIL: this suite must not run as root (uid 0)" "$rc $out"
out=$(FAKE_UID=1000 PATH="$T/fakeid:$PATH" /bin/sh "$T/root-guard.sh" 2>&1); rc=$?
is "0f any other uid: it goes on, silently" "0 " "$rc $out"
# The predicate, both directions, against things this suite owns.
reset fixture_mt3000
case "$(type _ks_swap_mark_ours_real 2>&1)" in
    *function*) ok "0f the shipping predicate was copied out of the engine" ;;
    *)          nok "0f the shipping predicate was copied out of the engine" "a shell function" "$(type _ks_swap_mark_ours_real 2>&1)" ;;
esac
printf 'x\n' > "$KS_SWAP_MARK"
if _ks_swap_mark_ours; then ok "0f an own regular file is ours"; else nok "0f an own regular file is ours" "rc 0" "rc 1"; fi
MARK_FOREIGN=1
if _ks_swap_mark_ours; then nok "0f MARK_FOREIGN=1 plays another owner: not ours" "rc 1" "rc 0"
else ok "0f MARK_FOREIGN=1 plays another owner: not ours"; fi
MARK_FOREIGN=""
rm -f "$KS_SWAP_MARK"
printf 'x\n' > "$T/lint-target"
ln -s "$T/lint-target" "$KS_SWAP_MARK"
if _ks_swap_mark_ours; then nok "0f a symlink, even to an own regular file, is not ours" "rc 1" "rc 0"
else ok "0f a symlink, even to an own regular file, is not ours"; fi
rm -f "$KS_SWAP_MARK" "$T/lint-target"
mkdir "$KS_SWAP_MARK"
if _ks_swap_mark_ours; then nok "0f a directory is not ours" "rc 1" "rc 0"; else ok "0f a directory is not ours"; fi
rmdir "$KS_SWAP_MARK"
if _ks_swap_mark_ours; then nok "0f a missing path is not ours" "rc 1" "rc 0"; else ok "0f a missing path is not ours"; fi

echo "--- case 1: arm on the MT3000 shape severs exactly the five qualifying pairs"
reset fixture_mt3000
ks_main arm > "$T/out" 2>&1; rc=$?
is "1 rc"                              0 "$rc"
is "1 lan:wan severed"                 0 "$(g 'firewall.@forwarding[0].enabled')"
is "1 lan:zerotier severed"            0 "$(g firewall.lan_zerotier.enabled)"
is "1 guest:awgclient severed"         0 "$(g 'firewall.@forwarding[7].enabled')"
is "1 guest:wan severed"               0 "$(g 'firewall.@forwarding[14].enabled')"
is "1 iot:wan severed (GL's iot zone)" 0 "$(g 'firewall.@forwarding[11].enabled')"
is "1 lan:wgserver NOT severed"        "" "$(g firewall.lan2wgserver.enabled)"
is "1 awgclient:wan NOT severed"       "" "$(g firewall.awgclient2wan.enabled)"
is "1 sidecar records exactly those pairs" "lan:wan lan:zerotier guest:awgclient iot:wan guest:wan" "$(sev)"
is "1 lan2ts section created"          forwarding "$(g firewall.ts_fix_lan2ts)"
is "1 lan2ts src"                      lan        "$(g firewall.ts_fix_lan2ts.src)"
is "1 lan2ts dest"                     tailscale0 "$(g firewall.ts_fix_lan2ts.dest)"
is "1 lan2ts enabled"                  1          "$(g firewall.ts_fix_lan2ts.enabled)"
is "1 lan2ts ownership flag"           1          "$(g ts-fix.settings.ks_lan2ts_created)"
is "1 commits both packages"           "firewall
ts-fix" "$(commits)"
is "1 one firewall reload"             1 "$(reloads)"
is "1 rule layer in place"             "$(layer_state)" "$(ipstate)"
is "1 no 5279 delete, ever"            "" "$(grep ' del .*priority 5279' "$T/ip-calls")"
has "1 summary logged"                 "armed" "$(logtext)"

echo "--- case 2: a forwarding already disabled at arm time is skipped and never recorded"
reset fixture_mt3000
uci set firewall.lan_zerotier.enabled=0
ks_main arm > "$T/out" 2>&1
is "2 pre-disabled stays disabled"     0 "$(g firewall.lan_zerotier.enabled)"
is "2 pre-disabled NOT recorded"       "lan:wan guest:awgclient iot:wan guest:wan" "$(sev)"

echo "--- case 2b: the other UCI false spellings are already-disabled too, and stay unrecorded"
# The asymmetry this covers: recording a pair is what makes disarm rewrite it to enabled='1'. A
# forwarding the user turned off as 'false' or 'off' must therefore be skipped exactly like '0',
# or disarm would re-open a path the user had closed by hand. Both spellings are asserted
# byte-identical after the round trip — the engine must not even normalise them to '0'.
reset fixture_mt3000
uci set firewall.lan_zerotier.enabled=false
uci set 'firewall.@forwarding[7].enabled=off'
ks_main arm > "$T/out" 2>&1
is "2b 'false' left as-is"             false "$(g firewall.lan_zerotier.enabled)"
is "2b 'off' left as-is"               off   "$(g 'firewall.@forwarding[7].enabled')"
is "2b neither recorded"               "lan:wan iot:wan guest:wan" "$(sev)"
ks_main disarm > "$T/out" 2>&1
is "2b disarm leaves 'false' alone"    false "$(g firewall.lan_zerotier.enabled)"
is "2b disarm leaves 'off' alone"      off   "$(g 'firewall.@forwarding[7].enabled')"
is "2b disarm still restores ours"     1     "$(g 'firewall.@forwarding[0].enabled')"

echo "--- case 2c: a spelling that is not a UCI false value is treated as live (fail-secure)"
reset fixture_mt3000
uci set firewall.lan_zerotier.enabled=yes
ks_main arm > "$T/out" 2>&1
is "2c ambiguous spelling severed"     0 "$(g firewall.lan_zerotier.enabled)"
is "2c and recorded"                   "lan:wan lan:zerotier guest:awgclient iot:wan guest:wan" "$(sev)"

echo "--- case 3: GL's own enabled lan -> tailscale0 forwarding suppresses ours"
reset fixture_mt3000_gl_lan_ts
ks_main arm > "$T/out" 2>&1
is "3 no ts_fix_lan2ts created"        "" "$(g firewall.ts_fix_lan2ts)"
is "3 no ownership flag"               "" "$(g ts-fix.settings.ks_lan2ts_created)"
is "3 GL's forwarding untouched"       "" "$(g firewall.lan_ts.enabled)"
is "3 sidecar unchanged"               "lan:wan lan:zerotier guest:awgclient iot:wan guest:wan" "$(sev)"

echo "--- case 3b: the tunnel path is never severed, even if the sidecar says so"
# Defence in depth against a hand-edited or corrupted sidecar: severing lan -> tailscale0 would
# black-hole the LAN with no way back, so dest tailscale0 is skipped before the sidecar is
# consulted, not merely classified as uninteresting.
reset fixture_mt3000_gl_lan_ts
uci add_list ts-fix.settings.ks_severed=lan:tailscale0
ks_main arm > "$T/out" 2>&1
is "3b tunnel forwarding still enabled" "" "$(g firewall.lan_ts.enabled)"
reset fixture_mt3000_gl_lan_ts
uci add_list ts-fix.settings.ks_severed=lan:tailscale0
ks_main check > "$T/out" 2>&1
is "3b check leaves it alone too"       "" "$(g firewall.lan_ts.enabled)"

echo "--- case 4: a second arm changes nothing and must not commit or reload"
reset fixture_mt3000
ks_main arm > "$T/out" 2>&1
counters_reset
ks_main arm > "$T/out" 2>&1; rc=$?
is "4 rc"                              0 "$rc"
is "4 no duplicate pairs"              "lan:wan lan:zerotier guest:awgclient iot:wan guest:wan" "$(sev)"
is "4 zero commits"                    "" "$(commits)"
is "4 zero reloads"                    0 "$(reloads)"

echo "--- case 4b: an armed steady-state check is free (it runs on the watchdog's 5s poll)"
reset fixture_mt3000
ks_main arm > "$T/out" 2>&1
IP4_DEFAULT="default via 192.168.8.1 dev eth0 proto static"
UBUS_DUMP="eth0 wan
eth0 wan6"
cp "$STATE" "$T/before"
counters_reset
ks_main check > "$T/out" 2>&1; rc=$?
is "4b rc"                             0 "$rc"
if cmp -s "$T/before" "$STATE"; then ok "4b state unchanged"; else nok "4b state unchanged" "no writes" "state differs"; fi
is "4b zero commits"                   "" "$(commits)"
is "4b zero reloads"                   0 "$(reloads)"
is "4b silent log"                     "" "$(logtext)"
# The poll's whole ip cost: the invariant's two default-route reads, then the rule layer's four.
is "4b ip calls: 2 route reads + the rule layer's 6 (4 rules/routes, 2 swap)" "-4 route show default
-6 route show default
$(ensure_expect_present)" "$(ipcalls)"

echo "--- case 5: disarm restores exactly the recorded pairs"
reset fixture_mt3000
uci set firewall.lan_zerotier.enabled=0      # not ours: severed by someone else first
ks_main arm > "$T/out" 2>&1
counters_reset
ks_main disarm > "$T/out" 2>&1; rc=$?
is "5 rc"                              0 "$rc"
is "5 lan:wan restored"                1 "$(g 'firewall.@forwarding[0].enabled')"
is "5 guest:awgclient restored"        1 "$(g 'firewall.@forwarding[7].enabled')"
is "5 guest:wan restored"              1 "$(g 'firewall.@forwarding[14].enabled')"
is "5 NOT ours stays disabled"         0 "$(g firewall.lan_zerotier.enabled)"
is "5 iot:wan restored"                1 "$(g 'firewall.@forwarding[11].enabled')"
is "5 sidecar deleted"                 "" "$(sev)"
is "5 lan2ts section deleted"          "" "$(g firewall.ts_fix_lan2ts)"
is "5 lan2ts options deleted"          "" "$(g firewall.ts_fix_lan2ts.src)"
is "5 ownership flag deleted"          "" "$(g ts-fix.settings.ks_lan2ts_created)"
is "5 commits both packages"           "firewall
ts-fix" "$(commits)"
is "5 one firewall reload"             1 "$(reloads)"
counters_reset
ks_main disarm > "$T/out" 2>&1
is "5 second disarm is quiet"          "" "$(commits)"

echo "--- case 5b: disarm never deletes a lan -> tailscale0 forwarding it did not create"
reset fixture_mt3000_gl_lan_ts
ks_main arm > "$T/out" 2>&1
ks_main disarm > "$T/out" 2>&1
is "5b GL's forwarding survives"       forwarding "$(g firewall.lan_ts)"
is "5b and is still enabled"           ""         "$(g firewall.lan_ts.enabled)"

echo "--- case 6: check severs a newly re-emitted lan -> wan6 forwarding (named wan6 zone)"
reset fixture_wan6
ks_main arm > "$T/out" 2>&1
is "6 armed on the v4 zone first"      "lan:wan" "$(sev)"
counters_reset
uci set firewall.lan2wan6=forwarding
uci set firewall.lan2wan6.src=lan
uci set firewall.lan2wan6.dest=wan6
uci set firewall.lan2wan6.enabled=1
ks_main check > "$T/out" 2>&1; rc=$?
is "6 rc"                              0 "$rc"
is "6 new forwarding severed"          0 "$(g firewall.lan2wan6.enabled)"
is "6 and recorded"                    "lan:wan lan:wan6" "$(sev)"
is "6 commits both packages"           "firewall
ts-fix" "$(commits)"
is "6 one firewall reload"             1 "$(reloads)"
has "6 logged loudly"                  "lan:wan6" "$(logtext)"

echo "--- case 6b: check re-severs a recorded pair the firewall brought back enabled"
reset fixture_mt3000
ks_main arm > "$T/out" 2>&1
counters_reset
uci set 'firewall.@forwarding[0].enabled=1'      # GL re-emitted the config while we were armed
ks_main check > "$T/out" 2>&1
is "6b re-severed"                     0 "$(g 'firewall.@forwarding[0].enabled')"
is "6b no duplicate pair recorded"     "lan:wan lan:zerotier guest:awgclient iot:wan guest:wan" "$(sev)"
is "6b one firewall reload"            1 "$(reloads)"
has "6b logged loudly"                 "re-severed lan:wan" "$(logtext)"

echo "--- case 6c: check restores the tunnel path if GL removes it while we are armed"
# Without this the LAN would sit fully dark until the next reapply: every egress forwarding is
# severed, so lan -> tailscale0 is the only way out.
reset fixture_mt3000_gl_lan_ts
ks_main arm > "$T/out" 2>&1
counters_reset
uci -q delete firewall.lan_ts
ks_main check > "$T/out" 2>&1
is "6c tunnel path recreated"          forwarding "$(g firewall.ts_fix_lan2ts)"
is "6c and flagged as ours"            1          "$(g ts-fix.settings.ks_lan2ts_created)"
is "6c one firewall reload"            1          "$(reloads)"

echo "--- case 7: the runtime invariant severs an uplink the seed vocabulary does not know"
reset fixture_unseeded_uplink
IP4_DEFAULT="default via 10.9.9.1 dev usb0 proto static metric 20"
UBUS_DUMP="usb0 usb0"
ks_main check > "$T/out" 2>&1; rc=$?
is "7 rc"                              0 "$rc"
is "7 unseeded uplink severed"         0 "$(g firewall.lan_usb.enabled)"
is "7 and recorded"                    "lan:wan lan:usbzone" "$(sev)"
is "7 commits both packages"           "firewall
ts-fix" "$(commits)"
is "7 one firewall reload"             1 "$(reloads)"
has "7 invariant named in the log"     "INVARIANT" "$(logtext)"

echo "--- case 7b: a default-route device with no interface mapping warns, changes nothing"
reset fixture_unseeded_uplink
IP4_DEFAULT="default via 10.9.9.1 dev ppp0 proto static"
UBUS_DUMP=""
cp "$STATE" "$T/before"
ks_main check > "$T/out" 2>&1
if cmp -s "$T/before" "$STATE"; then ok "7b state unchanged"; else nok "7b state unchanged" "no writes" "state differs"; fi
is "7b zero commits"                   "" "$(commits)"
has "7b warning logged"                "ppp0" "$(logtext)"

echo "--- case 7c: the invariant honours the UCI false spellings too (never severed, never recorded)"
# Same doctrine as case 2b, on the OTHER sever path: the invariant reaches this zone by what it
# carries, not by name, so without the shared skip test it would sever and record a forwarding the
# user had turned off — and disarm would then switch it back on.
reset fixture_unseeded_uplink
uci set firewall.lan_usb.enabled=false
IP4_DEFAULT="default via 10.9.9.1 dev usb0 proto static metric 20"
UBUS_DUMP="usb0 usb0"
cp "$STATE" "$T/before"
counters_reset
ks_main check > "$T/out" 2>&1; rc=$?
is "7c rc"                             0 "$rc"
is "7c 'false' left as-is"             false "$(g firewall.lan_usb.enabled)"
is "7c not recorded"                   "lan:wan" "$(sev)"
if cmp -s "$T/before" "$STATE"; then ok "7c state unchanged"; else nok "7c state unchanged" "no writes" "state differs"; fi
is "7c zero commits"                   "" "$(commits)"
is "7c zero reloads"                   0 "$(reloads)"

echo "--- case 7d: default routes flagged dead or linkdown are skipped — no warning, no sever"
# Device fact (MT3000, GL 4.11, 2026-09-30 07:12-07:16): a saved-but-disconnected repeater STA left
# two v6 defaults on apclix0, both "dead linkdown", with no uci interface mapped to the device, and
# the warning fired on every armed pass. The v6 lines are those two; the v4 line puts a linkdown
# default on usb0, a device that DOES map (fixture_unseeded_uplink's lan -> usbzone forwarding is
# enabled), so skipping it shows as "not severed". The rule layer is seeded so ensure adds nothing.
reset fixture_unseeded_uplink
seed_layer
IP4_DEFAULT="default via 10.9.9.1 dev usb0 proto static metric 20 linkdown"
IP6_DEFAULT="default via fe80::1 dev apclix0 proto static metric 2 dead linkdown
default via fe80::1 dev apclix0 proto ra metric 1024 dead linkdown pref medium"
UBUS_DUMP="usb0 usb0"
cp "$STATE" "$T/before"
counters_reset
ks_main check > "$T/out" 2>&1; rc=$?
is "7d rc"                             0 "$rc"
is "7d silent: no warning, no sever line" "" "$(logtext)"
is "7d no ubus lookup: neither device was collected" "" "$(othercalls)"
if cmp -s "$T/before" "$STATE"; then ok "7d lan -> usbzone left alone, nothing written"; else nok "7d lan -> usbzone left alone, nothing written" "no writes" "state differs"; fi
is "7d zero commits"                   "" "$(commits)"
if [ -e "$KS_DEFROUTEWARN" ]; then nok "7d no fingerprint written" "absent" "present"; else ok "7d no fingerprint written"; fi
echo "  7d-live: the same routes without the flags are acted on (the skip discriminates)"
IP4_DEFAULT="default via 10.9.9.1 dev usb0 proto static metric 20"
IP6_DEFAULT="default via fe80::1 dev apclix0 proto static metric 2"
counters_reset
ks_main check > "$T/out" 2>&1
is "7d-live the usb0 uplink is severed" 0 "$(g firewall.lan_usb.enabled)"
has "7d-live the unmapped apclix0 is warned about" "WARNING default route device 'apclix0' maps to no uci interface" "$(logtext)"

echo "--- case 7e: the unmapped-device warning is logged once per distinct set, then 'cleared' once"
reset fixture_unseeded_uplink
seed_layer
UBUS_DUMP="usb0 usb0"
IP6_DEFAULT="default via fe80::1 dev apclix0 proto static metric 2"
warn_lines() { grep -c 'WARNING default route device' "$T/log"; }
counters_reset
ks_main check > "$T/out" 2>&1
is "7e pass 1: one WARNING, naming apclix0" "1 1" \
    "$(warn_lines) $(grep -c "device 'apclix0' maps to no uci interface" "$T/log")"
is "7e ... the fingerprint holds the set"   "apclix0" "$(cat "$KS_DEFROUTEWARN" 2>/dev/null)"
counters_reset
ks_main check > "$T/out" 2>&1
is "7e pass 2, the same set: silent"       "" "$(logtext)"
IP4_DEFAULT="default via 10.64.0.1 dev ppp0 proto static"
counters_reset
ks_main check > "$T/out" 2>&1
is "7e the set grows: every device in it warned again" "2 1 1" \
    "$(warn_lines) $(grep -c "device 'ppp0'" "$T/log") $(grep -c "device 'apclix0'" "$T/log")"
is "7e ... the fingerprint holds the new set" "ppp0 apclix0" "$(cat "$KS_DEFROUTEWARN" 2>/dev/null)"
IP4_DEFAULT=""
IP6_DEFAULT="default via fe80::1 dev apclix0 proto static metric 2
default via fe80::2 dev ppp0 proto static metric 3"
counters_reset
ks_main check > "$T/out" 2>&1
is "7e the same set in another order: silent" "" "$(logtext)"
IP6_DEFAULT="default via fe80::1 dev apclix0 proto static metric 2"
counters_reset
ks_main check > "$T/out" 2>&1
is "7e the set shrinks: warned again, for what is left" "1 1" \
    "$(warn_lines) $(grep -c "device 'apclix0'" "$T/log")"
IP6_DEFAULT="default via fe80::1 dev apclix0 proto static metric 2 dead linkdown"
counters_reset
ks_main check > "$T/out" 2>&1
is "7e the set empties (the route went dead): one 'cleared' line" \
    "-t ts-fix ks: default route devices with no uci interface cleared" "$(logtext)"
if [ -e "$KS_DEFROUTEWARN" ]; then nok "7e ... and the fingerprint is gone" "absent" "present"; else ok "7e ... and the fingerprint is gone"; fi
counters_reset
ks_main check > "$T/out" 2>&1
is "7e the next pass: silent"               "" "$(logtext)"

echo "--- case 7f: the fingerprint's path, defined once, removed by prerm, enumerated by prerm-drain"
PRERM="$(dirname "$0")/../../pkg/prerm"
DRAIN="$(dirname "$0")/../prerm-drain.sh"
is "7f KS_DEFROUTEWARN, verbatim, defined once" 'KS_DEFROUTEWARN="/tmp/ts-fix-ks.defroutewarn"' \
    "$(grep -e 'KS_DEFROUTEWARN=' "$SRC")"
# prerm's tmpfs cleanup is one rm command continued over two lines: from its first line to the line
# that ends it.
rmcmd=$(command awk '/^rm -f \/tmp\/ts-fix-ks\.lock /,/2>\/dev\/null$/' "$PRERM")
is "7f prerm's tmpfs cleanup command was found, one rm" 1 "$(printf '%s\n' "$rmcmd" | grep -c '^rm -f ')"
is "7f ... it removes the scopewarn fingerprint and the defroutewarn one" "1 1" \
    "$(printf '%s\n' "$rmcmd" | grep -c -F '/tmp/ts-fix-ks.scopewarn') $(printf '%s\n' "$rmcmd" | grep -c -F '/tmp/ts-fix-ks.defroutewarn')"
is "7f prerm-drain's residue probe enumerates it" 1 \
    "$(grep -c -F '[ -f /tmp/ts-fix-ks.defroutewarn ] && echo "RES file /tmp/ts-fix-ks.defroutewarn"' "$DRAIN")"

echo "--- case 8: check is a silent no-op while the kill switch is off"
reset fixture_mt3000
uci set ts-fix.settings.kill_switch=0
cp "$STATE" "$T/before"
counters_reset
ks_main check > "$T/out" 2>&1; rc=$?
is "8 rc"                              0 "$rc"
if cmp -s "$T/before" "$STATE"; then ok "8 state unchanged"; else nok "8 state unchanged" "no writes" "state differs"; fi
is "8 zero commits"                    "" "$(commits)"
is "8 zero reloads"                    0 "$(reloads)"
is "8 exactly one probe: the v4 rule list" "-4 rule list priority 5279" "$(ipcalls)"

echo "--- case 8b: check is a silent no-op while Tailscale is disabled"
reset fixture_mt3000
uci set tailscale.settings.enabled=0
cp "$STATE" "$T/before"
counters_reset
ks_main check > "$T/out" 2>&1
if cmp -s "$T/before" "$STATE"; then ok "8b state unchanged"; else nok "8b state unchanged" "no writes" "state differs"; fi
is "8b zero commits"                   "" "$(commits)"

echo "--- case 9: the mode gate refuses non-router modes and warns on an unknown one"
reset fixture_mt3000
uci set glconfig.general.mode=extender
cp "$STATE" "$T/before"
counters_reset
ks_main arm > "$T/out" 2>&1; rc=$?
is "9 rc is 2"                         2 "$rc"
has "9 message on stdout"              "Router mode" "$(cat "$T/out")"
if cmp -s "$T/before" "$STATE"; then ok "9 state unchanged"; else nok "9 state unchanged" "no writes" "state differs"; fi
is "9 zero commits"                    "" "$(commits)"
is "9 zero reloads"                    0 "$(reloads)"
# A refusal must still take the rule layer down: an upgrading router carries live 5279 rules and
# the table-100 route, and nothing is armed here for them to back up.
is "9 rules-clean still ran"           "$(rules_clean_expect)" "$(ipcalls)"
reset fixture_mt3000
uci -q delete glconfig.general.mode
ks_main arm > "$T/out" 2>&1; rc=$?
is "9 unknown mode still arms"         0 "$rc"
is "9 unknown mode severs"             0 "$(g 'firewall.@forwarding[0].enabled')"
has "9 unknown mode warns"             "WARNING" "$(logtext)"

echo "--- case 9b: check honours the same mode gate as arm, silently"
# postinst restarts the service (which runs a check) BEFORE calling arm, so a check that ignored
# the mode would sever a bridged-mode router's forwardings and only then hear arm refuse.
reset fixture_mt3000
uci set glconfig.general.mode=extender
cp "$STATE" "$T/before"
counters_reset
ks_main check > "$T/out" 2>&1; rc=$?
is "9b rc"                             0 "$rc"
if cmp -s "$T/before" "$STATE"; then ok "9b state unchanged"; else nok "9b state unchanged" "no writes" "state differs"; fi
is "9b lan:wan left alone"             1 "$(g 'firewall.@forwarding[0].enabled')"
is "9b nothing recorded"               "" "$(sev)"
is "9b zero commits"                   "" "$(commits)"
is "9b zero reloads"                   0 "$(reloads)"
is "9b silent (no 5s-poll spam)"       "" "$(logtext)"
is "9b no ip probing"                  "" "$(ipcalls)"

echo "--- case 9c: the stranded-state backstop is mode-independent"
reset fixture_mt3000
ks_main arm > "$T/out" 2>&1                 # armed while still in router mode
uci set glconfig.general.mode=extender      # then the router is switched to a bridged mode
uci set ts-fix.settings.kill_switch=0       # and the toggle goes off with no disarm
counters_reset
ks_main check > "$T/out" 2>&1; rc=$?
is "9c rc"                             0 "$rc"
is "9c lan:wan restored anyway"        1 "$(g 'firewall.@forwarding[0].enabled')"
is "9c guest:wan restored anyway"      1 "$(g 'firewall.@forwarding[14].enabled')"
is "9c sidecar cleared"                "" "$(sev)"
is "9c our lan2ts removed"             "" "$(g firewall.ts_fix_lan2ts)"

echo "--- case 9d: an unknown mode still lets check work (availability over refusal)"
reset fixture_mt3000
uci -q delete glconfig.general.mode
counters_reset
ks_main check > "$T/out" 2>&1; rc=$?
is "9d rc"                             0 "$rc"
is "9d swept normally"                 0 "$(g 'firewall.@forwarding[0].enabled')"
is "9d recorded"                       "lan:wan lan:zerotier guest:awgclient iot:wan guest:wan" "$(sev)"
has "9d loud sweep logged"             "severed new" "$(logtext)"

echo "--- case 10: rules-clean issues exactly the rule-layer deletes, both families"
reset fixture_mt3000
ks_main rules-clean > "$T/out" 2>&1; rc=$?
is "10 rc"                             0 "$rc"
is "10 exact ip call list"             "$(rules_clean_expect)" "$(ipcalls)"
# The rename is total: a caller still using the old name fails loudly instead of doing nothing.
ks_main legacy-clean > "$T/out" 2>&1; rc=$?
is "10 the old name is gone (rc 2)"    2 "$rc"

echo "--- case 11: arm without armed intent is a no-op (callers must commit intent first)"
reset fixture_mt3000
uci set ts-fix.settings.kill_switch=0
cp "$STATE" "$T/before"
counters_reset
ks_main arm > "$T/out" 2>&1; rc=$?
is "11 rc"                             0 "$rc"
if cmp -s "$T/before" "$STATE"; then ok "11 state unchanged"; else nok "11 state unchanged" "no writes" "state differs"; fi
is "11 zero commits"                   "" "$(commits)"
has "11 no-op logged"                  "intent" "$(logtext)"
is "11 rules-clean still ran"          "$(rules_clean_expect)" "$(ipcalls)"
reset fixture_mt3000
uci set tailscale.settings.enabled=0
cp "$STATE" "$T/before"
ks_main arm > "$T/out" 2>&1
if cmp -s "$T/before" "$STATE"; then ok "11 tailscale-off state unchanged"; else nok "11 tailscale-off state unchanged" "no writes" "state differs"; fi

echo "--- case 12: the dispatcher rejects unknown and missing arguments"
reset fixture_mt3000
ks_main bogus > "$T/out" 2>&1; rc=$?
is "12 unknown arg rc is 2"            2 "$rc"
has "12 usage printed"                 "usage" "$(cat "$T/out")"
ks_main > "$T/out" 2>&1; rc=$?
is "12 no arg rc is 2"                 2 "$rc"

echo "--- case 13: a commit that cannot land is an ERROR, not an armed kill switch"
reset fixture_mt3000
UCI_COMMIT_FAIL=1
ks_main arm > "$T/out" 2>&1; rc=$?
is "13 rc is 1"                        1 "$rc"
has "13 ERROR logged"                  "ERROR" "$(logtext)"
has "13 says NOT effective"            "NOT effective" "$(logtext)"
hasnt "13 never claims armed"          "ks: armed" "$(logtext)"
is "13 no successful commit recorded"  "" "$(commits)"
if [ -f "$KS_COMMIT_FAIL" ]; then ok "13 failure remembered for retry"; else nok "13 failure remembered for retry" "flag file" "absent"; fi
# While the zone state is unconfirmed the rule layer is the protection left, so none of it is
# deleted on this path (case R7 covers what IS done to it).
is "13 nothing of the rule layer deleted" "" "$(grep ' del ' "$T/ip-calls")"
# Next pass: the sweep sees its own uncommitted delta (everything already 0) and would otherwise
# conclude it had converged. The remembered failure must force the commit to be retried.
UCI_COMMIT_FAIL=""
counters_reset
ks_main check > "$T/out" 2>&1; rc=$?
is "13 retry rc"                       0 "$rc"
is "13 retry commits both packages"    "firewall
ts-fix" "$(commits)"
if [ -f "$KS_COMMIT_FAIL" ]; then nok "13 flag cleared after success" "no flag" "still there"; else ok "13 flag cleared after success"; fi
counters_reset
ks_main check > "$T/out" 2>&1
is "13 and is quiet again after that" "" "$(commits)"

echo "--- case 13b: a sever we cannot record is an ERROR, and we still sever (fail-secure)"
reset fixture_mt3000
UCI_ADDLIST_FAIL=1
ks_main arm > "$T/out" 2>&1; rc=$?
is "13b rc is 1"                       1 "$rc"
is "13b severed anyway"                0 "$(g 'firewall.@forwarding[0].enabled')"
is "13b nothing recorded"              "" "$(sev)"
has "13b ERROR names the consequence"  "restore" "$(logtext)"

echo "--- case 13c: a restore that fails keeps the record so the next disarm retries"
reset fixture_mt3000
ks_main arm > "$T/out" 2>&1
counters_reset
UCI_SET_FAIL="@forwarding[0].enabled=1"
ks_main disarm > "$T/out" 2>&1; rc=$?
is "13c rc is 1"                       1 "$rc"
is "13c the failed one stays severed"  0 "$(g 'firewall.@forwarding[0].enabled')"
is "13c the others still restored"     1 "$(g 'firewall.@forwarding[14].enabled')"
is "13c record kept for the retry"     "lan:wan lan:zerotier guest:awgclient iot:wan guest:wan" "$(sev)"
has "13c ERROR logged"                 "ERROR" "$(logtext)"
UCI_SET_FAIL=""
counters_reset
ks_main disarm > "$T/out" 2>&1; rc=$?
is "13c retry rc"                      0 "$rc"
is "13c retry restores it"             1 "$(g 'firewall.@forwarding[0].enabled')"
is "13c retry clears the record"       "" "$(sev)"

echo "--- case 14: an enumeration that comes back empty is an error, never nothing-to-do"
reset fixture_no_firewall
cp "$STATE" "$T/before"
ks_main arm > "$T/out" 2>&1; rc=$?
is "14 arm rc is 1"                    1 "$rc"
has "14 arm ERROR logged"              "ERROR" "$(logtext)"
hasnt "14 arm never claims armed"      "ks: armed" "$(logtext)"
if cmp -s "$T/before" "$STATE"; then ok "14 arm wrote nothing"; else nok "14 arm wrote nothing" "no writes" "state differs"; fi
is "14 arm no lan2ts invented"         "" "$(g firewall.ts_fix_lan2ts)"
is "14 arm zero commits"               "" "$(commits)"
# The zone layer could not even be read, so the rule layer is all the protection there is: it is
# ensured (it writes no config), and nothing of it is deleted.
is "14 arm deleted nothing"            "" "$(grep ' del ' "$T/ip-calls")"
is "14 arm still ensured the rule layer" "$(layer_state)" "$(ipstate)"
: > "$IPSTATE"                          # netifd wipes the rulebase; the config is still unreadable
counters_reset
ks_main check > "$T/out" 2>&1; rc=$?
is "14 check rc is 1"                  1 "$rc"
has "14 check ERROR logged"            "ERROR" "$(logtext)"
if cmp -s "$T/before" "$STATE"; then ok "14 check wrote nothing"; else nok "14 check wrote nothing" "no writes" "state differs"; fi
is "14 check still ensured the rule layer" "$(layer_state)" "$(ipstate)"

echo "--- case 14b: disarm keeps the restore record when the enumeration comes back empty"
# The restore-direction counterpart to case 14, and the more dangerous half. The pairs are still
# severed in flash at this point, and the sidecar is the only map back to a working LAN — so an
# unreadable firewall config must make disarm fail LOUDLY and change nothing. Dropping the record
# here would leave a dark LAN with no record and no tooling to recover with, which is also why
# prerm gates its deletion of /etc/config/ts-fix on this exact return code.
reset fixture_no_firewall
uci add_list ts-fix.settings.ks_severed=lan:wan
uci add_list ts-fix.settings.ks_severed=guest:wan
ks_main disarm > "$T/out" 2>&1; rc=$?
is "14b rc is 1"                       1 "$rc"
has "14b ERROR logged"                 "ERROR" "$(logtext)"
is "14b restore record KEPT"           "lan:wan guest:wan" "$(sev)"
is "14b zero commits"                  "" "$(commits)"

echo "--- case 15: check unstrands a severed state left behind by a lost disarm"
reset fixture_mt3000
ks_main arm > "$T/out" 2>&1
uci set ts-fix.settings.kill_switch=0     # the toggle went off but the disarm never ran
counters_reset
ks_main check > "$T/out" 2>&1; rc=$?
is "15 rc"                             0 "$rc"
is "15 lan:wan restored"               1 "$(g 'firewall.@forwarding[0].enabled')"
is "15 guest:wan restored"             1 "$(g 'firewall.@forwarding[14].enabled')"
is "15 lan:zerotier restored"          1 "$(g firewall.lan_zerotier.enabled)"
is "15 sidecar cleared"                "" "$(sev)"
is "15 our lan2ts removed"             "" "$(g firewall.ts_fix_lan2ts)"
is "15 commits both packages"          "firewall
ts-fix" "$(commits)"
has "15 logged as a lost disarm"       "lost" "$(logtext)"
counters_reset
ks_main check > "$T/out" 2>&1
is "15 next disarmed poll is free"     "" "$(commits)"
is "15 and costs exactly one probe"    "-4 rule list priority 5279" "$(ipcalls)"

# =============================================================================================
# An intent read that FAILS. `uci -q get` prints nothing and returns 1 both for an absent option and
# for a read that failed, so a failed read of kill_switch or enabled used to read as "no armed
# intent": check then disarmed an armed router, arm removed the rule layer. The engine now reads
# intent with `uci -q show <pkg>.settings`, which prints the section's own line first whenever the
# section could be read. A failed read is UNKNOWN, and every subcommand holds on it.

# u_armed — fixture_mt3000 armed, both layers in place and guest's source rule swapped; then the
# state, the ip model and the marker are kept in $T/u-* for comparison, and the counters reset.
u_armed() {
    reset fixture_mt3000
    addrs "br-lan 192.168.50.1/24" "br-guest 192.168.160.1/24"
    seed_gl_lan
    seed "$(gl_rule 192.168.160.0/24)"
    gl_cond guest
    ks_main arm > "$T/out" 2>&1
    IP4_DEFAULT="default via 192.168.8.1 dev eth0 proto static"
    UBUS_DUMP="eth0 wan"
    cp "$STATE" "$T/u-state"; cp "$IPSTATE" "$T/u-ip"; cp "$KS_SWAP_MARK" "$T/u-mark" 2>/dev/null
    counters_reset
}
u_same() {   # <label> — nothing of the armed router changed: config, kernel model, marker
    if cmp -s "$T/u-state" "$STATE"; then ok "$1: the config is untouched"; else nok "$1: the config is untouched" "no writes" "state differs"; fi
    if cmp -s "$T/u-ip" "$IPSTATE"; then ok "$1: the rules, the route and the swap are untouched"
    else nok "$1: the rules, the route and the swap are untouched" "$(sort "$T/u-ip")" "$(ipstate)"; fi
    if cmp -s "$T/u-mark" "$KS_SWAP_MARK"; then ok "$1: the swap marker is untouched"; else nok "$1: the swap marker is untouched" "unchanged" "changed or gone"; fi
    is "$1: zero commits, zero reloads" ":0" "$(commits):$(reloads)"
    is "$1: no ip delete or add" "" "$(grep -e ' del ' -e ' add ' "$T/ip-calls")"
}

echo "--- case U1: an armed router whose intent read fails: check holds, warns once, then recovers once"
for pkg in tailscale ts-fix; do
    u_armed
    is "U1 $pkg non-vacuity: armed, rule layer, swap and record in place" \
        "$(layer_state) lan:wan lan:zerotier guest:awgclient iot:wan guest:wan guest 192.168.160.0/24" \
        "$(grep -v '^S|' "$IPSTATE" | sort) $(sev) $(marker)"
    UCI_READ_FAIL="$pkg"
    ks_main check > "$T/out" 2>&1; rc=$?
    is "U1 $pkg: rc 1 (the kill switch is not known to be right)" 1 "$rc"
    u_same "U1 $pkg"
    is "U1 $pkg: exactly one log line" 1 "$(grep -c . "$T/log")"
    has "U1 $pkg: a WARNING naming the read" "WARNING $pkg.settings could not be read" "$(logtext)"
    has "U1 $pkg: ... saying the kill switch is held" "left exactly as it is" "$(logtext)"
    counters_reset
    ks_main check > "$T/out" 2>&1; rc=$?
    is "U1 $pkg: a second failed check: rc 1, nothing logged" "1:" "$rc:$(logtext)"
    u_same "U1 $pkg, again"
    UCI_READ_FAIL=""
    counters_reset
    ks_main check > "$T/out" 2>&1; rc=$?
    is "U1 $pkg: the next readable check: rc 0, one line saying the read recovered" "0 1" "$rc $(grep -c . "$T/log")"
    has "U1 $pkg: ... which says so" "readable again" "$(logtext)"
    u_same "U1 $pkg, readable"
    counters_reset
    ks_main check > "$T/out" 2>&1
    is "U1 $pkg: and the check after that is silent" "" "$(logtext)"
done

echo "--- case U2: arm on a failed intent read: ERROR, rc 1, and NOTHING removed or written"
u_armed
UCI_READ_FAIL="tailscale"
ks_main arm > "$T/out" 2>&1; rc=$?
is "U2 rc 1"                           1 "$rc"
u_same "U2"
has "U2 an ERROR naming the read"      "ERROR arm: tailscale.settings could not be read" "$(logtext)"
hasnt "U2 never 'no armed intent'"     "no armed intent" "$(logtext)"
echo "  U2b: on a router not armed yet: no sever, no ip call at all"
reset fixture_mt3000
cp "$STATE" "$T/before"
UCI_READ_FAIL="ts-fix"
counters_reset
ks_main arm > "$T/out" 2>&1; rc=$?
is "U2b rc 1, zero ip calls, zero commits" "1::" "$rc:$(ipcalls):$(commits)"
if cmp -s "$T/before" "$STATE"; then ok "U2b nothing written"; else nok "U2b nothing written" "no writes" "state differs"; fi

echo "--- case U3: preboot on a failed intent read: ERROR, rc 1, nothing written"
reset fixture_mt3000
first_boot_state
cp "$STATE" "$T/before"
UCI_READ_FAIL="tailscale"
counters_reset
preboot_run; rc=$?
is "U3 rc 1"                           1 "$rc"
if cmp -s "$T/before" "$STATE"; then ok "U3 nothing re-severed, nothing written"; else nok "U3 nothing re-severed, nothing written" "no writes" "state differs"; fi
is "U3 zero commits, zero reloads, zero ip calls" ":0:" "$(commits):$(reloads):$(ipcalls)"
is "U3 exactly one log line"           1 "$(grep -c . "$T/log")"
has "U3 an ERROR naming the read"      "ERROR preboot: tailscale.settings could not be read" "$(logtext)"

echo "--- case U4: rules-ensure on a failed intent read is a no-op: no ip call, rc 1, silent"
u_armed
: > "$IPSTATE"                          # netifd wiped the rulebase
UCI_READ_FAIL="tailscale"
ks_main rules-ensure > "$T/out" 2>&1; rc=$?
is "U4 rc 1, zero ip calls, nothing added" "1::" "$rc:$(ipcalls):$(cat "$IPSTATE")"
is "U4 silent (the check owns the WARNING)" "" "$(logtext)"
UCI_READ_FAIL=""
ks_main rules-ensure > "$T/out" 2>&1; rc=$?
is "U4 control: readable again, the same call re-adds the layer, rc 0" "0 $(layer_state)" "$rc $(grep -v '^S|' "$IPSTATE" | sort)"

echo "--- case U5: a disarmed router whose read fails: not even the disarmed-branch cleanups run"
# The stranded-rule-layer and lost-disarm backstops take protection DOWN, so they too wait for a
# readable intent.
u_armed
uci set ts-fix.settings.kill_switch=0       # the toggle went off, the disarm was lost
cp "$STATE" "$T/u-state"
UCI_READ_FAIL="tailscale"
ks_main check > "$T/out" 2>&1; rc=$?
is "U5 lost disarm, read failing: rc 1" 1 "$rc"
u_same "U5 lost disarm"
is "U5 ... the record is kept"         "lan:wan lan:zerotier guest:awgclient iot:wan guest:wan" "$(sev)"
u_armed
uci set ts-fix.settings.kill_switch=0
uci -q delete ts-fix.settings.ks_severed     # only the rule layer and the swap are left behind
cp "$STATE" "$T/u-state"
UCI_READ_FAIL="tailscale"
ks_main check > "$T/out" 2>&1; rc=$?
is "U5 stranded rule layer, read failing: rc 1, not even the 5279 probe" "1:" "$rc:$(ipcalls)"
u_same "U5 stranded rule layer"

echo "--- case U6: the controls - explicit enabled='0' and an ABSENT enabled are off, not unknown"
u_armed
uci set tailscale.settings.enabled=0
ks_main check > "$T/out" 2>&1; rc=$?
is "U6 enabled '0': rc 0, disarmed as before (lost-disarm path)" "0 1" "$rc $(g 'firewall.@forwarding[0].enabled')"
is "U6 ... record dropped, rule layer gone" ":" "$(sev):$(grep -v '^S|' "$IPSTATE")"
has "U6 ... the lost-disarm line"      "a disarm was lost" "$(logtext)"
u_armed
uci -q delete tailscale.settings.enabled    # GL's slider deletes it to restore a never-set state
is "U6 non-vacuity: the section is still readable, with no enabled option" "tailscale.settings=settings|" \
    "$(uci -q show tailscale.settings | head -n 1)|$(uci -q show tailscale.settings | grep -e '\.enabled=')"
ks_main check > "$T/out" 2>&1; rc=$?
is "U6 enabled ABSENT: rc 0, disarmed exactly the same way" "0 1" "$rc $(g 'firewall.@forwarding[0].enabled')"
is "U6 ... record dropped, rule layer gone" ":" "$(sev):$(grep -v '^S|' "$IPSTATE")"
hasnt "U6 ... no WARNING"              "WARNING" "$(logtext)"

echo "--- case U7: arm's no-intent line reports the values it decided on, from the same two reads"
reset fixture_mt3000
uci set ts-fix.settings.kill_switch=0
counters_reset
ks_main arm > "$T/out" 2>&1; rc=$?
is "U7 rc 0"                           0 "$rc"
has "U7 the values as read"            "no armed intent (kill_switch='0' tailscale enabled='1')" "$(logtext)"
is "U7 intent read once per package, with show, and never with get" \
    "uci -q show ts-fix.settings
uci -q show tailscale.settings" "$(grep -e 'ts-fix\.settings' -e 'tailscale\.settings' "$T/uci-calls" | grep -v -e 'ks_severed' -e 'exit_node_ip' -e 'route_guest')"
reset fixture_mt3000
uci -q delete tailscale.settings.enabled
counters_reset
ks_main arm > "$T/out" 2>&1
has "U7 an absent option is named as absent" "kill_switch='1' tailscale enabled=(absent)" "$(logtext)"

echo "--- case U8: the tmpfs flags are their shipping values, defined once"
is "U8 KS_INTENTWARN, verbatim, defined once" 'KS_INTENTWARN="/tmp/ts-fix-ks.intentwarn"' "$(grep -e 'KS_INTENTWARN=' "$SRC")"
is "U8 KS_RELOAD_FAIL, verbatim, defined once" 'KS_RELOAD_FAIL="/tmp/ts-fix-ks.reload-failed"' "$(grep -e 'KS_RELOAD_FAIL=' "$SRC")"

# =============================================================================================
# A firewall reload that FAILS. The zone layer's severing is committed to flash, but only a reload
# makes it the running firewall's. A failed reload was ignored, and since the passes commit and
# reload only when something changed, it was never retried: the kill switch reported armed with the
# running firewall still forwarding.
rl_lines() { grep -c -e 'ERROR firewall reload failed' "$T/log"; }

echo "--- case RL1: a reload that fails on arm is rc 1 and an ERROR; the next checks retry the reload alone"
reset fixture_mt3000
FW_RELOAD_FAIL=1
ks_main arm > "$T/out" 2>&1; rc=$?
is "RL1 rc 1"                          1 "$rc"
is "RL1 the commit landed, the reload was attempted once" "firewall
ts-fix:1" "$(commits):$(reloads)"
if [ -f "$KS_RELOAD_FAIL" ]; then ok "RL1 the failure is remembered"; else nok "RL1 the failure is remembered" "flag file" "absent"; fi
if [ -f "$KS_COMMIT_FAIL" ]; then nok "RL1 ... as a reload failure, not a commit failure" "no commit flag" "commit flag"
else ok "RL1 ... as a reload failure, not a commit failure"; fi
is "RL1 one ERROR line"                1 "$(rl_lines)"
has "RL1 ... saying the config is committed but not in force" "NOT in force" "$(logtext)"
hasnt "RL1 never 'armed'"              "ks: armed" "$(logtext)"
is "RL1 the rule layer is ensured anyway" "$(layer_state)" "$(ipstate)"
counters_reset
ks_main check > "$T/out" 2>&1; rc=$?
is "RL1 next check, still failing: rc 1, ONE reload, ZERO commits (no flash write)" "1 1 " "$rc $(reloads) $(commits)"
is "RL1 ... and no second ERROR line (rate-limited)" 0 "$(rl_lines)"
FW_RELOAD_FAIL=""
counters_reset
ks_main check > "$T/out" 2>&1; rc=$?
is "RL1 the reload succeeds: rc 0, one reload, zero commits" "0 1 " "$rc $(reloads) $(commits)"
if [ -f "$KS_RELOAD_FAIL" ]; then nok "RL1 ... the flag is gone" "absent" "present"; else ok "RL1 ... the flag is gone"; fi
is "RL1 ... one line, the recovery's" 1 "$(grep -c . "$T/log")"
has "RL1 ... which says so"            "firewall reload succeeded" "$(logtext)"
counters_reset
ks_main check > "$T/out" 2>&1
is "RL1 and the next check is quiet again: no reload, no log" "0:" "$(reloads):$(logtext)"

echo "--- case RL2: thirteen failures in a row log the first and the thirteenth, and nothing between"
reset fixture_mt3000
FW_RELOAD_FAIL=1
ks_main arm > "$T/out" 2>&1
i=1
while [ "$i" -lt 12 ]; do ks_main check > "$T/out" 2>&1; i=$((i + 1)); done
is "RL2 twelve failures: twelve reloads, one ERROR line" "12 1" "$(reloads) $(rl_lines)"
ks_main check > "$T/out" 2>&1
is "RL2 the thirteenth: a second ERROR line" "13 2" "$(reloads) $(rl_lines)"
has "RL2 ... naming the count"         "13 in a row" "$(grep 'ERROR firewall reload failed' "$T/log" | tail -n 1)"
is "RL2 every retry was a reload alone: the arm's commits only" "firewall
ts-fix" "$(commits)"

echo "--- case RL3: disarm with a failing reload is rc 1; the disarmed check retries it"
reset fixture_mt3000
ks_main arm > "$T/out" 2>&1
uci set ts-fix.settings.kill_switch=0
FW_RELOAD_FAIL=1
counters_reset
ks_main disarm > "$T/out" 2>&1; rc=$?
is "RL3 disarm rc 1"                   1 "$rc"
if [ -f "$KS_RELOAD_FAIL" ]; then ok "RL3 the failure is remembered"; else nok "RL3 the failure is remembered" "flag file" "absent"; fi
is "RL3 one ERROR line"                1 "$(rl_lines)"
is "RL3 ... the restore itself was committed" "1:firewall
ts-fix" "$(g 'firewall.@forwarding[0].enabled'):$(commits)"
FW_RELOAD_FAIL=""
counters_reset
ks_main check > "$T/out" 2>&1; rc=$?
is "RL3 the disarmed check retries: rc 0, one reload, zero commits" "0 1 " "$rc $(reloads) $(commits)"
if [ -f "$KS_RELOAD_FAIL" ]; then nok "RL3 ... the flag is gone" "absent" "present"; else ok "RL3 ... the flag is gone"; fi
has "RL3 ... one recovery line"        "firewall reload succeeded" "$(logtext)"

echo "--- case RL4: preboot never reloads, even with a reload failure remembered"
reset fixture_mt3000
ks_main arm > "$T/out" 2>&1
printf '1\n' > "$KS_RELOAD_FAIL"
counters_reset
preboot_run; rc=$?
is "RL4 rc 0, zero reloads, no log"    "0 0 " "$rc $(reloads) $(logtext)"
if [ -f "$KS_RELOAD_FAIL" ]; then ok "RL4 the flag is left for the next check"; else nok "RL4 the flag is left for the next check" "present" "absent"; fi

echo "--- case RL5: a count that cannot be read counts as one - a full /tmp never turns into a log line per poll"
for c in garbage "" ; do
    reset fixture_mt3000
    ks_main arm > "$T/out" 2>&1
    printf '%s' "$c" > "$KS_RELOAD_FAIL"
    FW_RELOAD_FAIL=1
    counters_reset
    ks_main check > "$T/out" 2>&1; rc=$?
    is "RL5 flag holding '$c': rc 1, one reload, no ERROR line" "1 1 0" "$rc $(reloads) $(rl_lines)"
done

echo "--- case RL6: a check that changed something with a reload failure remembered: one commit, ONE reload"
reset fixture_mt3000
ks_main arm > "$T/out" 2>&1
printf '3\n' > "$KS_RELOAD_FAIL"
uci set 'firewall.@forwarding[0].enabled=1'      # GL re-emitted it
counters_reset
ks_main check > "$T/out" 2>&1; rc=$?
is "RL6 rc 0, committed, exactly one reload" "0 1" "$rc $(reloads)"
is "RL6 ... both packages committed" "firewall
ts-fix" "$(commits)"
if [ -f "$KS_RELOAD_FAIL" ]; then nok "RL6 ... the flag is gone" "absent" "present"; else ok "RL6 ... the flag is gone"; fi
has "RL6 ... with the recovery line"   "firewall reload succeeded after 3" "$(logtext)"

# =============================================================================================
# Forwardings GL owns at disarm. Two stock GL features turn off the very forwardings the zone layer
# severs, and can do so while the kill switch is armed; a disarm must not switch them back on. It
# leaves each such section disabled — no write, and no write failure, so the sidecar still goes —
# with one log line naming the section, its pair and the reason.
#   GL Tor: while tor.global.enable is '1', GL keeps the first forwarding section of the firewall
#     config disabled (uci's @forwarding[0], lan -> wan on stock configs). 4.8.4 and 4.9.0 do the
#     same to firewall.guestzone_fwd, which counts only where the installed Tor script names it
#     (KS_TOR_SCRIPT, this suite's $T/tor.sh).
#   GL 4.11's per-network "block all WAN" (wan_access_mode 2): every <net> -> wan and <net> -> wan6
#     forwarding disabled, and gl-black_white_list.<net>_transfer_enable.transfer_enable set to
#     '0'; never for lan. The older gl-black_white_list.<net>.transfer_enable reads '0' on routers
#     whose guest and iot are online, so it means something else (case G7).
# The uci fake declares no section for tor or gl-black_white_list: the engine reads one option of
# each, and the fake answers an option whether or not its section was declared.
tor_on()    { uci set tor.global.enable=1; }
tor_sh()    {   # mention | plain | missing — the installed GL Tor script, which disarm greps
    case "$1" in
        mention) printf '%s\n' '#!/bin/sh' 'uci set firewall.@forwarding[0].enabled="0"' \
                     'uci set firewall.guestzone_fwd.enabled="0"' > "$KS_TOR_SCRIPT" ;;
        plain)   printf '%s\n' '#!/bin/sh' 'uci set firewall.@forwarding[0].enabled="0"' > "$KS_TOR_SCRIPT" ;;
        missing) rm -f "$KS_TOR_SCRIPT" ;;
    esac
}
wan_block() { uci set "gl-black_white_list.$1_transfer_enable.transfer_enable=$2"; }   # <net> <value>
g_disarm()  { counters_reset; ks_main disarm > "$T/out" 2>&1; rc=$?; }
# The engine's exact log lines, as the logger fake records them.
left_line() { printf '%s\n' "-t ts-fix ks: disarm left $1 ($2) disabled - $3"; }     # <sec> <pair> <why>
sum_line()  { printf '%s\n' "-t ts-fix ks: disarmed - recorded pairs: $1; every forwarding of theirs is now enabled unless named above"; }
why_tor="GL Tor is on and manages it"
why_guest="GL blocks internet access for guest"
# The first forwarding section in the fixture's `uci show firewall`, read the way the engine reads
# its enumeration; and a fixture section renamed in every record that names it.
first_fwd() { uci show firewall | sed -n 's/^\(firewall\.[^.=]*\)=forwarding$/\1/p' | head -n 1; }
ren_fwd()   {   # <index> <name> — firewall.@forwarding[<index>] becomes firewall.<name>
    sed -e "s/|firewall\.@forwarding\[$1]/|firewall.$2/" "$STATE" > "$T/state.ren"
    mv "$T/state.ren" "$STATE"
}
# fixture_mt3000 plus a NAMED wan6 zone with a guest -> wan6 forwarding (GL's block covers both zone
# names), and guest -> wwan into a zone named wwan: uplink-class, so severed and recorded, but not
# one of the two zone names GL's block writes.
fixture_gl_owned() {
    fixture_mt3000
    cat >> "$STATE" <<'EOF'
S|firewall.wan6|zone
O|firewall.wan6.name|wan6
O|firewall.wan6.network|wan6
S|firewall.wwan|zone
O|firewall.wwan.name|wwan
O|firewall.wwan.network|wwan
S|firewall.guest_wan6|forwarding
O|firewall.guest_wan6.src|guest
O|firewall.guest_wan6.dest|wan6
O|firewall.guest_wan6.enabled|1
S|firewall.guest_wwan|forwarding
O|firewall.guest_wwan.src|guest
O|firewall.guest_wwan.dest|wwan
O|firewall.guest_wwan.enabled|1
EOF
}
# fixture_mt3000 plus 4.8.4/4.9.0's named guest -> wan forwarding, and a near-miss name beside it.
fixture_guestzone() {
    fixture_mt3000
    cat >> "$STATE" <<'EOF'
S|firewall.guestzone_fwd|forwarding
O|firewall.guestzone_fwd.src|guest
O|firewall.guestzone_fwd.dest|wan
O|firewall.guestzone_fwd.enabled|1
S|firewall.guestzone_fwd2|forwarding
O|firewall.guestzone_fwd2.src|guest
O|firewall.guestzone_fwd2.dest|wan
O|firewall.guestzone_fwd2.enabled|1
EOF
}
# fixture_484 with its first forwarding under the other names it can print as: an anonymous section
# by its raw name (`uci -X show` prints the first anonymous forwarding of a config as cfg04ad58),
# and a real name, which uci also resolves as @forwarding[0] when that section comes first.
fixture_cfg_first()   { fixture_484; ren_fwd 0 cfg04ad58; ren_fwd 1 cfg05ad58; }
fixture_named_first() { fixture_484; ren_fwd 0 lan2wan; }

echo "--- case G0: instrument lint for the G cases (fixtures, the Tor script, GL's keys)"
reset fixture_gl_owned
ks_main arm > "$T/out" 2>&1
is "G0 the extended MT3000 shape records guest:wan6 and guest:wwan too" \
    "lan:wan lan:zerotier guest:awgclient iot:wan guest:wan guest:wan6 guest:wwan" "$(sev)"
is "G0 ... and severs both"            "0 0" "$(g firewall.guest_wan6.enabled) $(g firewall.guest_wwan.enabled)"
tor_on
wan_block guest 0
uci set gl-black_white_list.guest.transfer_enable=1
is "G0 the fake reads GL's keys back, each under its own path" "1 0 1" \
    "$(g tor.global.enable) $(g gl-black_white_list.guest_transfer_enable.transfer_enable) $(g gl-black_white_list.guest.transfer_enable)"
hasnt "G0 ... and none of them is in the firewall capture" "transfer_enable" "$(uci show firewall)"
tor_sh mention; grep -q guestzone_fwd "$KS_TOR_SCRIPT"; r1=$?
tor_sh plain;   grep -q guestzone_fwd "$KS_TOR_SCRIPT"; r2=$?
tor_sh missing; grep -q guestzone_fwd "$KS_TOR_SCRIPT" 2>/dev/null; r3=$?
[ "$r3" -gt 1 ] && r3=error
is "G0 the Tor script fixture discriminates: names it, does not, is missing" "0 1 error" "$r1 $r2 $r3"
for spec in fixture_mt3000:firewall.@forwarding[0] fixture_cfg_first:firewall.cfg04ad58 \
            fixture_named_first:firewall.lan2wan; do
    reset "${spec%%:*}"
    is "G0 ${spec%%:*}: the first forwarding is ${spec#*:}, lan -> wan" "${spec#*:} lan wan" \
        "$(first_fwd) $(g "${spec#*:}.src") $(g "${spec#*:}.dest")"
done
reset fixture_cfg_first
hasnt "G0 fixture_cfg_first: no @forwarding path is left in it" "@forwarding[" "$(uci show firewall)"
is "G0 ... its second forwarding is cfg05ad58, guest -> wan" "guest wan" \
    "$(g firewall.cfg05ad58.src) $(g firewall.cfg05ad58.dest)"

echo "--- case G1: GL Tor on: disarm leaves @forwarding[0] disabled, restores the rest, drops the sidecar"
reset fixture_mt3000
ks_main arm > "$T/out" 2>&1
tor_on
tor_sh plain
g_disarm
is "G1 rc"                             0 "$rc"
is "G1 lan:wan, @forwarding[0], left disabled" 0 "$(g 'firewall.@forwarding[0].enabled')"
is "G1 ... with no write to it"        "" "$(grep -F 'firewall.@forwarding[0].enabled=1' "$T/uci-calls")"
is "G1 every other recorded pair restored" "1 1 1 1" \
    "$(g firewall.lan_zerotier.enabled) $(g 'firewall.@forwarding[7].enabled') $(g 'firewall.@forwarding[11].enabled') $(g 'firewall.@forwarding[14].enabled')"
is "G1 sidecar dropped: a section left disabled is not a failed restore" "" "$(sev)"
is "G1 our lan2ts removed as usual"    "" "$(g firewall.ts_fix_lan2ts)"
is "G1 the log: one line for the section Tor manages, then the summary" \
    "$(left_line 'firewall.@forwarding[0]' lan:wan "$why_tor")
$(sum_line 'lan:wan lan:zerotier guest:awgclient iot:wan guest:wan')" "$(logtext)"
is "G1 commits both packages"          "firewall
ts-fix" "$(commits)"
is "G1 one firewall reload"            1 "$(reloads)"
is "G1 nothing on stdout or stderr"    "" "$(cat "$T/out")"
echo "  G1b: afterwards a disarm, and the disarmed poll, find nothing left to do"
g_disarm
is "G1b a second disarm: rc 0, no commit, no log" "0::" "$rc:$(commits):$(logtext)"
is "G1b ... it reads no GL state: nothing is recorded" 0 "$(grep -c -e 'tor\.global' -e 'gl-black_white_list' "$T/uci-calls")"
is "G1b ... and @forwarding[0] is still disabled" 0 "$(g 'firewall.@forwarding[0].enabled')"
uci set ts-fix.settings.kill_switch=0
counters_reset
ks_main check > "$T/out" 2>&1
is "G1b the disarmed poll sees no lost disarm: its one probe, no log, no commit" \
    "-4 rule list priority 5279::" "$(ipcalls):$(logtext):$(commits)"
echo "  G1c: Tor on, @forwarding[0] enabled: nothing to leave disabled, so no line"
reset fixture_mt3000
ks_main arm > "$T/out" 2>&1
uci set 'firewall.@forwarding[0].enabled=1'
tor_on
tor_sh plain
g_disarm
is "G1c rc"                            0 "$rc"
is "G1c @forwarding[0] stays enabled"  1 "$(g 'firewall.@forwarding[0].enabled')"
hasnt "G1c no line: it was not left disabled" "disarm left" "$(logtext)"

echo "--- case G2: Tor off, not exactly '1', or absent: @forwarding[0] is restored (controls)"
for torval in 0 true absent; do
    reset fixture_mt3000
    ks_main arm > "$T/out" 2>&1
    [ "$torval" = "absent" ] || uci set "tor.global.enable=$torval"
    tor_sh mention                  # a Tor script that names guestzone_fwd changes nothing either
    g_disarm
    is "G2 tor.global.enable $torval: rc 0" 0 "$rc"
    is "G2 tor.global.enable $torval: @forwarding[0] restored" 1 "$(g 'firewall.@forwarding[0].enabled')"
    is "G2 tor.global.enable $torval: sidecar dropped" "" "$(sev)"
    hasnt "G2 tor.global.enable $torval: nothing left disabled" "disarm left" "$(logtext)"
done

echo "--- case G3: Tor's section is @forwarding[0] by position: a lan:wan that comes second is restored"
reset fixture_484
uci set 'firewall.@forwarding[0].dest=tailscale0'     # the first forwarding leads into the tunnel
uci set 'firewall.@forwarding[1].src=lan'             # and lan -> wan comes second
ks_main arm > "$T/out" 2>&1
is "G3 non-vacuity: lan:wan, the second forwarding, severed and recorded" "0 lan:wan" \
    "$(g 'firewall.@forwarding[1].enabled') $(sev)"
tor_on
tor_sh plain
g_disarm
is "G3 rc"                             0 "$rc"
is "G3 the second forwarding, lan:wan, restored" 1 "$(g 'firewall.@forwarding[1].enabled')"
hasnt "G3 nothing left disabled"       "disarm left" "$(logtext)"
is "G3 sidecar dropped"                "" "$(sev)"
echo "  G3b: whatever pair the first forwarding carries, it is the one Tor keeps disabled"
reset fixture_484
uci set 'firewall.@forwarding[0].src=guest'           # guest -> wan first
uci set 'firewall.@forwarding[1].src=lan'             # lan -> wan second
ks_main arm > "$T/out" 2>&1
is "G3b non-vacuity: both severed, both recorded" "0 0 guest:wan lan:wan" \
    "$(g 'firewall.@forwarding[0].enabled') $(g 'firewall.@forwarding[1].enabled') $(sev)"
tor_on
tor_sh plain
g_disarm
is "G3b rc"                            0 "$rc"
is "G3b the first forwarding, guest:wan, left disabled" 0 "$(g 'firewall.@forwarding[0].enabled')"
is "G3b the second, lan:wan, restored" 1 "$(g 'firewall.@forwarding[1].enabled')"
is "G3b one line, naming the first section and its pair" \
    "$(left_line 'firewall.@forwarding[0]' guest:wan "$why_tor")" "$(grep -e 'disarm left' "$T/log")"

echo "--- case G4: the first forwarding in either other naming form: a raw cfg name, a real name"
for spec in fixture_cfg_first:firewall.cfg04ad58:firewall.cfg05ad58 \
            fixture_named_first:firewall.lan2wan:firewall.@forwarding[1]; do
    fx="${spec%%:*}"; rest="${spec#*:}"; first="${rest%%:*}"; second="${rest#*:}"
    reset "$fx"
    ks_main arm > "$T/out" 2>&1
    is "G4 $first: non-vacuity: it and $second (guest:wan) severed and recorded" \
        "0 0 lan:wan guest:wan" "$(g "$first.enabled") $(g "$second.enabled") $(sev)"
    tor_on
    tor_sh plain
    g_disarm
    is "G4 $first: rc 0"               0 "$rc"
    is "G4 $first: left disabled"      0 "$(g "$first.enabled")"
    is "G4 $first: $second restored"   1 "$(g "$second.enabled")"
    is "G4 $first: the line names it in that form" "$(left_line "$first" lan:wan "$why_tor")" \
        "$(grep -e 'disarm left' "$T/log")"
    is "G4 $first: sidecar dropped"    "" "$(sev)"
done

echo "--- case G5: guestzone_fwd is Tor's only where the installed Tor script names it"
g5() {   # <tor.global.enable value, or absent> <mention | plain | missing>
    reset fixture_guestzone
    ks_main arm > "$T/out" 2>&1
    [ "$1" = "absent" ] || uci set "tor.global.enable=$1"
    tor_sh "$2"
    g_disarm
}
reset fixture_guestzone
ks_main arm > "$T/out" 2>&1
is "G5 non-vacuity: arm severs guestzone_fwd and guestzone_fwd2, under the one guest:wan" \
    "0 0 lan:wan lan:zerotier guest:awgclient iot:wan guest:wan" \
    "$(g firewall.guestzone_fwd.enabled) $(g firewall.guestzone_fwd2.enabled) $(sev)"
g5 1 mention
is "G5 Tor on, the script names it: rc 0" 0 "$rc"
is "G5 ... guestzone_fwd and @forwarding[0] left disabled" "0 0" \
    "$(g firewall.guestzone_fwd.enabled) $(g 'firewall.@forwarding[0].enabled')"
is "G5 ... the near-miss guestzone_fwd2 and @forwarding[14], guest:wan both, restored" "1 1" \
    "$(g firewall.guestzone_fwd2.enabled) $(g 'firewall.@forwarding[14].enabled')"
is "G5 ... one line per section left, in enumeration order" \
    "$(left_line 'firewall.@forwarding[0]' lan:wan "$why_tor")
$(left_line firewall.guestzone_fwd guest:wan "$why_tor")" "$(grep -e 'disarm left' "$T/log")"
is "G5 ... sidecar dropped"            "" "$(sev)"
g5 1 plain
is "G5 Tor on, the script does not name it: guestzone_fwd restored, @forwarding[0] left" "1 0" \
    "$(g firewall.guestzone_fwd.enabled) $(g 'firewall.@forwarding[0].enabled')"
is "G5 ... one line, for @forwarding[0]" "$(left_line 'firewall.@forwarding[0]' lan:wan "$why_tor")" \
    "$(grep -e 'disarm left' "$T/log")"
g5 1 missing
is "G5 Tor on, no Tor script: guestzone_fwd restored, @forwarding[0] left" "1 0" \
    "$(g firewall.guestzone_fwd.enabled) $(g 'firewall.@forwarding[0].enabled')"
is "G5 ... rc 0, and nothing on stdout or stderr from the missing file" "0:" "$rc:$(cat "$T/out")"
g5 0 mention
is "G5 Tor off, the script names it: both restored" "1 1" \
    "$(g firewall.guestzone_fwd.enabled) $(g 'firewall.@forwarding[0].enabled')"
hasnt "G5 ... nothing left disabled"   "disarm left" "$(logtext)"

echo "--- case G6: GL blocks all WAN for guest: guest -> wan and guest -> wan6 stay disabled, the rest returns"
reset fixture_gl_owned
ks_main arm > "$T/out" 2>&1
wan_block guest 0
g_disarm
is "G6 rc"                             0 "$rc"
is "G6 guest:wan and guest:wan6 left disabled" "0 0" \
    "$(g 'firewall.@forwarding[14].enabled') $(g firewall.guest_wan6.enabled)"
is "G6 ... with no write to either"    "" \
    "$(grep -F -e 'firewall.@forwarding[14].enabled=1' -e 'firewall.guest_wan6.enabled=1' "$T/uci-calls")"
is "G6 guest's others restored: awgclient, and wwan (a zone name GL's block never writes)" "1 1" \
    "$(g 'firewall.@forwarding[7].enabled') $(g firewall.guest_wwan.enabled)"
is "G6 lan and iot restored"           "1 1 1" \
    "$(g 'firewall.@forwarding[0].enabled') $(g firewall.lan_zerotier.enabled) $(g 'firewall.@forwarding[11].enabled')"
is "G6 sidecar dropped"                "" "$(sev)"
is "G6 the log: one line per section left, then the summary" \
    "$(left_line 'firewall.@forwarding[14]' guest:wan "$why_guest")
$(left_line firewall.guest_wan6 guest:wan6 "$why_guest")
$(sum_line 'lan:wan lan:zerotier guest:awgclient iot:wan guest:wan guest:wan6 guest:wwan')" "$(logtext)"
echo "  G6b: transfer_enable '1' (internet allowed): everything is restored"
reset fixture_gl_owned
ks_main arm > "$T/out" 2>&1
wan_block guest 1
g_disarm
is "G6b rc"                            0 "$rc"
is "G6b guest:wan and guest:wan6 restored" "1 1" \
    "$(g 'firewall.@forwarding[14].enabled') $(g firewall.guest_wan6.enabled)"
hasnt "G6b nothing left disabled"      "disarm left" "$(logtext)"
echo "  G6c: the key is per network: iot blocked, guest not"
reset fixture_gl_owned
ks_main arm > "$T/out" 2>&1
wan_block iot 0
g_disarm
is "G6c iot:wan left disabled; guest:wan and guest:wan6 restored" "0 1 1" \
    "$(g 'firewall.@forwarding[11].enabled') $(g 'firewall.@forwarding[14].enabled') $(g firewall.guest_wan6.enabled)"
is "G6c one line, naming iot" "$(left_line 'firewall.@forwarding[11]' iot:wan 'GL blocks internet access for iot')" \
    "$(grep -e 'disarm left' "$T/log")"

echo "--- case G7: the older gl-black_white_list.<net>.transfer_enable is not GL's block (TRAP control)"
# It reads '0' on live routers whose guest and iot are online. Taking it for the block would leave
# guest and iot offline after every disarm; with no <net>_transfer_enable section nothing is blocked.
reset fixture_gl_owned
ks_main arm > "$T/out" 2>&1
uci set gl-black_white_list.guest.transfer_enable=0
uci set gl-black_white_list.iot.transfer_enable=0
g_disarm
is "G7 rc"                             0 "$rc"
is "G7 guest:wan, guest:wan6 and iot:wan restored" "1 1 1" \
    "$(g 'firewall.@forwarding[14].enabled') $(g firewall.guest_wan6.enabled) $(g 'firewall.@forwarding[11].enabled')"
is "G7 sidecar dropped"                "" "$(sev)"
hasnt "G7 nothing left disabled"       "disarm left" "$(logtext)"

echo "--- case G8: GL's block never applies to lan, nor to a dest other than wan or wan6"
reset fixture_gl_owned
ks_main arm > "$T/out" 2>&1
wan_block lan 0
wan_block guest 0
g_disarm
is "G8 rc"                             0 "$rc"
is "G8 lan:wan restored: lan is never in that mode" 1 "$(g 'firewall.@forwarding[0].enabled')"
is "G8 guest:wwan restored: wwan is not wan or wan6" 1 "$(g firewall.guest_wwan.enabled)"
is "G8 non-vacuity: guest:wan and guest:wan6 left disabled in the same pass" "0 0" \
    "$(g 'firewall.@forwarding[14].enabled') $(g firewall.guest_wan6.enabled)"
hasnt "G8 no line names lan"           "(lan:" "$(logtext)"

echo "--- case G9: a restore that fails still keeps the record; a section left disabled is no failure"
reset fixture_mt3000
ks_main arm > "$T/out" 2>&1
tor_on
tor_sh plain
UCI_SET_FAIL="@forwarding[14].enabled=1"
g_disarm
UCI_SET_FAIL=""
is "G9 rc is 1"                        1 "$rc"
is "G9 the failed one stays severed, the one Tor manages stays disabled" "0 0" \
    "$(g 'firewall.@forwarding[14].enabled') $(g 'firewall.@forwarding[0].enabled')"
is "G9 the others restored"            "1 1 1" \
    "$(g firewall.lan_zerotier.enabled) $(g 'firewall.@forwarding[7].enabled') $(g 'firewall.@forwarding[11].enabled')"
is "G9 record kept for the retry"      "lan:wan lan:zerotier guest:awgclient iot:wan guest:wan" "$(sev)"
has "G9 the section Tor manages is reported as left, not failed" \
    "$(left_line 'firewall.@forwarding[0]' lan:wan "$why_tor")" "$(logtext)"
is "G9 every ERROR is about the failed write" "-t ts-fix ks: ERROR uci set 'firewall.@forwarding[14].enabled=1' failed - guest:wan stays severed
-t ts-fix ks: ERROR some forwardings could not be re-enabled - keeping the record (lan:wan lan:zerotier guest:awgclient iot:wan guest:wan) so the next disarm retries" \
    "$(grep -e ERROR "$T/log")"
g_disarm
is "G9 retry: rc 0"                    0 "$rc"
is "G9 retry: guest:wan restored, @forwarding[0] still disabled" "1 0" \
    "$(g 'firewall.@forwarding[14].enabled') $(g 'firewall.@forwarding[0].enabled')"
is "G9 retry: record dropped"          "" "$(sev)"
echo "  G9b: every recorded section left disabled: no firewall write at all, and the record goes"
reset fixture_484
ks_main arm > "$T/out" 2>&1
tor_on
tor_sh plain
wan_block guest 0
g_disarm
is "G9b rc"                            0 "$rc"
is "G9b lan:wan (Tor's) and guest:wan (GL's block) both left disabled" "0 0" \
    "$(g 'firewall.@forwarding[0].enabled') $(g 'firewall.@forwarding[1].enabled')"
is "G9b no enabled=1 write at all"     "" "$(grep -F '.enabled=1' "$T/uci-calls")"
is "G9b sidecar dropped"               "" "$(sev)"
is "G9b ... and that is committed"     "firewall
ts-fix" "$(commits)"
is "G9b the log: both lines, then the summary" \
    "$(left_line 'firewall.@forwarding[0]' lan:wan "$why_tor")
$(left_line 'firewall.@forwarding[1]' guest:wan "$why_guest")
$(sum_line 'lan:wan guest:wan')" "$(logtext)"
echo "  G9c: a section both features own is left disabled once, with one line"
reset fixture_484
uci set 'firewall.@forwarding[0].src=guest'
uci set 'firewall.@forwarding[1].src=lan'
ks_main arm > "$T/out" 2>&1
tor_on
tor_sh plain
wan_block guest 0
g_disarm
is "G9c rc"                            0 "$rc"
is "G9c guest:wan, @forwarding[0], left disabled; lan:wan restored" "0 1" \
    "$(g 'firewall.@forwarding[0].enabled') $(g 'firewall.@forwarding[1].enabled')"
is "G9c exactly one line, and only one" "$(left_line 'firewall.@forwarding[0]' guest:wan "$why_tor")" \
    "$(grep -e 'disarm left' "$T/log")"

echo "--- case G10: only disarm reads GL's Tor and WAN-block state; arm and the armed poll do not"
reset fixture_gl_owned
tor_on
tor_sh mention
wan_block guest 0
counters_reset
ks_main arm > "$T/out" 2>&1
ks_main check > "$T/out" 2>&1
is "G10 non-vacuity: armed, all three severed" "0 0 0" \
    "$(g 'firewall.@forwarding[0].enabled') $(g 'firewall.@forwarding[14].enabled') $(g firewall.guest_wan6.enabled)"
is "G10 neither read GL's state"       0 "$(grep -c -e 'tor\.global' -e 'gl-black_white_list' "$T/uci-calls")"

echo "--- case GK: KS_TOR_SCRIPT is its shipping value, defined once, never taken from the environment"
is "GK KS_TOR_SCRIPT, verbatim, defined once" 'KS_TOR_SCRIPT=/usr/bin/tor.sh' "$(grep -e 'KS_TOR_SCRIPT=' "$SRC")"
got=$(KS_TOR_SCRIPT="$T/evil-tor" TS_FIX_KS_NO_MAIN=1 /bin/sh -c '. "$1"; printf "%s" "$KS_TOR_SCRIPT"' _ "$SRC")
is "GK an environment value never replaces it" "/usr/bin/tor.sh" "$got"
tor_sh missing                                  # leave no Tor script behind for the cases below

echo "--- case 18: scope holes the zone model cannot close are warned about, once"
# Neither condition is rewritten — policy belongs to the user — but an armed engine must never
# report armed while lan/guest/iot traffic can leave through a path the severed forwardings do not
# cover. Stock GL has neither of these; a hand-built config can.
add_defaults_accept() { uci set 'firewall.@defaults[0]=defaults'; uci set 'firewall.@defaults[0].forward=ACCEPT'; }
add_accept_rule() {   # $1 = dest zone
    uci set 'firewall.@rule[3]=rule'
    uci set 'firewall.@rule[3].name=allow-out'
    uci set 'firewall.@rule[3].src=lan'
    uci set "firewall.@rule[3].dest=$1"
    uci set 'firewall.@rule[3].target=ACCEPT'
}

echo "  18a: global forward policy ACCEPT"
reset fixture_mt3000
add_defaults_accept
ks_main arm > "$T/out" 2>&1
has "18a warned"                       "scope hole" "$(logtext)"
has "18a names the condition"          "forward=ACCEPT" "$(logtext)"
if [ -f "$KS_SCOPEWARN" ]; then ok "18a fingerprint written"; else nok "18a fingerprint written" "file" "absent"; fi
counters_reset
ks_main check > "$T/out" 2>&1
is "18a standing hole does not respam a 5s poll" "" "$(logtext)"

echo "  18b: an enabled ACCEPT rule from lan to an uplink zone"
reset fixture_mt3000
add_accept_rule wan
ks_main arm > "$T/out" 2>&1
has "18b warned"                       "scope hole" "$(logtext)"
has "18b names the rule section"       "firewall.@rule[3]" "$(logtext)"
has "18b names the pair"               "lan -> wan" "$(logtext)"

echo "  18c: the same rule disabled is not a hole"
for spelling in 0 false; do
    reset fixture_mt3000
    add_accept_rule wan
    uci set "firewall.@rule[3].enabled=$spelling"
    ks_main arm > "$T/out" 2>&1
    hasnt "18c enabled='$spelling' is not warned about" "scope hole" "$(logtext)"
done

echo "  18c2: an enabled spelling the sweep would treat as live is warned about, not dropped"
# The warn side uses exactly the sweep's case-sensitive disabled set, so 'False' and 'OFF' are live
# here for the same reason the same spellings on a forwarding are live there.
for spelling in False OFF; do
    reset fixture_mt3000
    add_accept_rule wan
    uci set "firewall.@rule[3].enabled=$spelling"
    ks_main arm > "$T/out" 2>&1
    has "18c2 enabled='$spelling' is treated as live" "scope hole" "$(logtext)"
done

echo "  18d: a rule to a zone the kill switch does not cover is not a hole"
reset fixture_mt3000
add_accept_rule wgserver          # server-side VPN zone: classifies other, never severed
ks_main arm > "$T/out" 2>&1
hasnt "18d no warning for a non-egress dest" "scope hole" "$(logtext)"

echo "  18e: a clean config warns about nothing and leaves no fingerprint"
reset fixture_mt3000
uci set 'firewall.@defaults[0]=defaults'
uci set 'firewall.@defaults[0].forward=REJECT'
ks_main arm > "$T/out" 2>&1
hasnt "18e nothing warned"             "scope hole" "$(logtext)"
if [ -f "$KS_SCOPEWARN" ]; then nok "18e no fingerprint left" "absent" "file exists"; else ok "18e no fingerprint left"; fi

echo "  18f: a hole that appears is warned, and its removal is reported once"
reset fixture_mt3000
ks_main arm > "$T/out" 2>&1
counters_reset
add_defaults_accept                                  # the hole appears under a running engine
ks_main check > "$T/out" 2>&1
has "18f appearing hole warned"        "scope hole" "$(logtext)"
counters_reset
uci set 'firewall.@defaults[0].forward=REJECT'       # ... and is then closed
ks_main check > "$T/out" 2>&1
has "18f clearance reported"           "scope holes cleared" "$(logtext)"
if [ -f "$KS_SCOPEWARN" ]; then nok "18f fingerprint removed" "absent" "file exists"; else ok "18f fingerprint removed"; fi
counters_reset
ks_main check > "$T/out" 2>&1
is "18f and stays quiet afterwards"    "" "$(logtext)"

echo "  18g: dest '*' counts as a hole (fail-secure)"
reset fixture_mt3000
add_accept_rule '*'
ks_main arm > "$T/out" 2>&1
has "18g wildcard dest warned"         "any zone" "$(logtext)"

echo "  18h: an explicit arm re-states a standing hole; a poll does not"
reset fixture_mt3000
add_defaults_accept
ks_main arm > "$T/out" 2>&1
counters_reset
ks_main check > "$T/out" 2>&1
is "18h poll stays silent"             "" "$(logtext)"
counters_reset
ks_main arm > "$T/out" 2>&1
has "18h arm re-warns"                 "scope hole" "$(logtext)"

echo "  18j: a list-valued src or dest is reported, not silently missed"
# The uci fake cannot emit real list formatting, so this drives the shipped scan directly with a
# hand-built capture in the exact form uci prints a list option.
reset fixture_mt3000
_ks_show="firewall.@rule[9]=rule
firewall.@rule[9].src='lan' 'guest'
firewall.@rule[9].dest='wan'
firewall.@rule[9].target='ACCEPT'"
_ks_scope_warn
has "18j list-valued src warned"       "multi-valued" "$(logtext)"
has "18j names the section"            "firewall.@rule[9]" "$(logtext)"
counters_reset; rm -f "$KS_SCOPEWARN"
_ks_show="firewall.@rule[9]=rule
firewall.@rule[9].src='lan'
firewall.@rule[9].dest='wan' 'wan6'
firewall.@rule[9].target='ACCEPT'"
_ks_scope_warn
has "18j list-valued dest warned"      "multi-valued" "$(logtext)"
counters_reset; rm -f "$KS_SCOPEWARN"
_ks_show="firewall.@rule[9]=rule
firewall.@rule[9].src='lan' 'guest'
firewall.@rule[9].dest='wan'
firewall.@rule[9].target='ACCEPT'
firewall.@rule[9].enabled='0'"
_ks_scope_warn
hasnt "18j but a disabled one is not"  "multi-valued" "$(logtext)"

echo "  18k: a changed hole set is re-stated in full, with no spurious clearance"
reset fixture_mt3000
add_defaults_accept                                    # hole set {A}
ks_main arm > "$T/out" 2>&1
is "18k {A} logs one condition"        1 "$(grep -c 'scope hole' "$T/log")"
counters_reset
add_accept_rule wan                                    # -> {A,B}
ks_main check > "$T/out" 2>&1
is "18k {A}->{A,B} re-states both"     2 "$(grep -c 'scope hole' "$T/log")"
hasnt "18k no spurious clearance"      "scope holes cleared" "$(logtext)"
counters_reset
uci set 'firewall.@defaults[0].forward=REJECT'         # -> {B}
ks_main check > "$T/out" 2>&1
is "18k {A,B}->{B} logs the survivor"  1 "$(grep -c 'scope hole' "$T/log")"
hasnt "18k still no clearance"         "scope holes cleared" "$(logtext)"
counters_reset
ks_main check > "$T/out" 2>&1
is "18k then goes quiet"               0 "$(grep -c 'scope hole' "$T/log")"

echo "  18i: the clean armed poll costs ONE extra external and reads the config once"
reset fixture_mt3000
ks_main arm > "$T/out" 2>&1
IP4_DEFAULT="default via 192.168.8.1 dev eth0 proto static"
UBUS_DUMP="eth0 wan"
counters_reset
ks_main check > "$T/out" 2>&1
is "18i no live defaults read"    0 "$(grep -cF 'firewall.@defaults[0].forward' "$T/uci-calls")"
is "18i one awk pass"             1 "$(wc -l < "$T/ext-calls" | tr -d ' ')"
is "18i exactly one uci show"     1 "$(grep -cF 'uci show firewall' "$T/uci-calls")"
is "18i no logger output"         "" "$(logtext)"
is "18i still zero commits"       "" "$(commits)"

# =============================================================================================
# The iot source zone. GL creates an iot network from ROM uci-defaults since firmware 4.9.0
# (disabled by default; absent on 4.8.4) and treats it as LAN-class, so the zone layer covers it
# like guest: KS_SRC_ZONES="lan guest iot". Any other source zone stays out of scope.

echo "--- case I1: iot -> wan is severed on arm, recorded, re-severed by check, restored on disarm"
reset fixture_mt3000
ks_main arm > "$T/out" 2>&1; rc=$?
is "I1 arm rc"                         0 "$rc"
is "I1 iot:wan severed"                0 "$(g 'firewall.@forwarding[11].enabled')"
if ks_pair_in "$(sev)" iot:wan; then ok "I1 iot:wan recorded in the sidecar"
else nok "I1 iot:wan recorded in the sidecar" "a sidecar holding iot:wan" "$(sev)"; fi
has "I1 the arm summary names it"      "iot:wan" "$(logtext)"
counters_reset
uci set 'firewall.@forwarding[11].enabled=1'     # the forwarding came back while armed
ks_main check > "$T/out" 2>&1; rc=$?
is "I1 check rc"                       0 "$rc"
is "I1 check re-severs it"             0 "$(g 'firewall.@forwarding[11].enabled')"
has "I1 and says so"                   "re-severed iot:wan" "$(logtext)"
counters_reset
ks_main disarm > "$T/out" 2>&1; rc=$?
is "I1 disarm rc"                      0 "$rc"
is "I1 iot:wan restored"               1 "$(g 'firewall.@forwarding[11].enabled')"
is "I1 sidecar deleted"                "" "$(sev)"

echo "--- case I2: a scope hole from iot is warned about, and the forward-policy warning names iot"
reset fixture_mt3000
add_accept_rule wan
uci set 'firewall.@rule[3].src=iot'
ks_main arm > "$T/out" 2>&1
has "I2 an enabled ACCEPT rule iot -> wan is a hole" "scope hole" "$(logtext)"
has "I2 the warning names the rule's zones" "ACCEPT iot -> wan" "$(logtext)"
has "I2 and the pair it bypasses"      "severed forwarding for iot:wan" "$(logtext)"
reset fixture_mt3000
add_defaults_accept
ks_main arm > "$T/out" 2>&1
has "I2 the forward-policy warning names iot" "passes lan/guest/iot traffic" "$(logtext)"

echo "--- case I3: the runtime invariant severs an iot forwarding into an uplink the seed misses"
# Only the invariant can catch this one: usbzone's network (usb0) is not in the seed vocabulary, so
# the sweep classifies the zone "other" and passes it by.
reset fixture_unseeded_uplink
uci set firewall.iot=zone
uci set firewall.iot.name=iot
uci set firewall.iot.network=iot
uci set firewall.iot_usb=forwarding
uci set firewall.iot_usb.src=iot
uci set firewall.iot_usb.dest=usbzone
uci set firewall.iot_usb.enabled=1
IP4_DEFAULT="default via 10.9.9.1 dev usb0 proto static metric 20"
UBUS_DUMP="usb0 usb0"
counters_reset
ks_main check > "$T/out" 2>&1; rc=$?
is "I3 rc"                             0 "$rc"
is "I3 iot -> usbzone severed"         0 "$(g firewall.iot_usb.enabled)"
is "I3 and recorded"                   "lan:wan lan:usbzone iot:usbzone" "$(sev)"
has "I3 the invariant names it"        "INVARIANT severed iot:usbzone" "$(logtext)"

echo "--- case I4: an iot sever that cannot be written is an ERROR naming the iot pair"
reset fixture_mt3000
UCI_SET_FAIL="@forwarding[11].enabled=0"
ks_main arm > "$T/out" 2>&1; rc=$?
is "I4 rc is 1"                        1 "$rc"
has "I4 the ERROR names the zone and the pair" "iot egress via iot:wan is still open" "$(grep ERROR "$T/log")"
is "I4 the others are still severed"   0 "$(g 'firewall.@forwarding[14].enabled')"

echo "--- case I5: a 4.8.4-shaped config (no iot network, no iot zone) arms exactly as before"
reset fixture_484
cp "$STATE" "$T/unarmed"
ks_main arm > "$T/out" 2>&1; rc=$?
is "I5 arm rc"                         0 "$rc"
is "I5 exactly lan:wan and guest:wan recorded" "lan:wan guest:wan" "$(sev)"
hasnt "I5 no iot pair in the log"      "iot:" "$(logtext)"
hasnt "I5 no ERROR logged"             "ERROR" "$(logtext)"
counters_reset
ks_main check > "$T/out" 2>&1; rc=$?
is "I5 the armed poll is steady: rc"   0 "$rc"
is "I5 ... and commits nothing"        "" "$(commits)"
counters_reset
ks_main disarm > "$T/out" 2>&1; rc=$?
is "I5 disarm rc"                      0 "$rc"
if cmp -s "$T/unarmed" "$STATE"; then ok "I5 the arm/disarm round trip leaves the config byte-identical"
else nok "I5 the arm/disarm round trip leaves the config byte-identical" "identical" "state differs"; fi

echo "--- case I6: an iot forwarding the user already disabled is left alone and never recorded"
for spelling in 0 false off no; do
    reset fixture_mt3000
    uci set "firewall.@forwarding[11].enabled=$spelling"
    ks_main arm > "$T/out" 2>&1
    is "I6 '$spelling': arm leaves it as-is"   "$spelling" "$(g 'firewall.@forwarding[11].enabled')"
    if ks_pair_in "$(sev)" iot:wan; then nok "I6 '$spelling': never recorded" "no iot:wan" "$(sev)"
    else ok "I6 '$spelling': never recorded"; fi
    ks_main check > "$T/out" 2>&1
    ks_main disarm > "$T/out" 2>&1
    is "I6 '$spelling': still as-is after check and disarm" "$spelling" "$(g 'firewall.@forwarding[11].enabled')"
done

echo "--- case I7: only the named source zones are covered — not a near-miss name, not an empty src"
reset fixture_mt3000
uci set firewall.iot2=zone
uci set firewall.iot2.name=iot2
uci set firewall.iot2.network=iot2
uci set firewall.iot2_wan=forwarding
uci set firewall.iot2_wan.src=iot2
uci set firewall.iot2_wan.dest=wan
uci set firewall.iot2_wan.enabled=1
uci set firewall.nosrc_wan=forwarding
uci set firewall.nosrc_wan.dest=wan
uci set firewall.nosrc_wan.enabled=1
ks_main arm > "$T/out" 2>&1
is "I7 iot2 -> wan left alone"         1 "$(g firewall.iot2_wan.enabled)"
is "I7 a forwarding with no src left alone" 1 "$(g firewall.nosrc_wan.enabled)"
if ks_pair_in "$(sev)" iot2:wan || ks_pair_in "$(sev)" :wan; then
    nok "I7 neither recorded" "no iot2:wan, no :wan" "$(sev)"
else ok "I7 neither recorded"; fi
for s in iot2 ''; do
    reset fixture_mt3000
    add_accept_rule wan
    uci set "firewall.@rule[3].src=$s"           # '' deletes the option, as real uci does
    ks_main arm > "$T/out" 2>&1
    hasnt "I7 an ACCEPT rule from '${s:-<no src>}' is not a covered hole" "scope hole" "$(logtext)"
done

# =============================================================================================
# The rule layer: "iif br-lan|br-guest|br-iot priority 5279 lookup 100" per family, in front of an
# "unreachable default" route in table 100. It survives the firewall restart that erases the zone
# layer; netifd's start erases it, and leaves the zone layer standing.

echo "--- case R1: ensure on an empty model adds the whole rule layer, in one exact call list"
# The state netifd's start leaves: every policy rule gone, table 100 empty too.
reset fixture_mt3000
_ks_rules_ensure > "$T/out" 2>&1; rc=$?
is "R1 rc"                             0 "$rc"
is "R1 exact ip call list"             "$(ensure_expect_empty)" "$(ipcalls)"
is "R1 six rules and two routes"       "$(layer_state)" "$(ipstate)"
is "R1 one log line"                   1 "$(grep -c . "$T/log")"
has "R1 it names a rule it added"      "-6 iif br-iot" "$(logtext)"
has "R1 and a route it added"          "-4 unreachable default" "$(logtext)"

echo "--- case R2: ensure with everything present: 6 ip calls (4 rules/routes, 2 swap), no adds, no log"
reset fixture_mt3000
seed_layer
cp "$IPSTATE" "$T/ip-before"
_ks_rules_ensure > "$T/out" 2>&1; rc=$?
is "R2 rc"                             0 "$rc"
is "R2 exactly the six reads"          "$(ensure_expect_present)" "$(ipcalls)"
if cmp -s "$T/ip-before" "$IPSTATE"; then ok "R2 model unchanged"; else nok "R2 model unchanged" "no adds" "model differs"; fi
is "R2 silent"                         "" "$(logtext)"

echo "--- case R3: a partial layer gets exactly the one missing add"
reset fixture_mt3000
layer_records | grep -vxF 'R|-4|5279|br-guest|lookup 100' >> "$IPSTATE"
_ks_rules_ensure > "$T/out" 2>&1; rc=$?
is "R3 rc"                             0 "$rc"
is "R3 exactly that one add"           "-4 rule add iif br-guest priority 5279 lookup 100" "$(grep ' add ' "$T/ip-calls")"
is "R3 six reads + one add"            7 "$(grep -c . "$T/ip-calls")"
is "R3 layer complete"                 "$(layer_state)" "$(ipstate)"
has "R3 the log names it"              "-4 iif br-guest" "$(logtext)"
hasnt "R3 and nothing else"            "br-lan" "$(logtext)"

echo "--- case R4: a [detached] br-iot rule (bridge absent, iot disabled) counts as present"
reset fixture_mt3000
seed_layer
IP_ABSENT_DEVS="br-iot"
has "R4 non-vacuity: the fake lists it [detached]" "iif br-iot [detached] lookup 100" "$(ip -4 rule list priority 5279)"
counters_reset
_ks_rules_ensure > "$T/out" 2>&1; rc=$?
is "R4 rc"                             0 "$rc"
is "R4 exactly the six reads"          "$(ensure_expect_present)" "$(ipcalls)"
is "R4 silent"                         "" "$(logtext)"

echo "--- case R5: a foreign 'lookup 1002' rule at 5279 is not ours; ours is added beside it"
# GL's WireGuard client uses table 1002 on real routers. Taking that for ours — a substring match
# on "lookup 100" would — leaves br-lan outside the rule layer.
reset fixture_mt3000
layer_records | grep -vxF 'R|-4|5279|br-lan|lookup 100' >> "$IPSTATE"
seed 'R|-4|5279|br-lan|lookup 1002'
_ks_rules_ensure > "$T/out" 2>&1; rc=$?
is "R5 rc"                             0 "$rc"
is "R5 our br-lan rule added"          "-4 rule add iif br-lan priority 5279 lookup 100" "$(grep ' add ' "$T/ip-calls")"
is "R5 the foreign rule untouched, ours beside it" "$( (layer_records; echo 'R|-4|5279|br-lan|lookup 1002') | sort)" "$(ipstate)"

echo "--- case R5b: an add that fails is an ERROR (the rule layer is incomplete) and rc 1"
reset fixture_mt3000
IP_ADD_FAIL="-6 rule add iif br-guest"
_ks_rules_ensure > "$T/out" 2>&1; rc=$?
is "R5b rc is 1"                       1 "$rc"
has "R5b ERROR logged"                 "ERROR" "$(logtext)"
has "R5b it says incomplete"           "incomplete" "$(logtext)"
has "R5b and names what failed"        "-6 iif br-guest" "$(grep ERROR "$T/log")"
is "R5b every other piece still added" "$(layer_records | grep -vxF 'R|-6|5279|br-guest|lookup 100' | sort)" "$(ipstate)"
# The same failure reached through the subcommands: rc 1 from arm and check alike. An arm whose
# rule layer is incomplete also keeps any 5280 rules, like every other arm that is not rc 0.
reset fixture_mt3000
seed 'R|-4|5280|br-lan|lookup 100'
IP_ADD_FAIL="-4 route add"
ks_main arm > "$T/out" 2>&1; rc=$?
is "R5b arm rc is 1"                   1 "$rc"
is "R5b arm kept the 5280 rule"        "" "$(grep ' del ' "$T/ip-calls")"
counters_reset
ks_main check > "$T/out" 2>&1; rc=$?
is "R5b check rc is 1"                 1 "$rc"

echo "--- case R6: a re-arm that changes nothing in the zone still re-asserts the rule layer"
# netifd's start wipes every policy rule but leaves the flash-persisted zone layer standing, so a
# re-arm there has nothing to commit and must still bring the rules back. The same arm drops the
# pre-v1.0.21 layout at 5280 and only that: 5279 stays, and GL's own 5280 blackhole (same priority,
# no table lookup) is not ours to touch.
reset fixture_mt3000
ks_main arm > "$T/out" 2>&1
: > "$IPSTATE"
seed 'R|-4|5280|br-lan|lookup 100' 'R|-6|5280|br-guest|lookup 100' 'R|-4|5280|br-lan|blackhole'
counters_reset
ks_main arm > "$T/out" 2>&1; rc=$?
is "R6 rc"                             0 "$rc"
is "R6 nothing committed"              "" "$(commits)"
is "R6 zero reloads"                   0 "$(reloads)"
is "R6 5279 back, 5280 layout gone, GL's blackhole kept" "$( (layer_records; echo 'R|-4|5280|br-lan|blackhole') | sort)" "$(ipstate)"
is "R6 no 5279 delete issued"          "" "$(grep ' del .*priority 5279' "$T/ip-calls")"
has "R6 the 5280 deletes are lookup-qualified" "-6 rule del iif br-guest priority 5280 lookup 100" "$(ipcalls)"
hasnt "R6 no route delete either"      "route del" "$(ipcalls)"

echo "--- case R7: an arm whose zone commit fails still ensures the rule layer and keeps 5280"
reset fixture_mt3000
seed 'R|-4|5280|br-lan|lookup 100'
UCI_COMMIT_FAIL=1
ks_main arm > "$T/out" 2>&1; rc=$?
is "R7 rc is 1"                        1 "$rc"
is "R7 rule layer ensured, 5280 kept"  "$( (layer_records; echo 'R|-4|5280|br-lan|lookup 100') | sort)" "$(ipstate)"
is "R7 nothing deleted"                "" "$(grep ' del ' "$T/ip-calls")"
has "R7 the log says so"               "ensuring the rule layer anyway" "$(logtext)"

echo "--- case R9: disarm takes the rule layer down BEFORE any forwarding is restored"
# An interrupted disarm must leave the zone severed with its record intact — check's lost-disarm
# backstop finishes that — never a restored zone with no record and the rules still blackholing
# the LAN. uci calls, ip calls and reloads share one sequence log, so the order is read directly.
reset fixture_mt3000
ks_main arm > "$T/out" 2>&1
counters_reset
ks_main disarm > "$T/out" 2>&1; rc=$?
is "R9 rc"                             0 "$rc"
last_rm=$(seqlast '^ip -[46] (rule|route) del ')
first_restore=$(seqline '^uci set .*\.enabled=1$')
first_commit=$(seqline '^uci commit ')
if [ -n "$last_rm" ] && [ -n "$first_restore" ] && [ -n "$first_commit" ]; then
    ok "R9 non-vacuity: deletes, a restore and a commit all happened"
else
    nok "R9 non-vacuity: deletes, a restore and a commit all happened" "three line numbers" "[$last_rm] [$first_restore] [$first_commit]"
fi
if [ "${last_rm:-999999}" -lt "${first_restore:-0}" ]; then ok "R9 every delete precedes the first restore"
else nok "R9 every delete precedes the first restore" "last delete line < first restore line" "$last_rm vs $first_restore"; fi
if [ "${last_rm:-999999}" -lt "${first_commit:-0}" ]; then ok "R9 every delete precedes the zone commit"
else nok "R9 every delete precedes the zone commit" "last delete line < first commit line" "$last_rm vs $first_commit"; fi
is "R9 rule layer gone"                "" "$(ipstate)"
is "R9 zone restored"                  1 "$(g 'firewall.@forwarding[0].enabled')"

echo "--- case R10: the disarmed poll probes once for a stranded rule layer"
# A lost disarm on a router whose zone layer recorded nothing, or a lock-free rules-ensure that
# re-adds the rules just after a disarm removed them, leaves the rule layer behind with the sidecar
# empty: a LAN blackhole with the kill switch off that the sidecar backstop cannot see. One v4 rule
# list per poll is the whole cost of catching it.
reset fixture_mt3000
uci set ts-fix.settings.kill_switch=0
seed_layer
cp "$STATE" "$T/before"
counters_reset
ks_main check > "$T/out" 2>&1; rc=$?
is "R10 rc"                            0 "$rc"
is "R10 the probe comes first"         "-4 rule list priority 5279" "$(head -n 1 "$T/ip-calls")"
is "R10 and runs once"                 1 "$(grep -c ' rule list ' "$T/ip-calls")"
is "R10 our layer removed"             "" "$(ipstate)"
is "R10 one log line"                  1 "$(grep -c . "$T/log")"
has "R10 which says so"                "rule layer found with no armed intent - removed" "$(logtext)"
if cmp -s "$T/before" "$STATE"; then ok "R10 no uci writes"; else nok "R10 no uci writes" "no writes" "state differs"; fi
is "R10 zero commits"                  "" "$(commits)"
echo "  R10b: a lone [detached] br-iot rule is ours too"
reset fixture_mt3000
uci set ts-fix.settings.kill_switch=0
seed 'R|-4|5279|br-iot|lookup 100'
IP_ABSENT_DEVS="br-iot"
counters_reset
ks_main check > "$T/out" 2>&1
is "R10b removed"                      "" "$(ipstate)"
has "R10b logged"                      "no armed intent" "$(logtext)"
echo "  R10c: only a foreign rule at 5279 — untouched, silent, one call"
reset fixture_mt3000
uci set ts-fix.settings.kill_switch=0
seed 'R|-4|5279|br-lan|lookup 1002'
cp "$IPSTATE" "$T/ip-before"
counters_reset
ks_main check > "$T/out" 2>&1
is "R10c exactly the one probe"        "-4 rule list priority 5279" "$(ipcalls)"
if cmp -s "$T/ip-before" "$IPSTATE"; then ok "R10c foreign rule untouched"; else nok "R10c foreign rule untouched" "unchanged" "model differs"; fi
is "R10c silent"                       "" "$(logtext)"
echo "  R10d: nothing present — one ip call, zero writes"
reset fixture_mt3000
uci set ts-fix.settings.kill_switch=0
cp "$STATE" "$T/before"
counters_reset
ks_main check > "$T/out" 2>&1
is "R10d exactly the one probe"        "-4 rule list priority 5279" "$(ipcalls)"
if cmp -s "$T/before" "$STATE"; then ok "R10d no uci writes"; else nok "R10d no uci writes" "no writes" "state differs"; fi
is "R10d zero commits"                 "" "$(commits)"
is "R10d zero reloads"                 0 "$(reloads)"
is "R10d silent"                       "" "$(logtext)"

echo "--- case R11: an armed check ensures the rule layer after the zone work"
reset fixture_mt3000                    # intent on, nothing severed yet: this check does it all
counters_reset
ks_main check > "$T/out" 2>&1; rc=$?
is "R11 rc"                            0 "$rc"
is "R11 rule layer in place"           "$(layer_state)" "$(ipstate)"
last_zone=$(seqlast '^(uci commit |reload$)')
first_add=$(seqline '^ip -[46] (rule|route) add ')
if [ -n "$last_zone" ] && [ -n "$first_add" ]; then ok "R11 non-vacuity: zone commit and rule adds both happened"
else nok "R11 non-vacuity: zone commit and rule adds both happened" "two line numbers" "[$last_zone] [$first_add]"; fi
if [ "${first_add:-0}" -gt "${last_zone:-999999}" ]; then ok "R11 rules added after the zone commit and reload"
else nok "R11 rules added after the zone commit and reload" "first add line > last commit/reload line" "$first_add vs $last_zone"; fi
echo "  R11b: after netifd wiped the rulebase, the next armed poll restores it with no zone writes"
: > "$IPSTATE"
cp "$STATE" "$T/before"
counters_reset
ks_main check > "$T/out" 2>&1; rc=$?
is "R11b rc"                           0 "$rc"
is "R11b rule layer back"              "$(layer_state)" "$(ipstate)"
if cmp -s "$T/before" "$STATE"; then ok "R11b no uci writes"; else nok "R11b no uci writes" "no writes" "state differs"; fi
is "R11b zero commits"                 "" "$(commits)"
is "R11b zero reloads"                 0 "$(reloads)"

echo "--- case R12: rules-ensure self-gates on intent and mode, and writes no config"
reset fixture_mt3000
uci set ts-fix.settings.kill_switch=0
counters_reset
ks_main rules-ensure > "$T/out" 2>&1; rc=$?
is "R12 intent off: rc 0"              0 "$rc"
is "R12 intent off: zero ip calls"     "" "$(ipcalls)"
reset fixture_mt3000
uci set glconfig.general.mode=extender
counters_reset
ks_main rules-ensure > "$T/out" 2>&1; rc=$?
is "R12 mode refused: rc 0"            0 "$rc"
is "R12 mode refused: zero ip calls"   "" "$(ipcalls)"
reset fixture_mt3000
rm -f "$KS_LOCK"
cp "$STATE" "$T/before"
counters_reset
ks_main rules-ensure > "$T/out" 2>&1; rc=$?
is "R12 armed: rc 0"                   0 "$rc"
is "R12 armed: rule layer added"       "$(layer_state)" "$(ipstate)"
if cmp -s "$T/before" "$STATE"; then ok "R12 armed: no uci writes"; else nok "R12 armed: no uci writes" "no writes" "state differs"; fi
is "R12 armed: zero commits"           "" "$(commits)"
is "R12 armed: zero reloads"           0 "$(reloads)"
if [ -e "$KS_LOCK" ]; then nok "R12 the engine lock was never taken" "no lock file" "lock file created"
else ok "R12 the engine lock was never taken"; fi

echo "--- case R13: removal repeats each delete until it misses, at most 5 times per spec"
# A kernel that accepts an identical rule twice can hold a twin — from two concurrent ensures
# there, or already present — and one delete per spec would leave it blocking with the switch
# off. A kernel that refuses identical adds (EEXIST, as the model does) never creates one; the
# twins here are seeded directly.
reset fixture_mt3000
seed 'R|-4|5279|br-lan|lookup 100' 'R|-4|5279|br-lan|lookup 100'
ks_main rules-clean > "$T/out" 2>&1; rc=$?
is "R13 rc"                            0 "$rc"
is "R13 both copies gone"              "" "$(ipstate)"
is "R13 two hits then one miss"        3 "$(grep -cxF -e '-4 rule del iif br-lan priority 5279 lookup 100' "$T/ip-calls")"
reset fixture_mt3000
i=0
while [ "$i" -lt 7 ]; do seed 'R|-6|5280|br-guest|lookup 100'; i=$((i + 1)); done
ks_main rules-clean > "$T/out" 2>&1
is "R13 the loop stops at 5 attempts"  5 "$(grep -cxF -e '-6 rule del iif br-guest priority 5280 lookup 100' "$T/ip-calls")"
is "R13 so 2 of 7 survive (the cap is real)" 2 "$(grep -cxF -e 'R|-6|5280|br-guest|lookup 100' "$IPSTATE")"

echo "--- case R14: removal never touches GL's 5280 blackhole or a foreign rule at 5279"
# Every delete is qualified "lookup 100": GL 4.9's own kill switch is a 5280 blackhole, and GL's
# WireGuard client routes through table 1002.
reset fixture_mt3000
uci set glconfig.general.mode=extender          # arm refused -> the full removal runs
seed 'R|-4|5280|br-lan|blackhole' 'R|-4|5279|br-lan|lookup 1002' 'R|-6|5279|br-guest|lookup 1002'
cp "$IPSTATE" "$T/ip-before"
ks_main arm > "$T/out" 2>&1
has "R14 non-vacuity: the removal ran" "rule del iif br-lan priority 5280 lookup 100" "$(ipcalls)"
if cmp -s "$T/ip-before" "$IPSTATE"; then ok "R14 all three survive"; else nok "R14 all three survive" "unchanged" "model differs"; fi

echo "--- case R15: the rule matcher leaves the caller's IFS as it found it, on both exits"
# It re-splits with its own IFS; a leak would make every later "for br in \$KS_RULE_IIFS" in the
# same run iterate once over the whole list.
ifs_before="$IFS"
_ks_rule_ours "$(printf '5279:\tfrom all iif br-lan lookup 100')" br-lan; r1=$?
is "R15 a match returns 0"             0 "$r1"
if [ "$IFS" = "$ifs_before" ]; then ok "R15 IFS intact after a match"; else nok "R15 IFS intact after a match" "the default IFS" "changed"; fi
_ks_rule_ours "$(printf '5279:\tfrom all iif br-lan lookup 1002')" br-lan; r2=$?
is "R15 a miss returns 1"              1 "$r2"
if [ "$IFS" = "$ifs_before" ]; then ok "R15 IFS intact after a miss"; else nok "R15 IFS intact after a miss" "the default IFS" "changed"; fi
IFS="$ifs_before"

echo "--- case R16: an add that loses a race to a concurrent ensure is not an incomplete layer"
# rules-ensure takes no lock, and a kernel that refuses an identical add (EEXIST) fails the second
# of two concurrent adds. IP_ADD_RACE has the model play the winner: it inserts the item just
# before refusing the engine's own add of it. One re-read settles it, and costs one more read for
# that family only.
reset fixture_mt3000
IP_ADD_RACE="-4 rule add iif br-guest"
_ks_rules_ensure > "$T/out" 2>&1; rc=$?
is "R16 rc 0"                          0 "$rc"
hasnt "R16 no ERROR"                   "ERROR" "$(logtext)"
is "R16 the raced rule is there exactly once" 1 "$(grep -cxF -e 'R|-4|5279|br-guest|lookup 100' "$IPSTATE")"
is "R16 the whole layer is in place"   "$(layer_state)" "$(ipstate)"
is "R16 exactly one extra v4 rule list" 2 "$(grep -cxF -e '-4 rule list priority 5279' "$T/ip-calls")"
is "R16 and no extra v6 one"           1 "$(grep -cxF -e '-6 rule list priority 5279' "$T/ip-calls")"
hasnt "R16 the log does not claim the winner's add" "-4 iif br-guest" "$(logtext)"
echo "  R16b: the same race on the route"
reset fixture_mt3000
IP_ADD_RACE="-6 route add"
_ks_rules_ensure > "$T/out" 2>&1; rc=$?
is "R16b rc 0"                         0 "$rc"
hasnt "R16b no ERROR"                  "ERROR" "$(logtext)"
is "R16b the raced route is there exactly once" 1 "$(grep -cxF -e 'U|-6|100' "$IPSTATE")"
is "R16b the whole layer is in place"  "$(layer_state)" "$(ipstate)"
is "R16b exactly one extra v6 route show" 2 "$(grep -cxF -e '-6 route show table 100' "$T/ip-calls")"
is "R16b and no extra v4 one"          1 "$(grep -cxF -e '-4 route show table 100' "$T/ip-calls")"
echo "  R16c: through arm, a lost race is still rc 0 (so reapply logs no 'may NOT be effective')"
reset fixture_mt3000
IP_ADD_RACE="-4 rule add iif br-lan"
ks_main arm > "$T/out" 2>&1; rc=$?
is "R16c arm rc 0"                     0 "$rc"
hasnt "R16c no ERROR"                  "ERROR" "$(logtext)"

echo "--- case R17: a kernel with no IPv6 stack gets an IPv4-only rule layer, quietly"
# With no /proc/sys/net/ipv6 every ip -6 call fails, so the v6 half would log an ERROR on every 5s
# poll for nothing: with no IPv6 stack there is no IPv6 forwarding to protect.
reset fixture_mt3000
KS_IPV6_PROC="$T/no-ipv6-stack"
_ks_rules_ensure > "$T/out" 2>&1; rc=$?
is "R17 ensure rc 0"                   0 "$rc"
hasnt "R17 ensure logs no ERROR"       "ERROR" "$(logtext)"
is "R17 ensure makes exactly the -4 calls" "$(ensure_expect_empty | grep -e '^-4 ')" "$(ipcalls)"
is "R17 the three v4 rules and the v4 route" "$(layer_records | grep -F -e '|-4|' | sort)" "$(ipstate)"
reset fixture_mt3000
KS_IPV6_PROC="$T/no-ipv6-stack"
ks_main rules-clean > "$T/out" 2>&1; rc=$?
is "R17 remove rc 0"                   0 "$rc"
is "R17 remove issues only the -4 deletes" "$(rules_clean_expect | grep -e '^-4 ')" "$(ipcalls)"
reset fixture_mt3000
KS_IPV6_PROC="$T/no-ipv6-stack"
ks_main arm > "$T/out" 2>&1; rc=$?
is "R17 arm rc 0"                      0 "$rc"
is "R17 arm makes no -6 call at all (ensure and the 5280 drop)" "" "$(grep -e '^-6 ' "$T/ip-calls")"
hasnt "R17 arm logs no ERROR"          "ERROR" "$(logtext)"

# =============================================================================================
# The source-rule swap. Whenever a Custom Exit Node is set and the guest (or, on 4.9+, iot) network
# is enabled, GL's gl_tailscale adds "from <net> table main" with no priority. It lands at 0 and
# sends that network's traffic through the main table to the real uplink, so 5279 is never
# consulted for it. While armed, the engine deletes that rule and ensures "to <net> lookup main
# priority 0" instead — the swap Route Guest already makes for guest. Every path that takes the
# rule layer down undoes it, re-adding GL's rule only under GL's own condition. KS_SWAP_MARK
# records one "<zone> <NET/PFX>" line per network the swap touched.

echo "--- case SV: the CIDR validator takes exactly canonical a.b.c.d/p with a prefix of 8-32"
# The floor: a "to <net> lookup main" rule at priority 0 routes every destination in <net> around
# 5270/5279, so a /0 from a corrupted address would switch the rule layer off for all traffic. No
# leading zero anywhere: iproute2 reads 010 as octal 8 (u3-runs/netns-probe2.out), so such a string
# would not name the network ip acts on.
if command -v _ks_cidr_ok >/dev/null 2>&1; then ok "SV the validator exists (so the refusals below are not vacuous)"
else nok "SV the validator exists (so the refusals below are not vacuous)" "_ks_cidr_ok defined" "not found"; fi
for c in 192.168.160.0/23 10.0.0.0/8 0.0.0.0/8 255.255.255.255/32 192.168.10.0/24 1.2.3.4/9 100.64.0.0/10; do
    if _ks_cidr_ok "$c" 2>/dev/null; then ok "SV accepts $c"; else nok "SV accepts $c" "rc 0" "refused"; fi
done
for c in 0.0.0.0/0 10.0.0.0/7 1.2.3.4/33 256.1.1.0/24 1.2.3.256/24 192.168.010.0/24 192.168.10.0/024 \
         192.168.10.0/08 00.1.2.3/24 1.2.3/24 1.2.3.4.5/24 1..3.4/24 .1.2.3/24 1.2.3.4 1.2.3.4/ /24 \
         1.2.3.4/24/1 a.b.c.d/24 1.2.3.4/2x 1.2.3.x/24 -1.2.3.4/24 '' ' 1.2.3.4/24' '1.2.3.4/24 ' \
         1.2.3.4/+24 0x1.2.3.4/24 1.2.3.4/2.4 '1.2.3.4/24
'; do
    if _ks_cidr_ok "$c" 2>/dev/null; then nok "SV refuses '$c'" "rc 1" "accepted"; else ok "SV refuses '$c'"; fi
done

echo "--- case SK: the swap's constants are the brief's values, defined once, never taken from the environment"
# R1 fixes the values; D-b makes KS_IPCALC a plain constant, so no executable path can come from the
# environment (this harness overrides it after sourcing). Case 17's lint rewrites these very lines,
# so it cannot see a ${KS_IPCALC:-...} form; this case reads them as they ship.
is "SK KS_SWAP_ZONES, verbatim"        'KS_SWAP_ZONES="guest:br-guest iot:br-iot"' "$(grep -e '^KS_SWAP_ZONES=' "$SRC")"
is "SK KS_SWAP_MARK, verbatim"         'KS_SWAP_MARK=/tmp/ts-fix-ks.srcswap' "$(grep -e '^KS_SWAP_MARK=' "$SRC")"
is "SK KS_IPCALC, verbatim"            'KS_IPCALC=/bin/ipcalc.sh' "$(grep -e '^KS_IPCALC=' "$SRC")"
is "SK nothing else assigns any of them" "1 1 1" \
    "$(grep -c -e 'KS_SWAP_ZONES=' "$SRC") $(grep -c -e 'KS_SWAP_MARK=' "$SRC") $(grep -c -e 'KS_IPCALC=' "$SRC")"
# The same by behaviour: source the engine in a child shell whose environment offers other paths.
# Sourcing runs nothing but assignments and definitions (TS_FIX_KS_NO_MAIN=1).
got=$(KS_IPCALC="$T/evil-ipcalc" KS_SWAP_MARK="$T/evil-mark" TS_FIX_KS_NO_MAIN=1 \
    /bin/sh -c '. "$1"; printf "%s %s" "$KS_IPCALC" "$KS_SWAP_MARK"' _ "$SRC")
is "SK an environment value never replaces them" "/bin/ipcalc.sh /tmp/ts-fix-ks.srcswap" "$got"

echo "--- case S1: arm swaps GL's guest source rule, records it, and says so once"
reset fixture_mt3000
addrs "br-lan 192.168.50.1/24" "br-guest 192.168.160.1/24"
seed_gl_lan
seed "$(gl_rule 192.168.160.0/24)"
ks_main arm > "$T/out" 2>&1; rc=$?
is "S1 rc"                             0 "$rc"
is "S1 the swap's ip calls, in order: the delete is read back before it counts (case SF)" "-4 -br addr
-4 rule list priority 0
-4 rule del priority 0 from 192.168.160.0/24 lookup main
-4 rule list priority 0
-4 rule add to 192.168.160.0/24 lookup main priority 0" "$(swapcalls)"
is "S1 GL's rule gone, ours in place, the LAN rules untouched" "$(to_rule 192.168.50.0/24)
$(to_rule 192.168.200.0/24)
$(to_rule 192.168.160.0/24)" "$(prio0)"
is "S1 ipcalc got the bridge's address as ONE argument" "1:192.168.160.1/24" "$(ipcalcs)"
is "S1 the marker names the zone and network" "guest 192.168.160.0/24" "$(marker)"
is "S1 exactly one swap line in the log" 1 "$(grep -c 'source-rule swap' "$T/log")"
has "S1 it names the zone, the network and what was done" \
    "source-rule swap: guest 192.168.160.0/24 (deleted GL's from-rule, added the to-rule)" "$(logtext)"
hasnt "S1 no ERROR"                    "ERROR" "$(logtext)"
is "S1 the rule layer is in place too" "$(layer_state)" "$(grep -v '^S|' "$IPSTATE" | sort)"

echo "--- case S2: with GL's rule absent, ours is still ensured and recorded"
reset fixture_mt3000
addrs "br-guest 192.168.160.1/24"
_ks_swap_ensure > "$T/out" 2>&1; rc=$?
is "S2 rc"                             0 "$rc"
is "S2 two reads and the one add"      "-4 -br addr
-4 rule list priority 0
-4 rule add to 192.168.160.0/24 lookup main priority 0" "$(ipcalls)"
is "S2 ours in place"                  "$(to_rule 192.168.160.0/24)" "$(prio0)"
is "S2 the marker"                     "guest 192.168.160.0/24" "$(marker)"
is "S2 one log line, naming only the add" \
    "-t ts-fix ks: source-rule swap: guest 192.168.160.0/24 (added the to-rule)" "$(logtext)"

echo "--- case S3: a source rule for another network, a from+to rule and GL's LAN rules are left alone"
# Only the exact 5-token "0: from <net> lookup main" is GL's. The from+to rule would also be taken
# by the kernel's from-delete (case 0d-w), which is why nothing is deleted without an exact match.
reset fixture_mt3000
addrs "br-guest 192.168.160.1/24"
seed_gl_lan
seed "$(gl_rule 10.20.0.0/16)" 'S|-4|0|192.168.160.0/24|10.0.0.0/8|lookup main'
_ks_swap_ensure > "$T/out" 2>&1; rc=$?
is "S3 rc"                             0 "$rc"
is "S3 no delete issued"               "" "$(grep ' del ' "$T/ip-calls")"
is "S3 every foreign rule untouched, ours added after them" "$(to_rule 192.168.50.0/24)
$(to_rule 192.168.200.0/24)
$(gl_rule 10.20.0.0/16)
S|-4|0|192.168.160.0/24|10.0.0.0/8|lookup main
$(to_rule 192.168.160.0/24)" "$(prio0)"

echo "--- case S4: a /23 guest network is taken from ipcalc, never by zeroing the last octet"
reset fixture_mt3000
addrs "br-guest 192.168.161.1/23"
seed "$(gl_rule 192.168.160.0/23)"
_ks_swap_ensure > "$T/out" 2>&1; rc=$?
is "S4 rc"                             0 "$rc"
is "S4 ipcalc received one argument, the address as the bridge has it" "1:192.168.161.1/23" "$(ipcalcs)"
is "S4 it targets 192.168.160.0/23"    "-4 rule del priority 0 from 192.168.160.0/23 lookup main
-4 rule add to 192.168.160.0/23 lookup main priority 0" "$(grep -e ' del ' -e ' add ' "$T/ip-calls")"
is "S4 the marker"                     "guest 192.168.160.0/23" "$(marker)"

echo "--- case S5: no br-iot line -> iot skipped; a br-iot address (the 4.11 shape) -> swapped too"
reset fixture_mt3000
addrs "br-lan 192.168.50.1/24" "br-guest 192.168.160.1/24"
seed "$(gl_rule 192.168.160.0/24)"
_ks_swap_ensure > "$T/out" 2>&1; rc=$?
is "S5 rc, iot absent"                 0 "$rc"
is "S5 ipcalc only for guest"          "1:192.168.160.1/24" "$(ipcalcs)"
is "S5 the marker names guest only"    "guest 192.168.160.0/24" "$(marker)"
addrs "br-lan 192.168.50.1/24" "br-guest 192.168.160.1/24" "br-iot 192.168.10.1/24"
seed "$(gl_rule 192.168.10.0/24)"
counters_reset
_ks_swap_ensure > "$T/out" 2>&1; rc=$?
is "S5 rc, iot present"                0 "$rc"
is "S5 ipcalc for guest, then iot"     "1:192.168.160.1/24
1:192.168.10.1/24" "$(ipcalcs)"
is "S5 only iot needed work this time" "-4 rule del priority 0 from 192.168.10.0/24 lookup main
-4 rule add to 192.168.10.0/24 lookup main priority 0" "$(grep -e ' del ' -e ' add ' "$T/ip-calls")"
is "S5 both swapped"                   "$(to_rule 192.168.160.0/24)
$(to_rule 192.168.10.0/24)" "$(prio0)"
is "S5 the marker: guest, then iot"    "guest 192.168.160.0/24
iot 192.168.10.0/24" "$(marker)"
has "S5 the log line names iot"        "source-rule swap: iot 192.168.10.0/24 (deleted GL's from-rule, added the to-rule)" "$(logtext)"

echo "--- case S6: disarm undoes the swap before the zone restore; GL's rule back only under GL's condition"
s6_arm() {    # armed with guest and iot swapped and recorded; the caller sets GL's condition
    reset fixture_mt3000
    addrs "br-lan 192.168.50.1/24" "br-guest 192.168.160.1/24" "br-iot 192.168.10.1/24"
    seed_gl_lan
    seed "$(gl_rule 192.168.160.0/24)" "$(gl_rule 192.168.10.0/24)"
    ks_main arm > "$T/out" 2>&1
    counters_reset
}
s6_arm
gl_cond guest iot
is "S6 non-vacuity: both swapped and recorded" "guest 192.168.160.0/24
iot 192.168.10.0/24" "$(marker)"
ks_main disarm > "$T/out" 2>&1; rc=$?
is "S6 rc"                             0 "$rc"
last_swap=$(seqlast '^ip -4 rule (del priority 0 |add from )')
first_restore=$(seqline '^uci set .*\.enabled=1$')
if [ -n "$last_swap" ] && [ -n "$first_restore" ]; then ok "S6 non-vacuity: undo calls and a zone restore both happened"
else nok "S6 non-vacuity: undo calls and a zone restore both happened" "two line numbers" "[$last_swap] [$first_restore]"; fi
if [ "${last_swap:-999999}" -lt "${first_restore:-0}" ]; then ok "S6 the swap is undone before the first zone restore write"
else nok "S6 the swap is undone before the first zone restore write" "last undo line < first restore line" "$last_swap vs $first_restore"; fi
is "S6 ours gone, GL's rules back"     "$(to_rule 192.168.50.0/24)
$(to_rule 192.168.200.0/24)
$(gl_rule 192.168.160.0/24)
$(gl_rule 192.168.10.0/24)" "$(prio0)"
if [ -e "$KS_SWAP_MARK" ]; then nok "S6 the marker is gone" "absent" "present"; else ok "S6 the marker is gone"; fi
is "S6 one undo line"                  1 "$(grep -c 'source-rule swap' "$T/log")"
has "S6 it says what was undone and re-added" \
    "source-rule swap undone: removed the to-rule for guest 192.168.160.0/24, iot 192.168.10.0/24; re-added GL's from-rule for guest 192.168.160.0/24, iot 192.168.10.0/24" "$(logtext)"
echo "  S6b: no exit node set -> ours removed, GL's rule NOT re-added, and the re-add reads nothing"
s6_arm
uci set network.guest.disabled=0; uci set network.iot.disabled=0
ks_main disarm > "$T/out" 2>&1; rc=$?
is "S6b rc"                            0 "$rc"
is "S6b ours gone, GL's not re-added"  "$(to_rule 192.168.50.0/24)
$(to_rule 192.168.200.0/24)" "$(prio0)"
# The one address read is the guard's, taken before the first delete, and the only ipcalc calls are
# the guard's: guest checks br-lan and br-iot, iot then checks br-guest (br-lan is cached).
is "S6b one -br addr read, and ipcalc only for the guard: one per other bridge" "1:1:192.168.50.1/24
1:192.168.10.1/24
1:192.168.160.1/24" "$(grep -c -e '-br addr' "$T/ip-calls"):$(ipcalcs)"
if [ -e "$KS_SWAP_MARK" ]; then nok "S6b the marker is gone" "absent" "present"; else ok "S6b the marker is gone"; fi
echo "  S6c: guest disabled='1' -> guest not re-added; iot still is"
s6_arm
gl_cond iot
uci set network.guest.disabled=1
ks_main disarm > "$T/out" 2>&1
is "S6c GL's iot rule back, guest's not" "$(to_rule 192.168.50.0/24)
$(to_rule 192.168.200.0/24)
$(gl_rule 192.168.10.0/24)" "$(prio0)"
if [ -e "$KS_SWAP_MARK" ]; then nok "S6c the marker is gone" "absent" "present"; else ok "S6c the marker is gone"; fi
echo "  S6d: guest's disabled option ABSENT -> not re-added (GL's test is = \"0\")"
s6_arm
gl_cond iot
ks_main disarm > "$T/out" 2>&1
is "S6d GL's iot rule back, guest's not" "$(to_rule 192.168.50.0/24)
$(to_rule 192.168.200.0/24)
$(gl_rule 192.168.10.0/24)" "$(prio0)"
if [ -e "$KS_SWAP_MARK" ]; then nok "S6d the marker is gone" "absent" "present"; else ok "S6d the marker is gone"; fi

echo "--- case S7: route_guest=1 -> Route Guest owns guest's rules; iot is still undone"
s6_arm
gl_cond guest iot
uci set ts-fix.settings.route_guest=1
ks_main disarm > "$T/out" 2>&1; rc=$?
is "S7 rc"                             0 "$rc"
is "S7 guest's to-rule stays and GL's guest rule is not re-added; iot undone" "$(to_rule 192.168.50.0/24)
$(to_rule 192.168.200.0/24)
$(to_rule 192.168.160.0/24)
$(gl_rule 192.168.10.0/24)" "$(prio0)"
is "S7 not even a delete was tried for guest" "" "$(grep -e '192.168.160' "$T/ip-calls")"
if [ -e "$KS_SWAP_MARK" ]; then nok "S7 the marker is gone" "absent" "present"; else ok "S7 the marker is gone"; fi

echo "--- case S8: a disarmed poll that finds a swap marker undoes the swap, in one log line"
reset fixture_mt3000
uci set ts-fix.settings.kill_switch=0
addrs "br-lan 192.168.50.1/24" "br-guest 192.168.160.1/24"
seed_gl_lan
seed "$(to_rule 192.168.160.0/24)"                  # a swap left behind; no rule layer
printf 'guest 192.168.160.0/24\n' > "$KS_SWAP_MARK"
gl_cond guest
cp "$STATE" "$T/before"
counters_reset
ks_main check > "$T/out" 2>&1; rc=$?
is "S8 rc"                             0 "$rc"
is "S8 the 5279 probe comes first"     "-4 rule list priority 5279" "$(head -n 1 "$T/ip-calls")"
is "S8 ours removed, GL's back"        "$(to_rule 192.168.50.0/24)
$(to_rule 192.168.200.0/24)
$(gl_rule 192.168.160.0/24)" "$(prio0)"
if [ -e "$KS_SWAP_MARK" ]; then nok "S8 the marker is gone" "absent" "present"; else ok "S8 the marker is gone"; fi
is "S8 exactly one log line"           1 "$(grep -c . "$T/log")"
has "S8 which says a swap was found with no armed intent and undone" \
    "source-rule swap found with no armed intent - undone: removed the to-rule for guest 192.168.160.0/24; re-added GL's from-rule for guest 192.168.160.0/24" "$(logtext)"
if cmp -s "$T/before" "$STATE"; then ok "S8 no uci writes"; else nok "S8 no uci writes" "no writes" "state differs"; fi
is "S8 zero commits"                   "" "$(commits)"
echo "  S8b: no marker -> the branch's only ip call is the 5279 probe, whatever the kernel holds"
reset fixture_mt3000
uci set ts-fix.settings.kill_switch=0
addrs "br-guest 192.168.160.1/24"
seed "$(to_rule 192.168.160.0/24)"
counters_reset
ks_main check > "$T/out" 2>&1
is "S8b exactly the one probe"         "-4 rule list priority 5279" "$(ipcalls)"
is "S8b the rule is untouched"         "$(to_rule 192.168.160.0/24)" "$(prio0)"
# The gates: the intent's two section reads, and the sidecar read.
is "S8b no ipcalc, no uci beyond the gates" "::" \
    "$(ipcalcs):$(grep -v -x -e 'uci -q show ts-fix.settings' -e 'uci -q show tailscale.settings' -e '.*ks_severed' "$T/uci-calls"):$(logtext)"
echo "  S8c: a stale marker whose swap is already gone still gets its one line, and goes"
reset fixture_mt3000
uci set ts-fix.settings.kill_switch=0
printf 'guest 192.168.160.0/24\n' > "$KS_SWAP_MARK"
counters_reset
ks_main check > "$T/out" 2>&1
is "S8c exactly one log line"          1 "$(grep -c . "$T/log")"
has "S8c which says there was nothing left in place" \
    "source-rule swap found with no armed intent - undone: nothing was left in place" "$(logtext)"
if [ -e "$KS_SWAP_MARK" ]; then nok "S8c the marker is gone" "absent" "present"; else ok "S8c the marker is gone"; fi

echo "--- case S9: a second armed pass with everything in place: reads only, no marker rewrite, no log"
reset fixture_mt3000
addrs "br-lan 192.168.50.1/24" "br-guest 192.168.160.1/24" "br-iot 192.168.10.1/24"
seed_gl_lan
seed "$(gl_rule 192.168.160.0/24)" "$(gl_rule 192.168.10.0/24)"
ks_main arm > "$T/out" 2>&1
IP4_DEFAULT="default via 192.168.8.1 dev eth0 proto static"
UBUS_DUMP="eth0 wan"
is "S9 non-vacuity: the arm swapped both and wrote the marker" "guest 192.168.160.0/24
iot 192.168.10.0/24" "$(marker)"
m_inode=$(inode "$KS_SWAP_MARK")
cp "$KS_SWAP_MARK" "$T/mark-before"
counters_reset
ks_main rules-ensure > "$T/out" 2>&1; rc=$?
is "S9 rules-ensure rc"                0 "$rc"
is "S9 rules-ensure: exactly the six reads" "$(ensure_expect_present)" "$(ipcalls)"
is "S9 ... one ipcalc per addressed guest/iot bridge" "1:192.168.160.1/24
1:192.168.10.1/24" "$(ipcalcs)"
is "S9 ... no marker write"            "" "$(markcalls)"
is "S9 ... silent"                     "" "$(logtext)"
counters_reset
ks_main check > "$T/out" 2>&1; rc=$?
is "S9 check rc"                       0 "$rc"
is "S9 the armed poll: 2 route reads + the six" "-4 route show default
-6 route show default
$(ensure_expect_present)" "$(ipcalls)"
is "S9 ... the same ipcalc calls"      "1:192.168.160.1/24
1:192.168.10.1/24" "$(ipcalcs)"
is "S9 ... no marker write"            "" "$(markcalls)"
is "S9 ... no log, no commit"          ":" "$(logtext):$(commits)"
is "S9 the marker is the same file"    "$m_inode" "$(inode "$KS_SWAP_MARK")"
if cmp -s "$T/mark-before" "$KS_SWAP_MARK"; then ok "S9 ... with the same content"; else nok "S9 ... with the same content" "unchanged" "changed"; fi

echo "--- case S10: an ipcalc answer that is not a valid network: no ip write for that zone, ERROR, rc 1"
s10() {   # <label> <ipcalc output line>...
    s10_label="$1"; shift
    reset fixture_mt3000
    addrs "br-guest 192.168.160.1/24" "br-iot 192.168.10.1/24"
    seed "$(gl_rule 192.168.160.0/24)" "$(gl_rule 192.168.10.0/24)"
    ipcalc_inject 192.168.160.1/24 "$@"
    _ks_swap_ensure > "$T/out" 2>&1; rc=$?
    is "S10 $s10_label: rc 1"          1 "$rc"
    is "S10 $s10_label: no ip write for guest" "" "$(grep -e ' add ' -e ' del ' "$T/ip-calls" | grep -v '192.168.10.0/24')"
    has "S10 $s10_label: an ERROR naming the zone" "ERROR source-rule swap: no valid network for guest" "$(logtext)"
    is "S10 $s10_label: GL's guest rule untouched, iot still swapped" "$(gl_rule 192.168.160.0/24)
$(to_rule 192.168.10.0/24)" "$(prio0)"
    is "S10 $s10_label: the marker records iot only" "iot 192.168.10.0/24" "$(marker)"
}
s10 "/0"                     NETWORK=0.0.0.0 PREFIX=0
s10 "/7"                     NETWORK=192.0.0.0 PREFIX=7
s10 "a non-digit network"    NETWORK=192.168.1x5.0 PREFIX=24
s10 "a non-digit prefix"     NETWORK=192.168.160.0 PREFIX=2x
s10 "no PREFIX line"         NETWORK=192.168.160.0
s10 "no NETWORK line"        PREFIX=24
s10 "a leading zero"         NETWORK=192.168.060.0 PREFIX=24
s10 "a trailing token"       'NETWORK=192.168.160.0 x' PREFIX=24
hasnt "S10 the ERROR never echoes ipcalc's output" "192.168.160.0 x" "$(logtext)"
echo "  S10b: ipcalc itself failing (an address its table does not know) is the same ERROR"
reset fixture_mt3000
addrs "br-guest 192.168.99.1/24"
_ks_swap_ensure > "$T/out" 2>&1; rc=$?
is "S10b rc 1"                         1 "$rc"
has "S10b ERROR naming the zone and address" "no valid network for guest (br-guest 192.168.99.1/24" "$(logtext)"
is "S10b no write"                     "" "$(grep -e ' add ' -e ' del ' "$T/ip-calls")"
echo "  S10c: a read that fails: ERROR, rc 1, no write, marker untouched"
for rd in "-4 -br addr" "-4 rule list priority 0"; do
    reset fixture_mt3000
    addrs "br-guest 192.168.160.1/24"
    seed "$(gl_rule 192.168.160.0/24)"
    printf 'guest 192.168.160.0/24\n' > "$KS_SWAP_MARK"
    IP_READ_FAIL="$rd"
    _ks_swap_ensure > "$T/out" 2>&1; rc=$?
    IP_READ_FAIL=""
    is "S10c '$rd' fails: rc 1"        1 "$rc"
    has "S10c '$rd' fails: an ERROR naming the read" "ERROR source-rule swap: 'ip $rd' failed" "$(logtext)"
    is "S10c '$rd' fails: no write, no marker call, no ipcalc (both reads come first)" "::" "$(grep -e ' add ' -e ' del ' "$T/ip-calls"):$(markcalls):$(ipcalcs)"
    is "S10c '$rd' fails: GL's rule untouched" "$(gl_rule 192.168.160.0/24)" "$(prio0)"
done

echo "--- case S11: a lost race is not a failure; a write that really did not land is"
s11() { reset fixture_mt3000; addrs "br-guest 192.168.160.1/24"; seed "$(gl_rule 192.168.160.0/24)"; }
s11
IP_ADD_RACE="-4 rule add to 192.168.160.0/24"
_ks_swap_ensure > "$T/out" 2>&1; rc=$?
is "S11 an add lost to a concurrent pass (EEXIST): rc 0" 0 "$rc"
hasnt "S11 ... no ERROR"               "ERROR" "$(logtext)"
# Three lists: the pass's own, the read-back of its delete of GL's rule (case SF), and ONE for the
# add.
is "S11 ... ONE extra rule list for the add" 3 "$(grep -cxF -e '-4 rule list priority 0' "$T/ip-calls")"
is "S11 ... ours there once, GL's gone" "$(to_rule 192.168.160.0/24)" "$(prio0)"
is "S11 ... the marker is written"     "guest 192.168.160.0/24" "$(marker)"
hasnt "S11 ... the log does not claim the winner's add" "added the to-rule" "$(logtext)"
s11
IP_DEL_RACE="-4 rule del priority 0 from 192.168.160.0/24"
_ks_swap_ensure > "$T/out" 2>&1; rc=$?
is "S11 a delete that fails because the rule is already gone: rc 0" 0 "$rc"
hasnt "S11 ... no ERROR"               "ERROR" "$(logtext)"
is "S11 ... ONE extra rule list"       2 "$(grep -cxF -e '-4 rule list priority 0' "$T/ip-calls")"
is "S11 ... ours in place"             "$(to_rule 192.168.160.0/24)" "$(prio0)"
hasnt "S11 ... the log does not claim the winner's delete" "deleted" "$(logtext)"
s11
IP_ADD_FAIL="-4 rule add to 192.168.160.0/24"
_ks_swap_ensure > "$T/out" 2>&1; rc=$?
is "S11 an add that fails while the rule stays absent: rc 1" 1 "$rc"
has "S11 ... an ERROR naming it"       "ERROR source-rule swap incomplete: the to-rule for guest 192.168.160.0/24 is still absent" "$(logtext)"
is "S11 ... after ONE extra rule list for the add (the third: see above)" 3 "$(grep -cxF -e '-4 rule list priority 0' "$T/ip-calls")"
is "S11 ... the network is still recorded, so a disarm will look for it" "guest 192.168.160.0/24" "$(marker)"
s11
IP_DEL_FAIL="-4 rule del priority 0 from 192.168.160.0/24"
_ks_swap_ensure > "$T/out" 2>&1; rc=$?
is "S11 a delete that fails while the rule stays present: rc 1" 1 "$rc"
has "S11 ... an ERROR naming it"       "ERROR source-rule swap incomplete: GL's from-rule for guest 192.168.160.0/24 is still present" "$(logtext)"
s11
IP_ADD_FAIL="-4 rule add to 192.168.160.0/24"
IP_READ_FAIL="-4 rule list priority 0"; IP_READ_FAIL_SKIP=1
_ks_swap_ensure > "$T/out" 2>&1; rc=$?
is "S11 a failed add whose read-back cannot be taken: rc 1" 1 "$rc"
has "S11 ... an ERROR"                 "ERROR source-rule swap incomplete" "$(logtext)"

echo "--- case SF: GL's rule is deleted until a read-back shows it gone, whatever is listed ahead of it"
# A delete that names no input device takes the FIRST rule in list order matching what it does name
# (device fact, kernel 5.4 / iproute2 6.3.0, 2026-10-04). A foreign "from <net> iif lo lookup main"
# listed ahead of GL's rule is therefore deleted first, and a single delete reported as GL's left
# GL's rule routing guest around priority 5279 until the next pass. Removing the foreign rule on the
# way is accepted by design: GL's bypass is what must go.
sf() { reset fixture_mt3000; addrs "br-guest 192.168.160.1/24"; seed "$(iif_rule 192.168.160.0/24 lo)" "$(gl_rule 192.168.160.0/24)"; }
sf
_ks_swap_ensure > "$T/out" 2>&1; rc=$?
is "SF rc 0"                           0 "$rc"
is "SF GL's rule is gone (the foreign one with it), ours in place" "$(to_rule 192.168.160.0/24)" "$(prio0)"
is "SF the calls: each delete is read back, and the deletes stop once GL's rule is gone" "-4 -br addr
-4 rule list priority 0
-4 rule del priority 0 from 192.168.160.0/24 lookup main
-4 rule list priority 0
-4 rule del priority 0 from 192.168.160.0/24 lookup main
-4 rule list priority 0
-4 rule add to 192.168.160.0/24 lookup main priority 0" "$(swapcalls)"
is "SF one log line, and it is true now" \
    "-t ts-fix ks: source-rule swap: guest 192.168.160.0/24 (deleted GL's from-rule, added the to-rule)" "$(logtext)"
sf
ks_main arm > "$T/out" 2>&1; rc=$?
is "SF through arm: rc 0, GL's rule gone" "0 $(to_rule 192.168.160.0/24)" "$rc $(prio0)"
echo "  SF2: a GL rule that will not delete: five attempts, each read back, then an ERROR and rc 1"
reset fixture_mt3000
addrs "br-guest 192.168.160.1/24"
seed "$(gl_rule 192.168.160.0/24)"
IP_DEL_FAIL="-4 rule del priority 0 from 192.168.160.0/24"
_ks_swap_ensure > "$T/out" 2>&1; rc=$?
is "SF2 rc 1"                          1 "$rc"
is "SF2 exactly five deletes"          5 "$(grep -cxF -e '-4 rule del priority 0 from 192.168.160.0/24 lookup main' "$T/ip-calls")"
is "SF2 ... and six lists: the first, then one after each delete" 6 "$(grep -cxF -e '-4 rule list priority 0' "$T/ip-calls")"
has "SF2 an ERROR naming the rule and the attempts" \
    "ERROR source-rule swap incomplete: GL's from-rule for guest 192.168.160.0/24 is still present after 5 deletes" "$(logtext)"
hasnt "SF2 never 'deleted'"            "deleted GL's" "$(logtext)"
is "SF2 GL's rule is still there, ours added beside it" "$(gl_rule 192.168.160.0/24)
$(to_rule 192.168.160.0/24)" "$(prio0)"
echo "  SF3: the read-back fails after a delete: ERROR, rc 1, never 'deleted'"
reset fixture_mt3000
addrs "br-guest 192.168.160.1/24"
seed "$(iif_rule 192.168.160.0/24 lo)" "$(gl_rule 192.168.160.0/24)"
IP_READ_FAIL="-4 rule list priority 0"; IP_READ_FAIL_SKIP=1
_ks_swap_ensure > "$T/out" 2>&1; rc=$?
is "SF3 rc 1"                          1 "$rc"
is "SF3 one delete, then the failed read: no second delete" 1 "$(grep -cxF -e '-4 rule del priority 0 from 192.168.160.0/24 lookup main' "$T/ip-calls")"
has "SF3 an ERROR"                     "GL's from-rule for guest 192.168.160.0/24 could not be confirmed gone" "$(logtext)"
hasnt "SF3 never 'deleted'"            "deleted GL's" "$(logtext)"
echo "  SF4: the quiet path is unchanged: GL's rule absent costs one list and no delete"
reset fixture_mt3000
addrs "br-guest 192.168.160.1/24"
seed "$(to_rule 192.168.160.0/24)"
_ks_swap_ensure > "$T/out" 2>&1; rc=$?
is "SF4 rc 0, exactly the two reads"   "0 -4 -br addr
-4 rule list priority 0" "$rc $(swapcalls)"

echo "--- case S12: every rule-layer call site pairs the swap with it"
s12() { addrs "br-guest 192.168.160.1/24"; seed "$(gl_rule 192.168.160.0/24)"; }
reset fixture_no_firewall
s12
ks_main arm > "$T/out" 2>&1; rc=$?
is "S12 arm, unreadable firewall: rc 1, and swapped" "1 $(to_rule 192.168.160.0/24)" "$rc $(prio0)"
: > "$IPSTATE"; rm -f "$KS_SWAP_MARK"; s12
ks_main check > "$T/out" 2>&1; rc=$?
is "S12 check, unreadable firewall: rc 1, and swapped" "1 $(to_rule 192.168.160.0/24)" "$rc $(prio0)"
reset fixture_mt3000
s12
ks_main rules-ensure > "$T/out" 2>&1; rc=$?
is "S12 rules-ensure: rc 0, and swapped" "0 $(to_rule 192.168.160.0/24)" "$rc $(prio0)"
s12_swapped() {   # armed, guest swapped and recorded, GL's condition met
    reset fixture_mt3000
    s12
    gl_cond guest
    ks_main rules-ensure > "$T/out" 2>&1
    is "S12 non-vacuity: swapped and recorded before the undo" "$(to_rule 192.168.160.0/24):guest 192.168.160.0/24" "$(prio0):$(marker)"
    counters_reset
}
s12_swapped
uci set ts-fix.settings.kill_switch=0
ks_main arm > "$T/out" 2>&1
is "S12 arm with no intent undoes it"  "$(gl_rule 192.168.160.0/24):" "$(prio0):$(marker)"
s12_swapped
uci set glconfig.general.mode=extender
ks_main arm > "$T/out" 2>&1; rc=$?
# Outside Router mode gl_tailscale exits before adding its source rule: the undo re-adds none (SR9).
is "S12 arm refused by the mode undoes it (rc 2) and re-adds nothing" "2 :" "$rc $(prio0):$(marker)"
s12_swapped
ks_main rules-clean > "$T/out" 2>&1; rc=$?
is "S12 rules-clean undoes it (rc 0)"  "0 $(gl_rule 192.168.160.0/24):" "$rc $(prio0):$(marker)"
s12_swapped                                          # rules-ensure put the rule layer in place too
uci set ts-fix.settings.kill_switch=0
ks_main check > "$T/out" 2>&1
is "S12 the disarmed probe finding our rules undoes the swap with them" "$(gl_rule 192.168.160.0/24)::" "$(prio0):$(marker):$(grep -v '^S|' "$IPSTATE")"
is "S12 ... two lines: the rule layer's and the undo" "2" "$(grep -c . "$T/log")"
echo "  S12b: arm drops the 5280 rules only once rules AND swap are confirmed"
reset fixture_mt3000
s12
seed 'R|-4|5280|br-lan|lookup 100'
IP_ADD_FAIL="-4 rule add to 192.168.160.0/24"
ks_main arm > "$T/out" 2>&1; rc=$?
is "S12b a swap that fails: rc 1"      1 "$rc"
is "S12b ... and the 5280 rule is kept" "" "$(grep ' del .*priority 5280' "$T/ip-calls")"
if grep -qxF -e 'R|-4|5280|br-lan|lookup 100' "$IPSTATE"; then ok "S12b ... still in the model"
else nok "S12b ... still in the model" "the 5280 record" "gone"; fi
reset fixture_mt3000
s12
seed 'R|-4|5280|br-lan|lookup 100'
ks_main arm > "$T/out" 2>&1; rc=$?
is "S12b rules and swap both fine: rc 0" 0 "$rc"
if grep -qxF -e 'R|-4|5280|br-lan|lookup 100' "$IPSTATE"; then nok "S12b ... and the 5280 rule is dropped" "gone" "still there"
else ok "S12b ... and the 5280 rule is dropped"; fi

echo "--- case S13: the marker keeps every network the swap touched while armed; undo re-adds for today's"
reset fixture_mt3000
addrs "br-guest 192.168.160.1/24"
seed "$(gl_rule 192.168.160.0/24)"
gl_cond guest
ks_main arm > "$T/out" 2>&1
is "S13 armed at 192.168.160.1/24"     "guest 192.168.160.0/24" "$(marker)"
addrs "br-guest 192.168.176.1/24"
seed "$(gl_rule 192.168.176.0/24)"
IP4_DEFAULT="default via 192.168.8.1 dev eth0 proto static"
UBUS_DUMP="eth0 wan"
counters_reset
ks_main check > "$T/out" 2>&1; rc=$?
is "S13 the next pass: rc 0"           0 "$rc"
is "S13 the marker holds both networks, the older first" "guest 192.168.160.0/24
guest 192.168.176.0/24" "$(marker)"
is "S13 both to-rules in place, GL's new rule gone" "$(to_rule 192.168.160.0/24)
$(to_rule 192.168.176.0/24)" "$(prio0)"
counters_reset
ks_main disarm > "$T/out" 2>&1; rc=$?
is "S13 disarm: rc 0"                  0 "$rc"
is "S13 disarm deletes both to-rules"  "-4 rule del priority 0 to 192.168.160.0/24 lookup main
-4 rule del priority 0 to 192.168.176.0/24 lookup main" "$(grep -e 'del priority 0 to' "$T/ip-calls" | sort -u)"
is "S13 ... and re-adds GL's rule for 192.168.176.0/24 only" "$(gl_rule 192.168.176.0/24)" "$(prio0)"

echo "--- case S14: the marker is written atomically and exactly"
reset fixture_mt3000
addrs "br-guest 192.168.160.1/24"
seed "$(gl_rule 192.168.160.0/24)"
_ks_swap_ensure > "$T/out" 2>&1
is "S14 one mktemp on the marker's template, then one mv onto it" "mktemp $KS_SWAP_MARK.XXXXXX
mv -f $KS_SWAP_MARK. $KS_SWAP_MARK" "$(sed "s|^\(mv -f $KS_SWAP_MARK\.\)[^ ]* |\1 |" "$T/mark-calls")"
printf 'guest 192.168.160.0/24\n' > "$T/mark-want"
if cmp -s "$T/mark-want" "$KS_SWAP_MARK"; then ok "S14 the content is exactly the expected line, newline-terminated"
else nok "S14 the content is exactly the expected line, newline-terminated" "guest 192.168.160.0/24\\n" "$(od -c < "$KS_SWAP_MARK" | head -n 2)"; fi
is "S14 mode 0600"                     "-rw-------" "$(ls -l "$KS_SWAP_MARK" | cut -c1-10)"
is "S14 no temp file left"             "" "$(tmpleft)"
echo "  S14b: a failed mktemp, write or mv: ERROR, rc 1, no temp file left, marker unchanged, retried"
for f in MKTEMP_FAIL MKTEMP_RET MV_FAIL; do
    reset fixture_mt3000
    addrs "br-guest 192.168.160.1/24"
    seed "$(gl_rule 192.168.160.0/24)"
    _ks_swap_ensure > "$T/out" 2>&1
    cp "$KS_SWAP_MARK" "$T/mark-before"
    addrs "br-guest 192.168.176.1/24"             # the union now has a line to add
    counters_reset
    case "$f" in
        MKTEMP_FAIL) MKTEMP_FAIL=1 ;;
        MKTEMP_RET)  MKTEMP_RET="$T/no-such-dir/ts-fix-ks.srcswap.write" ;;
        MV_FAIL)     MV_FAIL=1 ;;
    esac
    _ks_swap_ensure > "$T/out" 2>&1; rc=$?
    MKTEMP_FAIL=""; MKTEMP_RET=""; MV_FAIL=""
    is "S14b $f: rc 1"                 1 "$rc"
    has "S14b $f: ERROR"               "ERROR source-rule swap: could not write $KS_SWAP_MARK" "$(logtext)"
    if cmp -s "$T/mark-before" "$KS_SWAP_MARK"; then ok "S14b $f: marker unchanged"
    else nok "S14b $f: marker unchanged" "$(cat "$T/mark-before")" "$(marker)"; fi
    is "S14b $f: no temp file left"    "" "$(tmpleft)"
    is "S14b $f: the rule was still swapped (the marker comes last)" "$(to_rule 192.168.160.0/24)
$(to_rule 192.168.176.0/24)" "$(prio0)"
    counters_reset
    _ks_swap_ensure > "$T/out" 2>&1; rc=$?
    is "S14b $f: the next pass writes it" "0 guest 192.168.160.0/24
guest 192.168.176.0/24" "$rc $(marker)"
done
echo "  S14c: a marker path that is a directory is an ERROR, never a write into it"
reset fixture_mt3000
addrs "br-guest 192.168.160.1/24"
mkdir "$KS_SWAP_MARK"
_ks_swap_ensure > "$T/out" 2>&1; rc=$?
is "S14c rc 1"                         1 "$rc"
has "S14c ERROR"                       "ERROR source-rule swap: could not write $KS_SWAP_MARK" "$(logtext)"
is "S14c nothing was put inside it"    "" "$(ls -A "$KS_SWAP_MARK")"
is "S14c no temp file left"            "" "$(tmpleft)"
rmdir "$KS_SWAP_MARK"
echo "  S14d: ensure keeps the valid lines of an existing marker, first, and drops the rest loudly"
reset fixture_mt3000
addrs "br-guest 192.168.160.1/24"
printf 'iot 192.168.10.0/24\nbogus line here\nguest 0.0.0.0/0\nlan 192.168.50.0/24\niot 192.168.10.0/24\n' > "$KS_SWAP_MARK"
_ks_swap_ensure > "$T/out" 2>&1; rc=$?
is "S14d rc 0: the swap itself is in place" 0 "$rc"
is "S14d the valid line kept first, deduplicated, then this pass's" "iot 192.168.10.0/24
guest 192.168.160.0/24" "$(marker)"
has "S14d one WARNING giving the count" "WARNING source-rule swap marker $KS_SWAP_MARK: 3 invalid line(s) dropped" "$(logtext)"
hasnt "S14d never the raw text"        "bogus" "$(logtext)"

echo "--- case SA: the bridge's FIRST address, from the line whose name is exactly the bridge"
reset fixture_mt3000
IP4_BR_ADDR="$(br_line br-guest2 UP 192.168.176.1/24)
$(br_line br-guest UP 192.168.160.1/24 192.168.176.1/24)"
seed "$(gl_rule 192.168.160.0/24)"
_ks_swap_ensure > "$T/out" 2>&1; rc=$?
is "SA rc"                             0 "$rc"
is "SA ipcalc saw br-guest's first address only" "1:192.168.160.1/24" "$(ipcalcs)"
is "SA the marker"                     "guest 192.168.160.0/24" "$(marker)"

echo "--- case SR1: undo with no marker is a file test and nothing else"
reset fixture_mt3000
addrs "br-guest 192.168.160.1/24"
seed "$(to_rule 192.168.160.0/24)"
gl_cond guest
counters_reset
_ks_swap_restore > "$T/out" 2>&1; rc=$?
is "SR1 rc 0"                          0 "$rc"
is "SR1 zero ip, uci and ipcalc calls, and silent" ":::" "$(ipcalls):$(cat "$T/uci-calls"):$(ipcalcs):$(logtext)"
is "SR1 the rule is untouched"         "$(to_rule 192.168.160.0/24)" "$(prio0)"

echo "--- case SR2: GL's rule already back (GL restarted first) is not added twice"
reset fixture_mt3000
addrs "br-guest 192.168.160.1/24"
seed "$(to_rule 192.168.160.0/24)" "$(gl_rule 192.168.160.0/24)"
printf 'guest 192.168.160.0/24\n' > "$KS_SWAP_MARK"
gl_cond guest
counters_reset
_ks_swap_restore > "$T/out" 2>&1; rc=$?
is "SR2 rc 0"                          0 "$rc"
is "SR2 no add issued"                 "" "$(grep ' add ' "$T/ip-calls")"
is "SR2 GL's rule there once, ours gone" "$(gl_rule 192.168.160.0/24)" "$(prio0)"

echo "--- case SR3: invalid marker lines: one ERROR with their count, never their text"
reset fixture_mt3000
seed "$(to_rule 192.168.160.0/24)"
printf 'guest 192.168.160.0/24\nguest 192.168.0.0/1\n$(reboot) x\nwan 10.0.0.0/8\n' > "$KS_SWAP_MARK"
counters_reset
_ks_swap_restore > "$T/out" 2>&1; rc=$?
is "SR3 exactly one ERROR line"        1 "$(grep -c ERROR "$T/log")"
has "SR3 it gives the count"           "ERROR source-rule swap marker $KS_SWAP_MARK: 3 invalid line(s) ignored" "$(logtext)"
hasnt "SR3 never the raw text (1)"     "reboot" "$(logtext)"
hasnt "SR3 never the raw text (2)"     "192.168.0.0/1" "$(logtext)"
is "SR3 no invalid line reached ip"    "" "$(grep -e '192.168.0.0/1' -e '10.0.0.0/8' "$T/ip-calls")"
is "SR3 the valid entry is still undone" "" "$(prio0)"
if [ -e "$KS_SWAP_MARK" ]; then nok "SR3 the marker is gone" "absent" "present"; else ok "SR3 the marker is gone"; fi

echo "--- case SR4: a re-add refused because GL re-added its rule concurrently is not a failure"
reset fixture_mt3000
addrs "br-guest 192.168.160.1/24"
seed "$(to_rule 192.168.160.0/24)"
printf 'guest 192.168.160.0/24\n' > "$KS_SWAP_MARK"
gl_cond guest
IP_ADD_RACE="-4 rule add from 192.168.160.0/24"
counters_reset
_ks_swap_restore > "$T/out" 2>&1; rc=$?
is "SR4 rc 0"                          0 "$rc"
hasnt "SR4 no ERROR"                   "ERROR" "$(logtext)"
is "SR4 GL's rule there once"          "$(gl_rule 192.168.160.0/24)" "$(prio0)"
is "SR4 after ONE extra rule list"     2 "$(grep -cxF -e '-4 rule list priority 0' "$T/ip-calls")"

echo "--- case SR5: a re-add that fails and stays absent is an ERROR; the marker still goes"
reset fixture_mt3000
addrs "br-guest 192.168.160.1/24"
seed "$(to_rule 192.168.160.0/24)"
printf 'guest 192.168.160.0/24\n' > "$KS_SWAP_MARK"
gl_cond guest
IP_ADD_FAIL="-4 rule add from 192.168.160.0/24"
counters_reset
_ks_swap_restore > "$T/out" 2>&1; rc=$?
is "SR5 rc 1"                          1 "$rc"
has "SR5 an ERROR naming it"           "ERROR source-rule swap undo: could not re-add GL's from-rule for guest 192.168.160.0/24" "$(logtext)"
is "SR5 ours removed all the same"     "" "$(prio0)"
if [ -e "$KS_SWAP_MARK" ]; then nok "SR5 the marker is gone" "absent" "present"; else ok "SR5 the marker is gone"; fi
echo "  SR6: an address read that fails during undo: ERROR, no to-rule deleted, no re-add, marker gone"
# The read comes before the first delete: without it no entry can be checked against the other
# bridges' networks (SR8), so no to-rule is deleted — a to-rule left behind is benign, and deleting
# one that is now another bridge's is what the guard exists to prevent.
reset fixture_mt3000
addrs "br-guest 192.168.160.1/24"
seed "$(to_rule 192.168.160.0/24)"
printf 'guest 192.168.160.0/24\n' > "$KS_SWAP_MARK"
gl_cond guest
IP_READ_FAIL="-br addr"
counters_reset
_ks_swap_restore > "$T/out" 2>&1; rc=$?
IP_READ_FAIL=""
is "SR6 rc 1"                          1 "$rc"
is "SR6 exactly one ERROR, naming the read and both consequences" "1 yes" "$(grep -c ERROR "$T/log") $(case "$(logtext)" in
    *"ERROR source-rule swap undo: 'ip -4 -br addr' failed - no to-rule removed, since whose network each one now is could not be checked; GL's from-rule not re-added for guest"*) echo yes ;; *) echo no ;; esac)"
is "SR6 the read was tried once, and no delete or add followed it" "-4 -br addr" "$(ipcalls)"
is "SR6 ours left in place, nothing re-added" "$(to_rule 192.168.160.0/24)" "$(prio0)"
if [ -e "$KS_SWAP_MARK" ]; then nok "SR6 the marker is gone" "absent" "present"; else ok "SR6 the marker is gone"; fi

echo "--- case SR7: undo repeats each to-rule delete until it misses, at most 5 times"
# As R13 for the 5279 rules: a kernel that accepts an identical rule twice can hold a twin, and one
# delete would leave it. The model refuses identical adds (EEXIST), so the twins are seeded.
reset fixture_mt3000
seed "$(to_rule 192.168.160.0/24)" "$(to_rule 192.168.160.0/24)"
printf 'guest 192.168.160.0/24\n' > "$KS_SWAP_MARK"
counters_reset
_ks_swap_restore > "$T/out" 2>&1
is "SR7 both copies gone"              "" "$(prio0)"
is "SR7 two hits then one miss"        3 "$(grep -cxF -e '-4 rule del priority 0 to 192.168.160.0/24 lookup main' "$T/ip-calls")"
reset fixture_mt3000
i=0
while [ "$i" -lt 7 ]; do seed "$(to_rule 192.168.160.0/24)"; i=$((i + 1)); done
printf 'guest 192.168.160.0/24\n' > "$KS_SWAP_MARK"
_ks_swap_restore > "$T/out" 2>&1
is "SR7 the loop stops at 5 attempts"  5 "$(grep -cxF -e '-4 rule del priority 0 to 192.168.160.0/24 lookup main' "$T/ip-calls")"
is "SR7 so 2 of 7 survive (the cap is real)" 2 "$(grep -cxF -e "$(to_rule 192.168.160.0/24)" "$IPSTATE")"

echo "--- case SR8: undo never deletes a to-rule whose network is now another bridge's"
# The marker keeps every network the swap touched while armed (S13), so after a renumber an entry
# can name the network another bridge has today — and "to <net> lookup main" is then that bridge's
# rule too: GL's own LAN rule has exactly that shape, and the kernel holds one copy of it. The
# review's sequence: armed with guest on 192.168.50.0/24, then the LAN moves onto that network and
# guest to another; a disarm must leave the LAN rule standing.
reset fixture_mt3000
addrs "br-guest 192.168.50.1/24"
seed "$(gl_rule 192.168.50.0/24)"
gl_cond guest
ks_main arm > "$T/out" 2>&1
is "SR8 non-vacuity: armed with guest on 192.168.50.0/24, swapped and recorded" \
    "$(to_rule 192.168.50.0/24):guest 192.168.50.0/24" "$(prio0):$(marker)"
# The renumber. GL's LAN rule for the LAN's new network is identical to the swap's old guest rule,
# so the kernel keeps the one copy; GL adds its from-rule for guest's new network, and the next
# armed pass swaps that too.
addrs "br-lan 192.168.50.1/24" "br-guest 192.168.160.1/24"
seed "$(gl_rule 192.168.160.0/24)"
IP4_DEFAULT="default via 192.168.8.1 dev eth0 proto static"
UBUS_DUMP="eth0 wan"
ks_main check > "$T/out" 2>&1
is "SR8 non-vacuity: the marker holds both guest networks, the LAN's network first" "guest 192.168.50.0/24
guest 192.168.160.0/24" "$(marker)"
is "SR8 non-vacuity: one rule for 192.168.50.0/24 (now the LAN's), and the new guest to-rule" \
    "$(to_rule 192.168.50.0/24)
$(to_rule 192.168.160.0/24)" "$(prio0)"
counters_reset
ks_main disarm > "$T/out" 2>&1; rc=$?
is "SR8 disarm rc 0"                   0 "$rc"
is "SR8 the LAN's to-rule survives; guest's own is gone and GL's guest rule is back" \
    "$(to_rule 192.168.50.0/24)
$(gl_rule 192.168.160.0/24)" "$(prio0)"
is "SR8 no delete was even tried for the LAN's network" "" "$(grep -e 'del priority 0 to 192.168.50.0/24' "$T/ip-calls")"
is "SR8 guest's current network was deleted as usual" 2 "$(grep -cxF -e '-4 rule del priority 0 to 192.168.160.0/24 lookup main' "$T/ip-calls")"
is "SR8 one line: what was removed, how many were left (a count, no network), what was re-added" \
    "-t ts-fix ks: source-rule swap undone: removed the to-rule for guest 192.168.160.0/24; left 1 to-rule(s) in place, the network now another bridge's; re-added GL's from-rule for guest 192.168.160.0/24" \
    "$(grep -e 'source-rule swap' "$T/log")"
is "SR8 exactly one -br addr read for the whole undo" 1 "$(grep -c -e '-br addr' "$T/ip-calls")"
is "SR8 ipcalc once per addressed bridge: br-lan for the guard, br-guest for the re-add" \
    "1:192.168.50.1/24
1:192.168.160.1/24" "$(ipcalcs)"
if [ -e "$KS_SWAP_MARK" ]; then nok "SR8 the marker is gone" "absent" "present"; else ok "SR8 the marker is gone"; fi
echo "  SR8b: the guard's other direction — a normal undo still deletes, and the read comes first"
reset fixture_mt3000
addrs "br-lan 192.168.50.1/24" "br-guest 192.168.160.1/24"
seed_gl_lan
seed "$(to_rule 192.168.160.0/24)"
printf 'guest 192.168.160.0/24\n' > "$KS_SWAP_MARK"
counters_reset
_ks_swap_restore > "$T/out" 2>&1; rc=$?
is "SR8b rc 0"                         0 "$rc"
is "SR8b the read, then the delete (it hits, then misses), then nothing: no exit node, no re-add" \
    "-4 -br addr
-4 rule del priority 0 to 192.168.160.0/24 lookup main
-4 rule del priority 0 to 192.168.160.0/24 lookup main" "$(ipcalls)"
is "SR8b ours gone, GL's LAN and uplink rules untouched" "$(to_rule 192.168.50.0/24)
$(to_rule 192.168.200.0/24)" "$(prio0)"
is "SR8b the log says only what was removed" \
    "-t ts-fix ks: source-rule swap undone: removed the to-rule for guest 192.168.160.0/24" "$(logtext)"
echo "  SR8c: the other swap bridge counts too: guest's old network, now iot's"
reset fixture_mt3000
addrs "br-lan 192.168.50.1/24" "br-guest 192.168.160.1/24" "br-iot 192.168.10.1/24"
seed "$(to_rule 192.168.10.0/24)"
printf 'guest 192.168.10.0/24\n' > "$KS_SWAP_MARK"
counters_reset
_ks_swap_restore > "$T/out" 2>&1; rc=$?
is "SR8c rc 0, iot's to-rule kept"     "0 $(to_rule 192.168.10.0/24)" "$rc $(prio0)"
has "SR8c ... and counted"             "left 1 to-rule(s) in place, the network now another bridge's" "$(logtext)"
# With iot's own entry beside it, the iot entry is the one that owns the rule, and it deletes it.
printf 'guest 192.168.10.0/24\niot 192.168.10.0/24\n' > "$KS_SWAP_MARK"
counters_reset
_ks_swap_restore > "$T/out" 2>&1; rc=$?
is "SR8c with iot's own entry: rc 0, the rule is gone" "0 " "$rc $(prio0)"
has "SR8c ... removed by iot's entry, guest's still counted as left" \
    "removed the to-rule for iot 192.168.10.0/24; left 1 to-rule(s) in place" "$(logtext)"
echo "  SR8d: a bridge whose address yields no valid network might be the one: kept, ERROR, rc 1"
reset fixture_mt3000
addrs "br-lan 192.168.99.1/24" "br-guest 192.168.160.1/24"   # ipcalc's table does not know .99
seed "$(to_rule 192.168.160.0/24)"
printf 'guest 192.168.160.0/24\n' > "$KS_SWAP_MARK"
counters_reset
_ks_swap_restore > "$T/out" 2>&1; rc=$?
is "SR8d rc 1"                         1 "$rc"
is "SR8d no delete issued, the to-rule stays" ":$(to_rule 192.168.160.0/24)" "$(grep ' del ' "$T/ip-calls"):$(prio0)"
is "SR8d exactly one ERROR, naming the bridge and its address" "1 yes" "$(grep -c ERROR "$T/log") $(case "$(logtext)" in
    *"ERROR source-rule swap undo: no valid network for br-lan (192.168.99.1/24 via $KS_IPCALC)"*) echo yes ;; *) echo no ;; esac)"
hasnt "SR8d the unsure entry is not counted as another bridge's" "left 1" "$(logtext)"
if [ -e "$KS_SWAP_MARK" ]; then nok "SR8d the marker is gone" "absent" "present"; else ok "SR8d the marker is gone"; fi
echo "  SR8e: every entry owned by Route Guest -> not even the address read"
reset fixture_mt3000
addrs "br-lan 192.168.50.1/24" "br-guest 192.168.160.1/24"
seed "$(to_rule 192.168.160.0/24)"
printf 'guest 192.168.160.0/24\n' > "$KS_SWAP_MARK"
uci set ts-fix.settings.route_guest=1
gl_cond guest
counters_reset
_ks_swap_restore > "$T/out" 2>&1; rc=$?
is "SR8e rc 0, zero ip and ipcalc calls, the to-rule kept" "0 ::$(to_rule 192.168.160.0/24)" "$rc $(ipcalls):$(ipcalcs):$(prio0)"

echo "--- case SR9: GL's rule is re-added only on GL's own path: Tailscale enabled, in Router mode"
# gl_tailscale on GL 4.9.0 and 4.11.0 (read on live routers 2026-10-02): every restart deletes the
# rules GL tracks, exits unless glconfig.general.mode is exactly 'router', and adds the guest/iot
# source rules back only inside `if [ "$enabled" = "1" ]`, with an exit node set and the zone's
# disabled exactly '0'. A copy the undo re-added anywhere else is tracked by nothing: re-added while
# Tailscale was off, it sat at priority 0 ahead of the slider accessory's transition lockdown on the
# next turn-on (GL 4.11.0, 2026-10-01). Every variant meets GL's exit-node and zone condition, with
# guest and iot both swapped and GL's LAN rules beside them, so only the pair under test varies.
sr9() {   # <label> <tailscale.settings.enabled> <glconfig.general.mode>; "-" = the option absent
    sr9_l="$1" sr9_en="$2" sr9_md="$3"
    reset fixture_mt3000
    addrs "br-lan 192.168.50.1/24" "br-guest 192.168.160.1/24" "br-iot 192.168.10.1/24"
    seed_gl_lan
    seed "$(to_rule 192.168.160.0/24)" "$(to_rule 192.168.10.0/24)"
    printf 'guest 192.168.160.0/24\niot 192.168.10.0/24\n' > "$KS_SWAP_MARK"
    gl_cond guest iot
    if [ "$sr9_en" = "-" ]; then uci -q delete tailscale.settings.enabled; else uci set "tailscale.settings.enabled=$sr9_en"; fi
    if [ "$sr9_md" = "-" ]; then uci -q delete glconfig.general.mode; else uci set "glconfig.general.mode=$sr9_md"; fi
    counters_reset
    _ks_swap_restore > "$T/out" 2>&1; rc=$?
    is "SR9$sr9_l rc 0"                    0 "$rc"
    if [ -e "$KS_SWAP_MARK" ]; then nok "SR9$sr9_l the marker is gone" "absent" "present"; else ok "SR9$sr9_l the marker is gone"; fi
}
sr9_none() {   # the same, where GL would have no rule: the to-rules go, and nothing is re-added
    sr9 "$1" "$2" "$3"
    is "SR9$sr9_l ours removed, GL's LAN rules untouched, no from-rule re-added" "$(to_rule 192.168.50.0/24)
$(to_rule 192.168.200.0/24)" "$(prio0)"
    is "SR9$sr9_l no rule list for a re-add, and no add at all" "" "$(grep -e 'rule list priority 0' -e ' add ' "$T/ip-calls")"
    is "SR9$sr9_l the one summary line names the removals only" \
        "-t ts-fix ks: source-rule swap undone: removed the to-rule for guest 192.168.160.0/24, iot 192.168.10.0/24" "$(logtext)"
}
echo "  SR9a: enabled='0', mode 'router' -> nothing re-added"
sr9_none a 0 router
echo "  SR9b: enabled absent, mode 'router' -> nothing re-added"
sr9_none b - router
echo "  SR9c: enabled='1', mode 'ap' -> nothing re-added"
sr9_none c 1 ap
echo "  SR9d: enabled='1', mode absent -> nothing re-added"
sr9_none d 1 -
echo "  SR9e: the control: enabled='1', mode 'router' -> both re-added, as before"
sr9 e 1 router
is "SR9e ours removed, GL's rules back" "$(to_rule 192.168.50.0/24)
$(to_rule 192.168.200.0/24)
$(gl_rule 192.168.160.0/24)
$(gl_rule 192.168.10.0/24)" "$(prio0)"
is "SR9e the one summary line names the removals and the re-adds" \
    "-t ts-fix ks: source-rule swap undone: removed the to-rule for guest 192.168.160.0/24, iot 192.168.10.0/24; re-added GL's from-rule for guest 192.168.160.0/24, iot 192.168.10.0/24" "$(logtext)"
is "SR9e enabled, mode and exit_node_ip each read exactly once by the undo" "1 1 1" \
    "$(grep -cxF 'uci -q get tailscale.settings.enabled' "$T/uci-calls") $(grep -cxF 'uci -q get glconfig.general.mode' "$T/uci-calls") $(grep -cxF 'uci -q get tailscale.settings.exit_node_ip' "$T/uci-calls")"
echo "  SR9f: the public paths with Tailscale disabled: disarm (the teardown) and the disarmed poll"
s6_arm
gl_cond guest iot
uci set tailscale.settings.enabled=0
is "SR9f disarm non-vacuity: both swapped and recorded" "$(to_rule 192.168.50.0/24)
$(to_rule 192.168.200.0/24)
$(to_rule 192.168.160.0/24)
$(to_rule 192.168.10.0/24):guest 192.168.160.0/24
iot 192.168.10.0/24" "$(prio0):$(marker)"
counters_reset
ks_main disarm > "$T/out" 2>&1; rc=$?
is "SR9f disarm rc 0"                  0 "$rc"
is "SR9f disarm: ours removed, GL's LAN rules untouched, no from-rule re-added" "$(to_rule 192.168.50.0/24)
$(to_rule 192.168.200.0/24)" "$(prio0)"
is "SR9f disarm: no add issued"        "" "$(grep -e ' add ' "$T/ip-calls")"
if [ -e "$KS_SWAP_MARK" ]; then nok "SR9f disarm: the marker is gone" "absent" "present"; else ok "SR9f disarm: the marker is gone"; fi
is "SR9f disarm: the one swap line names the removals only" \
    "-t ts-fix ks: source-rule swap undone: removed the to-rule for guest 192.168.160.0/24, iot 192.168.10.0/24" \
    "$(grep -e 'source-rule swap' "$T/log")"
reset fixture_mt3000
uci set tailscale.settings.enabled=0                # the toggle stays on; Tailscale is what is off
addrs "br-lan 192.168.50.1/24" "br-guest 192.168.160.1/24" "br-iot 192.168.10.1/24"
seed_gl_lan
seed "$(to_rule 192.168.160.0/24)" "$(to_rule 192.168.10.0/24)"   # a swap left behind; no rule layer
printf 'guest 192.168.160.0/24\niot 192.168.10.0/24\n' > "$KS_SWAP_MARK"
gl_cond guest iot
counters_reset
ks_main check > "$T/out" 2>&1; rc=$?
is "SR9f check rc 0"                   0 "$rc"
is "SR9f check: the disarmed branch, its 5279 probe first" "-4 rule list priority 5279" "$(head -n 1 "$T/ip-calls")"
is "SR9f check: ours removed, GL's LAN rules untouched, no from-rule re-added" "$(to_rule 192.168.50.0/24)
$(to_rule 192.168.200.0/24)" "$(prio0)"
is "SR9f check: no add issued"         "" "$(grep -e ' add ' "$T/ip-calls")"
if [ -e "$KS_SWAP_MARK" ]; then nok "SR9f check: the marker is gone" "absent" "present"; else ok "SR9f check: the marker is gone"; fi
is "SR9f check: exactly one log line, the stale-swap summary naming the removals only" \
    "-t ts-fix ks: source-rule swap found with no armed intent - undone: removed the to-rule for guest 192.168.160.0/24, iot 192.168.10.0/24" "$(logtext)"

echo "--- case SI: the swap's parsers leave the caller's IFS as they found it"
reset fixture_mt3000
addrs "br-lan 192.168.50.1/24" "br-guest 192.168.160.1/24"
seed "$(gl_rule 192.168.160.0/24)"
gl_cond guest
ifs_before="$IFS"
_ks_swap_ensure > "$T/out" 2>&1
if [ "$IFS" = "$ifs_before" ]; then ok "SI IFS intact after ensure"; else nok "SI IFS intact after ensure" "the default IFS" "changed"; fi
is "SI non-vacuity: ensure parsed an address, ipcalc output and the rule list" "$(to_rule 192.168.160.0/24)" "$(prio0)"
_ks_swap_restore > "$T/out" 2>&1
if [ "$IFS" = "$ifs_before" ]; then ok "SI IFS intact after undo"; else nok "SI IFS intact after undo" "the default IFS" "changed"; fi
is "SI non-vacuity: undo parsed the marker, an address and the rule list" "$(gl_rule 192.168.160.0/24)" "$(prio0)"
_ks_cidr_ok 192.168.160.0/24
if [ "$IFS" = "$ifs_before" ]; then ok "SI IFS intact after the validator"; else nok "SI IFS intact after the validator" "the default IFS" "changed"; fi
IFS="$ifs_before"

# ---------------------------------------------------------------------------------------------
# Marker trust. /tmp is world-writable, so what sits at the marker path may not be the engine's.
# Only a regular file, not a symlink, owned by the effective uid (_ks_swap_mark_ours) is ever read,
# acted on or removed. What the SM cases plant there names a to-rule that IS present, so a read
# would show as ip calls: zero calls, and an ensure marker without the planted line, are the proof
# that nothing was read.
sm_setup() {   # the fixture every SM case starts from: disarmed, the rule the planted line names present
    reset fixture_mt3000
    uci set ts-fix.settings.kill_switch=0                 # the disarmed poll looks at the marker too
    addrs "br-lan 192.168.50.1/24" "br-guest 192.168.176.1/24"
    seed "$(to_rule 192.168.160.0/24)"
    gl_cond guest
    printf 'guest 192.168.160.0/24\n' > "$T/planted-orig"
    cp "$IPSTATE" "$T/ip-before"
}
sm_plant() {   # $1 = link | dir | foreign: (re)put the thing at the marker path, and the rule back
    case "$1" in
        link)    rm -f "$KS_SWAP_MARK"; ln -s "$T/planted" "$KS_SWAP_MARK" ;;
        dir)     [ -d "$KS_SWAP_MARK" ] || { rm -f "$KS_SWAP_MARK"; mkdir "$KS_SWAP_MARK"; }
                 cp "$T/planted-orig" "$KS_SWAP_MARK/planted" ;;
        foreign) rm -f "$KS_SWAP_MARK"; cp "$T/planted-orig" "$KS_SWAP_MARK"; MARK_FOREIGN=1 ;;
    esac
    cp "$T/planted-orig" "$T/planted"
    cp "$T/ip-before" "$IPSTATE"
    counters_reset
}
sm_still_there() {   # $1 = kind -> rc 0 when the planted thing is at the marker path, unchanged
    case "$1" in
        link)    [ -L "$KS_SWAP_MARK" ] && cmp -s "$T/planted-orig" "$T/planted" ;;
        dir)     [ -d "$KS_SWAP_MARK" ] && cmp -s "$T/planted-orig" "$KS_SWAP_MARK/planted" ;;
        foreign) [ -f "$KS_SWAP_MARK" ] && [ ! -L "$KS_SWAP_MARK" ] && cmp -s "$T/planted-orig" "$KS_SWAP_MARK" ;;
    esac
}
sm_left_alone() {   # $1 = kind, $2 = label: the disarmed poll, then the undo, each on a fresh plant
    sm_plant "$1"
    ks_main check > "$T/out" 2>&1; rc=$?
    is "$2: the disarmed poll costs its one 5279 probe and nothing else, silently" \
        "0 -4 rule list priority 5279::" "$rc $(ipcalls):$(ipcalcs):$(logtext)"
    if sm_still_there "$1"; then ok "$2: ... leaves it where it is"; else nok "$2: ... leaves it where it is" "untouched" "$(ls -la "$KS_SWAP_MARK" 2>&1)"; fi
    if cmp -s "$T/ip-before" "$IPSTATE"; then ok "$2: ... and the rule it names"
    else nok "$2: ... and the rule it names" "$(cat "$T/ip-before")" "$(cat "$IPSTATE")"; fi
    sm_plant "$1"
    _ks_swap_restore > "$T/out" 2>&1; rc=$?
    is "$2: the undo returns 0 with no ip, uci or ipcalc call and no log" "0 :::" \
        "$rc $(ipcalls):$(cat "$T/uci-calls"):$(ipcalcs):$(logtext)"
    if sm_still_there "$1"; then ok "$2: ... leaves it where it is"; else nok "$2: ... leaves it where it is" "untouched" "$(ls -la "$KS_SWAP_MARK" 2>&1)"; fi
    if cmp -s "$T/ip-before" "$IPSTATE"; then ok "$2: ... and the rule it names"
    else nok "$2: ... and the rule it names" "$(cat "$T/ip-before")" "$(cat "$IPSTATE")"; fi
    sm_plant "$1"
    _ks_swap_mark_write "" > "$T/out" 2>&1           # "no line left: remove the marker"
    if sm_still_there "$1"; then ok "$2: an empty marker write removes only a marker of ours, not this"
    else nok "$2: an empty marker write removes only a marker of ours, not this" "untouched" "$(ls -la "$KS_SWAP_MARK" 2>&1)"; fi
}

echo "--- case SMP: the marker-trust predicate is the three tests R1-1 names, verbatim"
# Behaviour pins the symlink and directory halves (SM1, SM2); the owner half cannot be exercised
# without privilege — MARK_FOREIGN only plays it — so its text is pinned here.
is "SMP _ks_swap_mark_ours: regular file, not a symlink, owned by the effective uid" \
    '    [ -f "$KS_SWAP_MARK" ] && [ ! -L "$KS_SWAP_MARK" ] && [ -O "$KS_SWAP_MARK" ]' \
    "$(sed -n '/^_ks_swap_mark_ours() {$/,/^}$/p' "$SRC" | sed -n '2p')"
is "SMP ... and the function is exactly that one line" 3 \
    "$(sed -n '/^_ks_swap_mark_ours() {$/,/^}$/p' "$SRC" | grep -c .)"

echo "--- case SM1: a symlink at the marker path is never read, acted on or removed; ensure replaces it"
sm_setup
sm_left_alone link "SM1"
sm_plant link
_ks_swap_ensure > "$T/out" 2>&1; rc=$?
is "SM1 ensure afterwards: rc 0"       0 "$rc"
if [ -f "$KS_SWAP_MARK" ] && [ ! -L "$KS_SWAP_MARK" ]; then ok "SM1 ... the link was replaced by a regular file"
else nok "SM1 ... the link was replaced by a regular file" "a regular file" "$(ls -ld "$KS_SWAP_MARK")"; fi
is "SM1 ... holding exactly this pass's network, nothing read from the link" "guest 192.168.176.0/24" "$(marker)"
if cmp -s "$T/planted-orig" "$T/planted"; then ok "SM1 ... and nothing was written through the link"
else nok "SM1 ... and nothing was written through the link" "the target unchanged" "$(cat "$T/planted")"; fi
is "SM1 ... no temp file left"         "" "$(tmpleft)"
echo "  SM1b: a symlink to a directory: ensure refuses it, and moves nothing into the directory"
# mv follows a destination symlink that names a directory and moves the temp file INTO it, so the
# write's directory refusal must hold for a link to one too.
sm_setup
mkdir "$T/linked-dir"
ln -s "$T/linked-dir" "$KS_SWAP_MARK"
counters_reset
_ks_swap_ensure > "$T/out" 2>&1; rc=$?
is "SM1b rc 1, and an ERROR that says why" "1 yes" \
    "$rc $(case "$(logtext)" in *"could not write $KS_SWAP_MARK (it is a directory)"*) echo yes ;; *) echo no ;; esac)"
is "SM1b nothing moved into the linked directory" "" "$(ls -A "$T/linked-dir")"
if [ -L "$KS_SWAP_MARK" ]; then ok "SM1b the link itself is left where it is"; else nok "SM1b the link itself is left where it is" "the link" "gone"; fi
is "SM1b no temp file left"            "" "$(tmpleft)"
rm -f "$KS_SWAP_MARK"; rmdir "$T/linked-dir"

echo "--- case SM2: a directory at the marker path is never read, acted on or removed"
sm_setup
sm_left_alone dir "SM2"
# rename cannot replace a directory, and mv would move the temp file INTO it: ensure refuses,
# loudly, and leaves it alone.
sm_plant dir
_ks_swap_ensure > "$T/out" 2>&1; rc=$?
is "SM2 ensure while it stands: rc 1"  1 "$rc"
has "SM2 ... an ERROR that says why"    "could not write $KS_SWAP_MARK (it is a directory)" "$(logtext)"
is "SM2 ... nothing put inside it"     "planted" "$(ls -A "$KS_SWAP_MARK")"
is "SM2 ... no temp file left"         "" "$(tmpleft)"
rm -r "$KS_SWAP_MARK"                               # its owner takes it away
counters_reset
_ks_swap_ensure > "$T/out" 2>&1; rc=$?
is "SM2 ensure once it is gone: rc 0, the correct marker" "0 guest 192.168.176.0/24" "$rc $(marker)"

echo "--- case SM3: another user's file at the marker path is never read, acted on or removed; ensure replaces it"
sm_setup
sm_left_alone foreign "SM3"
sm_plant foreign
old_inode=$(inode "$KS_SWAP_MARK")
_ks_swap_ensure > "$T/out" 2>&1; rc=$?
is "SM3 ensure afterwards: rc 0"       0 "$rc"
is "SM3 ... holding exactly this pass's network, nothing merged from the file" "guest 192.168.176.0/24" "$(marker)"
if [ "$(inode "$KS_SWAP_MARK")" != "$old_inode" ]; then ok "SM3 ... in a new file: replaced by rename, not rewritten in place"
else nok "SM3 ... in a new file: replaced by rename, not rewritten in place" "a new inode" "$old_inode"; fi
is "SM3 ... no temp file left"         "" "$(tmpleft)"
MARK_FOREIGN=""

# =============================================================================================
# preboot, the pre-firewall pass. On the first boot after a keep-settings firmware upgrade, GL's ROM
# uci-default 99-vpn-client sets every lan -> wan and guest -> wan forwarding back to enabled='1'
# at boot step 10, before S19firewall applies UCI. An init script at START=18 runs
# `ts-fix-ks preboot` in between: it re-severs in UCI and commits WITHOUT a firewall reload, since
# the firewall's own start comes next and reads the committed config. It makes no ip, ubus,
# jsonfilter or tailscale call, and runs neither the invariant nor the scope scan.

echo "--- case P1: preboot re-severs what the first-boot defaults re-enabled, before the firewall"
reset fixture_mt3000
first_boot_state
rm -f "$KS_LOCK"
counters_reset
preboot_run; rc=$?
is "P1 rc"                             0 "$rc"
is "P1 lan:wan re-severed"             0 "$(g 'firewall.@forwarding[0].enabled')"
is "P1 guest:wan re-severed"           0 "$(g 'firewall.@forwarding[14].enabled')"
if cmp -s "$T/armed" "$STATE"; then ok "P1 the config is the armed one again, sidecar untouched"
else nok "P1 the config is the armed one again, sidecar untouched" "identical to the armed config" "state differs"; fi
is "P1 commits both packages"          "firewall
ts-fix" "$(commits)"
is "P1 zero firewall reloads"          0 "$(reloads)"
is "P1 zero ip calls"                  "" "$(ipcalls)"
is "P1 no ubus, jsonfilter or tailscale call" "" "$(othercalls)"
is "P1 no scope scan (zero awk)"       0 "$(grep -c . "$T/ext-calls")"
is "P1 exactly one log line"           1 "$(grep -c . "$T/log")"
is "P1 which names both pairs and says when" \
    "-t ts-fix ks: preboot re-severed lan:wan guest:wan before the firewall started" "$(logtext)"
is "P1 nothing on stdout or stderr"    "" "$(cat "$T/out")"
if [ -e "$KS_LOCK" ]; then ok "P1 it ran under the engine lock"
else nok "P1 it ran under the engine lock" "the lock file" "absent"; fi

echo "--- case P2: with no armed intent preboot is a silent no-op (a stranded sidecar is check's job)"
for off in ts-fix.settings.kill_switch=0 tailscale.settings.enabled=0; do
    reset fixture_mt3000
    first_boot_state
    uci set "$off"
    cp "$STATE" "$T/before"
    counters_reset
    preboot_run; rc=$?
    is "P2 $off: rc 0"                 0 "$rc"
    if cmp -s "$T/before" "$STATE"; then ok "P2 $off: no writes"; else nok "P2 $off: no writes" "no writes" "state differs"; fi
    is "P2 $off: zero commits"         "" "$(commits)"
    is "P2 $off: zero reloads"         0 "$(reloads)"
    is "P2 $off: no log"               "" "$(logtext)"
    is "P2 $off: zero ip calls"        "" "$(ipcalls)"
done

echo "--- case P3: a refused mode makes preboot a silent no-op too (rc 0, where arm returns 2)"
reset fixture_mt3000
first_boot_state
uci set glconfig.general.mode=extender
cp "$STATE" "$T/before"
counters_reset
preboot_run; rc=$?
is "P3 rc 0"                           0 "$rc"
if cmp -s "$T/before" "$STATE"; then ok "P3 no writes"; else nok "P3 no writes" "no writes" "state differs"; fi
is "P3 zero commits"                   "" "$(commits)"
is "P3 zero reloads"                   0 "$(reloads)"
is "P3 no log"                         "" "$(logtext)"
is "P3 nothing on stdout or stderr"    "" "$(cat "$T/out")"
is "P3 zero ip calls"                  "" "$(ipcalls)"

echo "--- case P4: a commit that cannot land is rc 1, the sentinel and an ERROR — and still no reload"
reset fixture_mt3000
first_boot_state
UCI_COMMIT_FAIL=1
counters_reset
preboot_run; rc=$?
is "P4 rc is 1"                        1 "$rc"
if [ -s "$T/commit-attempts" ]; then ok "P4 non-vacuity: a commit was attempted"
else nok "P4 non-vacuity: a commit was attempted" "commit attempts" "none"; fi
if [ -f "$KS_COMMIT_FAIL" ]; then ok "P4 the commit-failed sentinel is present"
else nok "P4 the commit-failed sentinel is present" "sentinel file" "absent"; fi
has "P4 ERROR logged"                  "ERROR uci commit failed" "$(logtext)"
has "P4 which says NOT effective"      "NOT effective" "$(logtext)"
hasnt "P4 no success line"             "before the firewall started" "$(logtext)"
is "P4 zero reloads on this path too"  0 "$(reloads)"
is "P4 zero ip calls"                  "" "$(ipcalls)"
# The sentinel hands the retry to the normal passes: the next check commits and reloads.
UCI_COMMIT_FAIL=""
counters_reset
ks_main check > "$T/out" 2>&1; rc=$?
is "P4 the next check retries: rc 0"   0 "$rc"
is "P4 ... it commits both packages"   "firewall
ts-fix" "$(commits)"
is "P4 ... and reloads"                1 "$(reloads)"
if [ -f "$KS_COMMIT_FAIL" ]; then nok "P4 ... and clears the sentinel" "no sentinel" "still there"
else ok "P4 ... and clears the sentinel"; fi

echo "--- case P5: an unreadable firewall config is one ERROR line and rc 1, with nothing written"
reset fixture_no_firewall
cp "$STATE" "$T/before"
counters_reset
preboot_run; rc=$?
is "P5 rc is 1"                        1 "$rc"
is "P5 exactly one log line"           1 "$(grep -c . "$T/log")"
has "P5 an ERROR"                      "ERROR" "$(logtext)"
if cmp -s "$T/before" "$STATE"; then ok "P5 nothing written"; else nok "P5 nothing written" "no writes" "state differs"; fi
is "P5 zero commits"                   "" "$(commits)"
is "P5 zero reloads"                   0 "$(reloads)"
is "P5 zero ip calls (no rule-layer ensure, unlike arm and check)" "" "$(ipcalls)"

echo "--- case P6: an ordinary boot has nothing to re-sever: no commit, no reload, no log"
reset fixture_mt3000
ks_main arm > "$T/out" 2>&1
: > "$IPSTATE"
cp "$STATE" "$T/before"
counters_reset
preboot_run; rc=$?
is "P6 rc 0"                           0 "$rc"
if cmp -s "$T/before" "$STATE"; then ok "P6 no writes"; else nok "P6 no writes" "no writes" "state differs"; fi
is "P6 zero commits"                   "" "$(commits)"
is "P6 zero reloads"                   0 "$(reloads)"
is "P6 no log"                         "" "$(logtext)"
is "P6 zero ip calls"                  "" "$(ipcalls)"

echo "--- case P7: a qualifying forwarding that is new at boot is severed and recorded, same one line"
reset fixture_mt3000
first_boot_state
uci set firewall.lan_awgc=forwarding
uci set firewall.lan_awgc.src=lan
uci set firewall.lan_awgc.dest=awgclient
uci set firewall.lan_awgc.enabled=1
counters_reset
preboot_run; rc=$?
is "P7 rc 0"                           0 "$rc"
is "P7 the new forwarding severed"     0 "$(g firewall.lan_awgc.enabled)"
is "P7 and recorded"                   "lan:wan lan:zerotier guest:awgclient iot:wan guest:wan lan:awgclient" "$(sev)"
is "P7 zero reloads"                   0 "$(reloads)"
is "P7 one line names both kinds"      \
    "-t ts-fix ks: preboot re-severed lan:wan guest:wan and severed new lan:awgclient before the firewall started" "$(logtext)"

echo "--- case P8: a tunnel path lost at boot is recreated in the same pass, still without a reload"
reset fixture_mt3000
ks_main arm > "$T/out" 2>&1
uci -q delete firewall.ts_fix_lan2ts
: > "$IPSTATE"
counters_reset
preboot_run; rc=$?
is "P8 rc 0"                           0 "$rc"
is "P8 lan2ts recreated"               forwarding "$(g firewall.ts_fix_lan2ts)"
is "P8 ... enabled"                    1 "$(g firewall.ts_fix_lan2ts.enabled)"
is "P8 committed"                      "firewall
ts-fix" "$(commits)"
is "P8 zero reloads"                   0 "$(reloads)"
is "P8 one log line, the tunnel path's own" 1 "$(grep -c . "$T/log")"
has "P8 which says so"                 "created lan -> tailscale0" "$(logtext)"

echo "--- case P9: the dispatcher's usage string lists preboot"
reset fixture_mt3000
ks_main bogus > "$T/out" 2>&1
has "P9 usage lists preboot"           "|preboot" "$(cat "$T/out")"

echo "--- case P10: an unset mode does not stop preboot, and adds no warning line"
reset fixture_mt3000
first_boot_state
uci -q delete glconfig.general.mode
counters_reset
preboot_run; rc=$?
is "P10 rc 0"                          0 "$rc"
is "P10 lan:wan re-severed"            0 "$(g 'firewall.@forwarding[0].enabled')"
is "P10 still exactly one log line"    1 "$(grep -c . "$T/log")"
hasnt "P10 no WARNING"                 "WARNING" "$(logtext)"

echo "--- case P11: a remembered commit failure is retried by preboot too: committed, not reloaded"
reset fixture_mt3000
ks_main arm > "$T/out" 2>&1
touch "$KS_COMMIT_FAIL"
counters_reset
preboot_run; rc=$?
is "P11 rc 0"                          0 "$rc"
is "P11 commits both packages"         "firewall
ts-fix" "$(commits)"
is "P11 zero reloads"                  0 "$(reloads)"
if [ -f "$KS_COMMIT_FAIL" ]; then nok "P11 the sentinel is cleared" "no sentinel" "still there"
else ok "P11 the sentinel is cleared"; fi
is "P11 no log"                        "" "$(logtext)"

echo "--- case S15: preboot without TS_FIX_KS_BOOT=1 is refused before the lock, any uci or any ip"
# On a live router preboot's commit would reach UCI and not netfilter, and check would then find
# nothing to change and reload nothing — so it runs only when boot() hands it the variable. The
# P-cases above are the other direction: TS_FIX_KS_BOOT=1, exactly, runs the pass.
for v in unset '' 0 01 yes ' 1' '1 '; do
    reset fixture_mt3000
    first_boot_state
    rm -f "$KS_LOCK"
    cp "$STATE" "$T/before"
    counters_reset
    if [ "$v" = "unset" ]; then label="unset"; else label="'$v'"; TS_FIX_KS_BOOT="$v"; fi
    ks_main preboot > "$T/out" 2> "$T/err"; rc=$?
    unset TS_FIX_KS_BOOT
    is "S15 $label: rc 2"              2 "$rc"
    is "S15 $label: one line on stderr" 1 "$(grep -c . "$T/err")"
    has "S15 $label: ... naming the boot script and check" \
        "preboot runs only from /etc/init.d/ts-fix-preboot at boot; on a running router use 'ts-fix-ks check'" "$(cat "$T/err")"
    is "S15 $label: nothing on stdout" "" "$(cat "$T/out")"
    is "S15 $label: one log line"      1 "$(grep -c . "$T/log")"
    is "S15 $label: zero uci and ip calls" ":" "$(cat "$T/uci-calls"):$(ipcalls)"
    if [ -e "$KS_LOCK" ]; then nok "S15 $label: the lock was never taken" "no lock file" "lock file created"
    else ok "S15 $label: the lock was never taken"; fi
    if cmp -s "$T/before" "$STATE"; then ok "S15 $label: nothing written"; else nok "S15 $label: nothing written" "no writes" "state differs"; fi
done

echo "--- case S16: the boot script passes TS_FIX_KS_BOOT=1; reapply re-swaps right after GL's chain"
INIT="$(dirname "$0")/../../src/init.d/ts-fix-preboot"
REAPPLY="$(dirname "$0")/../../src/scripts/ts-fix-reapply"
is "S16 the init script invokes preboot exactly once" 1 "$(grep -cF '/usr/bin/ts-fix-ks preboot' "$INIT")"
is "S16 ... prefixed TS_FIX_KS_BOOT=1" 1 "$(grep -cE '^[[:space:]]*TS_FIX_KS_BOOT=1 /usr/bin/ts-fix-ks preboot( |$)' "$INIT")"
is "S16 reapply calls rules-ensure exactly thrice (after GL's chain; after Route Guest's delete, case SG; after Route IoT's delete)" 3 "$(grep -cF 'ts-fix-ks rules-ensure' "$REAPPLY")"
wait_ln=$(grep -nF 'pgrep -f "gl_tailscale restart"' "$REAPPLY" | cut -d: -f1)
run_ln=$(grep -n '^# Now wait for Running state' "$REAPPLY" | cut -d: -f1)
re_ln=$(grep -n '^/usr/bin/ts-fix-ks rules-ensure </dev/null$' "$REAPPLY" | cut -d: -f1)
done_ln=""
[ -n "$wait_ln" ] && done_ln=$(tail -n "+$wait_ln" "$REAPPLY" | grep -n '^done$' | head -n 1 | cut -d: -f1)
[ -n "$done_ln" ] && done_ln=$((wait_ln + done_ln - 1))
is "S16 non-vacuity: one wait loop, one Running wait, one call" "1 1 1" \
    "$(printf '%s\n' "$wait_ln" | grep -c .) $(printf '%s\n' "$run_ln" | grep -c .) $(printf '%s\n' "$re_ln" | grep -c .)"
if [ -n "$done_ln" ] && [ -n "$re_ln" ] && [ -n "$run_ln" ] && [ "$done_ln" -lt "$re_ln" ] && [ "$re_ln" -lt "$run_ln" ]; then
    ok "S16 the call sits after the gl_tailscale wait loop and before the Running wait"
else
    nok "S16 the call sits after the gl_tailscale wait loop and before the Running wait" "done < call < Running" "[$done_ln] [$re_ln] [$run_ln]"
fi
between=""
[ -n "$done_ln" ] && [ -n "$re_ln" ] && between=$(sed -n "$((done_ln + 1)),$((re_ln - 1))p" "$REAPPLY" | grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$')
is "S16 ... immediately after the loop: nothing but comments between" "" "$between"

echo "--- case SG: where Route Guest's cleanup deletes the guest to-rule, the kill switch's copy goes back"
# While armed the engine's source-rule swap installs exactly the rule these deletes remove, so each
# delete is followed at once by the engine's own lock-free, self-gated rules-ensure. Line numbers
# are found with literal matches (awk index), so no pattern character in the code can mislead them.
lnum() { command awk -v p="$2" -v from="${3:-0}" 'NR > from && index($0, p) { print NR; exit }' "$1"; }
eqln() { command awk -v p="$2" -v from="${3:-0}" 'NR > from && $0 == p { print NR; exit }' "$1"; }
between_code() {   # <file> <after line> <before line> <comment prefix> -> the code lines between
    [ -n "$2" ] && [ -n "$3" ] || { echo "(missing line)"; return; }
    sed -n "$(($2 + 1)),$(($3 - 1))p" "$1" | grep -v -e "^[[:space:]]*$4" -e '^[[:space:]]*$'
}
rg_if=$(lnum "$REAPPLY" 'if [ "$route_guest" = "1" ] && [ -n "$guest_subnet" ]; then')
rg_else=$(eqln "$REAPPLY" 'else' "$rg_if")
rg_fi=$(eqln "$REAPPLY" 'fi' "$rg_else")
rg_del=$(lnum "$REAPPLY" 'ip rule del to "$_gs" table main 2>/dev/null' "$rg_else")
rg_call=$(lnum "$REAPPLY" '/usr/bin/ts-fix-ks rules-ensure </dev/null' "$rg_del")
if [ -n "$rg_if" ] && [ -n "$rg_else" ] && [ -n "$rg_fi" ] && [ -n "$rg_del" ] && [ -n "$rg_call" ] &&
   [ "$rg_del" -lt "$rg_call" ] && [ "$rg_call" -lt "$rg_fi" ] && [ "$rg_del" -lt "$rg_fi" ]; then
    ok "SG reapply: the call follows the delete, inside the else-branch that deletes"
else
    nok "SG reapply: the call follows the delete, inside the else-branch that deletes" \
        "else < delete < call < fi" "[$rg_else] [$rg_del] [$rg_call] [$rg_fi]"
fi
is "SG reapply: nothing but comments between the delete and the call" "" "$(between_code "$REAPPLY" "$rg_del" "$rg_call" '#')"
RPC="$(dirname "$0")/../../src/rpc/ts-fix"
fg_fn=$(lnum "$RPC" 'local function fix_guest_policy_route(enabled)')
fg_del=$(lnum "$RPC" 'exec("ip rule del to " .. guest_subnet' "$fg_fn")
fg_if=$(eqln "$RPC" '    if enabled then' "$fg_del")
fg_else=$(eqln "$RPC" '    else' "$fg_if")
fg_end=$(eqln "$RPC" '    end' "$fg_else")
fg_call=$(lnum "$RPC" 'exec("/usr/bin/ts-fix-ks rules-ensure </dev/null >/dev/null 2>&1")' "$fg_else")
is "SG RPC: exactly two rules-ensure in the module (Route Guest's and Route IoT's)" 2 "$(grep -cF 'ts-fix-ks rules-ensure' "$RPC")"
if [ -n "$fg_fn" ] && [ -n "$fg_del" ] && [ -n "$fg_if" ] && [ -n "$fg_else" ] && [ -n "$fg_end" ] && [ -n "$fg_call" ] &&
   [ "$fg_call" -lt "$fg_end" ]; then
    ok "SG RPC: the call follows the deletes, in the branch taken when Route Guest is off"
else
    nok "SG RPC: the call follows the deletes, in the branch taken when Route Guest is off" \
        "delete < if enabled < else < call < end" "[$fg_del] [$fg_if] [$fg_else] [$fg_call] [$fg_end]"
fi
is "SG RPC: nothing but comments between the else and the call" "" "$(between_code "$RPC" "$fg_else" "$fg_call" '--')"

echo "--- case TS: every \`tailscale set\` in reapply runs under a timeout, and its failure is handled"
# The watchdog runs reapply synchronously, so one hung CLI call would stall every kill-switch
# backstop behind it. ts_set_calls prints one line per `tailscale set` call in the code: "<line>
# bounded logged" for `timeout <seconds> /usr/sbin/tailscale set ... || \` followed by a
# `logger -t ts-fix` line, "<line> bounded reconcile" for the reconcile's `|| reconcile_ok=0` (it
# logs the failure further down), and "<line> UNBOUNDED" or "<line> bounded UNHANDLED" for anything
# else. Double-quoted strings are emptied first, so a logger message that names the command is not a
# call, and full-line comments are skipped. Linted on a fixture in both directions before the file.
ts_set_calls() {
    command awk '
        want > 0 && NR == want {
            if ($0 ~ /^[[:space:]]*logger -t ts-fix /) print pend " bounded logged"
            else print pend " bounded UNHANDLED"
            want = 0
        }
        /^[[:space:]]*#/ { next }
        {
            code = $0
            gsub(/"[^"]*"/, "\"\"", code)
            rest = code
            while ((i = index(rest, "tailscale set")) > 0) {
                pre = substr(rest, 1, i - 1)
                rest = substr(rest, i + 13)
                if (pre !~ /timeout [0-9]+ \/usr\/sbin\/$/) { print NR " UNBOUNDED"; continue }
                if (rest ~ /\|\| reconcile_ok=0$/) { print NR " bounded reconcile"; continue }
                if (rest ~ /\|\| \\$/) { pend = NR; want = NR + 1; continue }
                print NR " bounded UNHANDLED"
            }
        }' "$1"
}
cat > "$T/ts-set-fixture" <<'EOF'
/usr/sbin/tailscale set --ssh 2>/dev/null
    tailscale set --ssh
[ "$x" = "1" ] && /usr/sbin/tailscale set --ssh
timeout 10 /usr/sbin/tailscale set --ssh 2>/dev/null || \
    logger -t ts-fix "tailscale set --ssh failed (rc $?)"
# a comment naming tailscale set
timeout 10 /usr/sbin/tailscale set --exit-node= 2>/dev/null || reconcile_ok=0
timeout 10 /usr/sbin/tailscale set --a 2>/dev/null
timeout 10 /usr/sbin/tailscale set --b 2>/dev/null || \
    echo not a logger line
timeout 10 /usr/sbin/tailscale set --c && /usr/sbin/tailscale set --d
    logger -t ts-fix "running tailscale set --exit-node (binary: x)"
EOF
is "TS instrument lint: the fixture's calls, each classified" "1 UNBOUNDED
2 UNBOUNDED
3 UNBOUNDED
4 bounded logged
7 bounded reconcile
8 bounded UNHANDLED
9 bounded UNHANDLED
11 bounded UNHANDLED
11 UNBOUNDED" "$(ts_set_calls "$T/ts-set-fixture")"
ts_calls=$(ts_set_calls "$REAPPLY")
is "TS reapply: no unbounded or unhandled call" "" "$(printf '%s\n' "$ts_calls" | grep -e UNBOUNDED -e UNHANDLED)"
is "TS reapply: fifteen calls, thirteen logging their failure and the reconcile's two" "13 2" \
    "$(printf '%s\n' "$ts_calls" | grep -c ' bounded logged$') $(printf '%s\n' "$ts_calls" | grep -c ' bounded reconcile$')"
is "TS ... and every bound is exactly timeout 10" 15 "$(grep -c 'timeout 10 /usr/sbin/tailscale set' "$REAPPLY")"
# Every call into the CLI, reads included, in reapply and in the watchdog, which runs reapply
# synchronously. ts_cli_calls prints "<line> <subcommand> bounded" when the text right before
# `/usr/sbin/tailscale` is `timeout <seconds> `, else "<line> <subcommand> UNBOUNDED". Calls are
# found by their absolute path on every code line (full-line comments skipped), so one inside a
# double-quoted command substitution counts too. A bare `tailscale <word>` in code — a call through
# PATH, which neither file makes — is "<line> bare UNBOUNDED"; before that check, double-quoted
# strings holding no command substitution are emptied, so a logger message naming it is no call.
WATCHDOG="$(dirname "$0")/../../src/scripts/ts-fix-watchdog"
ts_cli_calls() {
    command awk '
        /^[[:space:]]*#/ { next }
        {
            rest = $0
            while ((i = index(rest, "/usr/sbin/tailscale ")) > 0) {
                pre = substr(rest, 1, i - 1)
                rest = substr(rest, i + 20)
                word = rest
                sub(/[^a-z].*$/, "", word)
                if (pre ~ /timeout [0-9]+ $/) print NR " " word " bounded"
                else print NR " " word " UNBOUNDED"
            }
            code = ""
            s = $0
            while (match(s, /"[^"]*"/)) {
                seg = substr(s, RSTART, RLENGTH)
                if (index(seg, "$(") == 0) seg = "\"\""
                code = code substr(s, 1, RSTART - 1) seg
                s = substr(s, RSTART + RLENGTH)
            }
            code = code s
            gsub(/\/usr\/sbin\/tailscale /, "", code)
            if (code ~ /(^|[[:space:];|&(`])tailscale [a-z]/) print NR " bare UNBOUNDED"
        }' "$1"
}
cat > "$T/ts-cli-fixture" <<'EOF'
x=$(/usr/sbin/tailscale debug prefs 2>/dev/null | jsonfilter -e '@.X')
x=$(timeout 10 /usr/sbin/tailscale debug prefs 2>/dev/null)
[ "$(/usr/sbin/tailscale status --json 2>/dev/null)" = "Running" ]
[ "$(timeout 10 /usr/sbin/tailscale status --json 2>/dev/null)" = "Running" ]
v=$(timeout 10 /usr/sbin/tailscale version 2>/dev/null | head -1)
    logger -t ts-fix "running tailscale set --exit-node (binary: x)"
# /usr/sbin/tailscale status in a comment
tailscale set --ssh
[ "$(uci -q get x)" = "1" ] && tailscale status
pgrep tailscaled >/dev/null && uci -q get tailscale.settings.enabled
timeout 10 /usr/sbin/tailscale set --a && /usr/sbin/tailscale set --b
pgrep -f "gl_tailscale restart" >/dev/null
x=$(timeout 3 /usr/sbin/tailscale debug prefs)
EOF
is "TS instrument lint, every CLI call: the fixture's calls, each classified" "1 debug UNBOUNDED
2 debug bounded
3 status UNBOUNDED
4 status bounded
5 version bounded
8 bare UNBOUNDED
9 bare UNBOUNDED
11 set bounded
11 set UNBOUNDED
13 debug bounded" "$(ts_cli_calls "$T/ts-cli-fixture")"
for f in "$REAPPLY" "$WATCHDOG"; do
    is "TS ${f##*/}: no unbounded call into the tailscale CLI" "" "$(ts_cli_calls "$f" | grep -e UNBOUNDED)"
done
is "TS reapply: its 25 calls by subcommand, every one bounded" "7 debug
15 set
1 status
2 version" "$(ts_cli_calls "$REAPPLY" | grep ' bounded$' | cut -d' ' -f2 | sort | uniq -c | command awk '{ print $1, $2 }')"
is "TS watchdog: its 4 calls by subcommand, every one bounded" "2 set
2 status" "$(ts_cli_calls "$WATCHDOG" | grep ' bounded$' | cut -d' ' -f2 | sort | uniq -c | command awk '{ print $1, $2 }')"
is "TS ... and every bound in both files is exactly timeout 10" "25 4" \
    "$(grep -c 'timeout 10 /usr/sbin/tailscale ' "$REAPPLY") $(grep -c 'timeout 10 /usr/sbin/tailscale ' "$WATCHDOG")"

echo "--- case TF: the timeout fallback line in reapply, the watchdog and the updater"
# All three bound calls with `timeout N ...` and carry one guarded line that, where no `timeout`
# exists, defines a function that drops the bound and runs the command as before — rather than
# failing it with 127. The line is taken from each file by its exact text and run in a child
# /bin/sh: this laptop's BusyBox ash resolves its own timeout applet without a PATH lookup, so no
# PATH can hide it there (the reason case 17 pins its child shell too).
UPDATER="$(dirname "$0")/../../src/scripts/ts-fix-update"
TF_LINE='command -v timeout >/dev/null 2>&1 || timeout() { shift; "$@"; }'
mkdir -p "$T/tf-empty" "$T/tf-fake"
cat > "$T/tf-fake/timeout" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TF_LOG"
shift
"$@"
EOF
chmod +x "$T/tf-fake/timeout"
if PATH="$T/tf-empty" /bin/sh -c 'command -v timeout' >/dev/null 2>&1; then
    nok "TF instrument lint: the child shell finds no timeout on the empty PATH" "command -v fails" "found"
else
    ok "TF instrument lint: the child shell finds no timeout on the empty PATH"
fi
is "TF instrument lint: on the fake PATH it finds the fake" "$T/tf-fake/timeout" \
    "$(PATH="$T/tf-fake" /bin/sh -c 'command -v timeout')"
for f in "$REAPPLY" "$WATCHDOG" "$UPDATER"; do
    n=${f##*/}
    is "TF $n carries the line exactly once" 1 "$(grep -c -x -F -e "$TF_LINE" "$f")"
    at=$(grep -n -x -F -e "$TF_LINE" "$f" | head -n 1 | cut -d: -f1)
    first=$(command awk '/^[[:space:]]*#/ { next } /timeout [0-9]/ { print NR; exit }' "$f")
    if [ -n "$at" ] && [ -n "$first" ] && [ "$at" -lt "$first" ]; then
        ok "TF $n: the line comes before the first bounded call"
    else
        nok "TF $n: the line comes before the first bounded call" "line < first use" "[$at] [$first]"
    fi
    line=$(grep -x -F -e "$TF_LINE" "$f" | head -n 1)
    got=$(PATH="$T/tf-empty" /bin/sh -c "$line"'
        case "$(type timeout 2>&1)" in *function*) echo function ;; *) echo not-a-function ;; esac
        timeout 10 printf "%s|" "a b" c; echo " rc=$?"
        timeout 10 /bin/sh -c "exit 7"; echo "rc=$?"' 2>&1)
    is "TF $n, no timeout on PATH: a function runs the command, arguments intact, and passes its status" \
        "function
a b|c| rc=0
rc=7" "$got"
    : > "$T/tf-log"
    got=$(TF_LOG="$T/tf-log" PATH="$T/tf-fake" /bin/sh -c "$line"'
        case "$(type timeout 2>&1)" in *function*) echo function ;; *) echo not-a-function ;; esac
        timeout 10 printf ok; echo " rc=$?"' 2>&1)
    is "TF $n, a timeout on PATH: no function is defined, the one on PATH runs" "not-a-function
ok rc=0
10 printf ok" "$got
$(cat "$T/tf-log")"
done

echo "--- case 17: ks_main serializes invokers on the engine's own lock"
# The lock lives in ks_main, which only the executed path reaches, so this case runs the script as
# a separate process against throwaway PATH stubs (every external the engine could touch is stubbed
# to fail, except that uci answers the intent's two section reads with a readable section and no
# kill_switch option, so the run takes the disarmed path — its sidecar read and its one rule probe
# both hit failing stubs — having written nothing, and no real uci/ip/logger is ever invoked). No
# pgrep is used anywhere in this harness, so there is no self-match pattern to bracket.
#
# The process runs a COPY of the engine under $T whose KS_LOCK, KS_SWAP_MARK, KS_IPCALC,
# KS_INTENTWARN and KS_RELOAD_FAIL lines are rewritten to paths inside $T — the ipcalc one to the
# harness's fake — and which is the shipping engine byte for byte everywhere else; the lint below
# asserts both. The production lock, marker and tmpfs flags are therefore never touched (the two
# flags are tested, and one removed, on every disarmed pass), and another run of this suite on the
# same host cannot contend with these cases.
#
# The child shell is pinned to /bin/sh rather than "whatever sh means to the shell running this
# suite": BusyBox ash runs sh, ip and logger as its own applets without a PATH lookup, so under it
# the stubs are never reached and the child calls the host's real ip and writes to the host's
# syslog. Before any child runs, the pinned shell must resolve every stub by PATH, and the copy
# must pass its lint; if either does not, ENGINE_SH becomes `false` and the dependent checks fail
# loudly instead of touching the host.
CHILD="$T/child"
CHILD_SRC="$CHILD/ts-fix-ks"
CHILD_LOCK="$CHILD/ks.lock"
mkdir -p "$CHILD"
# $T goes into a sed replacement and a double-quoted shell assignment, so it must hold nothing that
# either would interpret.
child_ok=yes
case "$T" in *[!A-Za-z0-9._/-]*) child_ok=no ;; esac
is "17 \$T is safe inside a sed replacement and a shell assignment (instrument lint)" yes "$child_ok"
sed -e "s|^KS_LOCK=.*|KS_LOCK=\"$CHILD_LOCK\"|" \
    -e "s|^KS_SWAP_MARK=.*|KS_SWAP_MARK=\"$CHILD/ts-fix-ks.srcswap\"|" \
    -e "s|^KS_IPCALC=.*|KS_IPCALC=\"$KS_IPCALC\"|" \
    -e "s|^KS_INTENTWARN=.*|KS_INTENTWARN=\"$CHILD/ts-fix-ks.intentwarn\"|" \
    -e "s|^KS_RELOAD_FAIL=.*|KS_RELOAD_FAIL=\"$CHILD/ts-fix-ks.reload-failed\"|" "$SRC" > "$CHILD_SRC"
for v in KS_LOCK KS_SWAP_MARK KS_IPCALC KS_INTENTWARN KS_RELOAD_FAIL; do
    line=$(grep -e "^$v=" "$CHILD_SRC")
    case "$line" in
        "$v=\"$T/"*) ok "17 the copy's $v line points into \$T" ;;
        *)
            nok "17 the copy's $v line points into \$T" "$v=\"$T/...\"" "$line"
            # An engine line that still points elsewhere must never run; a missing line has no path.
            [ -n "$line" ] && child_ok=no
            ;;
    esac
done
want=$(grep -n -e '^KS_LOCK=' -e '^KS_SWAP_MARK=' -e '^KS_IPCALC=' -e '^KS_INTENTWARN=' -e '^KS_RELOAD_FAIL=' "$SRC" | cut -d: -f1)
got=$(command awk 'NR == FNR { a[FNR] = $0; n = FNR; next } a[FNR] != $0 { print FNR } END { if (FNR != n) print "length" }' "$SRC" "$CHILD_SRC")
is "17 the copy differs from the engine on exactly those lines" "$want" "$got"
is "17 ... which are five, one definition each" 5 "$(printf '%s\n' "$want" | grep -c .)"
[ "$want" = "$got" ] || child_ok=no
mkdir -p "$T/bin"
for stub in uci ip ubus jsonfilter logger; do
    printf '#!/bin/sh\nexit 1\n' > "$T/bin/$stub"
    chmod +x "$T/bin/$stub"
done
cat > "$T/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
    "-q show ts-fix.settings"|"-q show tailscale.settings") echo "${3}=settings" ;;
    *) exit 1 ;;
esac
EOF
ENGINE_SH=/bin/sh
stubs_ok=yes
for stub in uci ip ubus jsonfilter logger; do
    [ "$(PATH="$T/bin:$PATH" "$ENGINE_SH" -c "command -v $stub")" = "$T/bin/$stub" ] || stubs_ok=no
done
is "17 the child shell resolves every stub by PATH (instrument lint)" yes "$stubs_ok"
[ "$stubs_ok" = "yes" ] && [ "$child_ok" = "yes" ] || ENGINE_SH=false
rm -f "$T/holder-ready"
( exec 9>"$CHILD_LOCK"; flock 9; touch "$T/holder-ready"; sleep 3 ) </dev/null >/dev/null 2>&1 &
holder_pid=$!
# Non-vacuity: do not time anything until the holder demonstrably owns the lock.
i=0
while [ ! -f "$T/holder-ready" ] && [ "$i" -lt 30 ]; do sleep 0.2; i=$((i + 1)); done
if [ -f "$T/holder-ready" ]; then ok "17 holder owns the lock (non-vacuity)"; else nok "17 holder owns the lock (non-vacuity)" "holder-ready" "timed out"; fi
t0=$(date +%s)
PATH="$T/bin:$PATH" "$ENGINE_SH" "$CHILD_SRC" check >/dev/null 2>&1; rc=$?
waited=$(( $(date +%s) - t0 ))
is "17 contended run still succeeds"   0 "$rc"
if [ "$waited" -ge 2 ]; then ok "17 blocked until the holder released (${waited}s)"
else nok "17 blocked until the holder released" ">= 2s" "${waited}s"; fi
wait "$holder_pid" 2>/dev/null
# Control in the other direction: with nobody holding it, the same call must not wait.
t0=$(date +%s)
PATH="$T/bin:$PATH" "$ENGINE_SH" "$CHILD_SRC" check >/dev/null 2>&1; rc=$?
free=$(( $(date +%s) - t0 ))
is "17 uncontended run still succeeds" 0 "$rc"
if [ "$free" -le 1 ]; then ok "17 uncontended run does not block (${free}s)"
else nok "17 uncontended run does not block" "<= 1s" "${free}s"; fi
# A usage error is rejected before the lock, so it cannot wait on anyone.
PATH="$T/bin:$PATH" "$ENGINE_SH" "$CHILD_SRC" bogus >/dev/null 2>&1; is "17 bad argument still rc 2" 2 "$?"

echo "--- case 17b: rules-ensure does not wait for the engine lock"
# It runs inside netifd's hotplug dispatch, so it must never queue behind an arm that holds the
# lock through a firewall reload. Same shape as case 17 (case 17's linted engine copy as a separate
# process under the pinned, linted /bin/sh, the copy's lock held by another process), except that
# these stubs report an armed router in Router mode and record what ip is asked — so the run does
# its real rule-layer work while the lock is held, rather than stopping at a gate. Stub output goes
# to files named in the environment, so no path is baked into a stub. The BusyBox build of the
# same code path is covered in-process by case R12.
mkdir -p "$T/bin2"
cat > "$T/bin2/uci" <<'EOF'
#!/bin/sh
case "$*" in
    "-q show ts-fix.settings") printf "ts-fix.settings=settings\nts-fix.settings.kill_switch='1'\n" ;;
    "-q show tailscale.settings") printf "tailscale.settings=settings\ntailscale.settings.enabled='1'\n" ;;
    *glconfig.general.mode*) echo router ;;
    *) exit 1 ;;
esac
EOF
cat > "$T/bin2/ip" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$KS_TEST_IPLOG"
exit 0
EOF
cat > "$T/bin2/logger" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$KS_TEST_LOG"
exit 0
EOF
for stub in ubus jsonfilter; do printf '#!/bin/sh\nexit 1\n' > "$T/bin2/$stub"; done
chmod +x "$T/bin2/uci" "$T/bin2/ip" "$T/bin2/logger" "$T/bin2/ubus" "$T/bin2/jsonfilter"
: > "$T/bin2-ip-calls"; : > "$T/bin2-log"
ENGINE_SH=/bin/sh
stubs_ok=yes
for stub in uci ip ubus jsonfilter logger; do
    [ "$(PATH="$T/bin2:$PATH" "$ENGINE_SH" -c "command -v $stub")" = "$T/bin2/$stub" ] || stubs_ok=no
done
is "17b the child shell resolves every stub by PATH (instrument lint)" yes "$stubs_ok"
[ "$stubs_ok" = "yes" ] && [ "$child_ok" = "yes" ] || ENGINE_SH=false
rm -f "$T/holder-ready"
( exec 9>"$CHILD_LOCK"; flock 9; touch "$T/holder-ready"; sleep 3 ) </dev/null >/dev/null 2>&1 &
holder_pid=$!
i=0
while [ ! -f "$T/holder-ready" ] && [ "$i" -lt 30 ]; do sleep 0.2; i=$((i + 1)); done
if [ -f "$T/holder-ready" ]; then ok "17b holder owns the lock (non-vacuity)"; else nok "17b holder owns the lock (non-vacuity)" "holder-ready" "timed out"; fi
t0=$(date +%s)
PATH="$T/bin2:$PATH" KS_TEST_IPLOG="$T/bin2-ip-calls" KS_TEST_LOG="$T/bin2-log" \
    "$ENGINE_SH" "$CHILD_SRC" rules-ensure >/dev/null 2>&1; rc=$?
took=$(( $(date +%s) - t0 ))
# Read before anything else: a non-blocking attempt on the same lock must still fail, i.e. the
# holder was holding it for the whole of the run above.
if ( exec 9>"$CHILD_LOCK"; flock -n 9 ) 2>/dev/null; then held=no; else held=yes; fi
is "17b the lock was held throughout (non-vacuity)" yes "$held"
is "17b rc"                            0 "$rc"
if [ "$took" -le 1 ]; then ok "17b returned without waiting (${took}s)"
else nok "17b returned without waiting" "<= 1s" "${took}s"; fi
# The copy differs from the engine only in its three path lines, so it probes the host's own
# /proc/sys/net/ipv6. Its ip stub prints nothing, so the swap finds no bridge address and adds none.
if [ -d /proc/sys/net/ipv6 ]; then want_rules=6 want_routes=2; else want_rules=3 want_routes=1; fi
is "17b did the rule-layer work: $want_rules rule adds" "$want_rules" "$(grep -c ' rule add ' "$T/bin2-ip-calls")"
is "17b ... and $want_routes route adds" "$want_routes" "$(grep -c ' route add ' "$T/bin2-ip-calls")"
wait "$holder_pid" 2>/dev/null

echo "--- case 16: the invariant resolves each zone once per pass"
# One device carrying both default routes maps to two interfaces that belong to the same zone;
# without de-duplication the zone would be scanned twice on every 5s poll. This case replaces
# _ks_sever_zone with a counter, so it MUST stay last: the real function is gone afterwards.
reset fixture_unseeded_uplink
uci set "firewall.usbzone.network=usb0 usb0_6"
IP4_DEFAULT="default via 10.9.9.1 dev usb0 proto static"
IP6_DEFAULT="default via fe80::1 dev usb0 proto static"
UBUS_DUMP="usb0 usb0
usb0 usb0_6"
: > "$T/sever-zone-calls"
_ks_sever_zone() { printf '%s\n' "$1" >> "$T/sever-zone-calls"; }
ks_main check > "$T/out" 2>&1
is "16 zone scanned once, not per interface" "usbzone" "$(cat "$T/sever-zone-calls")"

echo "--- instrument: the ip fake understood every invocation the engine made in this run"
is "no unmodelled ip invocation"       "" "$(cat "$T/ip-unsupported")"

echo "--- S14: no swap-marker temp file was left behind by any case (reset never removes them)"
is "no ts-fix-ks.srcswap.* file anywhere under \$T" "" "$(tmpleft)"

echo
[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "$fails case(s) failed"; exit 1
