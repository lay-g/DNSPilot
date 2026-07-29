# DNSPilot 文档

[English](../en/README.md)

这些文档描述长期有效的产品与工程合同，不记录实施阶段、测试轮次或历史验证结果。

## 设计

- [产品设计](design/product.md)：范围、支持能力、非目标和分发原则。
- [系统架构](design/architecture.md)：进程边界、所有权和事实源。
- [数据模型](design/data-model.md)：Profile、Rule、网络上下文、存储和 mutation recovery。
- [运行时设计](design/runtime.md)：DNS 引擎生命周期、切换、恢复和失败语义。
- [安全与 IPC](design/security.md)：签名身份、Mach XPC、payload、重放和隐私边界。
- [用户界面](design/user-interface.md)：窗口、菜单栏、引导、状态语言、Quit 和无障碍。
- [工具链](design/toolchain.md)：规范 Xcode、Swift、deployment 和并发基线。
- [测试策略](design/testing.md)：自动化、集成、签名运行时和人工验证边界。

## 开发与发布

- [构建](building.md)
- [发布](releasing.md)
- [AGDnsProxy 2.8.45 合规清单](compliance/agdnproxy-v2.8.45.md)

文档冲突时，主题更具体的设计合同优先。`Configurations/Base.xcconfig` 的构建设置必须与工具链文档保持一致。
