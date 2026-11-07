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

OpenWrt 21.02+ · зависимости ставятся сами (включая `openssh-keygen`) ·
ключ роутера создаётся автоматически · бот сам не запускается.

## Установка (ПК, Windows)

PowerShell **от имени администратора** — одна строка:

```powershell
irm https://raw.githubusercontent.com/griggsdevel/luci-app-wakemypc/main/windows/setup-ssh.ps1 | iex
```

Скрипт сам: включит `OpenSSH Server`, запустит `sshd`, откроет порт 22,
подготовит ключ на роутере, добавит его в `authorized_keys` и проверит связку
роутер → ПК. В конце печатает **SSH user** и **PC IP** для формы в LuCI.
Запускать можно повторно — он ничего не ломает.

С параметрами (если автоопределение не сработало):

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/griggsdevel/luci-app-wakemypc/main/windows/setup-ssh.ps1))) -RouterHost 192.168.1.1 -SshUser user
```

## Про SSH-ключи (частый вопрос)

Ключ живёт **на роутере**, а не на ПК:

| Где | Что лежит |
|---|---|
| Роутер `/root/.ssh/id_ed25519` | приватный ключ (клиент) — один на роутер |
| ПК `administrators_authorized_keys` и `~/.ssh/authorized_keys` | только публичная часть |

Поэтому «одинаковый ключ на каждом ПК» — это нормально и правильно: один и тот
же роутер заходит на разные ПК одним ключом. На каждом ПК лежит лишь его
публичная половина, приватный ключ на ПК копировать не нужно и нельзя.

Другой ключ нужен только если:
- у вас **несколько роутеров** (тогда у каждого свой ключ — удобнее отзывать);
- хотите **изолировать доступ**: отдельный ключ на конкретный ПК, чтобы
  компрометация одного не открывала остальные.

## Настройка из 4 шага

1. **Роутер:** выполни команду выше.
2. **LuCI:** `Services → WakeMyPc` → заполни **Токен бота**, **Telegram ID**,
   **MAC**, **IP**, **LAN-интерфейс**, **SSH-пользователь** → **Сохранить**.
3. **ПК с Windows:** запусти **PowerShell от имени администратора** → вставь:
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
| `Load key ... invalid format` | на роутере `ssh-keygen` — это dropbear. Лечится командой `apk add --no-cache openssh-keygen && ln -sf /usr/libexec/ssh-keygen-openssh /usr/bin/ssh-keygen`, затем перезапустить `setup-ssh.ps1` |
| Ключ 83 байта вместо ~400 | то же: это dropbear-ключ, OpenSSH-клиент его не читает |
| `identity_sign ... do not match public` | рядом с приватным ключом лежит устаревший `.pub`. Лечится: `rm -f /root/.ssh/id_ed25519.pub && ssh-keygen -y -f /root/.ssh/id_ed25519 > /root/.ssh/id_ed25519.pub` |
| WOL не срабатывает | см. чек-лист выше |
| Нет пункта в LuCI | `apk add luci-lua-runtime luci-compat`, затем `rm -f /tmp/luci-indexcache*` |
| Ключ то работает, то нет (RU Windows) | `Match Group administrators` не срабатывает на русской Windows. Скрипт пишет ключ в **оба** файла, но если настраивал вручную — добавь и в `C:\Users\<user>\.ssh\authorized_keys` |

## Вручную (если без скрипта)

1. **Windows 11:** Параметры → Система → Дополнительные компоненты →
   *Просмотреть компоненты* → `OpenSSH Server` → Установить.
2. `Set-Service sshd -StartupType Automatic; Start-Service sshd`
3. На роутере: `apk add --no-cache openssh-keygen` (иначе `ssh-keygen` — dropbear),
   затем `ssh-keygen -t ed25519 -N "" -f /root/.ssh/id_ed25519`,
   `ssh-keygen -y -f /root/.ssh/id_ed25519 > /root/.ssh/id_ed25519.pub` и
   `cat /root/.ssh/id_ed25519.pub` — строку вставить в
   `C:\ProgramData\ssh\administrators_authorized_keys` **и** в
   `C:\Users\<user>\.ssh\authorized_keys`.
4. Проверка с роутера: `ssh -i /root/.ssh/id_ed25519 USER@IP "echo ok"`.

## Удаление

**С ПК** — убирает ровно то, что добавил установщик: ключ роутера,
службу `OpenSSH Server` и правило брандмауэра. ПК при этом не «откатывается»:
твои файлы, ключи и настройки остаются на месте.

```powershell
irm https://raw.githubusercontent.com/griggsdevel/luci-app-wakemypc/main/windows/remove-ssh.ps1 | iex
```

Полезные варианты:

| Ключ | Что делает |
|---|---|
| `-DryRun` | только показать план, ничего не менять |
| `-KeepSshd` | убрать только ключ, SSH-сервер оставить |
| `-All` | снести все ключи из `authorized_keys` (если роутера уже нет) |
| `-Force` | без вопроса подтверждения |

**С роутера:** LuCI → **WakeMyPc** → **Удаление** → введи `DELETE` → «Удалить полностью».

Обновление: LuCI → **WakeMyPc** → кнопка **⬆️ Обновить**, либо
`wget -qO- https://raw.githubusercontent.com/griggsdevel/luci-app-wakemypc/main/update.sh | sh`.

MIT © 2026 WakeMyPc contributors
