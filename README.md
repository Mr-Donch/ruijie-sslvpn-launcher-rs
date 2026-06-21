# RuiJie SSLVPN Launcher RS

Rust CLI for launching RuiJie SSLVPN and fixing DNS after `ext_route` updates.

## Behavior

- Default action is `run`.
- Starts `C:\Program Files\RG-SSLVPN\RG-SSLVPN.exe` unless `--no-start` is used.
- Requests UAC elevation automatically for `run` when not already administrator.
- Uses `ext_route` update as the primary trigger.
- Confirms the SSLVPN adapter is `Up` and has a non-link-local IPv4 before fixing DNS.
- Calls `scripts\clear-ruijie-sslvpn-dns.ps1` to set DNS.
- Writes Rust CLI logs to `log\ruijie-sslvpn-launcher-rs.log`.
- Pauses on error by default so double-click failures stay visible.

## Config

Generate or refresh the default config:

```powershell
target\debug\ruijie-sslvpn-launcher-rs.exe init-config --force
```

Default config path:

```text
ruijie-sslvpn-launcher-rs.toml
```

Important options:

```toml
preferred_dns = ["114.114.114.114"]
start_vpn = true
allow_adapter_fallback = false
confirm_uncertain = true
pause_on_error = true
pause_on_success = false
auto_elevate = true
```

For long-term TUN usage:

```toml
preferred_dns = ["198.18.0.2"]
```

## Run

Run by double-clicking the executable, or from a terminal:

```powershell
target\debug\ruijie-sslvpn-launcher-rs.exe
```

If it is not already administrator, Windows will show a UAC prompt.

## Scripts

The PowerShell scripts are kept under `scripts\` and can be used without the Rust executable.
Chinese script documentation:

```text
scripts\README-zh.md
```

Show current SSLVPN DNS:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\show-ruijie-sslvpn-dns.ps1
```

Set SSLVPN DNS:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\clear-ruijie-sslvpn-dns.ps1 -Action set -ServerAddresses 114.114.114.114
```

PowerShell launcher:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-ruijie-sslvpn-and-fix-dns.ps1
```

Override DNS once:

```powershell
target\debug\ruijie-sslvpn-launcher-rs.exe --dns 198.18.0.2
```

Monitor an already-started SSLVPN:

```powershell
target\debug\ruijie-sslvpn-launcher-rs.exe --no-start
```

Enable adapter fallback:

```powershell
target\debug\ruijie-sslvpn-launcher-rs.exe --allow-adapter-fallback
```

Dry run:

```powershell
target\debug\ruijie-sslvpn-launcher-rs.exe --dry-run
```

## Build

```powershell
cargo build --release
```

Release executable:

```text
target\release\ruijie-sslvpn-launcher-rs.exe
```

## Package

Create a portable package under `dist\ruijie-sslvpn-launcher-rs-bin`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\package.ps1
```

The package contains:

- `ruijie-sslvpn-launcher-rs.exe`
- `ruijie-sslvpn-launcher-rs.toml`
- `scripts\*.ps1`
- `scripts\README-zh.md`
- `scripts\tests\*.ps1`
- `docs\*.md`

The default config uses relative paths for scripts and logs, so the package can be moved as a folder. The scripts remain usable even without the executable.
