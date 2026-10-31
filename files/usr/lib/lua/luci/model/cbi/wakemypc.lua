--[[
WakeMyPc - LuCI configuration model (CBI)
Copyright (c) 2026 WakeMyPc contributors
License: MIT
]]--

local fs   = require "nixio.fs"
local i18n = require "luci.i18n"
local uci  = require "luci.model.uci".cursor()

local VIEW    = "/usr/lib/lua/luci/view/wakemypc/status.htm"
local BOT_BIN = "/usr/bin/wakemypc"
local CONFIG  = "wakemypc"

local m, s, o

-- ---------------------------------------------------------------------------
-- Language
--
-- "auto" follows the LuCI language, otherwise ru/en. The same option is read
-- by the bot, so one setting drives both the web interface and the messages.
-- ---------------------------------------------------------------------------

local LANG_OPT = uci:get(CONFIG, "bot", "lang")
local UI_LANG  = nil

if i18n and i18n.context and i18n.context.lang and i18n.context.lang ~= "" then
	UI_LANG = i18n.context.lang
else
	UI_LANG = uci:get("luci", "main", "lang")
end

if not UI_LANG or UI_LANG == "" then
	UI_LANG = "en"
end

local LANG = LANG_OPT

if not LANG or LANG == "" or LANG == "auto" then
	LANG = UI_LANG
end

local IS_RU = LANG:sub(1, 2) == "ru"

local RU = {
	["Telegram bot that powers a home PC on via Wake-on-LAN and shuts it down or reboots it over SSH."] = "Telegram-бот: включает домашний ПК через Wake-on-LAN и выключает/перезагружает его по SSH.",
	["Bot settings"] = "Настройки бота",
	["Language"] = "Язык",
	["Auto (LuCI)"] = "Авто (как в LuCI)",
	["Interface and bot messages. 'Auto' follows the LuCI language."] = "Язык интерфейса и сообщений бота. «Авто» — как в LuCI.",
	["Bot Token"] = "Токен бота",
	["Token from @BotFather. Stored only in /etc/config/wakemypc."] = "Токен из @BotFather. Хранится только в /etc/config/wakemypc.",
	["Allowed Telegram ID"] = "Разрешённый Telegram ID",
	["Only this user may control the bot. Send /start to @userinfobot to get your numeric ID."] = "Только этот пользователь может управлять ботом. Узнать числовой ID: /start у @userinfobot.",
	["Notify when the PC comes online"] = "Уведомлять о включении ПК",
	["Send an automatic 'PC is up' message after the PC was offline. Off by default: the bot only answers your commands."] = "Автоматически сообщать, что ПК включился, после периода недоступности. По умолчанию выключено: бот отвечает только на команды.",
	["API Base URL"] = "Базовый URL API",
	["Default is https://api.telegram.org. You may put a Cloudflare Worker or any reverse proxy in front of Telegram."] = "По умолчанию https://api.telegram.org. Можно указать Cloudflare Worker или другой прокси перед Telegram.",
	["Check token"] = "Проверить токен",
	["PC settings"] = "Настройки ПК",
	["PC name"] = "Имя ПК",
	["Display name used in bot messages."] = "Отображаемое имя в сообщениях бота.",
	["MAC address"] = "MAC-адрес",
	["MAC address of the PC network card. Required for Wake-on-LAN."] = "MAC-адрес сетевой карты ПК. Нужен для Wake-on-LAN.",
	["IP address"] = "IP-адрес",
	["Static IP (or DHCP reservation) of the PC in your LAN."] = "Статический IP (или резервирование DHCP) ПК в локальной сети.",
	["LAN interface"] = "LAN-интерфейс",
	["Interface used to send the magic packet (etherwake -i)."] = "Интерфейс для отправки magic-пакета (etherwake -i).",
	["SSH user"] = "SSH-пользователь",
	["Account name used for SSH login on the PC (for example: user)."] = "Имя учётной записи для входа по SSH на ПК (например: user).",
	["SSH key path"] = "Путь к SSH-ключу",
	["Private key on the router used to log into the PC without a password."] = "Приватный ключ на роутере для входа на ПК без пароля.",
	["Find PC"] = "Найти ПК",
	["Scans the ARP table (ip neigh) and fills MAC/IP from the selected device."] = "Сканирует ARP-таблицу (ip neigh) и подставляет MAC/IP выбранного устройства.",
	["Control"] = "Управление",
	["Buttons talk to the same LuCI session and return JSON."] = "Кнопки работают через текущую сессию LuCI и возвращают JSON.",
	["Danger zone"] = "Удаление",
	["Type DELETE and press the button to remove WakeMyPc from this router completely."] = "Введи DELETE и нажми кнопку, чтобы полностью удалить WakeMyPc с роутера.",
	["Delete completely"] = "Удалить полностью",
	["Confirmation word"] = "Слово подтверждения",
	["not found"] = "не найден"
}

local function T(str)
	if IS_RU then
		return RU[str] or str
	end
	return str
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function sh(cmd)
	local f = io.popen(cmd .. " 2>&1")
	if not f then
		return ""
	end
	local out = f:read("*a") or ""
	f:close()
	return out
end

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

local function pc_state()
	local ip   = uci:get(CONFIG, "pc", "ip") or ""
	local user = uci:get(CONFIG, "pc", "ssh_user") or ""
	local key  = uci:get(CONFIG, "pc", "ssh_key") or "/root/.ssh/id_ed25519"

	if not ip:match("^%d+%.%d+%.%d+%.%d+$") or user == "" or not user:match("^[%w%._%-]+$") then
		return "unknown"
	end

	local cmd = string.format(
		"ssh -o BatchMode=yes -o StrictHostKeyChecking=no " ..
		"-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR " ..
		"-o ConnectTimeout=4 -i '%s' %s@%s 'echo ok'",
		key:gsub("'", ""), user, ip
	)

	if sh(cmd):find("ok", 1, true) then
		return "on"
	end

	return "off"
end

-- Render the control panel view and substitute placeholders.
local function control_panel()
	local f = io.open(VIEW, "r")
	local txt = ""

	if f then
		txt = f:read("*a") or ""
		f:close()
	end

	if txt == "" then
		return "<em>view/wakemypc/status.htm " .. T("not found") .. "</em>"
	end

	local url  = luci.dispatcher.build_url("admin", "services", "wakemypc", "control")
	local csrf = ""

	if luci.dispatcher.context then
		csrf = luci.dispatcher.context.authsession
			or luci.dispatcher.context.token
			or ""
	end

	if csrf == "" and luci.http and luci.http.getcookie then
		csrf = luci.http.getcookie("sysauth_https")
			or luci.http.getcookie("sysauth")
			or ""
	end

	local map = {
		__CONTROL_URL__ = url,
		__CSRF_TOKEN__  = csrf,
		__BOT_RUN__     = bot_running() and "1" or "0",
		__PC_STATE__    = pc_state(),
		__LANG__        = IS_RU and "ru" or "en"
	}

	for k, v in pairs(map) do
		txt = txt:gsub(k, function() return v end)
	end

	return txt
end

local function token_widget()
	return string.format([[
<div class="cbi-value">
	<div class="cbi-value-title">&nbsp;</div>
	<div class="cbi-value-field">
		<button type="button" class="cbi-button cbi-button-action" onclick="wmpCheckToken()">🔑 %s</button>
		<span id="wmp-token-result" style="margin-left:10px"></span>
	</div>
</div>]], T("Check token"))
end

local function scan_widget()
	return string.format([[
<div class="cbi-value">
	<div class="cbi-value-title">&nbsp;</div>
	<div class="cbi-value-field">
		<button type="button" class="cbi-button cbi-button-action" onclick="wmpScan()">🔎 %s</button>
		<span id="wmp-scan-info" style="margin-left:10px"></span>
		<div class="cbi-value-description">%s</div>
		<div id="wmp-scan-result"></div>
	</div>
</div>]], T("Find PC"), T("Scans the ARP table (ip neigh) and fills MAC/IP from the selected device."))
end

local function delete_widget()
	return string.format([[
<div class="cbi-value">
	<div class="cbi-value-title">%s</div>
	<div class="cbi-value-field">
		<input type="text" id="wmp-delete-confirm" class="cbi-input-text" style="width:160px" placeholder="DELETE" />
		<button type="button" class="cbi-button cbi-button-remove" onclick="wmpRemove()">🗑 %s</button>
		<span id="wmp-remove-result" style="margin-left:10px"></span>
	</div>
</div>]], T("Confirmation word"), T("Delete completely"))
end

-- LuCI's DummyValue + rawhtml renders the value twice on ucode-based LuCI
-- (once raw, once HTML-escaped), so the widget is emitted by a custom
-- render() that writes exactly once.
local function raw_option(section_obj, name, builder)
	local opt = section_obj:option(DummyValue, name, " ")
	opt.render = function(self, scope, section)
		local http = require "luci.http"
		http.write(builder())
	end
	return opt
end

-- ---------------------------------------------------------------------------
-- Map and sections
-- ---------------------------------------------------------------------------

m = Map(CONFIG, "WakeMyPc",
	T("Telegram bot that powers a home PC on via Wake-on-LAN and shuts it down or reboots it over SSH."))

m.redirect = luci.dispatcher.build_url("admin", "services", "wakemypc")

-- 1. Bot settings -----------------------------------------------------------

s = m:section(NamedSection, "bot", "bot", T("Bot settings"))
s.addremove = false
s.anonymous = false

o = s:option(ListValue, "lang", T("Language"))
o:value("auto", T("Auto (LuCI)"))
o:value("ru", "Русский")
o:value("en", "English")
o.default = "auto"
o.rmempty = false
o.description = T("Interface and bot messages. 'Auto' follows the LuCI language.")

o = s:option(Value, "token", T("Bot Token"))
o.password = true
o.rmempty = false
o.datatype = "string"
o.description = T("Token from @BotFather. Stored only in /etc/config/wakemypc.")

o = s:option(Value, "allowed_id", T("Allowed Telegram ID"))
o.rmempty = false
o.datatype = "uinteger"
o.placeholder = "123456789"
o.description = T("Only this user may control the bot. Send /start to @userinfobot to get your numeric ID.")

o = s:option(Flag, "notify", T("Notify when the PC comes online"))
o.default = "0"
o.rmempty = false
o.description = T("Send an automatic 'PC is up' message after the PC was offline. Off by default: the bot only answers your commands.")

o = s:option(Value, "api_base", T("API Base URL"))
o.default = "https://api.telegram.org"
o.placeholder = "https://api.telegram.org"
o.description = T("Default is https://api.telegram.org. You may put a Cloudflare Worker or any reverse proxy in front of Telegram.")

raw_option(s, "_token_check", token_widget)

-- 2. PC settings ------------------------------------------------------------

s = m:section(NamedSection, "pc", "pc", T("PC settings"))
s.addremove = false
s.anonymous = false

o = s:option(Value, "name", T("PC name"))
o.default = "MyPC"
o.rmempty = false
o.description = T("Display name used in bot messages.")

o = s:option(Value, "mac", T("MAC address"))
o.datatype = "macaddr"
o.placeholder = "AA:BB:CC:DD:EE:FF"
o.description = T("MAC address of the PC network card. Required for Wake-on-LAN.")

o = s:option(Value, "ip", T("IP address"))
o.datatype = "ip4addr"
o.placeholder = "192.168.1.100"
o.description = T("Static IP (or DHCP reservation) of the PC in your LAN.")

o = s:option(ListValue, "iface", T("LAN interface"))
o.default = "br-lan"
o.rmempty = false
o.description = T("Interface used to send the magic packet (etherwake -i).")

local current_iface = uci:get(CONFIG, "pc", "iface")
local seen = {}
local dir = fs.dir("/sys/class/net")

if dir then
	for dev in dir do
		if dev ~= "lo" then
			o:value(dev, dev)
			seen[dev] = true
		end
	end
end

if current_iface and current_iface ~= "" and not seen[current_iface] then
	o:value(current_iface, current_iface .. " (missing)")
end

o = s:option(Value, "ssh_user", T("SSH user"))
o.placeholder = "user"
o.rmempty = false
o.description = T("Account name used for SSH login on the PC (for example: user).")

o = s:option(Value, "ssh_key", T("SSH key path"))
o.default = "/root/.ssh/id_ed25519"
o.rmempty = false
o.description = T("Private key on the router used to log into the PC without a password.")

raw_option(s, "_scan", scan_widget)

-- 3. Control ----------------------------------------------------------------

s = m:section(SimpleSection)
s.title = T("Control")
s.description = T("Buttons talk to the same LuCI session and return JSON.")

raw_option(s, "_control", control_panel)

-- 4. Removal ----------------------------------------------------------------

s = m:section(SimpleSection)
s.title = T("Danger zone")
s.description = T("Type DELETE and press the button to remove WakeMyPc from this router completely.")

raw_option(s, "_delete", delete_widget)

-- Restart the bot when settings change so new values are picked up.
function m.on_after_commit(self)
	if bot_running() then
		sh("/etc/init.d/wakemypc reload")
	end
end

return m
