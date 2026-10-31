# WakeMyPc

[🇬🇧 English](README.md) | [🇷🇺 Русский](README.ru.md)

Telegram-бот для OpenWrt: включает домашний ПК (Wake-on-LAN), выключает и
перезагружает его по SSH. Веб-интерфейс в LuCI, RU/EN.

**Что делает бот**

- 🟢 **Статус** — проверяет, включён ли ПК (по SSH)
- ⏻ **Включить** — шлёт magic-пакет и ждёт до 90 с
- 🔌 **Выключить** — `shutdown /s /t 5` по SSH
- ♻️ **Перезагрузить** — `shutdown /r /t 5`
- 🔒 **Только ты** — один Telegram ID, остальные игнорируются
- 🖥 **ПК может быть выключен** — всё делает роутер

## Установка (роутер)

```sh
wget -qO- https://raw.githubusercontent.com/griggsdevel/luci-app-wakemypc/main/install.sh | sh
```

OpenWrt 21.02+ · зависимости ставятся сами · бот сам не запускается.

## Настройка из 4 шага

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

## Бот

| Кнопка / команда | Результат |
|---|---|
| `/start` | приветствие + клавиатура |
| `🟢 Статус` | `🟢 ПК включён (IP)` / `🔴 ПК выключен` |
| `⏻ Включить ПК` | WOL, ожидание до 90 с |
| `🔌 Выключить ПК` | `shutdown /s /t 5` |
| `♻️ Перезагрузить ПК` | `shutdown /r /t 5` |

Уведомлений нет, пока не включишь **Уведомлять о включении ПК** в LuCI.

## Где взять данные

| Данные | Где |
|---|---|
| Токен бота | [BotFather](https://t.me/BotFather) → `/newbot` |
| Telegram ID | [userinfobot](https://t.me/userinfobot) → `/start` |
| MAC / IP | LuCI → **🔎 Найти ПК** (ARP-скан) или настройки сети ПК |

## Wake-on-LAN — чек-лист

1. BIOS/UEFI: **Wake on LAN** = Enabled
2. BIOS/UEFI: **ErP** = Disabled
3. Windows: **Быстрый запуск** = выкл (`powercfg /h off`)
4. Драйвер адаптера: **Wake on Magic Packet** = Enabled

## Обновление / удаление

```sh
wget -qO- https://raw.githubusercontent.com/griggsdevel/luci-app-wakemypc/main/update.sh | sh
wget -qO- https://raw.githubusercontent.com/griggsdevel/luci-app-wakemypc/main/uninstall.sh | sh
```

Удалить можно и в LuCI → **Удаление** (ввести `DELETE`).

## Если не работает

| Проблема | Решение |
|---|---|
| Бот молчит | `logread \| grep wakemypc`; проверь токен и Telegram ID |
| ПК «офлайн» | на роутере: `ssh -i /root/.ssh/id_ed25519 USER@IP "echo ok"` должно вывести `ok` |
| WOL не срабатывает | см. чек-лист выше |
| Нет пункта в LuCI | `apk add luci-lua-runtime luci-compat`, затем `rm -f /tmp/luci-indexcache*` |

## Вручную (если без скрипта)

1. **Windows 11:** Параметры → Система → Дополнительные компоненты →
   *Просмотреть компоненты* → `OpenSSH Server` → Установить.
2. `Set-Service sshd -StartupType Automatic; Start-Service sshd`
3. На роутере: `ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519` и
   `cat /root/.ssh/id_ed25519.pub` — строку вставить в
   `C:\ProgramData\ssh\administrators_authorized_keys`.
4. Проверка с роутера: `ssh -i /root/.ssh/id_ed25519 USER@IP "echo ok"`.

MIT © 2026 WakeMyPc contributors
