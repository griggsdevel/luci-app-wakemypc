#!/bin/sh
#
# WakeMyPc uninstaller for OpenWrt
#
# Usage:
#   wget -qO- https://raw.githubusercontent.com/griggsdevel/luci-app-wakemypc/main/uninstall.sh | sh
#
# Non-interactive (used by the LuCI "Delete completely" button):
#   NONINTERACTIVE=1 sh /usr/lib/wakemypc/uninstall.sh
#
# Copyright (c) 2026 WakeMyPc contributors
# License: MIT
#

say() { printf '%s\n' "$*"; }

ask() {
	printf '%s' "$1"
	ans=""
	if [ -r /dev/tty ]; then
		read -r ans < /dev/tty 2>/dev/null
	fi
	# Strip trailing \r (serial/ptt consoles) and surrounding blanks.
	ans=$(printf '%s' "$ans" | tr -d ' \t\r\n')
}

# When the script deletes /usr/lib/wakemypc, it would delete itself while
# still running. Re-exec from /tmp first.
if [ "${WMP_SELF:-0}" != "1" ] && [ -f "$0" ]; then
	cp "$0" "/tmp/wakemypc.uninstall.$$" 2>/dev/null && {
		export WMP_SELF=1
		exec sh "/tmp/wakemypc.uninstall.$$" "$@"
	}
fi

say ""
say "══════════════════════════════════════════"
say "  WakeMyPc uninstaller"
say "══════════════════════════════════════════"
say ""

[ "$(id -u)" = "0" ] || { say "❌ Нужны права root."; exit 1; }

if [ "${NONINTERACTIVE:-0}" != "1" ]; then
	say "Будут удалены: init-скрипт, бот, LuCI-страница и /etc/config/wakemypc."
	ask "Введите DELETE для подтверждения: "
	if [ "$ans" != "DELETE" ]; then
		say "Отменено."
		exit 0
	fi
fi

# --- 1. Stop and disable ----------------------------------------------------

say "→ Останавливаю и отключаю сервис..."
if [ -x /etc/init.d/wakemypc ]; then
	/etc/init.d/wakemypc stop >/dev/null 2>&1
	/etc/init.d/wakemypc disable >/dev/null 2>&1
fi
killall wakemypc >/dev/null 2>&1

# --- 2. Remove files --------------------------------------------------------

say "→ Удаляю файлы..."
rm -f /etc/init.d/wakemypc
rm -f /usr/bin/wakemypc
rm -f /root/README.txt

rm -f /usr/lib/lua/luci/controller/wakemypc.lua
rm -f /usr/lib/lua/luci/model/cbi/wakemypc.lua
rm -rf /usr/lib/lua/luci/view/wakemypc

# Legacy i18n files, if any were ever installed.
rm -f /usr/lib/lua/luci/i18n/wakemypc.*.lmo

# --- 3. Remove config -------------------------------------------------------

say "→ Удаляю конфиг..."
rm -f /etc/config/wakemypc

# --- 4. Temp/state files ----------------------------------------------------

rm -f /tmp/wakemypc.*
rm -rf /tmp/luci-modulecache
rm -f /tmp/luci-indexcache* 2>/dev/null

# --- 5. Optional dependencies ----------------------------------------------

if [ "${NONINTERACTIVE:-0}" != "1" ]; then
	ask "Удалить также etherwake/openssh-client? (y/N) "
	case "$ans" in
		y|Y|yes|YES)
			if command -v apk >/dev/null 2>&1; then
				apk del etherwake openssh-client >/dev/null 2>&1
			else
				opkg remove etherwake openssh-client >/dev/null 2>&1
			fi
			say "→ Пакеты etherwake/openssh-client удалены."
			;;
		*)
			say "→ Пакеты оставлены."
			;;
	esac
fi

# --- 6. Self-remove ---------------------------------------------------------

rm -rf /usr/lib/wakemypc
rm -f /tmp/wakemypc.uninstall.*

say ""
say "✅ WakeMyPc удалён."
say "   Остались пакеты: curl, jq (используются другими приложениями)."
say ""
