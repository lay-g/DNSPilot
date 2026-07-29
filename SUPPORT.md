# DNSPilot Support

[中文](#dnspilot-支持)

DNSPilot supports macOS 15 or later. Before reporting a problem, update to the latest available DNSPilot version and macOS update, then check Settings > Diagnostics for the current DNS Proxy and System Extension state.

## Get Help

Use the [public issue tracker](https://github.com/lay-g/DNSPilot/issues) for reproducible bugs and feature requests. Search existing issues first and include:

- DNSPilot version and build number;
- macOS version and Mac architecture;
- whether the app came from the Mac App Store or another build source;
- the action you attempted, expected behavior, and observed behavior;
- the reduced diagnostic summary from Settings > Diagnostics, when relevant.

Do not post DNS query names, Wi-Fi names, IP addresses, private resolver URLs, endpoint tokens, certificates, provisioning profiles, signing details, packet captures, or unredacted diagnostic exports. Replace private values with synthetic examples.

For a suspected vulnerability or a report containing confidential security information, follow [SECURITY.md](SECURITY.md) or email [security@lay-g.com](mailto:security@lay-g.com). Do not open a public issue.

## Common Checks

- If the System Extension is awaiting approval, open System Settings from DNSPilot, approve it, and select Check Again.
- If Wi-Fi-name Rules are unavailable, review Location access in System Settings. Interface and subnet Rules do not require Location access.
- If a Profile fails its test, confirm the resolver address, port, DNS over HTTPS URL, bootstrap addresses, and current network access.
- Before removing DNSPilot, use Restore System DNS and confirm that DNS Proxy is Off.

DNSPilot has no user accounts or developer-operated DNS service. Questions about resolver availability, filtering, retention, or blocking policy should be directed to the resolver operator selected in the active Profile.

# DNSPilot 支持

[English](#dnspilot-support)

DNSPilot 支持 macOS 15 或更高版本。报告问题前，请更新到当前可用的最新 DNSPilot 版本和 macOS 更新，并在“Settings > Diagnostics”中检查 DNS Proxy 与 System Extension 状态。

## 获取帮助

对于可复现缺陷和功能建议，请使用[公开 Issue Tracker](https://github.com/lay-g/DNSPilot/issues)。请先搜索已有 Issue，并提供：

- DNSPilot 版本和构建号；
- macOS 版本和 Mac 架构；
- App 来自 Mac App Store 还是其他构建来源；
- 执行的操作、预期行为和实际行为；
- 必要时提供“Settings > Diagnostics”中的精简诊断摘要。

请勿公开 DNS 查询名称、Wi-Fi 名称、IP 地址、私有解析器 URL、endpoint token、证书、provisioning profile、签名信息、抓包文件或未经脱敏的诊断导出。请使用虚构示例替换私密值。

如果怀疑存在安全漏洞，或报告包含机密安全信息，请按照 [SECURITY.md](SECURITY.md) 操作，或发送邮件至 [security@lay-g.com](mailto:security@lay-g.com)。请勿创建公开 Issue。

## 常见检查

- 如果 System Extension 正在等待批准，请从 DNSPilot 打开 System Settings，完成批准后点击“Check Again”。
- 如果 Wi-Fi 名称 Rule 不可用，请检查 System Settings 中的位置权限。接口和子网 Rule 不需要位置权限。
- 如果 Profile 测试失败，请检查解析器地址、端口、DNS over HTTPS URL、bootstrap 地址和当前网络连接。
- 移除 DNSPilot 前，请使用“Restore System DNS”，并确认 DNS Proxy 已关闭。

DNSPilot 不提供用户账号或开发者运营的 DNS 服务。有关解析器可用性、过滤、保留或拦截策略的问题，请联系活动 Profile 所选解析器的运营方。
