# Melo

[![CI](https://github.com/overdev-l/Melo/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/overdev-l/Melo/actions/workflows/ci.yml)

Melo 是一个面向个人使用的原生 macOS 系统工具，目标是逐步对齐 Mole 官方桌面端的公开功能与使用体验。实时监控由 Melo 直接使用 macOS 系统接口完成；清理、软件卸载、维护和空间分析当前复用已安装的 [Mole CLI](https://github.com/tw93/mole)。

当前版本包含：

- `mo clean --dry-run` 的可检查清理预览，以及强制废纸篓模式、可取消的确认清理
- `mo uninstall --list` 驱动的应用清单，以及按应用名执行的残留预览与可恢复卸载
- `mo optimize --dry-run` 驱动的系统维护计划、保护项与可取消的确认执行
- `mo analyze --json` 驱动的可下钻文件夹空间地图，以及受保护路径拒绝、二次确认的废纸篓操作
- 原生 1 秒级 CPU、内存、网络和进程监控，保留最近 60 秒趋势
- 状态页支持进程排序、置顶、路径复制、解释与 TERM → KILL 二次确认流程
- `mo status --json` 补充硬件健康、GPU、磁盘、电源和可用传感器信息
- 复用同一采样源的菜单栏 CPU 指标与资源概览
- 原生菜单栏 HUD：CPU 与内存可独立常驻并记住选择，支持可选图标角色、隐私活动、右键快速菜单和菜单栏模式
- Keep Screen On 三种范围与定时/永久会话，退出或重启后按剩余时间恢复
- 多显示器 Clean Screen、可选输入锁、Escape 退出，以及可移动磁盘安全推出确认
- 麦克风进程与摄像设备活动检测，可选本地系统通知，不读取音视频内容
- Software 分为更新、启动项和卸载：原生枚举应用，检查 Homebrew、Sparkle、Electron 与 App Store，传统启动项分级管理
- 经过 HTTPS、SHA-512、Bundle ID 与签名团队验证的 Electron ZIP 可安全原位更新，失败自动回滚；检查与安装均可取消
- 多选应用后逐项 dry-run 汇总，再一次确认并按顺序移到废纸篓
- `mo history --json` 驱动的本地操作记录
- 原生 AppleSMC 风扇能力/RPM 只读探测；正式签名包可通过受限 XPC Helper 使用硬件夹值的风扇预设、Battery Care 与临时充到 100% 后自动恢复区间
- 风扇 Helper 断联 5 秒、客户端退出或写入验证失败时自动恢复 macOS 控制；无电池/无风扇设备自动隐藏不适用功能
- Doctor 只读体检：环境、系统、权限、配置、安全与运行时报告，问题分级、系统设置入口和脱敏复制
- 菜单栏面板提供 CPU、内存、网络、风扇、温度、电池、磁盘与高 CPU 进程；Status 展示配对设备和蓝牙附件电量；⌥⌘M 可从键盘打开 HUD

Melo 不包含或修改 Mole 源码，也不隶属于 Mole 或其作者。所有扫描都在本机完成。

## 下载与分发状态

公开仓库的 CI 会生成 `unsigned-preview` ZIP 与 DMG，用于检查界面和只读功能。它们没有 Apple 公证，不能视为正式分发版本；无 Team ID 的预览构建会主动禁用硬件 Helper 注册和 AppleSMC 写入。建议当前用户从源码构建。

正式下载包需要 Developer ID Application 签名、Apple 公证和真机硬件写入验收。项目不会建议用户关闭 Gatekeeper 或绕过 macOS 安全警告。

## 环境要求

- macOS 14 或更高版本
- Mole CLI（使用清理、卸载、维护、分析功能时需要）：`brew install mole`
- 源码构建需要 Xcode 15.3 或更高版本

## 开发运行

```bash
swift run Melo
```

## 构建应用

```bash
./scripts/build-app.sh
open dist/Melo.app
```

构建脚本生成一个包含 `MeloHardwareHelper` 的本地临时签名 `dist/Melo.app`。临时签名只开放硬件只读监测；风扇与 Battery Care 写入必须使用位于 `/Applications`、带可信 Developer ID 的正式构建。对外分发前仍需配置 Hardened Runtime 和 Apple 公证。

已有 Developer ID Application 证书时，可用 `MELO_SIGN_IDENTITY="Developer ID Application: …" ./scripts/build-app.sh` 生成带 Hardened Runtime 与时间戳的签名构建；公证仍作为独立发布步骤执行。

使用 `./scripts/verify-app.sh` 可重复核对主应用与 Helper 的 Bundle ID、Team ID、Hardened Runtime、嵌套签名和 LaunchDaemon 配置。Apple Development 身份可用于本机受控测试，但不等同于可公证分发的 Developer ID Application。

生成 ZIP、DMG 与 SHA-256 校验和：

```bash
./scripts/package-release.sh
```

打包脚本会根据签名身份把产物标记为 `unsigned-preview`、`development-preview` 或 `notarization-pending`，避免把开发构建误认为正式版本。

涉及 AppleSMC 写入的真机测试必须按 [HARDWARE_VALIDATION.md](HARDWARE_VALIDATION.md) 执行，并在安装 Helper、改变风扇或充电策略前取得明确授权。

## 安全边界

- 清理、卸载和系统维护的检查阶段始终使用 Mole 的 dry-run。
- 真正清理、卸载应用或执行维护前，Melo 始终再次显示确认操作。
- 清理与应用卸载显式设置 Mole 的 `MOLE_DELETE_MODE=trash`；废纸篓不可用时拒绝回退到永久删除。
- Clean 和 Optimize 的保护项以原子写入、`0600` 权限保存在 Mole 原生 whitelist 配置中，移除保护前再次确认。
- Analyze 只允许移动当前扫描范围内的普通项目，并拒绝系统目录、账户敏感目录、应用包和卷根。
- Melo 不读取管理员密码；没有现成 sudo 会话时，Mole 会跳过需要管理员权限的系统级项目。
- 清理历史继续由 Mole 写入 `~/Library/Logs/mole/`。
- 实时系统监控与风扇 RPM 读取不依赖 Mole，采样结果仅保存在内存中，不上传到网络。
- 特权 Helper 不接受 shell 字符串或任意路径命令，只接受结构化风扇/Battery Care 请求，并验证客户端签名身份。

## 对齐进度

Status、菜单栏与日常工具、Software、Clean、Optimize、Analyze、Doctor 和权限诊断的主要公开流程已经接入。风扇控制、自动恢复、Battery Care 与最小权限 Helper 已完成代码、单元测试、临时签名构建和只读真机验收；Developer ID 正式包仍需在受支持硬件上完成受控写入验收，全量 VoiceOver 与真实窗口回归正在持续进行。

## 许可证

Melo 以 [MIT License](LICENSE) 开源。适配自 `smctl` 的 AppleSMC 子集及其来源见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。Mole CLI 是独立安装的 GPL-3.0 项目，不随 Melo 仓库或安装包分发。
