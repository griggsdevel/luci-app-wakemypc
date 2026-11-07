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

pkg_installed() {
	if [ "$PKG" = "apk" ]; then
		apk info -e "$1" >/dev/null 2>&1
	else
		opkg list-installed 2>/dev/null | grep -q "^$1 "
	fi
}

# Install and then check by presence, not by exit code. On some routers apk
# exits non-zero because unrelated pinned entries in /etc/apk/world cannot be
# resolved ("2 errors"), even though every package we asked for is in place.
# Trusting the exit code there aborts a perfectly good install.
pkg_ensure() {
	_ok=1
	for _p in "$@"; do
		pkg_installed "$_p" || _ok=0
	done
	[ "$_ok" = 1 ] && return 0

	pkg_install "$@" >/dev/null 2>&1 || true

	for _p in "$@"; do
		pkg_installed "$_p" || return 1
	done
	return 0
}

# On OpenWrt /usr/bin/ssh-keygen is usually a symlink to dropbear. Dropbear
# writes keys in its own binary format (83 bytes), which the OpenSSH client on
# the same router cannot read: "Load key ... invalid format". That is why the
# router must use the real openssh-keygen.
ensure_openssh_keygen() {
	_kg=$(command -v ssh-keygen 2>/dev/null || true)
	_real=1
	if [ -z "$_kg" ]; then
		_real=0
	else
		case "$(readlink -f "$_kg" 2>/dev/null || echo "$_kg")" in
			*dropbear*) _real=0 ;;
		esac
	fi
	[ "$_real" = 1 ] && return 0

	say "→ ssh-keygen указывает на dropbear — ставлю настоящий openssh-keygen..."
	pkg_update
	pkg_install openssh-keygen >/dev/null 2>&1 || true
	for _c in /usr/libexec/ssh-keygen-openssh /usr/bin/ssh-keygen-openssh; do
		[ -x "$_c" ] && ln -sf "$_c" /usr/bin/ssh-keygen
	done

	if command -v ssh-keygen >/dev/null 2>&1; then
		case "$(readlink -f "$(command -v ssh-keygen)" 2>/dev/null || true)" in
			*dropbear*) say "⚠️  Не удалось подменить ssh-keygen — ключ создай на ПК (setup-ssh.ps1)" ;;
			*) say "→ openssh-keygen установлен" ;;
		esac
	fi
}

# A usable key is a real OpenSSH private key, not a 83-byte dropbear stub.
key_is_valid() {
	[ -f "$1" ] || return 1
	_sz=$(wc -c < "$1" 2>/dev/null || echo 0)
	[ "$_sz" -gt 200 ] || return 1
	head -1 "$1" 2>/dev/null | grep -q 'BEGIN OPENSSH PRIVATE KEY' || return 1
	ssh-keygen -y -f "$1" >/dev/null 2>&1 || return 1
	return 0
}

# LuCI detection works both for the Lua (<= 24.10) and ucode (25.x) era.
luci_present() {
	[ -e /www/cgi-bin/luci ] || [ -f /etc/config/luci ]
}

# --- 3. Dependencies --------------------------------------------------------

say "→ Устанавливаю зависимости: curl jq etherwake openssh-client openssh-keygen"
pkg_update
pkg_ensure curl jq etherwake openssh-client \
	|| die "Не удалось установить зависимости (curl jq etherwake openssh-client)."
pkg_ensure openssh-keygen \
	|| say "⚠️  Пакет openssh-keygen недоступен — ключ можно создать на ПК."
ensure_openssh_keygen

# --- 4. LuCI check ----------------------------------------------------------

if ! luci_present; then
	say ""
	say "⚠️  LuCI не найден — веб-интерфейс работать не будет."
	ask "   Установить LuCI сейчас? (y/N) "
	case "$ans" in
		y|yes)
			say "→ Устанавливаю LuCI (это может занять пару минут)..."
			pkg_update
			pkg_ensure luci || say "⚠️  Не удалось установить luci, продолжаю без него."
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
			pkg_ensure "$extra" >/dev/null 2>&1 \
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
fetch "$RAW/files/usr/lib/lua/luci/view/wakemypc/theme.htm" /usr/lib/lua/luci/view/wakemypc/theme.htm \
	|| say "⚠️  theme.htm не скачан — страница будет без оформления"
fetch "$RAW/files/root/README.txt" /root/README.txt \
	|| say "⚠️  README.txt не скачан (не критично)"
fetch "$RAW/uninstall.sh" /usr/lib/wakemypc/uninstall.sh \
	|| say "⚠️  uninstall.sh не скачан (удаление из LuCI будет недоступно)"
fetch "$RAW/update.sh" /usr/lib/wakemypc/update.sh \
	|| say "⚠️  update.sh не скачан (кнопка обновления в LuCI будет недоступна)"

chmod +x /usr/bin/wakemypc /etc/init.d/wakemypc 2>/dev/null
chmod +x /usr/lib/wakemypc/uninstall.sh 2>/dev/null
chmod +x /usr/lib/wakemypc/update.sh 2>/dev/null

# Drop LuCI caches so the new menu entry appears immediately.
rm -f /tmp/luci-indexcache* 2>/dev/null
rm -rf /tmp/luci-modulecache 2>/dev/null

# --- 6b. SSH key for PC control --------------------------------------------
# The router is the SSH client; it must own an OpenSSH private key. We create
# it here so setup-ssh.ps1 on the PC only has to read the public part.

KEY=/root/.ssh/id_ed25519
mkdir -p /root/.ssh
chmod 700 /root/.ssh

if ! key_is_valid "$KEY"; then
	if [ -f "$KEY" ]; then
		say "→ Ключ роутера битый ($(wc -c < "$KEY" 2>/dev/null || echo 0) байт) — пересоздаю"
		rm -f "$KEY" "$KEY.pub"
	fi
	if ssh-keygen -t ed25519 -N '' -f "$KEY" >/dev/null 2>&1; then
		say "→ Создан SSH-ключ роутера: $KEY"
	else
		say "⚠️  Не удалось создать ключ на роутере — его создаст setup-ssh.ps1 на ПК."
	fi
fi

if [ -f "$KEY" ]; then
	chmod 600 "$KEY" 2>/dev/null
	# Always rebuild .pub from the private key: a stale .pub makes ssh offer a
	# key it cannot sign with ("identity_sign ... do not match public").
	rm -f "$KEY.pub"
	ssh-keygen -y -f "$KEY" > "$KEY.pub" 2>/dev/null || true
	chmod 644 "$KEY.pub" 2>/dev/null
fi

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
say "   1) ПК — открой PowerShell от администратора и вставь ОДНУ строку:"
say ""
say "      irm ${RAW}/windows/setup-ssh.ps1 | iex"
say ""
say "      Скрипт включит sshd, положит ключ роутера и напечатает SSH user + PC IP."
say ""
say "   2) LuCI:  http://${ROUTER_IP}/cgi-bin/luci/admin/services/wakemypc"
say "      Заполни токен бота, Telegram ID, MAC, IP, SSH user → Save & Apply → ▶️ Start."
say ""
say "   3) Telegram → /start"
say ""
say "   Логи:    logread | grep wakemypc"
say "   Проверка: ssh -i /root/.ssh/id_ed25519 USER@PC-IP \"echo ok\""
say ""
if [ -f "$KEY.pub" ]; then
	say "   Публичный ключ роутера (если настраиваешь ПК вручную):"
	say "   $(cat "$KEY.pub")"
	say ""
fi
say "   Бот НЕ запущен — это нормально, запусти его кнопкой Start в LuCI."
say ""
