# 发布 DNSPilot

[English](../en/releasing.md)

## 源码发布

1. 确认公开 tree 不包含私有 Team、Bundle、certificate、account path、credential 或 diagnostic literal。
2. 对当前 tree 和 reachable history 运行 repository check、Gitleaks、非 UI 测试、analysis 和 universal Community build。
3. 验证 source tag、依赖 revision、checksum、changelog、license、notice、privacy 声明和已知限制。
4. 从 canonical public repository 创建 signed source tag，并发布 source archive 与 checksum。

源码发布不表示应用二进制已经可以重新分发。

## 二进制发布门禁

发布 App、archive、installer 或 store build 前：

1. 完成 [AGDnsProxy transitive inventory](compliance/agdnproxy-v2.8.45.md)，并打包所有必需 license/NOTICE。
2. 从干净的公开源码 checkout 构建，使用受保护 signing input。
3. 验证 Host、System Extension、nested framework、entitlement、provisioning、designated requirement、version 和双 architecture。
4. Strip 并检查 distributed archive、dSYM、Info.plist、entitlement 和 binary，确保没有私有开发路径或身份。
5. 完成签名 clean-machine 的 install、approval、XPC、DNS、switch、sleep/wake、recovery、update 和正常 Quit 验证。
6. 验证 privacy manifest 和 encryption/export declaration。
7. 确认 artifact 精确映射公开 source commit，并发布 checksum、notice、limitation 和 rollback guidance。

Pull-request CI 与 fork build 永不接收官方 signing 或 store credential。官方 release credential 只在受保护人工环境使用。

## 失败与回滚

不得在发布说明中用 waiver 隐藏未解决门禁。如果无法证明 artifact identity、signing、dependency provenance、notice completeness、runtime restoration 或 source traceability，就不得分发二进制。

已发布版本出现缺陷时，应尽可能撤回 artifact，保留 source tag 与 checksum 供追溯，说明受影响版本，并引导用户使用已验证旧版本或执行 System DNS restoration。
