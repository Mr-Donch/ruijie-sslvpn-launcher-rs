$ErrorActionPreference = 'Stop'

$scriptsRoot = Split-Path -Parent $PSScriptRoot
$modulePath = Join-Path $scriptsRoot 'ruijie-sslvpn-launcher.psm1'

Import-Module $modulePath -Force

$script:failures = 0

function Assert-True {
    param(
        [Parameter(Mandatory)] [bool]$Condition,
        [Parameter(Mandatory)] [string]$Name
    )

    if (-not $Condition) {
        $script:failures += 1
        Write-Host "FAIL $Name"
        return
    }

    Write-Host "PASS $Name"
}

function Assert-False {
    param(
        [Parameter(Mandatory)] [bool]$Condition,
        [Parameter(Mandatory)] [string]$Name
    )

    Assert-True -Condition (-not $Condition) -Name $Name
}

$loginSuccess = -join @([char]0x767b, [char]0x5f55, [char]0x6210, [char]0x529f)
$adapterConfigured = -join @([char]0x7f51, [char]0x5361, [char]0x914d, [char]0x7f6e, [char]0x6210, [char]0x529f)
$logout = -join @([char]0x7528, [char]0x6237, [char]0x6ce8, [char]0x9500, [char]0x767b, [char]0x5f55)

Assert-True `
    -Name 'log line with Chinese login success triggers DNS fix' `
    -Condition (Test-RuijieSslvpnConnectedLogLine -Line "[2026-06-21 12:41:33][LoginService][27804][info] - $loginSuccess")

Assert-True `
    -Name 'log line with adapter configured triggers DNS fix' `
    -Condition (Test-RuijieSslvpnConnectedLogLine -Line "[2026-06-21 12:41:33][DataProcessServicenService][27804][info] - $adapterConfigured")

Assert-True `
    -Name 'log line with DNS injection completion triggers DNS fix' `
    -Condition (Test-RuijieSslvpnConnectedLogLine -Line '[2026-06-21 12:41:33][IPTUNCTRL_PLUGIN][27804][info] - set_vnic finished!dns.size:3')

Assert-False `
    -Name 'log line with set_vnic error does not trigger DNS fix' `
    -Condition (Test-RuijieSslvpnConnectedLogLine -Line '[2026-06-21 13:08:35][IPTUNCTRL_PLUGIN][44136][info] - set_vnic finished!error:183')

Assert-False `
    -Name 'logout line does not trigger DNS fix' `
    -Condition (Test-RuijieSslvpnConnectedLogLine -Line "[2026-06-21 12:41:39][LoginService][27804][info] - $logout")

$extRoute = @'
192.168.0.0;255.255.0.0;172.16.10.1;5;7;
10.0.0.0;255.0.0.0;172.16.10.1;5;7;
172.16.0.0;255.255.0.0;172.16.10.1;5;7;
114.114.114.114;255.255.255.255;172.16.10.1;5;7;
'@

Assert-True `
    -Name 'ext_route with VPN gateway and private routes looks connected' `
    -Condition (Test-RuijieExtRouteLooksConnected -Content $extRoute)

Assert-False `
    -Name 'empty ext_route does not look connected' `
    -Condition (Test-RuijieExtRouteLooksConnected -Content '')

Assert-True `
    -Name 'ext_route trigger is allowed by default' `
    -Condition (Test-RuijieTriggerCanFixDns -TriggerKind 'ext_route' -AllowAdapterFallback:$false)

Assert-False `
    -Name 'log trigger is diagnostic only by default' `
    -Condition (Test-RuijieTriggerCanFixDns -TriggerKind 'log' -AllowAdapterFallback:$false)

Assert-False `
    -Name 'adapter trigger is disabled without fallback flag' `
    -Condition (Test-RuijieTriggerCanFixDns -TriggerKind 'adapter' -AllowAdapterFallback:$false)

Assert-True `
    -Name 'adapter trigger is enabled with fallback flag' `
    -Condition (Test-RuijieTriggerCanFixDns -TriggerKind 'adapter' -AllowAdapterFallback:$true)

Assert-True `
    -Name 'DNS differs from preferred value needs fix' `
    -Condition (Test-RuijieDnsNeedsFix -CurrentDns @('198.18.0.2', '192.168.124.1', '114.114.114.114') -PreferredDns @('114.114.114.114'))

Assert-False `
    -Name 'DNS equal to preferred value does not need fix' `
    -Condition (Test-RuijieDnsNeedsFix -CurrentDns @('114.114.114.114') -PreferredDns @('114.114.114.114'))

$lockedLogPath = Join-Path $env:TEMP ('ruijie-locked-log-{0}.log' -f ([guid]::NewGuid().ToString('N')))
Set-Content -Encoding UTF8 -Path $lockedLogPath -Value 'locked'
$lockedStream = [System.IO.File]::Open($lockedLogPath, [System.IO.FileMode]::Open, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
try {
    $lockedRead = Read-RuijieNewLogLines -Path $lockedLogPath -PreviousLength 0
    Assert-True `
        -Name 'locked log file returns no lines instead of throwing' `
        -Condition ($lockedRead.Count -eq 0)
} finally {
    $lockedStream.Dispose()
    Remove-Item -LiteralPath $lockedLogPath -Force -ErrorAction SilentlyContinue
}

if ($script:failures -gt 0) {
    throw "$script:failures test(s) failed."
}

Write-Host 'All launcher tests passed.'
