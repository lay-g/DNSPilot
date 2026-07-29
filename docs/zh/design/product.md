# 产品设计

[English](../../en/design/product.md)

## 产品目标

DNSPilot 是菜单栏优先的 macOS 工具，通过 DNS Proxy System Extension 转发系统 DNS 流量。用户可以创建 DNS Profile，并根据当前网络手动或自动选择 Profile。

## 支持能力

- 普通 DNS：UDP 优先、TCP fallback，并支持原生 TCP DNS flow。
- DNS over HTTPS：使用 DNS wire format。
- 根据 Wi-Fi SSID、活动接口类型和 IPv4/IPv6 子网按顺序自动匹配 Rule。
- 第一条启用且匹配的 Rule 生效；用户指定的 Default Profile 负责兜底。
- Manual 选择持续有效，直到用户明确返回 Automatic。
- 关闭管理窗口不退出 App，也不关闭 DNS Proxy。
- 正常 Quit 尝试禁用 DNS Proxy 并恢复 System DNS。
- UI 分别展示 Target Profile、已确认的 Active Profile、运行模式、网络上下文、System Extension 状态和 DNS Proxy 状态。

官方版本和源码自编译版本具有相同功能和配置格式。DNSPilot 不包含订阅、内购、账号、receipt 检查、license key、Profile 数量限制或付费功能门槛。

## 平台边界

DNSPilot 要求 macOS 15 或更高版本。签名安装需要 Apple Developer Team 获得 `dns-proxy` Network Extension entitlement。源码许可证不提供证书、provisioning profile、entitlement、官方标识或 App Store 分发权。

如果 VPN、其他 DNS Proxy、Fake-IP 服务或 scoped resolver 已接管 DNS，DNSPilot 不保证拦截这些请求，也不检测或修复 VPN DNS 优先级。

## 非目标

- DoT、DNSCrypt、DoQ 或自定义 DNS JSON API。
- Query 历史、统计、缓存控制、过滤或 DNSSEC 控制。
- 多上游 failover、负载均衡、域名分流或应用分流。
- VPN 控制、Captive Portal 自动化、Hosts、Route 或系统代理修改。
- 账号、云同步、配置导入导出或独立更新服务。
- 隐藏 fallback resolver，或上游失败后静默替换目标。

## 分发原则

源码使用 Apache-2.0。官方版本可以使用受保护的名称、图标、签名资产、标识和商店元数据，但这些资产不改变功能。签名产物必然会公开其 Team ID 与 Bundle ID。

应用二进制分发必须满足[发布要求](../releasing.md)和 [AGDnsProxy 合规清单](../compliance/agdnproxy-v2.8.45.md)。
