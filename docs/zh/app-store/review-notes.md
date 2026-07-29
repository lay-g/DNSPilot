# App 审核备注

[English](../../en/app-store/review-notes.md)

提交前替换方括号中的构建版本。以下内容用于 App Review Information 的备注字段。

## 可直接使用的备注

DNSPilot `[版本] ([构建号])` 是一款菜单栏优先的 macOS DNS 配置工具。它使用 Apple NetworkExtension 和 SystemExtensions framework 实现内置 DNS Proxy System Extension。App 不包含账号、购买、订阅、广告、分析、遥测或开发者运营的后端。

System Extension 安装和 DNS Proxy 启用是 onboarding 中两个独立、明确的用户操作。macOS 可能要求用户在 System Settings 中批准。App 不会请求 root 凭据，也不会安装独立 App 或更新器。

建议在 macOS 15 或更高版本按以下流程审核：

1. 启动 DNSPilot，进入 Profile 设置。
2. 选择内置解析器或 Custom，然后使用“Test and Continue”。测试会通过该解析器执行一次 DNS 查询。
3. 可以不授予位置权限继续，也可以授权以测试 Wi-Fi 名称 Rule。位置权限仅用于读取当前 Wi-Fi SSID；接口和子网 Rule 不依赖该权限。
4. 点击“Install”安装 System Extension。如果 macOS 显示等待批准，请在 System Settings 中批准 DNSPilot，然后返回 App。
5. 点击“Enable DNS Proxy”。只有在 System Extension 确认活动运行配置后，App 才会显示完成。
6. 在管理窗口中使用 Profiles 和 Rules，也可以从菜单栏切换 Automatic/Manual 模式。
7. 移除或停用扩展前使用“Restore System DNS”。从菜单选择 Quit 时也会尝试确认 System DNS 已恢复。

DNS 流量直接发送到活动 Profile 选择的解析器。App 配置与 Rule 仅保存在当前 macOS 用户本地。Debug Logging 默认关闭，启用前会显示敏感数据警告。诊断导出是可选操作，需要用户确认，并且只写入用户选择的位置。

Mac App Store 版本使用的 Network Extension entitlement 值为 `dns-proxy`。Host 负责用户配置和 `NEDNSProxyManager` 写入；System Extension 负责 DNS flow 处理和单个进程内 AGDnsProxy runtime。

不需要审核账号或外部硬件。测试公共 DNS 解析器需要互联网连接。如果 System Extension 批准界面没有出现或激活持续等待，请通过本次提交中提供的联系信息联系 `[APP 审核联系人]`。

## 提交检查

- 替换 `[版本]`、`[构建号]` 和 `[APP 审核联系人]`。
- 使用最终上传构建逐项核对操作说明。
- 审核期间保持公共 DNS 解析器服务可访问。
- 仅在 App Review 要求时附加 entitlement 支持材料。
- 不描述仅供开发的验收控制或尚不可用的功能。
