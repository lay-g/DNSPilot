# 产品设计

[English](../../en/design/product.md)

## 产品目标

DNSPilot 是原生 macOS DNS 工具，通过 DNS Proxy System Extension 转发系统 DNS 流量。用户可以创建 DNS Profile，并根据当前网络手动或自动选择 Profile。

## 支持能力

- 普通 DNS：UDP 优先、TCP fallback，并支持原生 TCP DNS flow。
- DNS over TLS：证书校验与 bootstrap resolution 由 DnsLibs 负责。
- DNS over HTTPS：使用 DNS wire format。
- 根据 Wi-Fi SSID、活动接口类型和 IPv4/IPv6 子网按顺序自动匹配 Rule。
- 通过现有 Profile 或不持久化的自定义 Plain DNS、DoT、DoH upstream 执行一次性 DNS 查询，并展示返回状态、answer、逻辑 upstream 和耗时。
- 第一条启用且匹配的 Rule 生效；用户指定的 Default Profile 负责兜底。
- Manual 选择持续有效，直到用户明确返回 Automatic。
- 关闭管理窗口后 App 继续运行，并保持当前 DNS Proxy 状态。
- 正常 Quit 尝试禁用 DNS Proxy 并恢复 System DNS。若 Proxy 已确认开启，下次启动会在 lifecycle evidence、manager ownership、配置与 Extension readiness 仍一致时安全恢复开启状态。
- UI 分别展示 Target Profile、已确认的 Active Profile、运行模式、网络上下文、System Extension 状态和 DNS Proxy 状态。

## 平台边界

DNSPilot 要求 macOS 15 或更高版本。签名安装需要 Apple Developer Team 获得 `dns-proxy` Network Extension entitlement。源码许可证不提供证书、provisioning profile、entitlement、官方标识或 App Store 分发权。

## 许可证与构建身份

源码使用 Apache-2.0。构建身份在 Git 外提供，并统一派生 Host、System Extension、App Group、Mach service 和 XPC peer requirement。签名产物会公开其 Team ID 与 Bundle ID。
