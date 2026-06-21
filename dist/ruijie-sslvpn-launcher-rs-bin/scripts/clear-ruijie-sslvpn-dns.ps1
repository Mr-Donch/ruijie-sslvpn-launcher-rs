param(
    [ValidateSet('clear','set','dhcp','status')]
    [string]$Action = 'clear',

    [string[]]$ServerAddresses = @(),

    [string]$LogPath = (Join-Path $PSScriptRoot 'logs\ruijie-sslvpn-dns-cleaner.log')
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string]$Message)
    $logDir = Split-Path -Parent $LogPath
    if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Force -Path $logDir | Out-Null
    }
    $line = '{0} {1}' -f (Get-Date).ToString('s'), $Message
    Add-Content -Encoding UTF8 -Path $LogPath -Value $line
}

function Get-CurrentDnsServers {
    $currentDns = Get-DnsClientServerAddress -InterfaceIndex $vpn.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    @($currentDns.ServerAddresses)
}

$vpn = Get-NetAdapter -IncludeHidden |
    Where-Object { $_.InterfaceDescription -eq 'RuiJie SSLVPN Virtual Network Card' } |
    Select-Object -First 1

if (-not $vpn) {
    Write-Log 'RuiJie SSLVPN adapter not found.'
    exit 0
}

$dns = Get-DnsClientServerAddress -InterfaceIndex $vpn.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
$current = @($dns.ServerAddresses)
$currentText = if ($current.Count) { $current -join ',' } else { '<empty>' }

if ($Action -eq 'status') {
    [pscustomobject]@{
        Time = (Get-Date).ToString('s')
        InterfaceIndex = $vpn.ifIndex
        InterfaceAlias = $vpn.Name
        Status = $vpn.Status.ToString()
        DnsServers = $(if ($current.Count) { $current -join ',' } else { '<empty>' })
    } | Format-List
    exit 0
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
    IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Log 'Not running as administrator; cannot change DNS.'
    throw 'Run as administrator.'
}

if ($vpn.Status -ne 'Up') {
    Write-Log "Adapter status is $($vpn.Status); no DNS change. Current DNS: $currentText"
    exit 0
}

if ($Action -eq 'clear') {
    if ($current.Count -eq 0) {
        Write-Log 'DNS already empty; no change.'
        exit 0
    }

    $netshOutput = & netsh interface ipv4 set dnsservers name="$($vpn.Name)" source=static address=none validate=no 2>&1
    Clear-DnsClientCache
    Start-Sleep -Milliseconds 500

    $after = Get-CurrentDnsServers
    $afterText = if ($after.Count) { $after -join ',' } else { '<empty>' }
    if ($after.Count -eq 0) {
        Write-Log "Cleared SSLVPN DNS. Previous DNS: $currentText"
        exit 0
    }

    $netshShow = (& netsh interface ipv4 show dnsservers name="$($vpn.Name)" 2>&1) -join ' | '
    Write-Log "FAILED to clear SSLVPN DNS. Previous DNS: $currentText Current DNS: $afterText netsh-set-output: $($netshOutput -join ' | ') netsh-show: $netshShow"
    throw "DNS was not cleared. Current DNS: $afterText"
}

if ($Action -eq 'dhcp') {
    & netsh interface ipv4 set dnsservers name="$($vpn.Name)" source=dhcp validate=no | Out-Null
    Clear-DnsClientCache
    Write-Log "Restored SSLVPN DNS source to DHCP. Previous DNS: $currentText"
    exit 0
}

if ($Action -eq 'set') {
    if ($ServerAddresses.Count -eq 0) {
        throw 'Provide -ServerAddresses when using -Action set.'
    }

    $wantedText = $ServerAddresses -join ','
    if (($current -join ',') -eq $wantedText) {
        Write-Log "DNS already set to $wantedText; no change."
        exit 0
    }

    Set-DnsClientServerAddress -InterfaceIndex $vpn.ifIndex -ServerAddresses $ServerAddresses
    Clear-DnsClientCache
    Start-Sleep -Milliseconds 500

    $after = Get-CurrentDnsServers
    $afterText = if ($after.Count) { $after -join ',' } else { '<empty>' }
    if (($after -join ',') -eq $wantedText) {
        Write-Log "Set SSLVPN DNS to $wantedText. Previous DNS: $currentText"
        exit 0
    }

    Write-Log "FAILED to set SSLVPN DNS to $wantedText. Previous DNS: $currentText Current DNS: $afterText"
    throw "DNS was not set to $wantedText. Current DNS: $afterText"
}
