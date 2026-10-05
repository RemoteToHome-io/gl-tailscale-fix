#!/bin/sh
# Unit test for the three-state read of the kill switch's intent outside the engine — ts_state and
# ks_state, kept byte-identical between "# ---8<--- ts_state" marker lines in
# src/scripts/ts-fix-watchdog, src/scripts/ts-fix-reapply, src/hotplug/20-ts-fix and pkg/postinst —
# and for the decision each of those four takes on it. Laptop-only, no router involved:
#   sh tests/unit/test-ts-state.sh [tree]          (also runs under: busybox ash)
# The optional argument names another tree to test instead of this one; the tree before this change
# must fail.
#
# `uci -q get` prints nothing and returns 1 both for an absent option and for a read that failed,
# so a failed read used to pass for "Tailscale off" or "kill switch off": the watchdog and hotplug
# 20 ran reapply's teardown on it, reapply then committed kill_switch=0, reapply disarmed on a
# failed kill_switch read, the watchdog's follow mode and both exit-node reconciles acted on an
# exit_node_ip read that had failed, and postinst removed the rule layer. `uci -q show
# <pkg>.settings` tells the two apart: a readable section prints its own "<pkg>.settings=<type>"
# line first, and a failed read prints nothing. Every case below turns on that difference.
#
# How each script is driven:
#   - the helper block is extracted by its markers and evaluated in this shell;
#   - the watchdog, reapply, hotplug 20 and postinst's convergence block run from COPIES whose
#     absolute paths (/usr/bin/, /usr/sbin/, /etc/, /tmp/, /bin/ipcalc.sh) are rewritten to the same
#     paths under a throwaway root ($FR), where executable fakes record what they are asked. Each
#     rewrite is linted before anything runs: no such path is left in the code, and no other line
#     differs from the shipping file.
#   - the watchdog is sourced as a library (TS_FIX_WD_LIB=1) and its wd_poll run one poll at a time;
#     hotplug 20 and the postinst block are sourced in a subshell; reapply runs in a child BusyBox
#     ash, pinned whatever shell runs this suite: its lock line `exec 200>"$LOCK"` is a form dash
#     rejects ("exec: 200: not found", verified on this laptop), and GL routers run BusyBox ash.
# The function fakes (uci, ip, logger, pgrep, sleep, flock, timeout, jsonfilter) live in one file,
# sourced here and by the child, and are linted in case 0 in both directions before any case runs.

TREE=${1:-"$(dirname "$0")/../.."}
WD_SRC="$TREE/src/scripts/ts-fix-watchdog"
RA_SRC="$TREE/src/scripts/ts-fix-reapply"
HP_SRC="$TREE/src/hotplug/20-ts-fix"
PI_SRC="$TREE/pkg/postinst"
KS_SRC="$TREE/src/scripts/ts-fix-ks"
for f in "$WD_SRC" "$RA_SRC" "$HP_SRC" "$PI_SRC" "$KS_SRC"; do
    [ -r "$f" ] || { echo "FAIL: cannot read $f"; exit 1; }
done

T=$(mktemp -d "${TMPDIR:-/tmp}/ts-fix-ts-state.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$T"' EXIT
FR="$T/root"
FK_DIR="$T/fk"
FAKES="$T/fakes.sh"
mkdir -p "$FK_DIR" "$FR/usr/bin" "$FR/usr/sbin" "$FR/etc/init.d" "$FR/tmp" "$FR/bin"
export FK_DIR

fails=0; oks=0
ok()    { oks=$((oks + 1)); printf 'ok   %s\n' "$1"; }
nok()   { fails=$((fails + 1)); printf 'FAIL %s\n       want: [%s]\n       got:  [%s]\n' "$1" "$2" "$3"; }
is()    { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "$2" "$3"; fi; }
has()   { case "$3" in *"$2"*) ok "$1" ;; *) nok "$1" "text containing: $2" "$3" ;; esac; }
hasnt() { case "$3" in *"$2"*) nok "$1" "text NOT containing: $2" "$3" ;; *) ok "$1" ;; esac; }
lines() { [ "$#" -eq 0 ] || printf '%s\n' "$@"; }

# $T and $FR go into sed replacements and shell assignments, so they must hold nothing either reads.
case "$T" in *[!A-Za-z0-9._/-]*) echo "FAIL: unsafe temp path $T"; exit 1 ;; esac

# ------------------------------------------------------------------------------------- the fakes
# uci over $FK_DIR/state, one record per line, as test-ks-armdisarm.sh keeps it:
#   S|<pkg>.<section>|<type>     O|<pkg>.<section>.<option>|<value>
# `show <pkg>.<section>` prints what a router prints (device-verified 2026-10-04, GL 4.8.4, 4.9.0
# and 4.11.0): "<pkg>.<section>=<type>", then one "<pkg>.<section>.<option>='<value>'" line per
# option; a missing section prints nothing and fails (rc 1). `show <pkg>` does that for every
# section of the package, rc 1 when it has none. `get` prints a value (or a section's type), and for
# a missing key nothing, rc 1. Fault injection: FK_UCI_FAIL="<pkg>..." makes a show or get of those
# packages print nothing and fail, after FK_UCI_FAIL_SKIP such reads went through;
# FK_UCI_FAIL_KEY=<key> fails a get of exactly that key and nothing else; FK_UCI_SHOW_JUNK=<text>
# prints a line of text ahead of a successful section show. Every call lands in calls, every write
# (set, delete, commit) in writes, and anything else in unexpected.
cat > "$FAKES" <<'EOF'
_fk_put() {     # kind key value — replace in place, keeping record order
    local k p v wrote=0
    : > "$FK_DIR/state.tmp"
    while IFS='|' read -r k p v; do
        if [ "$k" = "$1" ] && [ "$p" = "$2" ]; then
            printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$FK_DIR/state.tmp"; wrote=1
        else
            printf '%s|%s|%s\n' "$k" "$p" "$v" >> "$FK_DIR/state.tmp"
        fi
    done < "$FK_DIR/state"
    [ "$wrote" = "1" ] || printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$FK_DIR/state.tmp"
    command mv "$FK_DIR/state.tmp" "$FK_DIR/state"
}
_fk_del() {     # key — an option, or a section and its options
    local k p v
    : > "$FK_DIR/state.tmp"
    while IFS='|' read -r k p v; do
        [ "$p" = "$1" ] && continue
        case "$p" in "$1".*) continue ;; esac
        printf '%s|%s|%s\n' "$k" "$p" "$v" >> "$FK_DIR/state.tmp"
    done < "$FK_DIR/state"
    command mv "$FK_DIR/state.tmp" "$FK_DIR/state"
}
_fk_show_sec() {
    local k p v hit=1
    while IFS='|' read -r k p v; do
        if [ "$k" = "S" ] && [ "$p" = "$1" ]; then printf '%s=%s\n' "$p" "$v"; hit=0; fi
    done < "$FK_DIR/state"
    [ "$hit" = "0" ] || return 1
    while IFS='|' read -r k p v; do
        [ "$k" = "O" ] || continue
        case "$p" in "$1".*) printf "%s='%s'\n" "$p" "$v" ;; esac
    done < "$FK_DIR/state"
}
uci() {
    local cmd arg pkg k p v rc=1
    printf 'uci %s\n' "$*" >> "$FK_DIR/calls"
    while [ "$#" -gt 0 ]; do case "$1" in -*) shift ;; *) break ;; esac; done
    cmd="$1"; arg="$2"; pkg="${arg%%.*}"
    if [ "$cmd" = "show" ] || [ "$cmd" = "get" ]; then
        if [ -n "$FK_UCI_FAIL" ] && case " $FK_UCI_FAIL " in *" $pkg "*) true ;; *) false ;; esac; then
            printf 'x\n' >> "$FK_DIR/readfail"
            [ "$(grep -c . "$FK_DIR/readfail")" -gt "${FK_UCI_FAIL_SKIP:-0}" ] && return 1
        fi
        [ "$cmd" = "get" ] && [ -n "$FK_UCI_FAIL_KEY" ] && [ "$arg" = "$FK_UCI_FAIL_KEY" ] && return 1
    fi
    case "$cmd" in
        show)
            case "$arg" in
                *.*)
                    _fk_show_sec "$arg" > "$FK_DIR/show.out" || return 1
                    [ -n "$FK_UCI_SHOW_JUNK" ] && printf '%s\n' "$FK_UCI_SHOW_JUNK"
                    cat "$FK_DIR/show.out"
                    ;;
                *)
                    while IFS='|' read -r k p v; do
                        [ "$k" = "S" ] || continue
                        case "$p" in "$arg".*) _fk_show_sec "$p"; rc=0 ;; esac
                    done < "$FK_DIR/state"
                    return $rc
                    ;;
            esac
            ;;
        get)
            while IFS='|' read -r k p v; do
                if [ "$k" = "O" ] && [ "$p" = "$arg" ]; then printf '%s\n' "$v"; return 0; fi
            done < "$FK_DIR/state"
            while IFS='|' read -r k p v; do
                if [ "$k" = "S" ] && [ "$p" = "$arg" ]; then printf '%s\n' "$v"; return 0; fi
            done < "$FK_DIR/state"
            return 1
            ;;
        set)
            printf 'uci set %s\n' "$arg" >> "$FK_DIR/writes"
            k="${arg%%=*}"; v="${arg#*=}"
            if [ -z "$v" ]; then _fk_del "$k"; return 0; fi
            case "${k#*.}" in *.*) _fk_put O "$k" "$v" ;; *) _fk_put S "$k" "$v" ;; esac
            ;;
        delete)
            printf 'uci delete %s\n' "$arg" >> "$FK_DIR/writes"
            _fk_del "$arg"
            ;;
        commit)
            printf 'uci commit %s\n' "$arg" >> "$FK_DIR/writes"
            ;;
        *)
            printf 'uci %s\n' "$cmd $arg" >> "$FK_DIR/unexpected"
            return 1
            ;;
    esac
}
# ip: the reads the watchdog and reapply make, as fixtures. FK_T52 is table 52's default route.
ip() {
    printf 'ip %s\n' "$*" >> "$FK_DIR/calls"
    case "$*" in
        "-4 rule list priority 0") return 0 ;;
        "-4 route show table 52") [ -n "$FK_T52" ] && printf '%s\n' "$FK_T52"; return 0 ;;
        "-4 addr show br-guest") return 0 ;;
        "-4 addr show br-iot") return 0 ;;
    esac
    printf 'ip %s\n' "$*" >> "$FK_DIR/unexpected"
    return 1
}
# pgrep: tailscaled is running when FK_TSD_UP=1; no other process is.
pgrep() {
    printf 'pgrep %s\n' "$*" >> "$FK_DIR/calls"
    [ "$*" = "tailscaled" ] && [ "$FK_TSD_UP" = "1" ]
}
logger()  { printf '%s\n' "$*" >> "$FK_DIR/log"; }
sleep()   { printf 'sleep %s\n' "$*" >> "$FK_DIR/calls"; }
flock()   { printf 'flock %s\n' "$*" >> "$FK_DIR/calls"; return 0; }
timeout() { printf 'timeout %s\n' "$*" >> "$FK_DIR/calls"; shift; "$@"; }
# jsonfilter records only once its input has ended, so its line follows the writer's in a pipeline.
jsonfilter() {
    local in
    in=$(cat)
    printf 'jsonfilter %s\n' "$*" >> "$FK_DIR/calls"
    case "$2" in
        @.BackendState) printf '%s\n' "$in" | sed -n 's/.*"BackendState":"\([^"]*\)".*/\1/p' ;;
        @.ExitNodeID)   printf '%s\n' "$in" | sed -n 's/.*"ExitNodeID":"\([^"]*\)".*/\1/p' ;;
    esac
    return 0
}
EOF
. "$FAKES"

# Executable fakes at the rewritten absolute paths. Each records "<name> <args>" in calls.
mkstub() {   # <path under $FR> <name> [extra shell]
    printf '#!/bin/sh\nprintf "%%s\\n" "%s $*" >> "$FK_DIR/calls"\n%s\nexit 0\n' "$2" "${3:-}" > "$FR/$1"
    chmod +x "$FR/$1"
}
mkstub usr/bin/ts-fix-reapply reapply
mkstub usr/bin/ts-fix-ks ks 'exit "${FK_KS_RC:-0}"'
mkstub usr/bin/ts-fix-isolate6 isolate6
mkstub etc/init.d/firewall fw
mkstub etc/init.d/dnsmasq dnsmasq
mkstub usr/sbin/tailscale tailscale 'case "$1" in
    status) printf "{\"BackendState\":\"%s\"}\n" "${FK_TS_STATE:-Stopped}" ;;
    debug) printf "{\"ExitNodeID\":\"%s\"}\n" "$FK_TS_EID" ;;
    version) echo 1.0.0-fixture ;;
    set) exit "${FK_TS_SET_RC:-0}" ;;
esac'
printf '4.11.0\n' > "$FR/etc/glversion"

# st_reset — empty state and recordings, every knob back to its default.
st_reset() {
    : > "$FK_DIR/state"; : > "$FK_DIR/calls"; : > "$FK_DIR/writes"; : > "$FK_DIR/log"
    : > "$FK_DIR/readfail"; : > "$FK_DIR/rc"
    rm -f "$FR/tmp/"* 2>/dev/null
    FK_UCI_FAIL=""; FK_UCI_FAIL_SKIP=""; FK_UCI_FAIL_KEY=""; FK_UCI_SHOW_JUNK=""
    FK_TSD_UP=""; FK_T52=""; FK_TS_STATE=""; FK_TS_EID=""; FK_TS_SET_RC=""; FK_KS_RC=""
    export FK_TS_STATE FK_TS_EID FK_TS_SET_RC FK_KS_RC
}
sec() {      # sec <pkg.section> <type> [opt=value]... — declare a section with its options
    local s="$1" t="$2" a
    shift 2
    _fk_put S "$s" "$t"
    for a; do _fk_put O "$s.${a%%=*}" "${a#*=}"; done
}
calls()  { cat "$FK_DIR/calls"; }
writes() { cat "$FK_DIR/writes"; }
logt()   { cat "$FK_DIR/log"; }

# ------------------------------------------------------------------- copies under the fake root
# rewrite <src> <dst> — every absolute path the four scripts use, moved under $FR. Through a
# placeholder, so a path that the first substitution produced is never rewritten a second time.
rewrite() {
    sed -e 's|/usr/bin/|@FR@/usr/bin/|g' -e 's|/usr/sbin/|@FR@/usr/sbin/|g' -e 's|/etc/|@FR@/etc/|g' \
        -e 's|/tmp/|@FR@/tmp/|g' -e 's|/bin/ipcalc\.sh|@FR@/bin/ipcalc.sh|g' "$1" | sed "s|@FR@|$FR|g" > "$2"
}
# lint_copy <label> <src> <dst> — rc 0 when the copy is safe to run, with an ok/nok per check.
lint_copy() {
    local left diff
    left=$(grep -v -e '^[[:space:]]*#' "$3" | sed "s|$FR/[A-Za-z0-9._/-]*|@R@|g" |
        grep -e '/usr/' -e '/etc/' -e '/tmp/' -e '/bin/' -e '/sbin/')
    is "$1: no absolute path outside the fake root is left in the code" "" "$left"
    diff=$(command awk 'NR == FNR { a[FNR] = $0; n = FNR; next }
        a[FNR] != $0 && a[FNR] !~ /\/usr\/bin\/|\/usr\/sbin\/|\/etc\/|\/tmp\/|\/bin\/ipcalc\.sh/ { print FNR }
        END { if (FNR != n) print "length" }' "$2" "$3")
    is "$1: the copy differs from the shipping file only on lines naming one of those paths" "" "$diff"
    [ -z "$left" ] && [ -z "$diff" ]
}

# --------------------------------------------------------------------------------------- case 0
echo "--- case 0: the fakes (each behaviour a case relies on, and each recorder records)"
st_reset
sec tailscale.settings settings enabled=1 exit_node_ip=192.0.2.7
sec ts-fix.settings settings kill_switch=0
TAB=$(printf '\t')
is "0 show of a section: the section line, then its options single-quoted (the device format)" \
    "$(lines 'tailscale.settings=settings' "tailscale.settings.enabled='1'" "tailscale.settings.exit_node_ip='192.0.2.7'")" \
    "$(uci -q show tailscale.settings)"
uci -q show tailscale.settings >/dev/null; is "0 ... rc 0" 0 "$?"
is "0 show of a missing section: nothing" "" "$(uci -q show tailscale.nosuch)"
uci -q show tailscale.nosuch >/dev/null; is "0 ... rc 1" 1 "$?"
is "0 show of a missing package: nothing" "" "$(uci -q show nosuch.settings)"
uci -q show nosuch >/dev/null; is "0 ... rc 1 (package form too)" 1 "$?"
is "0 get of an option" "1" "$(uci -q get tailscale.settings.enabled)"
is "0 get of a missing option: nothing" "" "$(uci -q get tailscale.settings.nosuch)"
uci -q get tailscale.settings.nosuch >/dev/null; is "0 ... rc 1" 1 "$?"
FK_UCI_FAIL=tailscale
v=$(uci -q show tailscale.settings); r=$?
is "0 FK_UCI_FAIL: a show of that package prints nothing, rc 1" "|1" "$v|$r"
v=$(uci -q get tailscale.settings.enabled); r=$?
is "0 ... and a get of it too" "|1" "$v|$r"
v=$(uci -q show ts-fix.settings); r=$?
is "0 ... and another package is unaffected" "ts-fix.settings=settings
ts-fix.settings.kill_switch='0'|0" "$v|$r"
FK_UCI_FAIL=""; : > "$FK_DIR/readfail"
FK_UCI_FAIL=tailscale; FK_UCI_FAIL_SKIP=1
r=""; for i in 1 2 3; do uci -q show tailscale.settings >/dev/null; r="$r$?"; done
is "0 FK_UCI_FAIL_SKIP=1: the first read goes through, every later one fails" "011" "$r"
FK_UCI_FAIL=""; FK_UCI_FAIL_SKIP=""; : > "$FK_DIR/readfail"
FK_UCI_FAIL_KEY=tailscale.settings.exit_node_ip
r="$(uci -q get tailscale.settings.exit_node_ip; echo "rc $?")|$(uci -q get tailscale.settings.enabled)|$(uci -q show tailscale.settings | grep -c .)"
is "0 FK_UCI_FAIL_KEY fails a get of exactly that key; other gets and the show are unaffected" "rc 1|1|3" "$r"
FK_UCI_FAIL_KEY=""
FK_UCI_SHOW_JUNK="junk"
is "0 FK_UCI_SHOW_JUNK prints its line ahead of a successful section show" "junk" "$(uci -q show ts-fix.settings | head -n 1)"
FK_UCI_SHOW_JUNK=""
: > "$FK_DIR/writes"
uci set ts-fix.settings.kill_switch=1; uci -q set ts-fix.settings.x=y; uci -q delete ts-fix.settings.x; uci commit ts-fix
uci set ts-fix.settings.empty=''
is "0 set, delete and commit are recorded in writes" "$(lines 'uci set ts-fix.settings.kill_switch=1' \
    'uci set ts-fix.settings.x=y' 'uci delete ts-fix.settings.x' 'uci commit ts-fix' 'uci set ts-fix.settings.empty=')" "$(writes)"
is "0 ... the set landed, the delete removed, an empty set created nothing" "1||" \
    "$(uci -q get ts-fix.settings.kill_switch)|$(uci -q get ts-fix.settings.x)|$(uci -q get ts-fix.settings.empty)"
st_reset
FK_T52="default dev tailscale0"
is "0 ip: table 52 from FK_T52" "default dev tailscale0" "$(ip -4 route show table 52)"
pgrep tailscaled; r1=$?; FK_TSD_UP=1; pgrep tailscaled; r2=$?; pgrep -f "gl_tailscale restart"; r3=$?
is "0 pgrep: tailscaled only when FK_TSD_UP=1, nothing else ever" "1 0 1" "$r1 $r2 $r3"
FK_TS_STATE=Running
is "0 timeout runs its command; the tailscale fake answers status as JSON; jsonfilter takes the field" "Running" \
    "$(timeout 10 "$FR/usr/sbin/tailscale" status --json | jsonfilter -e '@.BackendState')"
"$FR/usr/bin/ts-fix-ks" check; r1=$?; FK_KS_RC=1; "$FR/usr/bin/ts-fix-ks" arm; r2=$?; FK_KS_RC=""
"$FR/usr/bin/ts-fix-reapply"; sleep 3; flock -n 200; logger -t ts-fix "lint line"
is "0 recorders: every call in order, the stubs' rc" "$(lines 'ip -4 route show table 52' 'pgrep tailscaled' \
    'pgrep tailscaled' 'pgrep -f gl_tailscale restart' "timeout 10 $FR/usr/sbin/tailscale status --json" \
    'tailscale status --json' 'jsonfilter -e @.BackendState' 'ks check' 'ks arm' 'reapply ' 'sleep 3' 'flock -n 200') 0 1" \
    "$(calls) $r1 $r2"
is "0 recorders: logger" "-t ts-fix lint line" "$(logt)"
uci bogus x; ip link show
is "0 an unmodelled uci or ip call lands in unexpected" "$(lines 'uci bogus x' 'ip link show')" "$(cat "$FK_DIR/unexpected")"
rm -f "$FK_DIR/unexpected"
fakes=""
for f in uci ip logger pgrep sleep flock timeout jsonfilter; do
    case "$(type "$f" 2>&1)" in *function*) fakes="$fakes $f" ;; esac
done
is "0 every fake resolves to its function in this shell" " uci ip logger pgrep sleep flock timeout jsonfilter" "$fakes"
case "$(type sed 2>&1)" in
    *function*) nok "0 the lint discriminates: sed is not a function" "not a function" "$(type sed 2>&1)" ;;
    *) ok "0 the lint discriminates: sed is not a function" ;;
esac
got=$(busybox ash -c '. "$1"; for f in uci ip logger pgrep sleep flock timeout jsonfilter sed; do
    case "$(type "$f" 2>&1)" in *function*) printf "%s " "$f" ;; esac; done' _ "$FAKES" 2>&1)
is "0 the pinned child shell (busybox ash) resolves every fake to its function, sed to none" \
    "uci ip logger pgrep sleep flock timeout jsonfilter " "$got"

# -------------------------------------------------------------------------- A: the marker blocks
echo "--- case A: one ts_state block in each of the four files, byte-identical"
blk() { command awk '/^# ---8<--- ts_state$/,/^# ---8<--- end ts_state$/' "$1"; }
for f in "$WD_SRC" "$RA_SRC" "$HP_SRC" "$PI_SRC"; do
    n="${f#"$TREE"/}"
    is "A $n: the start marker once, the end marker once" "1 1" \
        "$(grep -c -x -e '# ---8<--- ts_state' "$f") $(grep -c -x -e '# ---8<--- end ts_state' "$f")"
done
blk "$WD_SRC" > "$T/blk.wd"
is "A the watchdog's block is not empty (so the comparisons below are not vacuous)" yes \
    "$([ -s "$T/blk.wd" ] && grep -q '^ts_state() {$' "$T/blk.wd" && grep -q '^ks_state() {$' "$T/blk.wd" && echo yes)"
for f in "$RA_SRC" "$HP_SRC" "$PI_SRC"; do
    blk "$f" > "$T/blk.other"
    if [ -s "$T/blk.wd" ] && cmp -s "$T/blk.wd" "$T/blk.other"; then ok "A ${f#"$TREE"/} carries the watchdog's block byte for byte"
    else nok "A ${f#"$TREE"/} carries the watchdog's block byte for byte" "identical" "$(diff "$T/blk.wd" "$T/blk.other" | head -n 5)"; fi
done
printf 'x\n' >> "$T/blk.other"
if cmp -s "$T/blk.wd" "$T/blk.other"; then nok "A the comparison discriminates (one extra line differs)" "differs" "same"
else ok "A the comparison discriminates (one extra line differs)"; fi
# The block defines functions and nothing else: sourcing it runs no command.
code=$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$T/blk.wd" | head -n 1)
is "A the block's first code line is a function definition" "ts_state() {" "$code"

# ------------------------------------------------------------------------- B: the helper itself
echo "--- case B: ts_state and ks_state on fixture text"
helper_ok=0
if [ -s "$T/blk.wd" ]; then
    eval "$(cat "$T/blk.wd")"
    command -v ts_state >/dev/null 2>&1 && command -v ks_state >/dev/null 2>&1 && helper_ok=1
fi
is "B the helper block defines ts_state and ks_state" 1 "$helper_ok"
tsr() {   # tsr -> "<rc> en=[<ts_en>] eip=[<ts_eip>]" after one ts_state call
    if [ "$helper_ok" = "1" ]; then ts_state; printf '%s en=[%s] eip=[%s]' "$?" "$ts_en" "$ts_eip"; else echo "NO HELPER"; fi
}
ksr() {
    if [ "$helper_ok" = "1" ]; then ks_state; printf '%s ks=[%s]' "$?" "$ks_on"; else echo "NO HELPER"; fi
}
st_reset; sec tailscale.settings settings enabled=1 exit_node_ip=192.0.2.7
is "B readable, enabled '1', an exit node" "0 en=[1] eip=[192.0.2.7]" "$(tsr)"
is "B ... exactly one uci call: the show" "uci -q show tailscale.settings" "$(calls)"
st_reset; sec tailscale.settings settings enabled=0 exit_node_ip=192.0.2.7
is "B enabled '0': off" "0 en=[0] eip=[192.0.2.7]" "$(tsr)"
st_reset; sec tailscale.settings settings lan_enabled=1
is "B enabled ABSENT in a readable section: off, not unknown (GL's slider deletes it)" "0 en=[0] eip=[]" "$(tsr)"
for v in true yes on 01 '1 ' ' 1' 11; do
    st_reset; sec tailscale.settings settings "enabled=$v"
    is "B enabled '$v': off (only '1' is on)" "0 en=[0] eip=[]" "$(tsr)"
done
st_reset; sec tailscale.settings settings enabled1=1 xenabled=1
is "B a look-alike option name: off" "0 en=[0] eip=[]" "$(tsr)"
st_reset; sec tailscale.settings2 settings enabled=1
is "B a look-alike section name: the section is missing, so unknown" "1 en=[] eip=[]" "$(tsr)"
st_reset; sec tailscale.settings settings enabled=1 exit_node_ip=192.0.2.7; FK_UCI_FAIL=tailscale
is "B unreadable (show rc 1, nothing printed): unknown, rc 1, both empty" "1 en=[] eip=[]" "$(tsr)"
st_reset
is "B no tailscale package at all: unknown" "1 en=[] eip=[]" "$(tsr)"
st_reset; sec tailscale.settings settings enabled=1; FK_UCI_SHOW_JUNK="uci: something else first"
is "B output whose first line is not the section line: unknown" "1 en=[] eip=[]" "$(tsr)"
st_reset; sec tailscale.settings settings exit_node_ip=198.51.100.9 enabled=1
is "B exit_node_ip ahead of enabled: both read" "0 en=[1] eip=[198.51.100.9]" "$(tsr)"
st_reset; sec tailscale.settings settings enabled=1 exit_node_ip_old=192.0.2.9
is "B a look-alike of exit_node_ip is not it" "0 en=[1] eip=[]" "$(tsr)"
if [ "$helper_ok" = "1" ]; then
    st_reset; sec tailscale.settings settings enabled=1 exit_node_ip=192.0.2.7
    ts_state; FK_UCI_FAIL=tailscale; ts_state; r=$?
    is "B a failed read after a good one leaves nothing of the good one behind" "1 en=[] eip=[]" "$r en=[$ts_en] eip=[$ts_eip]"
    st_reset; sec tailscale.settings settings enabled=1 exit_node_ip='*'
    mkdir -p "$T/globdir"; : > "$T/globdir/afile"
    ifs_before="$IFS"
    r=$(cd "$T/globdir" && ts_state && printf '%s' "$ts_eip")
    is "B a value that is a glob is taken literally, never expanded" "*" "$r"
    ts_state
    if [ "$IFS" = "$ifs_before" ]; then ok "B the caller's IFS is left as it was"; else nok "B the caller's IFS is left as it was" "unchanged" "changed"; fi
fi
st_reset; sec ts-fix.settings settings kill_switch=1 route_guest=0
is "B ks_state: kill_switch '1'" "0 ks=[1]" "$(ksr)"
is "B ... exactly one uci call: the show" "uci -q show ts-fix.settings" "$(calls)"
st_reset; sec ts-fix.settings settings kill_switch=0
is "B ks_state: kill_switch '0'" "0 ks=[0]" "$(ksr)"
st_reset; sec ts-fix.settings settings route_guest=1
is "B ks_state: kill_switch absent in a readable section: off" "0 ks=[0]" "$(ksr)"
st_reset; sec ts-fix.settings settings kill_switch=1; FK_UCI_FAIL=ts-fix
is "B ks_state: unreadable: unknown" "1 ks=[]" "$(ksr)"

# ----------------------------------------------------------- E: the engine agrees on the parse
echo "--- case E: the engine's _ks_intent and the helper agree on every combination"
# The engine keeps its own reader; this holds the two to one meaning. _ks_intent: 0 armed intent,
# 1 no intent (both reads succeeded), 2 unknown. The helper's verdict for the same state: unknown if
# either is unknown, armed if both are 1, otherwise no intent.
st_engine() {   # <ts-fix spec> <tailscale spec>: one|zero|absent|other|unread
    st_reset
    case "$1" in
        one) sec ts-fix.settings settings kill_switch=1 ;; zero) sec ts-fix.settings settings kill_switch=0 ;;
        absent) sec ts-fix.settings settings route_guest=0 ;; other) sec ts-fix.settings settings kill_switch=yes ;;
        unread) sec ts-fix.settings settings kill_switch=1 ;;
    esac
    case "$2" in
        one) sec tailscale.settings settings enabled=1 ;; zero) sec tailscale.settings settings enabled=0 ;;
        absent) sec tailscale.settings settings lan_enabled=1 ;; other) sec tailscale.settings settings enabled=true ;;
        unread) sec tailscale.settings settings enabled=1 ;;
    esac
}
eng_intent() {   # the engine's _ks_intent rc, sourced in a subshell (its set -f stays there)
    ( TS_FIX_KS_NO_MAIN=1; . "$KS_SRC"; _ks_intent >/dev/null 2>&1; echo "$?" )
}
mism=""; n=0
for a in one zero absent other unread; do
    for b in one zero absent other unread; do
        st_engine "$a" "$b"
        FK_UCI_FAIL=""
        [ "$a" = "unread" ] && FK_UCI_FAIL="ts-fix"
        [ "$b" = "unread" ] && FK_UCI_FAIL="${FK_UCI_FAIL:+$FK_UCI_FAIL }tailscale"
        eng=$(eng_intent)
        if [ "$helper_ok" = "1" ]; then
            ks_state; ts_state
            if [ -z "$ks_on" ] || [ -z "$ts_en" ]; then hlp=2
            elif [ "$ks_on" = "1" ] && [ "$ts_en" = "1" ]; then hlp=0
            else hlp=1; fi
        else
            hlp=none
        fi
        n=$((n + 1))
        [ "$eng" = "$hlp" ] || mism="$mism [$a/$b engine=$eng helper=$hlp]"
    done
done
is "E 25 combinations, one verdict each, engine == helper" "25:" "$n:$mism"
st_engine one one;    FK_UCI_FAIL="";          r=$(eng_intent)
st_engine one unread; FK_UCI_FAIL=tailscale;   r="$r $(eng_intent)"
st_engine unread one; FK_UCI_FAIL=ts-fix;      r="$r $(eng_intent)"
st_engine zero one;   FK_UCI_FAIL="";          r="$r $(eng_intent)"
st_engine one absent; FK_UCI_FAIL="";          r="$r $(eng_intent)"
is "E the engine's answers spelled out: armed 0, either read failing 2, off 1, absent enabled 1" "0 2 2 1 1" "$r"
st_engine one one; FK_UCI_FAIL=""
( TS_FIX_KS_NO_MAIN=1; . "$KS_SRC"; _ks_intent >/dev/null 2>&1 )
is "E the engine reads each package once, with a show, and nothing else" \
    "$(lines 'uci -q show ts-fix.settings' 'uci -q show tailscale.settings')" "$(calls)"

# -------------------------------------------------------------------------------- H: hotplug 20
echo "--- case H: hotplug 20 runs reapply only on a readable state"
rewrite "$HP_SRC" "$T/hp.copy"
lint_copy "H hotplug copy" "$HP_SRC" "$T/hp.copy"; hp_ok=$?
hp() {   # hp <ACTION> <INTERFACE> — source the copy in a subshell, rc to rc file
    if [ "$hp_ok" != "0" ]; then echo "NOT RUN: lint failed" >> "$FK_DIR/calls"; return; fi
    ( ACTION="$1"; INTERFACE="$2"; . "$T/hp.copy" ) > "$T/hp.out" 2>&1
    printf '%s\n' "$?" >> "$FK_DIR/rc"
}
hp_case() {   # <label> <want: "reapply " or nothing> <ACTION> <INTERFACE> — rc 0 and silent always
    hp "$3" "$4"
    is "H $1" "$2|0|" "$(grep -e '^reapply' "$FK_DIR/calls")|$(cat "$FK_DIR/rc")|$(cat "$T/hp.out")"
}
st_reset; sec tailscale.settings settings enabled=1; FK_UCI_FAIL=tailscale
hp_case "unknown, ifup wan: nothing" "" ifup wan
is "H ... its one call is the show" "uci -q show tailscale.settings" "$(calls)"
st_reset; sec tailscale.settings settings enabled=1; FK_UCI_FAIL=tailscale
hp_case "unknown, ifdown wan: nothing (no teardown on a failed read)" "" ifdown wan
st_reset; sec tailscale.settings settings enabled=1
hp_case "enabled '1', ifup wan: reapply" "reapply " ifup wan
st_reset; sec tailscale.settings settings enabled=1
hp_case "enabled '1', ifup loopback: nothing" "" ifup loopback
st_reset; sec tailscale.settings settings enabled=1
hp_case "enabled '1', ifdown wan: nothing" "" ifdown wan
st_reset; sec tailscale.settings settings enabled=0
hp_case "enabled '0', ifdown wan: reapply (its teardown)" "reapply " ifdown wan
st_reset; sec tailscale.settings settings lan_enabled=1
hp_case "enabled absent, ifup wan: reapply (its teardown)" "reapply " ifup wan

# ------------------------------------------------------------------------------------ R: reapply
echo "--- case R: reapply holds on a failed read and never commits a disable from one"
rewrite "$RA_SRC" "$T/ra.copy"
lint_copy "R reapply copy" "$RA_SRC" "$T/ra.copy"; ra_ok=$?
ra() {   # ra — run the copy in the pinned child; rc appended to rc
    if [ "$ra_ok" != "0" ]; then echo "NOT RUN: lint failed" >> "$FK_DIR/calls"; return; fi
    (
        export FK_UCI_FAIL FK_UCI_FAIL_SKIP FK_UCI_FAIL_KEY FK_UCI_SHOW_JUNK FK_TSD_UP FK_T52
        busybox ash -c '. "$1"; . "$2"' _ "$FAKES" "$T/ra.copy"
    ) </dev/null > "$T/ra.out" 2>&1
    printf '%s\n' "$?" >> "$FK_DIR/rc"
}
ks_calls() { grep -e '^ks ' "$FK_DIR/calls"; }
st_reset
sec tailscale.settings settings enabled=1 exit_node_ip=192.0.2.7
sec ts-fix.settings settings kill_switch=1 route_guest=1 advertise_exit_node=1
FK_UCI_FAIL=tailscale
ra
is "R unknown: rc 1" "1" "$(cat "$FK_DIR/rc")"
is "R unknown: its only call is the one show" "uci -q show tailscale.settings" "$(calls)"
is "R unknown: no write at all" "" "$(writes)"
is "R unknown: exactly one log line" "1" "$(grep -c . "$FK_DIR/log")"
has "R unknown: an ERROR naming the read" "ERROR" "$(logt)"
has "R ... and the package" "tailscale.settings could not be read" "$(logt)"
is "R unknown: kill_switch still 1" "1" "$(uci -q get ts-fix.settings.kill_switch)"
for en in 0 -; do
    st_reset
    if [ "$en" = "-" ]; then sec tailscale.settings settings lan_enabled=1; lbl="enabled absent"
    else sec tailscale.settings settings enabled=0; lbl="enabled '0'"; fi
    sec ts-fix.settings settings kill_switch=1 route_guest=1
    ra
    is "R $lbl: the teardown runs, rc 0" "0" "$(cat "$FK_DIR/rc")"
    is "R $lbl: ... the engine is asked to disarm" "ks disarm" "$(ks_calls)"
    has "R $lbl: ... and intent is reset and committed" "uci set ts-fix.settings.kill_switch=0" "$(writes)"
    has "R $lbl: ... (commit)" "uci commit ts-fix" "$(writes)"
    hasnt "R $lbl: ... before any lock" "flock" "$(calls)"
done
st_reset
sec tailscale.settings settings enabled=1
sec ts-fix.settings settings kill_switch=1
FK_UCI_FAIL=ts-fix
ra
is "R ts-fix.settings unreadable: neither arm nor disarm; only the lock-free rules-ensure" "ks rules-ensure" "$(ks_calls)"
is "R ... no write" "" "$(writes)"
has "R ... one ERROR saying the kill switch was left as it is" "ERROR" "$(grep -e 'ts-fix.settings' "$FK_DIR/log")"
is "R ... exactly one line names ts-fix.settings" "1" "$(grep -c -e 'ts-fix.settings' "$FK_DIR/log")"
is "R ... rc 0 (the rest of the pass ran)" "0" "$(cat "$FK_DIR/rc")"
for ks in 1 0; do
    st_reset
    sec tailscale.settings settings enabled=1
    sec ts-fix.settings settings "kill_switch=$ks"
    ra
    if [ "$ks" = "1" ]; then want="ks arm"; else want="ks disarm"; fi
    is "R control: kill_switch '$ks' -> $want, then rules-ensure" "$want
ks rules-ensure" "$(ks_calls)"
done
# The exit-node reconcile, past the daemon wait: the daemon routes through an exit node, and GL's
# UCI agrees with the snapshot, so a correct read changes nothing.
ra_rec() {   # <tailscale.settings exit_node_ip | -> <last_seen | ->
    st_reset
    if [ "$1" = "-" ]; then sec tailscale.settings settings enabled=1
    else sec tailscale.settings settings enabled=1 "exit_node_ip=$1"; fi
    if [ "$2" = "-" ]; then sec ts-fix.settings settings kill_switch=0
    else sec ts-fix.settings settings kill_switch=0 "last_seen_exit_node_ip=$2"; fi
    FK_TSD_UP=1; FK_TS_STATE=Running; FK_TS_EID=nodeEXIT
}
ra_rec 192.0.2.7 192.0.2.7
ra
is "R reconcile control, readable and unchanged: no exit-node push" "" "$(grep -e 'tailscale set --exit-node' "$FK_DIR/calls")"
is "R ... the snapshot option untouched" "" "$(grep -e 'last_seen_exit_node_ip' "$FK_DIR/writes")"
is "R ... rc 0" "0" "$(cat "$FK_DIR/rc")"
ra_rec 198.51.100.9 192.0.2.7
FK_TS_EID=""
ra
is "R reconcile control, readable and changed: the push runs (the instrument sees a push)" \
    "tailscale set --exit-node=198.51.100.9" "$(grep -e '^tailscale set --exit-node' "$FK_DIR/calls")"
has "R ... and the snapshot advances" "uci set ts-fix.settings.last_seen_exit_node_ip=198.51.100.9" "$(writes)"
ra_rec 192.0.2.7 192.0.2.7
FK_UCI_FAIL=tailscale; FK_UCI_FAIL_SKIP=1   # the top read succeeds, the reconcile's re-read fails
ra
is "R reconcile, the re-read fails: no exit-node push or clear" "" "$(grep -e 'tailscale set --exit-node' "$FK_DIR/calls")"
is "R ... the snapshot option untouched" "" "$(grep -e 'last_seen_exit_node_ip' "$FK_DIR/writes")"
is "R ... still 192.0.2.7" "192.0.2.7" "$(uci -q get ts-fix.settings.last_seen_exit_node_ip)"
is "R ... one line says so" "1" "$(grep -c -e 'reconcile.*tailscale.settings could not be read' "$FK_DIR/log")"
is "R ... the read that failed was the second one (non-vacuity)" "2" "$(grep -c . "$FK_DIR/readfail")"

# ----------------------------------------------------------------------------------- W: watchdog
echo "--- case W: the watchdog takes one snapshot per poll and acts only on a readable one"
rewrite "$WD_SRC" "$T/wd.copy"
lint_copy "W watchdog copy" "$WD_SRC" "$T/wd.copy"; wd_ok=$?
GUARD='[ "${TS_FIX_WD_LIB:-0}" = "1" ] && return 0'
is "W the library guard is there, once (so sourcing returns before the loop)" 1 "$(grep -c -x -F -e "$GUARD" "$WD_SRC")"
[ "$(grep -c -x -F -e "$GUARD" "$WD_SRC")" = "1" ] || wd_ok=1
wd() {   # wd <commands> — source the copy as a library in a subshell, then run the commands
    if [ "$wd_ok" != "0" ]; then echo "NOT RUN: lint or guard failed" >> "$FK_DIR/calls"; return; fi
    (
        TS_FIX_WD_LIB=1
        TS_FIX_GLVERSION="$FR/etc/glversion"
        TS_FIX_FW_INIT="$FR/etc/init.d/firewall"
        TS_FIX_REAPPLY="$T/ra.copy"
        TS_FIX_ISOLATE6="$FR/usr/bin/ts-fix-isolate6"
        IPCALC="$FR/bin/ipcalc.sh"
        . "$T/wd.copy"
        if ! command -v wd_poll >/dev/null 2>&1; then echo "MISSING wd_poll" >> "$FK_DIR/calls"; exit 1; fi
        eval "$1"
    ) </dev/null > "$T/wd.out" 2>&1
}
wd_router() {   # <enabled|-> <exit_node_ip|-> <kill_switch> <follow> — then route_guest 0 throughout
    st_reset
    if [ "$1" = "-" ]; then sec tailscale.settings settings lan_enabled=1
    else sec tailscale.settings settings "enabled=$1"; fi
    [ "$2" = "-" ] || _fk_put O tailscale.settings.exit_node_ip "$2"
    sec ts-fix.settings settings "kill_switch=$3" route_guest=0 "ks_follow_exit_node=$4"
}
acts() {   # what a poll DID: reapply runs, uci writes, exit-node pushes — one per line
    grep -e '^reapply' -e '^tailscale set' "$FK_DIR/calls"
    cat "$FK_DIR/writes"
}
wd_router 1 192.0.2.7 1 1
FK_TSD_UP=1; FK_T52="default dev tailscale0"
FK_UCI_FAIL=tailscale
wd 'wd_poll'
is "W unknown: nothing done - no teardown, no follow, no reconcile, no write" "" "$(acts)"
is "W ... the engine's check still runs (it holds on its own)" "ks check" "$(grep -e '^ks ' "$FK_DIR/calls")"
is "W ... one WARNING naming the read" "1" "$(grep -c -e 'WARNING tailscale.settings could not be read' "$FK_DIR/log")"
is "W ... and nothing else logged" "1" "$(grep -c . "$FK_DIR/log")"
: > "$FK_DIR/log"
wd 'wd_poll; : > "$FK_DIR/log"; wd_poll; wd_poll'
is "W unknown, polls 2 and 3 of the episode: still nothing done" "" "$(acts)"
is "W ... and nothing more logged" "" "$(logt)"
wd 'wd_poll; FK_UCI_FAIL=""; : > "$FK_DIR/log"; wd_poll; printf "%s\n" "--" >> "$FK_DIR/log"; wd_poll'
is "W the next readable poll logs one 'readable again' line, the one after nothing" \
    "$(lines '-t ts-fix tailscale.settings readable again - resuming' '--')" "$(logt)"
wd_router 0 - 1 0
wd 'wd_poll'
is "W enabled '0' with kill_switch '1': the teardown runs (reapply)" "reapply " "$(acts)"
has "W ... and says so" "Tailscale disabled + ts-fix settings still applied" "$(logt)"
wd_router - - 1 0
wd 'wd_poll'
is "W enabled ABSENT with kill_switch '1': the teardown runs too (absent is off)" "reapply " "$(acts)"
wd_router 0 - 0 0
wd 'wd_poll'
is "W enabled '0', every setting 0: nothing to tear down" "" "$(acts)"
wd_router 1 192.0.2.7 0 1
wd 'wd_poll'
is "W follow control, readable: an exit node set and the kill switch off -> armed (the instrument sees a follow)" \
    "$(lines 'reapply ' 'uci set ts-fix.settings.kill_switch=1' 'uci commit ts-fix')" "$(acts)"
wd_router 1 192.0.2.7 0 1
FK_UCI_FAIL=tailscale
wd 'wd_poll'
is "W follow, unknown: nothing" "" "$(acts)"
wd_router 1 192.0.2.7 1 1
FK_UCI_FAIL_KEY=tailscale.settings.exit_node_ip
wd 'wd_poll; wd_poll'
is "W follow: an exit_node_ip read that would fail is never taken - no disarm" "" "$(acts)"
is "W the poll reads tailscale.settings through its one show and no get" \
    "uci -q show tailscale.settings
uci -q show tailscale.settings" "$(grep -e 'tailscale\.settings' "$FK_DIR/calls" | grep -e '^uci ')"
wd_router 1 - 0 0
FK_TSD_UP=1; FK_T52="default dev tailscale0"
wd 'wd_poll; wd_poll'
is "W CLEAR control, readable: GL's exit node cleared, the daemon still routing -> cleared on poll 2" \
    "tailscale set --exit-node=" "$(acts)"
wd_router 1 192.0.2.7 0 0
FK_TSD_UP=1; FK_T52="default dev tailscale0"
FK_UCI_FAIL_KEY=tailscale.settings.exit_node_ip
wd 'wd_poll; wd_poll; wd_poll'
is "W CLEAR: the user's exit node is never cleared off a read that would fail" "" "$(acts)"
wd_router 1 - 0 0
FK_TSD_UP=1; FK_T52="default dev tailscale0"
FK_UCI_FAIL=tailscale
wd 'wd_poll; wd_poll; wd_poll'
is "W CLEAR, unknown for three polls: nothing" "" "$(acts)"
wd_router 1 192.0.2.7 0 0
FK_TSD_UP=1; FK_TS_STATE=Running
wd 'wd_poll; wd_poll; wd_poll'
is "W SET control, readable: GL's exit node set, the daemon not routing -> pushed on poll 3" \
    "tailscale set --exit-node=192.0.2.7" "$(acts)"
wd_router 1 192.0.2.7 0 0
FK_TSD_UP=1; FK_TS_STATE=Running
FK_UCI_FAIL=tailscale
wd 'wd_poll; wd_poll; wd_poll'
is "W SET, unknown for three polls: nothing" "" "$(acts)"
is "W no unmodelled call anywhere in the W cases" "" "$(cat "$FK_DIR/unexpected" 2>/dev/null)"

# ----------------------------------------------------------------------------------- P: postinst
echo "--- case P: postinst's kill-switch convergence"
# The block is the one that starts at the exact line below and ends at the first `fi` after it,
# taken from a rewritten copy; the helper block is taken from the same copy.
START='if [ -x /usr/bin/ts-fix-ks ]; then'
is "P the convergence block's first line appears once" 1 "$(grep -c -x -F -e "$START" "$PI_SRC")"
rewrite "$PI_SRC" "$T/pi.full"
command awk -v s="if [ -x $FR/usr/bin/ts-fix-ks ]; then" '$0 == s { on = 1 } on { print } on && /^fi$/ { exit }' \
    "$T/pi.full" > "$T/pi.conv"
command awk '/^# ---8<--- ts_state$/,/^# ---8<--- end ts_state$/' "$T/pi.full" > "$T/pi.blk"
cat "$T/pi.blk" "$T/pi.conv" > "$T/pi.copy"
command awk -v s="$START" '$0 == s { on = 1 } on { print } on && /^fi$/ { exit }' "$PI_SRC" > "$T/pi.conv.src"
command awk '/^# ---8<--- ts_state$/,/^# ---8<--- end ts_state$/' "$PI_SRC" > "$T/pi.blk.src"
cat "$T/pi.blk.src" "$T/pi.conv.src" > "$T/pi.src"
lint_copy "P postinst block copy" "$T/pi.src" "$T/pi.copy"; pi_ok=$?
is "P the extracted block ends with its fi" "fi" "$(tail -n 1 "$T/pi.conv")"
pi() {
    if [ "$pi_ok" != "0" ]; then echo "NOT RUN: lint failed" >> "$FK_DIR/calls"; return; fi
    ( . "$T/pi.copy" ) </dev/null > "$T/pi.out" 2>&1
    printf '%s\n' "$?" >> "$FK_DIR/rc"
}
pi_case() {   # <label> <ts-fix kill_switch|-> <tailscale enabled|-> <want ks call>
    st_reset
    if [ "$2" = "-" ]; then sec ts-fix.settings settings route_guest=0; else sec ts-fix.settings settings "kill_switch=$2"; fi
    if [ "$3" = "-" ]; then sec tailscale.settings settings lan_enabled=1; else sec tailscale.settings settings "enabled=$3"; fi
    pi
    is "P $1" "$4|0|" "$(grep -e '^ks ' "$FK_DIR/calls")|$(cat "$FK_DIR/rc")|$(logt)"
}
pi_case "armed: arm" 1 1 "ks arm"
pi_case "kill_switch '0': rules-clean" 0 1 "ks rules-clean"
pi_case "Tailscale '0': rules-clean" 1 0 "ks rules-clean"
pi_case "Tailscale enabled absent: rules-clean" 1 - "ks rules-clean"
pi_case "kill_switch absent: rules-clean" - 1 "ks rules-clean"
for pkg in tailscale ts-fix; do
    st_reset
    sec ts-fix.settings settings kill_switch=1
    sec tailscale.settings settings enabled=1
    FK_UCI_FAIL=$pkg
    pi
    is "P $pkg.settings unreadable: neither arm nor rules-clean" "" "$(grep -e '^ks ' "$FK_DIR/calls")"
    is "P ... rc 0, one log line" "0 1" "$(cat "$FK_DIR/rc") $(grep -c . "$FK_DIR/log")"
    has "P ... saying the kill switch was left as it is" "left as it is" "$(logt)"
    has "P ... and the watchdog's check converges it" "watchdog" "$(logt)"
done
st_reset
sec ts-fix.settings settings kill_switch=1
sec tailscale.settings settings enabled=1
chmod -x "$FR/usr/bin/ts-fix-ks"
pi
chmod +x "$FR/usr/bin/ts-fix-ks"
is "P the engine missing: no call, one line naming it" "|1" "$(grep -e '^ks ' "$FK_DIR/calls")|$(grep -c -e 'ts-fix-ks missing' "$FK_DIR/log")"

# --------------------------------------------------------------------------------------- finish
echo "--- instrument: no unmodelled call anywhere in the run"
is "no unexpected uci or ip call" "" "$(cat "$FK_DIR/unexpected" 2>/dev/null)"

echo
[ "$fails" -eq 0 ] && { echo "ALL PASS ($oks ok)"; exit 0; }
echo "$fails FAILED ($oks ok)"; exit 1
