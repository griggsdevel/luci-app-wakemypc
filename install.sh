#!/bin/sh
#
# WakeMyPc installer for OpenWrt
#
# Usage:
#   wget -qO- https://raw.githubusercontent.com/griggsdevel/luci-app-wakemypc/main/install.sh | sh
#
# Copyright (c) 2026 WakeMyPc contributors
# License: MIT
#

REPO="griggsdevel/luci-app-wakemypc"
BRANCH="${WAKEMYPC_BRANCH:-main}"
RAW="https://raw.githubusercontent.com/${REPO}/${BRANCH}"

say() { printf '%s\n' "$*"; }
die() { say "❌ $*"; exit 1; }

# Ask a question even when the script itself is piped into sh.
# The answer is normalized: trailing \r from serial/ptt consoles is stripped,
# case is lowered, so "y" / "Y" / "2" always work.
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

say ""
say "══════════════════════════════════════════"
say "  WakeMyPc installer (LuCI app)"
say "══════════════════════════════════════════"
say ""

# --- 1. Sanity checks -------------------------------------------------------

[ -f /etc/openwrt_release ] || die "Это не OpenWrt (/etc/openwrt_release не найден). Установка прервана."

if [ "$(id -u)" != "0" ]; then
	die "Нужны права root. Запусти: wget -qO- ${RAW}/install.sh | sh"
fi

# --- 2. Package manager -----------------------------------------------------

if command -v apk >/dev/null 2>&1; then
	PKG="apk"
elif command -v opkg >/dev/null 2>&1; then
	PKG="opkg"
else
	die "Не найден ни apk, ни opkg — не могу установить зависимости."
fi

say "→ Менеджер пакетов: $PKG"

pkg_update() {
	if [ "$PKG" = "apk" ]; then
		apk update >/dev/null 2>&1
	else
		opkg update >/dev/null 2>&1
	fi
}

pkg_install() {
	if [ "$PKG" = "apk" ]; then
		apk add --no-cache "$@"
	else
		opkg install "$@"
	fi
}

# LuCI detection works both for the Lua (<= 24.10) and ucode (25.x) era.
luci_present() {
	[ -e /www/cgi-bin/luci ] || [ -f /etc/config/luci ]
}

# --- 3. Dependencies --------------------------------------------------------

say "→ Устанавливаю зависимости: curl jq etherwake openssh-client"
pkg_update
pkg_install curl jq etherwake openssh-client || die "Не удалось установить зависимости."

# --- 4. LuCI check ----------------------------------------------------------

if ! luci_present; then
	say ""
	say "⚠️  LuCI не найден — веб-интерфейс работать не будет."
	ask "   Установить LuCI сейчас? (y/N) "
	case "$ans" in
		y|yes)
			say "→ Устанавливаю LuCI (это может занять пару минут)..."
			pkg_update
			pkg_install luci || say "⚠️  Не удалось установить luci, продолжаю без него."
			;;
		*)
			say "→ Продолжаю без LuCI (бот будет работать, настройка — через uci)."
			say "   Позже можно поставить так: apk update && apk add luci"
			;;
	esac
fi

# --- 4b. Lua runtime for LuCI ----------------------------------------------
# OpenWrt 25.x ships LuCI on ucode; legacy Lua plugins (this app) need
# luci-lua-runtime and luci-compat, otherwise uhttpd logs
# "Lua controller ... present but no Lua runtime installed" / "module 'luci.cbi' not found"
# and the menu entry never appears.

if luci_present; then
	if [ "$PKG" = "apk" ]; then
		for extra in luci-lua-runtime luci-compat; do
			apk info -e "$extra" >/dev/null 2>&1 && continue
			apk search -x "$extra" >/dev/null 2>&1 || continue
			say "→ Устанавливаю $extra (нужен Lua-плагинам LuCI на OpenWrt 25.x)..."
			pkg_install "$extra" >/dev/null 2>&1 \
				|| say "⚠️  Не удалось поставить $extra."
		done
	fi
fi

# --- 5. Config + language ---------------------------------------------------

if [ -f /etc/config/wakemypc ]; then
	say "→ Конфиг уже есть, сохраняю: /etc/config/wakemypc"
else
	fetch "$RAW/files/etc/config/wakemypc" /etc/config/wakemypc \
		|| die "Не удалось скачать файл конфига."
	say "→ Создан /etc/config/wakemypc"

	say ""
	say "   Язык интерфейса и бота / Interface and bot language:"
	say "     1) Русский"
	say "     2) English"
	ask "   Выбор / Choice [1]: "
	case "$ans" in
		2|en|english) LANG_CHOICE="en" ;;
		*)           LANG_CHOICE="ru" ;;
	esac

	uci set wakemypc.bot.lang="$LANG_CHOICE"
	uci commit wakemypc
	say "→ Язык / Language: $LANG_CHOICE (можно изменить в LuCI)"
fi

# --- 6. Files ---------------------------------------------------------------

mkdir -p /usr/lib/lua/luci/controller \
         /usr/lib/lua/luci/model/cbi \
         /usr/lib/lua/luci/view/wakemypc \
         /usr/lib/wakemypc

say "→ Скачиваю файлы бота и LuCI..."

fetch "$RAW/files/usr/bin/wakemypc" /usr/bin/wakemypc \
	|| die "Не удалось скачать /usr/bin/wakemypc"
fetch "$RAW/files/etc/init.d/wakemypc" /etc/init.d/wakemypc \
	|| die "Не удалось скачать init-скрипт"
fetch "$RAW/files/usr/lib/lua/luci/controller/wakemypc.lua" /usr/lib/lua/luci/controller/wakemypc.lua \
	|| die "Не удалось скачать controller"
fetch "$RAW/files/usr/lib/lua/luci/model/cbi/wakemypc.lua" /usr/lib/lua/luci/model/cbi/wakemypc.lua \
	|| die "Не удалось скачать CBI-модель"
fetch "$RAW/files/usr/lib/lua/luci/view/wakemypc/status.htm" /usr/lib/lua/luci/view/wakemypc/status.htm \
	|| die "Не удалось скачать view/status.htm"
fetch "$RAW/files/root/README.txt" /root/README.txt \
	|| say "⚠️  README.txt не скачан (не критично)"
fetch "$RAW/uninstall.sh" /usr/lib/wakemypc/uninstall.sh \
	|| say "⚠️  uninstall.sh не скачан (удаление из LuCI будет недоступно)"

chmod +x /usr/bin/wakemypc /etc/init.d/wakemypc 2>/dev/null
chmod +x /usr/lib/wakemypc/uninstall.sh 2>/dev/null

# Drop LuCI caches so the new menu entry appears immediately.
rm -f /tmp/luci-indexcache* 2>/dev/null
rm -rf /tmp/luci-modulecache 2>/dev/null

# --- 7. Autostart (but do NOT start) ---------------------------------------

/etc/init.d/wakemypc enable >/dev/null 2>&1

ROUTER_IP=$(uci -q get network.lan.ipaddr)
# On OpenWrt 25.x netifd returns a CIDR value ("192.168.1.1/24").
case "$ROUTER_IP" in
	*/*) ROUTER_IP="${ROUTER_IP%%/*}" ;;
esac
[ -n "$ROUTER_IP" ] || ROUTER_IP="192.168.1.1"

say ""
say "✅ Установлено. / Installed."
say ""
say "   Web UI:  http://${ROUTER_IP}/cgi-bin/luci/admin/services/wakemypc"
say "   Логи:    logread | grep wakemypc"
say ""
say "   Бот НЕ запущен — заполни токен и данные ПК в LuCI, затем нажми Start."
say ""
say "   Если с роутера не проходит: ssh -i /root/.ssh/id_ed25519 USER@PC-IP \"echo ok\""
say "   запусти на ПК от администратора windows/setup-ssh.ps1 (см. README)."
say ""
