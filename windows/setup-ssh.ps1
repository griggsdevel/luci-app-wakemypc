<#
.SYNOPSIS
    WakeMyPc - automatic SSH setup for the Windows PC.

.DESCRIPTION
    One command, safe to re-run:

        irm https://raw.githubusercontent.com/griggsdevel/luci-app-wakemypc/main/windows/setup-ssh.ps1 | iex

    What it does:

      1. Elevates itself when started without Administrator rights.
      2. Installs the "OpenSSH Server" optional feature when missing.
      3. Enables sshd (automatic start), starts it, opens the firewall port.
      4. Prepares a VALID OpenSSH key on the router:
           - detects the dropbear stub (/usr/bin/ssh-keygen -> dropbear),
             installs openssh-keygen and repoints the symlink;
           - regenerates a broken / too small private key;
           - always rebuilds ~/.ssh/id_ed25519.pub from the private key,
             so a stale .pub can never shadow the real key again.
      5. Authorizes that key on this PC in BOTH places
         (administrators_authorized_keys and ~/.ssh/authorized_keys),
         because "Match Group administrators" does not match on localized
         Windows builds (Russian: BUILTIN\Администраторы).
      6. Restarts sshd and runs an end-to-end test router -> PC.
      7. Prints SSH user / PC IP for the LuCI form.

.PARAMETER RouterHost
    Router IP. Default: the default gateway of this PC (auto-detected).

.PARAMETER RouterUser
    SSH user on the router. Default: root.

.PARAMETER SshUser
    Windows account the router will log in as. Default: current user.

.PARAMETER Port
    SSH port on this PC. Default: 22.

.PARAMETER NoElevate
    Internal: do not try to re-launch as Administrator.

.EXAMPLE
    irm https://raw.githubusercontent.com/griggsdevel/luci-app-wakemypc/main/windows/setup-ssh.ps1 | iex

.EXAMPLE
    # explicit addresses
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/griggsdevel/luci-app-wakemypc/main/windows/setup-ssh.ps1))) -RouterHost 192.168.1.1 -SshUser user

.NOTES
    Windows 10 / 11 / Server 2019+.  Copyright (c) 2026 WakeMyPc contributors - MIT
#>

[CmdletBinding()]
param(
    [string]$RouterHost = "",
    [string]$RouterUser = "root",
    [string]$SshUser    = $env:USERNAME,
    [int]$Port          = 22,
    [switch]$NoElevate
)

$ErrorActionPreference = "Stop"

$Script:RawUrl = "https://raw.githubusercontent.com/griggsdevel/luci-app-wakemypc/main/windows/setup-ssh.ps1"

function Say($text, $color = "Gray") { Write-Host $text -ForegroundColor $color }
function Step($text) { Write-Host ""; Write-Host "==> $text" -ForegroundColor Cyan }
function Ok($text)   { Write-Host "    OK  $text" -ForegroundColor Green }
function Warn($text) { Write-Host "    !!  $text" -ForegroundColor Yellow }
function Fail($text) { Write-Host "    XX  $text" -ForegroundColor Red }

# Close the script but keep the window readable: the elevated copy runs in its
# own console, and without this it vanishes before the summary is read.
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
        ForEach-Object {
            $alias = (Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue).Name
            [pscustomobject]@{ NextHop = $_.NextHop; Metric = $_.RouteMetric; Alias = $alias }
        } |
        Where-Object { $_.Alias -and $_.Alias -notmatch "VPN|Radmin|WireGuard|TAP|TUN|Tailscale|ZeroTier" }

    $best = $routes | Sort-Object Metric | Select-Object -First 1
    if ($best) { return $best.NextHop }
    return $null
}

function Get-PcIp {
    param([string]$RouterIp)

    if ($RouterIp) {
        $prefix = ($RouterIp -split "\.")[0..2] -join "."
        $ip = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -like "$prefix.*" -and $_.IPAddress -notlike "169.254.*" } |
            Select-Object -First 1 -ExpandProperty IPAddress
        if ($ip) { return $ip }
    }

    $route = Get-NetRoute -DestinationPrefix "0.0.0.0/0" -ErrorAction SilentlyContinue |
        Sort-Object RouteMetric | Select-Object -First 1
    if ($route) {
        return (Get-NetIPAddress -InterfaceIndex $route.InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike "169.254.*" } |
            Select-Object -First 1 -ExpandProperty IPAddress)
    }

    return $null
}

function Test-IsAdminAccount {
    # Localized-safe: look for the well-known Administrators SID, not the name.
    $groups = & "$env:SystemRoot\System32\whoami.exe" /groups 2>$null
    return [bool]($groups -match "S-1-5-32-544")
}

function Set-KeyFileAcl {
    param([string]$Path, [switch]$AdminFile)

    # Names like "Administrators" are localized ("Администраторы"), SIDs are not.
    & icacls.exe $Path /inheritance:r | Out-Null
    if ($AdminFile) {
        & icacls.exe $Path /grant "*S-1-5-32-544:F" "*S-1-5-18:F" | Out-Null
    } else {
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        & icacls.exe $Path /grant "*${sid}:F" "*S-1-5-18:F" | Out-Null
    }
}

function Add-KeyLine {
    param([string]$Path, [string]$Line)

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (-not (Test-Path $Path)) { New-Item -ItemType File -Path $Path -Force | Out-Null }

    $Line = $Line.Trim() -replace "`r", ""
    $body = ($Line -split "\s+")[1]

    $kept = @()
    foreach ($l in @(Get-Content -Path $Path -ErrorAction SilentlyContinue)) {
        $t = ($l -replace "`r", "").Trim()
        if (-not $t) { continue }
        # throw away BOM damage, comments, half-pasted lines
        if ($t -notmatch "^(ssh-ed25519|ssh-rsa|ecdsa-sha2-|sk-ssh-ed25519|sk-ecdsa-)") { continue }
        if ($body -and ($t -match [regex]::Escape($body))) { continue }
        $kept += $t
    }
    $kept += $Line

    Set-Content -Path $Path -Value $kept -Encoding ascii
    return @{ Count = $kept.Count; Added = -not ($kept.Count -lt 1) }
}

function Invoke-RouterSsh {
    param([string]$Command)

    $sshArgs = @(
        '-o', 'StrictHostKeyChecking=accept-new',
        '-o', 'ConnectTimeout=12',
        '-o', 'PreferredAuthentications=publickey,password,keyboard-interactive',
        '-o', 'LogLevel=ERROR',
        "$RouterUser@$RouterHost", $Command
    )

    # Native stderr + $ErrorActionPreference=Stop can throw, so collect it.
    try { $out = @(& ssh @sshArgs 2>&1) } catch { $out = @("$($_.Exception.Message)") }

    # A router that was reflashed has a new host key, while known_hosts still
    # holds the old one -> "Host key verification failed" and no output at all.
    # Drop the stale entry and retry once.
    if (($out -join "`n") -match 'HOST IDENTIFICATION|HOST KEY|Host key verification failed|REMOTE HOST|@@@@@@') {
        Warn "known_hosts holds an old key for $RouterHost (router was reflashed?) - refreshing it"
        & ssh-keygen -R $RouterHost 2>&1 | Out-Null
        & ssh-keygen -R "[$RouterHost]:$Port" 2>&1 | Out-Null
        try { $out = @(& ssh @sshArgs 2>&1) } catch { $out = @("$($_.Exception.Message)") }
    }

    return $out
}

# ---------------------------------------------------------------------------
# 0. Elevation
# ---------------------------------------------------------------------------

if (-not (Test-Admin) -and -not $NoElevate) {
    Say ""
    Say "  Нужны права администратора — перезапускаю с повышением." "Yellow"
    Say "  Administrator rights required - relaunching elevated." "Yellow"
    $inner = "& ([scriptblock]::Create((irm '$Script:RawUrl'))) -RouterHost '$RouterHost' " +
             "-RouterUser '$RouterUser' -SshUser '$SshUser' -Port $Port -NoElevate"
    # One quoted -Command string: Start-Process joins arguments with spaces,
    # so a separate "-Command" + command pair would be split apart.
    # -NoExit keeps the elevated window open, so the summary stays on screen.
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
Say "  WakeMyPc - SSH setup for this Windows PC" "DarkCyan"
Say "==============================================" "DarkCyan"

if (-not (Test-Admin)) {
    Fail "Run as Administrator (right-click PowerShell -> Run as administrator)."
    Quit 1
}
Ok "Running as Administrator"

# ---------------------------------------------------------------------------
# 1. OpenSSH Server
# ---------------------------------------------------------------------------

Step "OpenSSH Server"

$sshdExe = "$env:SystemRoot\System32\OpenSSH\sshd.exe"
if (Test-Path $sshdExe) {
    Ok "already installed"
} else {
    Warn "not installed, adding the optional feature..."
    try {
        $cap = Get-WindowsCapability -Online -Name "OpenSSH.Server*" | Select-Object -First 1
        if ($cap.State -ne "Installed") { Add-WindowsCapability -Online -Name $cap.Name | Out-Null }
        Ok "installed via Windows optional features"
    } catch {
        Warn "optional feature failed: $($_.Exception.Message)"
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            winget install --id Microsoft.OpenSSH.Beta -e --accept-source-agreements --accept-package-agreements | Out-Null
        }
        if (-not (Test-Path $sshdExe)) {
            Fail "Could not install OpenSSH Server automatically."
            Fail "Manual: Settings -> System -> Optional features -> Add a feature -> 'OpenSSH Server'"
            Quit 1
        }
        Ok "installed via winget"
    }
}

# ---------------------------------------------------------------------------
# 2. sshd service + firewall
# ---------------------------------------------------------------------------

Step "sshd service"
Set-Service -Name sshd -StartupType Automatic
if ((Get-Service sshd).Status -ne "Running") { Start-Service sshd }
Ok "state: $((Get-Service sshd).Status), start type: $((Get-Service sshd).StartType)"

Step "Windows Firewall"
$rule = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
if ($rule) {
    Ok "rule 'OpenSSH-Server-In-TCP' already exists"
} else {
    New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort $Port | Out-Null
    Ok "inbound rule created for TCP $Port"
}

# ---------------------------------------------------------------------------
# 3. Addresses
# ---------------------------------------------------------------------------

Step "Addresses"
if (-not $RouterHost) {
    $RouterHost = Get-DefaultRouter
    if (-not $RouterHost) {
        Fail "Could not detect the router. Run again with: -RouterHost 192.168.1.1"
        Quit 1
    }
}
Ok "router: $RouterUser@$RouterHost"

$pcIp = Get-PcIp -RouterIp $RouterHost
if (-not $pcIp) {
    Fail "Could not detect the LAN IP of this PC."
    Quit 1
}
Ok "this PC: $SshUser@$pcIp"

# ---------------------------------------------------------------------------
# 4. Router key (the part that used to break)
# ---------------------------------------------------------------------------

Step "Router SSH key"

$remoteScript = @'
set -u
KEY=/root/.ssh/id_ed25519
mkdir -p /root/.ssh 2>/dev/null
chmod 700 /root/.ssh 2>/dev/null

is_real_openssh() {
    kg=$(command -v ssh-keygen 2>/dev/null) || return 1
    [ -n "$kg" ] || return 1
    tgt=$(readlink -f "$kg" 2>/dev/null || echo "$kg")
    case "$tgt" in *dropbear*) return 1 ;; esac
    return 0
}

if ! is_real_openssh; then
    echo "STEP=install-keygen"
    if command -v apk >/dev/null 2>&1; then
        apk add --no-cache openssh-keygen >/dev/null 2>&1
    elif command -v opkg >/dev/null 2>&1; then
        opkg update >/dev/null 2>&1
        opkg install openssh-keygen >/dev/null 2>&1
    fi
    for cand in /usr/libexec/ssh-keygen-openssh /usr/bin/ssh-keygen-openssh; do
        [ -x "$cand" ] && ln -sf "$cand" /usr/bin/ssh-keygen
    done
fi

# Never create a key with the dropbear stub: it writes an 83-byte file that the
# OpenSSH client cannot read. Stop and let the caller explain what to install.
if ! is_real_openssh; then
    echo "KEYGEN=dropbear"
    echo "KEYSIZE=0"
    echo "PUBKEY="
    exit 0
fi

valid_key() {
    [ -f "$1" ] || return 1
    sz=$(wc -c < "$1" 2>/dev/null || echo 0)
    [ "$sz" -gt 200 ] || return 1
    head -1 "$1" 2>/dev/null | grep -q 'BEGIN OPENSSH PRIVATE KEY' || return 1
    ssh-keygen -y -f "$1" >/dev/null 2>&1 || return 1
    return 0
}

if ! valid_key "$KEY"; then
    echo "STEP=generate-key"
    rm -f "$KEY" "$KEY.pub"
    ssh-keygen -t ed25519 -N '' -f "$KEY" >/dev/null 2>&1 || true
fi

chmod 600 "$KEY" 2>/dev/null

# Always rebuild .pub from the private key: a stale .pub makes ssh offer a
# key it cannot sign with ("identity_sign ... do not match public").
rm -f "$KEY.pub"
ssh-keygen -y -f "$KEY" > "$KEY.pub" 2>/dev/null || true
chmod 644 "$KEY.pub" 2>/dev/null

echo "KEYSIZE=$(wc -c < "$KEY" 2>/dev/null || echo 0)"
echo "KEYGEN=$(readlink -f "$(command -v ssh-keygen 2>/dev/null)" 2>/dev/null || echo unknown)"
echo "PUBKEY=$(cat "$KEY.pub" 2>/dev/null)"
'@

# The remote shell must get LF endings: CRLF breaks "set -u" and every command.
$remoteScript = ($remoteScript -replace [char]13, '')

$routerOut = @()
try { $routerOut = @(Invoke-RouterSsh -Command $remoteScript) } catch { $routerOut = @() }

if ($routerOut -match "STEP=install-keygen") { Warn "dropbear ssh-keygen found -> installed openssh-keygen on the router" }
if ($routerOut -match "STEP=generate-key")   { Warn "router key was missing/invalid -> generated a new one" }

# The remote side prints "PUBKEY=ssh-ed25519 ...": strip the prefix, and keep
# a fallback for a bare "ssh-..." line in case the remote script changes.
$pubKey  = ($routerOut | Where-Object { $_ -match "^PUBKEY=ssh-" } | Select-Object -First 1)
if ($pubKey) { $pubKey = $pubKey -replace '^PUBKEY=', '' }
if (-not $pubKey) {
    $pubKey = ($routerOut | Where-Object { $_ -match "^ssh-" } | Select-Object -First 1)
}
$keySize = ($routerOut | Where-Object { $_ -match "^KEYSIZE=" } | Select-Object -First 1) -replace "^KEYSIZE=", ""
$keyGen  = ($routerOut | Where-Object { $_ -match "^KEYGEN=" } | Select-Object -First 1) -replace "^KEYGEN=", ""

if ($keyGen -eq "dropbear") {
    Fail "The router's ssh-keygen is a dropbear stub - it cannot create OpenSSH keys."
    Fail "Run these two commands on the router, then start this script again:"
    Fail "  apk add --no-cache openssh-keygen"
    Fail "  ln -sf /usr/libexec/ssh-keygen-openssh /usr/bin/ssh-keygen"
    Quit 1
}
if (-not $pubKey) {
    Fail "Could not read the router public key."
    $routerOut | Select-Object -Last 8 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkYellow }
    Fail "Check that SSH to the router works:  ssh $RouterUser@$RouterHost"
    Fail "Or paste the key manually (see README)."
    Quit 1
}

if ($keySize -and [int]$keySize -le 200) {
    Fail "Router key is only $keySize bytes - that is a dropbear key, not OpenSSH."
    Fail "Run once on the router:"
    Fail "  apk add --no-cache openssh-keygen"
    Fail "  ln -sf /usr/libexec/ssh-keygen-openssh /usr/bin/ssh-keygen"
    Fail "then run this script again."
    Quit 1
}

Ok "public key: $($pubKey.Substring(0, [Math]::Min(44, $pubKey.Length)))..."
if ($keySize) { Ok "private key size: $keySize bytes" }

# ---------------------------------------------------------------------------
# 5. Authorize the key on Windows (both files)
# ---------------------------------------------------------------------------

Step "Authorized keys"

$userFile  = Join-Path $env:USERPROFILE ".ssh\authorized_keys"
$authFiles = @($userFile)
if (Test-IsAdminAccount) {
    $adminFile = "$env:ProgramData\ssh\administrators_authorized_keys"
    $authFiles += $adminFile
    Ok "account is an Administrator (SID S-1-5-32-544) -> writing both files"
} else {
    Ok "regular account -> user file only"
}

foreach ($file in $authFiles) {
    Add-KeyLine -Path $file -Line $pubKey | Out-Null
    $isAdminFile = ($file -like "*ProgramData*")
    Set-KeyFileAcl -Path $file -AdminFile:$isAdminFile
    Ok "key written: $file"
}

Restart-Service sshd
Ok "sshd restarted"

# Which file sshd really reads (localized "Match Group" may not fire).
$akf = $null
if (Test-Path $sshdExe) {
    $t = & $sshdExe -T -C "user=$SshUser,host=$pcIp,addr=$pcIp" 2>$null
    $line = $t | Select-String -Pattern "^authorizedkeysfile" | Select-Object -First 1
    if ($line) { $akf = $line.ToString().Trim() }
}
if ($akf) { Say "    sshd uses: $akf" "DarkGray" }

# ---------------------------------------------------------------------------
# 6. End-to-end test
# ---------------------------------------------------------------------------

Step "End-to-end test from the router"
Start-Sleep -Seconds 2

$testCmd = "ssh -i /root/.ssh/id_ed25519 -o BatchMode=yes -o IdentitiesOnly=yes " +
           "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null " +
           "-o LogLevel=ERROR -o ConnectTimeout=8 $SshUser@$pcIp 'echo ok'"

$result = @()
try { $result = @(Invoke-RouterSsh -Command $testCmd) } catch { $result = @("$($_.Exception.Message)") }

if (($result -join " ") -match "ok") {
    Ok "router -> PC works"
} else {
    Fail "test failed"
    $result | Select-Object -Last 6 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkYellow }

    Warn "collecting details..."
    $diag = "ssh -vv -i /root/.ssh/id_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes " +
            "-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null $SshUser@$pcIp 'echo ok' 2>&1 " +
            "| grep -Ei 'offer|accept|denied|invalid|signature|load key|authentications' | head -20"
    try {
        Invoke-RouterSsh -Command $diag | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
    } catch { }

    if ($akf -and $akf -match "administrators_authorized_keys" -and -not (Test-IsAdminAccount)) {
        Warn "sshd expects administrators_authorized_keys, but this is a regular account."
    }
    Warn "Check: Get-Content '$userFile'"
    if ($adminFile) { Warn "Check: Get-Content '$adminFile'" }
}

# ---------------------------------------------------------------------------
# 7. Summary
# ---------------------------------------------------------------------------

Say ""
Say "==============================================" "DarkCyan"
Say "  Done" "DarkCyan"
Say "==============================================" "DarkCyan"
Say ""
Say "  SSH user for the WakeMyPc web form: $SshUser"
Say "  PC IP:                              $pcIp"
Say "  Router key:                         /root/.ssh/id_ed25519"
Say ""
Say "  LuCI -> Services -> WakeMyPc:"
Say "    SSH user   : $SshUser"
Say "    IP address : $pcIp"
Say "  then Save & Apply and Start."
Say ""

# The console may be about to close - do not let the summary disappear.
if ($Host.Name -eq 'ConsoleHost') {
    Say ""
    Say "  Нажми Enter, чтобы закрыть окно / Press Enter to close" "DarkGray"
    [void](Read-Host)
}
