# DNSPilot

[English](README.md) | 简体中文

DNSPilot 是原生 macOS DNS Proxy 工具，用于管理普通 DNS 和 DNS-over-HTTPS Profile。用户可以手动选择 Profile，也可以根据有序的 Wi-Fi SSID、接口类型和子网 Rule 自动选择。

## 功能

- 普通 DNS：UDP 优先、TCP fallback，并支持原生 TCP flow。
- DNS over HTTPS 与显式 bootstrap address。
- 根据有序网络 Rule 自动选择 Profile。
- 持久化 Manual mode 和用户指定的 Default Profile。
- 原生管理窗口、Settings 窗口和菜单栏控制。
- Exact runtime identity、认证后的 Host/Extension IPC 和有界 DNS 恢复。
- 无账号、订阅、内购、receipt 检查、license key 或 Profile 数量限制。

官方版本与源码自编译版本具有相同产品功能和配置格式。

## 要求

- macOS 15 或更高版本。
- Xcode 26.4 build 17E192，Apple Swift 6.3。
- 签名安装需要 Apple Developer Team 获得 `dns-proxy` Network Extension entitlement。
- Team 自有的 Host、System Extension 和 App Group identifier。

Entitlement 是否批准由 Apple 决定。Apache-2.0 许可证不提供签名凭据、provisioning profile、entitlement、官方品牌或商店分发权。

## Community 构建

```bash
cp Configurations/Identity.local.xcconfig.example \
   Configurations/Identity.local.xcconfig
```

把 `IDENTITY_TEAM_IDENTIFIER` 和 `IDENTITY_BUNDLE_ID_PREFIX` 设置为你的 Team 所拥有的值，配置匹配的 Apple identifier 与 provisioning，然后使用 `DNSPilot Community` scheme。

本地 identity 文件被 Git 忽略。Unsigned build 可以编译并运行非 UI 测试，但不能证明 System Extension 安装、XPC authentication、系统授权或 DNS behavior。

构建命令与身份派生方式见[构建文档](docs/zh/building.md)。

## 文档

- [中文文档](docs/zh/README.md)
- [English documentation](docs/en/README.md)
- [产品设计](docs/zh/design/product.md)
- [系统架构](docs/zh/design/architecture.md)
- [运行时设计](docs/zh/design/runtime.md)
- [工具链基线](docs/zh/design/toolchain.md)
- [测试策略](docs/zh/design/testing.md)
- [发布要求](docs/zh/releasing.md)

## 隐私

DNSPilot 不运营账号、analytics 或 telemetry 服务。DNS query 会发送到用户选择的 resolver。Location 权限只用于获取当前 Wi-Fi 名称以匹配 SSID Rule。Debug Logging 和显式 diagnostic export 可能包含敏感 DNS 与网络信息。分享日志前请阅读 [PRIVACY.md](PRIVACY.md)。

## 限制

- DNSPilot 不检测、控制或修复 VPN DNS 优先级。
- VPN、其他 DNS Proxy、Fake-IP 服务或 scoped resolver 可能使 DNSPilot 无法观察全部 DNS 流量。
- 正常 Quit 会尝试恢复 System DNS；crash 或 Force Quit 无法保证清理。
- AGDnsProxy 是锁定版本的预编译依赖，受 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) 约束。
- [AGDnsProxy transitive inventory](docs/zh/compliance/agdnproxy-v2.8.45.md) 完成前禁止重新分发应用二进制。

## 开发

```bash
export DEVELOPER_DIR="/Applications/Xcode-26.4.0.app/Contents/Developer"
scripts/ci/all.sh
```

该命令运行 repository check、串行非 UI 测试、static analysis 和 unsigned universal Community build。UI 或签名系统状态测试需要明确授权和匹配 provisioning。

## 项目政策

- [参与贡献](CONTRIBUTING.md)
- [安全](SECURITY.md)
- [隐私](PRIVACY.md)
- [支持](SUPPORT.md)
- [品牌](BRANDING.md)
- [第三方声明](THIRD-PARTY-NOTICES.md)
- [变更记录](CHANGELOG.md)

DNSPilot 源码使用 Apache License 2.0，参见 [LICENSE](LICENSE) 和 [NOTICE](NOTICE)。
