# 瑞捷 SSLVPN DNS 工具

> 历史 PowerShell 工具文档。当前项目入口和最新命令请优先查看 `..\README.md` 和 `..\scripts\README-zh.md`；本文中部分绝对路径保留为当时排查记录。

这个目录里的脚本用于查看和修正 `RuiJie SSLVPN Virtual Network Card` 网卡上的 DNS。

## 当前结论

不要把 SSLVPN 网卡 DNS 设置为：

```text
192.168.124.1
```

原因：`192.168.124.1` 本身作为 DNS 是可用的，但它已经是 WLAN 网卡的 DNS。如果再把它设置到 SSLVPN 网卡上，就会出现同一个 DNS 同时挂在 SSLVPN 和 WLAN 两个接口上的状态。实测这种组合会让 Windows 默认 DNS 解析进入 12 秒左右的回退路径。

当前更稳的选择：

```text
通用方案：SSLVPN DNS = 114.114.114.114
长期 TUN 方案：SSLVPN DNS = 198.18.0.2
```

`clear` 清空模式对这个瑞捷 DHCP 虚拟网卡不可靠，保留为实验项。主推荐是使用 `set` 覆盖成一个明确 DNS。

## 文件说明

- `show-ruijie-sslvpn-dns.ps1`：只读查看 SSLVPN DNS，并提示是否需要修正。
- `clear-ruijie-sslvpn-dns.ps1`：设置、清空或恢复 SSLVPN DNS。
- `install-ruijie-sslvpn-dns-cleaner-task.ps1`：安装/卸载自动修正计划任务。
- `test-vpn-clash-priority.ps1`：采集 DNS、路由、解析耗时的诊断脚本。
- `ruijie-sslvpn-launcher-rs`：Rust CLI 启动器项目。
- `学习与经验总结.md`：完整排查复盘。

## 查看 SSLVPN DNS

普通 PowerShell 即可执行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\donch\.codex\ruijie-sslvpn-dns-tools\show-ruijie-sslvpn-dns.ps1
```

重点看：

```text
DnsServers        当前 SSLVPN 网卡 DNS
WlanDnsServers    WLAN 网卡 DNS
DuplicatesWlanDns 是否和 WLAN DNS 重复
IsPreferredDns    是否已经是推荐 DNS
NeedsFix          是否建议修正
```

默认推荐 DNS 是 `114.114.114.114`。如果你长期使用 TUN，可以用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\donch\.codex\ruijie-sslvpn-dns-tools\show-ruijie-sslvpn-dns.ps1 -PreferredDns 198.18.0.2
```

## 推荐：设置为 114.114.114.114

适合开或不开 TUN 的通用场景。需要管理员 PowerShell：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\donch\.codex\ruijie-sslvpn-dns-tools\clear-ruijie-sslvpn-dns.ps1 -Action set -ServerAddresses 114.114.114.114
```

## 长期使用 TUN：设置为 198.18.0.2

如果你长期打开 Clash/Mihomo TUN，可以把 SSLVPN DNS 固定到 Mihomo DNS。需要管理员 PowerShell：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\donch\.codex\ruijie-sslvpn-dns-tools\clear-ruijie-sslvpn-dns.ps1 -Action set -ServerAddresses 198.18.0.2
```

## 推荐：启动 SSLVPN 后自动修正 DNS

`start-ruijie-sslvpn-and-fix-dns.ps1` 会启动瑞捷 SSLVPN，然后监控：

- `C:\Program Files\RG-SSLVPN\ext_route`
- `C:\Program Files\RG-SSLVPN\log\yyyy-MM-dd_sslvpn.log`
- `C:\Program Files\RG SSL VPN Client\SslVpnWin.log`
- `RuiJie SSLVPN Virtual Network Card` 网卡状态

默认以 `ext_route` 更新时间变化作为连接成功的主触发。日志只作为诊断信号写入启动器日志，不直接触发 DNS 修正；网卡状态只用于确认和可选兜底。

检测到 `ext_route` 更新且内容包含 VPN 路由后，会调用 `clear-ruijie-sslvpn-dns.ps1 -Action set` 把 SSLVPN 网卡 DNS 改成目标值，并复查是否生效。需要管理员 PowerShell：

如果瑞捷进程暂时锁住日志文件，启动器会跳过这一轮日志读取，继续用 `ext_route` 更新时间和网卡状态判断连接，不需要手动处理。

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\donch\Desktop\ruijie-sslvpn-dns-tools\start-ruijie-sslvpn-and-fix-dns.ps1
```

长期使用 TUN 时：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\donch\Desktop\ruijie-sslvpn-dns-tools\start-ruijie-sslvpn-and-fix-dns.ps1 -PreferredDns 198.18.0.2
```

如果 SSLVPN 已经手动启动，只想监控并修正当前会话：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\donch\Desktop\ruijie-sslvpn-dns-tools\start-ruijie-sslvpn-and-fix-dns.ps1 -NoStart
```

如果以后遇到 `ext_route` 没变化但网卡已连接、DNS 又被瑞捷改坏的场景，可以显式允许网卡状态兜底触发：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\donch\Desktop\ruijie-sslvpn-dns-tools\start-ruijie-sslvpn-and-fix-dns.ps1 -AllowAdapterFallback
```

启动器日志：

```powershell
Get-Content C:\Users\donch\Desktop\ruijie-sslvpn-dns-tools\ruijie-sslvpn-launcher.log -Tail 20
```

后续如果需要做 Rust CLI，可以复用当前启动器的判断规则：默认只在 `ext_route` 重写且包含 VPN 路由时修正 DNS；日志只做诊断；网卡状态兜底需要显式开启。

## Rust CLI 启动器

Rust 版本位于：

```text
C:\Users\donch\Desktop\ruijie-sslvpn-dns-tools\ruijie-sslvpn-launcher-rs
```

生成配置：

```powershell
cd C:\Users\donch\Desktop\ruijie-sslvpn-dns-tools\ruijie-sslvpn-launcher-rs
target\debug\ruijie-sslvpn-launcher-rs.exe init-config --force
```

运行时会自动请求 UAC 管理员授权：

```powershell
target\debug\ruijie-sslvpn-launcher-rs.exe
```

长期使用 TUN 时：

```powershell
target\debug\ruijie-sslvpn-launcher-rs.exe --dns 198.18.0.2
```

构建 release：

```powershell
cargo build --release
```

生成便携包：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\package.ps1
```

输出目录：

```text
ruijie-sslvpn-launcher-rs\dist\ruijie-sslvpn-launcher-rs-bin
```

## 不推荐：设置为 192.168.124.1

虽然这个 DNS 单独测试很快：

```text
Resolve-DnsName www.baidu.com -Server 192.168.124.1
```

但它同时存在于 WLAN 和 SSLVPN 两个接口上时，实测 Windows 默认解析会变成约 12 秒。因此不建议：

```powershell
-ServerAddresses 192.168.124.1
```

## 实验项：清空 SSLVPN DNS

这个瑞捷虚拟网卡的 DNS 来自 DHCP/客户端控制，清空可能不生效。脚本会在清空后立即复查；如果没清掉，会报错。

需要管理员 PowerShell：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\donch\.codex\ruijie-sslvpn-dns-tools\clear-ruijie-sslvpn-dns.ps1 -Action clear
```

## 恢复 SSLVPN DNS 自动获取

如果想撤销静态 DNS，恢复瑞捷/DHCP 自动下发 DNS，需要管理员 PowerShell：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\donch\.codex\ruijie-sslvpn-dns-tools\clear-ruijie-sslvpn-dns.ps1 -Action dhcp
```

## 安装自动修正计划任务

默认安装为每 1 分钟把 SSLVPN DNS 设置成 `114.114.114.114`。需要管理员 PowerShell：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\donch\.codex\ruijie-sslvpn-dns-tools\install-ruijie-sslvpn-dns-cleaner-task.ps1 -Action install
```

长期 TUN 用户可安装为自动设置 `198.18.0.2`：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\donch\.codex\ruijie-sslvpn-dns-tools\install-ruijie-sslvpn-dns-cleaner-task.ps1 -Action install -CleanerAction set -ServerAddresses 198.18.0.2
```

查看任务：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\donch\.codex\ruijie-sslvpn-dns-tools\install-ruijie-sslvpn-dns-cleaner-task.ps1 -Action status
```

卸载任务需要管理员 PowerShell：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\donch\.codex\ruijie-sslvpn-dns-tools\install-ruijie-sslvpn-dns-cleaner-task.ps1 -Action uninstall
```

## 查看日志

```powershell
Get-Content C:\Users\donch\.codex\ruijie-sslvpn-dns-tools\ruijie-sslvpn-dns-cleaner.log -Tail 20
```

## 验证解析速度

```powershell
Resolve-DnsName www.baidu.com
Resolve-DnsName www.google.com
```

完整诊断：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\donch\.codex\ruijie-sslvpn-dns-tools\test-vpn-clash-priority.ps1 -Name after-set-114
```
