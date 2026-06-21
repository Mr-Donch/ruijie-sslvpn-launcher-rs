param(
    [string]$VpnExePath = 'C:\Program Files\RG-SSLVPN\RG-SSLVPN.exe',
    [string]$ExtRoutePath = 'C:\Program Files\RG-SSLVPN\ext_route',
    [string]$LogDirectory = 'C:\Program Files\RG-SSLVPN\log',
    [string]$ClientLogPath = 'C:\Program Files\RG SSL VPN Client\SslVpnWin.log',
    [string[]]$PreferredDns = @('114.114.114.114'),
    [int]$TimeoutSeconds = 120,
    [int]$PollIntervalMilliseconds = 500,
    [int]$FixDelayMilliseconds = 800,
    [int]$MaxFixAttempts = 3,
    [switch]$NoStart,
    [switch]$AllowAdapterFallback,
    [string]$LauncherLogPath = (Join-Path $PSScriptRoot 'logs\ruijie-sslvpn-launcher.log')
)

$ErrorActionPreference = 'Stop'

$modulePath = Join-Path $PSScriptRoot 'ruijie-sslvpn-launcher.psm1'
$cleanerScriptPath = Join-Path $PSScriptRoot 'clear-ruijie-sslvpn-dns.ps1'
Import-Module $modulePath -Force

function Write-LauncherLog {
    param([string]$Message)

    $logDir = Split-Path -Parent $LauncherLogPath
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    }

    $line = '{0} {1}' -f (Get-Date).ToString('s'), $Message
    Add-Content -Encoding UTF8 -Path $LauncherLogPath -Value $line
    Write-Host $line
}

function Get-TodaySslvpnLogPath {
    $name = '{0}_sslvpn.log' -f (Get-Date).ToString('yyyy-MM-dd')
    Join-Path $LogDirectory $name
}

function Get-FileState {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Exists = $false
            LastWriteTimeUtc = $null
            Length = 0L
        }
    }

    $item = Get-Item -LiteralPath $Path
    [pscustomobject]@{
        Exists = $true
        LastWriteTimeUtc = $item.LastWriteTimeUtc
        Length = $item.Length
    }
}

function Try-FixDns {
    $preferredText = $PreferredDns -join ','

    for ($attempt = 1; $attempt -le $MaxFixAttempts; $attempt += 1) {
        Start-Sleep -Milliseconds $FixDelayMilliseconds

        $snapshot = Get-RuijieSslvpnAdapterSnapshot
        if (-not $snapshot.Found) {
            Write-LauncherLog "DNS fix attempt $attempt skipped: adapter not found."
            continue
        }

        if ($snapshot.Status -ne 'Up') {
            Write-LauncherLog "DNS fix attempt $attempt skipped: adapter status is $($snapshot.Status)."
            continue
        }

        if (-not (Test-RuijieDnsNeedsFix -CurrentDns $snapshot.DnsServers -PreferredDns $PreferredDns)) {
            Write-LauncherLog "DNS already set to $preferredText."
            return $true
        }

        $currentText = if ($snapshot.DnsServers.Count) { $snapshot.DnsServers -join ',' } else { '<empty>' }
        Write-LauncherLog "DNS fix attempt ${attempt}: current=$currentText target=$preferredText"

        $exitCode = Invoke-RuijieDnsFix -CleanerScriptPath $cleanerScriptPath -PreferredDns $PreferredDns
        if ($exitCode -ne 0) {
            Write-LauncherLog "DNS fix attempt $attempt failed: cleaner exit code $exitCode."
            continue
        }

        $after = Get-RuijieSslvpnAdapterSnapshot
        if (-not (Test-RuijieDnsNeedsFix -CurrentDns $after.DnsServers -PreferredDns $PreferredDns)) {
            Write-LauncherLog "DNS fixed to $preferredText."
            return $true
        }

        $afterText = if ($after.DnsServers.Count) { $after.DnsServers -join ',' } else { '<empty>' }
        Write-LauncherLog "DNS fix attempt $attempt did not stick: current=$afterText target=$preferredText"
    }

    return $false
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
    IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    throw 'Run as administrator. DNS changes require elevated privileges.'
}

if (-not (Test-Path -LiteralPath $cleanerScriptPath)) {
    throw "Cleaner script not found: $cleanerScriptPath"
}

if (-not $NoStart) {
    if (-not (Test-Path -LiteralPath $VpnExePath)) {
        throw "SSLVPN executable not found: $VpnExePath"
    }

    Write-LauncherLog "Starting SSLVPN: $VpnExePath"
    Start-Process -FilePath $VpnExePath -WorkingDirectory (Split-Path -Parent $VpnExePath)
} else {
    Write-LauncherLog 'NoStart enabled; monitoring existing SSLVPN session.'
}

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$logPath = Get-TodaySslvpnLogPath
$logState = Get-FileState -Path $logPath
$clientLogState = Get-FileState -Path $ClientLogPath
$extRouteState = Get-FileState -Path $ExtRoutePath

Write-LauncherLog "Monitoring log=$logPath ext_route=$ExtRoutePath timeout=${TimeoutSeconds}s"

while ((Get-Date) -lt $deadline) {
    $trigger = ''
    $triggerKind = ''

    $currentLogPath = Get-TodaySslvpnLogPath
    if ($currentLogPath -ne $logPath) {
        $logPath = $currentLogPath
        $logState = Get-FileState -Path $logPath
    }

    $newLogLines = Read-RuijieNewLogLines -Path $logPath -PreviousLength $logState.Length
    $logState = Get-FileState -Path $logPath
    foreach ($line in $newLogLines) {
        if (Test-RuijieSslvpnConnectedLogLine -Line $line) {
            Write-LauncherLog "Diagnostic log signal: $line"
        }
    }

    $newClientLines = Read-RuijieNewLogLines -Path $ClientLogPath -PreviousLength $clientLogState.Length
    $clientLogState = Get-FileState -Path $ClientLogPath
    foreach ($line in $newClientLines) {
        if (Test-RuijieSslvpnConnectedLogLine -Line $line) {
            Write-LauncherLog "Diagnostic client log signal: $line"
        }
    }

    if (-not $trigger) {
        $newExtRouteState = Get-FileState -Path $ExtRoutePath
        if ($newExtRouteState.Exists -and (
                -not $extRouteState.Exists -or
                $newExtRouteState.LastWriteTimeUtc -ne $extRouteState.LastWriteTimeUtc -or
                $newExtRouteState.Length -ne $extRouteState.Length
            )) {
            $content = Get-Content -LiteralPath $ExtRoutePath -Raw -ErrorAction SilentlyContinue
            if (Test-RuijieExtRouteLooksConnected -Content $content) {
                $trigger = 'ext_route updated and contains VPN routes'
                $triggerKind = 'ext_route'
            }
        }
        $extRouteState = $newExtRouteState
    }

    if (-not $trigger) {
        $adapter = Get-RuijieSslvpnAdapterSnapshot
        if ($AllowAdapterFallback -and $adapter.IsConnected -and (Test-RuijieDnsNeedsFix -CurrentDns $adapter.DnsServers -PreferredDns $PreferredDns)) {
            $trigger = "adapter connected: $($adapter.InterfaceAlias)"
            $triggerKind = 'adapter'
        }
    }

    if ($trigger) {
        if (-not (Test-RuijieTriggerCanFixDns -TriggerKind $triggerKind -AllowAdapterFallback:$AllowAdapterFallback)) {
            Write-LauncherLog "Trigger is diagnostic only; continuing to monitor: $trigger"
            Start-Sleep -Milliseconds $PollIntervalMilliseconds
            continue
        }

        Write-LauncherLog "Connection trigger detected: $trigger"
        if (Try-FixDns) {
            exit 0
        }

        Write-LauncherLog 'Connection trigger was too early or DNS fix failed; continuing to monitor.'
    }

    Start-Sleep -Milliseconds $PollIntervalMilliseconds
}

throw "Timed out after $TimeoutSeconds seconds waiting for SSLVPN connection."
