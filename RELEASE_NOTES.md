# Melo 0.2.0 Preview

这是 Melo 的首个公开预览版本，提供原生 macOS 图形界面，覆盖 Clean、Software、Optimize、Analyze、Status、Doctor、菜单栏 HUD 与日常工具的主要流程。

## 预览范围

- 每秒 CPU、内存、网络与进程监控，以及最近 60 秒趋势
- CPU/内存可独立常驻的菜单栏 HUD
- 基于 Mole CLI 的清理、卸载、维护与空间分析预览确认流程
- 可恢复删除、受保护路径拒绝、软件更新验证与启动项管理
- AppleSMC 风扇 RPM 只读检测，以及受限 Helper 的源码与安全恢复策略

## 分发限制

附件名称包含 `unsigned-preview`，表示它们未使用 Developer ID Application 签名，也未通过 Apple 公证。预览包不会开放硬件 Helper 注册或 AppleSMC 写入。当前推荐方式是克隆源码后在本机使用 Xcode/Swift 构建。

项目不会建议关闭 Gatekeeper 或绕过 macOS 安全警告。正式分发包将在完成 Developer ID 签名、公证和授权真机写入验收后提供。
