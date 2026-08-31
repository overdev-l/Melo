import Foundation

enum SidebarItem: String, CaseIterable, Identifiable {
    case overview
    case cleanup
    case software
    case maintenance
    case storage
    case status
    case doctor
    case history
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "概览"
        case .cleanup: "智能清理"
        case .software: "软件"
        case .maintenance: "系统维护"
        case .storage: "空间分析"
        case .status: "系统状态"
        case .doctor: "Doctor"
        case .history: "操作记录"
        case .settings: "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "rectangle.3.group"
        case .cleanup: "sparkles"
        case .software: "square.stack.3d.up"
        case .maintenance: "wrench.and.screwdriver"
        case .storage: "internaldrive"
        case .status: "waveform.path.ecg"
        case .doctor: "stethoscope"
        case .history: "clock.arrow.circlepath"
        case .settings: "gearshape"
        }
    }
}

struct MoleApplication: Decodable, Equatable, Identifiable {
    let name: String
    let bundleID: String
    let source: String
    let uninstallName: String
    let path: String
    let size: String

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case name
        case bundleID = "bundle_id"
        case source
        case uninstallName = "uninstall_name"
        case path
        case size
    }

    var sizeInBytes: UInt64? {
        SizeStringParser.bytes(from: size)
    }
}

struct UninstallPreview: Equatable {
    let application: MoleApplication
    let paths: [String]
    let summary: String
    let rawOutput: String

    static func parse(_ output: String, application: MoleApplication) -> UninstallPreview {
        let cleanOutput = output.strippingANSISequences()
        let paths = cleanOutput.components(separatedBy: .newlines).compactMap { line -> String? in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.hasPrefix("✓") || trimmed.hasPrefix("⚠") else { return nil }
            return trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
        }
        let summary = cleanOutput.components(separatedBy: .newlines)
            .first(where: { $0.contains("Would remove") })?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "将移除 \(application.name) 及 Mole 能安全关联的残留文件"
        return UninstallPreview(application: application, paths: paths, summary: summary, rawOutput: cleanOutput)
    }
}

struct UninstallResult: Equatable {
    let applicationName: String
    let summary: String
    let rawOutput: String

    static func parse(_ output: String, applicationName: String) -> UninstallResult {
        let cleanOutput = output.strippingANSISequences()
        let summary = cleanOutput.components(separatedBy: .newlines)
            .first(where: { $0.localizedCaseInsensitiveContains("freed") || $0.localizedCaseInsensitiveContains("removed") })?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "\(applicationName) 已处理完成"
        return UninstallResult(applicationName: applicationName, summary: summary, rawOutput: cleanOutput)
    }
}

struct MaintenancePreview: Equatable {
    let sections: [CleanupSection]
    let applicableCount: Int?
    let unchangedCount: Int?
    let skippedCount: Int?
    let rawOutput: String

    static func parse(_ output: String) -> MaintenancePreview {
        let cleanOutput = output.strippingANSISequences()
        let sections = MoleSectionParser.sections(from: cleanOutput)
        let applicableCount = matchInteger(in: cleanOutput, pattern: #"Would apply\s+(\d+)\s+optimizations"#)
        let unchangedCount = matchInteger(in: cleanOutput, pattern: #"(\d+)\s+unchanged"#)
        let skippedCount = matchInteger(in: cleanOutput, pattern: #"(\d+)\s+skipped"#)
        return MaintenancePreview(
            sections: sections,
            applicableCount: applicableCount,
            unchangedCount: unchangedCount,
            skippedCount: skippedCount,
            rawOutput: cleanOutput
        )
    }

    private static func matchInteger(in text: String, pattern: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[range])
    }
}

struct MaintenanceResult: Equatable {
    let summary: String
    let rawOutput: String

    static func parse(_ output: String) -> MaintenanceResult {
        let cleanOutput = output.strippingANSISequences()
        let summary = cleanOutput.components(separatedBy: .newlines)
            .first(where: { $0.localizedCaseInsensitiveContains("optimizations") && !$0.localizedCaseInsensitiveContains("Would apply") })?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "系统维护已完成"
        return MaintenanceResult(summary: summary, rawOutput: cleanOutput)
    }
}

struct MoleStatus: Decodable, Equatable {
    let collectedAt: String?
    let host: String?
    let uptime: String?
    let procs: Int?
    let hardware: HardwareInfo?
    let healthScore: Int?
    let healthScoreMessage: String?
    let cpu: CPUStatus?
    let memory: MemoryStatus?
    let gpu: [GPUStatus]
    let network: [NetworkStatus]
    let diskIO: DiskIOStatus?
    let batteries: [BatteryStatus]
    let bluetooth: [BluetoothDeviceStatus]
    let disks: [DiskStatus]
    let topProcesses: [ProcessInfo]
    let thermal: ThermalStatus?

    enum CodingKeys: String, CodingKey {
        case collectedAt = "collected_at"
        case host
        case uptime
        case procs
        case hardware
        case healthScore = "health_score"
        case healthScoreMessage = "health_score_msg"
        case cpu
        case memory
        case gpu
        case network
        case diskIO = "disk_io"
        case batteries
        case bluetooth
        case disks
        case topProcesses = "top_processes"
        case thermal
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        collectedAt = try container.decodeIfPresent(String.self, forKey: .collectedAt)
        host = try container.decodeIfPresent(String.self, forKey: .host)
        uptime = try container.decodeIfPresent(String.self, forKey: .uptime)
        procs = try container.decodeIfPresent(Int.self, forKey: .procs)
        hardware = try container.decodeIfPresent(HardwareInfo.self, forKey: .hardware)
        healthScore = try container.decodeIfPresent(Int.self, forKey: .healthScore)
        healthScoreMessage = try container.decodeIfPresent(String.self, forKey: .healthScoreMessage)
        cpu = try container.decodeIfPresent(CPUStatus.self, forKey: .cpu)
        memory = try container.decodeIfPresent(MemoryStatus.self, forKey: .memory)
        gpu = try container.decodeIfPresent([GPUStatus].self, forKey: .gpu) ?? []
        network = try container.decodeIfPresent([NetworkStatus].self, forKey: .network) ?? []
        diskIO = try container.decodeIfPresent(DiskIOStatus.self, forKey: .diskIO)
        batteries = try container.decodeIfPresent([BatteryStatus].self, forKey: .batteries) ?? []
        bluetooth = try container.decodeIfPresent([BluetoothDeviceStatus].self, forKey: .bluetooth) ?? []
        disks = try container.decodeIfPresent([DiskStatus].self, forKey: .disks) ?? []
        topProcesses = try container.decodeIfPresent([ProcessInfo].self, forKey: .topProcesses) ?? []
        thermal = try container.decodeIfPresent(ThermalStatus.self, forKey: .thermal)
    }
}

struct HardwareInfo: Decodable, Equatable {
    let model: String?
    let cpuModel: String?
    let totalRAM: String?
    let diskSize: String?
    let osVersion: String?

    enum CodingKeys: String, CodingKey {
        case model
        case cpuModel = "cpu_model"
        case totalRAM = "total_ram"
        case diskSize = "disk_size"
        case osVersion = "os_version"
    }
}

struct CPUStatus: Decodable, Equatable {
    let usage: Double
    let perCore: [Double]
    let load1: Double?
    let load5: Double?
    let load15: Double?
    let coreCount: Int?
    let performanceCoreCount: Int?
    let efficiencyCoreCount: Int?

    enum CodingKeys: String, CodingKey {
        case usage
        case perCore = "per_core"
        case load1
        case load5
        case load15
        case coreCount = "core_count"
        case performanceCoreCount = "p_core_count"
        case efficiencyCoreCount = "e_core_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usage = try container.decodeIfPresent(Double.self, forKey: .usage) ?? 0
        perCore = try container.decodeIfPresent([Double].self, forKey: .perCore) ?? []
        load1 = try container.decodeIfPresent(Double.self, forKey: .load1)
        load5 = try container.decodeIfPresent(Double.self, forKey: .load5)
        load15 = try container.decodeIfPresent(Double.self, forKey: .load15)
        coreCount = try container.decodeIfPresent(Int.self, forKey: .coreCount)
        performanceCoreCount = try container.decodeIfPresent(Int.self, forKey: .performanceCoreCount)
        efficiencyCoreCount = try container.decodeIfPresent(Int.self, forKey: .efficiencyCoreCount)
    }
}

struct MemoryStatus: Decodable, Equatable {
    let used: UInt64
    let total: UInt64
    let available: UInt64?
    let usedPercent: Double
    let swapUsed: UInt64?
    let swapTotal: UInt64?
    let cached: UInt64?
    let pressure: String?

    enum CodingKeys: String, CodingKey {
        case used
        case total
        case available
        case usedPercent = "used_percent"
        case swapUsed = "swap_used"
        case swapTotal = "swap_total"
        case cached
        case pressure
    }
}

struct GPUStatus: Decodable, Equatable, Identifiable {
    let name: String
    let usage: Double?
    let memoryUsed: UInt64?
    let memoryTotal: UInt64?
    let coreCount: Int?
    let note: String?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case usage
        case memoryUsed = "memory_used"
        case memoryTotal = "memory_total"
        case coreCount = "core_count"
        case note
    }
}

struct NetworkStatus: Decodable, Equatable, Identifiable {
    let name: String
    let receiveRateMB: Double
    let sendRateMB: Double
    let ip: String?

    var id: String { name }

    enum CodingKeys: String, CodingKey {
        case name
        case receiveRateMB = "rx_rate_mbs"
        case sendRateMB = "tx_rate_mbs"
        case ip
    }
}

struct DiskIOStatus: Decodable, Equatable {
    let readRate: Double
    let writeRate: Double

    enum CodingKeys: String, CodingKey {
        case readRate = "read_rate"
        case writeRate = "write_rate"
    }
}

struct BatteryStatus: Decodable, Equatable, Identifiable {
    let name: String?
    let percent: Double?
    let status: String?
    let health: Double?
    let cycles: Int?
    let power: Double?

    var id: String { name ?? "battery" }

    enum CodingKeys: String, CodingKey {
        case name
        case percent
        case status
        case health
        case cycles
        case power
    }
}

struct BluetoothDeviceStatus: Decodable, Equatable, Identifiable {
    let name: String
    let connected: Bool?
    let battery: String?

    var id: String { name }
}

struct DiskStatus: Decodable, Equatable, Identifiable {
    let mount: String
    let device: String?
    let used: UInt64
    let total: UInt64
    let usedPercent: Double
    let external: Bool?
    let smartStatus: String?

    var id: String { "\(device ?? mount)-\(mount)" }

    enum CodingKeys: String, CodingKey {
        case mount
        case device
        case used
        case total
        case usedPercent = "used_percent"
        case external
        case smartStatus = "smart_status"
    }
}

struct ProcessInfo: Decodable, Equatable, Identifiable {
    let pid: Int
    let name: String
    let cpu: Double
    let memory: Double
    let memoryBytes: UInt64?

    var id: Int { pid }

    enum CodingKeys: String, CodingKey {
        case pid
        case name
        case cpu
        case memory
        case memoryBytes = "memory_bytes"
    }
}

struct ThermalStatus: Decodable, Equatable {
    let cpuTemp: Double?
    let gpuTemp: Double?
    let batteryTemp: Double?
    let fanSpeed: Int?
    let fanCount: Int?
    let systemPower: Double?
    let adapterPower: Double?
    let batteryPower: Double?

    enum CodingKeys: String, CodingKey {
        case cpuTemp = "cpu_temp"
        case gpuTemp = "gpu_temp"
        case batteryTemp = "battery_temp"
        case fanSpeed = "fan_speed"
        case fanCount = "fan_count"
        case systemPower = "system_power"
        case adapterPower = "adapter_power"
        case batteryPower = "battery_power"
    }
}

struct DiskAnalysis: Decodable, Equatable {
    let path: String
    let entries: [AnalysisEntry]
    let largeFiles: [AnalysisEntry]
    let totalSize: UInt64
    let totalFiles: Int

    enum CodingKeys: String, CodingKey {
        case path
        case entries
        case largeFiles = "large_files"
        case totalSize = "total_size"
        case totalFiles = "total_files"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        entries = try container.decodeIfPresent([AnalysisEntry].self, forKey: .entries) ?? []
        largeFiles = try container.decodeIfPresent([AnalysisEntry].self, forKey: .largeFiles) ?? []
        totalSize = try container.decodeIfPresent(UInt64.self, forKey: .totalSize) ?? 0
        totalFiles = try container.decodeIfPresent(Int.self, forKey: .totalFiles) ?? 0
    }
}

struct AnalysisEntry: Decodable, Equatable, Identifiable {
    let name: String
    let path: String
    let size: UInt64
    let isDirectory: Bool?

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case name
        case path
        case size
        case isDirectory = "is_dir"
    }
}

struct MoleHistory: Decodable, Equatable {
    let sessions: [HistorySession]
    let deletions: [DeletionRecord]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sessions = try container.decodeIfPresent([HistorySession].self, forKey: .sessions) ?? []
        deletions = try container.decodeIfPresent([DeletionRecord].self, forKey: .deletions) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case sessions
        case deletions
    }
}

struct HistorySession: Decodable, Equatable, Identifiable {
    let command: String
    let startedAt: String
    let endedAt: String?
    let items: Int?
    let size: String?
    let operationCount: Int?
    let failedTasks: Int?
    let actions: HistoryActions?

    var id: String { "\(command)-\(startedAt)" }

    enum CodingKeys: String, CodingKey {
        case command
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case items
        case size
        case operationCount = "operation_count"
        case failedTasks = "failed_tasks"
        case actions
    }
}

struct HistoryActions: Decodable, Equatable {
    let removed: Int?
    let trashed: Int?
    let skipped: Int?
    let failed: Int?
    let rebuilt: Int?
}

struct DeletionRecord: Decodable, Equatable, Identifiable {
    let timestamp: String
    let mode: String
    let status: String
    let sizeKB: Int?
    let path: String

    var id: String { "\(timestamp)-\(path)" }

    enum CodingKeys: String, CodingKey {
        case timestamp
        case mode
        case status
        case sizeKB = "size_kb"
        case path
    }
}

struct CleanupPreview: Equatable {
    let sections: [CleanupSection]
    let potentialSpace: String?
    let itemCount: Int?
    let categoryCount: Int?
    let requiresAdminForFullPreview: Bool
    let rawOutput: String

    static func parse(_ output: String) -> CleanupPreview {
        let cleanOutput = output.strippingANSISequences()
        var sections: [CleanupSection] = []
        var currentTitle: String?
        var currentItems: [CleanupItem] = []

        func flushSection() {
            guard let title = currentTitle else { return }
            sections.append(CleanupSection(title: title, items: currentItems))
            currentItems.removeAll(keepingCapacity: true)
        }

        for originalLine in cleanOutput.components(separatedBy: .newlines) {
            let line = originalLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            if line.hasPrefix("➤") {
                flushSection()
                currentTitle = line.dropFirst().trimmingCharacters(in: .whitespaces)
                continue
            }

            guard currentTitle != nil else { continue }
            if ["→", "✓", "◎", "⊙", "•"].contains(where: line.hasPrefix) {
                let symbol = String(line.prefix(1))
                let text = line.dropFirst().trimmingCharacters(in: .whitespaces)
                currentItems.append(CleanupItem(symbol: symbol, text: text))
            }
        }
        flushSection()

        let summaryPattern = #"Potential space:\s*([^|\n]+)(?:\s*\|\s*Items:\s*(\d+))?(?:\s*\|\s*Categories:\s*(\d+))?"#
        var potentialSpace: String?
        var itemCount: Int?
        var categoryCount: Int?
        if let regex = try? NSRegularExpression(pattern: summaryPattern),
           let match = regex.firstMatch(in: cleanOutput, range: NSRange(cleanOutput.startIndex..., in: cleanOutput)) {
            if let range = Range(match.range(at: 1), in: cleanOutput) {
                potentialSpace = String(cleanOutput[range]).trimmingCharacters(in: .whitespaces)
            }
            if match.numberOfRanges > 2, let range = Range(match.range(at: 2), in: cleanOutput) {
                itemCount = Int(cleanOutput[range])
            }
            if match.numberOfRanges > 3, let range = Range(match.range(at: 3), in: cleanOutput) {
                categoryCount = Int(cleanOutput[range])
            }
        }

        return CleanupPreview(
            sections: sections.filter { !$0.items.isEmpty },
            potentialSpace: potentialSpace,
            itemCount: itemCount,
            categoryCount: categoryCount,
            requiresAdminForFullPreview: cleanOutput.localizedCaseInsensitiveContains("System caches need sudo"),
            rawOutput: cleanOutput
        )
    }
}

struct CleanupSection: Equatable, Identifiable {
    let title: String
    let items: [CleanupItem]

    var id: String { title }
}

struct CleanupItem: Equatable, Identifiable {
    let symbol: String
    let text: String

    var id: String { "\(symbol)-\(text)" }

    var isSkipped: Bool { symbol == "◎" }
    var isInformational: Bool { symbol == "⊙" || symbol == "•" }
}

struct CleanupRunResult: Equatable {
    let output: String
    let summary: String

    static func parse(_ output: String) -> CleanupRunResult {
        let cleanOutput = output.strippingANSISequences()
        let lines = cleanOutput.components(separatedBy: .newlines)
        let summary = lines.first(where: { $0.contains("Tracked cleanup:") })?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? (cleanOutput.contains("System was already clean") ? "系统已经很干净" : "清理已完成")
        return CleanupRunResult(output: cleanOutput, summary: summary)
    }
}

extension String {
    func strippingANSISequences() -> String {
        let pattern = #"\u{001B}\[[0-?]*[ -/]*[@-~]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return self }
        return regex.stringByReplacingMatches(
            in: self,
            range: NSRange(startIndex..., in: self),
            withTemplate: ""
        )
    }
}

enum ByteFormatting {
    static let formatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter
    }()

    static func string(_ bytes: UInt64) -> String {
        formatter.string(fromByteCount: Int64(clamping: bytes))
    }

    static func string(kilobytes: Int?) -> String {
        guard let kilobytes else { return "大小未知" }
        return formatter.string(fromByteCount: Int64(kilobytes) * 1024)
    }
}

enum MoleSectionParser {
    static func sections(from output: String) -> [CleanupSection] {
        var sections: [CleanupSection] = []
        var currentTitle: String?
        var currentItems: [CleanupItem] = []

        func flush() {
            guard let currentTitle else { return }
            sections.append(CleanupSection(title: currentTitle, items: currentItems))
            currentItems.removeAll(keepingCapacity: true)
        }

        for originalLine in output.components(separatedBy: .newlines) {
            let line = originalLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            if line.hasPrefix("➤") {
                flush()
                currentTitle = line.dropFirst().trimmingCharacters(in: .whitespaces)
            } else if currentTitle != nil,
                      ["→", "✓", "◎", "⊙", "•"].contains(where: line.hasPrefix) {
                currentItems.append(CleanupItem(
                    symbol: String(line.prefix(1)),
                    text: line.dropFirst().trimmingCharacters(in: .whitespaces)
                ))
            }
        }
        flush()
        return sections.filter { !$0.items.isEmpty }
    }
}

enum SizeStringParser {
    static func bytes(from value: String) -> UInt64? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard normalized != "--" else { return nil }
        let pattern = #"^([0-9]+(?:\.[0-9]+)?)\s*(KB|MB|GB|TB|B)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
              let numberRange = Range(match.range(at: 1), in: normalized),
              let unitRange = Range(match.range(at: 2), in: normalized),
              let number = Double(normalized[numberRange]) else { return nil }
        let multiplier: Double = switch String(normalized[unitRange]) {
        case "KB": 1_024
        case "MB": 1_048_576
        case "GB": 1_073_741_824
        case "TB": 1_099_511_627_776
        default: 1
        }
        return UInt64(number * multiplier)
    }
}
