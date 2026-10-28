#!/bin/sh
# Unit test for the Tailscale binary keep list (unit K1). A firmware upgrade that keeps settings
# copies every path a /lib/upgrade/keep.d list names that exists, so the binaries must be listed
# only while a Version Manager binary is installed:
#   - src/upgrade/keep.d/gl-tailscale-fix no longer names /usr/sbin/tailscale(d);
#   - src/scripts/ts-fix-update writes a second list,
#     /lib/upgrade/keep.d/gl-tailscale-fix-tailscale, when it installs a binary (install_binary ->
#     keep_write) and removes it on Restore, and --sync-keep converges it on what is installed;
#   - pkg/postinst runs --sync-keep after its sysupgrade.conf migration;
#   - pkg/postrm removes the second list on a real removal, never on an upgrade.
# Laptop only, no router involved:
#   sh tests/unit/test-keep-binary.sh [root]       (also runs under: busybox ash)
# root defaults to the repo. Another tree with the same four files at the same relative paths can be
# given instead, e.g. the pre-change baseline tests/results/20261003-build/baselines/pre-K1/, which
# must fail.
#
# The updater is SOURCED with TS_FIX_UPDATE_LIB=1, so the cases bind to shipping code; its library
# guard returns before the mode dispatch. A copy without that guard line ahead of the dispatch is
# never sourced, and every behavioural case then fails. Every path the updater writes or reads is
# pointed into a temp dir: TS_BIN, TS_DAEMON, TS_INIT, ROM_PREFIX and KEEP_BIN by the environment
# overrides it reads at load, LOCK, STATUS, CACHE, PLUGIN_CACHE and SYSUPGRADE_CONF by assignment
# after sourcing. The install leg (case e) tests install_binary, the function do_install calls once
# the download is verified, plus a static check of that call's place in do_install: do_install
# itself downloads to a fixed /tmp path, so it is not run here. pkg/postrm is run with its paths
# rewritten into the temp dir (linted first); pkg/postinst is checked statically. do_restore (case
# d) always runs under busybox ash, whatever shell runs this suite: its `exec 200>"$LOCK"` is a
# multi-digit fd redirection, which BusyBox ash (the router's shell) accepts and dash reads as a
# command named 200.
#
# The fakes, linted in case 0 before any case relies on them:
#   tailscale  fake_ts writes an executable that records its arguments in $T/ts-calls and prints
#              the given lines (a real `tailscale version` prints the version on line 1 and commit
#              lines after it); fake_hang one that execs a 30 s sleep; fake_fail one that writes to
#              stderr and exits 1.
#   timeout    a shell function recording its bound in $T/timeouts and running the command under a
#              real 2 s bound, so a hang leg costs 2 s, not 10.
#   logger, sleep, mv
#              shell functions recording their calls ($T/log, $T/calls, $T/mvlog); mv then runs the
#              real mv, sleep does not sleep.
#   the service TS_INIT names an executable fake recording "init <args>" in $T/calls.
# The four functions are written once to $T/fakes.sh and sourced both here and by the busybox ash
# driver, so the definitions case 0 lints are the ones every case uses.

R=${1:-"$(dirname "$0")/../.."}
UPD="$R/src/scripts/ts-fix-update"
KEEPD="$R/src/upgrade/keep.d/gl-tailscale-fix"
POSTINST="$R/pkg/postinst"
POSTRM="$R/pkg/postrm"
for f in "$UPD" "$KEEPD" "$POSTINST" "$POSTRM"; do
    [ -r "$f" ] || { echo "FAIL: cannot read $f"; exit 1; }
done

# Absolute, so `.` never searches PATH for it and the busybox ash driver finds it from anywhere.
UPD="$(cd "$(dirname "$UPD")" && pwd)/$(basename "$UPD")"

T=$(mktemp -d "${TMPDIR:-/tmp}/ts-fix-keep-bin.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
trap 'rm -rf "$T"' EXIT

fails=0; oks=0
ok()  { oks=$((oks + 1)); printf 'ok   %s\n' "$1"; }
nok() { fails=$((fails + 1)); printf 'FAIL %s\n       want: [%s]\n       got:  [%s]\n' "$1" "$2" "$3"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "$2" "$3"; fi; }
lines() { [ "$#" -eq 0 ] || printf '%s\n' "$@"; }
finish() {
    echo
    [ "$fails" -eq 0 ] && { echo "ALL PASS ($oks ok)"; exit 0; }
    echo "$fails FAILED ($oks ok)"; exit 1
}

# $T goes into sed replacements and generated scripts, so it must hold nothing special to either.
case "$T" in
    *[!A-Za-z0-9._/-]*) nok "the temp dir is safe in sed replacements and scripts" "[A-Za-z0-9._/-] only" "$T"; finish ;;
esac

SB="$T/usr/sbin"
TSD="$SB/tailscaled"
TSB="$SB/tailscale"
KD="$T/lib/upgrade/keep.d"
KB="$KD/gl-tailscale-fix-tailscale"
ROMSB="$T/rom$SB"
TINY="1.98.8-tiny.by.admon.1320"
COMMIT="  tailscale commit: 0123456789abcdef0123456789abcdef01234567"
CMT1="# Written by /usr/bin/ts-fix-update when the Version Manager installed this Tailscale binary;"
CMT2="# deleted on Restore."

# ------------------------------------------------------------------------------------- the fakes
fake_ts() {     # fake_ts <path> <line>...
    _ft=$1; shift
    printf '%s\n' "$@" > "$_ft.lines"
    printf '%s\n' '#!/bin/sh' "printf '%s\\n' \"\$*\" >> '$T/ts-calls'" "cat '$_ft.lines'" > "$_ft"
    chmod 755 "$_ft"
}
fake_hang() {   # fake_hang <path>
    printf '%s\n' '#!/bin/sh' "printf '%s\\n' \"\$*\" >> '$T/ts-calls'" 'exec sleep 30' > "$1"
    chmod 755 "$1"
}
fake_fail() {   # fake_fail <path>
    printf '%s\n' '#!/bin/sh' "printf '%s\\n' \"\$*\" >> '$T/ts-calls'" 'echo "no such daemon" >&2' 'exit 1' > "$1"
    chmod 755 "$1"
}
printf '%s\n' '#!/bin/sh' "printf 'init %s\\n' \"\$*\" >> '$T/calls'" > "$T/init"
chmod 755 "$T/init"

cat > "$T/fakes.sh" <<'EOF'
timeout() { printf '%s\n' "$1" >> "$T/timeouts"; shift; command timeout 2 "$@"; }
logger()  { printf '%s\n' "$*" >> "$T/log"; }
sleep()   { printf 'sleep %s\n' "$*" >> "$T/calls"; }
mv()      { printf 'mv %s\n' "$*" >> "$T/mvlog"; command mv "$@"; }
EOF
. "$T/fakes.sh"
# The updater sourced as a library with every path in $T, then the commands in $1. Sourced by
# in_upd in a subshell of this shell, and run by in_upd_ash as a busybox ash process.
cat > "$T/load.sh" <<'EOF'
if [ "$guard_ok" != "1" ]; then
    printf 'NOT SOURCED: no library guard ahead of the dispatch\n' >> "$T/notes"
    exit 1
fi
TS_FIX_UPDATE_LIB=1
TS_BIN="$TSB"; TS_DAEMON="$TSD"; TS_INIT="$T/init"; ROM_PREFIX="$T/rom"; KEEP_BIN="$KB"
. "$UPD"
set +e
LOCK="$T/lock"; STATUS="$T/status"; CACHE="$T/cache"; PLUGIN_CACHE="$T/plugin-cache"
SYSUPGRADE_CONF="$T/sysupgrade.conf"
for _fn in keep_write keep_remove install_binary do_sync_keep do_restore; do
    command -v "$_fn" >/dev/null 2>&1 || { printf 'MISSING: %s\n' "$_fn" >> "$T/notes"; exit 1; }
done
eval "$1"
EOF

fresh() {   # empty recordings, an empty fake root
    rm -rf "$T/usr" "$T/lib" "$T/rom" "$T/dl"
    mkdir -p "$SB" "$KD" "$ROMSB"
    for f in ts-calls timeouts log calls mvlog notes out err status lock sysupgrade.conf; do rm -f "$T/$f"; done
    : > "$T/ts-calls"; : > "$T/timeouts"; : > "$T/log"; : > "$T/calls"; : > "$T/mvlog"; : > "$T/notes"
}
installed() {   # installed <first version line>: tailscaled prints it, tailscale a symlink to it
    fake_ts "$TSD" "$1" "$COMMIT"
    ln -sf tailscaled "$TSB"
}
keep_old() { printf '%s\n' "# an older list" "/usr/sbin/tailscaled" > "$KB"; }
content() { if [ -e "$1" ] || [ -L "$1" ]; then cat "$1"; else printf '<absent>'; fi; }
kd_names() { ls -A "$KD" | tr '\n' ' ' | sed 's/ $//'; }
# What GL's sysupgrade reads from a keep list: the sed in /sbin/sysupgrade (gl-image 4.9.0
# base-files, list_static_conffiles) drops blank lines and lines starting with #.
effective() { sed -ne '/^[[:space:]]*$/d; /^#/d; p' "$1"; }

# --------------------------------------------------------------------------------------- case 0
echo "--- case 0: the fakes, and the checkers the static cases rely on"
fresh
fake_ts "$T/ft" "line one" "line two"
is "0 fake_ts prints its lines and records its arguments" "line one
line two|version --json" "$("$T/ft" version --json)|$(cat "$T/ts-calls")"
fake_fail "$T/ff"
is "0 fake_fail: nothing on stdout, a line on stderr, rc 1" "|no such daemon|1" \
    "$("$T/ff" version 2>"$T/err")|$(content "$T/err")|$("$T/ff" version >/dev/null 2>&1; echo $?)"
fake_hang "$T/fh"
command timeout 1 "$T/fh" >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ]; then ok "0 fake_hang is still running after 1 s (a 1 s bound kills it: rc $rc)"
else nok "0 fake_hang is still running after 1 s" "rc != 0" "rc 0"; fi
command timeout 1 "$T/ft" >/dev/null 2>&1; rc=$?
is "0 ... while fake_ts finishes under the same 1 s bound" 0 "$rc"
: > "$T/timeouts"
t0=$(date +%s); timeout 10 "$T/fh" >/dev/null 2>&1; rc=$?; t1=$(date +%s)
if [ "$rc" -ne 0 ] && [ $((t1 - t0)) -le 5 ]; then ok "0 the timeout fake bounds a hang (rc $rc, $((t1 - t0)) s)"
else nok "0 the timeout fake bounds a hang" "rc != 0 within 5 s" "rc $rc after $((t1 - t0)) s"; fi
is "0 ... and records the bound it was asked for" "10" "$(cat "$T/timeouts")"
is "0 the timeout fake passes output, arguments and status through" "a b|c|7" \
    "$(timeout 10 printf '%s|' 'a b' c; timeout 10 sh -c 'exit 7'; printf '%s' "$?")"
logger -t ts-fix "lint line"; sleep 3; "$T/init" stop
is "0 logger records its arguments" "-t ts-fix lint line" "$(cat "$T/log")"
is "0 sleep and the service fake record, in order" "sleep 3
init stop" "$(cat "$T/calls")"
printf 'x\n' > "$T/mvsrc"; mv "$T/mvsrc" "$T/mvdst"
is "0 mv records and moves" "mv $T/mvsrc $T/mvdst|<absent>|x" "$(cat "$T/mvlog")|$(content "$T/mvsrc")|$(cat "$T/mvdst")"
fakes=""
for f in timeout logger sleep mv; do
    case "$(type "$f" 2>&1)" in *function*) fakes="$fakes $f" ;; esac
done
is "0 timeout, logger, sleep and mv resolve to their fake functions in this shell" " timeout logger sleep mv" "$fakes"
command -v busybox >/dev/null 2>&1 || nok "busybox present (case d and the process legs run under busybox ash)" "busybox" "not found"
is "0 ... and in the busybox ash driver's shell, before the updater is loaded" " timeout logger sleep mv" \
    "$(T="$T" busybox ash -c '. "$T/fakes.sh"; for f in timeout logger sleep mv; do
        case "$(type "$f" 2>&1)" in *function*) printf " %s" "$f" ;; esac; done' 2>&1)"
# The keep-list checker, both directions: a binary line is found, the same text in a comment is not.
printf '%s\n' "# /usr/sbin/tailscaled is mentioned here" "" "/etc/config/ts-fix" "/usr/sbin/tailscaled" > "$T/kl-pos"
printf '%s\n' "# /usr/sbin/tailscaled is mentioned here" "/etc/config/ts-fix" > "$T/kl-neg"
is "0 effective(): a listed binary is read, a commented one and the blank line are not" \
    "/etc/config/ts-fix
/usr/sbin/tailscaled" "$(effective "$T/kl-pos")"
is "0 effective(): with only a comment naming it, nothing about the binary" "/etc/config/ts-fix" "$(effective "$T/kl-neg")"
# The order checker, both directions.
in_order() {    # in_order <file> <function> <fixed line>...: each once in the function's body, in order
    _io_f=$1; _io_fn=$2; shift 2
    _io_body=$(awk -v fn="$_io_fn" '$0 == fn "() {" { on = 1 } on { print } on && /^}/ { exit }' "$_io_f")
    [ -n "$_io_body" ] || { printf 'no function %s' "$_io_fn"; return 1; }
    _io_prev=0
    for _io_l in "$@"; do
        _io_n=$(printf '%s\n' "$_io_body" | grep -c -x -F -e "$_io_l")
        [ "$_io_n" = 1 ] || { printf '%s x%s' "$_io_l" "$_io_n"; return 1; }
        _io_at=$(printf '%s\n' "$_io_body" | grep -n -x -F -e "$_io_l" | cut -d: -f1)
        [ "$_io_at" -gt "$_io_prev" ] || { printf 'out of order: %s' "$_io_l"; return 1; }
        _io_prev=$_io_at
    done
    printf 'in order'
}
printf '%s\n' 'f() {' '    one' '    two' '}' 'g() {' '    two' '}' > "$T/order-fx"
is "0 in_order: ascending lines pass" "in order" "$(in_order "$T/order-fx" f '    one' '    two')"
is "0 in_order: swapped lines fail" "out of order:     one" "$(in_order "$T/order-fx" f '    two' '    one')"
is "0 in_order: a line outside the function is not found in it" "    one x0" "$(in_order "$T/order-fx" g '    one')"
is "0 in_order: a missing function fails" "no function h" "$(in_order "$T/order-fx" h '    one')"

# --------------------------------------------------------------------------------------- case a
echo "--- case a: the static keep list no longer names the binaries, and still names itself"
eff=$(effective "$KEEPD")
n=$(printf '%s\n' "$eff" | grep -c .)
if [ "$n" -ge 10 ]; then ok "a the list parses to $n entries (the parse read it)"
else nok "a the list parses to its entries" ">= 10 entries" "$n"; fi
is "a no entry is /usr/sbin/tailscale or /usr/sbin/tailscaled (or starts with them)" "" \
    "$(printf '%s\n' "$eff" | grep -e '^/usr/sbin/tailscale')"
is "a no entry is the dynamic list either (it is written at runtime, never shipped)" "" \
    "$(printf '%s\n' "$eff" | grep -x -F -e /lib/upgrade/keep.d/gl-tailscale-fix-tailscale)"
is "a it still lists itself" "/lib/upgrade/keep.d/gl-tailscale-fix" \
    "$(printf '%s\n' "$eff" | grep -x -F -e /lib/upgrade/keep.d/gl-tailscale-fix)"
is "a its comment names the file that now lists them" "1" \
    "$(grep -c -e '^#.*/lib/upgrade/keep\.d/gl-tailscale-fix-tailscale' "$KEEPD")"

# -------------------------------------------------------------------------------- static checks
echo "--- static: the updater's library guard, its defaults, its call sites"
GUARD='[ "${TS_FIX_UPDATE_LIB:-0}" = "1" ] && return 0'
g_n=$(grep -c -x -F -e "$GUARD" "$UPD")
g_at=$(grep -n -x -F -e "$GUARD" "$UPD" | head -n 1 | cut -d: -f1)
c_at=$(grep -n -x -F -e 'case "$1" in' "$UPD" | tail -n 1 | cut -d: -f1)
f_at=$(grep -n -e '^[a-z_]*() {$' "$UPD" | tail -n 1 | cut -d: -f1)
guard_ok=0
if [ "$g_n" = "1" ] && [ -n "$c_at" ] && [ -n "$f_at" ] && [ "$g_at" -lt "$c_at" ] && [ "$g_at" -gt "$f_at" ]; then
    guard_ok=1
    ok "S1 the library guard appears once, after the last function and ahead of the dispatch"
else
    nok "S1 the library guard appears once, after the last function and ahead of the dispatch" \
        "1 guard line, last function < guard < case" "count=$g_n guard=[$g_at] last-fn=[$f_at] case=[$c_at]"
fi
got=$(
    [ "$guard_ok" = "1" ] || { echo "NOT SOURCED"; exit 0; }
    unset TS_BIN TS_DAEMON TS_INIT ROM_PREFIX KEEP_BIN
    TS_FIX_UPDATE_LIB=1
    . "$UPD"
    printf '%s ' "$TS_BIN" "$TS_DAEMON" "$TS_INIT" "$ROM_PREFIX" "$KEEP_BIN"
)
is "S2 unset, the overridable paths default to the production ones" \
    "/usr/sbin/tailscale /usr/sbin/tailscaled /etc/init.d/tailscale /rom /lib/upgrade/keep.d/gl-tailscale-fix-tailscale " "$got"
is "S3 do_install: stop, then install_binary (which keeps the binary), then start" "in order" \
    "$(in_order "$UPD" do_install '    "$TS_INIT" stop 2>/dev/null || true' '    install_binary "$tmpfile"' \
        '    "$TS_INIT" start 2>/dev/null || true')"
is "S3 ... and do_install no longer moves the download into place itself" "0" \
    "$(awk '$0 == "do_install() {" { on = 1 } on { print } on && /^}/ { exit }' "$UPD" | grep -c -F -e 'mv "$tmpfile"')"
is "S4 install_binary: keep_write only once the binary and the symlink are in place" "in order" \
    "$(in_order "$UPD" install_binary '    mv "$1" "$TS_DAEMON"' '    chmod 755 "$TS_DAEMON"' \
        '    ln -sf tailscaled "$TS_BIN"' '    keep_write || true')"
# The restore steps live in restore_factory, which do_restore calls (as does the rollback of an
# install whose new binary prints no version; tests/unit/test-arch-select.sh covers that).
is "S5 restore_factory: keep_remove only once the factory binaries are copied back, before the restart" "in order" \
    "$(in_order "$UPD" restore_factory '    cp -a "${ROM_PREFIX}${TS_BIN}" "$TS_BIN"' \
        '    cp -a "${ROM_PREFIX}${TS_DAEMON}" "$TS_DAEMON"' '    keep_remove || true' '    "$TS_INIT" start 2>/dev/null || true')"
is "S5 ... and do_restore runs restore_factory once" "in order" "$(in_order "$UPD" do_restore '    restore_factory')"
is "S6 the dispatch has a --sync-keep mode" "1" \
    "$(grep -c -x -F -e '    --sync-keep)     do_sync_keep ;;' "$UPD")"
TS_FIX_UPDATE_LIB=0 TS_BIN="$TSB" TS_DAEMON="$TSD" TS_INIT="$T/init" ROM_PREFIX="$T/rom" KEEP_BIN="$KB" \
    sh "$UPD" --no-such-mode > "$T/out" 2>&1; rc=$?
is "S6 ... and the usage text names it, on the usage line and its own (an unknown mode: usage, rc 1)" "2 1" \
    "$(grep -c -e '--sync-keep' "$T/out") $rc"

# in_upd <commands> — in a subshell of this shell, load.sh: the updater as a library, then commands
in_upd() { ( set -- "$1"; . "$T/load.sh" ); }
# in_upd_ash <commands> — the same, as a busybox ash process (the fakes sourced first)
in_upd_ash() {
    T="$T" UPD="$UPD" TSB="$TSB" TSD="$TSD" KB="$KB" guard_ok="$guard_ok" \
        busybox ash -c '. "$T/fakes.sh"; . "$T/load.sh"' in_upd_ash "$1"
}

# --------------------------------------------------------------------------------------- case b
echo "--- case b: keep_write writes the list atomically, exactly, naming itself"
fresh
got=$(
    [ "$guard_ok" = "1" ] || { echo "NOT SOURCED"; exit 0; }
    unset TS_BIN TS_DAEMON
    TS_FIX_UPDATE_LIB=1; KEEP_BIN="$KB"
    . "$UPD"
    set +e
    command -v keep_write >/dev/null 2>&1 || { echo "MISSING keep_write"; exit 0; }
    keep_write; printf 'rc=%s' "$?"
)
is "b production binary paths: rc 0" "rc=0" "$got"
is "b ... the content, exactly: the comment, both binaries, then the list's own path" \
    "$(lines "$CMT1" "$CMT2" /usr/sbin/tailscaled /usr/sbin/tailscale "$KB")" "$(content "$KB")"
is "b ... what sysupgrade reads from it: both binaries and the list itself" \
    "$(lines /usr/sbin/tailscaled /usr/sbin/tailscale "$KB")" "$(effective "$KB" 2>&1)"
is "b ... no temp file left in the keep.d directory" "gl-tailscale-fix-tailscale" "$(kd_names)"
case "$(cat "$T/mvlog")" in
    "mv -f $KD/.gl-tailscale-fix-tailscale.tmp."[0-9]*" $KB") ok "b ... renamed into place from a dot-named temp file in the same directory" ;;
    *) nok "b ... renamed into place from a dot-named temp file in the same directory" \
        "mv -f $KD/.gl-tailscale-fix-tailscale.tmp.<pid> $KB" "$(cat "$T/mvlog")" ;;
esac
is "b ... nothing logged" "" "$(cat "$T/log")"
keep_old
ino0=$(ls -di "$KB" | awk '{ print $1 }')
: > "$T/mvlog"
in_upd 'keep_write; printf "%s\n" "$?" > "$T/rc"'
ino1=$(ls -di "$KB" 2>/dev/null | awk '{ print $1 }')
is "b over an existing list: rc 0" "0" "$(content "$T/rc")"
is "b ... replaced, exactly (the test's binary paths this time)" "$(lines "$CMT1" "$CMT2" "$TSD" "$TSB" "$KB")" "$(content "$KB")"
if [ -n "$ino1" ] && [ "$ino0" != "$ino1" ]; then ok "b ... a new file renamed over the old one, not rewritten in place (inode $ino0 -> $ino1)"
else nok "b ... a new file renamed over the old one, not rewritten in place" "inode changed" "$ino0 -> $ino1"; fi
is "b ... no temp file left" "gl-tailscale-fix-tailscale" "$(kd_names)"
rm -rf "$KD"
in_upd 'keep_write > "$T/out" 2> "$T/err"; printf "%s\n" "$?" > "$T/rc"; echo continued >> "$T/notes"'
is "b the keep.d directory missing: rc 1, and the caller's shell carries on" "1|continued" "$(content "$T/rc")|$(cat "$T/notes")"
is "b ... nothing created, nothing on stdout or stderr" "<absent>||" "$(content "$KB")|$(content "$T/out")|$(content "$T/err")"
is "b ... one syslog line naming the list" \
    "-t ts-fix ts-fix-update: could not write $KB - this Tailscale binary will not be kept across a firmware upgrade" "$(cat "$T/log")"

# --------------------------------------------------------------------------------------- case c
echo "--- case c: --sync-keep keeps a Version Manager binary, and nothing else"
sync_case() {   # sync_case <label> <want KEEP_BIN content>: run do_sync_keep under set -e, as in production
    : > "$T/ts-calls"; : > "$T/timeouts"
    in_upd '( set -e; do_sync_keep ) > "$T/out" 2> "$T/err"; printf "%s\n" "$?" > "$T/rc"'
    is "$1: rc 0, silent" "0||" "$(content "$T/rc")|$(content "$T/out")|$(content "$T/err")"
    is "$1: the list" "$2" "$(content "$KB")"
}
WANT_LIST=$(lines "$CMT1" "$CMT2" "$TSD" "$TSB" "$KB")
fresh; installed "$TINY"
sync_case "c tiny build, no list yet" "$WANT_LIST"
is "c ... it asked the binary for its version, bounded at 10 s" "version|10" "$(cat "$T/ts-calls")|$(cat "$T/timeouts")"
fresh; installed "$TINY"; keep_old
sync_case "c tiny build, an older list" "$WANT_LIST"
fresh; installed "1.92.5"; keep_old
sync_case "c firmware build 1.92.5, a list from an older plugin" "<absent>"
fresh; installed "1.92.5"
sync_case "c firmware build 1.92.5, no list" "<absent>"
fresh; installed "1.80.3"; keep_old
sync_case "c firmware build 1.80.3 (the one the bug carried over), a list" "<absent>"
fresh; installed "1.92.5" "  build: $TINY"; keep_old
sync_case "c the tiny string only on line 2: not a Version Manager build" "<absent>"
fresh; fake_ts "$TSB" "$TINY" "$COMMIT"; keep_old
sync_case "c no tailscaled (a tailscale that would answer tiny)" "<absent>"
is "c ... the version was not even asked" "" "$(cat "$T/ts-calls")"
fresh; fake_fail "$TSD"; ln -sf tailscaled "$TSB"; keep_old
sync_case "c version command fails" "<absent>"
fresh; fake_hang "$TSD"; ln -sf tailscaled "$TSB"; keep_old
t0=$(date +%s)
sync_case "c version command hangs" "<absent>"
t1=$(date +%s)
if [ $((t1 - t0)) -le 6 ]; then ok "c ... bounded: $((t1 - t0)) s under the fake's 2 s bound"
else nok "c ... bounded" "<= 6 s" "$((t1 - t0)) s"; fi
is "c ... and the bound the updater asked for is 10" "10" "$(cat "$T/timeouts")"
fresh; installed "$TINY"; rm -rf "$KD"
sync_case "c tiny build, the list cannot be written" "<absent>"
is "c ... logged" "1" "$(grep -c -F -e "could not write $KB" "$T/log")"

echo "--- case c (process): ts-fix-update --sync-keep as postinst runs it, under sh and busybox ash"
run_sync() {    # run_sync <shell words>: the updater as a separate process, every path in $T
    TS_FIX_UPDATE_LIB=0 TS_BIN="$TSB" TS_DAEMON="$TSD" TS_INIT="$T/init" ROM_PREFIX="$T/rom" KEEP_BIN="$KB" \
        $1 "$UPD" --sync-keep > "$T/out" 2> "$T/err"
}
for shl in "sh" "busybox ash"; do
    fresh; installed "$TINY"
    run_sync "$shl"; rc=$?
    is "c [$shl] tiny build: rc 0, silent" "0||" "$rc|$(content "$T/out")|$(content "$T/err")"
    is "c [$shl] ... the list written" "$WANT_LIST" "$(content "$KB")"
    fresh; installed "1.92.5"; keep_old
    run_sync "$shl"; rc=$?
    is "c [$shl] firmware build, a list: rc 0, silent, the list removed" "0|||<absent>" \
        "$rc|$(content "$T/out")|$(content "$T/err")|$(content "$KB")"
    fresh; keep_old
    run_sync "$shl"; rc=$?
    is "c [$shl] no binary at all, a list: rc 0, silent, the list removed" "0|||<absent>" \
        "$rc|$(content "$T/out")|$(content "$T/err")|$(content "$KB")"
    fresh; fake_fail "$TSD"; ln -sf tailscaled "$TSB"; keep_old
    run_sync "$shl"; rc=$?
    is "c [$shl] version command fails, a list: rc 0, silent, the list removed" "0|||<absent>" \
        "$rc|$(content "$T/out")|$(content "$T/err")|$(content "$KB")"
done

# --------------------------------------------------------------------------------------- case d
echo "--- case d: Restore puts the factory binaries back and stops keeping them"
restore_setup() {   # a Version Manager binary installed and kept; the firmware's 1.92.5 in the fake /rom
    fresh
    installed "$TINY"
    keep_old
    fake_ts "$ROMSB/tailscaled" "1.92.5" "$COMMIT"
    ln -sf tailscaled "$ROMSB/tailscale"
    # do_restore drops the lines naming its own binary paths, which here are the test's
    printf '%s\n' "/etc/something" "$TSD" "$TSB" > "$T/sysupgrade.conf"
}
restore_setup
in_upd_ash '( set -e; do_restore ) > "$T/out" 2> "$T/err"; printf "%s\n" "$?" > "$T/rc"'
is "d rc 0, nothing on stdout or stderr" "0||" "$(content "$T/rc")|$(content "$T/out")|$(content "$T/err")"
is "d the list is gone" "<absent>" "$(content "$KB")"
if cmp -s "$ROMSB/tailscaled" "$TSD"; then ok "d tailscaled is the factory binary again"
else nok "d tailscaled is the factory binary again" "same as $ROMSB/tailscaled" "$(head -n 3 "$TSD" 2>&1)"; fi
is "d tailscale is the factory symlink again" "tailscaled" "$(readlink "$TSB" 2>&1)"
is "d the service stopped, then started (sleeps stubbed)" "$(lines 'init stop' 'sleep 1' 'init start' 'sleep 3')" "$(cat "$T/calls")"
is "d status: success, naming the restored version" '{"status":"success","message":"Restored to factory version (1.92.5)"}' \
    "$(content "$T/status")"
is "d the lock was cleaned up" "<absent>" "$(content "$T/lock")"
is "d stale sysupgrade.conf entries cleaned, as before" "/etc/something" "$(cat "$T/sysupgrade.conf")"
is "d nothing logged" "" "$(cat "$T/log")"
restore_setup
rm -f "$ROMSB/tailscaled"
in_upd_ash '( set -e; do_restore ) > "$T/out" 2> "$T/err"; printf "%s\n" "$?" > "$T/rc"'
is "d no factory binary: rc 1, an error status" "1|{\"status\":\"error\",\"message\":\"Factory binary not found: $T/rom$TSD\"}" \
    "$(content "$T/rc")|$(content "$T/status")"
is "d ... the installed binary and its list are left alone" "$TINY|$(lines "# an older list" /usr/sbin/tailscaled)" \
    "$("$TSD" version | head -n 1)|$(content "$KB")"
is "d ... the service untouched" "" "$(cat "$T/calls")"

# --------------------------------------------------------------------------------------- case e
echo "--- case e: install_binary (do_install's install step) puts the binary in place and keeps it"
fresh
installed "1.92.5"
fake_ts "$T/dl" "$TINY" "$COMMIT"
cp "$T/dl" "$T/dl.expect"
in_upd '( set -e; install_binary "$T/dl" ) > "$T/out" 2> "$T/err"; printf "%s\n" "$?" > "$T/rc"'
is "e rc 0, silent" "0||" "$(content "$T/rc")|$(content "$T/out")|$(content "$T/err")"
if cmp -s "$T/dl.expect" "$TSD"; then ok "e tailscaled is the download"
else nok "e tailscaled is the download" "same as the download" "$(head -n 3 "$TSD" 2>&1)"; fi
is "e ... mode 755, the download moved (not copied), tailscale a symlink to it" "755|<absent>|tailscaled" \
    "$(stat -c %a "$TSD" 2>&1)|$(content "$T/dl")|$(readlink "$TSB" 2>&1)"
is "e the list written, exactly" "$WANT_LIST" "$(content "$KB")"
is "e ... the binary answers with the tiny version through the symlink" "$TINY" "$("$TSB" version | head -n 1)"
fresh
installed "1.92.5"
fake_ts "$T/dl" "$TINY" "$COMMIT"
rm -rf "$KD"
in_upd '( set -e; install_binary "$T/dl"; echo "install continued" ) > "$T/out" 2> "$T/err"; printf "%s\n" "$?" > "$T/rc"'
is "e the list cannot be written: the install still completes, rc 0" "0|install continued|" \
    "$(content "$T/rc")|$(content "$T/out")|$(content "$T/err")"
is "e ... the binary is in place" "$TINY" "$("$TSB" version 2>&1 | head -n 1)"
is "e ... and the failure is logged" "1" "$(grep -c -F -e "could not write $KB" "$T/log")"

# --------------------------------------------------------------------------------------- case f
echo "--- case f: postinst runs --sync-keep after the sysupgrade.conf migration; postrm removes the list"
CALL='/usr/bin/ts-fix-update --sync-keep >/dev/null 2>&1 || true'
call_n=$(grep -c -F -e '--sync-keep' "$POSTINST")
call_at=$(grep -n -x -F -e "$CALL" "$POSTINST" | head -n 1 | cut -d: -f1)
sym_at=$(grep -n -x -F -e '    ln -sf tailscaled /usr/sbin/tailscale' "$POSTINST" | head -n 1 | cut -d: -f1)
mig_at=$(grep -n -x -F -e 'if [ -f /etc/sysupgrade.conf ]; then' "$POSTINST" | head -n 1 | cut -d: -f1)
fi_at=$(awk -v m="${mig_at:-0}" 'm > 0 && NR > m && /^fi$/ { print NR; exit }' "$POSTINST")
fw_at=$(grep -n -F -e 'fw_ver=$(awk' "$POSTINST" | head -n 1 | cut -d: -f1)
if [ "$call_n" = "1" ] && [ -n "$call_at" ] && [ -n "$sym_at" ] && [ -n "$fi_at" ] && [ -n "$fw_at" ] &&
   [ "$sym_at" -lt "$mig_at" ] && [ "$fi_at" -lt "$call_at" ] && [ "$call_at" -lt "$fw_at" ]; then
    ok "f postinst: one top-level --sync-keep call, after the symlink repair and the migration block"
else
    nok "f postinst: one top-level --sync-keep call, after the symlink repair and the migration block" \
        "1 call, symlink < migration fi < call < fw_ver" \
        "count=$call_n symlink=[$sym_at] migration=[$mig_at] fi=[$fi_at] call=[$call_at] fw_ver=[$fw_at]"
fi
if [ -n "$fi_at" ] && [ -n "$call_at" ]; then
    between=$(awk -v a="$fi_at" -v b="$call_at" 'NR > a && NR < b && !/^#/ && !/^[[:space:]]*$/' "$POSTINST")
    is "f ... with nothing but comments between the migration block and the call" "" "$between"
else
    nok "f ... with nothing but comments between the migration block and the call" "the block and the call found" \
        "fi=[$fi_at] call=[$call_at]"
fi

g2_at=$(grep -n -x -F -e '[ "$PKG_UPGRADE" = "1" ] && exit 0' "$POSTRM" | head -n 1 | cut -d: -f1)
rm_n=$(grep -c -F -e 'gl-tailscale-fix-tailscale' "$POSTRM")
rm_at=$(grep -n -x -F -e 'rm -f /lib/upgrade/keep.d/gl-tailscale-fix-tailscale' "$POSTRM" | head -n 1 | cut -d: -f1)
ng_at=$(grep -n -F -e '/etc/init.d/nginx' "$POSTRM" | grep -v -e '^[0-9]*:#' | head -n 1 | cut -d: -f1)
if [ "$rm_n" = "1" ] && [ -n "$g2_at" ] && [ -n "$rm_at" ] && [ -n "$ng_at" ] && [ "$g2_at" -lt "$rm_at" ] && [ "$rm_at" -lt "$ng_at" ]; then
    ok "f postrm: one removal of the list, after the PKG_UPGRADE guard"
else
    nok "f postrm: one removal of the list, after the PKG_UPGRADE guard" "1 rm line, guard < rm < nginx" \
        "count=$rm_n guard=[$g2_at] rm=[$rm_at] nginx=[$ng_at]"
fi

# postrm run: its paths rewritten into $T/pr, linted, then run under each PKG_UPGRADE value.
pr_code=$(sed -e "s|/lib/upgrade/keep\.d/|$T/pr/lib/upgrade/keep.d/|g" \
    -e "s|/etc/init\.d/nginx|$T/pr/etc/init.d/nginx|g" \
    -e "s|/etc/init\.d/firewall|$T/pr/etc/init.d/firewall|g" \
    -e "s|/tmp/ts-fix-isolate6\.lock|$T/pr/ts-fix-isolate6.lock|g" "$POSTRM")
left=$(printf '%s\n' "$pr_code" | grep -v -e '^[[:space:]]*#' | sed "s|$T/pr/|@PR@:|g" |
    grep -e '/etc/' -e '/lib/' -e '/usr/' -e '/tmp/' -e '/rom/' -e '/sbin/' -e '/bin/')
is "f postrm instrument lint: every path in its code now points into the temp dir" "" "$left"
if [ -z "$left" ]; then
    run_postrm() {  # run_postrm <PKG_UPGRADE value | unset>
        rm -rf "$T/pr"; mkdir -p "$T/pr/lib/upgrade/keep.d"
        printf 'list\n' > "$T/pr/lib/upgrade/keep.d/gl-tailscale-fix-tailscale"
        printf 'static\n' > "$T/pr/lib/upgrade/keep.d/gl-tailscale-fix"
        : > "$T/pr-calls"
        (
            pgrep() { printf 'pgrep %s\n' "$*" >> "$T/pr-calls"; return 1; }
            kill()  { printf 'kill %s\n' "$*" >> "$T/pr-calls"; }
            sleep() { printf 'sleep %s\n' "$*" >> "$T/pr-calls"; }
            # postrm's isolate6 block reads the firewall config; an empty one leaves it nothing to
            # do (tests/unit/test-isolate6.sh cases P and P2 test that block and its lock, which
            # takes the real flock here on a file in $T/pr). A WARNING from it would be recorded,
            # never sent to this machine's syslog.
            uci()   { :; }
            logger() { printf 'logger %s\n' "$*" >> "$T/pr-calls"; }
            if [ "$1" = "unset" ]; then unset PKG_UPGRADE; else PKG_UPGRADE=$1; fi
            eval "$pr_code"
        ) > "$T/out" 2>&1
        printf '%s' "$?"
    }
    is "f postrm, PKG_UPGRADE=1 (an opkg upgrade): rc 0, the list kept" "0|list" \
        "$(run_postrm 1)|$(content "$T/pr/lib/upgrade/keep.d/gl-tailscale-fix-tailscale")"
    is "f postrm, PKG_UPGRADE=0 (opkg remove): rc 0, the list removed" "0|<absent>" \
        "$(run_postrm 0)|$(content "$T/pr/lib/upgrade/keep.d/gl-tailscale-fix-tailscale")"
    is "f ... the static list is not its business (opkg removes package files)" "static" \
        "$(content "$T/pr/lib/upgrade/keep.d/gl-tailscale-fix")"
    is "f postrm, PKG_UPGRADE unset (apk post-deinstall): rc 0, the list removed" "0|<absent>" \
        "$(run_postrm unset)|$(content "$T/pr/lib/upgrade/keep.d/gl-tailscale-fix-tailscale")"
    is "f ... no nginx handling reached (no fake nginx init), no output" "|" "$(cat "$T/pr-calls")|$(content "$T/out")"
fi

finish
