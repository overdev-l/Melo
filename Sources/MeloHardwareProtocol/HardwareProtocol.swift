import Foundation

public enum HardwareControlCommand: Codable, Equatable, Sendable {
    case snapshot
    case heartbeat
    case setFanTarget(index: Int?, rpm: Double)
    case restoreFanAuto(index: Int?)
    case setBatteryCare(lower: Int, upper: Int)
    case chargeToFull
    case stopBatteryCare
}

public struct HardwareControlRequest: Codable, Equatable, Sendable {
    public let command: HardwareControlCommand
    public let requestID: UUID

    public init(command: HardwareControlCommand, requestID: UUID = UUID()) {
        self.command = command
        self.requestID = requestID
    }
}

public struct HardwareFanState: Codable, Equatable, Identifiable, Sendable {
    public let index: Int
    public let actualRPM: Double?
    public let targetRPM: Double?
    public let minimumRPM: Double?
    public let maximumRPM: Double?
    public let isManual: Bool

    public init(
        index: Int,
        actualRPM: Double?,
        targetRPM: Double?,
        minimumRPM: Double?,
        maximumRPM: Double?,
        isManual: Bool
    ) {
        self.index = index
        self.actualRPM = actualRPM
        self.targetRPM = targetRPM
        self.minimumRPM = minimumRPM
        self.maximumRPM = maximumRPM
        self.isManual = isManual
    }

    public var id: Int { index }
}

public struct BatteryCareState: Codable, Equatable, Sendable {
    public let batteryPresent: Bool
    public let chargingControlSupported: Bool
    public let configuredLowerLimit: Int?
    public let configuredUpperLimit: Int?
    public let isChargingAllowed: Bool?
    public let currentPercent: Int?
    public let chargeToFullActive: Bool

    public init(
        batteryPresent: Bool,
        chargingControlSupported: Bool,
        configuredLowerLimit: Int? = nil,
        configuredUpperLimit: Int? = nil,
        isChargingAllowed: Bool? = nil,
        currentPercent: Int? = nil,
        chargeToFullActive: Bool = false
    ) {
        self.batteryPresent = batteryPresent
        self.chargingControlSupported = chargingControlSupported
        self.configuredLowerLimit = configuredLowerLimit
        self.configuredUpperLimit = configuredUpperLimit
        self.isChargingAllowed = isChargingAllowed
        self.currentPercent = currentPercent
        self.chargeToFullActive = chargeToFullActive
    }
}

public struct HardwareControlSnapshot: Codable, Equatable, Sendable {
    public let fans: [HardwareFanState]
    public let fanControlSupported: Bool
    public let ftstAvailable: Bool
    public let batteryCare: BatteryCareState
    public let helperVersion: Int

    public init(
        fans: [HardwareFanState],
        fanControlSupported: Bool,
        ftstAvailable: Bool,
        batteryCare: BatteryCareState,
        helperVersion: Int
    ) {
        self.fans = fans
        self.fanControlSupported = fanControlSupported
        self.ftstAvailable = ftstAvailable
        self.batteryCare = batteryCare
        self.helperVersion = helperVersion
    }
}

public struct HardwareControlResponse: Codable, Equatable, Sendable {
    public let requestID: UUID
    public let snapshot: HardwareControlSnapshot?
    public let message: String?

    public init(requestID: UUID, snapshot: HardwareControlSnapshot?, message: String?) {
        self.requestID = requestID
        self.snapshot = snapshot
        self.message = message
    }
}

@objc public protocol MeloHardwareXPCProtocol {
    func perform(_ requestData: Data, withReply reply: @escaping (Data?, String?) -> Void)
}

public enum MeloHardwareProtocolInfo {
    public static let appBundleIdentifier = "dev.melo.companion"
    public static let helperBundleIdentifier = "dev.melo.companion.hardware"
    public static let machServiceName = "dev.melo.companion.hardware"
    public static let launchDaemonPlistName = "dev.melo.companion.hardware.plist"
    public static let helperVersion = 2
}

public enum HardwareBundleTrustPolicy {
    public static func canRegisterHelper(
        appIsValid: Bool,
        appIdentifier: String?,
        appTeamIdentifier: String?,
        helperIsValid: Bool,
        helperIdentifier: String?,
        helperTeamIdentifier: String?
    ) -> Bool {
        guard appIsValid,
              helperIsValid,
              appIdentifier == MeloHardwareProtocolInfo.appBundleIdentifier,
              helperIdentifier == MeloHardwareProtocolInfo.helperBundleIdentifier,
              let appTeamIdentifier,
              !appTeamIdentifier.isEmpty else {
            return false
        }
        return helperTeamIdentifier == appTeamIdentifier
    }
}

public enum HardwareSafetyPolicy {
    public static let fanHeartbeatTimeout: TimeInterval = 5

    public static func clampedRPM(_ requested: Double, minimum: Double, maximum: Double) -> Double? {
        guard requested.isFinite, minimum.isFinite, maximum.isFinite,
              minimum > 0, maximum >= minimum else { return nil }
        return min(max(requested, minimum), maximum)
    }

    public static func shouldRestoreManualFans(
        hasManualFans: Bool,
        activeConnections: Int,
        lastHeartbeat: Date,
        now: Date,
        thermalPressureIsUnsafe: Bool = false,
        timeout: TimeInterval = fanHeartbeatTimeout
    ) -> Bool {
        guard hasManualFans else { return false }
        if thermalPressureIsUnsafe { return true }
        guard timeout.isFinite, timeout > 0 else { return true }
        return activeConnections <= 0 || now.timeIntervalSince(lastHeartbeat) >= timeout
    }

    public static func isValidBatteryRange(lower: Int, upper: Int) -> Bool {
        (50...95).contains(lower) && (55...100).contains(upper) && upper - lower >= 5
    }

    public static func batteryChargeEvaluation(
        percent: Int,
        lower: Int,
        upper: Int,
        chargeToFull: Bool
    ) -> BatteryChargeEvaluation {
        if chargeToFull, percent < 100 {
            return BatteryChargeEvaluation(chargingAllowed: true, completedChargeToFull: false)
        }
        let completed = chargeToFull && percent >= 100
        if percent >= upper {
            return BatteryChargeEvaluation(chargingAllowed: false, completedChargeToFull: completed)
        }
        if percent <= lower {
            return BatteryChargeEvaluation(chargingAllowed: true, completedChargeToFull: completed)
        }
        return BatteryChargeEvaluation(chargingAllowed: nil, completedChargeToFull: completed)
    }
}

public enum HardwareClientTrustPolicy {
    public static func isTrusted(
        clientIdentifier: String?,
        expectedIdentifier: String,
        clientTeamIdentifier: String?,
        helperTeamIdentifier: String?,
        clientExecutablePath: String?,
        expectedAdHocExecutablePath: String?
    ) -> Bool {
        guard clientIdentifier == expectedIdentifier else { return false }
        if let helperTeamIdentifier, !helperTeamIdentifier.isEmpty {
            return clientTeamIdentifier == helperTeamIdentifier
        }
        guard clientTeamIdentifier == nil,
              let clientExecutablePath,
              let expectedAdHocExecutablePath else {
            return false
        }
        return URL(fileURLWithPath: clientExecutablePath).standardizedFileURL.path
            == URL(fileURLWithPath: expectedAdHocExecutablePath).standardizedFileURL.path
    }
}

public struct BatteryChargeEvaluation: Equatable, Sendable {
    public let chargingAllowed: Bool?
    public let completedChargeToFull: Bool

    public init(chargingAllowed: Bool?, completedChargeToFull: Bool) {
        self.chargingAllowed = chargingAllowed
        self.completedChargeToFull = completedChargeToFull
    }
}
