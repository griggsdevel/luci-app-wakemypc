<#
.SYNOPSIS
    WakeMyPc - automatic SSH setup for the Windows PC.

.DESCRIPTION
    Does everything needed so that the router can log into this PC with a key:

      1. Installs the "OpenSSH Server" optional feature when it is missing.
      2. Enables the sshd service (automatic start) and starts it.
      3. Allows port 22 through the Windows Firewall.
      4. Makes sure the router has an SSH key (/root/.ssh/id_ed25519).
      5. Reads the router public key over SSH and authorizes it on this PC
         (administrators_authorized_keys for admins, authorized_keys otherwise).
      6. Tests the whole chain from the router: ssh user@this-pc "echo ok".

    Safe to run multiple times - every step is checked first.

.PARAMETER RouterHost
    Router IP. Default: the default gateway of this PC (auto-detected).

.PARAMETER RouterUser
    SSH user on the router. Default: root.

.PARAMETER SshUser
    Windows account the router will log in as. Default: current user.

.PARAMETER Port
    SSH port on this PC. Default: 22.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-ssh.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\setup-ssh.ps1 -RouterHost 192.168.1.1 -SshUser user

.NOTES
    Run as Administrator. Windows 10 / 11 / Server 2019+.
    Copyright (c) 2026 WakeMyPc contributors - MIT
#>

[CmdletBinding()]
param(
    [string]$RouterHost = "",
    [string]$RouterUser = "root",
    [string]$SshUser    = $env:USERNAME,
    [int]$Port          = 22
)

$ErrorActionPreference = "Stop"

function Say($text, $color = "Gray") { Write-Host $text -ForegroundColor $color }
function Step($text) { Write-Host ""; Write-Host "==> $text" -ForegroundColor Cyan }
function Ok($text)   { Write-Host "    OK  $text" -ForegroundColor Green }
function Warn($text) { Write-Host "    !!  $text" -ForegroundColor Yellow }
function Fail($text) { Write-Host "    XX  $text" -ForegroundColor Red }

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
    $groups = & "$env:SystemRoot\System32\whoami.exe" /groups 2>$null
    return [bool]($groups -match "S-1-5-32-544")
}

function Add-LineToFile {
    param([string]$Path, [string]$Line)

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    if (-not (Test-Path $Path)) { New-Item -ItemType File -Path $Path -Force | Out-Null }

    $existing = Get-Content -Path $Path -ErrorAction SilentlyContinue
    $keyBody = ($Line -split " ")[1]

    foreach ($l in $existing) {
        if ($l -match [regex]::Escape($keyBody)) {
            return $false
        }
    }

    Add-Content -Path $Path -Value $Line -Encoding ascii
    return $true
}

Say ""
Say "==============================================" "DarkCyan"
Say "  WakeMyPc - SSH setup for this Windows PC" "DarkCyan"
Say "==============================================" "DarkCyan"
Say ""

# --- 0. Admin rights --------------------------------------------------------

if (-not (Test-Admin)) {
    Fail "Run this script as Administrator (right-click PowerShell -> Run as administrator)."
    exit 1
}
Ok "Running as Administrator"

# --- 1. OpenSSH Server ------------------------------------------------------

Step "OpenSSH Server"

$sshdExe = "$env:SystemRoot\System32\OpenSSH\sshd.exe"
if (Test-Path $sshdExe) {
    Ok "already installed ($sshdExe)"
} else {
    Warn "not installed, adding the optional feature..."
    try {
        $cap = Get-WindowsCapability -Online -Name "OpenSSH.Server*" | Select-Object -First 1
        if ($cap.State -ne "Installed") {
            Add-WindowsCapability -Online -Name $cap.Name | Out-Null
        }
        Ok "installed via Windows optional features"
    } catch {
        Warn "optional feature failed: $($_.Exception.Message)"
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Say "    trying winget..." "DarkGray"
            winget install --id Microsoft.OpenSSH.Beta -e --accept-source-agreements --accept-package-agreements
        }
        if (-not (Test-Path $sshdExe)) {
            Fail "Could not install OpenSSH Server automatically."
            Fail "Manual: Settings -> System -> Optional features -> Add a feature -> 'OpenSSH Server' -> Install"
            exit 1
        }
        Ok "installed via winget"
    }
}

# --- 2. sshd service --------------------------------------------------------

Step "sshd service"

Set-Service -Name sshd -StartupType Automatic
if ((Get-Service sshd).Status -ne "Running") { Start-Service sshd }
Ok "state: $((Get-Service sshd).Status), start type: $((Get-Service sshd).StartType)"

# --- 3. Firewall ------------------------------------------------------------

Step "Windows Firewall"

$rule = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue
if ($rule) {
    Ok "rule 'OpenSSH-Server-In-TCP' already exists"
} else {
    New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" `
        -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort $Port | Out-Null
    Ok "inbound rule created for TCP $Port"
}

# --- 4. Router address ------------------------------------------------------

Step "Router"

if (-not $RouterHost) {
    $RouterHost = Get-DefaultRouter
    if (-not $RouterHost) {
        Fail "Could not detect the router. Run again with: -RouterHost 192.168.1.1"
        exit 1
    }
}
Ok "router: $RouterUser@$RouterHost"

$pcIp = Get-PcIp -RouterIp $RouterHost
if (-not $pcIp) {
    Fail "Could not detect the LAN IP of this PC."
    exit 1
}
Ok "this PC: $SshUser@$pcIp"

# --- 5. Router key ----------------------------------------------------------

Step "Router SSH key"

$remoteCmd = "test -f /root/.ssh/id_ed25519 || ssh-keygen -t ed25519 -N '' -f /root/.ssh/id_ed25519 >/dev/null 2>&1; cat /root/.ssh/id_ed25519.pub"

$pubKey = $null
try {
    $pubKey = & ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 `
        -o PreferredAuthentications=publickey,password,keyboard-interactive `
        "$RouterUser@$RouterHost" $remoteCmd 2>$null | Where-Object { $_ -match "^ssh-" }
} catch {
    $pubKey = $null
}

if (-not $pubKey) {
    Fail "Could not read the router public key."
    Fail "Check that SSH works:  ssh $RouterUser@$RouterHost cat /root/.ssh/id_ed25519.pub"
    Fail "Or paste the key into the file manually (see README)."
    exit 1
}

Ok "public key: $($pubKey.Substring(0, [Math]::Min(40, $pubKey.Length)))..."

# --- 6. Authorize the key ---------------------------------------------------

Step "Authorized keys"

if (Test-IsAdminAccount) {
    $authFile = "$env:ProgramData\ssh\administrators_authorized_keys"
    Ok "this account is an Administrator -> $authFile"

    $added = Add-LineToFile -Path $authFile -Line $pubKey
    if ($added) { Ok "key added" } else { Ok "key already present" }

    & icacls.exe $authFile /inheritance:r /grant "Administrators:F" /grant "SYSTEM:F" | Out-Null
    Ok "permissions fixed (Administrators, SYSTEM)"
} else {
    $authFile = "$env:USERPROFILE\.ssh\authorized_keys"
    Ok "regular account -> $authFile"
    $added = Add-LineToFile -Path $authFile -Line $pubKey
    if ($added) { Ok "key added" } else { Ok "key already present" }
}

Restart-Service sshd
Ok "sshd restarted"

# --- 7. End-to-end test -----------------------------------------------------

Step "End-to-end test from the router"

Start-Sleep -Seconds 2

$testCmd = "ssh -i /root/.ssh/id_ed25519 -o BatchMode=yes -o StrictHostKeyChecking=no " +
           "-o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=8 " +
           "$SshUser@$pcIp 'echo ok'"

$result = & ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 `
    -o PreferredAuthentications=publickey,password,keyboard-interactive `
    "$RouterUser@$RouterHost" $testCmd 2>&1

if ($result -match "ok") {
    Ok "router -> PC works: ssh $SshUser@$pcIp `"echo ok`" -> ok"
} else {
    Fail "test failed. Output:"
    $result | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkYellow }
    Warn "Typical reasons: the account is not allowed to log in over SSH,"
    Warn "sshd_config has 'PasswordAuthentication no' and the key was rejected,"
    Warn "or the Windows account name differs from '$SshUser'."
}

# --- 8. Summary -------------------------------------------------------------

Say ""
Say "==============================================" "DarkCyan"
Say "  Done" "DarkCyan"
Say "==============================================" "DarkCyan"
Say ""
Say "  SSH user for the WakeMyPc web form: $SshUser"
Say "  PC IP:                              $pcIp"
Say ""
Say "  In LuCI -> Services -> WakeMyPc set:"
Say "    SSH user : $SshUser"
Say "    IP address: $pcIp"
Say "  then press Save & Apply and Start."
Say ""
