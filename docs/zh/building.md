# 构建 DNSPilot

[English](../en/building.md)

## 要求

- macOS 15 或更高版本。
- Xcode 26.4 build 17E192，Apple Swift 6.3。
- 签名运行需要 Apple Developer Team 获得 `dns-proxy` entitlement。

修改 Swift、Xcode setting、build script 或 CI 前阅读[工具链基线](design/toolchain.md)。

## 身份配置

创建被 Git 忽略的本地文件：

```bash
cp Configurations/Identity.local.xcconfig.example \
   Configurations/Identity.local.xcconfig
```

填写由你的 Apple Developer Team 拥有的值：

```xcconfig
IDENTITY_TEAM_IDENTIFIER = ABCDE12345
IDENTITY_BUNDLE_ID_PREFIX = org.example
```

构建会派生 Host/System Extension Bundle ID、App Group、versioned Mach service、测试 identifier 和双方 XPC requirement。不要提交该文件。

| Configuration | Host suffix | Extension suffix | 用途 |
| --- | --- | --- | --- |
| DebugLocal | `.DNSPilot.dev` | `.DNSPilot.dev.DNSProxy` | 本地诊断与 failure control |
| Community | `.DNSPilot` | `.DNSPilot.DNSPilot-NE` | 源码构建与公开 CI |
| Sandbox | `.DNSPilot` | `.DNSPilot.DNSPilot-NE` | Store sandbox 验证 |
| Release | `.DNSPilot` | `.DNSPilot.DNSPilot-NE` | 分发候选 |

证书保存在 Keychain 或受保护 CI。Provisioning profile 和 Store credential 永不提交。

## Community 验证

```bash
export DEVELOPER_DIR="/Applications/Xcode-26.4.0.app/Contents/Developer"
scripts/check-toolchain.sh
scripts/ci/all.sh
```

CI 入口依次运行 repository policy check、串行非 UI 测试、static analysis 和 unsigned universal Community build。

不签名检查派生身份：

```bash
xcodebuild -project DNSPilot.xcodeproj \
  -scheme "DNSPilot Community" \
  -configuration Community \
  -showBuildSettings \
  IDENTITY_TEAM_IDENTIFIER=ABCDE12345 \
  IDENTITY_BUNDLE_ID_PREFIX=org.example \
  CODE_SIGNING_ALLOWED=NO
```

命令行 build setting 优先于 xcconfig，适合 CI secret。签名构建还需要匹配的 Host、Extension、App Group 和 `dns-proxy` provisioning。

## 签名构建

Provisioning 完成后，使用同一 scheme 且不禁用 signing。改变系统状态前检查 Host、embedded Extension、两份 AGDnsProxy、entitlement、designated requirement、Bundle ID、build number 和 architecture。Runtime acceptance candidate 从 `/Applications` 安装。

Unsigned build/test 不能证明安装、XPC authentication、authorization 或 DNS behavior。
