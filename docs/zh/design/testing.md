# 测试策略

[English](../../en/design/testing.md)

DNSPilot 使用确定性自动检查、受控网络 fixture、签名运行时验证和人工 UI 检查。

## 自动单元测试

Unit 与 contract test 覆盖：

- Profile、upstream、Rule、IP、CIDR 和引用校验。
- Plain DNS、DoT 与 DoH 的模型校验、adapter wire mapping、bootstrap conversion 和按 transport 区分的 schema capability gating。
- Rule 顺序、AND/OR、SSID availability 和 Default fallback。
- Configuration schema、canonical encoding、fingerprint、atomic commit、损坏保留和 compare-and-swap conflict。
- Automatic/Manual 持久化、target coalescing、stale decision 和 session fencing。
- Mutation journal authentication、compensation、crash recovery 和 cleanup。
- Safe Quit resume journal encoding、phase fencing、损坏保留、一次性 claim，以及 manager disable 前后的 crash window。
- Runtime payload、exact identity、replay、rate limit、rollback、quiescence、resume 和 recovery classification。
- Manual/Automatic startup resume、fresh-session network selection、Extension readiness gate、exact-disabled manager mismatch 和显式 Keep System DNS 行为。
- Quit key-up、repeat rejection、timeout、cancellation、draft handling 和 exactly-once dispatch。
- 隐私安全的显示 identity 与 diagnostic redaction。

非 UI suite 串行运行，因为部分测试会使用 process-global Network Extension 或 DnsLibs resource。

## 静态与构建验证

每个 code/build-system 变更应运行 repository policy check、pinned toolchain check、非 UI 测试、static analysis 和 unsigned universal Community build。检查 expanded build settings 中的 Swift、deployment、concurrency、派生身份、logging mode 和 architecture。

Build-only 成功不能证明 code signing、entitlement authorization、System Extension activation 或真实 DNS interception。

## 集成验证

受控 DNS/DoH fixture 验证真实 DnsLibs 行为，包括 UDP/TCP fallback、HTTP connection reuse、bootstrap、cancellation、resource limit、重复 lifecycle、rollback 和 stop。Fixture 使用保留地址与 synthetic domain。

## 签名运行时验证

正确 provisioning 的机器用于验证：

- Host、Extension、nested framework 的 signature 与 entitlement。
- System Extension install、approval、replacement 和 deactivation。
- DNS Proxy enablement 与真实 system DNS interception。
- XPC peer authentication 和 wrong-signer rejection。
- Plain DNS、DoT、DoH、switching、retry、sleep/wake 和 restoration。
- Network 与 active-user-session change。
- 与其他 DNS/VPN 产品的冲突。
- Crash recovery 与正常 Quit restoration。

改变 UI 或系统状态的 signed validation 必须获得用户明确授权。

## 人工 UI 验证

人工检查覆盖窗口行为、菜单一致性、keyboard-only、VoiceOver、长本地化、权限弹窗、contrast、transparency、motion 和 Quit alert。UI 与授权检查在获得明确授权的测试机器上执行。
