param(
    [ValidateSet('install','uninstall','run','status')]
    [string]$Action = 'install',

    [ValidateSet('clear','set')]
    [string]$CleanerAction = 'set',

    [string[]]$ServerAddresses = @('114.114.114.114'),

    [string]$TaskName = 'Set RuiJie SSLVPN DNS',

    [int]$RepeatMinutes = 1
)

$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'clear-ruijie-sslvpn-dns.ps1'

if (-not (Test-Path $scriptPath)) {
    throw "Cleaner script not found: $scriptPath"
}

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
        IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-CleanerArguments {
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Action $CleanerAction"
    if ($CleanerAction -eq 'set') {
        if ($ServerAddresses.Count -eq 0) {
            throw 'Provide -ServerAddresses when using -CleanerAction set.'
        }
        $joined = $ServerAddresses -join ','
        $args += " -ServerAddresses $joined"
    }
    $args
}

if ($Action -eq 'status') {
    Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue |
        Select-Object TaskName,State,TaskPath
    exit 0
}

if ($Action -eq 'uninstall') {
    if (-not (Test-Admin)) {
        throw 'Run as administrator to uninstall the scheduled task.'
    }
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
    "Uninstalled task: $TaskName"
    exit 0
}

if ($Action -eq 'run') {
    $runArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$scriptPath,'-Action',$CleanerAction)
    if ($CleanerAction -eq 'set') {
        if ($ServerAddresses.Count -eq 0) {
            throw 'Provide -ServerAddresses when using -CleanerAction set.'
        }
        $runArgs += '-ServerAddresses'
        $runArgs += $ServerAddresses
    }
    & powershell.exe @runArgs
    exit $LASTEXITCODE
}

if (-not (Test-Admin)) {
    throw 'Run as administrator to install the scheduled task.'
}

$taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument (Get-CleanerArguments)
$trigger = New-ScheduledTaskTrigger -AtLogOn
$trigger.Repetition = New-ScheduledTaskTrigger -Once -At (Get-Date).Date -RepetitionInterval (New-TimeSpan -Minutes $RepeatMinutes) -RepetitionDuration ([TimeSpan]::MaxValue)
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -LogonType Interactive -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -StartWhenAvailable

Register-ScheduledTask -TaskName $TaskName -Action $taskAction -Trigger $trigger -Principal $principal -Settings $settings -Force | Out-Null
"Installed task: $TaskName"
"Cleaner action: $CleanerAction"
if ($CleanerAction -eq 'set') {
    "Server addresses: $($ServerAddresses -join ',')"
}
