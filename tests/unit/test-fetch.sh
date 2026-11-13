#!/bin/sh
# Unit test for the Version Manager's downloads and version checks in src/scripts/ts-fix-update,
# and for download_file in install-gl-tailscale-fix.sh (GitHub issue #21). GL's wget is
# uclient-fetch, which cannot read a response header line longer than its 4 KB read buffer and
# waits for its timeout instead; GitHub's release-download redirects carry a 4,175-byte one
# (counting its line ending), so every wget of a release URL hung until its timeout (measured on a
# GL-AXT1800 4.8.4, 2026-11-12).
# Separately, the RPC's spawns were killed mid-run, leaving the lock and a "running" status behind,
# and every page poll without a cache started another check. Now:
#   - fetch <url> <dest> <seconds> runs curl whenever it is installed (-fsSL, --connect-timeout 15,
#     --max-time <seconds> - 5) and wget (-T 30) only when it is not, never one after the other;
#   - do_check and do_check_plugin run one at a time (CHECK_LOCK, PLUGIN_CHECK_LOCK): a second one
#     returns 0 at once without downloading;
#   - do_check records a failed check in CHECK_FAIL, clears it on success, and leaves the cache
#     alone on a failure;
#   - do_install and do_restore open LOCK for append and write their PID into it once they hold
#     it, before any status, so a run that finds the lock taken leaves the holder's PID alone;
#   - the installer's download_file prefers curl too.
# Laptop only, no router and no network involved:
#   sh tests/unit/test-fetch.sh [root]       (also runs under: busybox ash)
# root defaults to the repo. Another tree with src/scripts/ts-fix-update and
# install-gl-tailscale-fix.sh at the same relative paths can be given instead, e.g. one holding
# 0f2c4cc's two files (git show 0f2c4cc:<path>), which must fail.
#
# The updater is SOURCED with TS_FIX_UPDATE_LIB=1, as in tests/unit/test-keep-binary.sh: CURL_BIN,
# WGET_BIN and the binary, service and ROM paths point into a temp dir through the overrides it
# reads at load; LOCK, STATUS, CACHE, PLUGIN_CACHE, CHECK_LOCK, PLUGIN_CHECK_LOCK, CHECK_FAIL,
# SYSUPGRADE_CONF and TINY_URL by assignment after sourcing. Every URL is on 127.0.0.1 port 9
# except the plugin check's, which the updater fixes; only the fakes are ever handed one, and a case
# whose functions are missing (the pre-change updater has no fetch) is not run at all. Cases F1 and
# F2 run twice: in a subshell of the shell running this suite, and as a busybox ash process (the
# router's shell). F3 to F6 open fd 201 or 202, and the F7 process legs fd 200: a multi-digit fd
# redirection, which dash reads as a command named 201. They run as a busybox ash process always,
# and in this shell only when it accepts one (skipped, and counted, under dash). The F7 second-run
# leg runs a holder and a second do_restore as two busybox ash processes, whatever this shell is.
#
# The fakes and checkers, linted in case 0 before any case relies on them:
#   curl, wget executables in $T/bin recording their arguments, one call per line joined by |, in
#              $T/argv.curl and $T/argv.wget; they print $T/body, when it exists, to stdout or to
#              the file named by -o (curl) or -qO (wget) unless that is -, and exit with the status
#              in $T/rc.curl or $T/rc.wget (0 when absent);
#   timeout    a shell function recording its bound in $T/timeouts and running the command under a
#              real 10 s bound;
#   the holder a separate /bin/sh process holding a lock file with flock until told to let go
#              (lock_free, which waits out the second BusyBox's timeout keeps a check lock after a
#              run, is plain flock -w and needs no lint of its own);
#   the fd probe, in_order, wget_outside and the download_file extraction, and the shadow that
#              makes a shell running its own wget applet ahead of PATH (BusyBox ash on this laptop;
#              on the router wget is uclient-fetch, a file on PATH) reach the wget fake in case F8.
# The timeout function is written once to $T/fakes.sh and sourced both here and by the busybox ash
# driver, so the definition case 0 lints is the one every case uses.

R=${1:-"$(dirname "$0")/../.."}
UPD="$R/src/scripts/ts-fix-update"
INST="$R/install-gl-tailscale-fix.sh"
for f in "$UPD" "$INST"; do
    [ -r "$f" ] || { echo "FAIL: cannot read $f"; exit 1; }
done

# Absolute, so `.` never searches PATH for it and the busybox ash driver finds it from anywhere.
UPD="$(cd "$(dirname "$UPD")" && pwd)/$(basename "$UPD")"

T=$(mktemp -d "${TMPDIR:-/tmp}/ts-fix-fetch.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }

# The holder: a separate process holding <lock file> with flock until hold_stop, at most 30 s.
HOLDER=""
hold_start() {  # hold_start <lock file>: rc 0 once the lock is held
    rm -f "$T/held" "$T/release"
    /bin/sh -c 'exec 9>"$1"; flock 9 || exit 1; : > "$2"
        i=0; while [ ! -e "$3" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done' \
        holder "$1" "$T/held" "$T/release" &
    HOLDER=$!
    _hs=0
    while [ ! -e "$T/held" ] && [ "$_hs" -lt 50 ]; do sleep 0.1; _hs=$((_hs + 1)); done
    [ -e "$T/held" ]
}
hold_stop() {
    [ -n "$HOLDER" ] || return 0
    : > "$T/release"
    wait "$HOLDER" 2>/dev/null
    HOLDER=""
}
trap 'hold_stop; rm -rf "$T"' EXIT

fails=0; oks=0; skips=0
ok()   { oks=$((oks + 1)); printf 'ok   %s\n' "$1"; }
nok()  { fails=$((fails + 1)); printf 'FAIL %s\n       want: [%s]\n       got:  [%s]\n' "$1" "$2" "$3"; }
is()   { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "$2" "$3"; fi; }
skip() { skips=$((skips + 1)); printf 'skip %s\n       why:  %s\n' "$1" "$2"; }
lines() { [ "$#" -eq 0 ] || printf '%s\n' "$@"; }
finish() {
    echo
    [ "$fails" -eq 0 ] && { echo "ALL PASS ($oks ok, $skips skipped)"; exit 0; }
    echo "$fails FAILED ($oks ok, $skips skipped)"; exit 1
}

# $T goes into sed replacements and generated scripts, so it must hold nothing special to either.
case "$T" in
    *[!A-Za-z0-9._/-]*) nok "the temp dir is safe in sed replacements and scripts" "[A-Za-z0-9._/-] only" "$T"; finish ;;
esac

U="http://127.0.0.1:9/ts-fix-fetch-test"
PLUGIN_URL="https://api.github.com/repos/RemoteToHome-io/gl-tailscale-fix/releases/latest"
CB="$T/bin/curl"
WB="$T/bin/wget"
# What the cases hand the updater as CURL_BIN (F2 the absent one), and fetch's arguments in F1, F2
USE_CURL="$CB"; FURL=""; FDEST=""; FSECS=""

# ------------------------------------------------------------------------------------- the fakes
mkdir -p "$T/bin"
cat > "$T/fake.tmpl" <<'EOF'
#!/bin/sh
# A fake downloader: records its arguments, prints the body, exits with the configured status
PATH=/usr/bin:/bin
for a in "$@"; do printf '%s|' "$a"; done >> '@T@/argv.@N@'
echo >> '@T@/argv.@N@'
dest=-
while [ $# -gt 0 ]; do
    if [ "$1" = '@O@' ] && [ $# -ge 2 ]; then dest=$2; shift; fi
    shift
done
if [ -f '@T@/body' ]; then
    if [ "$dest" = - ]; then cat '@T@/body'; else cat '@T@/body' > "$dest"; fi
fi
rc=$(cat '@T@/rc.@N@' 2>/dev/null)
exit "${rc:-0}"
EOF
for nf in curl:-o wget:-qO; do
    sed -e "s|@T@|$T|g" -e "s|@N@|${nf%%:*}|g" -e "s|@O@|${nf#*:}|g" "$T/fake.tmpl" > "$T/bin/${nf%%:*}"
    chmod 755 "$T/bin/${nf%%:*}"
done

cat > "$T/fakes.sh" <<'EOF'
timeout() { printf '%s\n' "$1" >> "$T/timeouts"; shift; command timeout 10 "$@"; }
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
CURL_BIN="$USE_CURL"; WGET_BIN="$WB"
TS_BIN="$T/usr/sbin/tailscale"; TS_DAEMON="$T/usr/sbin/tailscaled"; TS_INIT="$T/init"
ROM_PREFIX="$T/rom"; KEEP_BIN="$T/keep"; REF_ELF="$T/ref"
. "$UPD"
set +e
LOCK="$T/lock"; STATUS="$T/status"; CACHE="$T/cache"; PLUGIN_CACHE="$T/plugin-cache"
CHECK_LOCK="$T/check.lock"; PLUGIN_CHECK_LOCK="$T/check-plugin.lock"; CHECK_FAIL="$T/check.failed"
SYSUPGRADE_CONF="$T/sysupgrade.conf"
TINY_URL="$U/tiny"
for _fn in $2; do
    command -v "$_fn" >/dev/null 2>&1 || { printf 'MISSING: %s\n' "$_fn" >> "$T/notes"; exit 1; }
done
eval "$1"
EOF

fresh() {   # empty recordings; no body, every fake exiting 0
    for f in argv.curl argv.wget timeouts notes; do : > "$T/$f"; done
    for f in body rc.curl rc.wget out err rc dl cache plugin-cache check.failed lock status \
             lock-seen pid f8-dst f8-shadow; do
        rm -f "$T/$f"
    done
}
content() { if [ -e "$1" ] || [ -L "$1" ]; then cat "$1"; else printf '<absent>'; fi; }
oneline() { tr '\n' ' ' < "$1" | sed 's/ $//'; }

# --------------------------------------------------------------------------------------- case 0
echo "--- case 0: the fakes, the drivers, and the checkers the cases rely on"
command -v busybox >/dev/null 2>&1 || nok "busybox present (the ash driver)" "busybox" "not found"
command -v dash >/dev/null 2>&1 || nok "dash present (the fd probe lint)" "dash" "not found"
command -v flock >/dev/null 2>&1 || nok "flock present (the holder, and the updater's locks)" "flock" "not found"

fresh
printf 'line one\r\nline two\n' > "$T/body"
got=$("$CB" -fsSL --max-time 55 "$U/a"); rc=$?
is "0 curl fake: prints the body to stdout, records its arguments, rc 0" \
    "$(lines "$(printf 'line one\r\nline two')" "-fsSL|--max-time|55|$U/a|" 0)" \
    "$(lines "$got" "$(cat "$T/argv.curl")" "$rc")"
fresh; printf 'bin\n' > "$T/body"
"$CB" -fsSL -o "$T/dl" "$U/b" > "$T/out"; rc=$?
is "0 curl fake: -o <file> writes the body there, nothing to stdout" "bin||0" \
    "$(content "$T/dl")|$(content "$T/out")|$rc"
fresh; printf '22\n' > "$T/rc.curl"
"$CB" -fsSL "$U/c" > "$T/out"; rc=$?
is "0 curl fake: no body, nothing printed, the status from rc.curl" "|22" "$(content "$T/out")|$rc"
fresh; printf 'ver\n' > "$T/body"
got=$("$WB" -T 30 -qO - "$U/d"); rc=$?
is "0 wget fake: -qO - prints the body, records its arguments, rc 0" "ver|-T|30|-qO|-|$U/d||0" \
    "$got|$(cat "$T/argv.wget")|$rc"
"$WB" -T 30 -qO "$T/dl" "$U/e" > "$T/out"; rc=$?
is "0 wget fake: -qO <file> writes the body there, a second call is a second line" \
    "$(lines "ver||0" "-T|30|-qO|-|$U/d|" "-T|30|-qO|$T/dl|$U/e|")" \
    "$(lines "$(content "$T/dl")|$(content "$T/out")|$rc" "$(cat "$T/argv.wget")")"
fresh; printf '4\n' > "$T/rc.wget"
"$WB" -qO - "$U/f" > "$T/out"; rc=$?
is "0 wget fake: no body, the status from rc.wget; curl's record untouched" "|4|" \
    "$(content "$T/out")|$rc|$(cat "$T/argv.curl")"

fresh
got=$(timeout 60 printf '%s|' 'a b' c; timeout 10 sh -c 'exit 7'; printf '%s' "$?")
is "0 the timeout fake records its bound and passes output, arguments and status through" \
    "a b|c|7|60 10" "$got|$(oneline "$T/timeouts")"
fakes=""; case "$(type timeout 2>&1)" in *function*) fakes=" timeout" ;; esac
is "0 timeout resolves to the fake function in this shell" " timeout" "$fakes"
fresh
got=$(T="$T" busybox ash -c '. "$T/fakes.sh"; case "$(type timeout 2>&1)" in *function*) printf " timeout" ;; esac
    timeout 300 sh -c "exit 7"; printf "|%s" "$?"' 2>&1)
is "0 ... and in the busybox ash driver's shell, passing the status through there too" " timeout|7|300" \
    "$got|$(oneline "$T/timeouts")"
is "0 command -v finds the curl fake by its path, and nothing at /nonexistent/curl (this shell)" "$CB|" \
    "$(command -v "$CB")|$(command -v /nonexistent/curl)"
is "0 ... and the same in busybox ash" "$CB|" \
    "$(busybox ash -c 'printf "%s|" "$(command -v "$1")"; command -v /nonexistent/curl' probe "$CB")"

# The multi-digit fd probe, both directions, then this shell's answer.
FDPROBE='( exec 201>"$1" ) 2>/dev/null && echo yes || echo no'
is "0 the multi-digit fd probe: dash cannot open fd 201, busybox ash can" "no|yes" \
    "$(dash -c "$FDPROBE" probe "$T/fdp")|$(busybox ash -c "$FDPROBE" probe "$T/fdp")"
if ( exec 201>"$T/fdp" ) 2>/dev/null; then MULTIFD=yes; else MULTIFD=no; fi
echo "     (this shell opens a multi-digit fd: $MULTIFD)"

# The holder, both directions: the lock refused to another process while held, granted after.
hold_start "$T/lint.lock"; started=$?
flock -n "$T/lint.lock" true; held_rc=$?
hold_stop
flock -n "$T/lint.lock" true; free_rc=$?
is "0 holder: up, the lock refused to another process while held, granted once released" "0|1|0" \
    "$started|$held_rc|$free_rc"

# The order checker, both directions (the same one as tests/unit/test-arch-select.sh).
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
# first_status_after <file> <function> <fixed line>: "after" when the function's first set_status
# line comes after <fixed line>
first_status_after() {
    _fs_body=$(awk -v fn="$2" '$0 == fn "() {" { on = 1 } on { print } on && /^}/ { exit }' "$1")
    _fs_at=$(printf '%s\n' "$_fs_body" | grep -n -x -F -e "$3" | head -n 1 | cut -d: -f1)
    _fs_st=$(printf '%s\n' "$_fs_body" | grep -n -e '^[[:space:]]*set_status ' | head -n 1 | cut -d: -f1)
    if [ -n "$_fs_at" ] && [ -n "$_fs_st" ] && [ "$_fs_at" -lt "$_fs_st" ]; then printf 'after'
    else printf 'line [%s], first set_status [%s]' "$_fs_at" "$_fs_st"; fi
}
printf '%s\n' 'f() {' '    mark' '    set_status a' '}' 'g() {' '    set_status a' '    mark' '}' > "$T/status-fx"
is "0 first_status_after: a status after the line passes" "after" "$(first_status_after "$T/status-fx" f '    mark')"
is "0 first_status_after: a status before it fails" "line [3], first set_status [2]" \
    "$(first_status_after "$T/status-fx" g '    mark')"

# The wget checker, both directions: a wget run with an option outside fetch() is counted; one
# inside fetch(), the WGET_BIN default, a comment, and words containing the letters are not.
wget_outside() {    # wget_outside <file>: lines outside fetch() that run wget with an option
    awk '$0 == "fetch() {" { on = 1 } !on { print } on && /^}/ { on = 0 }' "$1" |
        grep -v -e '^[[:space:]]*#' | grep -c -E -e '(^|[^A-Za-z0-9_$])wget[[:space:]]+-'
}
printf '%s\n' 'WGET_BIN=${WGET_BIN:-wget}' 'fetch() {' '    timeout "$3" wget -T 30 -qO "$2" "$1"' '}' \
    '# wget -T 30 in a comment' 'echo "uses mywget -q"' > "$T/wget-neg"
printf '%s\n' 'fetch() {' '    :' '}' 'x=$(timeout 60 wget -T 30 -qO- "$u")' > "$T/wget-pos"
is "0 wget_outside: a wget run outside fetch() is counted" "1" "$(wget_outside "$T/wget-pos")"
is "0 wget_outside: inside fetch(), the WGET_BIN default, comments and other words are not" "0" \
    "$(wget_outside "$T/wget-neg")"

# The download_file extraction, both directions.
extract_df() { sed -n '/^download_file() {$/,/^}$/p' "$1"; }
printf '%s\n' 'a() {' '    x' '}' 'download_file() {' '    y' '}' 'b() {' '    z' '}' > "$T/df-fx"
is "0 extract_df: only download_file's definition, whole" "$(lines 'download_file() {' '    y' '}')" \
    "$(extract_df "$T/df-fx")"
printf '%s\n' 'a() {' '    x' '}' > "$T/df-none"
is "0 extract_df: nothing from a file without it" "" "$(extract_df "$T/df-none")"

# F8's runner: the installer's download_file with only the fakes in $T/f8bin on PATH. $1: yes when
# the wget fake is there; $2: lint (one wget call) or run.
cat > "$T/f8.sh" <<'EOF'
PATH="$T/f8bin"
if [ "$1" = yes ] && [ "$(command -v wget)" != "$T/f8bin/wget" ]; then
    # This shell runs its own wget applet ahead of PATH (BusyBox ash on this laptop); the router's
    # wget is uclient-fetch, a file on PATH. Resolve it to the fake on PATH, as the router would.
    wget() { "$T/f8bin/wget" "$@"; }
    printf 'shadowed\n' >> "$T/f8-shadow"
fi
if [ "$2" = lint ]; then wget -lint; exit; fi
. "$T/download_file.sh"
download_file "$U/pkg.ipk" "$T/f8-dst"
EOF
f8_setup() {    # f8_setup <curl: yes|no> <wget: yes|no>
    rm -rf "$T/f8bin"; mkdir -p "$T/f8bin"
    [ "$1" = yes ] && cp "$CB" "$T/f8bin/curl"
    [ "$2" = yes ] && cp "$WB" "$T/f8bin/wget"
    return 0
}
f8_sh()  { ( set -- "$1" "$2"; . "$T/f8.sh" ) > "$T/out" 2> "$T/err"; printf '%s\n' "$?" > "$T/rc"; }
f8_ash() { T="$T" U="$U" busybox ash "$T/f8.sh" "$1" "$2" > "$T/out" 2> "$T/err"; printf '%s\n' "$?" > "$T/rc"; }
f8_via() { if [ -s "$T/f8-shadow" ]; then printf 'through the shadow'; else printf 'by PATH'; fi; }
for drv in f8_sh f8_ash; do
    fresh; f8_setup no yes
    $drv yes lint
    is "0 [$drv] F8 runner: a wget call reaches the fake ($(f8_via))" "-lint|||0" \
        "$(cat "$T/argv.wget")|$(cat "$T/argv.curl")|$(content "$T/rc")"
done

# -------------------------------------------------------------------------------- static checks
echo "--- static: the updater's library guard"
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
    unset CURL_BIN WGET_BIN
    TS_FIX_UPDATE_LIB=1
    . "$UPD"
    printf '%s ' "$CURL_BIN" "$WGET_BIN" "$CHECK_LOCK" "$PLUGIN_CHECK_LOCK" "$CHECK_FAIL"
)
is "S2 unset, the downloaders default to curl and wget; the check lock and marker paths" \
    "curl wget /tmp/ts-fix-check.lock /tmp/ts-fix-check-plugin.lock /tmp/ts-fix-latest-version.failed " "$got"

# in_upd <commands> <functions> — in a subshell of this shell, load.sh: the updater as a library
in_upd() { ( set -- "$1" "$2"; . "$T/load.sh" ); }
# in_upd_ash <commands> <functions> — the same, as a busybox ash process (the fakes sourced first)
in_upd_ash() {
    T="$T" U="$U" UPD="$UPD" USE_CURL="$USE_CURL" WB="$WB" guard_ok="$guard_ok" \
        FURL="$FURL" FDEST="$FDEST" FSECS="$FSECS" \
        busybox ash -c '. "$T/fakes.sh"; . "$T/load.sh"' in_upd_ash "$1" "$2"
}
# The drivers for a case that opens a multi-digit fd: busybox ash always, this shell when it can.
fd_drivers() { if [ "$MULTIFD" = yes ]; then echo "in_upd in_upd_ash"; else echo "in_upd_ash"; fi; }
fd_skip() {     # fd_skip <case>: report the leg this shell cannot run
    [ "$MULTIFD" = yes ] || skip "$1 [in_upd]" "this shell reads a multi-digit fd redirection as a command; the busybox ash leg runs it"
}

RUN='fetch "$FURL" "$FDEST" "$FSECS" > "$T/out" 2> "$T/err"; printf "%s\n" "$?" > "$T/rc"'

# -------------------------------------------------------------------------------------- case F1
echo "--- case F1: fetch with curl installed: curl, bounded, and never wget"
for drv in in_upd in_upd_ash; do
    fresh; printf 'body one\nbody two\n' > "$T/body"
    FURL="$U/a"; FDEST=-; FSECS=60; USE_CURL="$CB"
    $drv "$RUN" fetch
    is "F1 [$drv] to stdout: the body, rc 0" "$(lines 'body one' 'body two')|0||" \
        "$(content "$T/out")|$(content "$T/rc")|$(content "$T/err")|$(content "$T/notes")"
    is "F1 [$drv] ... curl -fsSL, connect 15 s, at most 55 s, the URL; bounded at 60 s; wget not run" \
        "-fsSL|--connect-timeout|15|--max-time|55|$U/a||60|" \
        "$(cat "$T/argv.curl")|$(oneline "$T/timeouts")|$(cat "$T/argv.wget")"

    fresh; printf 'binary\n' > "$T/body"
    FURL="$U/b"; FDEST="$T/dl"; FSECS=300; USE_CURL="$CB"
    $drv "$RUN" fetch
    is "F1 [$drv] to a file: the body there, nothing on stdout, rc 0" "binary||0" \
        "$(content "$T/dl")|$(content "$T/out")|$(content "$T/rc")"
    is "F1 [$drv] ... curl with -o <file>, at most 295 s; bounded at 300 s; wget not run" \
        "-fsSL|--connect-timeout|15|--max-time|295|-o|$T/dl|$U/b||300|" \
        "$(cat "$T/argv.curl")|$(oneline "$T/timeouts")|$(cat "$T/argv.wget")"

    fresh; printf '22\n' > "$T/rc.curl"
    FURL="$U/c"; FDEST=-; FSECS=60; USE_CURL="$CB"
    $drv "$RUN" fetch
    is "F1 [$drv] curl fails (22): fetch returns 22, and wget is not tried after it" "22|1|" \
        "$(content "$T/rc")|$(grep -c . "$T/argv.curl")|$(cat "$T/argv.wget")"
done

# -------------------------------------------------------------------------------------- case F2
echo "--- case F2: fetch with no curl: wget, as before"
for drv in in_upd in_upd_ash; do
    fresh; printf 'body\n' > "$T/body"
    FURL="$U/a"; FDEST=-; FSECS=60; USE_CURL=/nonexistent/curl
    $drv "$RUN" fetch
    is "F2 [$drv] to stdout: the body, rc 0" "body|0||" \
        "$(content "$T/out")|$(content "$T/rc")|$(content "$T/err")|$(content "$T/notes")"
    is "F2 [$drv] ... wget -T 30 -qO - and the URL; bounded at 60 s; the curl fake not run" \
        "-T|30|-qO|-|$U/a||60|" "$(cat "$T/argv.wget")|$(oneline "$T/timeouts")|$(cat "$T/argv.curl")"

    fresh; printf 'binary\n' > "$T/body"
    FURL="$U/b"; FDEST="$T/dl"; FSECS=300; USE_CURL=/nonexistent/curl
    $drv "$RUN" fetch
    is "F2 [$drv] to a file: wget -qO <file>, the body there, rc 0, bounded at 300 s" \
        "-T|30|-qO|$T/dl|$U/b||binary|0|300" \
        "$(cat "$T/argv.wget")|$(content "$T/dl")|$(content "$T/rc")|$(oneline "$T/timeouts")"

    fresh; printf '4\n' > "$T/rc.wget"
    FURL="$U/c"; FDEST=-; FSECS=60; USE_CURL=/nonexistent/curl
    $drv "$RUN" fetch
    is "F2 [$drv] wget fails (4): fetch returns 4" "4" "$(content "$T/rc")"
done
USE_CURL="$CB"

CHECK='( set -e; do_check; echo continued ) > "$T/out" 2> "$T/err"; printf "%s\n" "$?" > "$T/rc"'
PCHECK='( set -e; do_check_plugin; echo continued ) > "$T/out" 2> "$T/err"; printf "%s\n" "$?" > "$T/rc"'
# BusyBox's timeout runs the command in its own process and leaves a watcher that keeps the
# command's open fds for up to a second after it ends (measured on this laptop, BusyBox 1.36.1), so
# a check lock taken by a run under it is still held just after that run. A case that needs the lock
# free waits for it first, at most 5 s.
lock_free() {   # lock_free <case> <lock file>
    flock -w 5 "$2" true || nok "$1 the lock is free before the run" "free within 5 s" "still held"
}

# -------------------------------------------------------------------------------------- case F3
echo "--- case F3: do_check, the fetch succeeds: the cache, and no failure marker"
fd_skip F3
for drv in $(fd_drivers); do
    fresh; printf '1.98.8-tiny.by.admon.1320\r\n1.98.5\r\n' > "$T/body"; : > "$T/check.failed"
    lock_free "F3 [$drv]" "$T/check.lock"
    $drv "$CHECK" "fetch do_check"
    is "F3 [$drv] rc 0, carries on, silent" "0|continued||" \
        "$(content "$T/rc")|$(content "$T/out")|$(content "$T/err")|$(content "$T/notes")"
    is "F3 [$drv] the cache: the first line, CR stripped" "1.98.8-tiny.by.admon.1320" "$(content "$T/cache")"
    is "F3 [$drv] the failure marker a previous check left is removed" "<absent>" "$(content "$T/check.failed")"
    is "F3 [$drv] one curl call for version.txt, bounded at 60 s; wget not run" \
        "-fsSL|--connect-timeout|15|--max-time|55|$U/tiny/version.txt||60|" \
        "$(cat "$T/argv.curl")|$(oneline "$T/timeouts")|$(cat "$T/argv.wget")"
done

# -------------------------------------------------------------------------------------- case F4
echo "--- case F4: do_check, the fetch fails: the failure marker, the cache untouched, rc 0"
fd_skip F4
for drv in $(fd_drivers); do
    fresh; printf '22\n' > "$T/rc.curl"
    lock_free "F4 [$drv]" "$T/check.lock"
    $drv "$CHECK" "fetch do_check"
    is "F4 [$drv] no cache before: rc 0 under set -e, carries on" "0|continued||" \
        "$(content "$T/rc")|$(content "$T/out")|$(content "$T/err")|$(content "$T/notes")"
    is "F4 [$drv] ... no cache written, the failure marker present, curl tried once, wget not" \
        "<absent>||1|" "$(content "$T/cache")|$(content "$T/check.failed")|$(grep -c . "$T/argv.curl")|$(cat "$T/argv.wget")"

    fresh; printf '22\n' > "$T/rc.curl"; printf '1.98.5-tiny.by.admon.1293\n' > "$T/cache"
    lock_free "F4 [$drv]" "$T/check.lock"
    $drv "$CHECK" "fetch do_check"
    is "F4 [$drv] a cache before: rc 0, the cache unchanged, the failure marker present" \
        "0|1.98.5-tiny.by.admon.1293|" "$(content "$T/rc")|$(content "$T/cache")|$(content "$T/check.failed")"
done

# -------------------------------------------------------------------------------------- case F5
echo "--- case F5: do_check while another process holds CHECK_LOCK: returns 0 at once, no download"
fd_skip F5
for drv in $(fd_drivers); do
    fresh; printf '1.98.8-tiny.by.admon.1320\n' > "$T/body"
    lock_free "F5 [$drv]" "$T/check.lock"
    hold_start "$T/check.lock"; started=$?
    flock -n "$T/check.lock" true; held_rc=$?
    t0=$(date +%s)
    $drv "$CHECK" "fetch do_check"
    t1=$(date +%s)
    hold_stop
    is "F5 [$drv] the holder holds the lock during the run (lock refused to another process)" "0|1" "$started|$held_rc"
    is "F5 [$drv] rc 0, carries on, silent" "0|continued||" \
        "$(content "$T/rc")|$(content "$T/out")|$(content "$T/err")|$(content "$T/notes")"
    is "F5 [$drv] ... no downloader run, no cache, no failure marker" "|||<absent>|<absent>" \
        "$(cat "$T/argv.curl")|$(cat "$T/argv.wget")|$(cat "$T/timeouts")|$(content "$T/cache")|$(content "$T/check.failed")"
    if [ $((t1 - t0)) -le 2 ]; then ok "F5 [$drv] ... and it did not wait for the lock ($((t1 - t0)) s)"
    else nok "F5 [$drv] ... and it did not wait for the lock" "<= 2 s" "$((t1 - t0)) s"; fi
    # Control, same run: the lock released, the same call downloads.
    lock_free "F5 [$drv]" "$T/check.lock"
    $drv "$CHECK" "fetch do_check"
    is "F5 [$drv] control: the lock released, the same call downloads once and writes the cache" \
        "0|1|1.98.8-tiny.by.admon.1320" "$(content "$T/rc")|$(grep -c . "$T/argv.curl")|$(content "$T/cache")"
done

# -------------------------------------------------------------------------------------- case F6
echo "--- case F6: do_check_plugin while another process holds PLUGIN_CHECK_LOCK"
fd_skip F6
for drv in $(fd_drivers); do
    fresh; printf '22\n' > "$T/rc.curl"
    lock_free "F6 [$drv]" "$T/check-plugin.lock"
    hold_start "$T/check-plugin.lock"; started=$?
    flock -n "$T/check-plugin.lock" true; held_rc=$?
    $drv "$PCHECK" "fetch do_check_plugin"
    is "F6 [$drv] the holder holds the lock during the run" "0|1" "$started|$held_rc"
    is "F6 [$drv] rc 0, carries on, silent; no downloader run, no plugin cache" "0|continued|||||<absent>" \
        "$(content "$T/rc")|$(content "$T/out")|$(content "$T/err")|$(content "$T/notes")|$(cat "$T/argv.curl")|$(cat "$T/argv.wget")|$(content "$T/plugin-cache")"
    # The two checks lock separately: the plugin lock held, the version check still downloads.
    printf '0\n' > "$T/rc.curl"; printf '1.98.8\n' > "$T/body"
    lock_free "F6 [$drv]" "$T/check.lock"
    $drv "$CHECK" "fetch do_check"
    is "F6 [$drv] ... while it is held, do_check still downloads (its own lock)" "0|1.98.8|1" \
        "$(content "$T/rc")|$(content "$T/cache")|$(grep -c . "$T/argv.curl")"
    hold_stop
    # Control, same run: the lock released, the plugin check downloads (a failing fetch here, so
    # the cache is written empty: "checked, nothing available").
    fresh; printf '22\n' > "$T/rc.curl"
    lock_free "F6 [$drv]" "$T/check-plugin.lock"
    $drv "$PCHECK" "fetch do_check_plugin"
    is "F6 [$drv] control: the lock released, the plugin check asks GitHub's API once, bounded at 60 s" \
        "0|-fsSL|--connect-timeout|15|--max-time|55|$PLUGIN_URL||60|" \
        "$(content "$T/rc")|$(cat "$T/argv.curl")|$(oneline "$T/timeouts")|$(content "$T/plugin-cache")"
done

# -------------------------------------------------------------------------------------- case F7
echo "--- case F7: do_install and do_restore open the lock for append, then write their PID once they hold it"
is "F7 do_install: append open, flock, then the PID, then its first status" "in order" \
    "$(in_order "$UPD" do_install '    exec 200>>"$LOCK"' \
        '    flock -n 200 || { echo "Update already running"; exit 1; }' \
        '    echo $$ > "$LOCK"' '    set_status "running" "Detecting architecture..."')"
is "F7 ... no set_status ahead of the PID" "after" "$(first_status_after "$UPD" do_install '    echo $$ > "$LOCK"')"
is "F7 do_restore: append open, flock, then the PID, then its first status" "in order" \
    "$(in_order "$UPD" do_restore '    exec 200>>"$LOCK"' \
        '    flock -n 200 || { echo "Operation already running"; exit 1; }' \
        '    echo $$ > "$LOCK"' '    set_status "running" "Restoring factory binaries..."')"
is "F7 ... no set_status ahead of the PID" "after" "$(first_status_after "$UPD" do_restore '    echo $$ > "$LOCK"')"
is "F7 no truncating open of the lock anywhere (exec 200>\"\$LOCK\")" "0" \
    "$(grep -c -F -e 'exec 200>"$LOCK"' "$UPD")"
is "F7 no wget run with an option anywhere outside fetch()" "0" "$(wget_outside "$UPD")"

echo "--- case F7 (process): the lock holds the updater's own PID while it runs"
# set_status is replaced by a spy that copies the lock file at each status, the moment the RPC
# reads it. Run in the driver's own process ($$), never a subshell, so $$ is the PID written.
# do_install stops at its version check (the curl fake fails); do_restore at its missing factory
# binary ($T/rom is empty); neither touches anything else.
SPY='set_status() { cat "$LOCK" >> "$T/lock-seen" 2>/dev/null; printf "%s\n" "$1" >> "$T/status-seen"; }
printf "%s\n" "$$" > "$T/pid"'
pid_case() {    # pid_case <driver> <function> <functions required>
    fresh; rm -f "$T/status-seen"; printf '22\n' > "$T/rc.curl"
    $1 "$SPY
set -e; $2 > \"\$T/out\" 2> \"\$T/err\"" "$3"
    _pc_rc=$?
    _pc_pid=$(content "$T/pid")
    _pc_bad=$(grep -v -x -F -e "$_pc_pid" "$T/lock-seen" 2>/dev/null | head -n 1)
    is "F7 [$1] $2: stops (rc 1), nothing missing" "1|" "$_pc_rc|$(content "$T/notes")"
    if [ -s "$T/lock-seen" ] && [ -z "$_pc_bad" ] && [ "$(grep -c . "$T/lock-seen")" = "$(grep -c . "$T/status-seen")" ]; then
        ok "F7 [$1] $2: at each of its $(grep -c . "$T/status-seen") statuses the lock held its PID ($_pc_pid)"
    else
        nok "F7 [$1] $2: at each of its statuses the lock held its PID" "$_pc_pid at every status" \
            "$(oneline "$T/lock-seen" 2>&1) at $(oneline "$T/status-seen" 2>&1)"
    fi
    is "F7 [$1] $2: ... and the lock is removed on exit" "<absent>" "$(content "$T/lock")"
}
fd_skip "F7 (process)"
for drv in $(fd_drivers); do
    pid_case "$drv" do_install "fetch do_install"
    pid_case "$drv" do_restore "do_restore"
done

echo "--- case F7 (second run): a do_restore that finds the lock taken leaves the holder's PID alone"
# The holder is a real do_restore, as a busybox ash process in the background: a fake factory
# binary in $T/rom lets it reach restore_factory, whose "$TS_INIT" stop is a fake that waits for
# $T/holder-go, so the holder sits holding the lock with its PID written. The second do_restore runs
# as another busybox ash process. sleep is a no-op in the holder, so the restore after the release
# is quick; everything it copies or removes is under $T.
fresh
rm -rf "$T/rom" "$T/usr" "$T/holder-in" "$T/holder-go" "$T/holder-pid" "$T/holder-out" "$T/lock.before"
# The factory copies sit at ROM_PREFIX followed by the binary paths, which here are under $T too
ROMSB="$T/rom$T/usr/sbin"
mkdir -p "$ROMSB" "$T/usr/sbin"
printf '%s\n' '#!/bin/sh' 'echo 1.92.5' > "$ROMSB/tailscaled"
chmod 755 "$ROMSB/tailscaled"
ln -s tailscaled "$ROMSB/tailscale"
cat > "$T/init" <<'EOF'
#!/bin/sh
# A fake service script: stop waits, at most 30 s, until the case lets it go
if [ "$1" = stop ]; then
    : > "$(dirname "$0")/holder-in"
    i=0
    while [ ! -e "$(dirname "$0")/holder-go" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
fi
exit 0
EOF
chmod 755 "$T/init"
in_upd_ash 'sleep() { :; }; printf "%s\n" "$$" > "$T/holder-pid"
set -e; do_restore > "$T/holder-out" 2>&1' do_restore &
HOLDER2=$!
_n=0
while [ ! -e "$T/holder-in" ] && [ "$_n" -lt 50 ]; do sleep 0.1; _n=$((_n + 1)); done
holder_pid=$(content "$T/holder-pid")
is "F7 the holder is inside its restore, holding the lock with its PID written" "yes|$holder_pid|1" \
    "$([ -e "$T/holder-in" ] && echo yes || echo no)|$(content "$T/lock")|$(flock -n "$T/lock" true; echo $?)"
cp "$T/lock" "$T/lock.before" 2>/dev/null
cp "$T/status" "$T/status.before" 2>/dev/null
in_upd_ash '( set -e; do_restore ) > "$T/out" 2> "$T/err"; printf "%s\n" "$?" > "$T/rc"' do_restore
is "F7 the second do_restore: rc 1, \"Operation already running\", nothing on stderr" \
    "1|Operation already running||" "$(content "$T/rc")|$(content "$T/out")|$(content "$T/err")|$(content "$T/notes")"
if cmp -s "$T/lock.before" "$T/lock"; then lk="unchanged"; else lk="changed"; fi
if cmp -s "$T/status.before" "$T/status"; then st="unchanged"; else st="changed"; fi
is "F7 ... the lock file byte for byte as the holder wrote it, the holder's status untouched" \
    "unchanged|$holder_pid|unchanged" "$lk|$(content "$T/lock")|$st"
: > "$T/holder-go"
wait "$HOLDER2"
is "F7 the holder, let go, finishes its restore and removes the lock" \
    '|{"status":"success","message":"Restored to factory version (1.92.5)"}|<absent>' \
    "$(content "$T/holder-out")|$(content "$T/status")|$(content "$T/lock")"
rm -rf "$T/rom" "$T/usr" "$T/init"

# -------------------------------------------------------------------------------------- case F8
echo "--- case F8: the installer's download_file prefers curl"
extract_df "$INST" > "$T/download_file.sh"
is "F8 download_file extracted from the installer" "download_file() {|}" \
    "$(head -n 1 "$T/download_file.sh")|$(tail -n 1 "$T/download_file.sh")"
for drv in f8_sh f8_ash; do
    fresh; f8_setup yes yes; printf 'ipk\n' > "$T/body"
    $drv yes run
    is "F8 [$drv] curl and wget both installed: curl, bounded, to the file; wget not run (wget $(f8_via))" \
        "$(lines "curl: -fsSL|--connect-timeout|15|--max-time|120|$U/pkg.ipk|-o|$T/f8-dst|" "wget: " "rc: 0" "file: ipk")" \
        "$(lines "curl: $(cat "$T/argv.curl")" "wget: $(cat "$T/argv.wget")" "rc: $(content "$T/rc")" "file: $(content "$T/f8-dst")")"
    fresh; f8_setup no yes; printf 'ipk\n' > "$T/body"
    $drv yes run
    is "F8 [$drv] no curl: wget, as before (wget $(f8_via))" \
        "$(lines "curl: " "wget: -q|$U/pkg.ipk|-O|$T/f8-dst|" "rc: 0")" \
        "$(lines "curl: $(cat "$T/argv.curl")" "wget: $(cat "$T/argv.wget")" "rc: $(content "$T/rc")")"
done

finish
