param(
    [string]$Name = '',
    [string]$LogPath = (Join-Path $PSScriptRoot 'logs\vpn-clash-priority-log.jsonl'),
    [int]$TimeoutSeconds = 6
)

$ErrorActionPreference = 'Stop'

function Test-ResolveWithTimeout {
    param(
        [Parameter(Mandatory)] [string]$QueryName,
        [string]$Server,
        [string]$Type = 'A',
        [int]$TimeoutSeconds = 6
    )

    $script = {
        param($QueryName, $Server, $Type)
        if ($Server) {
            Resolve-DnsName $QueryName -Server $Server -Type $Type -DnsOnly -ErrorAction Stop
        } else {
            Resolve-DnsName $QueryName -Type $Type -DnsOnly -ErrorAction Stop
        }
    }

    $job = Start-Job -ScriptBlock $script -ArgumentList $QueryName,$Server,$Type
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $done = Wait-Job $job -Timeout $TimeoutSeconds
    $sw.Stop()

    if (-not $done) {
        Stop-Job $job -ErrorAction SilentlyContinue
        Remove-Job $job -Force -ErrorAction SilentlyContinue
        return [pscustomobject]@{
            Name = $QueryName
            Type = $Type
            Server = $(if ($Server) { $Server } else { '<system-default>' })
            Ms = $sw.ElapsedMilliseconds
            Status = 'TIMEOUT'
            Answers = @()
        }
    }

    try {
        $result = Receive-Job $job -ErrorAction Stop
        $answers = @($result | Where-Object { $_.IPAddress -or $_.NameHost } | ForEach-Object {
            if ($_.IPAddress) { $_.IPAddress } else { $_.NameHost }
        })
        $status = 'OK'
    } catch {
        $answers = @()
        $status = 'ERR: ' + $_.Exception.Message
    } finally {
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }

    [pscustomobject]@{
        Name = $QueryName
        Type = $Type
        Server = $(if ($Server) { $Server } else { '<system-default>' })
        Ms = $sw.ElapsedMilliseconds
        Status = $status
        Answers = $answers
    }
}

function Get-AdapterDns {
    param([int]$InterfaceIndex)

    $dns = Get-DnsClientServerAddress -InterfaceIndex $InterfaceIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
    @($dns.ServerAddresses)
}

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
    IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$adapters = @(Get-NetAdapter -IncludeHidden | Where-Object {
    $_.InterfaceDescription -match 'RuiJie SSLVPN|Meta Tunnel' -or
    $_.Name -match 'Mihomo|Clash|SSLVPN|RuiJie|WLAN'
} | Sort-Object ifIndex | ForEach-Object {
    $ipIf = @(Get-NetIPInterface -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue | Select-Object -First 1)
    $ip = @(Get-NetIPAddress -InterfaceIndex $_.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' } |
        Select-Object -First 5 -ExpandProperty IPAddress)

    [pscustomobject]@{
        IfIndex = $_.ifIndex
        Name = $_.Name
        Description = $_.InterfaceDescription
        Status = $_.Status.ToString()
        IPv4 = $ip
        InterfaceMetric = $(if ($ipIf) { $ipIf.InterfaceMetric } else { $null })
        AutomaticMetric = $(if ($ipIf) { $ipIf.AutomaticMetric } else { $null })
        DnsServers = @(Get-AdapterDns -InterfaceIndex $_.ifIndex)
    }
})

$interestingPrefixes = @(
    '0.0.0.0/0',
    '10.0.0.0/8',
    '172.16.0.0/16',
    '192.168.0.0/16',
    '192.168.124.1/32',
    '114.114.114.114/32',
    '198.18.0.2/32'
)

$routes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction SilentlyContinue |
    Where-Object { $interestingPrefixes -contains $_.DestinationPrefix } |
    Sort-Object DestinationPrefix,RouteMetric,InterfaceMetric |
    Select-Object ifIndex,InterfaceAlias,DestinationPrefix,NextHop,RouteMetric,InterfaceMetric)

$servers = @($adapters.DnsServers | Where-Object { $_ } | Select-Object -Unique)
$dnsTests = @()
foreach ($server in $servers) {
    foreach ($query in @('www.baidu.com','www.google.com')) {
        $dnsTests += Test-ResolveWithTimeout -QueryName $query -Server $server -Type A -TimeoutSeconds $TimeoutSeconds
    }
}

$defaultTests = @()
foreach ($query in @('www.baidu.com','www.google.com')) {
    Clear-DnsClientCache -ErrorAction SilentlyContinue
    $defaultTests += Test-ResolveWithTimeout -QueryName $query -Type A -TimeoutSeconds ($TimeoutSeconds * 3)
}

$processes = @(Get-Process -ErrorAction SilentlyContinue |
    Where-Object { $_.ProcessName -match 'clash|mihomo|verge|vpn|ssl|ruijie|RG-SSLVPN' } |
    Select-Object Id,ProcessName,Path)

$snapshot = [pscustomobject]@{
    Time = (Get-Date).ToString('s')
    Label = $Name
    IsAdmin = $isAdmin
    ComputerName = $env:COMPUTERNAME
    Adapters = $adapters
    Routes = $routes
    DnsServerTests = $dnsTests
    SystemDefaultDnsTests = $defaultTests
    Processes = $processes
}

$logDir = Split-Path -Parent $LogPath
if ($logDir -and -not (Test-Path -LiteralPath $logDir)) {
    New-Item -ItemType Directory -Force -Path $logDir | Out-Null
}

$snapshot | ConvertTo-Json -Depth 8 -Compress | Add-Content -Encoding UTF8 $LogPath

Write-Host ''
Write-Host "Snapshot saved to: $LogPath"
Write-Host "Label: $Name"
Write-Host ''
Write-Host 'Adapters'
$adapters | Format-Table IfIndex,Name,Status,InterfaceMetric,DnsServers -AutoSize
Write-Host ''
Write-Host 'Key routes'
$routes | Format-Table ifIndex,InterfaceAlias,DestinationPrefix,NextHop,RouteMetric,InterfaceMetric -AutoSize
Write-Host ''
Write-Host 'DNS server tests'
$dnsTests | Format-Table Server,Name,Ms,Status -AutoSize
Write-Host ''
Write-Host 'System default DNS tests'
$defaultTests | Format-Table Server,Name,Ms,Status -AutoSize
