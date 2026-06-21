# PowerShell 脚本说明

这些脚本可以独立于 Rust 可执行文件使用。需要修改网卡 DNS 的命令必须在管理员 PowerShell 中运行。

## clear-ruijie-sslvpn-dns.ps1

用途：修正 `RuiJie SSLVPN Virtual Network Card` 的 IPv4 DNS。

查看状态：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\clear-ruijie-sslvpn-dns.ps1 -Action status
```

设置为通用 DNS：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\clear-ruijie-sslvpn-dns.ps1 -Action set -ServerAddresses 114.114.114.114
```

长期使用 Mihomo/Clash TUN 时设置为 TUN DNS：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\clear-ruijie-sslvpn-dns.ps1 -Action set -ServerAddresses 198.18.0.2
```

恢复 DHCP 自动获取 DNS：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\clear-ruijie-sslvpn-dns.ps1 -Action dhcp
```

实验性清空 DNS：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\clear-ruijie-sslvpn-dns.ps1 -Action clear
```

日志默认写入：

```text
scripts\logs\ruijie-sslvpn-dns-cleaner.log
```

## show-ruijie-sslvpn-dns.ps1

用途：只读查看 SSLVPN 虚拟网卡 DNS、WLAN DNS、是否重复、是否建议修正。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\show-ruijie-sslvpn-dns.ps1
```

指定目标 DNS 进行检查：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\show-ruijie-sslvpn-dns.ps1 -PreferredDns 198.18.0.2
```

## start-ruijie-sslvpn-and-fix-dns.ps1

用途：PowerShell 版启动器。启动 SSLVPN，监控 `ext_route`，连接成功后调用 `clear-ruijie-sslvpn-dns.ps1` 修正 DNS。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-ruijie-sslvpn-and-fix-dns.ps1
```

长期使用 TUN：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-ruijie-sslvpn-and-fix-dns.ps1 -PreferredDns 198.18.0.2
```

只监控已有 SSLVPN：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-ruijie-sslvpn-and-fix-dns.ps1 -NoStart
```

允许网卡状态兜底触发：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\start-ruijie-sslvpn-and-fix-dns.ps1 -AllowAdapterFallback
```

日志默认写入：

```text
scripts\logs\ruijie-sslvpn-launcher.log
```

## install-ruijie-sslvpn-dns-cleaner-task.ps1

用途：安装或卸载计划任务，周期性运行 DNS 修正脚本。通常 Rust CLI 已经够用，计划任务只作为兜底方案。

安装：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-ruijie-sslvpn-dns-cleaner-task.ps1 -Action install
```

长期 TUN：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-ruijie-sslvpn-dns-cleaner-task.ps1 -Action install -CleanerAction set -ServerAddresses 198.18.0.2
```

查看状态：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-ruijie-sslvpn-dns-cleaner-task.ps1 -Action status
```

卸载：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install-ruijie-sslvpn-dns-cleaner-task.ps1 -Action uninstall
```

## test-vpn-clash-priority.ps1

用途：采集 VPN、Mihomo/Clash、DNS、路由和解析耗时快照，用于排障。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\test-vpn-clash-priority.ps1 -Name after-change
```

日志默认写入：

```text
scripts\logs\vpn-clash-priority-log.jsonl
```

## tests\start-ruijie-sslvpn-launcher.Tests.ps1

用途：PowerShell 启动器模块的回归测试。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\tests\start-ruijie-sslvpn-launcher.Tests.ps1
```
