$ErrorActionPreference = 'Stop'

function Test-RuijieSslvpnConnectedLogLine {
    param(
        [AllowNull()] [string]$Line
    )

    if ([string]::IsNullOrWhiteSpace($Line)) {
        return $false
    }

    $adapterConfigured = -join @(
        [char]0x7f51,
        [char]0x5361,
        [char]0x914d,
        [char]0x7f6e,
        [char]0x6210,
        [char]0x529f
    )
    $loginSuccess = -join @(
        [char]0x767b,
        [char]0x5f55,
        [char]0x6210,
        [char]0x529f
    )
    $tunnelListening = -join @(
        [char]0x96a7,
        [char]0x9053,
        [char]0x76d1,
        [char]0x542c,
        [char]0x5f00,
        [char]0x59cb
    )

    if ($Line.Contains('set_vnic finished')) {
        return ($Line.Contains('dns.size') -and -not $Line.Contains('error:'))
    }

    $patterns = @(
        $adapterConfigured,
        ('Msg_Function,msg:' + $loginSuccess),
        $loginSuccess,
        $tunnelListening
    )

    foreach ($pattern in $patterns) {
        if ($Line.Contains($pattern)) {
            return $true
        }
    }

    return $false
}

function Test-RuijieExtRouteLooksConnected {
    param(
        [AllowNull()] [string]$Content
    )

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $false
    }

    $hasVpnGateway = $Content.Contains('172.16.10.1')
    $hasPrivateRoute = (
        $Content.Contains('10.0.0.0;') -or
        $Content.Contains('172.16.0.0;') -or
        $Content.Contains('192.168.0.0;')
    )

    return ($hasVpnGateway -and $hasPrivateRoute)
}

function Test-RuijieDnsNeedsFix {
    param(
        [string[]]$CurrentDns = @(),
        [string[]]$PreferredDns = @('114.114.114.114')
    )

    $currentText = (@($CurrentDns) -join ',')
    $preferredText = (@($PreferredDns) -join ',')
    return ($currentText -ne $preferredText)
}

function Test-RuijieTriggerCanFixDns {
    param(
        [ValidateSet('ext_route','adapter','log')]
        [string]$TriggerKind,
        [bool]$AllowAdapterFallback = $false
    )

    if ($TriggerKind -eq 'ext_route') {
        return $true
    }

    if ($TriggerKind -eq 'adapter') {
        return $AllowAdapterFallback
    }

    return $false
}

function Read-RuijieNewLogLines {
    param(
        [string]$Path,
        [long]$PreviousLength
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    try {
        $item = Get-Item -LiteralPath $Path
        if ($item.Length -lt $PreviousLength) {
            $PreviousLength = 0
        }

        $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            if ($PreviousLength -gt 0) {
                $stream.Seek($PreviousLength, [System.IO.SeekOrigin]::Begin) | Out-Null
            }
            $reader = [System.IO.StreamReader]::new($stream, [System.Text.Encoding]::UTF8, $true)
            try {
                $text = $reader.ReadToEnd()
            } finally {
                $reader.Dispose()
            }
        } finally {
            $stream.Dispose()
        }
    } catch [System.IO.IOException] {
        return @()
    } catch [System.UnauthorizedAccessException] {
        return @()
    }

    if ([string]::IsNullOrEmpty($text)) {
        return @()
    }

    return @($text -split "`r?`n" | Where-Object { $_ })
}

function Get-RuijieSslvpnAdapterSnapshot {
    param(
        [string]$AdapterDescription = 'RuiJie SSLVPN Virtual Network Card'
    )

    $vpn = Get-NetAdapter -IncludeHidden -ErrorAction SilentlyContinue |
        Where-Object { $_.InterfaceDescription -eq $AdapterDescription } |
        Select-Object -First 1

    if (-not $vpn) {
        return [pscustomobject]@{
            Found = $false
            Status = '<missing>'
            InterfaceIndex = $null
            InterfaceAlias = ''
            IPv4 = @()
            DnsServers = @()
            IsConnected = $false
        }
    }

    $ipv4 = @(Get-NetIPAddress -InterfaceIndex $vpn.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '169.254.*' } |
        Select-Object -ExpandProperty IPAddress)

    $dns = @(Get-DnsClientServerAddress -InterfaceIndex $vpn.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty ServerAddresses)

    [pscustomobject]@{
        Found = $true
        Status = $vpn.Status.ToString()
        InterfaceIndex = $vpn.ifIndex
        InterfaceAlias = $vpn.Name
        IPv4 = $ipv4
        DnsServers = $dns
        IsConnected = ($vpn.Status -eq 'Up' -and @($ipv4 | Where-Object { $_ -like '172.16.*' }).Count -gt 0)
    }
}

function Invoke-RuijieDnsFix {
    param(
        [Parameter(Mandatory)] [string]$CleanerScriptPath,
        [string[]]$PreferredDns = @('114.114.114.114')
    )

    if (-not (Test-Path -LiteralPath $CleanerScriptPath)) {
        throw "Cleaner script not found: $CleanerScriptPath"
    }

    $args = @(
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        $CleanerScriptPath,
        '-Action',
        'set',
        '-ServerAddresses'
    ) + $PreferredDns

    & powershell.exe @args
    return $LASTEXITCODE
}

Export-ModuleMember -Function `
    Test-RuijieSslvpnConnectedLogLine, `
    Test-RuijieExtRouteLooksConnected, `
    Test-RuijieDnsNeedsFix, `
    Test-RuijieTriggerCanFixDns, `
    Read-RuijieNewLogLines, `
    Get-RuijieSslvpnAdapterSnapshot, `
    Invoke-RuijieDnsFix
