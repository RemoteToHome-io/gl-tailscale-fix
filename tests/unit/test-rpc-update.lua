-- The Lua half of tests/unit/test-rpc-update.sh, which prepares its arguments: run it through
-- that script, not by hand.
--   <lua> test-rpc-update.lua <root> <module copy> <live updater pid> <shell oks> <shell fails>
-- <module copy> is src/rpc/ts-fix with its "/tmp/ and "/rom/ literals pointed into <root>. It is
-- loaded with ngx, uci, cjson and oui.fs replaced by stubs: ngx.pipe.spawn records its argv (and
-- really runs `date -r`, which file_mtime needs), cjson.decode reads only the status file's
-- {"status":"..","message":".."} shape, uci answers nothing, oui.fs.access is io.open. Written for
-- Lua 5.1 (the router runs LuaJIT) and also runs under 5.2+ and texlua.
local ROOT, MOD, LIVE_PID = arg[1], arg[2], arg[3]
local oks, fails = tonumber(arg[4]) or 0, tonumber(arg[5]) or 0

local spawns, logs = {}, {}
local function proc(out)
    return { stdout_read_all = function() return out end, wait = function() return true end }
end
ngx = {
    ERR = "ERR", WARN = "WARN",
    time = function() return os.time() end,
    log = function(lvl, msg) logs[#logs + 1] = lvl .. " " .. msg end,
    pipe = { spawn = function(argv)
        spawns[#spawns + 1] = table.concat(argv, "\1")
        if argv[1] == "date" then
            local p = io.popen("date -r '" .. argv[3] .. "' +%s 2>/dev/null")
            local out = p:read("*a")
            p:close()
            return proc(out)
        end
        return proc("")
    end },
}
package.preload["uci"] = function()
    return { cursor = function() return { get = function() return nil end } end }
end
package.preload["cjson"] = function()
    return { decode = function(s)
        local st, msg = s:match('^%s*{"status":"([^"]*)","message":"([^"]*)"}%s*$')
        if not st then error("not a status object") end
        return { status = st, message = msg }
    end }
end
package.preload["oui.fs"] = function()
    return {
        access = function(p) local f = io.open(p, "r"); if f then f:close(); return true end; return false end,
        sync = function() end,
    }
end

local function is(label, want, got)
    if want == got then
        oks = oks + 1
        print("ok   " .. label)
    else
        fails = fails + 1
        print("FAIL " .. label .. "\n       want: [" .. tostring(want) .. "]\n       got:  [" .. tostring(got) .. "]")
    end
end
local function sh(cmd)  -- os.execute returns 0 on 5.1 and true on 5.2+ when the command succeeds
    local r = os.execute(cmd)
    if r ~= 0 and r ~= true then error("command failed: " .. cmd) end
end
local function write(p, s) local f = assert(io.open(p, "w")); f:write(s); f:close() end
local function read(p)
    local f = io.open(p, "r")
    if not f then return "<absent>" end
    local s = f:read("*a")
    f:close()
    return s
end
local function exists(p) local f = io.open(p, "r"); if f then f:close(); return "present" end; return "<absent>" end
local function touch(p, when) sh("touch -d '" .. when .. "' '" .. p .. "'") end
local function age(p)
    local h = io.popen("date -r '" .. p .. "' +%s")
    local m = tonumber((h:read("*a") or ""):match("^(%d+)"))
    h:close()
    return m and (os.time() - m) or nil
end
local function updater_spawns()
    local out = {}
    for _, s in ipairs(spawns) do
        if s:find("ts-fix-update", 1, true) then out[#out + 1] = (s:gsub("\1", " ")) end
    end
    return table.concat(out, " ; ")
end
local function reset() spawns = {}; logs = {} end
local T = ROOT .. "/tmp/"
local CACHE, FAILED = T .. "ts-fix-latest-version", T .. "ts-fix-latest-version.failed"
local LOCK, STATUS = T .. "ts-fix-update.lock", T .. "ts-fix-update.status"
local PCACHE = T .. "ts-fix-plugin-latest-version"
local function SPAWN(flag) return "sh -c /usr/bin/ts-fix-update " .. flag .. " </dev/null >/dev/null 2>&1 &" end

local ok_load, M = pcall(dofile, MOD)
is("0 the module copy loads under the stubs", "true", tostring(ok_load))
if not ok_load then print(M); M = {} end

-- The clock offsets the cases rely on, read back with date -r, both directions.
write(T .. "lint", "")
touch(T .. "lint", "30 seconds ago")
local a = age(T .. "lint")
is("0 touch -d '30 seconds ago' reads back 25-40 s old", "true", tostring(a ~= nil and a >= 25 and a <= 40))
touch(T .. "lint", "5 minutes")
a = age(T .. "lint")
is("0 touch -d '5 minutes' reads back 250-310 s in the future (a negative age)", "true",
   tostring(a ~= nil and a <= -250 and a >= -310))
os.remove(T .. "lint")

print("--- get_update_info")
local function info_case(label, cache, marker_when, want)
    os.remove(CACHE); os.remove(FAILED)
    if cache then write(CACHE, cache) end
    if marker_when then write(FAILED, ""); if marker_when ~= "now" then touch(FAILED, marker_when) end end
    reset()
    local ok, r = pcall(M.get_update_info)
    if not ok then is("get_update_info, " .. label, want, "error: " .. tostring(r)); return end
    is("get_update_info, " .. label, want, updater_spawns() .. "|" .. r.latest_version .. "|" .. r.latest_full
       .. "|" .. tostring(r.update_available))
end
info_case("no cache, no marker: one detached --check, checking...", nil, nil,
          SPAWN("--check") .. "|checking...|checking...|false")
info_case("no cache, a marker just written: no spawn, unavailable/unknown, no update", nil, "now",
          "|unavailable|unknown|false")
info_case("no cache, a marker 9 minutes old: still held off", nil, "9 minutes ago", "|unavailable|unknown|false")
info_case("no cache, a marker 11 minutes old: a new --check, checking...", nil, "11 minutes ago",
          SPAWN("--check") .. "|checking...|checking...|false")
info_case("no cache, a marker 5 minutes in the future (the clock set back): a new --check, checking...",
          nil, "5 minutes", SPAWN("--check") .. "|checking...|checking...|false")
info_case("a fresh cache, a marker: no spawn, the cached version", "1.98.8-tiny.by.admon.1320\n", "now",
          "|1.98.8|1.98.8-tiny.by.admon.1320|false")
write(CACHE, "1.98.8-tiny.by.admon.1320\n"); touch(CACHE, "4 days ago"); os.remove(FAILED); reset()
local r = M.get_update_info and M.get_update_info() or { latest_version = "?" }
is("get_update_info, a stale cache: one detached --check, the cached version still shown",
   SPAWN("--check") .. "|1.98.8", updater_spawns() .. "|" .. r.latest_version)

print("--- do_update and do_restore: the lock holder")
local STARTING = '{"status":"running","message":"Starting..."}'
local function update_case(label, lock_content, refused)
    if lock_content == nil then os.remove(LOCK) else write(LOCK, lock_content) end
    os.remove(STATUS); reset()
    local res = M.do_update()
    if refused then
        is("do_update, " .. label .. ": refused, no spawn, status untouched",
           "-1|Update already in progress||<absent>",
           tostring(res.err_code) .. "|" .. tostring(res.err_msg) .. "|" .. updater_spawns() .. "|" .. read(STATUS))
    else
        is("do_update, " .. label .. ": Starting... written, one detached --install",
           "nil|update_started|" .. SPAWN("--install") .. "|" .. STARTING,
           tostring(res.err_code) .. "|" .. tostring(res.status) .. "|" .. updater_spawns() .. "|" .. read(STATUS))
    end
end
update_case("no lock file", nil, false)
update_case("an empty lock file (a killed run before the PID was written)", "", false)
update_case("garbage in the lock file", "abc\n", false)
update_case("a PID with a suffix", LIVE_PID .. "x\n", false)
update_case("the PID of a process that is gone", "999999999\n", false)
update_case("the PID of a live process that is not the updater (pid 1)", "1\n", false)
update_case("the PID of a live ts-fix-update", LIVE_PID .. "\n", true)

os.remove(ROOT .. "/rom/usr/sbin/tailscale"); os.remove(LOCK); reset()
local res = M.do_restore()
is("do_restore, no factory binary: refused as before, no spawn", "-1|Factory binaries not found in /rom/|",
   tostring(res.err_code) .. "|" .. tostring(res.err_msg) .. "|" .. updater_spawns())
write(ROOT .. "/rom/usr/sbin/tailscale", "")
write(LOCK, LIVE_PID .. "\n"); os.remove(STATUS); reset()
res = M.do_restore()
is("do_restore, a live updater holds the lock: refused, no spawn, status untouched",
   "-1|Another update or restore is in progress||<absent>",
   tostring(res.err_code) .. "|" .. tostring(res.err_msg) .. "|" .. updater_spawns() .. "|" .. read(STATUS))
write(LOCK, ""); os.remove(STATUS); reset()
res = M.do_restore()
is("do_restore, a stale empty lock: Starting... written, one detached --restore",
   "nil|restore_started|" .. SPAWN("--restore") .. "|" .. STARTING,
   tostring(res.err_code) .. "|" .. tostring(res.status) .. "|" .. updater_spawns() .. "|" .. read(STATUS))

print("--- get_update_status")
local RUN = '{"status":"running","message":"Downloading Tailscale 1.98.8..."}'
local STILL = "running|Downloading Tailscale 1.98.8..."
local GONE = "error|Interrupted unexpectedly - check network and retry"
local function status_case(label, content, when, lock, want)
    if content == nil then os.remove(STATUS) else write(STATUS, content) end
    if when then touch(STATUS, when) end
    if lock == nil then os.remove(LOCK) else write(LOCK, lock) end
    local s = M.get_update_status()
    is("get_update_status, " .. label, want, tostring(s.status) .. "|" .. tostring(s.message))
    is("... the status file left as it was", content == nil and "<absent>" or content, read(STATUS))
end
status_case("no file: idle", nil, nil, nil, "idle|")
status_case("running, no live holder, 30 s old: interrupted", RUN, "30 seconds ago", "", GONE)
status_case("running, no live holder, 5 minutes in the future (the clock set back): interrupted",
            RUN, "5 minutes", nil, GONE)
status_case("running, no live holder, just written: still running", RUN, nil, nil, STILL)
status_case("running, no live holder, 15 s old: still running", RUN, "15 seconds ago", "garbage", STILL)
status_case("running, a live holder, 5 minutes old: still running", RUN, "5 minutes ago", LIVE_PID .. "\n", STILL)
status_case("running, a live holder, 5 minutes in the future: still running", RUN, "5 minutes",
            LIVE_PID .. "\n", STILL)
status_case("success, no holder, old: as written", '{"status":"success","message":"Updated to 1.98.8"}',
            "5 minutes ago", nil, "success|Updated to 1.98.8")
status_case("error, no holder, old: as written", '{"status":"error","message":"Download failed or timed out"}',
            "5 minutes ago", nil, "error|Download failed or timed out")

print("--- get_plugin_info, force_check_versions")
os.remove(PCACHE); reset()
r = M.get_plugin_info()
is("get_plugin_info, no cache: one detached --check-plugin", SPAWN("--check-plugin") .. "|checking...",
   updater_spawns() .. "|" .. r.latest_version)
write(PCACHE, "1.0.23\nhttps://example.invalid/r\n"); touch(PCACHE, "4 days ago"); reset()
r = M.get_plugin_info()
is("get_plugin_info, a stale cache: one detached --check-plugin, the cached version",
   SPAWN("--check-plugin") .. "|1.0.23", updater_spawns() .. "|" .. r.latest_version)
os.remove(CACHE); write(FAILED, ""); reset()
M.force_check_versions()
is("force_check_versions, a failed-check marker just written: the marker removed, then --check and --check-plugin",
   "<absent>|" .. SPAWN("--check") .. " ; " .. SPAWN("--check-plugin"), exists(FAILED) .. "|" .. updater_spawns())
reset()
r = M.get_update_info()
is("... so the page's next get_update_info reads checking... and polls (no cache)",
   SPAWN("--check") .. "|checking...", updater_spawns() .. "|" .. r.latest_version)

print("--- spawn_update refuses any other flag")
local spawn_update
for i = 1, 30 do
    local name, val = debug.getupvalue(M.force_check_versions or function() end, i)
    if name == nil then break end
    if name == "spawn_update" then spawn_update = val end
end
is("spawn_update reached through force_check_versions' upvalues", "function", type(spawn_update))
if spawn_update then
    for _, bad in ipairs({ "--sync-keep", "--check; reboot", "", "--install " }) do
        reset()
        spawn_update(bad)
        is("spawn_update(" .. string.format("%q", bad) .. "): no spawn, one ERR log", "|1|ERR",
           updater_spawns() .. "|" .. #logs .. "|" .. ((logs[1] or ""):match("^(%S+)") or ""))
    end
end

print()
if fails == 0 then
    print("ALL PASS (" .. oks .. " ok, 0 skipped)")
    os.exit(0)
end
print(fails .. " FAILED (" .. oks .. " ok, 0 skipped)")
os.exit(1)
