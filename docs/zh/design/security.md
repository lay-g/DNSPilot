# 安全与 IPC 设计

[English](../../en/design/security.md)

## 构建身份

Team 与 Bundle identity 通过被忽略的本地配置或受保护 CI 值注入，公开默认值全部是 synthetic。Host、System Extension、App Group、Mach service 和 XPC peer requirement 从同一组输入派生。

双方都在 activate XPC connection 前安装 code-signing requirement，绑定预期 Apple signing anchor、Team ID 和环境对应 Bundle ID。Extension 还要求 effective user ID 等于当前 console user。PID 只用于诊断。

## Mach XPC 合同

Mach service name 按 build version 化，并位于 App Group namespace。Service 提供只读 status/evidence，以及有界的 reapply、quiesce、resume runtime command。

Selector 只接收 `Data`，返回 `Data` 与 `NSError`。Write message 必须是 exact-key strict binary property list。未知字段需要 protocol revision。

- 最大 write envelope：64 KiB。
- 最大 embedded runtime configuration：48 KiB。
- 同时最多一个 runtime mutation。
- Process-local token bucket：8 requests/秒，burst 16。
- Terminal replay cache：最多 32 个 operation，并限定 lifecycle epoch。

Admission 在 decode、single-flight 或 replay lookup 前计费。Malformed、oversized、replayed 和 conflicting request 使用同一预算。

## Compare-And-Swap Identity

Provider instance、lifecycle epoch、base generation、base fingerprint、target fingerprint、operation ID 和 exact request bytes 共同组成 mutation boundary。

相同 operation ID 与相同 bytes 返回 cached terminal response；同一 ID 配不同 bytes 必须拒绝。Stale 或结构无效的 request 不能授权 rollback、manager disable、runtime adoption 或 Profile publication。

Host 校验 response protocol、operation identity、Provider instance、各 disposition 必需字段、target/base identity、preserved exact bytes 和 forbidden fields。Malformed response 视为 control outcome 未知。

## 数据最小化

XPC 不接收 Profile catalog、Rules、SSID、文件路径、任意 command string、shell command 或 DNS query data。Runtime status 是进程内 evidence，不是持久化配置通道。

配置与恢复文件位于私有目录并使用严格权限。DNS name、SSID、地址、子网、answer、endpoint path、token、bootstrap 和 raw runtime payload 都是私有数据。

默认日志避开这些值。Debug Logging 必须先警告，并可能暴露这些内容。复制 diagnostic summary 需要降敏；显式 export 被视为敏感操作并要求确认。

## 失败策略

Authentication、ownership、schema、replay、rate-limit 或 identity 不确定时 fail closed。外部 manager change 只观察，不自动覆盖。Legacy read-only runtime-control 允许查看 status，但在安装兼容 Extension 前禁止 active Profile switching。
