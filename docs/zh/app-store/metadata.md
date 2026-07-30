# App Store 元数据

[English](../../en/app-store/metadata.md)

本文档包含首次 Mac App Store 发布可直接使用的元数据。提交前必须替换所有方括号字段。

## App 信息

- 名称：`DNSPilot`
- 副标题：`按网络自动切换 DNS`
- 主要类别：`工具`
- 次要类别：`开发者工具`
- 内容版权：选择`否`。DNSPilot 不包含、展示或访问第三方内容；开源软件依赖仍须单独通过二进制发布许可证合规检查。
- 自定义许可协议：无，使用 Apple 标准《许可应用程序最终用户许可协议》。
- 版权：`[年份] [法定名称]`

## URL

- 技术支持 URL：`https://github.com/lay-g/DNSPilot/blob/main/SUPPORT.md`
- 隐私政策 URL：`https://github.com/lay-g/DNSPilot/blob/main/PRIVACY.md`
- 营销 URL：`https://github.com/lay-g/DNSPilot`

提交前应保持仓库公开，并在未登录状态下验证这些 URL。

## 宣传文本

创建并测试普通 DNS、DNS over TLS 和 DNS over HTTPS Profile，然后从菜单栏切换，或让网络 Rule 自动选择。

## 描述

DNSPilot 是一款管理 Mac 所用 DNS 解析器的原生 macOS 工具。

你可以创建、复制、编辑和测试普通 DNS、DNS over TLS 或 DNS over HTTPS Profile，然后从 App 或菜单栏快速切换。自动模式按照 Rule 顺序，根据当前 Wi-Fi 名称、活动接口类型或 IPv4、IPv6 子网选择 Profile；手动模式会持续使用指定 Profile，直到你返回自动模式。

DNSPilot 将配置保存在 Mac 本地，不要求注册账号。位置权限是可选的，仅用于读取当前 Wi-Fi 名称以匹配 SSID Rule。拒绝位置权限后，接口和子网 Rule 仍可正常工作。

主要功能：

- 普通 DNS，优先 UDP 并支持 TCP fallback
- 支持证书验证的 DNS over TLS
- 使用 DNS wire format 的 DNS over HTTPS
- 按顺序匹配 Rule，并由 Default Profile 兜底
- 自动与手动运行模式
- 菜单栏控制与明确的活动状态
- Profile 启用前测试
- 明确恢复 System DNS，并提供诊断信息

DNS 查询会发送到活动 Profile 中选择的解析器。解析器运营方和网络提供方依据各自条款与隐私政策处理相关流量。

需要 macOS 15 或更高版本。

## 关键词

`DoH,DoT,加密DNS,域名解析,网络切换,Wi-Fi,SSID,隐私,菜单栏,自动切换,配置文件`

## 首次发布摘要

DNSPilot 首次发布，支持普通 DNS、DNS over TLS 与 DNS over HTTPS Profile、基于网络的自动 Rule、菜单栏控制、Profile 测试、诊断和经过确认的 System DNS 恢复。

App Store Connect 不为 App 的首个版本提供“此版本的新功能”字段。仅在其他位置要求首次发布摘要时复用本段，不要尝试把它填写为版本 1.0 的更新说明。

## App 隐私草案

App Store Connect 暂定回答：开发者`不收集数据`。

正式提交前必须根据最终签名二进制和 Apple 当时的定义重新确认，特别是确认用户选择的解析器不被视为开发者控制的第三方合作伙伴。DNSPilot 本身没有账号系统、分析、广告、遥测、崩溃上报 SDK 或开发者运营的后端。DNS 流量会按功能需要发送给用户选择的解析器；诊断导出仅由用户明确操作并保留在用户控制下。

## 提交检查

- 将 `[年份] [法定名称]` 替换为 App Store Connect 销售主体对应的版权方。
- 确认技术支持 URL 按销售地区法律要求提供通用支持邮箱、法定地址或电话号码；仅提供公开 Issue Tracker 可能无法满足所有 storefront。
- 确认最终价格和销售地区。
- 分发前完成开源二进制许可证和声明清单审查。
- 根据归档二进制重新检查 App 隐私答案。
- 根据最终二进制的加密功能完成出口合规问卷。
- 上传真实使用界面的截图，不使用占位内容或仅供开发的验收控制。
