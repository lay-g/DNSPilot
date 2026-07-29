# DNSPilot Privacy Policy

Last updated: July 29, 2026

[中文](#dnspilot-隐私政策)

This policy applies to the DNSPilot build offered by the seller identified on its Mac App Store listing. Independently distributed builds may have different operators and policies.

## Summary

DNSPilot does not provide user accounts, advertising, analytics, telemetry, or a developer-operated backend. The developer does not receive your DNS configuration, DNS queries, Wi-Fi name, location, or diagnostics through the app.

DNSPilot must send DNS traffic to the resolver selected by you. That resolver and your network providers can process DNS query names, IP addresses, timing, and protocol metadata under their own terms and privacy policies.

## Data Stored on Your Mac

DNSPilot stores the following data locally for the current macOS user:

- Profile names and resolver configuration, including addresses, ports, DNS over HTTPS URLs, and bootstrap addresses;
- Rule names and conditions, which may include Wi-Fi names, interface types, and IPv4 or IPv6 subnets;
- the Default Profile, Automatic or Manual mode, and related app preferences;
- short-lived recovery evidence used to complete or safely reverse an interrupted configuration change.

Configuration and recovery files use private app directories and restrictive file permissions. DNSPilot does not synchronize this data to a developer service.

## DNS Processing

The DNS Proxy System Extension receives DNS flows from macOS and sends them to the resolver selected in the active Profile. DNSPilot supports plain DNS and DNS over HTTPS. It has no persistent DNS-query-history feature. Query data may exist transiently in memory, resolver traffic, and system logs as needed to perform DNS resolution.

Built-in resolver templates are optional starting configurations. Their operators are independent third parties. You can instead configure a resolver of your choice. Review the selected resolver's privacy policy before use.

## Location and Wi-Fi Name

macOS requires Location authorization before an app can read the current Wi-Fi network name. DNSPilot requests this permission only after an explicit user action and uses it only to obtain the Wi-Fi SSID for local Rule evaluation. DNSPilot does not request geographic coordinates and does not send the SSID to the developer.

Location permission is optional. If it is denied, Wi-Fi-name conditions are unavailable, while interface, subnet, Default Profile, and Manual selection continue to work.

## Logs and Diagnostics

Default logging minimizes DNS and configuration details. Debug Logging is off by default and requires confirmation because system logs may then contain full domain names, resolver responses, addresses, Wi-Fi names, resolver endpoints, or endpoint tokens. macOS controls system-log storage and retention.

Copy Diagnostic Summary produces a reduced local summary. Export Diagnostics is an explicit action, requires confirmation, and writes an unredacted file to a location you select. DNSPilot does not upload either form of diagnostic information. If you choose to share a report through GitHub, email, or another service, that service processes the information under its own policy. Review and redact exports before sharing.

## Retention and Deletion

Local configuration remains until you change or remove it. Exported diagnostics remain wherever you saved them. Removing the app may not remove its sandbox container or disable an enabled system-managed DNS Proxy. Restore System DNS before removing DNSPilot, then remove any remaining local app data using macOS if desired.

The developer has no app account or backend copy of this data to delete. Information you voluntarily submit for support is retained by the service you use to submit it and handled only to investigate or respond to the report.

## Third Parties

DNSPilot uses AdGuard DnsLibs/AGDnsProxy for local DNS processing. See [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md). Apple provides macOS, System Extension management, Location authorization, signing, and App Store services. The selected DNS resolver, network providers, GitHub, and any service you use to contact support operate under their own policies.

## Children

DNSPilot is a general-purpose utility and is not directed to children. It does not knowingly collect personal information from children through a developer-operated service.

## Changes and Contact

Material changes to this policy will be published at this URL with an updated date. For privacy questions or confidential privacy reports, email [security@lay-g.com](mailto:security@lay-g.com). For non-sensitive support requests, use [DNSPilot Support](SUPPORT.md).

# DNSPilot 隐私政策

最后更新：2026 年 7 月 29 日

[English](#dnspilot-privacy-policy)

本政策适用于 Mac App Store 页面所列销售方提供的 DNSPilot 构建。由其他主体独立分发的构建可能由不同运营方负责，并适用不同政策。

## 摘要

DNSPilot 不提供用户账号、广告、分析、遥测或开发者运营的后端。开发者不会通过 App 接收你的 DNS 配置、DNS 查询、Wi-Fi 名称、位置或诊断信息。

DNSPilot 必须将 DNS 流量发送到你选择的解析器。该解析器及你的网络提供方可以依据各自条款和隐私政策处理 DNS 查询名称、IP 地址、时间及协议元数据。

## 保存在 Mac 上的数据

DNSPilot 为当前 macOS 用户在本地保存以下数据：

- Profile 名称和解析器配置，包括地址、端口、DNS over HTTPS URL 与 bootstrap 地址；
- Rule 名称和条件，其中可能包括 Wi-Fi 名称、接口类型以及 IPv4 或 IPv6 子网；
- Default Profile、Automatic 或 Manual 模式及相关 App 偏好；
- 用于完成或安全撤销中断配置变更的短期恢复证据。

配置和恢复文件保存在 App 私有目录中，并使用受限文件权限。DNSPilot 不会将这些数据同步到开发者服务。

## DNS 处理

DNS Proxy System Extension 从 macOS 接收 DNS flow，并发送到活动 Profile 选择的解析器。DNSPilot 支持普通 DNS 和 DNS over HTTPS，不提供持久 DNS 查询历史功能。为完成 DNS 解析，查询数据可能短暂存在于内存、解析器流量和系统日志中。

内置解析器模板只是可选的初始配置，其运营方是独立第三方。你也可以配置自行选择的解析器。使用前请查阅所选解析器的隐私政策。

## 位置和 Wi-Fi 名称

macOS 要求 App 获得位置授权后才能读取当前 Wi-Fi 网络名称。DNSPilot 仅在用户明确操作后请求此权限，并且只用它获取 Wi-Fi SSID，以便在本地匹配 Rule。DNSPilot 不请求地理坐标，也不会把 SSID 发送给开发者。

位置权限是可选的。拒绝权限后，Wi-Fi 名称条件不可用，但接口、子网、Default Profile 和 Manual 选择仍可正常工作。

## 日志和诊断

默认日志会尽量减少 DNS 和配置信息。Debug Logging 默认关闭，启用前需要确认，因为系统日志随后可能包含完整域名、解析器响应、地址、Wi-Fi 名称、解析器 endpoint 或 endpoint token。系统日志的保存和保留由 macOS 控制。

“Copy Diagnostic Summary”生成精简的本地摘要。“Export Diagnostics”是需要用户确认的明确操作，会将未经脱敏的文件写入用户选择的位置。DNSPilot 不上传任何一种诊断信息。如果你自行通过 GitHub、邮件或其他服务分享报告，该服务将依据自身政策处理信息。分享前应检查并脱敏导出内容。

## 保留和删除

本地配置会一直保留，直到你修改或移除相关内容。导出的诊断文件保留在你选择的位置。移除 App 不一定会删除其 sandbox container，也不一定会停用系统管理且已启用的 DNS Proxy。移除 DNSPilot 前应先恢复 System DNS，随后可以按需使用 macOS 删除剩余本地 App 数据。

开发者没有需要删除的 App 账号或后端数据副本。你主动提交用于支持的信息由提交时使用的服务保留，并且仅用于调查或回复报告。

## 第三方

DNSPilot 使用 AdGuard DnsLibs/AGDnsProxy 在本地处理 DNS，详见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。Apple 提供 macOS、System Extension 管理、位置授权、签名与 App Store 服务。所选 DNS 解析器、网络提供方、GitHub 以及你用于联系支持的其他服务分别依据各自政策运营。

## 儿童

DNSPilot 是通用工具，并非面向儿童。它不会通过开发者运营的服务故意收集儿童个人信息。

## 变更与联系

本政策如有重大变更，将在此 URL 发布并更新日期。隐私问题或机密隐私报告请发送邮件至 [security@lay-g.com](mailto:security@lay-g.com)；非敏感支持请求请参阅 [DNSPilot 支持](SUPPORT.md)。
