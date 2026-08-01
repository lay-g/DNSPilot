# 数据模型与规则

[English](../../en/design/data-model.md)

## DNS Profile

```swift
struct DNSProfile {
    let id: UUID
    let name: String
    let upstream: DNSUpstream
}

enum DNSUpstream {
    case plain(PlainDNSConfiguration)
    case tls(DoTConfiguration)
    case https(DoHConfiguration)
}
```

Profile UUID 是身份，名称允许重复。名称去除首尾空白后不能为空。普通 DNS 接受 IPv4/IPv6 literal 和 `1...65535` 端口。DoT 接受 hostname 或 IP address 和 `1...65535` 端口，默认端口为 853；hostname 至少需要一个 literal bootstrap address。DoH 必须使用 HTTPS、包含 host、不得包含 user info 或 fragment；endpoint 使用 hostname 时至少提供一个 literal bootstrap address。

显示身份由名称和隐私安全的协议/server 摘要组成。DoT 摘要不包含 bootstrap；DoH 摘要不包含 path、query、token 或 bootstrap。业务逻辑始终使用 UUID。

Default Profile 是用户自有 Profile 的角色。Provider 模板创建普通 Profile，用户可以继续编辑。

## Rule

```swift
struct DNSRule {
    let id: UUID
    let name: String
    let isEnabled: Bool
    let conditions: RuleConditions
    let profileID: DNSProfile.ID
}
```

Rule 至少包含一个条件。已配置的条件组之间使用 AND，同组内多个值使用 OR。SSID 精确且区分大小写。接口条件匹配活动接口类型。子网条件按二进制 IPv4/IPv6 CIDR containment 判断。禁用 Rule 被跳过，第一条启用且匹配的 Rule 生效。

Automatic 按有序 Rules 选择目标，未命中时使用 Default Profile。Manual 持久化选中的 Profile，并忽略网络驱动选择，直到用户返回 Automatic。

## Network Context

`NetworkContext` 记录 path 状态、SSID 及其不可用原因、活动接口类型和所有相关活动 IPv4/IPv6 地址。

SSID 权限拒绝只禁用 SSID 条件；接口和子网 Rule 继续工作。网络变化先按内容去重，再 debounce 1 秒。切换进行中只保留最新决策。

## 配置存储

Profiles、Rules、Default Profile、operating mode 和全局 DNS cache 配置存在一个 versioned `AppConfiguration` 文档。Cache 默认开启，最多保存 1,000 条响应；开启时容量限制为 `1...10,000`，关闭后仍保留最后一个合法容量供再次开启使用。初始空配置使用 Automatic，在至少存在一个有效 Profile 和 Default Profile 前不能启用 DNS Proxy。

加载时校验 schema、重复 identity、全部引用和 cache 范围。持久化 schema 1 和 2 在内存中使用标准 cache 配置 canonical migration 为 schema 3，并且只通过正常 atomic commit path 修改正式文件。更高 schema 进入只读恢复，绝不被旧版本覆盖。损坏输入在提供 reset 前必须保留。

配置采用 canonical encoding 与 fingerprint，通过 compare-and-swap 提交；使用私有 Application Support 目录、严格权限、durable 临时写入和原子替换。`UserDefaults` 只保存 UI preference。

## 引用完整性

删除被引用的 Profile 时，Rules、Default、Manual target 和 Active runtime 都需要显式 replacement。与 Active 不同的 pending Target 必须先完成 reconcile、取消或 Restore System DNS。任何操作都不能留下悬空引用。

## Mutation Journal

Configuration mutation 串行执行。Inactive 修改只需要一次原子配置提交。影响 Active runtime 的 Profile 或 cache 修改使用 compensating transaction，记录：

- operation 与 runtime transaction identity；
- old/draft configuration fingerprint；
- old/draft runtime identity；
- journal phase 与认证 checksum；
- 包含 compensation 所需 exact bytes 的短期私有 payload。

启动时先处理 mutation evidence，再进行普通 runtime reconcile。恢复只能完成 draft、恢复 old state，或清理已验证的 terminal transaction。未知、冲突、不完整或损坏 evidence 进入 recovery-required。只有验证 terminal state 后才能删除恢复文件。

## Lifecycle Resume Journal

Safe Quit 在同一私有 Application Support 目录使用独立的 versioned lifecycle journal。它保存 operation identity、phase、App configuration fingerprint、预期 manager owner 与 localized-description fingerprint、Active generation、Active configuration fingerprint 和 Profile identity，绝不保存 raw runtime bytes、upstream 配置、network context 或 DNS traffic。

Schema 2 增加可选的 Extension upgrade subrecord，包含 operation ID、source/target short 与 build version、pre-update owner fingerprint、replacement attempt ID，以及 `prepared`、`replacementSubmitted` 或 `replacementConfirmed` phase。Schema 1 record 仍可读取并保留原 resume 资格；进入 upgrade transaction 时，使用新验证的 manager evidence 将其重写为 schema 2。Upgrade 处于 prepared 或 submitted 时禁止 resume claim。

Base phase 覆盖 prepared Quit、confirmed disable、claimed launch 与 failed attempt。全部 base/upgrade phase 变更使用 canonical encoding、checksum、durable atomic replacement 和 operation-scoped compare-and-swap。损坏或更高 schema 的 record 会被保留，且绝不能授权自动 enable。Journal 只消费一次，不属于 `AppConfiguration`；`UserDefaults` 仍只保存 UI preference。
