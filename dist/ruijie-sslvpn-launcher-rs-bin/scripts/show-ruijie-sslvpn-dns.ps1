param(
    [string]$AdapterDescription = 'RuiJie SSLVPN Virtual Network Card',

    [string]$PreferredDns = '114.114.114.114'
)

$ErrorActionPreference = 'Stop'

$vpn = Get-NetAdapter -IncludeHidden |
    Where-Object { $_.InterfaceDescription -eq $AdapterDescription } |
    Select-Object -First 1

if (-not $vpn) {
    [pscustomobject]@{
        Time = (Get-Date).ToString('s')
        Found = $false
        Message = "Adapter not found: $AdapterDescription"
    } | Format-List
    exit 1
}

$dns = Get-DnsClientServerAddress -InterfaceIndex $vpn.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
$servers = @($dns.ServerAddresses)
$ipv4 = @(Get-NetIPAddress -InterfaceIndex $vpn.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -notlike '169.254.*' } |
    Select-Object -ExpandProperty IPAddress)
$ipIf = Get-NetIPInterface -InterfaceIndex $vpn.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
$wlanDns = @(Get-DnsClientServerAddress -InterfaceAlias 'WLAN' -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Select-Object -ExpandProperty ServerAddresses)
$duplicatesWlanDns = @($servers | Where-Object { $wlanDns -contains $_ })
$isPreferred = ($servers.Count -eq 1 -and $servers[0] -eq $PreferredDns)

[pscustomobject]@{
    Time = (Get-Date).ToString('s')
    Found = $true
    InterfaceIndex = $vpn.ifIndex
    InterfaceAlias = $vpn.Name
    Status = $vpn.Status.ToString()
    IPv4 = ($ipv4 -join ',')
    InterfaceMetric = $ipIf.InterfaceMetric
    DnsServers = $(if ($servers.Count) { $servers -join ',' } else { '<empty>' })
    WlanDnsServers = $(if ($wlanDns.Count) { $wlanDns -join ',' } else { '<empty>' })
    DuplicatesWlanDns = $(if ($duplicatesWlanDns.Count) { $duplicatesWlanDns -join ',' } else { '<none>' })
    IsPreferredDns = $isPreferred
    NeedsFix = ($vpn.Status -eq 'Up' -and -not $isPreferred)
    CleanupCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\clear-ruijie-sslvpn-dns.ps1`" -Action clear"
    SetPreferredCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\clear-ruijie-sslvpn-dns.ps1`" -Action set -ServerAddresses $PreferredDns"
    RestoreDhcpCommand = "powershell -NoProfile -ExecutionPolicy Bypass -File `"$PSScriptRoot\clear-ruijie-sslvpn-dns.ps1`" -Action dhcp"
} | Format-List
