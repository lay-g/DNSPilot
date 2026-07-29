# 系统架构

[English](../../en/design/architecture.md)

## 可执行单元

DNSPilot 包含两个可执行单元：

```text
DNSPilot.app
  SwiftUI 与 MenuBarExtra
  ConfigurationStore 与 RuleEngine
  NetworkMonitor
  SystemExtensionController
  DNSProxyController 与 DNSProxyManagerClient
  MachXPCClient 与 UpstreamValidator

DNSPilot DNS Proxy System Extension
  NEDNSProxyProvider
  MachXPCServer
  ProxyLifecycleController
  DNSProxyEngine
  AGDnsProxy 与 AGDnsAppProxyFlowManager
  RuntimeStatusStore
```

Host 负责用户配置、Location 权限、网络观察、Profile 选择、System Extension 管理、全部 `NEDNSProxyManager` 写入和用户可见状态。System Extension 负责 DNS flow、单一进程内 DNS runtime、认证后的运行时控制和 actual runtime evidence。

## 所有权分层

System lifecycle layer 属于 Host，负责首次启用、Restore System DNS、正常 Quit、Extension replacement 和有界修复。只有这一层可以写 `NEDNSProxyManager`。Runtime quiesce/resume 是 lifecycle 操作，不是普通 Profile 切换。

Runtime switching layer 属于 Extension，通过 authenticated Mach XPC 访问。它把已持久化的 desired bytes 应用到当前 Provider instance，执行 single-engine rollback，在 mutation 期间管理 flow admission，并发布 exact runtime identity。

## 唯一事实源

| 事实 | Owner | 持久化 |
| --- | --- | --- |
| Profiles、Rules、Default、mode | Host `AppConfiguration` | 持久化 |
| Desired runtime configuration | `NEDNSProxyManager.providerConfiguration` | 持久化 |
| Actual runtime 与最后确认 bytes | `ProxyLifecycleController` | 进程内 |
| Runtime phase 与 evidence | `RuntimeStatusStore` | 进程内 |
| Profile mutation compensation | Host mutation journal | 仅恢复持久化 |
| Extension 安装与批准 | macOS | 系统拥有 |

任何层都不得静默复制、替换或推断另一层的事实源。

## 通信边界

Host 和 Extension 通过由构建身份派生的 Mach service 通信。两者不使用 App Group 文件、共享 `UserDefaults`、Darwin Notification、`/Users/Shared` 或其他共享持久化存储。App Group entitlement 只授权 Mach service namespace。

Extension 只接收一个 immutable `ActiveProxyConfiguration`，不接收 Profile catalog、Rules、SSID、UI state、发行状态或购买状态。

## 依赖边界

`AGDnsProxy` 是唯一 DNS transport engine。DNSPilot 只映射配置、把 Network Extension flow 交给 `AGDnsAppProxyFlowManager`、桥接事件和日志，并管理 runtime identity。DNS wire 解析、request ID、UDP/TCP exchange、TC fallback、DoH、bootstrap、TLS、HTTP connection reuse、取消和 transport cleanup 均由 DnsLibs 负责。

Host 通过 `AGDnsUtils.testUpstream` 使用同一份纯 upstream mapping 做预检。DNSPilot 不得创建平行 transport，也不得在 DnsLibs 外修补 raw DNS response。

## 登录会话边界

只有当前活动桌面登录会话可以触发自动切换。GUI session 失活时 Host 停止网络驱动决策；重新激活后必须获取新的网络上下文，再恢复 Automatic。
