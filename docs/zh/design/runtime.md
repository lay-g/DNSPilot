# 运行时设计

[English](../../en/design/runtime.md)

## Runtime Identity

每个 desired runtime 由一份 decoded `ActiveProxyConfiguration`、它的 exact binary property-list bytes，以及这些 bytes 的 SHA-256 fingerprint 表示。配置包含 schema version、generation UUID、Profile UUID、upstream、logging mode 和 DNS cache 设置。

每个 generation 只编码一次。Manager 持久化、XPC mutation、runtime application、rollback 和 final verification 使用同一份 bytes。Generation 与 fingerprint 是相互独立的身份维度。

只有 Provider instance、generation、fingerprint、`.ready` phase、兼容 control protocol 和最终 manager ownership reload 全部一致，runtime 才算已确认。

Active Proxy schema capability 按 transport 区分：DoH 至少需要 schema 1，Plain DNS 至少需要 schema 2，DoT 至少需要 schema 3。Schema 1 至 3 隐含标准 DNS cache 配置；自定义容量或关闭 cache 需要 schema 4。Host 在编码需要更高 schema 的 transport 或 cache 设置前先发现经过认证的 Provider capability，绝不能静默丢弃用户请求的设置。Capability 不匹配时必须在预检或 manager mutation 前失败。

## DNS Cache 变更

普通 DNS 响应 cache 是全局设置。默认最多缓存 1,000 条响应；开启时容量接受 `1...10,000`，关闭时向 DnsLibs 传入容量零。Optimistic cache 始终关闭且不提供用户配置。

Proxy Off 时保存只提交 App configuration，并在下次 enable 时生效。存在 exact Active runtime 时，保存使用与 Active Profile 编辑相同的 manager-enabled、authenticated single-engine mutation 和 compensation 路径；upstream 未变化时不重复 upstream preflight。Cache settings reapply 会丢弃旧 cache entry。只有 exact target runtime 与最终 manager verification 均成功后才发布成功；结果不确定时进入 recovery-required。

## Single-Engine Lifecycle

Provider process 只拥有一个 `AGDnsProxy` 和一个 `AGDnsAppProxyFlowManager`。

- 启动时解码并校验 manager exact bytes，发布 `.starting`，创建 engine，再发布 exact `.ready` identity。
- UDP/TCP flow 直接以 redirect mode 交给 flow manager。
- Provider 全局 active local-flow 上限为 256。
- Flow admission、start、reapply、quiesce、resume 和 stop 由同一个 lifecycle ownership boundary 线性化。
- Teardown 先停止 flow manager，再停止 proxy；清理 event routing，并保持幂等。
- Quiescence 保留 exact stopped generation 与 configuration，供 lifecycle resume 使用。
- Resume 只允许从 exact quiescence 发起，并使用保留的 exact bytes 重建 engine。

旧 generation、lifecycle epoch 或 Provider instance 的 late callback 不得更新当前状态。

## 普通 Profile 切换

普通切换全程保持 `NEDNSProxyManager` enabled：

1. 确认 manager ownership、exact desired bytes、Active Profile、Provider instance、runtime identity、`.ready` phase 和 runtime-control compatibility。
2. 对 target upstream 做预检。
3. 创建 fresh generation 与 operation ID，只编码一次 target。
4. 使用 compare-and-save 把 exact target bytes 写入 enabled manager。
5. Reload 并验证 enabled、owner、bytes、generation 和 fingerprint。
6. 启动 5 秒 runtime-application deadline。
7. 如果 exact old runtime 仍 ready，发送一次 identity-scoped reapply；任何无法解释的状态进入 recovery-required。
8. Provider 阻止新 flow admission，校验 base identity，并同步 reapply 当前 engine。
9. 只有 reapply 成功后才发布 target identity。
10. Host 等待 exact target `.ready`，reload manager ownership，最后才发布新 Active Profile。

只保留最新且不同的 pending target。Preference save 完成或 DnsLibs 返回成功都不能单独证明切换成功。

## 失败语义

- `applied`：Provider 已发布 target runtime identity，Host 仍需 final verify。
- `rejectedPreservingBase`：mutation 在修改前被拒绝，或 exact old-configuration rollback 成功；响应携带验证后的 old bytes 与 identity。
- `unrecoverable`：target 和 rollback 均失败；Provider 同步停止 runtime 并发布 failure。
- `rejected`：malformed、stale identity、不支持 protocol、rate limit、冲突或 runtime unavailable 等 pre-mutation refusal。

DnsLibs reapply 失败被视为可能已经修改 engine。Flow admission 仍被阻止时，使用最后确认的 exact configuration rollback。未知状态绝不能显示为 old Active、target Active、degraded service 或 System DNS 已恢复。

## Timeout 与 Reconciliation

| 操作 | 限制 |
| --- | --- |
| Upstream preflight | 5 秒 |
| Manager reload 后 runtime application | 5 秒 |
| Failure reconcile 与 repair | 8 秒 |
| Runtime polling | 200 毫秒 |
| Network-context debounce | 1 秒 |
| DnsLibs upstream exchange | 5 秒 |
| Keyboard Quit confirmation | 2 秒 |
| Confirmed safe Quit decision | 5 秒 |

`AGDnsProxy.reapplySettings` 是同步且不可取消的。Host cancellation 只终止 Host 等待。发生 timeout、reply 丢失或 XPC interruption 后，Host 读取 authenticated actual status，并且只能使用同一 operation ID 重放相同 request bytes。

## Restore System DNS 与 Quit

Lifecycle shutdown 阻止新切换意图，等待无法取消的 mutation，捕获 exact ownership，quiesce runtime，compare-and-save manager disabled，再 reload disabled state。只有 exact quiescence 和 manager proof 同时存在时才能报告 disabled。

如果 disable 明确失败且 exact manager 仍 enabled，可以尝试 exact runtime resume。如果 manager save outcome 未知，在 operation settle 并 reload preference 前禁止 resume 和其他 manager mutation。

确认 exact Active 后，safe Quit 在 quiescence 前耐久写入一次性 resume record，并在 final manager reload 后将 exact disable 标记为 confirmed。两个 phase 之间发生 crash 时，下次启动根据 record 与当前 exact manager state reconcile。任何 startup enable 前必须先耐久 claim record，每次启动最多自动尝试一次。

启动先处理 configuration mutation recovery，再处理 safe Quit resume evidence。Exact enabled manager 只做 reconcile/adopt，不 stop/start。只有 owner identity、保留配置的 generation/fingerprint、App configuration identity 和 Extension readiness 都与 record 一致，exact disabled manager 才可以被 enable。Manual 使用持久化 Profile；Automatic 等待当前活动桌面 session 的 fresh network context 后重新计算 Rules。Missing、corrupt、claimed、foreign、changed 或 uncertain evidence 均不能授权自动 manager write。

正常 Quit 保留已安装的 System Extension。发生 Force Quit、crash 或断电后，系统管理的 DNS Proxy 可能保持 enabled，直到下次启动 reconcile persisted state 与 actual runtime，或用户恢复 System DNS。Manager stop/start 用于首次 enable、safe Quit resume、显式 restore、Quit、Extension replacement 和有界 lifecycle repair；普通 Profile 切换使用 manager enabled 的 single-engine reapply 路径。
