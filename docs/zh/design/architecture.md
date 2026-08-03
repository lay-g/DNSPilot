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
  MachXPCClient、UpstreamValidator 与 DNSQueryTester

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

System lifecycle layer 属于 Host，负责首次启用、Restore System DNS、正常 Quit、耐久的 Extension replacement 协调和有界修复。只有这一层可以写 `NEDNSProxyManager`。Runtime quiesce/resume 是 lifecycle 操作，不是普通 Profile 切换。SwiftUI 与 `SystemExtensionController` 只能通过该 Host coordination boundary 请求 replacement，绝不能写 manager。

Runtime switching layer 属于 Extension，通过 authenticated Mach XPC 访问。它把已持久化的 desired bytes 应用到当前 Provider instance，执行 single-engine rollback，在 mutation 期间管理 flow admission，并发布 exact runtime identity。

## 唯一事实源

| 事实 | Owner | 持久化 |
| --- | --- | --- |
| Profiles、Rules、Default、mode、DNS cache 设置 | Host `AppConfiguration` | 持久化 |
| Desired runtime configuration | `NEDNSProxyManager.providerConfiguration` | 持久化 |
| Actual runtime 与最后确认 bytes | `ProxyLifecycleController` | 进程内 |
| Runtime phase 与 evidence | `RuntimeStatusStore` | 进程内 |
| Profile mutation compensation | Host mutation journal | 仅恢复持久化 |
| Safe Quit resume 与 Extension replacement evidence | Host lifecycle journal | 持久化、一次性 |
| Extension 安装与批准 | macOS | 系统拥有 |

任何层都不得静默复制、替换或推断另一层的事实源。

Lifecycle journal 只记录 DNSPilot 在 safe Quit 中准备或完成了一次 exact manager disable，以及可选的、将一个已安装 Extension build 绑定到一个 bundled replacement build 的 transaction。它是下一次启动进行一次 reconciliation 的证据，不是 desired-runtime 事实源，也不能独立授权 manager 写入。

## 通信边界

Host 和 Extension 只通过由构建身份派生的 Mach service 通信。App Group entitlement 只授权 Mach service namespace。Host 配置保存在私有 Application Support storage，runtime status 保存在 Extension 进程内。

Extension 接收一份 immutable `ActiveProxyConfiguration`，内容包括 schema version、generation 与 Profile identity、upstream 配置、runtime logging mode 和 DNS cache 设置。

## 依赖边界

`AGDnsProxy` 是唯一 DNS transport engine。DNSPilot 只映射配置、把 Network Extension flow 交给 `AGDnsAppProxyFlowManager`、桥接事件和日志，并管理 runtime identity。DNS wire 解析、request ID、UDP/TCP exchange、TC fallback、DoH、bootstrap、TLS、HTTP connection reuse、取消和 transport cleanup 均由 DnsLibs 负责。

Host 通过 `AGDnsUtils.testUpstream` 使用同一份纯 upstream mapping 做预检。Host 还为用户明确发起的 DNS Test query 持有隔离、临时的 `AGDnsProxy`。Host 构造一个通过校验的 DNS question；DnsLibs 负责 exchange 与 response parsing，并返回 status、answer、upstream ID、elapsed time、byte counts 和 error 的 immutable snapshot。临时 proxy 没有 listener 或 cache，并在完成、timeout 或 cancellation 后停止。

DNS Test 不直接调用 System Extension runtime，不写 `NEDNSProxyManager`，不改变 Active Profile，也不实现独立 transport。macOS 仍可能把 Host 创建的 53 端口 Plain DNS flow 交给 Active DNS Proxy；UI 会提示该查询可能经 Active Profile 转发。逻辑服务器展示来自用户选择的配置，不能证明实际连接服务器；bootstrap address 绝不作为实际连接服务器展示。Runtime、preflight 与 DNS Test transport 都通过 DnsLibs 实现。

## 登录会话边界

只有当前活动桌面登录会话可以触发自动切换。GUI session 失活时 Host 停止网络驱动决策；重新激活后必须获取新的网络上下文，再恢复 Automatic。
