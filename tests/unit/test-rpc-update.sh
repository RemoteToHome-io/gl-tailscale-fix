#!/bin/sh
# Unit test for the Version Manager's side of the RPC module, src/rpc/ts-fix (GitHub issue #21).
# GL's ngx.pipe runs each spawn through gl-ngx-session's command proxy, which SIGKILLs a command
# still running about 20 s after it starts, so updater runs started directly were killed mid-way,
# leaving the lock and a "running" status behind; and every page poll without a version cache
# started another check. Now:
#   - every start of /usr/bin/ts-fix-update goes through spawn_update: one of four literal flags,
#     detached through sh -c '... &'; any other flag is refused and logged;
#   - do_update and do_restore refuse only while a live ts-fix-update holds the lock (its PID in the
#     lock file, /proc/<pid>/cmdline naming the updater), and write a fresh "Starting..." status;
#   - get_update_status reports a "running" status with no live holder as interrupted once it is
#     more than 20 s old, or dated in the future (the clock set back);
#   - get_update_info holds off a new check for 10 minutes after a failed one (the marker the
#     updater leaves), reporting "unavailable", unless the marker is dated in the future;
#   - force_check_versions removes that marker before it starts a check.
# Laptop only, no router and no network involved:
#   sh tests/unit/test-rpc-update.sh [root]       (also runs under: busybox ash)
# root defaults to the repo. Another tree with src/rpc/ts-fix at the same relative path can be given
# instead, e.g. one holding 0f2c4cc's module (git show 0f2c4cc:src/rpc/ts-fix), which must fail.
#
# The cases are Lua, in tests/unit/test-rpc-update.lua beside this file. This script picks the
# first of lua5.1, luajit, lua and texlua on PATH (the router runs LuaJIT; texlua, from TeX Live, is
# Lua 5.3) and, when there is none, prints a counted skip and exits 0. It copies the module into a
# temp root with every "/tmp/ and "/rom/ string literal pointed into that root, so nothing the cases
# write touches this machine's /tmp, and starts a stand-in updater: a /bin/sh process whose command
# line names a script called ts-fix-update, for the lock-holder cases. /proc is the real one.
#
# Checked here before the Lua cases run (the Lua file lints its own stubs and the clock offsets):
#   the copy: as many literals rewritten as the module has, and none left;
#   the stand-in: alive, and its /proc/<pid>/cmdline names ts-fix-update.

R=${1:-"$(dirname "$0")/../.."}
RPC="$R/src/rpc/ts-fix"
LUA_CASES="$(cd "$(dirname "$0")" && pwd)/test-rpc-update.lua"
for f in "$RPC" "$LUA_CASES"; do
    [ -r "$f" ] || { echo "FAIL: cannot read $f"; exit 1; }
done

fails=0; oks=0
ok()  { oks=$((oks + 1)); printf 'ok   %s\n' "$1"; }
nok() { fails=$((fails + 1)); printf 'FAIL %s\n       want: [%s]\n       got:  [%s]\n' "$1" "$2" "$3"; }
is()  { if [ "$2" = "$3" ]; then ok "$1"; else nok "$1" "$2" "$3"; fi; }

LUA=""
for c in lua5.1 luajit lua texlua; do
    if command -v "$c" >/dev/null 2>&1; then LUA=$c; break; fi
done
if [ -z "$LUA" ]; then
    printf 'skip %s\n       why:  %s\n' "the RPC update cases" "no lua5.1, luajit, lua or texlua on PATH"
    echo
    echo "ALL PASS (0 ok, 1 skipped)"
    exit 0
fi

T=$(mktemp -d "${TMPDIR:-/tmp}/ts-fix-rpc.XXXXXX") || { echo "FAIL: mktemp"; exit 1; }
STANDIN=""
trap '[ -z "$STANDIN" ] || { kill "$STANDIN" 2>/dev/null; wait "$STANDIN" 2>/dev/null; }; rm -rf "$T"' EXIT

# $T goes into a sed replacement and a generated script, so it must hold nothing special to either.
case "$T" in
    *[!A-Za-z0-9._/-]*) nok "the temp dir is safe in sed replacements and scripts" "[A-Za-z0-9._/-] only" "$T"
                         echo; echo "$fails FAILED ($oks ok, 0 skipped)"; exit 1 ;;
esac

echo "--- case 0: the interpreter, the module copy, the stand-in updater"
echo "     (Lua interpreter: $LUA, $(command -v "$LUA"))"
mkdir -p "$T/root/tmp" "$T/root/rom/usr/sbin" "$T/root/bin"
sed -e "s|\"/tmp/|\"$T/root/tmp/|g" -e "s|\"/rom/|\"$T/root/rom/|g" "$RPC" > "$T/ts-fix.lua"
# $T itself starts with /tmp/, so the rewritten literals are set aside before looking for any left.
n_src=$(grep -o -e '"/tmp/' -e '"/rom/' "$RPC" | wc -l | tr -d ' ')
n_new=$(grep -o -F -e "\"$T/root/" "$T/ts-fix.lua" | wc -l | tr -d ' ')
left=$(sed -e "s|\"$T/root/|\"@ROOT@/|g" "$T/ts-fix.lua" | grep -n -e '"/tmp/' -e '"/rom/')
if [ "$n_src" -gt 0 ] && [ "$n_src" = "$n_new" ] && [ -z "$left" ]; then
    ok "0 the copy: all $n_src \"/tmp/ and \"/rom/ literals point into the temp root, none left"
else
    nok "0 the copy: every \"/tmp/ and \"/rom/ literal points into the temp root" \
        "$n_src rewritten, none left" "$n_new rewritten, left: $left"
fi

printf '%s\n' '#!/bin/sh' 'sleep 60' > "$T/root/bin/ts-fix-update"
/bin/sh "$T/root/bin/ts-fix-update" &
STANDIN=$!
# Until it has exec'd, the child's command line is still this shell's: wait for it, at most 2 s.
_n=0
while [ "$_n" -lt 20 ]; do
    case "$(tr '\0' ' ' < "/proc/$STANDIN/cmdline" 2>/dev/null)" in *ts-fix-update*) break ;; esac
    sleep 0.1; _n=$((_n + 1))
done
case "$(tr '\0' ' ' < "/proc/$STANDIN/cmdline" 2>/dev/null)" in
    *ts-fix-update*) ok "0 the stand-in updater is alive and its command line names ts-fix-update (pid $STANDIN)" ;;
    *) nok "0 the stand-in updater's command line names ts-fix-update" "*ts-fix-update*" \
           "$(tr '\0' ' ' < "/proc/$STANDIN/cmdline" 2>&1)" ;;
esac

"$LUA" "$LUA_CASES" "$T/root" "$T/ts-fix.lua" "$STANDIN" "$oks" "$fails"
