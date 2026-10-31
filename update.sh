#!/bin/sh
#
# WakeMyPc updater for OpenWrt
#
# Usage:
#   wget -qO- https://raw.githubusercontent.com/griggsdevel/luci-app-wakemypc/main/update.sh | sh
#
# Copyright (c) 2026 WakeMyPc contributors
# License: MIT
#

REPO="griggsdevel/luci-app-wakemypc"
BRANCH="${WAKEMYPC_BRANCH:-main}"
RAW="https://raw.githubusercontent.com/${REPO}/${BRANCH}"

BOT_BIN="/usr/bin/wakemypc"
TMP="/tmp/wakemypc.update.$$"

say() { printf '%s\n' "$*"; }
die() { say "❌ $*"; rm -rf "$TMP"; exit 1; }

ask() {
	printf '%s' "$1"
	ans=""
	if [ -r /dev/tty ]; then
		read -r ans < /dev/tty 2>/dev/null
	fi
	ans=$(printf '%s' "$ans" | tr -d ' \t\r\n' | tr 'A-Z' 'a-z')
}

fetch() {
	_url="$1"
	_out="$2"

	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --max-time 60 "$_url" -o "$_out"
	elif command -v wget >/dev/null 2>&1; then
		wget -q -O "$_out" "$_url"
	else
		return 1
	fi
}

ver_of() {
	sed -n 's/^BOT_VERSION="\(.*\)"$/\1/p' "$1" 2>/dev/null | head -n 1
}

# ver_gt A B -> exit 0 when A > B
ver_gt() {
	awk -v a="$1" -v b="$2" 'BEGIN {
		n = split(a, x, ".");
		m = split(b, y, ".");
		if (m > n) n = m;
		for (i = 1; i <= n; i++) {
			ai = (i in x) ? x[i] + 0 : 0;
			bi = (i in y) ? y[i] + 0 : 0;
			if (ai > bi) exit 0;
			if (ai < bi) exit 1;
		}
		exit 1;
	}'
}

say ""
say "══════════════════════════════════════════"
say "  WakeMyPc updater"
say "══════════════════════════════════════════"
say ""

[ -f /etc/openwrt_release ] || die "Это не OpenWrt."
[ "$(id -u)" = "0" ] || die "Нужны права root."
[ -f "$BOT_BIN" ] || die "WakeMyPc не установлен ($BOT_BIN отсутствует). Сначала запусти install.sh."

# --- 1. Download to temp ---------------------------------------------------

mkdir -p "$TMP" || die "Не могу создать $TMP"

say "→ Скачиваю свежие файлы во временную папку..."
fetch "$RAW/files/usr/bin/wakemypc" "$TMP/wakemypc" || die "Не удалось скачать wakemypc."
fetch "$RAW/files/etc/init.d/wakemypc" "$TMP/init.wakemypc" || die "Не удалось скачать init-скрипт."
fetch "$RAW/files/usr/lib/lua/luci/controller/wakemypc.lua" "$TMP/controller.lua" || die "Не удалось скачать controller."
fetch "$RAW/files/usr/lib/lua/luci/model/cbi/wakemypc.lua" "$TMP/cbi.lua" || die "Не удалось скачать CBI-модель."
fetch "$RAW/files/usr/lib/lua/luci/view/wakemypc/status.htm" "$TMP/status.htm" || die "Не удалось скачать status.htm."

# --- 2. Compare versions ----------------------------------------------------

NEW_VER=$(ver_of "$TMP/wakemypc")
CUR_VER=$(ver_of "$BOT_BIN")

[ -n "$NEW_VER" ] || die "Не удалось определить версию новых файлов."
[ -n "$CUR_VER" ] || CUR_VER="0.0.0"

say "→ Установлено: $CUR_VER   Доступно: $NEW_VER"

if ver_gt "$NEW_VER" "$CUR_VER"; then
	say "→ Есть обновление."
elif ver_gt "$CUR_VER" "$NEW_VER"; then
	say ""
	say "⚠️  Внимание: установленная версия ($CUR_VER) НОВЕЕ удалённой ($NEW_VER)."
	say "    Это откат на более старую версию (например, ветка $BRANCH отстаёт)."
	ask "    Продолжить? (y/N) "
	case "$ans" in
		y|yes) say "→ Продолжаю (downgrade)." ;;
		*) say "Отменено."; rm -rf "$TMP"; exit 0 ;;
	esac
else
	say "✅ Уже установлена последняя версия ($CUR_VER). Обновление не требуется."
	rm -rf "$TMP"
	exit 0
fi

# --- 3. Replace files -------------------------------------------------------

WAS_ENABLED=$(uci -q get wakemypc.bot.enabled)

say "→ Останавливаю бота..."
/etc/init.d/wakemypc stop >/dev/null 2>&1

say "→ Заменяю файлы..."
cp -f "$TMP/wakemypc" "$BOT_BIN" || die "Не удалось заменить $BOT_BIN"
cp -f "$TMP/init.wakemypc" /etc/init.d/wakemypc || die "Не удалось заменить init-скрипт"
cp -f "$TMP/controller.lua" /usr/lib/lua/luci/controller/wakemypc.lua || die "Не удалось заменить controller"
cp -f "$TMP/cbi.lua" /usr/lib/lua/luci/model/cbi/wakemypc.lua || die "Не удалось заменить CBI-модель"
mkdir -p /usr/lib/lua/luci/view/wakemypc
cp -f "$TMP/status.htm" /usr/lib/lua/luci/view/wakemypc/status.htm || die "Не удалось заменить status.htm"

chmod +x "$BOT_BIN" /etc/init.d/wakemypc

# uninstall.sh (optional)
mkdir -p /usr/lib/wakemypc
fetch "$RAW/uninstall.sh" /usr/lib/wakemypc/uninstall.sh >/dev/null 2>&1
chmod +x /usr/lib/wakemypc/uninstall.sh 2>/dev/null

rm -f /tmp/luci-indexcache* 2>/dev/null
rm -rf /tmp/luci-modulecache 2>/dev/null
rm -rf "$TMP"

# --- 4. Restart -------------------------------------------------------------

if [ "$WAS_ENABLED" = "1" ]; then
	say "→ Запускаю бота..."
	/etc/init.d/wakemypc enable >/dev/null 2>&1
	/etc/init.d/wakemypc start >/dev/null 2>&1
fi

say ""
say "✅ Обновлено до $NEW_VER"
say "   Логи: logread | grep wakemypc"
say ""
