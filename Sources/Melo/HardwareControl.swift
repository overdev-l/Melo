import Foundation
import IOKit.ps
import MeloHardwareProtocol
import Security
import ServiceManagement
import SMCCore

enum HardwareHelperState: String, Equatable, Sendable {
    case enabled
    case requiresApproval
    case notInstalled
    case developmentBuild
    case moveToApplications
    case invalidBuild

    var title: String {
        switch self {
        case .enabled: "安全 Helper 已启用"
        case .requiresApproval: "等待在系统设置中批准"
        case .notInstalled: "尚未安装硬件 Helper"
        case .developmentBuild: "开发签名仅支持只读监测"
        case .moveToApplications: "请先把 Melo 移到“应用程序”"
        case .invalidBuild: "Helper 签名或封装无效"
        }
    }
}

actor NativeHardwareProbe {
    private let backend: SMCConnection?
    private let capabilities: Capabilities

    init() {
        if let connection = try? SMCConnection() {
            backend = connection
            capabilities = KeyCatalog().detectCapabilities(using: connection)
        } else {
            backend = nil
            capabilities = Capabilities()
        }
    }

    func snapshot() -> HardwareControlSnapshot {
        let fans = capabilities.fans.map { fan in
            let rawMode = fan.modeKey.flatMap(readNumber).map { UInt8(clamping: Int($0.rounded())) }
            return HardwareFanState(
                index: fan.index,
                actualRPM: readNumber(fan.actualKey),
                targetRPM: readNumber(fan.targetKey),
                minimumRPM: readNumber(fan.minimumKey),
                maximumRPM: readNumber(fan.maximumKey),
                isManual: rawMode == FanMode.manual.rawValue
            )
        }
        return HardwareControlSnapshot(
            fans: fans,
            fanControlSupported: capabilities.fans.contains { $0.modeKey != nil },
            ftstAvailable: capabilities.ftstAvailable,
            batteryCare: BatteryCareState(
                batteryPresent: Self.batteryChargePercent() != nil,
                chargingControlSupported: capabilities.chargingControl != nil,
                currentPercent: Self.batteryChargePercent()
            ),
            helperVersion: 0
        )
    }

    private func readNumber(_ key: String) -> Double? {
        guard let value = try? backend?.readValue(key) else { return nil }
        return value.decoded?.doubleValue
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
                  maximum > 0 else { continue }
            return Int((Double(current) / Double(maximum) * 100).rounded())
        }
        return nil
    }
}

actor HardwareControlCoordinator {
    private let probe = NativeHardwareProbe()
    private var connection: NSXPCConnection?

    func snapshot(helperEnabled: Bool) async -> HardwareControlSnapshot {
        if helperEnabled, let response = try? await perform(.snapshot), let snapshot = response.snapshot {
            return snapshot
        }
        return await probe.snapshot()
    }

    func perform(_ command: HardwareControlCommand) async throws -> HardwareControlResponse {
        let request = HardwareControlRequest(command: command)
        let data = try JSONEncoder().encode(request)
        return try await withCheckedThrowingContinuation { continuation in
            let connection = persistentConnection()
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                Task { self.discardConnection(connection) }
                continuation.resume(throwing: error)
            }) as? MeloHardwareXPCProtocol else {
                discardConnection(connection)
                continuation.resume(throwing: MoleClientError.launchFailed("无法连接硬件 Helper。"))
                return
            }
            proxy.perform(data) { responseData, errorMessage in
                do {
                    if let errorMessage { throw MoleClientError.launchFailed(errorMessage) }
                    guard let responseData else { throw MoleClientError.invalidOutput("Helper 没有返回数据") }
                    continuation.resume(returning: try JSONDecoder().decode(HardwareControlResponse.self, from: responseData))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func disconnect() {
        let previousConnection = connection
        connection = nil
        previousConnection?.invalidationHandler = nil
        previousConnection?.invalidate()
    }

    /// Keep one authenticated XPC session alive while Melo is running. The helper
    /// deliberately restores automatic fan control when this session disappears,
    /// so per-request connections would make every manual target immediately revert.
    private func persistentConnection() -> NSXPCConnection {
        if let connection { return connection }
        let newConnection = NSXPCConnection(
            machServiceName: MeloHardwareProtocolInfo.machServiceName,
            options: .privileged
        )
        newConnection.remoteObjectInterface = NSXPCInterface(with: MeloHardwareXPCProtocol.self)
        newConnection.invalidationHandler = { [weak self, weak newConnection] in
            guard let self, let newConnection else { return }
            Task { await self.connectionDidInvalidate(newConnection) }
        }
        newConnection.resume()
        connection = newConnection
        return newConnection
    }

    private func discardConnection(_ failedConnection: NSXPCConnection) {
        guard connection === failedConnection else { return }
        connection = nil
        failedConnection.invalidate()
    }

    private func connectionDidInvalidate(_ invalidatedConnection: NSXPCConnection) {
        guard connection === invalidatedConnection else { return }
        connection = nil
    }
}

enum HardwareHelperEligibility {
    static func state() -> HardwareHelperState {
        let service = SMAppService.daemon(plistName: MeloHardwareProtocolInfo.launchDaemonPlistName)
        switch service.status {
        case .enabled: return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered, .notFound:
            break
        @unknown default:
            break
        }
        guard Bundle.main.bundleURL.path.hasPrefix("/Applications/") else { return .moveToApplications }
        guard let appSigning = signingInformation(at: Bundle.main.bundleURL),
              appSigning.teamIdentifier != nil else {
            return .developmentBuild
        }
        let helperURL = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Library/LaunchServices/MeloHardwareHelper")
        guard let helperSigning = signingInformation(at: helperURL),
              HardwareBundleTrustPolicy.canRegisterHelper(
                appIsValid: appSigning.isValid,
                appIdentifier: appSigning.identifier,
                appTeamIdentifier: appSigning.teamIdentifier,
                helperIsValid: helperSigning.isValid,
                helperIdentifier: helperSigning.identifier,
                helperTeamIdentifier: helperSigning.teamIdentifier
              ) else {
            return .invalidBuild
        }
        return .notInstalled
    }

    static func register() throws {
        guard state() == .notInstalled else {
            throw MoleClientError.launchFailed("当前构建不满足 Helper 注册条件。")
        }
        try SMAppService.daemon(plistName: MeloHardwareProtocolInfo.launchDaemonPlistName).register()
    }

    static func unregister() throws {
        let service = SMAppService.daemon(plistName: MeloHardwareProtocolInfo.launchDaemonPlistName)
        guard service.status == .enabled || service.status == .requiresApproval else { return }
        try service.unregister()
    }

    private static func signingInformation(at url: URL) -> SigningInformation? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &code) == errSecSuccess,
              let code else { return nil }
        let isValid = SecStaticCodeCheckValidity(
            code,
            SecCSFlags(rawValue: kSecCSStrictValidate),
            nil
        ) == errSecSuccess
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return nil }
        return SigningInformation(
            isValid: isValid,
            identifier: dictionary[kSecCodeInfoIdentifier as String] as? String,
            teamIdentifier: dictionary[kSecCodeInfoTeamIdentifier as String] as? String
        )
    }

    private struct SigningInformation {
        let isValid: Bool
        let identifier: String?
        let teamIdentifier: String?
    }
}
