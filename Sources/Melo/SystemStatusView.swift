import Charts
import SwiftUI

struct SystemStatusView: View {
    @ObservedObject var model: AppModel
    @State private var processSort = ProcessSort.cpu
    @State private var sortAscending = false
    @State private var selectedProcess: LiveProcess?
    @State private var processToTerminate: LiveProcess?
    @State private var fanPresetCandidate: Double?
    @State private var batteryLimitCandidate: Int?
    @State private var showChargeToFullConfirmation = false
    @State private var showHelperConfirmation = false
    @State private var showRemoveHelperConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "系统状态",
                    subtitle: statusSubtitle,
                    actionTitle: model.isMoleInstalled ? "刷新硬件" : nil,
                    actionIcon: "arrow.clockwise",
                    isWorking: model.isRefreshingStatus,
                    action: { Task { await model.refreshStatus() } }
                )

                if let error = model.errorMessage {
                    ErrorBanner(message: error, dismiss: model.dismissError)
                }
                if let message = model.hardwareControlMessage {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.shield.fill").foregroundStyle(MeloTheme.safeGreen)
                        Text(message).font(.callout)
                        Spacer()
                        Button("关闭", action: model.dismissHardwareControlMessage).buttonStyle(.plain)
                    }
                    .padding(12)
                    .background(MeloTheme.safeGreen.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                }

                HStack {
                    StatusBadge(
                        title: model.isLiveMonitoring ? "每秒实时刷新" : "正在启动监控",
                        systemImage: "dot.radiowaves.left.and.right",
                        color: model.isLiveMonitoring ? MeloTheme.safeGreen : .secondary
                    )
                    if let date = model.liveSnapshot?.date {
                        Text("更新于 \(date.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.status == nil, model.isMoleInstalled {
                        Text("刷新硬件可补充磁盘、GPU 与传感器详情")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if let live = model.liveSnapshot {
                    dashboard(live: live, detail: model.status)
                    accessoryBatteries(model.status)
                    hardwareControls
                    processList(live.processes)
                } else {
                    WorkingStateView(title: "正在启动实时监控", message: "首次采样后会每秒更新，并保留最近 60 秒趋势。")
                }
            }
            .padding(28)
            .frame(maxWidth: 1120, alignment: .leading)
        }
        .onAppear(perform: model.startLiveMonitoring)
        .sheet(item: $selectedProcess) { process in
            ProcessExplanationView(
                process: process,
                isPinned: model.pinnedProcessIDs.contains(process.pid),
                pinAction: { model.toggleProcessPin(process) },
                copyAction: { model.copyExecutablePath(process) },
                terminateAction: process.canTerminate ? {
                    selectedProcess = nil
                    processToTerminate = process
                } : nil
            )
            .frame(minWidth: 520, minHeight: 330)
        }
        .confirmationDialog(
            processToTerminate.map { "终止 \($0.name)？" } ?? "终止进程？",
            isPresented: Binding(
                get: { processToTerminate != nil },
                set: { if !$0 { processToTerminate = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let process = processToTerminate {
                Button("终止进程", role: .destructive) {
                    processToTerminate = nil
                    Task { await model.terminateProcess(process) }
                }
            }
            Button("取消", role: .cancel) { processToTerminate = nil }
        } message: {
            Text("Melo 会先发送 TERM；若两秒内没有退出，再发送 KILL。未保存的数据可能丢失。")
        }
        .confirmationDialog(
            "启用手动风扇控制？",
            isPresented: Binding(get: { fanPresetCandidate != nil }, set: { if !$0 { fanPresetCandidate = nil } }),
            titleVisibility: .visible
        ) {
            if let fanPresetCandidate {
                Button("应用并保持安全看门狗") {
                    Task { await model.applyFanPreset(fraction: fanPresetCandidate) }
                    self.fanPresetCandidate = nil
                }
            }
            Button("取消", role: .cancel) { fanPresetCandidate = nil }
        } message: {
            Text("目标会被限制在硬件公布的最小与最大 RPM 内。Melo 断联超过 5 秒、Helper 退出或写入验证失败时，风扇会自动交还 macOS。")
        }
        .confirmationDialog(
            batteryLimitCandidate.map { "把 Battery Care 上限设为 \($0)%？" } ?? "设置 Battery Care？",
            isPresented: Binding(get: { batteryLimitCandidate != nil }, set: { if !$0 { batteryLimitCandidate = nil } }),
            titleVisibility: .visible
        ) {
            if let batteryLimitCandidate {
                Button("启用 \(batteryLimitCandidate - 5)%–\(batteryLimitCandidate)%") {
                    Task { await model.setBatteryCare(upperLimit: batteryLimitCandidate) }
                    self.batteryLimitCandidate = nil
                }
            }
            Button("取消", role: .cancel) { batteryLimitCandidate = nil }
        } message: {
            Text("Helper 会在达到上限时暂停充电、降至下限时恢复；不会主动放电。停止 Battery Care 会立即把充电交还系统。")
        }
        .confirmationDialog("临时充到 100%？", isPresented: $showChargeToFullConfirmation, titleVisibility: .visible) {
            Button("开始充到 100%") { Task { await model.chargeBatteryToFull() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("达到 100% 后，Helper 会自动恢复原来的 Battery Care 上下限。停止 Battery Care 会取消临时满充。")
        }
        .confirmationDialog("安装最小权限硬件 Helper？", isPresented: $showHelperConfirmation, titleVisibility: .visible) {
            Button("请求系统安装") { model.installHardwareHelper() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("Helper 只接受受限的风扇、Battery Care 和状态请求，不执行任意命令。macOS 会要求管理员批准。")
        }
        .confirmationDialog("移除硬件 Helper？", isPresented: $showRemoveHelperConfirmation, titleVisibility: .visible) {
            Button("恢复系统自动并移除", role: .destructive) {
                Task { await model.removeHardwareHelper() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("Melo 会先把所有风扇交还 macOS，再断开 XPC 并注销 Helper。Battery Care 也会停止由当前 Helper 执行。")
        }
    }

    @ViewBuilder
    private func accessoryBatteries(_ detail: MoleStatus?) -> some View {
        let paired = Array((detail?.batteries ?? []).dropFirst())
        let bluetooth = detail?.bluetooth ?? []
        if !paired.isEmpty || !bluetooth.isEmpty {
            SectionSurface("配对设备与蓝牙附件") {
                VStack(spacing: 0) {
                    ForEach(paired) { battery in
                        HStack(spacing: 11) {
                            Image(systemName: "iphone").foregroundStyle(.blue).frame(width: 22)
                            Text(battery.name ?? "配对设备").font(.callout.weight(.medium))
                            Spacer()
                            if let status = battery.status {
                                Text(status).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(battery.percent.map { "\(Int($0.rounded()))%" } ?? "—")
                                .font(.system(.callout, design: .rounded, weight: .semibold))
                                .monospacedDigit()
                        }
                        .padding(.vertical, 9)
                        .accessibilityElement(children: .combine)
                    }
                    ForEach(bluetooth) { device in
                        HStack(spacing: 11) {
                            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.indigo).frame(width: 22)
                            Text(device.name).font(.callout.weight(.medium))
                            Spacer()
                            if device.connected == false {
                                Text("未连接").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(device.battery ?? "电量未知")
                                .font(.system(.callout, design: .rounded, weight: .semibold))
                                .monospacedDigit()
                        }
                        .padding(.vertical, 9)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var statusSubtitle: String {
        let uptime = model.status?.uptime.map { "已运行 \($0)" }
        let processCount = model.liveSnapshot.map { "监测 \($0.processes.count) 个活跃进程" }
        let result = [uptime, processCount]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
        return result.isEmpty ? "原生每秒采样，保留最近 60 秒趋势。" : result
    }

    @ViewBuilder
    private func dashboard(live: LiveSystemSnapshot, detail: MoleStatus?) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 245), spacing: 14)], spacing: 14) {
            if let score = detail?.healthScore {
                StatusMetricCard(
                    title: "健康度",
                    value: "\(score)",
                    subtitle: localizedHealth(detail?.healthScoreMessage),
                    systemImage: "heart.text.square",
                    tint: score >= 80 ? MeloTheme.safeGreen : MeloTheme.warningAmber
                )
            }

            StatusMetricCard(
                title: "CPU",
                value: percent(live.cpuUsage),
                subtitle: coreDescription(live: live, detail: detail),
                systemImage: "cpu",
                tint: MeloTheme.brandRose,
                points: model.liveHistory.cpu
            )

            StatusMetricCard(
                title: "内存",
                value: percent(live.memoryUsedPercent),
                subtitle: "\(ByteFormatting.string(live.memoryUsed)) / \(ByteFormatting.string(live.memoryTotal))",
                systemImage: "memorychip",
                tint: .blue,
                points: model.liveHistory.memory
            )

            networkCard(live: live, detail: detail)

            if let gpu = detail?.gpu.first {
                StatusMetricCard(
                    title: "GPU",
                    value: gpuValue(gpu),
                    subtitle: gpu.coreCount.map { "\(gpu.name) · \($0) 核心" } ?? gpu.name,
                    systemImage: "square.3.layers.3d",
                    tint: .purple
                )
            }

            if let thermal = detail?.thermal {
                thermalCard(thermal)
            }

            if let disk = detail?.disks.first(where: { $0.external != true }) ?? detail?.disks.first {
                StatusMetricCard(
                    title: "磁盘",
                    value: percent(disk.usedPercent),
                    subtitle: "已用 \(ByteFormatting.string(disk.used)) / \(ByteFormatting.string(disk.total))",
                    systemImage: disk.external == true ? "externaldrive" : "internaldrive",
                    tint: disk.usedPercent > 85 ? MeloTheme.warningAmber : .indigo
                )
            }

            if let battery = detail?.batteries.first {
                StatusMetricCard(
                    title: battery.name ?? "电池",
                    value: battery.percent.map(percent) ?? "—",
                    subtitle: [battery.status, battery.health.map { "健康 \(percent($0))" }]
                        .compactMap { $0 }
                        .joined(separator: " · "),
                    systemImage: "battery.75percent",
                    tint: MeloTheme.safeGreen
                )
            }
        }

        if let detail, !detail.disks.isEmpty {
            disks(detail.disks)
        }
    }

    private func networkCard(live: LiveSystemSnapshot, detail: MoleStatus?) -> some View {
        let receive = ByteFormatting.speed(live.networkReceiveBytesPerSecond)
        let send = ByteFormatting.speed(live.networkSendBytesPerSecond)
        let interface = detail?.network.first(where: { !($0.ip ?? "").isEmpty })
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("网络", systemImage: "arrow.up.arrow.down")
                    .font(.headline)
                Spacer()
                Text("↓ \(receive)  ↑ \(send)")
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .monospacedDigit()
            }
            NetworkSparkline(
                received: model.liveHistory.networkReceive,
                sent: model.liveHistory.networkSend
            )
            Text(interface.map { "\($0.name) · \($0.ip ?? "")" } ?? "当前活动接口")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(17)
        .frame(maxWidth: .infinity, minHeight: 138, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("网络，下载 \(receive)，上传 \(send)")
    }

    private func thermalCard(_ thermal: ThermalStatus) -> some View {
        let temperatures = [thermal.cpuTemp, thermal.gpuTemp].compactMap { value -> Double? in
            guard let value, value > 0 else { return nil }
            return value
        }
        let temperature = temperatures.max()
        let fanAvailable = (thermal.fanCount ?? 0) > 0
        let value = temperature.map { $0.formatted(.number.precision(.fractionLength(0))) + "°C" }
            ?? (fanAvailable ? "\(thermal.fanSpeed ?? 0) RPM" : "不支持")
        let subtitle: String
        if fanAvailable {
            subtitle = "\(thermal.fanCount ?? 0) 个风扇 · 当前只读监测"
        } else if let power = thermal.systemPower, power > 0 {
            subtitle = "系统功耗 \(power.formatted(.number.precision(.fractionLength(1)))) W"
        } else {
            subtitle = "当前硬件未返回温度或风扇传感器"
        }
        return StatusMetricCard(
            title: fanAvailable ? "温度与风扇" : "温度与能耗",
            value: value,
            subtitle: subtitle,
            systemImage: fanAvailable ? "fan" : "thermometer.medium",
            tint: temperature.map { $0 >= 85 ? MeloTheme.warningAmber : MeloTheme.safeGreen } ?? .secondary
        )
    }

    private func disks(_ disks: [DiskStatus]) -> some View {
        SectionSurface("磁盘") {
            VStack(spacing: 18) {
                ForEach(disks) { disk in
                    VStack(spacing: 7) {
                        HStack {
                            Image(systemName: disk.external == true ? "externaldrive" : "internaldrive")
                                .foregroundStyle(.secondary)
                                .frame(width: 22)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(displayMount(disk.mount)).font(.callout.weight(.medium))
                                Text(disk.external == true ? "外置磁盘" : "内置磁盘")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(ByteFormatting.string(disk.used)) / \(ByteFormatting.string(disk.total))")
                                .font(.system(.callout, design: .rounded))
                                .monospacedDigit()
                            if disk.smartStatus == "verified" {
                                StatusBadge(title: "SMART 正常", systemImage: "checkmark", color: MeloTheme.safeGreen)
                            }
                        }
                        ProgressView(value: min(disk.usedPercent, 100), total: 100)
                            .tint(disk.usedPercent > 85 ? MeloTheme.warningAmber : MeloTheme.brandRose)
                    }
                }
            }
        }
    }

    private var hardwareControls: some View {
        SectionSurface("风扇与 Battery Care") {
            HStack {
                Label(model.hardwareHelperState.title, systemImage: helperIcon)
                    .font(.callout.weight(.semibold))
                Spacer()
                if model.hardwareHelperState == .notInstalled {
                    Button("安装 Helper") { showHelperConfirmation = true }.buttonStyle(.bordered)
                } else if model.hardwareHelperState == .enabled || model.hardwareHelperState == .requiresApproval {
                    Button("移除 Helper") { showRemoveHelperConfirmation = true }
                        .buttonStyle(.bordered)
                        .disabled(model.isChangingHardwareControl)
                }
            }
            if model.hardwareHelperState == .developmentBuild ||
                model.hardwareHelperState == .moveToApplications ||
                model.hardwareHelperState == .invalidBuild {
                Text("当前仍提供原生只读 RPM 与能力检测；硬件写入只会在正式签名且位于 /Applications 的构建中开放。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if let hardware = model.hardwareSnapshot, !hardware.fans.isEmpty {
                VStack(spacing: 8) {
                    ForEach(hardware.fans) { fan in
                        HStack {
                            Label("风扇 \(fan.index + 1)", systemImage: "fan")
                            Spacer()
                            Text("\(Int(fan.actualRPM ?? 0)) RPM")
                                .font(.system(.callout, design: .rounded, weight: .semibold))
                                .monospacedDigit()
                            Text(fan.isManual ? "手动" : "系统自动")
                                .font(.caption).foregroundStyle(.secondary).frame(width: 58)
                        }
                    }
                }
                HStack {
                    Button("系统自动") { Task { await model.restoreAutomaticFans() } }
                    Button("安静 45%") { fanPresetCandidate = 0.45 }
                    Button("均衡 70%") { fanPresetCandidate = 0.70 }
                    Button("全速") { fanPresetCandidate = 1.0 }
                }
                .buttonStyle(.bordered)
                .disabled(model.hardwareHelperState != .enabled || model.isChangingHardwareControl)
            } else {
                Label("没有检测到风扇；无风扇 Mac 会自动隐藏控制。", systemImage: "fan.slash")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Divider()
            if let battery = model.hardwareSnapshot?.batteryCare, battery.batteryPresent {
                HStack {
                    Label("Battery Care", systemImage: "battery.75percent")
                    Spacer()
                    if let upper = battery.configuredUpperLimit {
                        if let percent = battery.currentPercent {
                            Text("当前 \(percent)%").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("\(battery.configuredLowerLimit ?? upper - 5)%–\(upper)%")
                            .font(.callout.monospacedDigit())
                        if battery.chargeToFullActive {
                            StatusBadge(title: "充到 100%", systemImage: "bolt.fill", color: MeloTheme.safeGreen)
                        } else {
                            Button("充到 100%") { showChargeToFullConfirmation = true }.buttonStyle(.bordered)
                        }
                        Button("停止") { Task { await model.stopBatteryCare() } }.buttonStyle(.bordered)
                    } else {
                        Button("80%") { batteryLimitCandidate = 80 }
                        Button("85%") { batteryLimitCandidate = 85 }
                        Button("90%") { batteryLimitCandidate = 90 }
                    }
                }
                .buttonStyle(.bordered)
                .disabled(model.hardwareHelperState != .enabled || !battery.chargingControlSupported || model.isChangingHardwareControl)
            } else {
                Label("这台 Mac 没有内置电池，Battery Care 不适用。", systemImage: "desktopcomputer")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var helperIcon: String {
        switch model.hardwareHelperState {
        case .enabled: "checkmark.shield.fill"
        case .requiresApproval: "person.badge.key"
        case .notInstalled: "lock.shield"
        case .developmentBuild, .moveToApplications: "eye"
        case .invalidBuild: "exclamationmark.shield"
        }
    }

    private func processList(_ processes: [LiveProcess]) -> some View {
        SectionSurface("活跃进程") {
            VStack(spacing: 0) {
                HStack {
                    processHeader("进程", sort: .name, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    processHeader("PID", sort: .pid, alignment: .trailing).frame(width: 72)
                    processHeader("CPU", sort: .cpu, alignment: .trailing).frame(width: 86)
                    processHeader("内存", sort: .memory, alignment: .trailing).frame(width: 110)
                    Color.clear.frame(width: 28)
                }
                .padding(.bottom, 7)

                ForEach(sortedProcesses(processes)) { process in
                    Divider()
                    Button {
                        selectedProcess = process
                    } label: {
                        HStack {
                            HStack(spacing: 8) {
                                Image(systemName: model.pinnedProcessIDs.contains(process.pid) ? "pin.fill" : "app.dashed")
                                    .foregroundStyle(model.pinnedProcessIDs.contains(process.pid) ? MeloTheme.brandRose : .secondary)
                                    .frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(process.name).lineLimit(1)
                                    if let path = process.executablePath {
                                        Text(path)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            Text(process.pid.formatted()).frame(width: 72, alignment: .trailing)
                            Text(percent(process.cpu)).frame(width: 86, alignment: .trailing)
                            Text(ByteFormatting.string(process.memoryBytes)).frame(width: 110, alignment: .trailing)
                            if model.terminatingProcessID == process.pid {
                                ProgressView().controlSize(.small).frame(width: 28)
                            } else {
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 28)
                            }
                        }
                        .font(.system(.callout, design: .rounded))
                        .monospacedDigit()
                        .contentShape(Rectangle())
                        .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(
                        "\(process.name)，PID \(process.pid)，CPU \(percent(process.cpu))，内存 \(ByteFormatting.string(process.memoryBytes))"
                    )
                    .accessibilityHint("打开进程说明与管理操作")
                    .contextMenu {
                        Button(model.pinnedProcessIDs.contains(process.pid) ? "取消置顶" : "置顶") {
                            model.toggleProcessPin(process)
                        }
                        if process.executablePath != nil {
                            Button("复制可执行文件路径") { model.copyExecutablePath(process) }
                        }
                        if process.canTerminate {
                            Divider()
                            Button("终止进程", role: .destructive) { processToTerminate = process }
                        }
                    }
                }
            }
        }
    }

    private func processHeader(_ title: String, sort: ProcessSort, alignment: Alignment) -> some View {
        Button {
            if processSort == sort {
                sortAscending.toggle()
            } else {
                processSort = sort
                sortAscending = sort == .name || sort == .pid
            }
        } label: {
            HStack(spacing: 4) {
                Text(title)
                if processSort == sort {
                    Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                        .font(.caption2)
                }
            }
            .frame(maxWidth: .infinity, alignment: alignment)
        }
        .buttonStyle(.plain)
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }

    private func sortedProcesses(_ processes: [LiveProcess]) -> [LiveProcess] {
        processes.sorted { lhs, rhs in
            let lhsPinned = model.pinnedProcessIDs.contains(lhs.pid)
            let rhsPinned = model.pinnedProcessIDs.contains(rhs.pid)
            if lhsPinned != rhsPinned { return lhsPinned }
            let comparison: ComparisonResult
            switch processSort {
            case .name:
                comparison = lhs.name.localizedStandardCompare(rhs.name)
            case .pid:
                comparison = lhs.pid == rhs.pid ? .orderedSame : (lhs.pid < rhs.pid ? .orderedAscending : .orderedDescending)
            case .cpu:
                comparison = lhs.cpu == rhs.cpu ? .orderedSame : (lhs.cpu < rhs.cpu ? .orderedAscending : .orderedDescending)
            case .memory:
                comparison = lhs.memoryBytes == rhs.memoryBytes ? .orderedSame : (lhs.memoryBytes < rhs.memoryBytes ? .orderedAscending : .orderedDescending)
            }
            return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    private func coreDescription(live: LiveSystemSnapshot, detail: MoleStatus?) -> String {
        if let cpu = detail?.cpu,
           let performance = cpu.performanceCoreCount,
           let efficiency = cpu.efficiencyCoreCount {
            return "\(live.perCoreUsage.count) 核心 · \(performance) 性能 + \(efficiency) 能效"
        }
        return "\(live.perCoreUsage.count) 个逻辑核心"
    }

    private func gpuValue(_ gpu: GPUStatus) -> String {
        guard let usage = gpu.usage, usage >= 0 else { return "—" }
        return percent(usage)
    }

    private func localizedHealth(_ message: String?) -> String {
        switch message?.lowercased() {
        case "excellent": "状态优秀"
        case "good": "状态良好"
        case "fair": "需要留意"
        case "poor": "建议检查"
        default: message ?? "综合系统状态"
        }
    }

    private func percent(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0))) + "%"
    }

    private func displayMount(_ mount: String) -> String {
        let name = URL(fileURLWithPath: mount).lastPathComponent
        return name.isEmpty ? mount : name
    }
}

private enum ProcessSort {
    case name
    case pid
    case cpu
    case memory
}

private struct StatusMetricCard: View {
    let title: String
    let value: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    var points: [MetricPoint] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(title, systemImage: systemImage).font(.headline)
                Spacer()
                Text(value)
                    .font(.system(.title3, design: .rounded, weight: .semibold))
                    .monospacedDigit()
            }
            if !points.isEmpty {
                Sparkline(points: points, tint: tint)
            } else {
                Spacer(minLength: 32)
            }
            Text(subtitle.isEmpty ? "暂无详细信息" : subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .padding(17)
        .frame(maxWidth: .infinity, minHeight: 138, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title)，\(value)，\(subtitle)")
    }
}

private struct Sparkline: View {
    let points: [MetricPoint]
    let tint: Color

    var body: some View {
        Chart(points) { point in
            AreaMark(x: .value("时间", point.date), y: .value("数值", point.value))
                .foregroundStyle(
                    LinearGradient(colors: [tint.opacity(0.23), tint.opacity(0.01)], startPoint: .top, endPoint: .bottom)
                )
            LineMark(x: .value("时间", point.date), y: .value("数值", point.value))
                .foregroundStyle(tint)
                .lineStyle(StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 42)
        .accessibilityLabel("最近 \(points.count) 秒趋势")
    }
}

private struct NetworkSparkline: View {
    let received: [MetricPoint]
    let sent: [MetricPoint]

    var body: some View {
        Chart {
            ForEach(received) { point in
                LineMark(x: .value("时间", point.date), y: .value("下载", point.value))
                    .foregroundStyle(.blue)
            }
            ForEach(sent) { point in
                LineMark(x: .value("时间", point.date), y: .value("上传", point.value))
                    .foregroundStyle(MeloTheme.brandRose)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 42)
        .accessibilityLabel("最近 60 秒网络趋势")
    }
}

private struct ProcessExplanationView: View {
    let process: LiveProcess
    let isPinned: Bool
    let pinAction: () -> Void
    let copyAction: () -> Void
    let terminateAction: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(process.name).font(.title2.weight(.semibold))
                    Text("PID \(process.pid) · 父进程 \(process.parentPID)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
            }
            Divider()
            LabeledContent("CPU", value: process.cpu.formatted(.number.precision(.fractionLength(1))) + "%")
            LabeledContent("内存", value: ByteFormatting.string(process.memoryBytes))
            LabeledContent("权限", value: process.isOwnedByCurrentUser ? "当前用户" : "其他用户或系统")
            if let path = process.executablePath {
                VStack(alignment: .leading, spacing: 6) {
                    Text("可执行文件").font(.caption).foregroundStyle(.secondary)
                    Text(path)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
            Spacer()
            HStack {
                Button(isPinned ? "取消置顶" : "置顶进程", action: pinAction)
                    .buttonStyle(.bordered)
                if process.executablePath != nil {
                    Button("复制路径", action: copyAction).buttonStyle(.bordered)
                }
                Spacer()
                if let terminateAction {
                    Button("请求终止", role: .destructive, action: terminateAction)
                        .buttonStyle(.bordered)
                        .help("打开二次确认；不会立即终止")
                }
            }
            Text("数据每秒更新；关闭此面板不会停止进程。终止操作始终需要再次确认。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(24)
    }
}

extension ByteFormatting {
    static func speed(_ bytesPerSecond: Double) -> String {
        let value = max(bytesPerSecond, 0)
        if value >= 1_000_000_000 {
            return (value / 1_000_000_000).formatted(.number.precision(.fractionLength(1))) + " GB/s"
        }
        if value >= 1_000_000 {
            return (value / 1_000_000).formatted(.number.precision(.fractionLength(1))) + " MB/s"
        }
        if value >= 1_000 {
            return (value / 1_000).formatted(.number.precision(.fractionLength(0))) + " KB/s"
        }
        return value.formatted(.number.precision(.fractionLength(0))) + " B/s"
    }
}
