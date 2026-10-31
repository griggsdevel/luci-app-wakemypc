--[[
WakeMyPc - LuCI controller
Copyright (c) 2026 WakeMyPc contributors
License: MIT
]]--

module("luci.controller.wakemypc", package.seeall)

local http = require "luci.http"
local fs   = require "nixio.fs"

local UCI_CONFIG  = "wakemypc"
local BOT_BIN     = "/usr/bin/wakemypc"
local BOT_INIT    = "/etc/init.d/wakemypc"
local UNINSTALLER = "/usr/lib/wakemypc/uninstall.sh"

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function uci_cursor()
	return require("luci.model.uci").cursor()
end

local function sh(cmd)
	local f = io.popen(cmd .. " 2>&1")
	if not f then
		return ""
	end
	local out = f:read("*a") or ""
	f:close()
	return out
end

local function trim(s)
	s = tostring(s or "")
	s = s:gsub("^%s+", "")
	s = s:gsub("%s+$", "")
	return s
end

local function jesc(s)
	s = tostring(s or "")
	s = s:gsub("\\", "\\\\")
	s = s:gsub('"', '\\"')
	s = s:gsub("\r", "\\r")
	s = s:gsub("\n", "\\n")
	s = s:gsub("\t", "\\t")
	s = s:gsub("%c", " ")
	return s
end

local function shellq(s)
	return "'" .. tostring(s or ""):gsub("'", "'\\''") .. "'"
end

local function is_ipv4(ip)
	if not ip or ip == "" then
		return false
	end
	local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
	if not a then
		return false
	end
	for _, v in ipairs({ a, b, c, d }) do
		if tonumber(v) > 255 then
			return false
		end
	end
	return true
end

-- The bot is a shell script, so /proc/<pid>/cmdline contains
-- "/bin/sh /usr/bin/wakemypc". Scanning /proc avoids matching our own
-- `pgrep` command line.
local function bot_running()
	local dir = fs.dir("/proc")

	if not dir then
		return false
	end

	for entry in dir do
		if entry:match("^%d+$") then
			local f = io.open("/proc/" .. entry .. "/cmdline", "r")
			if f then
				local cmd = f:read("*a") or ""
				f:close()
				if cmd:find(BOT_BIN, 1, true) then
					return true
				end
			end
		end
	end

	return false
end

local function pc_config()
	local c = uci_cursor()
	return {
		name = c:get(UCI_CONFIG, "pc", "name") or "",
		ip   = c:get(UCI_CONFIG, "pc", "ip") or "",
		mac  = c:get(UCI_CONFIG, "pc", "mac") or "",
		user = c:get(UCI_CONFIG, "pc", "ssh_user") or "",
		key  = c:get(UCI_CONFIG, "pc", "ssh_key") or "/root/.ssh/id_ed25519"
	}
end

-- Probe the PC over SSH. Returns true / false / nil (cannot test).
local function pc_online()
	local pc = pc_config()

	if not is_ipv4(pc.ip) or pc.user == "" then
		return nil
	end

	if not pc.user:match("^[%w%._%-]+$") then
		return nil
	end

	local cmd = string.format(
		"ssh -o BatchMode=yes -o StrictHostKeyChecking=no " ..
		"-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR " ..
		"-o ConnectTimeout=5 -i %s %s@%s 'echo ok'",
		shellq(pc.key), pc.user, pc.ip
	)

	return sh(cmd):find("ok", 1, true) ~= nil
end

local function service(cmd)
	return sh(BOT_INIT .. " " .. cmd)
end

local function set_enabled(value)
	local c = uci_cursor()
	c:set(UCI_CONFIG, "bot", "enabled", value)
	c:commit(UCI_CONFIG)
end

-- Full status payload (bot + pc + version), optionally with a command output.
local function status_json(output)
	local pc = pc_online()
	local state

	if pc == true then
		state = "on"
	elseif pc == false then
		state = "off"
	else
		state = "unknown"
	end

	if output and output ~= "" then
		return string.format(
			'{"ok":true,"bot":%s,"pc":"%s","version":"1.0.0","output":"%s"}',
			bot_running() and "true" or "false", state, jesc(trim(output)))
	end

	return string.format(
		'{"ok":true,"bot":%s,"pc":"%s","version":"1.0.0"}',
		bot_running() and "true" or "false", state)
end

local function wait_until(pred, seconds)
	local i

	for i = 1, seconds do
		if pred() then
			return true
		end
		sh("sleep 1")
	end

	return pred()
end

-- Stop must be synchronous: procd may spend a few seconds on SIGTERM/SIGKILL
-- and may even respawn once while stopping. Kill leftovers so the UI never
-- reports a stale "running" state.
local function do_stop()
	set_enabled("0")
	local out = service("stop")
	local i

	for i = 1, 6 do
		if not bot_running() then
			break
		end
		sh("killall wakemypc >/dev/null 2>&1")
		sh("sleep 1")
	end

	return out
end

local function do_start()
	set_enabled("1")
	service("enable")
	local out = service("start")
	wait_until(bot_running, 5)
	return out
end

local function do_restart()
	do_stop()
	return do_start()
end

local function read_logs()
	local out = sh("logread | grep wakemypc | tail -n 50")

	if trim(out) == "" then
		out = sh("logread -e wakemypc | tail -n 50")
	end

	if trim(out) == "" then
		out = "(no log entries yet: logread | grep wakemypc)"
	end

	return out
end

local function check_token()
	local c    = uci_cursor()
	local tok  = c:get(UCI_CONFIG, "bot", "token") or ""
	local base = c:get(UCI_CONFIG, "bot", "api_base") or ""

	if tok == "" then
		return { ok = false, error = "Token is empty / Токен не задан" }
	end

	if base == "" then
		base = "https://api.telegram.org"
	end

	base = base:gsub("/+$", "")

	local url = base .. "/bot" .. tok .. "/getMe"
	local res = sh("curl -s --max-time 20 " .. shellq(url))

	if res == "" then
		return { ok = false, error = "No response from API / API не отвечает" }
	end

	local username = res:match('"username"%s*:%s*"([^"]+)"')
	local ok_field = res:match('"ok"%s*:%s*true')
	local desc     = res:match('"description"%s*:%s*"([^"]+)"')

	if ok_field and username then
		return { ok = true, username = username }
	end

	return { ok = false, error = desc or trim(res):sub(1, 200) }
end

local function scan_lan()
	local out = sh("ip neigh show")
	local list = {}

	for line in out:gmatch("[^\r\n]+") do
		local ip, mac = line:match("^(%d+%.%d+%.%d+%.%d+)%s+dev%s+%S+%s+lladdr%s+([%x][%x]:[%x][%x]:[%x][%x]:[%x][%x]:[%x][%x]:[%x][%x])")
		if ip and mac then
			local state = line:match("%s([A-Z]+)%s*$") or ""
			list[#list + 1] = { ip = ip, mac = mac:lower(), state = state }
		end
	end

	return list
end

local function do_remove()
	if fs.access(UNINSTALLER) then
		local out = sh("NONINTERACTIVE=1 sh " .. UNINSTALLER)
		sh("rm -f /tmp/luci-indexcache* ; rm -rf /tmp/luci-modulecache")
		return out
	end

	-- Fallback when the installer copy is missing.
	local out = {}
	out[#out + 1] = service("stop")
	out[#out + 1] = service("disable")
	sh("rm -f " .. BOT_INIT .. " " .. BOT_BIN)
	sh("rm -f /usr/lib/lua/luci/controller/wakemypc.lua")
	sh("rm -f /usr/lib/lua/luci/model/cbi/wakemypc.lua")
	sh("rm -rf /usr/lib/lua/luci/view/wakemypc")
	sh("rm -f /etc/config/wakemypc /tmp/wakemypc.*")
	sh("rm -f /tmp/luci-indexcache* ; rm -rf /tmp/luci-modulecache")
	out[#out + 1] = "[WakeMyPc] removed / удалено"
	return table.concat(out, "\n")
end

-- ---------------------------------------------------------------------------
-- Dispatcher
-- ---------------------------------------------------------------------------

function index()
	if not fs.access("/etc/config/wakemypc") then
		return
	end

	entry({"admin", "services", "wakemypc"},
		cbi("wakemypc"),
		_("WakeMyPc"), 60).dependent = true

	entry({"admin", "services", "wakemypc", "control"},
		call("action_control")).dependent = true
end

function action_control()
	local action = http.formvalue("action") or ""
	local body

	if action == "status" then
		body = status_json()

	elseif action == "start" then
		body = status_json(do_start())

	elseif action == "stop" then
		body = status_json(do_stop())

	elseif action == "restart" then
		body = status_json(do_restart())

	elseif action == "logs" then
		body = string.format('{"ok":true,"logs":"%s"}', jesc(read_logs()))

	elseif action == "checktoken" then
		local r    = check_token()
		local name = r.username and ("@" .. r.username) or ""
		body = string.format('{"ok":%s,"username":"%s","error":"%s"}',
			r.ok and "true" or "false", jesc(name), jesc(r.error or ""))

	elseif action == "scan" then
		local list = scan_lan()
		local items = {}

		for _, d in ipairs(list) do
			items[#items + 1] = string.format(
				'{"ip":"%s","mac":"%s","state":"%s"}',
				jesc(d.ip), jesc(d.mac), jesc(d.state))
		end

		body = string.format('{"ok":true,"devices":[%s]}', table.concat(items, ","))

	elseif action == "remove" then
		if http.formvalue("confirm") ~= "DELETE" then
			body = '{"ok":false,"error":"confirmation required / нужно подтверждение"}'
		else
			body = string.format('{"ok":true,"output":"%s"}', jesc(do_remove()))
		end

	else
		body = '{"ok":false,"error":"unknown action / неизвестное действие"}'
	end

	http.prepare_content("application/json")
	http.write(body)
end
