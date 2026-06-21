# SSLVPN、Clash/Mihomo 与 DNS 问题学习总结

> 历史排查复盘。当前项目入口和最新命令请优先查看 `..\README.md` 和 `..\scripts\README-zh.md`；本文中部分绝对路径保留为当时排查记录。

本文总结本机遇到的 DNS 变慢问题、排查过程、根因判断、解决方案，以及相关的 DNS、Windows 多网卡、Clash/Mihomo DNS 知识。

## 1. 问题现象

电脑同时使用：

- Clash Verge / Mihomo
- TUN 模式或系统代理模式
- 瑞捷 SSLVPN，用于访问公司内网

出现的问题：

```text
首次打开网页明显变慢，有时达到 10 秒以上。
后续访问同一类网站可能变快。
后开 SSLVPN 时更容易复现。
```

典型测试结果：

```text
<system-default> www.baidu.com   约 12s
<system-default> www.google.com  约 12s
```

但显式指定 Mihomo DNS 时很快：

```text
Resolve-DnsName www.baidu.com -Server 198.18.0.2
约 300-500ms
```

这说明慢点不是网站本身，也不是浏览器本身，而是 Windows 默认 DNS 解析路径出了问题。

## 2. 关键现场状态

### 2.1 网卡

主要相关网卡：

```text
WLAN
  物理 Wi-Fi 网卡
  IP: 192.168.124.9
  DNS: 192.168.124.1

Mihomo
  Clash/Mihomo TUN 虚拟网卡
  IP: 198.18.0.1
  DNS: 198.18.0.2

本地连接* 1
  RuiJie SSLVPN Virtual Network Card
  IP: 172.16.10.76
  DNS: 198.18.0.2, 192.168.124.1, 114.114.114.114
```

### 2.2 路由

SSLVPN 连接后会添加类似路由：

```text
10.0.0.0/8         -> SSLVPN
172.16.0.0/16      -> SSLVPN
192.168.0.0/16     -> SSLVPN
114.114.114.114/32 -> SSLVPN
```

其中：

```text
114.114.114.114/32 -> SSLVPN
```

说明 SSLVPN 明确把 `114.114.114.114` 这个公共 DNS 地址导进了 VPN。

同时系统也存在：

```text
192.168.124.1/32 -> WLAN
```

这条比 `192.168.0.0/16 -> SSLVPN` 更精确，所以访问本地网关 `192.168.124.1` 仍然走 WLAN。

## 3. 排查过程

### 3.1 单独指定 DNS 测试

最初在 TUN + SSLVPN + `strict-route: true` 下测到：

```text
198.18.0.2       OK，约 300-500ms
192.168.124.1    TIMEOUT，约 6s
114.114.114.114  TIMEOUT，约 6s
```

系统默认解析约 12 秒，刚好对应两个 DNS 超时叠加：

```text
6s + 6s = 12s
```

### 3.2 补充测试：关闭 strict-route

把 Mihomo TUN 的：

```yaml
strict-route: true
```

改为：

```yaml
strict-route: false
```

之后，两个 DNS 都恢复：

```text
192.168.124.1    OK
114.114.114.114  OK
```

说明原来的 12 秒超时与 Mihomo 的严格路由有关。

### 3.3 补充测试：关闭 Clash/TUN，仅开 SSLVPN

只开 SSLVPN 时：

```text
192.168.124.1    OK
114.114.114.114  OK
```

说明 `192.168.124.1` 和 `114.114.114.114` 本身不是坏 DNS。

### 3.4 补充测试：不开 SSLVPN

不开 SSLVPN 时，不管开不开 TUN：

```text
<system-default> www.baidu.com   约 300ms
<system-default> www.google.com  约 300ms
```

说明只要没有 SSLVPN 的高优先级虚拟网卡和 DNS 混入，Windows 默认 DNS 解析就比较简单、稳定。

## 4. 根因总结

根因不是单个因素，而是组合问题：

```text
瑞捷 SSLVPN 下发/写入不合理 DNS
+ Windows 多网卡 DNS 选择机制
+ Mihomo TUN strict-route 防 DNS 泄露规则
= 默认 DNS 解析变慢或超时
```

更具体地说：

1. 瑞捷 SSLVPN 新增一个高优先级虚拟网卡。
2. 这个网卡 DNS 里混入了：

```text
198.18.0.2
192.168.124.1
114.114.114.114
```

3. 这些 DNS 并不是清晰的公司内网 DNS。
4. Windows 默认解析时会把这个高优先级 SSLVPN 网卡纳入 DNS 选择。
5. 在 Mihomo `strict-route: true` 时，Mihomo 会在 Windows 上加防 DNS 泄露相关规则，导致部分 DNS 路径被阻断或异常。
6. 于是 Windows 等待超时后才回退，造成 10 秒以上首开网页延迟。

## 5. 为什么说 SSLVPN 配置不合理

正常企业 SSLVPN 更合理的配置通常是：

```text
下发公司内网 DNS，例如 10.x.x.x 或 172.16.x.x
只让公司内网域名走公司 DNS
公网域名继续走本地 DNS 或代理 DNS
```

更规范的方式是 split DNS：

```text
*.corp.example.com -> 公司 DNS
其它域名 -> 本机原 DNS
```

而本机 SSLVPN 实际下发的是：

```text
192.168.124.1
114.114.114.114
198.18.0.2
```

这些都不像公司内网 DNS。

而且公司内网地址 `git.ghostcloud.cn` 还需要靠 hosts 处理，这进一步说明 SSLVPN DNS 策略没有正确处理公司内网域名解析。

## 6. DNS 基础知识

### 6.1 DNS 是什么

DNS 用于把域名解析成 IP。

例如：

```text
github.com -> 140.82.x.x
www.baidu.com -> 110.242.x.x
```

访问网页前，系统通常先做 DNS 查询，再建立 TCP/HTTPS 连接。

### 6.2 网关不等于 DNS

`192.168.124.1` 是本地网关，也是路由器地址。

它通常也会提供 DNS 转发，所以 DHCP 会把它下发为 DNS：

```text
WLAN DNS: 192.168.124.1
```

但原则上：

```text
网关能 ping 通
不等于它的 DNS 服务一定可用
```

本次后续测试证明，在没有 TUN/strict-route 干扰时，`192.168.124.1` 作为 DNS 是可用的。

### 6.3 公共 DNS

`114.114.114.114` 是常见公共 DNS。

但 SSLVPN 添加了：

```text
114.114.114.114/32 -> SSLVPN
```

所以它不一定再走公网，而可能被导进公司 VPN。是否可用取决于 VPN 内部是否允许访问它。

## 7. Windows 多网卡 DNS 机制

Windows 有多个网卡时，不是简单只问一个 DNS。

它会考虑：

- 接口 metric
- DNS 服务器顺序
- DNS 服务器可达性
- 历史响应状态
- 并发查询和回退策略
- 缓存状态

所以：

```powershell
Resolve-DnsName www.baidu.com -Server 192.168.124.1
```

不等于：

```powershell
Resolve-DnsName www.baidu.com
```

前者是显式指定 DNS。

后者是 Windows 默认 DNS 选择，会涉及多网卡策略。

这就是为什么显式指定 DNS 只有 300ms，但 `<system-default>` 可能有 1200ms 或 12s。

## 8. Clash/Mihomo DNS 知识

### 8.1 fake-ip

配置：

```yaml
enhanced-mode: fake-ip
fake-ip-range: 198.18.0.1/16
```

含义：

Mihomo DNS 不直接返回真实公网 IP，而是返回一个 fake-ip，例如：

```text
github.com -> 198.18.0.29
raw.githubusercontent.com -> 198.18.0.11
```

应用连接这个 fake-ip 时，Mihomo 根据映射关系知道原始域名，再按规则决定走代理还是直连。

### 8.2 198.18.0.2 是什么

`198.18.0.2` 是 Mihomo TUN 内部 DNS 地址。

Windows 问它时，请求会进入 Mihomo DNS。

### 8.3 dns-hijack

配置示例：

```yaml
dns-hijack:
  - any:53
```

含义：

进入 Mihomo TUN 的 53 端口 DNS 请求会被 Mihomo 接管。

注意：

```text
dns-hijack 不是全系统魔法钩子。
正常情况下，它只能处理进入 TUN 的流量。
```

### 8.4 strict-route

配置：

```yaml
strict-route: true
```

Mihomo 官方文档说明，在 Windows 上它会添加防火墙规则，用来阻止 Windows 多网卡 DNS 查询导致 DNS 泄露。

优点：

```text
减少 DNS 泄露
更强制地让流量走 TUN
```

缺点：

```text
容易和 SSLVPN、企业 VPN、本地 DNS、多网卡环境冲突
```

本机问题中，`strict-route: true` 是导致 12 秒 DNS 超时的重要因素。

### 8.5 DNS 覆写

Clash Verge 的 DNS 覆写是配置层面的覆盖。

它用于覆盖最终运行配置中的：

```yaml
dns:
  enable:
  nameserver:
  nameserver-policy:
  proxy-server-nameserver:
  direct-nameserver:
```

它不是网络层劫持，不会直接改 Windows 网卡 DNS。

作用：

- 统一不同订阅的 DNS 配置
- 避免订阅自带 DNS 配置混乱
- 为 GitHub、Google 等域名指定海外 DoH
- 为国内域名使用国内 DNS

## 9. 最终采用的解决方案

### 9.1 Mihomo TUN 配置

建议：

```yaml
strict-route: false
```

这样可以避免 Mihomo 在 Windows 上加过强的 DNS 防泄露规则，减少和 SSLVPN 的冲突。

### 9.2 DNS 覆写

采用稳定的国内 DNS + 针对 GitHub/Google 的海外 DoH 策略。

重点：

```yaml
respect-rules: true
use-hosts: true
use-system-hosts: true
ipv6: false
```

并避免使用：

```yaml
default-nameserver:
  - system
```

因为 `system` 可能重新引入 SSLVPN/WLAN 的混合 DNS。

### 9.3 修正 SSLVPN 网卡 DNS

由于瑞捷 SSLVPN 网卡上的 DNS 本身不合理，最终准备了工具脚本：

```text
ruijie-sslvpn-dns-tools
```

用于：

- 查看 SSLVPN 网卡 DNS
- 手动覆盖 SSLVPN 网卡 DNS
- 安装计划任务自动修正

最新测试发现，`clear` 清空模式对这个瑞捷 DHCP 虚拟网卡不可靠。更稳的是把 SSLVPN DNS 覆盖成一个明确值。

不要设置成：

```text
192.168.124.1
```

原因是 WLAN 网卡本身也使用 `192.168.124.1`。当 SSLVPN 和 WLAN 同时使用同一个 DNS，且 `192.168.124.1/32` 实际路由走 WLAN 时，Windows 默认 DNS 解析会进入约 12 秒的回退路径。

当前推荐：

```text
通用方案：SSLVPN DNS = 114.114.114.114
长期 TUN 方案：SSLVPN DNS = 198.18.0.2
```

## 10. 后续排障命令

查看 SSLVPN DNS：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\donch\.codex\ruijie-sslvpn-dns-tools\show-ruijie-sslvpn-dns.ps1
```

设置 SSLVPN DNS 为通用稳定值：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\donch\.codex\ruijie-sslvpn-dns-tools\clear-ruijie-sslvpn-dns.ps1 -Action set -ServerAddresses 114.114.114.114
```

长期使用 TUN 时设置为 Mihomo DNS：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\donch\.codex\ruijie-sslvpn-dns-tools\clear-ruijie-sslvpn-dns.ps1 -Action set -ServerAddresses 198.18.0.2
```

测试完整网络状态：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\donch\.codex\test-vpn-clash-priority.ps1 -Name after-change
```

指定 DNS 测试：

```powershell
Resolve-DnsName www.baidu.com -Server 198.18.0.2
Resolve-DnsName www.baidu.com -Server 192.168.124.1
Resolve-DnsName www.baidu.com -Server 114.114.114.114
```

系统默认 DNS 测试：

```powershell
Resolve-DnsName www.baidu.com
Resolve-DnsName www.google.com
```

查看 DNS 列表：

```powershell
Get-DnsClientServerAddress -AddressFamily IPv4
```

查看路由：

```powershell
route print -4
```

或：

```powershell
Get-NetRoute -AddressFamily IPv4
```

## 11. 经验教训

1. DNS 慢不一定是 DNS 服务器慢，也可能是系统默认 DNS 选择过程慢。
2. 显式指定 DNS 测试和系统默认 DNS 测试都要做。
3. VPN 客户端下发的 DNS 和路由不一定合理，需要实际验证。
4. Windows 多网卡 DNS 行为比单网卡复杂，metric、DNS 列表、历史状态都会影响结果。
5. Mihomo `strict-route` 在 Windows 上会加防 DNS 泄露规则，和 SSLVPN 共存时要谨慎。
6. `dns-hijack`、`strict-route`、`DNS 覆写` 是三种不同层面的功能，不要混为一谈。
7. 对于企业内网域名，正确方案应该是公司 VPN 下发内网 DNS 或 split DNS，而不是让用户手动 hosts。
8. 如果 VPN 管理侧配置不专业，本机侧可以通过覆盖 SSLVPN DNS、调整 Mihomo 配置来规避。
9. 不要把 WLAN 已经使用的 DNS `192.168.124.1` 再设置到 SSLVPN 网卡上；显式 DNS 测试虽快，但 Windows 默认解析可能会因为多接口重复 DNS 而进入长时间回退。

## 12. 当前推荐长期状态

推荐组合：

```text
Clash/Mihomo:
  TUN 可开
  strict-route: false
  DNS 覆写开启
  use-system-hosts: true

瑞捷 SSLVPN:
  连接后把 SSLVPN 网卡 DNS 覆盖为 114.114.114.114
  如果长期使用 TUN，也可以覆盖为 198.18.0.2

Windows:
  WLAN 继续通过 DHCP 使用 192.168.124.1
  公司内网特殊域名继续使用 hosts，除非公司后续提供内网 DNS
```

如果以后公司修正 SSLVPN 后台配置，开始下发真正的公司 DNS，则需要重新评估是否还应该清空 SSLVPN DNS。
