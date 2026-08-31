import AppKit
import ApplicationServices
import AVFoundation
import Darwin
import Foundation
import MeloHardwareProtocol
import Security
import UserNotifications

enum DoctorSeverity: Int, Codable, Comparable, Sendable {
    case healthy
    case information
    case warning
    case critical

    static func < (lhs: DoctorSeverity, rhs: DoctorSeverity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .healthy: "正常"
        case .information: "信息"
        case .warning: "注意"
        case .critical: "严重"
        }
    }
}

struct DoctorItem: Identifiable, Equatable, Sendable {
    let label: String
    let value: String
    let detail: String?
    let severity: DoctorSeverity

    var id: String { label }

    init(_ label: String, _ value: String, detail: String? = nil, severity: DoctorSeverity = .healthy) {
        self.label = label
        self.value = value
        self.detail = detail
        self.severity = severity
    }
}

struct DoctorSection: Identifiable, Equatable, Sendable {
    let title: String
    let items: [DoctorItem]
    var id: String { title }
}

struct DoctorIssue: Identifiable, Equatable, Sendable {
    let title: String
    let detail: String
    let severity: DoctorSeverity
    var id: String { title }
}

struct DoctorReport: Equatable, Sendable {
    let generatedAt: Date
    let sections: [DoctorSection]
    let issues: [DoctorIssue]

    var highestSeverity: DoctorSeverity {
        issues.map(\.severity).max() ?? .healthy
    }

    var plainText: String {
        var lines = [
            "Melo Doctor Report",
            "Generated: \(generatedAt.formatted(.iso8601))",
            ""
        ]
        for section in sections {
            lines.append("## \(section.title)")
            for item in section.items {
                lines.append("- \(item.label): \(item.value)")
                if let detail = item.detail, !detail.isEmpty {
                    lines.append("  \(detail)")
                }
            }
            lines.append("")
        }
        lines.append("## Detected Issues")
        if issues.isEmpty {
            lines.append("- None")
        } else {
            for issue in issues {
                lines.append("- [\(issue.severity.title)] \(issue.title): \(issue.detail)")
            }
        }
        return DoctorPrivacy.redact(lines.joined(separator: "\n"))
    }
}

enum DoctorPermissionState: String, Equatable, Sendable {
    case granted = "已允许"
    case denied = "未允许"
    case notDetermined = "未确定"
    case restricted = "受系统限制"

    var severity: DoctorSeverity {
        switch self {
        case .granted: .healthy
        case .notDetermined: .information
        case .denied, .restricted: .warning
        }
    }
}

struct DoctorSignals: Equatable, Sendable {
    var moleInstalled: Bool
    var fullDiskAccess: DoctorPermissionState
    var accessibility: DoctorPermissionState
    var notifications: DoctorPermissionState
    var privacyAlertsEnabled: Bool
    var helperEnabled: Bool
    var hardwareControlAvailable: Bool
    var memoryUsedPercent: Double?
    var diskUsedPercent: Double?
    var thermalState: Foundation.ProcessInfo.ThermalState
    var recentFailureCount: Int

    static func issues(for signals: DoctorSignals) -> [DoctorIssue] {
        var issues: [DoctorIssue] = []
        if !signals.moleInstalled {
            issues.append(.init(
                title: "Mole CLI 未连接",
                detail: "实时监控仍可用，但清理、卸载、维护和空间分析暂不可用。",
                severity: .warning
            ))
        }
        switch signals.fullDiskAccess {
        case .denied, .restricted:
            issues.append(.init(
                title: "未获得完全磁盘访问",
                detail: "邮件、浏览器与其他受保护目录可能无法完整扫描。Melo 不会自行请求或绕过权限。",
                severity: .warning
            ))
        case .notDetermined:
            issues.append(.init(
                title: "完全磁盘访问状态未确定",
                detail: "当前账户没有可用于只读探测的 TCC 数据库；需要时可在系统设置中核对。",
                severity: .information
            ))
        case .granted:
            break
        }
        if signals.accessibility != .granted {
            issues.append(.init(
                title: "辅助功能权限未允许",
                detail: "核心功能不依赖此权限；Doctor 仅报告当前系统授权状态。",
                severity: .information
            ))
        }
        if signals.privacyAlertsEnabled, signals.notifications != .granted {
            issues.append(.init(
                title: "隐私提醒无法发送系统通知",
                detail: "摄像头或麦克风活动仍会在菜单栏显示，但不会弹出系统通知。",
                severity: .warning
            ))
        }
        if signals.hardwareControlAvailable, !signals.helperEnabled {
            issues.append(.init(
                title: "硬件控制 Helper 未启用",
                detail: "原生传感器监测可用；风扇或 Battery Care 写入保持关闭。",
                severity: .warning
            ))
        }
        if let memory = signals.memoryUsedPercent, memory >= 90 {
            issues.append(.init(
                title: "内存使用率较高",
                detail: "当前已使用 \(memory.formatted(.number.precision(.fractionLength(0))))%。",
                severity: .warning
            ))
        }
        if let disk = signals.diskUsedPercent, disk >= 90 {
            issues.append(.init(
                title: "系统磁盘空间不足",
                detail: "当前已使用 \(disk.formatted(.number.precision(.fractionLength(0))))%。",
                severity: .warning
            ))
        }
        if signals.thermalState == .serious || signals.thermalState == .critical {
            issues.append(.init(
                title: "系统温控压力较高",
                detail: signals.thermalState == .critical ? "macOS 报告严重温控压力。" : "macOS 已开始明显限制性能。",
                severity: signals.thermalState == .critical ? .critical : .warning
            ))
        }
        if signals.recentFailureCount > 0 {
            issues.append(.init(
                title: "最近操作存在失败项",
                detail: "操作记录中共有 \(signals.recentFailureCount) 个失败项，请在“操作记录”查看。",
                severity: .warning
            ))
        }
        return issues.sorted { $0.severity > $1.severity }
    }
}

struct DoctorContext {
    let live: LiveSystemSnapshot?
    let status: MoleStatus?
    let hardware: HardwareControlSnapshot?
    let history: MoleHistory?
    let moleURL: URL?
    let moleVersion: String?
    let helperState: HardwareHelperState
    let launchAtLogin: Bool
    let menuBarOnly: Bool
    let privacyAlerts: Bool
    let cleanProtectedCount: Int
    let optimizeProtectedCount: Int
}

@MainActor
enum DoctorService {
    static func run(context: DoctorContext) async -> DoctorReport {
        let notifications = await notificationPermission()
        let fullDisk = fullDiskAccess()
        let accessibility: DoctorPermissionState = AXIsProcessTrusted() ? .granted : .denied
        let thermal = Foundation.ProcessInfo.processInfo.thermalState
        let failed = context.history?.sessions.reduce(0) {
            $0 + max($1.actions?.failed ?? 0, $1.failedTasks ?? 0)
        } ?? 0
        let internalDisk = context.status?.disks.first(where: { $0.external != true })
            ?? context.status?.disks.first
        let hardwareControlAvailable = context.hardware?.fanControlSupported == true
            || context.hardware?.batteryCare.chargingControlSupported == true
        let signals = DoctorSignals(
            moleInstalled: context.moleURL != nil,
            fullDiskAccess: fullDisk,
            accessibility: accessibility,
            notifications: notifications,
            privacyAlertsEnabled: context.privacyAlerts,
            helperEnabled: context.helperState == .enabled,
            hardwareControlAvailable: hardwareControlAvailable,
            memoryUsedPercent: context.live?.memoryUsedPercent,
            diskUsedPercent: internalDisk?.usedPercent ?? localDiskUsage().percent,
            thermalState: thermal,
            recentFailureCount: failed
        )

        return DoctorReport(
            generatedAt: Date(),
            sections: [
                environmentSection(),
                systemSection(context: context, thermal: thermal),
                permissionsSection(
                    fullDisk: fullDisk,
                    accessibility: accessibility,
                    notifications: notifications
                ),
                configurationSection(context: context),
                securitySection(),
                runtimeSection(context: context, failed: failed)
            ],
            issues: DoctorSignals.issues(for: signals)
        )
    }

    private static func environmentSection() -> DoctorSection {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发构建"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        let displayDetails = NSScreen.screens.map { screen in
            let width = Int(screen.frame.width * screen.backingScaleFactor)
            let height = Int(screen.frame.height * screen.backingScaleFactor)
            let notch = screen.safeAreaInsets.top > 0 ? " · 刘海屏" : ""
            return "\(width)×\(height) @\(Double(screen.backingScaleFactor).formatted(.number.precision(.fractionLength(0...1))))x\(notch)"
        }
        let displays = "\(displayDetails.count) 台 · " + displayDetails.joined(separator: ", ")
        return DoctorSection(title: "环境", items: [
            DoctorItem("应用", "Melo \(version) (\(build))"),
            DoctorItem("macOS", Foundation.ProcessInfo.processInfo.operatingSystemVersionString),
            DoctorItem("芯片", sysctlString("machdep.cpu.brand_string") ?? "Apple Silicon"),
            DoctorItem("机型", sysctlString("hw.model") ?? "未知"),
            DoctorItem("架构", architecture()),
            DoctorItem("语言区域", Locale.current.identifier),
            DoctorItem("Bundle", bundle.bundleIdentifier ?? "dev.melo.companion", detail: bundle.bundleURL.path),
            DoctorItem("显示器", displays.isEmpty ? "未检测到" : displays)
        ])
    }

    private static func systemSection(
        context: DoctorContext,
        thermal: Foundation.ProcessInfo.ThermalState
    ) -> DoctorSection {
        let load = loadAverages()
        let disk = context.status?.disks.first(where: { $0.external != true }) ?? context.status?.disks.first
        let localDisk = localDiskUsage()
        let fanText: String = {
            guard let fans = context.hardware?.fans, !fans.isEmpty else { return "未检测到风扇" }
            return fans.map { fan in
                let rpm = fan.actualRPM?.formatted(.number.precision(.fractionLength(0))) ?? "—"
                return "风扇 \(fan.index + 1) \(rpm) RPM\(fan.isManual ? " 手动" : " 自动")"
            }.joined(separator: ", ")
        }()
        let battery = context.status?.batteries.first
        let batteryText = battery.map {
            let percent = $0.percent?.formatted(.number.precision(.fractionLength(0))) ?? "—"
            return "\(percent)% · \($0.status ?? "状态未知")"
        } ?? (context.hardware?.batteryCare.batteryPresent == true ? "已检测到" : "没有内置电池")
        let topProcesses = context.live?.processes.sorted { $0.cpu > $1.cpu }.prefix(5)
            .map { "\($0.name) \($0.cpu.formatted(.number.precision(.fractionLength(1))))%" }
            .joined(separator: ", ") ?? "尚无采样"
        return DoctorSection(title: "系统", items: [
            DoctorItem("CPU", context.live.map { "\($0.cpuUsage.formatted(.number.precision(.fractionLength(1))))% · \($0.perCoreUsage.count) 核心" } ?? "尚无采样"),
            DoctorItem("负载", load.map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: " / ")),
            DoctorItem("内存", context.live.map { "\(ByteFormatting.string($0.memoryUsed)) / \(ByteFormatting.string($0.memoryTotal)) · \($0.memoryUsedPercent.formatted(.number.precision(.fractionLength(0))))%" } ?? "尚无采样"),
            DoctorItem(
                "内存压力",
                context.status?.memory?.pressure.flatMap { $0.isEmpty ? nil : $0 } ?? "未提供"
            ),
            DoctorItem("温控压力", thermalDescription(thermal), severity: thermal == .critical ? .critical : (thermal == .serious ? .warning : .healthy)),
            DoctorItem("温度", temperatureDescription(context.status?.thermal)),
            DoctorItem("风扇", fanText),
            DoctorItem("磁盘", disk.map { "\(ByteFormatting.string($0.used)) / \(ByteFormatting.string($0.total)) · \($0.usedPercent.formatted(.number.precision(.fractionLength(0))))%" } ?? localDisk.text),
            DoctorItem("电池", batteryText),
            DoctorItem("低电量模式", Foundation.ProcessInfo.processInfo.isLowPowerModeEnabled ? "已开启" : "未开启"),
            DoctorItem("运行时间", duration(Foundation.ProcessInfo.processInfo.systemUptime)),
            DoctorItem("健康度", context.status?.healthScore.map { "\($0) / 100" } ?? "硬件详情尚未刷新"),
            DoctorItem("高 CPU 进程", topProcesses),
            DoctorItem("卷", volumeDescription(context.status?.disks ?? [])),
            DoctorItem("网络隧道", networkTunnels())
        ])
    }

    private static func permissionsSection(
        fullDisk: DoctorPermissionState,
        accessibility: DoctorPermissionState,
        notifications: DoctorPermissionState
    ) -> DoctorSection {
        let camera = capturePermission(.video)
        let microphone = capturePermission(.audio)
        return DoctorSection(title: "权限", items: [
            DoctorItem("完全磁盘访问", fullDisk.rawValue, detail: "通过受 TCC 保护数据库执行只读探测，不会触发授权弹窗。", severity: fullDisk.severity),
            DoctorItem("辅助功能", accessibility.rawValue, detail: "核心功能不要求；仅展示当前授权状态。", severity: accessibility == .granted ? .healthy : .information),
            DoctorItem("通知", notifications.rawValue, severity: notifications.severity),
            DoctorItem("摄像头", camera.rawValue, detail: "Melo 只读取设备是否正在使用，不采集画面。", severity: camera.severity),
            DoctorItem("麦克风", microphone.rawValue, detail: "Melo 只读取设备是否正在使用，不采集声音。", severity: microphone.severity)
        ])
    }

    private static func configurationSection(context: DoctorContext) -> DoctorSection {
        let batteryCare: String = {
            guard let state = context.hardware?.batteryCare else { return "未检测" }
            guard state.batteryPresent else { return "不适用（无内置电池）" }
            if let lower = state.configuredLowerLimit, let upper = state.configuredUpperLimit {
                return "已启用 \(lower)%–\(upper)%"
            }
            return state.chargingControlSupported ? "支持，未启用" : "此机型不支持"
        }()
        return DoctorSection(title: "配置", items: [
            DoctorItem("Mole CLI", context.moleURL.map { "\(context.moleVersion ?? "版本未知") · \($0.path)" } ?? "未连接", severity: context.moleURL == nil ? .warning : .healthy),
            DoctorItem("硬件 Helper", context.helperState.title, severity: context.helperState == .enabled ? .healthy : .information),
            DoctorItem("Battery Care", batteryCare),
            DoctorItem("删除模式", "移入废纸篓（可恢复）"),
            DoctorItem("登录时启动", context.launchAtLogin ? "已启用" : "未启用"),
            DoctorItem("运行方式", context.menuBarOnly ? "仅菜单栏" : "窗口与菜单栏"),
            DoctorItem("菜单栏 HUD", "已启用"),
            DoctorItem("隐私提醒", context.privacyAlerts ? "已启用" : "未启用"),
            DoctorItem("保护项目", "清理 \(context.cleanProtectedCount) 项 · 维护 \(context.optimizeProtectedCount) 项"),
            DoctorItem("代理", proxyDescription())
        ])
    }

    private static func securitySection() -> DoctorSection {
        let signing = signingDescription()
        return DoctorSection(title: "安全", items: [
            DoctorItem("系统完整性保护", commandOutput("/usr/bin/csrutil", ["status"])),
            DoctorItem("代码签名", signing.description, severity: signing.production ? .healthy : .information),
            DoctorItem("App Sandbox", Foundation.ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] == nil ? "未启用（独立分发）" : "已启用"),
            DoctorItem("数据处理", "全部在本机完成，不上传扫描结果"),
            DoctorItem("Helper 能力边界", "仅允许状态、心跳、风扇目标/自动恢复与 Battery Care；不接受任意命令")
        ])
    }

    private static func runtimeSection(context: DoctorContext, failed: Int) -> DoctorSection {
        let operations = context.history?.sessions.count ?? 0
        let deletions = context.history?.deletions.count ?? 0
        let last = context.history?.sessions.first.map { "\($0.command) · \($0.startedAt)" } ?? "无记录"
        return DoctorSection(title: "运行时", items: [
            DoctorItem("实时监控", context.live == nil ? "等待首次采样" : "正常 · 每秒刷新"),
            DoctorItem("操作日志", "\(operations) 次会话 · \(deletions) 条文件记录"),
            DoctorItem("最近操作", last),
            DoctorItem("失败项", "\(failed)", severity: failed > 0 ? .warning : .healthy),
            DoctorItem(
                "硬件协议",
                (context.hardware?.helperVersion ?? 0) > 0
                    ? "Helper v\(context.hardware?.helperVersion ?? 0)"
                    : "原生只读探针"
            )
        ])
    }

    private static func fullDiskAccess() -> DoctorPermissionState {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let protectedFiles = [
            "Library/Application Support/com.apple.TCC/TCC.db",
            "Library/Safari/History.db",
            "Library/Messages/chat.db"
        ]
        var sawPermissionDenial = false
        for relativePath in protectedFiles {
            let descriptor = open(home.appendingPathComponent(relativePath).path, O_RDONLY)
            if descriptor >= 0 {
                close(descriptor)
                return .granted
            }
            if errno == EACCES || errno == EPERM {
                sawPermissionDenial = true
            }
        }
        return sawPermissionDenial ? .denied : .notDetermined
    }

    private static func notificationPermission() async -> DoctorPermissionState {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return .granted
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    private static func capturePermission(_ mediaType: AVMediaType) -> DoctorPermissionState {
        switch AVCaptureDevice.authorizationStatus(for: mediaType) {
        case .authorized: .granted
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .notDetermined
        }
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        return String(cString: bytes)
    }

    private static func architecture() -> String {
        var system = utsname()
        uname(&system)
        let capacity = MemoryLayout.size(ofValue: system.machine)
        return withUnsafePointer(to: &system.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: capacity) {
                String(cString: $0)
            }
        }
    }

    private static func loadAverages() -> [Double] {
        var values = [Double](repeating: 0, count: 3)
        _ = getloadavg(&values, 3)
        return values
    }

    private static func volumeDescription(_ disks: [DiskStatus]) -> String {
        guard !disks.isEmpty else { return "仅系统卷或详情尚未刷新" }
        var seen = Set<String>()
        let descriptions = disks.compactMap { disk -> String? in
            let name = disk.mount == "/" ? "Macintosh HD" : URL(fileURLWithPath: disk.mount).lastPathComponent
            guard seen.insert(name).inserted else { return nil }
            return disk.external == true ? "\(name)（外置）" : name
        }
        return descriptions.joined(separator: " · ")
    }

    private static func networkTunnels() -> String {
        var address: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&address) == 0, let first = address else { return "无法读取" }
        defer { freeifaddrs(address) }
        var names = Set<String>()
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let pointer = current {
            let interface = pointer.pointee
            let flags = Int32(interface.ifa_flags)
            let name = String(cString: interface.ifa_name)
            if flags & IFF_UP != 0, name.hasPrefix("utun") {
                names.insert(name)
            }
            current = interface.ifa_next
        }
        let sorted = names.sorted()
        return sorted.isEmpty ? "无活动隧道" : sorted.joined(separator: ", ") + "（活动）"
    }

    private static func proxyDescription() -> String {
        let raw = commandOutput("/usr/sbin/scutil", ["--proxy"])
        let lines = raw.components(separatedBy: .newlines)
        func value(_ key: String) -> String? {
            lines.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key) :") }?
                .components(separatedBy: ":").dropFirst().joined(separator: ":")
                .trimmingCharacters(in: .whitespaces)
        }
        if value("HTTPSEnable") == "1", let host = value("HTTPSProxy"), let port = value("HTTPSPort") {
            return "HTTPS \(host):\(port)"
        }
        if value("HTTPEnable") == "1", let host = value("HTTPProxy"), let port = value("HTTPPort") {
            return "HTTP \(host):\(port)"
        }
        if value("SOCKSEnable") == "1", let host = value("SOCKSProxy"), let port = value("SOCKSPort") {
            return "SOCKS \(host):\(port)"
        }
        return "未启用"
    }

    private static func localDiskUsage() -> (percent: Double?, text: String) {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys),
              let totalValue = values.volumeTotalCapacity,
              let availableValue = values.volumeAvailableCapacityForImportantUsage else {
            return (nil, "未知")
        }
        let total = UInt64(max(totalValue, 0))
        let available = UInt64(max(availableValue, 0))
        let used = total > available ? total - available : 0
        let percent = total > 0 ? Double(used) / Double(total) * 100 : nil
        return (percent, "\(ByteFormatting.string(used)) / \(ByteFormatting.string(total)) · \(percent?.formatted(.number.precision(.fractionLength(0))) ?? "—")%")
    }

    private static func temperatureDescription(_ thermal: ThermalStatus?) -> String {
        guard let thermal else { return "传感器详情尚未刷新" }
        let values = [
            thermal.cpuTemp.flatMap { $0 > 0 ? "CPU \($0.formatted(.number.precision(.fractionLength(0))))°C" : nil },
            thermal.gpuTemp.flatMap { $0 > 0 ? "GPU \($0.formatted(.number.precision(.fractionLength(0))))°C" : nil },
            thermal.batteryTemp.flatMap { $0 > 0 ? "电池 \($0.formatted(.number.precision(.fractionLength(0))))°C" : nil }
        ].compactMap { $0 }
        return values.isEmpty ? "此机型未提供" : values.joined(separator: " · ")
    }

    private static func thermalDescription(_ state: Foundation.ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "正常"
        case .fair: "轻微"
        case .serious: "较高"
        case .critical: "严重"
        @unknown default: "未知"
        }
    }

    private static func duration(_ seconds: TimeInterval) -> String {
        let days = Int(seconds) / 86_400
        let hours = (Int(seconds) % 86_400) / 3_600
        return days > 0 ? "\(days) 天 \(hours) 小时" : "\(hours) 小时"
    }

    private static func commandOutput(_ executable: String, _ arguments: [String]) -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return output.isEmpty ? "未知" : output
        } catch {
            return "无法读取"
        }
    }

    private static func signingDescription() -> (description: String, production: Bool) {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code else { return ("无法读取", false) }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return ("无法读取", false) }
        if let team = dictionary[kSecCodeInfoTeamIdentifier as String] as? String {
            let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate]
            let authority = certificates?.first
                .flatMap { SecCertificateCopySubjectSummary($0) as String? }
                ?? "Apple 签名"
            let isDeveloperID = authority.hasPrefix("Developer ID Application:")
            return ("\(authority) · Team \(team)", isDeveloperID)
        }
        return ("本地/临时签名（硬件写入保持关闭）", false)
    }
}

enum DoctorPrivacy {
    static func redact(_ text: String, homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        let home = homeDirectory.standardizedFileURL.path
        guard home != "/", !home.isEmpty else { return text }
        return text.replacingOccurrences(of: home, with: "~")
    }
}

enum SystemSettingsTarget {
    case fullDiskAccess
    case accessibility
    case notifications
    case camera
    case microphone

    var urlString: String {
        switch self {
        case .fullDiskAccess: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        case .accessibility: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        case .notifications: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        case .camera: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
        case .microphone: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
        }
    }
}
