# WakeMyPc

[🇬🇧 English](#english) | [🇷🇺 Русский](#русский)

Telegram bot for OpenWrt: turns a home PC **on** (Wake-on-LAN), **off** and
**reboots** it over SSH. Web UI in LuCI, RU/EN.

**What the bot does**

- 🟢 **Status** — checks whether the PC is on (SSH)
- ⏻ **Power on** — sends a magic packet, waits up to 90 s
- 🔌 **Power off** — `shutdown /s /t 5` over SSH
- ♻️ **Reboot** — `shutdown /r /t 5`
- 🔒 **Only you** — one Telegram ID, everyone else is ignored
- 🖥 **No PC needed** — the router does everything, the PC can be off

---

<a name="english"></a>
## English

### Install (router)

```sh
wget -qO- https://raw.githubusercontent.com/griggsdevel/luci-app-wakemypc/main/install.sh | sh
```

OpenWrt 21.02+ · dependencies install themselves · bot does not start by itself.

### Setup in 4 steps

1. **Router:** run the command above.
2. **LuCI:** `Services → WakeMyPc` → fill **Bot Token**, **Telegram ID**, **MAC**,
   **IP**, **LAN interface**, **SSH user** → **Save & Apply**.
3. **PC (Windows):** `Win + X` → **Terminal (Admin)** → paste:
   ```powershell
   irm https://raw.githubusercontent.com/griggsdevel/luci-app-wakemypc/main/windows/setup-ssh.ps1 | iex
   ```
   Wait for `Done` — it prints the `SSH user` and `PC IP` for step 2.
4. **LuCI:** press **▶️ Start** → Telegram → `/start`.

Language: LuCI → **Language** → `Auto (LuCI)` / `Русский` / `English` — applies to
the bot too.

### Bot

| Button / command | Result |
|---|---|
| `/start` | greeting + keyboard |
| `🟢 Status` | `🟢 PC is on (IP)` / `🔴 PC is off` |
| `⏻ Power on` | WOL, waits up to 90 s |
| `🔌 Shut down` | `shutdown /s /t 5` |
| `♻️ Reboot` | `shutdown /r /t 5` |

No notifications unless you enable **Notify when the PC comes online** in LuCI.

### Where to get the values

| Value | Where |
|---|---|
| Bot Token | [BotFather](https://t.me/BotFather) → `/newbot` |
| Telegram ID | [userinfobot](https://t.me/userinfobot) → `/start` |
| MAC / IP | LuCI → **🔎 Find PC** (ARP scan) or the PC's network settings |

### Wake-on-LAN checklist

1. BIOS/UEFI: **Wake on LAN** = Enabled
2. BIOS/UEFI: **ErP** = Disabled
3. Windows: **Fast Startup** = off (`powercfg /h off`)
4. Adapter → Advanced: **Wake on Magic Packet** = Enabled

### Update / uninstall

```sh
wget -qO- https://raw.githubusercontent.com/griggsdevel/luci-app-wakemypc/main/update.sh | sh
wget -qO- https://raw.githubusercontent.com/griggsdevel/luci-app-wakemypc/main/uninstall.sh | sh
```

Uninstall is also in LuCI → **Danger zone** (type `DELETE`).

### If it does not work

| Problem | Fix |
|---|---|
| Bot silent | `logread \| grep wakemypc`; check token + Telegram ID |
| PC shows offline | on the router: `ssh -i /root/.ssh/id_ed25519 USER@IP "echo ok"` must print `ok` |
| WOL does nothing | see the checklist above |
| No menu in LuCI | `apk add luci-lua-runtime luci-compat`, then `rm -f /tmp/luci-indexcache*` |

MIT © 2026 WakeMyPc contributors

---

<a name="русский"></a>
## Русский

Telegram-бот для OpenWrt: включает домашний ПК (Wake-on-LAN), выключает и
перезагружает его по SSH. Веб-интерфейс в LuCI, RU/EN.

**Что делает бот**

- 🟢 **Статус** — проверяет, включён ли ПК (по SSH)
- ⏻ **Включить** — шлёт magic-пакет и ждёт до 90 с
- 🔌 **Выключить** — `shutdown /s /t 5` по SSH
- ♻️ **Перезагрузить** — `shutdown /r /t 5`
- 🔒 **Только ты** — один Telegram ID, остальные игнорируются
- 🖥 **ПК может быть выключен** — всё делает роутер

### Установка (роутер)

```sh
wget -qO- https://raw.githubusercontent.com/griggsdevel/luci-app-wakemypc/main/install.sh | sh
```

OpenWrt 21.02+ · зависимости ставятся сами · бот сам не запускается.

### Настройка из 4 шага

1. **Роутер:** выполни команду выше.
2. **LuCI:** `Services → WakeMyPc` → заполни **Токен бота**, **Telegram ID**,
   **MAC**, **IP**, **LAN-интерфейс**, **SSH-пользователь** → **Сохранить**.
3. **ПК (Windows):** `Win + X` → **Терминал (администратор)** → вставь:
   ```powershell
   irm https://raw.githubusercontent.com/griggsdevel/luci-app-wakemypc/main/windows/setup-ssh.ps1 | iex
   ```
   Дождись `Done` — в конце будут `SSH user` и `PC IP` для шага 2.
4. **LuCI:** нажми **▶️ Запустить** → Telegram → `/start`.

Язык: LuCI → **Язык** → `Авто (как в LuCI)` / `Русский` / `English` — он же язык бота.

### Бот

| Кнопка / команда | Результат |
|---|---|
| `/start` | приветствие + клавиатура |
| `🟢 Статус` | `🟢 ПК включён (IP)` / `🔴 ПК выключен` |
| `⏻ Включить ПК` | WOL, ожидание до 90 с |
| `🔌 Выключить ПК` | `shutdown /s /t 5` |
| `♻️ Перезагрузить ПК` | `shutdown /r /t 5` |

Уведомлений нет, пока не включишь **Уведомлять о включении ПК** в LuCI.

### Где взять данные

| Данные | Где |
|---|---|
| Токен бота | [BotFather](https://t.me/BotFather) → `/newbot` |
| Telegram ID | [userinfobot](https://t.me/userinfobot) → `/start` |
| MAC / IP | LuCI → **🔎 Найти ПК** (ARP-скан) или настройки сети ПК |

### Wake-on-LAN — чек-лист

1. BIOS/UEFI: **Wake on LAN** = Enabled
2. BIOS/UEFI: **ErP** = Disabled
3. Windows: **Быстрый запуск** = выкл (`powercfg /h off`)
4. Драйвер адаптера: **Wake on Magic Packet** = Enabled

### Обновление / удаление

```sh
wget -qO- https://raw.githubusercontent.com/griggsdevel/luci-app-wakemypc/main/update.sh | sh
wget -qO- https://raw.githubusercontent.com/griggsdevel/luci-app-wakemypc/main/uninstall.sh | sh
```

Удалить можно и в LuCI → **Удаление** (ввести `DELETE`).

### Если не работает

| Проблема | Решение |
|---|---|
| Бот молчит | `logread \| grep wakemypc`; проверь токен и Telegram ID |
| ПК «офлайн» | на роутере: `ssh -i /root/.ssh/id_ed25519 USER@IP "echo ok"` должно вывести `ok` |
| WOL не срабатывает | см. чек-лист выше |
| Нет пункта в LuCI | `apk add luci-lua-runtime luci-compat`, затем `rm -f /tmp/luci-indexcache*` |

MIT © 2026 WakeMyPc contributors
