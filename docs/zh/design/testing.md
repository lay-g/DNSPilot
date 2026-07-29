# 测试策略

[English](../../en/design/testing.md)

DNSPilot 将确定性的自动检查与需要签名、macOS 授权、网络 fixture 或人工 UI 检查的操作分开。历史测试轮次和机器相关 evidence 不作为长期设计文档保存。

## 自动单元测试

Unit 与 contract test 覆盖：

- Profile、upstream、Rule、IP、CIDR 和引用校验。
- Rule 顺序、AND/OR、SSID availability 和 Default fallback。
- Configuration schema、canonical encoding、fingerprint、atomic commit、损坏保留和 compare-and-swap conflict。
- Automatic/Manual 持久化、target coalescing、stale decision 和 session fencing。
- Mutation journal authentication、compensation、crash recovery 和 cleanup。
- Runtime payload、exact identity、replay、rate limit、rollback、quiescence、resume 和 recovery classification。
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
- Plain DNS、DoH、switching、retry、sleep/wake 和 restoration。
- Network 与 active-user-session change。
- 与其他 DNS/VPN 产品的冲突。
- Crash recovery 与正常 Quit restoration。

改变 UI 或系统状态的 signed validation 必须获得用户明确授权。

## 人工 UI 边界

除非当前任务明确授权 UI automation，不启动并操作 App，不点击授权弹窗，也不使用 XCUITest、Playwright 或 browser-style automation。窗口行为、菜单一致性、keyboard-only、VoiceOver、长本地化、权限弹窗、contrast、transparency、motion 和 Quit alert 仍需人工检查。

未执行这些检查时，必须列为剩余验证，不能宣称完整验收。
