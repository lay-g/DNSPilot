# 工具链与并发基线

[English](../../en/design/toolchain.md)

本文件是 compiler、deployment 与 concurrency 的规范基线。

## 版本

| 项目 | 基线 |
| --- | --- |
| Xcode | 26.4 |
| Xcode build | 17E192 |
| Apple Swift compiler | 6.3 |
| Swift language mode | Swift 6 |
| `SWIFT_VERSION` | `6.0` |
| Strict concurrency | `complete` |
| Default actor isolation | `nonisolated` |
| macOS deployment target | `15.0` |
| Architectures | 依赖支持时使用 `arm64`、`x86_64` |

Compiler version、language mode 和 deployment target 是独立概念。Xcode 26.4 不表示 deployment target 是 macOS 26，上游 `swift-5` artifact 标签也不要求 Swift 5 language mode。

所有 first-party target 从 `Configurations/Base.xcconfig` 继承基线。Project 或 target setting 不得覆盖这些值。

## Isolation 与 Ownership

- SwiftUI-facing type 和 UI command coordinator 显式使用 `@MainActor`。
- `DNSProxyController`、`ProfileMutationCoordinator` 等共享可变 service 使用 actor。
- Rule、CIDR、configuration mapping 和 payload model 使用 `Sendable` value 与纯函数。
- 共享 Contracts 同时在 Host/Extension 编译，不得获得 target-wide actor isolation。
- Test 只在访问 UI-isolated API 的局部使用 `@MainActor`。

`nonisolated` 不保证后台执行。同步阻塞的 `AGDnsUtils.testUpstream` 在 owned serial blocking executor 运行，通过 checked continuation 返回。

## Objective-C 依赖边界

`AGDnsProxy`、flow manager 和 mutable callback 只存在于 Provider lifecycle owner 内，不跨 actor 或 XPC。DnsLibs callback 先复制成 immutable、带 identity 的 event，再进入应用状态。

禁止用 module-wide `@preconcurrency import` 或大范围 `@unchecked Sendable` 消除诊断。必要 escape hatch 必须是 adapter 层最小 wrapper，并说明 ownership 与测试不变量。

## 工具选择

本地命令使用：

```bash
export DEVELOPER_DIR="/Applications/Xcode-26.4.0.app/Contents/Developer"
scripts/check-toolchain.sh
```

CI 可以使用不同安装路径，但必须显式选择并验证相同 Xcode build 和 compiler。不得依赖环境中的 `xcode-select`。

## 升级规则

修改 Xcode、compiler、language mode、strict-concurrency、default isolation、deployment target 或 architecture 时，必须在同一个 reviewed change 中更新本文件、`Configurations/Base.xcconfig`、toolchain check、CI pin、架构约束和相关测试。升级前 Host 与 Extension 都必须成功编译共享 Contracts 和 DnsLibs adapter。
