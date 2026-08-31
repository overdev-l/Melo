import Foundation
import IOKit
import IOKit.ps
import MeloHardwareProtocol
import Security
import SMCCore

private final class HardwareDaemon: NSObject, MeloHardwareXPCProtocol, @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.melo.companion.hardware.state")
    private let backend: SMCConnection?
    private let capabilities: Capabilities
    private var fanController: FanController?
    private var ftstGate = FtstGateManager()
    private var lastHeartbeat = Date.distantPast
    private var activeConnections = 0
    private var batteryPolicy: BatteryCarePolicy?
    private var chargingAllowed: Bool?
    private var timer: DispatchSourceTimer?

    override init() {
        if let connection = try? SMCConnection() {
            backend = connection
            capabilities = KeyCatalog().detectCapabilities(using: connection)
            fanController = FanController(backend: connection, capabilities: capabilities)
        } else {
            backend = nil
            capabilities = Capabilities()
            fanController = nil
        }
        super.init()
        batteryPolicy = Self.loadBatteryPolicy()
        restoreChargingToSafeDefault()
        startSafetyTimer()
    }

    deinit {
        timer?.cancel()
        restoreAllFans()
        restoreChargingToSafeDefault()
    }

    func clientConnected() {
        queue.async {
            self.activeConnections += 1
            self.lastHeartbeat = Date()
        }
    }

    func clientDisconnected() {
        queue.async {
            self.activeConnections = max(0, self.activeConnections - 1)
            if self.activeConnections == 0 { self.restoreAllFans() }
        }
    }

    func perform(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void) {
        queue.async {
            do {
                let request = try JSONDecoder().decode(HardwareControlRequest.self, from: requestData)
                let response = try self.execute(request)
                reply(try JSONEncoder().encode(response), nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }

    private func execute(_ request: HardwareControlRequest) throws -> HardwareControlResponse {
        let message: String?
        switch request.command {
        case .snapshot:
            lastHeartbeat = Date()
            message = nil
        case .heartbeat:
            lastHeartbeat = Date()
            message = nil
        case .setFanTarget(let requestedIndex, let requestedRPM):
            try setFanTarget(index: requestedIndex, rpm: requestedRPM)
            lastHeartbeat = Date()
            message = "风扇目标已应用，并由断联看门狗保护。"
        case .restoreFanAuto(let index):
            try restoreFans(index: index)
            message = "风扇已交还 macOS 自动控制。"
        case .setBatteryCare(let lower, let upper):
            try setBatteryCare(lower: lower, upper: upper)
            message = "Battery Care 已设置为 \(lower)%–\(upper)%。"
        case .chargeToFull:
            try chargeToFull()
            message = "正在临时充到 100%，完成后会恢复 Battery Care 区间。"
        case .stopBatteryCare:
            try stopBatteryCare()
            message = "Battery Care 已停止，充电控制已交还系统。"
        }
        return HardwareControlResponse(
            requestID: request.requestID,
            snapshot: snapshot(),
            message: message
        )
    }

    private func snapshot() -> HardwareControlSnapshot {
        let fanStates = fanController?.status().map {
            HardwareFanState(
                index: $0.index,
                actualRPM: $0.actualRPM,
                targetRPM: $0.targetRPM,
                minimumRPM: $0.minimumRPM,
                maximumRPM: $0.maximumRPM,
                isManual: $0.mode == .manual
            )
        } ?? []
        return HardwareControlSnapshot(
            fans: fanStates,
            fanControlSupported: capabilities.fans.contains { $0.modeKey != nil },
            ftstAvailable: capabilities.ftstAvailable,
            batteryCare: BatteryCareState(
                batteryPresent: Self.batteryChargePercent() != nil,
                chargingControlSupported: capabilities.chargingControl != nil,
                configuredLowerLimit: batteryPolicy?.lower,
                configuredUpperLimit: batteryPolicy?.upper,
                isChargingAllowed: chargingAllowed,
                currentPercent: Self.batteryChargePercent(),
                chargeToFullActive: batteryPolicy?.chargeToFull ?? false
            ),
            helperVersion: MeloHardwareProtocolInfo.helperVersion
        )
    }

    private func setFanTarget(index: Int?, rpm: Double) throws {
        guard rpm.isFinite, let fanController else { throw HardwareHelperError.fanUnsupported }
        let statuses = fanController.status()
        let selected = index.map { target in statuses.filter { $0.index == target } } ?? statuses
        guard !selected.isEmpty else { throw HardwareHelperError.fanUnsupported }
        do {
            for fan in selected {
                guard let minimum = fan.minimumRPM,
                      let maximum = fan.maximumRPM,
                      let clamped = HardwareSafetyPolicy.clampedRPM(
                        rpm,
                        minimum: minimum,
                        maximum: maximum
                      ) else {
                    throw HardwareHelperError.fanLimitsUnavailable
                }
                _ = try fanController.setManual(index: fan.index, rpm: clamped)
                ftstGate.enterManual(index: fan.index)
            }
        } catch {
            restoreAllFans()
            throw error
        }
    }

    private func restoreFans(index: Int?) throws {
        guard let fanController else { throw HardwareHelperError.fanUnsupported }
        let indices = index.map { [$0] } ?? fanController.status().map(\.index)
        for fanIndex in indices {
            let othersRemain = ftstGate.otherManualFansRemain(afterLeaving: fanIndex)
            try fanController.setAuto(index: fanIndex, otherManualFansRemaining: othersRemain)
            ftstGate.leaveManual(index: fanIndex)
        }
        if !ftstGate.hasManualFans { try fanController.clearFtstIfSet() }
    }

    private func restoreAllFans() {
        guard let fanController else { return }
        for fanIndex in fanController.status().map(\.index) {
            let othersRemain = ftstGate.otherManualFansRemain(afterLeaving: fanIndex)
            try? fanController.setAuto(index: fanIndex, otherManualFansRemaining: othersRemain)
            ftstGate.leaveManual(index: fanIndex)
        }
        try? fanController.clearFtstIfSet()
        ftstGate.removeAll()
    }

    private func setBatteryCare(lower: Int, upper: Int) throws {
        guard Self.batteryChargePercent() != nil,
              capabilities.chargingControl != nil else {
            throw HardwareHelperError.batteryUnsupported
        }
        guard HardwareSafetyPolicy.isValidBatteryRange(lower: lower, upper: upper) else {
            throw HardwareHelperError.invalidBatteryRange
        }
        batteryPolicy = BatteryCarePolicy(lower: lower, upper: upper, chargeToFull: false)
        try Self.saveBatteryPolicy(batteryPolicy)
        evaluateBatteryPolicy()
    }

    private func chargeToFull() throws {
        guard Self.batteryChargePercent() != nil,
              capabilities.chargingControl != nil,
              var policy = batteryPolicy else {
            throw HardwareHelperError.batteryCareNotEnabled
        }
        policy.chargeToFull = true
        batteryPolicy = policy
        try Self.saveBatteryPolicy(policy)
        try setCharging(enabled: true)
    }

    private func stopBatteryCare() throws {
        batteryPolicy = nil
        try Self.saveBatteryPolicy(nil)
        try setCharging(enabled: true)
    }

    private func evaluateBatteryPolicy() {
        guard let batteryPolicy, let percent = Self.batteryChargePercent() else { return }
        let evaluation = HardwareSafetyPolicy.batteryChargeEvaluation(
            percent: percent,
            lower: batteryPolicy.lower,
            upper: batteryPolicy.upper,
            chargeToFull: batteryPolicy.chargeToFull
        )
        if evaluation.completedChargeToFull {
            var resumed = batteryPolicy
            resumed.chargeToFull = false
            self.batteryPolicy = resumed
            try? Self.saveBatteryPolicy(resumed)
        }
        if let allowed = evaluation.chargingAllowed, chargingAllowed != allowed {
            try? setCharging(enabled: allowed)
        }
    }

    private func setCharging(enabled: Bool) throws {
        guard let backend, let group = capabilities.chargingControl else {
            throw HardwareHelperError.batteryUnsupported
        }
        let writes = enabled ? group.enableWrites : group.disableWrites
        for write in writes { try backend.writeKey(write.key, bytes: write.bytes) }
        chargingAllowed = enabled
    }

    private func restoreChargingToSafeDefault() {
        if capabilities.chargingControl != nil {
            try? setCharging(enabled: true)
        }
    }

    private func startSafetyTimer() {
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + .seconds(1), repeating: .seconds(1))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            if HardwareSafetyPolicy.shouldRestoreManualFans(
                hasManualFans: self.ftstGate.hasManualFans,
                activeConnections: self.activeConnections,
                lastHeartbeat: self.lastHeartbeat,
                now: Date(),
                thermalPressureIsUnsafe: Self.thermalPressureIsUnsafe
            ) {
                self.restoreAllFans()
            }
            self.evaluateBatteryPolicy()
        }
        source.resume()
        timer = source
    }

    private static var thermalPressureIsUnsafe: Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: true
        case .nominal, .fair: false
        @unknown default: true
        }
    }

    private static func batteryChargePercent() -> Int? {
        guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
            return nil
        }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue()
                    as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int,
                  maximum > 0 else {
                continue
            }
            let ratio = Double(current) / Double(maximum)
            return Int((ratio * 100).rounded())
        }
        return nil
    }

    private static let policyURL = URL(fileURLWithPath: "/Library/Application Support/Melo/battery-care.json")

    private static func loadBatteryPolicy() -> BatteryCarePolicy? {
        guard let data = try? Data(contentsOf: policyURL) else { return nil }
        return try? JSONDecoder().decode(BatteryCarePolicy.self, from: data)
    }

    private static func saveBatteryPolicy(_ policy: BatteryCarePolicy?) throws {
        let manager = FileManager.default
        let directory = policyURL.deletingLastPathComponent()
        try manager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        guard let policy else {
            if manager.fileExists(atPath: policyURL.path) { try manager.removeItem(at: policyURL) }
            return
        }
        try JSONEncoder().encode(policy).write(to: policyURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: policyURL.path)
    }
}

private struct BatteryCarePolicy: Codable, Equatable, Sendable {
    let lower: Int
    let upper: Int
    var chargeToFull: Bool

    private enum CodingKeys: String, CodingKey {
        case lower
        case upper
        case chargeToFull
    }

    init(lower: Int, upper: Int, chargeToFull: Bool) {
        self.lower = lower
        self.upper = upper
        self.chargeToFull = chargeToFull
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        lower = try container.decode(Int.self, forKey: .lower)
        upper = try container.decode(Int.self, forKey: .upper)
        chargeToFull = try container.decodeIfPresent(Bool.self, forKey: .chargeToFull) ?? false
    }
}

private enum HardwareHelperError: LocalizedError {
    case fanUnsupported
    case fanLimitsUnavailable
    case batteryUnsupported
    case batteryCareNotEnabled
    case invalidBatteryRange

    var errorDescription: String? {
        switch self {
        case .fanUnsupported: "这台 Mac 没有可安全控制的风扇。"
        case .fanLimitsUnavailable: "无法读取风扇硬件上下限，已拒绝手动控制。"
        case .batteryUnsupported: "这台 Mac 没有可用的电池充电控制能力。"
        case .batteryCareNotEnabled: "请先启用 Battery Care，再临时充到 100%。"
        case .invalidBatteryRange: "Battery Care 区间必须在 50%–100%，并至少相差 5%。"
        }
    }
}

private final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let daemon = HardwareDaemon()

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard ClientCodeValidator.isTrusted(connection: connection) else { return false }
        connection.exportedInterface = NSXPCInterface(with: MeloHardwareXPCProtocol.self)
        connection.exportedObject = daemon
        daemon.clientConnected()
        connection.invalidationHandler = { [weak daemon] in daemon?.clientDisconnected() }
        connection.resume()
        return true
    }
}

private enum ClientCodeValidator {
    static func isTrusted(connection: NSXPCConnection) -> Bool {
        let attributes = [
            kSecGuestAttributePid as String: NSNumber(value: connection.processIdentifier)
        ] as CFDictionary
        var guestCode: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes, SecCSFlags(), &guestCode) == errSecSuccess,
              let guestCode,
              SecCodeCheckValidity(guestCode, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess,
              let guest = signingInformation(for: guestCode),
              let own = ownSigningInformation() else {
            return false
        }
        let expectedAdHocExecutableURL = own.executableURL?
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("MacOS/Melo")
        return HardwareClientTrustPolicy.isTrusted(
            clientIdentifier: guest.identifier,
            expectedIdentifier: "dev.melo.companion",
            clientTeamIdentifier: guest.teamID,
            helperTeamIdentifier: own.teamID,
            clientExecutablePath: guest.executableURL?.path,
            expectedAdHocExecutablePath: expectedAdHocExecutableURL?.path
        )
    }

    private static func ownSigningInformation() -> SigningInformation? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        return signingInformation(for: code)
    }

    private static func signingInformation(for code: SecCode) -> SigningInformation? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let dictionary = information as? [String: Any],
              let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String else {
            return nil
        }
        return SigningInformation(
            identifier: identifier,
            teamID: dictionary[kSecCodeInfoTeamIdentifier as String] as? String,
            executableURL: dictionary[kSecCodeInfoMainExecutable as String] as? URL
        )
    }

    private struct SigningInformation {
        let identifier: String
        let teamID: String?
        let executableURL: URL?
    }
}

private let delegate = HelperListenerDelegate()
private let listener = NSXPCListener(machServiceName: MeloHardwareProtocolInfo.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.current.run()
