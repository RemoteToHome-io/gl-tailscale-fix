#!/bin/sh
# Unit test for the Version Manager's choice of Tailscale binary and its checks on it, in
# src/scripts/ts-fix-update. A 32-bit MIPS kernel reports `uname -m` = mips for both byte orders, so
# a little-endian MT7621 router (GL-MG1300) was handed the big-endian asset tailscaled-linux-mips,
# which its kernel cannot run, and the install still reported success. Now:
#   - detect_arch takes a mips router's byte order from byte 5 (EI_DATA) of the ELF header of
#     REF_ELF, a binary the router runs (default /bin/busybox): 1 -> mipsle, 2 -> mips, anything
#     else -> "" (the "Unsupported architecture" error);
#   - check_download, run by do_install after the size check and before anything is stopped,
#     refuses a download that is not ELF or whose byte order differs from REF_ELF's;
#   - a new binary that prints no version is rolled back to the factory one (rollback_install, via
#     restore_factory, which do_restore now shares), and success names only a version the binary
#     printed.
# Laptop only, no router involved:
#   sh tests/unit/test-arch-select.sh [root]       (also runs under: busybox ash)
# root defaults to the repo. Another tree with src/scripts/ts-fix-update at the same relative path
# can be given instead, e.g. the pre-change baseline tests/results/20261028-mips-arch/baselines/pre/,
# which must fail.
#
# The updater is SOURCED with TS_FIX_UPDATE_LIB=1, as in tests/unit/test-keep-binary.sh: TS_BIN,
# TS_DAEMON, TS_INIT, ROM_PREFIX, KEEP_BIN and REF_ELF point into a temp dir through the overrides
# it reads at load, LOCK, STATUS, CACHE, PLUGIN_CACHE and SYSUPGRADE_CONF by assignment after
# sourcing. do_install downloads to a fixed /tmp path, so it is not run: the functions it calls are
# (cases B, C, D), and case E checks statically where it calls them. Cases B, C and D run twice: in
# a subshell of the shell running this suite, and as a busybox ash process (the router's shell,
# where dd and cmp are BusyBox applets). The do_restore leg runs under busybox ash only: its
# `exec 200>"$LOCK"` is a multi-digit fd redirection, which dash reads as a command named 200.
#
# The fakes and checkers, linted in case 0 before any case relies on them:
#   uname      a shell function printing $FAKE_M for -m, the real uname otherwise;
#   sleep, logger
#              shell functions recording their calls ($T/calls, $T/log); sleep does not sleep;
#   the service TS_INIT names an executable fake recording "init <args>" in $T/calls;
#   fake_ts    an executable printing the given lines, as `tailscale version` does; fake_silent one
#              that prints nothing on stdout, as a binary the kernel cannot run gives no version;
#   ELF headers written with printf into $T/fx, their bytes checked with od (present on this laptop,
#              missing on the GL routers checked, so the updater must not use it: case E checks
#              that too);
#   in_order and uses_od, the static checkers case E relies on.
# The three functions are written once to $T/fakes.sh and sourced both here and by the busybox ash
# driver, so the definitions case 0 lints are the ones every case uses.

R=${1:-"$(dirname "$0")/../.."}
UPD="$R/src/scripts/ts-fix-update"
[ -r "$UPD" ] || { echo "FAIL: cannot read $UPD"; exit 1; }

# Absolute, so `.` never searches PATH for it and the busybox ash driver finds it from anywhere.
UPD="$(cd "$(dirname "$UPD")" && pwd)/$(basename "$UPD")"

T=$(mktemp -d "${TMPDIR:-/tmp}/ts-fix-arch.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
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

# $T goes into generated scripts, so it must hold nothing special to the shell.
case "$T" in
    *[!A-Za-z0-9._/-]*) nok "the temp dir is safe in scripts" "[A-Za-z0-9._/-] only" "$T"; finish ;;
esac

SB="$T/usr/sbin"
TSD="$SB/tailscaled"
TSB="$SB/tailscale"
KD="$T/lib/upgrade/keep.d"
KB="$KD/gl-tailscale-fix-tailscale"
ROMSB="$T/rom$SB"
FX="$T/fx"
COMMIT="  tailscale commit: 0123456789abcdef0123456789abcdef01234567"
NEWV="1.104.4"
ST_GUARD='{"status":"error","message":"Downloaded binary does not match this router - nothing was changed"}'
ST_RB="{\"status\":\"error\",\"message\":\"Tailscale $NEWV did not run on this router - factory version restored\"}"
ST_NOROM="{\"status\":\"error\",\"message\":\"Tailscale $NEWV did not run on this router and no factory binary was found to restore\"}"
ST_RBFAIL="{\"status\":\"error\",\"message\":\"Tailscale $NEWV did not run on this router and the factory version could not be restored\"}"

# ------------------------------------------------------------------------------------- the fakes
fake_ts() {     # fake_ts <path> <line>...
    _ft=$1; shift
    printf '%s\n' "$@" > "$_ft.lines"
    printf '%s\n' '#!/bin/sh' "cat '$_ft.lines'" > "$_ft"
    chmod 755 "$_ft"
}
fake_silent() { # fake_silent <path>: nothing on stdout, a line on stderr, rc 126
    printf '%s\n' '#!/bin/sh' 'echo "Exec format error" >&2' 'exit 126' > "$1"
    chmod 755 "$1"
}
printf '%s\n' '#!/bin/sh' "printf 'init %s\\n' \"\$*\" >> '$T/calls'" > "$T/init"
chmod 755 "$T/init"

cat > "$T/fakes.sh" <<'EOF'
uname()  { if [ "$1" = "-m" ]; then printf '%s\n' "$FAKE_M"; else command uname "$@"; fi; }
sleep()  { printf 'sleep %s\n' "$*" >> "$T/calls"; }
logger() { printf '%s\n' "$*" >> "$T/log"; }
EOF
. "$T/fakes.sh"
# The updater sourced as a library with every path in $T, the functions named in $2 required, then
# the commands in $1. Sourced by in_upd in a subshell of this shell, run by in_upd_ash as a busybox
# ash process.
cat > "$T/load.sh" <<'EOF'
if [ "$guard_ok" != "1" ]; then
    printf 'NOT SOURCED: no library guard ahead of the dispatch\n' >> "$T/notes"
    exit 1
fi
TS_FIX_UPDATE_LIB=1
TS_BIN="$TSB"; TS_DAEMON="$TSD"; TS_INIT="$T/init"; ROM_PREFIX="$T/rom"; KEEP_BIN="$KB"; REF_ELF="$REF"
. "$UPD"
set +e
LOCK="$T/lock"; STATUS="$T/status"; CACHE="$T/cache"; PLUGIN_CACHE="$T/plugin-cache"
SYSUPGRADE_CONF="$T/sysupgrade.conf"
for _fn in $2; do
    command -v "$_fn" >/dev/null 2>&1 || { printf 'MISSING: %s\n' "$_fn" >> "$T/notes"; exit 1; }
done
eval "$1"
EOF

fresh() {   # empty recordings, an empty fake root
    rm -rf "$T/usr" "$T/lib" "$T/rom" "$T/dl" "$T/dl.expect" "$T/tsd.expect"
    mkdir -p "$SB" "$KD" "$ROMSB"
    for f in log calls notes out err rc status lock sysupgrade.conf; do rm -f "$T/$f"; done
    : > "$T/log"; : > "$T/calls"; : > "$T/notes"
}
content() { if [ -e "$1" ] || [ -L "$1" ]; then cat "$1"; else printf '<absent>'; fi; }
hx() { od -An -tx1 -N6 "$1" | tr -d ' \n'; }     # the first six bytes, in hex
first_ver() { "$1" version 2>/dev/null | head -n 1 | awk '{print $1}'; }   # as do_install reads it
keep_old() { printf '%s\n' "# an older list" "/usr/sbin/tailscaled" > "$KB"; }

# --------------------------------------------------------------------------------------- case 0
echo "--- case 0: the fixtures, the fakes, and the checkers the static cases rely on"
fresh
command -v od >/dev/null 2>&1 || nok "od present on this laptop (it checks the fixtures)" "od" "not found"
command -v busybox >/dev/null 2>&1 || nok "busybox present (the ash driver and the dd applet lint)" "busybox" "not found"
is "0 od reads bytes as hex, both directions (AB -> 4142, BA -> 4241)" "4142|4241" \
    "$(printf 'AB' | od -An -tx1 | tr -d ' \n')|$(printf 'BA' | od -An -tx1 | tr -d ' \n')"
mkdir -p "$FX"
printf '\177ELF\001\002\001\000\000\000\000\000' > "$FX/be32"     # 32-bit big-endian (Admon's mips)
printf '\177ELF\001\001\001\000\000\000\000\000' > "$FX/le32"     # 32-bit little-endian (mipsle, arm)
printf '\177ELF\002\001\001\000\000\000\000\000' > "$FX/le64"     # 64-bit little-endian (arm64, amd64)
printf '\177ELF\002\002\001\000\000\000\000\000' > "$FX/be64"     # 64-bit big-endian
printf '<html>\n<body>Not Found</body>\n' > "$FX/html"          # an error page saved as the binary
printf '\177ELF\001' > "$FX/trunc"                              # a header cut short at byte 5
: > "$FX/empty"
is "0 be32 fixture: ELF, class 1, data 2" "7f454c460102" "$(hx "$FX/be32")"
is "0 le32 fixture: ELF, class 1, data 1" "7f454c460101" "$(hx "$FX/le32")"
is "0 le64 fixture: ELF, class 2, data 1" "7f454c460201" "$(hx "$FX/le64")"
is "0 be64 fixture: ELF, class 2, data 2" "7f454c460202" "$(hx "$FX/be64")"
is "0 html fixture: not ELF" "3c68746d6c3e" "$(hx "$FX/html")"
is "0 trunc fixture: five bytes" "7f454c4601|5" "$(hx "$FX/trunc")|$(wc -c < "$FX/trunc" | tr -d ' ')"
is "0 empty fixture: no bytes" "|0" "$(hx "$FX/empty")|$(wc -c < "$FX/empty" | tr -d ' ')"
# The comparison the updater makes: six bytes read with dd against a printf string. Both directions,
# with this shell's dd and with BusyBox's applet (the router's dd).
LE=$(printf '\177ELF\001\001')
for d in "dd" "busybox dd"; do
    r=""
    for f in le32 be32 le64 html empty; do
        if [ "$($d if="$FX/$f" bs=1 count=6 2>/dev/null)" = "$LE" ]; then r="$r $f=eq"; else r="$r $f=ne"; fi
    done
    is "0 [$d] six bytes compared with the little-endian 32-bit header: only le32 is equal" \
        " le32=eq be32=ne le64=ne html=ne empty=ne" "$r"
done
FAKE_M=mips
is "0 uname fake: -m prints FAKE_M (mips)" "mips" "$(uname -m)"
FAKE_M=aarch64
is "0 ... and follows it (aarch64)" "aarch64" "$(uname -m)"
is "0 ... any other option runs the real uname" "$(command uname -s)" "$(uname -s)"
sleep 3; logger -t ts-fix "lint line"; "$T/init" stop
is "0 sleep and the service fake record, in order" "$(lines 'sleep 3' 'init stop')" "$(cat "$T/calls")"
is "0 logger records its arguments" "-t ts-fix lint line" "$(cat "$T/log")"
fakes=""
for f in uname sleep logger; do
    case "$(type "$f" 2>&1)" in *function*) fakes="$fakes $f" ;; esac
done
is "0 uname, sleep and logger resolve to their fake functions in this shell" " uname sleep logger" "$fakes"
is "0 ... and in the busybox ash driver's shell, before the updater is loaded" " uname sleep logger|mips" \
    "$(T="$T" FAKE_M=mips busybox ash -c '. "$T/fakes.sh"; for f in uname sleep logger; do
        case "$(type "$f" 2>&1)" in *function*) printf " %s" "$f" ;; esac; done; printf "|%s" "$(uname -m)"' 2>&1)"
fake_ts "$T/ft" "1.92.5" "$COMMIT"
is "0 fake_ts prints its lines; the version read takes the first word of line 1" "1.92.5|1.92.5" \
    "$("$T/ft" version | head -n 1)|$(first_ver "$T/ft")"
fake_silent "$T/fs"
"$T/fs" version > "$T/out" 2> "$T/err"; rc=$?
is "0 fake_silent: nothing on stdout, a line on stderr, rc 126, an empty version read" "|Exec format error|126|" \
    "$(content "$T/out")|$(content "$T/err")|$rc|$(first_ver "$T/fs")"
# The order checker, both directions (the same one as tests/unit/test-keep-binary.sh).
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
# The od checker, both directions: od run as a command is found; od in a comment, and words that only
# contain the letters (download), are not.
uses_od() { grep -v -e '^[[:space:]]*#' "$1" | grep -c -w -e 'od'; }
printf '%s\n' '# od is not used here' 'h=$(od -An -tx1 -N6 "$f")' > "$T/od-pos"
printf '%s\n' '# od is not used here' 'echo "Downloading, then dd" >&2' 'set_status "download"' > "$T/od-neg"
is "0 uses_od: an od command is counted, its comment is not" "1" "$(uses_od "$T/od-pos")"
is "0 uses_od: comments and words containing the letters are not counted" "0" "$(uses_od "$T/od-neg")"

# -------------------------------------------------------------------------------- static checks
echo "--- static: the updater's library guard and the REF_ELF default"
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
    unset REF_ELF
    TS_FIX_UPDATE_LIB=1
    . "$UPD"
    printf '%s' "$REF_ELF"
)
is "S2 unset, REF_ELF defaults to /bin/busybox" "/bin/busybox" "$got"

# in_upd <commands> <functions> — in a subshell of this shell, load.sh: the updater as a library
in_upd() { ( set -- "$1" "$2"; . "$T/load.sh" ); }
# in_upd_ash <commands> <functions> — the same, as a busybox ash process (the fakes sourced first)
in_upd_ash() {
    T="$T" UPD="$UPD" TSB="$TSB" TSD="$TSD" KB="$KB" REF="$REF" FAKE_M="$FAKE_M" guard_ok="$guard_ok" \
        busybox ash -c '. "$T/fakes.sh"; . "$T/load.sh"' in_upd_ash "$1" "$2"
}

# --------------------------------------------------------------------------------------- case B
echo "--- case B: detect_arch, uname faked; on mips the byte order comes from REF_ELF"
arch_case() {   # arch_case <driver> <label> <uname -m> <reference> <want>
    fresh
    FAKE_M=$3; REF=$4
    $1 'detect_arch > "$T/out" 2> "$T/err"' detect_arch
    is "B [$1] $2" "$5||" "$(content "$T/out")|$(content "$T/err")|$(content "$T/notes")"
}
for drv in in_upd in_upd_ash; do
    arch_case "$drv" "aarch64 -> arm64" aarch64 "$FX/le64" arm64
    arch_case "$drv" "aarch64 -> arm64 whatever REF_ELF is (missing here)" aarch64 "$FX/missing" arm64
    arch_case "$drv" "armv7l -> arm" armv7l "$FX/le32" arm
    arch_case "$drv" "x86_64 -> amd64" x86_64 "$FX/le64" amd64
    arch_case "$drv" "mips, little-endian REF_ELF -> mipsle" mips "$FX/le32" mipsle
    arch_case "$drv" "mips, big-endian REF_ELF -> mips" mips "$FX/be32" mips
    arch_case "$drv" "mips, REF_ELF missing -> \"\"" mips "$FX/missing" ""
    arch_case "$drv" "mips, REF_ELF not ELF -> \"\"" mips "$FX/html" ""
    arch_case "$drv" "mips, REF_ELF empty -> \"\"" mips "$FX/empty" ""
    arch_case "$drv" "mips64 -> \"\" (no mips64 asset is chosen)" mips64 "$FX/be64" ""
    arch_case "$drv" "an unknown machine (sparc) -> \"\"" sparc "$FX/le32" ""
done

# --------------------------------------------------------------------------------------- case C
echo "--- case C: check_download keeps a download with REF_ELF's byte order and refuses the rest"
guard_case() {  # guard_case <driver> <label> <reference> <download fixture | missing> <pass|fail>
    fresh
    REF=$3
    fake_ts "$TSD" "1.92.5" "$COMMIT"; ln -sf tailscaled "$TSB"; keep_old
    cp "$TSD" "$T/tsd.expect"
    [ "$4" = "missing" ] || { cp "$FX/$4" "$T/dl"; cp "$FX/$4" "$T/dl.expect"; }
    $1 '( set -e; check_download "$T/dl"; echo passed ) > "$T/out" 2> "$T/err"; printf "%s\n" "$?" > "$T/rc"' \
        check_download
    if [ "$5" = "pass" ]; then
        if cmp -s "$T/dl" "$T/dl.expect"; then dl="kept"; else dl="changed or gone"; fi
        is "C [$1] $2: passes (rc 0, carries on), the download kept, no status" "0|passed||kept|<absent>" \
            "$(content "$T/rc")|$(content "$T/out")|$(content "$T/err")|$dl|$(content "$T/status")"
    else
        is "C [$1] $2: refused (rc 1, stops), the download deleted, an error status" \
            "1|||<absent>|$ST_GUARD" \
            "$(content "$T/rc")|$(content "$T/out")|$(content "$T/err")|$(content "$T/dl")|$(content "$T/status")"
    fi
    if cmp -s "$TSD" "$T/tsd.expect"; then tsd="untouched"; else tsd="changed"; fi
    is "C [$1] ... nothing installed changed: the binary, its link, its keep list, no service call" \
        "untouched|tailscaled|$(lines "# an older list" /usr/sbin/tailscaled)|" \
        "$tsd|$(readlink "$TSB" 2>&1)|$(content "$KB")|$(cat "$T/calls")"
    is "C [$1] ... nothing missing" "" "$(content "$T/notes")"
}
for drv in in_upd in_upd_ash; do
    guard_case "$drv" "LE ref, LE download" "$FX/le32" le32 pass
    guard_case "$drv" "BE ref, BE download (a big-endian MIPS router)" "$FX/be32" be32 pass
    guard_case "$drv" "LE 32-bit ref, LE 64-bit download (class is not compared)" "$FX/le32" le64 pass
    guard_case "$drv" "LE ref, BE download (the MG1300 case)" "$FX/le32" be32 fail
    guard_case "$drv" "BE ref, LE download" "$FX/be32" le32 fail
    guard_case "$drv" "LE ref, an HTML error page" "$FX/le32" html fail
    guard_case "$drv" "LE ref, an empty download" "$FX/le32" empty fail
    guard_case "$drv" "LE ref, a header cut short" "$FX/le32" trunc fail
    guard_case "$drv" "LE ref, no download at all" "$FX/le32" missing fail
    guard_case "$drv" "ref missing, LE download" "$FX/missing" le32 fail
    guard_case "$drv" "ref not ELF, LE download" "$FX/html" le32 fail
done

# --------------------------------------------------------------------------------------- case D
echo "--- case D: a new binary that prints no version is rolled back to the factory one"
rb_setup() {    # an installed binary that prints nothing, kept; the firmware's 1.92.5 in the fake /rom
    fresh
    REF="$FX/le32"
    fake_silent "$TSD"; ln -sf tailscaled "$TSB"; keep_old
    cp "$TSD" "$T/tsd.expect"
    fake_ts "$ROMSB/tailscaled" "1.92.5" "$COMMIT"
    ln -sf tailscaled "$ROMSB/tailscale"
    # restore_factory drops the lines naming its own binary paths, which here are the test's
    printf '%s\n' "/etc/something" "$TSD" "$TSB" > "$T/sysupgrade.conf"
}
RB='( set -e; rollback_install "'"$NEWV"'"; echo continued ) > "$T/out" 2> "$T/err"; printf "%s\n" "$?" > "$T/rc"'
for drv in in_upd in_upd_ash; do
    rb_setup
    is "D [$drv] the installed binary gives no version, read as do_install reads it" "" "$(first_ver "$TSB")"
    $drv "$RB" "rollback_install restore_factory"
    is "D [$drv] rc 1 (stops), nothing on stdout or stderr" "1||" \
        "$(content "$T/rc")|$(content "$T/out")|$(content "$T/err")"
    if cmp -s "$ROMSB/tailscaled" "$TSD"; then ok "D [$drv] tailscaled is the factory copy"
    else nok "D [$drv] tailscaled is the factory copy" "same as $ROMSB/tailscaled" "$(head -n 3 "$TSD" 2>&1)"; fi
    is "D [$drv] tailscale is the factory symlink, and answers with the factory version" "tailscaled|1.92.5" \
        "$(readlink "$TSB" 2>&1)|$(first_ver "$TSB")"
    is "D [$drv] the keep list is removed" "<absent>" "$(content "$KB")"
    is "D [$drv] the service stopped, then started (sleeps stubbed)" \
        "$(lines 'init stop' 'sleep 1' 'init start' 'sleep 3')" "$(cat "$T/calls")"
    is "D [$drv] status: an error naming the version and the restore" "$ST_RB" "$(content "$T/status")"
    is "D [$drv] stale sysupgrade.conf entries cleaned; nothing logged; nothing missing" "/etc/something||" \
        "$(cat "$T/sysupgrade.conf")|$(cat "$T/log")|$(content "$T/notes")"

    rb_setup
    rm -f "$ROMSB/tailscaled"
    $drv "$RB" "rollback_install restore_factory"
    is "D [$drv] no factory binary: rc 1, an error status naming the missing factory binary" "1||$ST_NOROM" \
        "$(content "$T/rc")|$(content "$T/out")|$(content "$T/status")"
    if cmp -s "$TSD" "$T/tsd.expect"; then tsd="untouched"; else tsd="changed"; fi
    is "D [$drv] ... the installed binary, its link and its list left alone, the service untouched" \
        "untouched|tailscaled|$(lines "# an older list" /usr/sbin/tailscaled)|" \
        "$tsd|$(readlink "$TSB" 2>&1)|$(content "$KB")|$(cat "$T/calls")"

    rb_setup
    rm -f "$ROMSB/tailscale"
    $drv "$RB" "rollback_install restore_factory"
    is "D [$drv] the factory link missing, so one copy fails: rc 1, an error status saying so" "1||$ST_RBFAIL" \
        "$(content "$T/rc")|$(content "$T/out")|$(content "$T/status")"
    is "D [$drv] ... the restore still ran to the end: stopped, then started" \
        "$(lines 'init stop' 'sleep 1' 'init start' 'sleep 3')" "$(cat "$T/calls")"
    if cmp -s "$ROMSB/tailscaled" "$TSD"; then tsd="factory"; else tsd="not factory"; fi
    is "D [$drv] ... tailscaled is the factory copy, the keep list removed" "factory|<absent>" \
        "$tsd|$(content "$KB")"
done

echo "--- case D (restore): do_restore's plain call keeps aborting at a failed copy, as before"
# do_restore calls restore_factory without ||, so set -e still stops it at a failed copy and the
# exit trap reports the interruption: the behaviour of the code it replaced. busybox ash only.
rb_setup
rm -f "$ROMSB/tailscale"
in_upd_ash '( set -e; do_restore; echo continued ) > "$T/out" 2> "$T/err"; printf "%s\n" "$?" > "$T/rc"' do_restore
is "D do_restore, the factory link missing: rc 1, stopped at the copy, the interruption reported, lock gone" \
    "1||$(lines 'init stop' 'sleep 1')|{\"status\":\"error\",\"message\":\"Interrupted unexpectedly - check network and retry\"}|<absent>" \
    "$(content "$T/rc")|$(content "$T/out")|$(cat "$T/calls")|$(content "$T/status")|$(content "$T/lock")"

# --------------------------------------------------------------------------------------- case E
echo "--- case E: where do_install and do_restore call the new steps"
is "E do_install: size check, the download check, stop, install, start, version read, rollback, success" \
    "in order" \
    "$(in_order "$UPD" do_install '    if [ "$size" -lt 1000000 ]; then' '    check_download "$tmpfile"' \
        '    "$TS_INIT" stop 2>/dev/null || true' '    install_binary "$tmpfile"' \
        '    "$TS_INIT" start 2>/dev/null || true' \
        "    new_ver=\$(\$TS_BIN version 2>/dev/null | head -1 | awk '{print \$1}') || true" \
        '    [ -n "$new_ver" ] || rollback_install "$latest_ver"' \
        '    set_status "success" "Updated to ${new_ver}"')"
is "E ... the \${new_ver:-\$ver_raw} fallback is gone from the file" "0" "$(grep -c -F -e 'new_ver:-' "$UPD")"
is "E restore_factory: stop, copy both binaries, drop the keep list, start" "in order" \
    "$(in_order "$UPD" restore_factory '    "$TS_INIT" stop 2>/dev/null || true' \
        '    cp -a "${ROM_PREFIX}${TS_BIN}" "$TS_BIN"' '    cp -a "${ROM_PREFIX}${TS_DAEMON}" "$TS_DAEMON"' \
        '    keep_remove || true' '    "$TS_INIT" start 2>/dev/null || true')"
is "E ... and the copy is nowhere else in the file (two cp -a lines in all)" "2" \
    "$(grep -c -F -e 'cp -a "${ROM_PREFIX}' "$UPD")"
is "E do_restore: its factory check, then restore_factory, then its success status" "in order" \
    "$(in_order "$UPD" do_restore '    if [ ! -f "${ROM_PREFIX}${TS_DAEMON}" ]; then' '    restore_factory' \
        '    set_status "success" "Restored to factory version (${ver:-unknown})"')"
is "E rollback_install: its factory check, then restore_factory under ||, then exit 1" "in order" \
    "$(in_order "$UPD" rollback_install '    if [ ! -f "${ROM_PREFIX}${TS_DAEMON}" ]; then' \
        '    restore_factory || true' '    exit 1')"
is "E no od in the updater's code (the GL routers checked have no od)" "0" "$(uses_od "$UPD")"

finish
