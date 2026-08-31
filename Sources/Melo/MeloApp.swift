import SwiftUI

@main
@MainActor
struct MeloApp: App {
    @StateObject private var model: AppModel
    private let menuBarController: MenuBarController

    init() {
        let model = AppModel()
        _model = StateObject(wrappedValue: model)
        menuBarController = MenuBarController(model: model)
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .frame(minWidth: 980, minHeight: 680)
                .tint(MeloTheme.brandRose)
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(after: .appInfo) {
                Button("刷新系统状态") {
                    Task { await model.refreshStatus() }
                }
                .keyboardShortcut("r", modifiers: .command)
                Button("显示菜单栏面板") {
                    menuBarController.showPopover()
                }
                .keyboardShortcut("m", modifiers: [.command, .option])
            }
        }

        Settings {
            SettingsView(model: model)
                .frame(width: 620, height: 620)
        }

    }
}

struct MenuBarStatusView: View {
    @ObservedObject var model: AppModel
    @State private var showEjectConfirmation = false

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Melo").font(.headline)
                    Text(model.isLiveMonitoring ? "本机实时监控" : "正在启动监控")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let session = model.keepAwakeSession {
                    StatusBadge(
                        title: session.mode.shortTitle,
                        systemImage: "cup.and.saucer.fill",
                        color: MeloTheme.safeGreen
                    )
                }
            }

            privacySection

            if let live = model.liveSnapshot {
                MetricRow(
                    label: "处理器",
                    value: live.cpuUsage,
                    valueText: live.cpuUsage.formatted(.number.precision(.fractionLength(0))) + "%"
                )
                MetricRow(
                    label: "内存",
                    value: live.memoryUsedPercent,
                    valueText: live.memoryUsedPercent.formatted(.number.precision(.fractionLength(0))) + "%",
                    tint: .blue
                )
                HStack {
                    Label("网络", systemImage: "arrow.up.arrow.down")
                        .font(.callout)
                    Spacer()
                    Text("↓ \(ByteFormatting.speed(live.networkReceiveBytesPerSecond))  ↑ \(ByteFormatting.speed(live.networkSendBytesPerSecond))")
                        .font(.system(.caption, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                if !live.processes.isEmpty {
                    Divider()
                    Text("CPU 占用较高").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(live.processes.prefix(3)) { process in
                        HStack {
                            Text(process.name).lineLimit(1)
                            Spacer()
                            Text(process.cpu.formatted(.number.precision(.fractionLength(1))) + "%")
                                .monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
            } else {
                Text("正在启动本机实时监控。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            hardwareTiles

            Divider()

            everydayTools

            Divider()

            quickDestinations

            if !model.ejectableVolumes.isEmpty {
                Button {
                    showEjectConfirmation = true
                } label: {
                    Label("推出所有可移动磁盘（\(model.ejectableVolumes.count)）", systemImage: "eject")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }

            Divider()

            HStack {
                Button("打开 Melo") {
                    model.openMainWindow()
                }
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        }
        .frame(width: 350)
        .frame(maxHeight: 620)
        .confirmationDialog(
            "推出所有可移动磁盘？",
            isPresented: $showEjectConfirmation,
            titleVisibility: .visible
        ) {
            Button("推出 \(model.ejectableVolumes.count) 个磁盘") {
                Task { await model.ejectAllVolumes() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("请先确认文件写入已经完成。无法安全推出的磁盘会保持挂载。")
        }
    }

    @ViewBuilder
    private var hardwareTiles: some View {
        let fans = model.hardwareSnapshot?.fans ?? []
        let battery = model.status?.batteries.first
        let thermal = model.status?.thermal
        if !fans.isEmpty || battery != nil || thermal != nil {
            Divider()
            Text("硬件")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                if let fan = fans.first {
                    menuHardwareTile(
                        title: "风扇",
                        value: "\(Int(fan.actualRPM ?? 0)) RPM",
                        icon: "fan",
                        tint: fan.isManual ? MeloTheme.warningAmber : .blue
                    )
                }
                if let battery {
                    menuHardwareTile(
                        title: battery.name ?? "电池",
                        value: battery.percent.map { "\(Int($0.rounded()))%" } ?? "—",
                        icon: "battery.75percent",
                        tint: MeloTheme.safeGreen
                    )
                } else if let percent = model.hardwareSnapshot?.batteryCare.currentPercent {
                    menuHardwareTile(
                        title: "电池",
                        value: "\(percent)%",
                        icon: "battery.75percent",
                        tint: MeloTheme.safeGreen
                    )
                }
                if let temperature = [thermal?.cpuTemp, thermal?.gpuTemp]
                    .compactMap({ $0 }).filter({ $0 > 0 }).max() {
                    menuHardwareTile(
                        title: "温度",
                        value: "\(Int(temperature.rounded()))°C",
                        icon: "thermometer.medium",
                        tint: temperature >= 85 ? MeloTheme.warningAmber : .orange
                    )
                }
                if let disk = model.status?.disks.first(where: { $0.external != true }) {
                    menuHardwareTile(
                        title: "磁盘",
                        value: "\(Int(disk.usedPercent.rounded()))%",
                        icon: "internaldrive",
                        tint: disk.usedPercent >= 90 ? MeloTheme.warningAmber : .purple
                    )
                }
            }
        }
    }

    private func menuHardwareTile(title: String, value: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).foregroundStyle(tint).frame(width: 17)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Text(value).font(.system(.caption, design: .rounded, weight: .semibold)).monospacedDigit()
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var privacySection: some View {
        HStack(spacing: 10) {
            Image(systemName: model.privacyActivity.isActive ? "record.circle.fill" : "hand.raised.fill")
                .foregroundStyle(model.privacyActivity.isActive ? Color.orange : MeloTheme.safeGreen)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.privacyActivity.isActive ? "隐私活动" : "隐私状态正常")
                    .font(.caption.weight(.semibold))
                Text(model.privacyActivity.summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(9)
        .background(
            (model.privacyActivity.isActive ? Color.orange : MeloTheme.safeGreen).opacity(0.09),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .accessibilityElement(children: .combine)
    }

    private var everydayTools: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("日常工具")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if let session = model.keepAwakeSession {
                HStack {
                    Label(session.remainingText, systemImage: session.mode.systemImage)
                        .font(.caption)
                    Spacer()
                    Button("停止") { model.stopKeepAwake() }
                        .controlSize(.small)
                }
            } else {
                HStack(spacing: 8) {
                    Picker("唤醒范围", selection: $model.keepAwakeMode) {
                        ForEach(KeepAwakeMode.allCases) { mode in
                            Text(mode.shortTitle).tag(mode)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 88)

                    Picker("持续时间", selection: $model.keepAwakeDuration) {
                        ForEach(KeepAwakeDuration.allCases) { duration in
                            Text(duration.title).tag(duration)
                        }
                    }
                    .labelsHidden()

                    Button("开始") { model.startKeepAwake() }
                        .buttonStyle(.borderedProminent)
                        .tint(MeloTheme.brandRose)
                }
                .controlSize(.small)
            }

            Button {
                model.startCleanScreen()
            } label: {
                HStack {
                    Label("清洁屏幕", systemImage: "sparkles.rectangle.stack")
                    Spacer()
                    Text(model.cleanScreenLocksInput ? "锁定输入" : "点击退出")
                        .foregroundStyle(.secondary)
                }
                .font(.caption)
            }
            .buttonStyle(.plain)
        }
    }

    private var quickDestinations: some View {
        HStack(spacing: 7) {
            quickButton("清理", icon: "sparkles", destination: .cleanup)
            quickButton("软件", icon: "square.stack.3d.up", destination: .software)
            quickButton("分析", icon: "folder.badge.gearshape", destination: .storage)
            quickButton("状态", icon: "waveform.path.ecg", destination: .status)
        }
    }

    private func quickButton(_ title: String, icon: String, destination: SidebarItem) -> some View {
        Button {
            model.openMainWindow(selection: destination)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                Text(title).font(.caption2)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderless)
        .disabled(destination != .status && !model.isMoleInstalled)
        .accessibilityLabel("打开\(title)")
    }
}
