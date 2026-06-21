param(
    [string]$Configuration = 'release',
    [string]$PackageName = 'ruijie-sslvpn-launcher-rs-bin'
)

$ErrorActionPreference = 'Stop'

$projectRoot = $PSScriptRoot
$distRoot = Join-Path $projectRoot 'dist'
$packageRoot = Join-Path $distRoot $PackageName
$exeSource = Join-Path $projectRoot "target\$Configuration\ruijie-sslvpn-launcher-rs.exe"

Push-Location $projectRoot
try {
    cargo build --release

    if (-not (Test-Path -LiteralPath $exeSource)) {
        throw "Executable not found: $exeSource"
    }

    if (Test-Path -LiteralPath $packageRoot) {
        Remove-Item -LiteralPath $packageRoot -Recurse -Force
    }

    New-Item -ItemType Directory -Force -Path $packageRoot | Out-Null

    Copy-Item -LiteralPath $exeSource -Destination (Join-Path $packageRoot 'ruijie-sslvpn-launcher-rs.exe') -Force
    Copy-Item -LiteralPath (Join-Path $projectRoot 'ruijie-sslvpn-launcher-rs.toml') -Destination (Join-Path $packageRoot 'ruijie-sslvpn-launcher-rs.toml') -Force
    Copy-Item -LiteralPath (Join-Path $projectRoot 'README.md') -Destination (Join-Path $packageRoot 'README.md') -Force

    $docsDest = Join-Path $packageRoot 'docs'
    New-Item -ItemType Directory -Force -Path $docsDest | Out-Null
    Copy-Item -Path (Join-Path $projectRoot 'scripts') -Destination $packageRoot -Recurse -Force
    Copy-Item -Path (Join-Path $projectRoot 'docs\*.md') -Destination $docsDest -Force

    Write-Host "Package created: $packageRoot"
} finally {
    Pop-Location
}
