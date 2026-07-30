# 用户界面设计

[English](../../en/design/user-interface.md)

## 产品形态

DNSPilot 是安静、原生的 macOS utility，包含一个管理窗口、一个标准 Settings 窗口和常驻菜单栏菜单。关闭窗口后 App 继续运行，并保持当前 DNS Proxy 状态。

管理窗口使用两列 NavigationSplitView，包含 Overview、Profiles、Rules。Settings 包含 General、Privacy、Diagnostics、About。使用原生 list、form、sheet、alert、menu、segmented control、toggle、系统字体、语义色和 SF Symbols。颜色不能单独表达状态。

## 状态语言

UI 展示可观察的运行状态：`DNS Proxy On`、`DNS Proxy Off`、`Preparing`、`Applying`、`Restoring System DNS`、`Recovery Required` 和 `Error`。

System Extension installation 与 DNS Proxy enablement 是独立状态。稳定状态显示一个 Active Profile；切换或失败可以同时显示 Target 与已确认 Active。Ownership 或 runtime identity 未知时必须显示 recovery-required。

## Overview

Overview 展示 DNS Proxy 状态与控制、Automatic/Manual、Target/Active Profile、selection source、当前网络、Profile test、诊断入口和恢复操作。

选择 Manual 会持久化请求的 Profile，并保持当前 Proxy On/Off 状态。切换失败保留 Target 与已确认 Active，并提供 Retry 和 `Use Active Profile (Manual)`。返回 Automatic 后立即计算最新有效 network context。

## Profiles 与 Rules

Profile/Rule editor 使用 staged draft，只有 Save 才提交 domain configuration。Validation 聚焦第一个无效字段。编辑 Active Profile 使用 journaled runtime/configuration transaction，并在 exact verification 后把 draft 发布为 Active。

Profiles 提供 create、edit、duplicate、test、make-default、replacement 和 delete。自定义 Profile editor 支持 Plain DNS、DNS over TLS 和 DNS over HTTPS。DoT 输入包含 server name 或 address、port 和 bootstrap address。列表身份使用隐私安全的 DoT 与 DoH server 摘要。

Rules 显示 enabled、priority、condition summary 和 target Profile。Reorder 只保存一次并 reevaluate 一次。Drag 必须提供 Move Up/Move Down 键盘替代。Default Profile selector 保持可见，Proxy 可用时不能为空。

## Onboarding

Setup 是独立流程：

1. 解释 DNS 接管与恢复行为。
2. 由用户明确选择模板或自定义输入创建 Profile，并要求预检成功。
3. 解释 SSID Rule 所需的可选 Location 权限。
4. 用户明确执行后安装 System Extension。
5. 再由用户明确执行后启用 DNS Proxy。
6. 只有确认 exact Active runtime 后显示完成。

拒绝权限只影响 SSID Rule。等待批准时提供 System Settings 和重新检查。引导中断后保留已提交配置，只有确认 exact Active runtime 后才显示完成。

## 菜单栏与命令

菜单栏显示 Proxy state、Active/Target Profile、mode 和 network summary，提供 Automatic、Manual Profile、Open DNSPilot、Settings、Turn On/Restore System DNS 和 Quit。所有入口调用共享 app intent，不分别实现业务逻辑。

标准快捷键包括 `Command-1/2/3` 切换主页面、`Command-,` 打开 Settings、`Command-N` 新建 Profile、`Shift-Command-N` 新建 Rule、`Command-W` 关闭窗口。

## Quit

键盘 Quit 要求 2 秒内两次独立 `Command-Q`。忽略 auto-repeat，两次 key-down 之间必须有 key-up。第一次只显示 non-activating visual prompt 和 VoiceOver announcement。Timeout、Escape 或失去 keyboard context 后取消 armed。

明确点击菜单项会立即开始 safe Quit。未保存 draft 需要独立 discard confirmation。确认 Quit 后阻止新 mutation，在有界时间内恢复 System DNS，只有得到 proof 后退出。失败时提供 Retry、Cancel Quit、Quit Anyway，并警告 DNS Proxy 可能仍 enabled。

## 隐私与诊断

Location 在需要 Wi-Fi SSID 时按上下文请求。Debug Logging 持续显示敏感数据警告。Diagnostic export 需要确认。About 展示 version、build、license、source、privacy、support、third-party notices 和 build origin。

## 无障碍与布局

核心流程必须支持 keyboard-only 与 VoiceOver。纯图标控件需要 label 和 tooltip。列表提供完整 accessibility value。主要命令不能截断。长名称、IPv6、URL 和 error code 可以换行或中间截断，但复制保留完整值。

Reduced Motion、Increased Contrast、Reduced Transparency、长本地化文本和最小 `760 x 520 pt` 管理窗口都必须保持层级、焦点和可操作性，不得重叠。
