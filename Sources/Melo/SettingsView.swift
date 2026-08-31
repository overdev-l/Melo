import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(title: "设置", subtitle: "菜单栏、日常工具、隐私提醒与安全边界。")

                if let error = model.errorMessage {
                    ErrorBanner(message: error, dismiss: model.dismissError)
                }

                SectionSurface("菜单栏") {
                    Picker("显示样式", selection: $model.menuBarDisplayStyle) {
                        ForEach(MenuBarDisplayStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    Divider()
                    Picker("图标角色", selection: $model.menuBarCompanion) {
                        ForEach(MenuBarCompanion.allCases) { companion in
                            Label(companion.title, systemImage: companion.systemImage).tag(companion)
                        }
                    }
                    Divider()
                    Toggle("在菜单栏常驻显示 CPU", isOn: $model.menuBarShowsCPU)
                    Toggle("在菜单栏常驻显示内存", isOn: $model.menuBarShowsMemory)
                    Text("CPU 与内存可独立选择；关闭两项时，指标区域显示 Melo。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("交换菜单栏左键与右键操作", isOn: $model.swapMenuBarClicks)
                    Toggle("仅在菜单栏运行（隐藏 Dock 图标）", isOn: $model.menuBarOnlyMode)
                    Toggle(
                        "登录时启动 Melo",
                        isOn: Binding(
                            get: { model.launchAtLoginEnabled },
                            set: model.setLaunchAtLogin
                        )
                    )
                }

                SectionSurface("隐私与日常工具") {
                    Toggle(
                        "摄像头或麦克风开始使用时提醒",
                        isOn: Binding(
                            get: { model.privacyAlertsEnabled },
                            set: model.setPrivacyAlertsEnabled
                        )
                    )
                    Text("活动检测使用 macOS 音频和摄像设备状态，不读取、录制或上传音视频。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if model.privacyAlertsEnabled, !model.privacyNotificationsAuthorized {
                        Button("允许系统通知") {
                            Task { await model.requestPrivacyNotificationAuthorization() }
                        }
                        .buttonStyle(.bordered)
                    }
                    Divider()
                    HStack {
                        Picker("保持唤醒", selection: $model.keepAwakeMode) {
                            ForEach(KeepAwakeMode.allCases) { mode in
                                Text(mode.shortTitle).tag(mode)
                            }
                        }
                        Picker("持续时间", selection: $model.keepAwakeDuration) {
                            ForEach(KeepAwakeDuration.allCases) { duration in
                                Text(duration.title).tag(duration)
                            }
                        }
                        Spacer()
                        if model.keepAwakeSession == nil {
                            Button("开始保持唤醒") { model.startKeepAwake() }
                                .buttonStyle(.bordered)
                        } else {
                            Button("停止保持唤醒") { model.stopKeepAwake() }
                                .buttonStyle(.bordered)
                        }
                    }
                    Divider()
                    HStack {
                        Toggle("清洁屏幕时锁定鼠标与键盘输入", isOn: $model.cleanScreenLocksInput)
                        Spacer()
                        Button("进入清洁模式") { model.startCleanScreen() }
                            .buttonStyle(.bordered)
                    }
                    Text("清洁模式覆盖所有显示器，按 Escape 随时退出。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SectionSurface("Mole CLI") {
                    settingRow(
                        label: "连接状态",
                        value: model.isMoleInstalled ? "已连接" : "未安装",
                        valueColor: model.isMoleInstalled ? MeloTheme.safeGreen : MeloTheme.warningAmber
                    )
                    Divider()
                    settingRow(label: "版本", value: model.moleVersion ?? "未知")
                    Divider()
                    settingRow(label: "路径", value: model.moleExecutableURL?.path ?? "未找到")
                    HStack {
                        Button("查看 Mole 项目") {
                            model.openURL("https://github.com/tw93/mole")
                        }
                        .buttonStyle(.bordered)
                        Button("安装说明") {
                            model.openURL("https://github.com/tw93/mole#quick-start")
                        }
                        .buttonStyle(.bordered)
                    }
                }

                SectionSurface("安全") {
                    Label("清理前始终要求确认", systemImage: "checkmark.shield")
                        .font(.callout.weight(.medium))
                    Text("这一项不可关闭。Melo 只在你确认后调用 mo clean，并保留 Mole 的操作日志。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Divider()
                    Label("系统级缓存按现有授权处理", systemImage: "lock")
                        .font(.callout.weight(.medium))
                    Text("Melo 不读取管理员密码。没有现成 sudo 会话时，Mole 自动跳过系统级项目。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SectionSurface("关于 Melo") {
                    Text("Melo 是独立的原生 macOS 系统工具，不隶属于 Mole 或其作者。实时监控与日常工具由 Melo 直接实现；当前清理、卸载、维护和分析功能调用本机安装的 Mole CLI。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Link("Mole 使用 GPL-3.0 开源", destination: URL(string: "https://github.com/tw93/mole/blob/main/LICENSE")!)
                        .font(.callout)
                }
            }
            .padding(28)
            .frame(maxWidth: 1040, alignment: .leading)
        }
    }

    private func settingRow(label: String, value: String, valueColor: Color = .secondary) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.callout)
            Spacer()
            Text(value)
                .font(.system(.callout, design: label == "路径" ? .monospaced : .default))
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
