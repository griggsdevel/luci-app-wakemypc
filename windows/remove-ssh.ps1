<#
.SYNOPSIS
    WakeMyPc - remove what setup-ssh.ps1 added to this Windows PC.

.DESCRIPTION
    Removes exactly the artifacts of windows/setup-ssh.ps1 and nothing else:

      * the router's public key from
        C:\Users\<user>\.ssh\authorized_keys and
        C:\ProgramData\ssh\administrators_authorized_keys;
      * those files when they become empty, and the .ssh folder after them;
      * the sshd service: stopped and its autostart disabled;
      * the firewall rule "OpenSSH-Server-In-TCP";
      * the "OpenSSH Server" optional feature that the installer turned on.

    Your own keys, files, settings and other services are not touched.
    With -KeepSshd only the key is removed and the SSH server stays as it is.

.PARAMETER RouterHost
    Router address. Auto-detected from the default gateway when omitted.

.PARAMETER RouterUser
    SSH user on the router. Default: root.

.PARAMETER SshUser
    Windows account whose authorized_keys are cleaned. Default: current user.

.PARAMETER Port
    SSH port on the router. Default: 22.

.PARAMETER All
    Remove ALL keys from both authorized_keys files, not just the router key.
    Use when the router is gone and its key cannot be fetched.

.PARAMETER PublicKey
    Remove this exact key instead of asking the router.

.PARAMETER KeepSshd
    Do not touch the SSH server: only the key is removed.

.PARAMETER Force
    Do not ask for confirmation.

.PARAMETER DryRun
    Only show what would be removed. Makes no changes, needs no admin rights.

.PARAMETER NoElevate
    Internal: do not re-launch as Administrator.

.EXAMPLE
    irm https://raw.githubusercontent.com/griggsdevel/luci-app-wakemypc/main/windows/remove-ssh.ps1 | iex

.EXAMPLE
    Same, but keep the SSH server and remove only the router key:
    add -KeepSshd

.NOTES
    Windows 10 / 11 / Server 2019+.  Copyright (c) 2026 WakeMyPc contributors - MIT
#>

[CmdletBinding()]
param(
    [string]$RouterHost = "",
    [string]$RouterUser = "root",
    [string]$SshUser    = $env:USERNAME,
    [int]$Port          = 22,
    [switch]$All,
    [string]$PublicKey  = "",
    [switch]$KeepSshd,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$NoElevate
)

$ErrorActionPreference = "Stop"

$Script:RawUrl = "https://raw.githubusercontent.com/griggsdevel/luci-app-wakemypc/main/windows/remove-ssh.ps1"

function Say($text, $color = "Gray") { Write-Host $text -ForegroundColor $color }
function Step($text) { Write-Host ""; Write-Host "==> $text" -ForegroundColor Cyan }
function Ok($text)   { Write-Host "    OK  $text" -ForegroundColor Green }
function Warn($text) { Write-Host "    !!  $text" -ForegroundColor Yellow }
function Fail($text) { Write-Host "    XX  $text" -ForegroundColor Red }

# Close the script but keep the window readable.
function Quit([int]$code = 0) {
    if ($Host.Name -eq 'ConsoleHost' -and -not $env:WAKEMYPC_NO_PAUSE) {
        Write-Host ""
        Write-Host "  Нажми Enter, чтобы закрыть окно / Press Enter to close" -ForegroundColor DarkGray
        [void](Read-Host)
    }
    exit $code
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-DefaultRouter {
    $routes = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -ne "0.0.0.0" } |
        Sort-Object RouteMetric
    foreach ($r in $routes) {
        if ($r.NextHop -match '^\d+\.\d+\.\d+\.\d+$' -and $r.NextHop -ne "0.0.0.0") { return $r.NextHop }
    }
    return $null
}

function Invoke-RouterSsh {
    param([string]$Command)

    $sshArgs = @(
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'ConnectTimeout=8',
        '-o', 'PreferredAuthentications=publickey,password,keyboard-interactive',
        '-o', 'LogLevel=ERROR',
        "$RouterUser@$RouterHost", $Command
    )

    try { $out = @(& ssh @sshArgs 2>&1) } catch { $out = @("$($_.Exception.Message)") }

    if (($out -join "`n") -match 'HOST IDENTIFICATION HAS CHANGED|Host key verification failed') {
        Warn "known_hosts holds an old key for $RouterHost - refreshing"
        & ssh-keygen -R $RouterHost 2>&1 | Out-Null
        try { $out = @(& ssh @sshArgs 2>&1) } catch { $out = @("$($_.Exception.Message)") }
    }

    return $out
}

# Remove matching lines from one authorized_keys file. Returns the count.
function Remove-KeyLines {
    param([string]$Path, [string]$Body)

    if (-not (Test-Path $Path)) { return 0 }

    $kept = @()
    $removed = 0

    foreach ($l in @(Get-Content -Path $Path -ErrorAction SilentlyContinue)) {
        $t = ($l -replace "`r", "").Trim()
        if (-not $t) { continue }
        if ($All -or ($Body -and $t -match [regex]::Escape($Body))) {
            $removed++
            continue
        }
        $kept += $t
    }

    if ($removed -gt 0 -and -not $DryRun) {
        if ($kept.Count -gt 0) {
            Set-Content -Path $Path -Value $kept -Encoding ascii
        } else {
            # The file only carried our key: drop it, like before the install.
            Remove-Item -Path $Path -Force -ErrorAction SilentlyContinue
        }
    }

    return $removed
}

# ---------------------------------------------------------------------------
# 0. Elevation
# ---------------------------------------------------------------------------

if (-not $DryRun -and -not (Test-Admin) -and -not $NoElevate) {
    Say ""
    Say "  Нужны права администратора — перезапускаю с повышением." "Yellow"
    Say "  Administrator rights required - relaunching elevated." "Yellow"

    $inner = "& ([scriptblock]::Create((irm '$Script:RawUrl'))) -RouterHost '$RouterHost' " +
             "-RouterUser '$RouterUser' -SshUser '$SshUser' -Port $Port -NoElevate" +
             $(if ($All) { " -All" } else { "" }) +
             $(if ($PublicKey) { " -PublicKey '$PublicKey'" } else { "" }) +
             $(if ($KeepSshd) { " -KeepSshd" } else { "" }) +
             $(if ($Force) { " -Force" } else { "" })

    $argLine = "-NoProfile -ExecutionPolicy Bypass -NoExit -Command `"$inner`""

    try {
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $argLine | Out-Null
    } catch {
        Fail "Не удалось повысить права. Запусти PowerShell от имени администратора."
        return
    }

    Say ""
    Say "  Дальше работа идёт в новом окне с правами администратора." "Yellow"
    Say "  Continue in the elevated window - it stays open when finished." "Yellow"
    return
}

Say ""
Say "==============================================" "DarkCyan"
Say "  WakeMyPc - remove what the installer added" "DarkCyan"
Say "==============================================" "DarkCyan"

if ($DryRun) { Warn "DRY RUN: nothing will be changed." }

$userFile  = Join-Path $env:USERPROFILE ".ssh\authorized_keys"
$adminFile = "$env:ProgramData\ssh\administrators_authorized_keys"
$files     = @($userFile)
if (Test-Path $adminFile) { $files += $adminFile }

# ---------------------------------------------------------------------------
# 1. Which key to remove
# ---------------------------------------------------------------------------

$keyLine = ""

if ($PublicKey) {
    $keyLine = $PublicKey.Trim()
    Ok "key given on the command line"
}
elseif ($All) {
    Warn "ALL keys will be removed from both files"
}
else {
    if (-not $RouterHost) { $RouterHost = Get-DefaultRouter }
    if (-not $RouterHost) {
        Fail "Could not detect the router."
        Fail "Run again with -RouterHost 192.168.1.1 - or use -All to wipe every key."
        Quit 1
    }

    Step "Router key"
    Ok "router: $RouterUser@$RouterHost"

    $remote = "ssh-keygen -y -f /root/.ssh/id_ed25519 2>/dev/null || cat /root/.ssh/id_ed25519.pub 2>/dev/null"
    $out = @(Invoke-RouterSsh -Command $remote)
    $keyLine = ($out | Where-Object { $_ -match "^ssh-" } | Select-Object -First 1)

    if (-not $keyLine) {
        Fail "Could not read the router public key."
        Fail "If the router is gone, wipe every key instead:  -All"
        Fail "Or pass the key explicitly:  -PublicKey 'ssh-ed25519 AAAA... user@host'"
        Quit 1
    }

    Ok "key: $($keyLine.Substring(0, [Math]::Min(44, $keyLine.Length)))..."
}

$keyBody = ""
if ($keyLine) { $keyBody = ($keyLine -split "\s+")[1] }

# ---------------------------------------------------------------------------
# 2. Confirm
# ---------------------------------------------------------------------------

if (-not $Force -and -not $DryRun) {
    Say ""
    Say "  Будет удалено только то, что добавил setup-ssh.ps1:" "Yellow"
    Say "    - ключ роутера в authorized_keys (файлы, ставшие пустыми, удаляются)"
    if (-not $KeepSshd) {
        Say "    - служба sshd остановлена, автозапуск выключен"
        Say "    - правило брандмауэра OpenSSH-Server-In-TCP удалено"
        Say "    - компонент Windows 'OpenSSH Server' удалён"
    } else {
        Say "    - SSH-сервер остаётся включённым (-KeepSshd)"
    }
    Say ""
    Say "  Твои ключи, файлы и настройки не трогаются."
    Say ""
    Say "  Продолжить? / Continue? (y/N) " "Yellow"
    $answer = ""
    try { $answer = (Read-Host).Trim().ToLower() } catch { }
    if ($answer -ne "y" -and $answer -ne "yes" -and $answer -ne "д" -and $answer -ne "да") {
        Say "  Отменено / Cancelled." "Yellow"
        Quit 0
    }
}

# ---------------------------------------------------------------------------
# 3. Remove the key
# ---------------------------------------------------------------------------

Step "Authorized keys"

$total = 0
foreach ($f in $files) {
    if (-not (Test-Path $f)) {
        Say "    --  $f  (нет файла)" "DarkGray"
        continue
    }

    $before = @(Get-Content -Path $f -ErrorAction SilentlyContinue | Where-Object { $_.Trim() }).Count
    $removed = Remove-KeyLines -Path $f -Body $keyBody
    $total += $removed

    if ($DryRun) {
        Ok "$f : было $before, будет удалено $removed"
    } else {
        Ok "$f : удалено $removed из $before"
    }
}

if ($total -eq 0) {
    Warn "Подходящих ключей не найдено — возможно, доступ уже закрыт."
}

# Drop the .ssh folder when nothing is left in it.
$sshDir = Join-Path $env:USERPROFILE ".ssh"
if (-not $DryRun -and (Test-Path $sshDir)) {
    $left = @(Get-ChildItem -Path $sshDir -Force -ErrorAction SilentlyContinue)
    if ($left.Count -eq 0) {
        Remove-Item -Path $sshDir -Force -ErrorAction SilentlyContinue
        Ok "пустая папка .ssh удалена"
    } elseif ($total -gt 0) {
        Say "    --  в .ssh остались другие файлы, папка сохранена" "DarkGray"
    }
}

# ---------------------------------------------------------------------------
# 4. SSH server: stop, disable, uninstall
# ---------------------------------------------------------------------------

if (-not $KeepSshd) {
    Step "SSH server"

    if ($DryRun) {
        Ok "would stop sshd and disable its autostart"
        Ok "would remove firewall rule OpenSSH-Server-In-TCP"
        Ok "would uninstall the OpenSSH.Server capability"
    }
    else {
        if (Get-Service sshd -ErrorAction SilentlyContinue) {
            try { Stop-Service sshd -Force -ErrorAction Stop; Ok "sshd остановлен" } catch { Warn "sshd уже не запущен" }
        } else {
            Say "    --  служба sshd не найдена" "DarkGray"
        }

        $rule = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
        if ($rule) {
            Remove-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
            Ok "правило брандмауэра удалено"
        } else {
            Say "    --  правила брандмауэра нет" "DarkGray"
        }

        $cap = Get-WindowsCapability -Online -Name "OpenSSH.Server*" -ErrorAction SilentlyContinue
        if ($cap -and $cap.State -eq "Installed") {
            try {
                Remove-WindowsCapability -Online -Name $cap.Name -ErrorAction Stop | Out-Null
                Ok "компонент удалён: $($cap.Name)"
            } catch {
                Warn "не удалось удалить компонент: $($_.Exception.Message)"
            }
        } else {
            Say "    --  компонент OpenSSH Server не установлен" "DarkGray"
        }
    }
}

# ---------------------------------------------------------------------------
# 5. Summary
# ---------------------------------------------------------------------------

Say ""
Say "==============================================" "DarkCyan"
Say $(if ($DryRun) { "  Dry run finished" } else { "  Готово / Done" }) "DarkCyan"
Say "==============================================" "DarkCyan"
Say ""
Say "  Ключ роутера: удалён (файлов затронуто: $($files.Count))"
Say "  SSH-сервер:   $(if ($KeepSshd) { 'оставлен как есть' } else { 'остановлен и удалён' })"
Say ""
Say "  Убрано ровно то, что добавил setup-ssh.ps1: бот больше не может зайти на ПК по SSH."
Say "  Ключ роутера остался на роутере (/root/.ssh/id_ed25519) - он никому не мешает."
Say ""
Say "  Чтобы снова включить управление ПК, запусти windows/setup-ssh.ps1."
Say ""

if ($Host.Name -eq 'ConsoleHost') {
    Say ""
    Say "  Нажми Enter, чтобы закрыть окно / Press Enter to close" "DarkGray"
    [void](Read-Host)
}
