import Darwin
import Foundation
import IOKit

// Minimal AppleSMC implementation adapted from leaperone/smctl (MIT), pinned in
// THIRD_PARTY_NOTICES.md. The main Melo process uses reads only; writes are called
// exclusively by the privileged MeloHardwareHelper target.

public enum SMCError: Error, Equatable, LocalizedError {
    case invalidKey(String)
    case serviceNotFound
    case openFailed(kern_return_t)
    case callFailed(kern_return_t)
    case badCommand
    case notFound
    case keySizeMismatch
    case notPrivileged
    case smcResult(UInt8)
    case malformedData(String)
    case writeVerificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidKey(let key): "Invalid SMC key: \(key)"
        case .serviceNotFound: "AppleSMC service was not found."
        case .openFailed(let code): "AppleSMC could not be opened (\(code))."
        case .callFailed(let code): "AppleSMC call failed (\(code))."
        case .badCommand: "AppleSMC rejected the command."
        case .notFound: "AppleSMC key was not found."
        case .keySizeMismatch: "AppleSMC key size did not match."
        case .notPrivileged: "AppleSMC write requires the privileged helper."
        case .smcResult(let result): "AppleSMC returned 0x\(String(result, radix: 16))."
        case .malformedData(let detail): "Malformed AppleSMC data: \(detail)"
        case .writeVerificationFailed(let key): "AppleSMC did not verify the write to \(key)."
        }
    }

    fileprivate static func fromSMCResult(_ result: UInt8) -> SMCError? {
        switch result {
        case 0: nil
        case 0x82: .badCommand
        case 0x84: .notFound
        case 0x87: .keySizeMismatch
        default: .smcResult(result)
        }
    }
}

public enum FourCharCode {
    public static func make(_ string: String) throws -> UInt32 {
        let bytes = Array(string.utf8)
        guard bytes.count == 4 else { throw SMCError.invalidKey(string) }
        return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
    }

    public static func string(_ value: UInt32) -> String {
        [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
            .map { (0x20...0x7e).contains($0) ? String(UnicodeScalar($0)) : " " }
            .joined()
    }

    public static func normalizedStrings(_ value: UInt32) -> Set<String> {
        [string(value), string(value.byteSwapped)]
    }
}

public enum SMCDecodedValue: Equatable, Codable, Sendable {
    case number(Double)
    case unsigned(UInt32)
    case bytes([UInt8])

    public var doubleValue: Double? {
        switch self {
        case .number(let value): value
        case .unsigned(let value): Double(value)
        case .bytes: nil
        }
    }
}

public enum SMCDataDecoder {
    public static func decode(key: String, bytes: [UInt8], dataType: UInt32) throws -> SMCDecodedValue {
        let types = FourCharCode.normalizedStrings(dataType)
        if types.contains("flt ") || types.contains("flt") {
            try require(bytes, 4, key)
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            return .number(Double(Float(bitPattern: bits)))
        }
        if types.contains("fpe2") {
            try require(bytes, 2, key)
            return .number(Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4)
        }
        if types.contains("sp78") {
            try require(bytes, 2, key)
            return .number(Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256)
        }
        if types.contains("ui8 ") || types.contains("ui8") {
            try require(bytes, 1, key)
            return .unsigned(UInt32(bytes[0]))
        }
        if types.contains("ui16") {
            try require(bytes, 2, key)
            #if arch(arm64)
            return .unsigned(UInt32(UInt16(bytes[1]) << 8 | UInt16(bytes[0])))
            #else
            return .unsigned(UInt32(UInt16(bytes[0]) << 8 | UInt16(bytes[1])))
            #endif
        }
        if types.contains("ui32") {
            try require(bytes, 4, key)
            #if arch(arm64)
            return .unsigned(UInt32(bytes[3]) << 24 | UInt32(bytes[2]) << 16 | UInt32(bytes[1]) << 8 | UInt32(bytes[0]))
            #else
            return .unsigned(UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3]))
            #endif
        }
        return .bytes(bytes)
    }

    private static func require(_ bytes: [UInt8], _ count: Int, _ key: String) throws {
        guard bytes.count >= count else { throw SMCError.malformedData("\(key) expected \(count) bytes") }
    }
}

public enum SMCDataEncoder {
    public static func encodeFanTarget(_ rpm: Double, info: SMCKeyInfo) throws -> [UInt8] {
        guard rpm.isFinite, rpm >= 0 else {
            throw SMCError.malformedData("Fan target must be a finite, non-negative RPM value")
        }
        let types = FourCharCode.normalizedStrings(info.dataType)
        if types.contains("flt ") || types.contains("flt") {
            guard info.dataSize == 4 else { throw SMCError.keySizeMismatch }
            let bits = Float(rpm).bitPattern
            return [
                UInt8(bits & 0xff),
                UInt8((bits >> 8) & 0xff),
                UInt8((bits >> 16) & 0xff),
                UInt8((bits >> 24) & 0xff)
            ]
        }
        if types.contains("fpe2") {
            guard info.dataSize == 2, rpm <= Double(UInt16.max) / 4 else {
                throw SMCError.keySizeMismatch
            }
            let encoded = UInt16((rpm * 4).rounded())
            return [UInt8((encoded >> 8) & 0xff), UInt8(encoded & 0xff)]
        }
        throw SMCError.malformedData("Unsupported fan target data type")
    }
}

public typealias SMCByteTuple20 = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)
public typealias SMCByteTuple32 = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

public struct SMCVersion {
    public var major: UInt8 = 0
    public var minor: UInt8 = 0
    public var build: UInt8 = 0
    public var reserved: UInt8 = 0
}

public struct SMCKeyInfo: Codable, Equatable, Sendable {
    public var dataSize: UInt32 = 0
    public var dataType: UInt32 = 0
    public var dataAttributes: UInt8 = 0

    public init(dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0) {
        self.dataSize = dataSize
        self.dataType = dataType
        self.dataAttributes = dataAttributes
    }
}

public struct SMCParamStruct {
    public var key: UInt32 = 0
    public var vers = SMCVersion()
    public var pLimitData: SMCByteTuple20 = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    public var keyInfo = SMCKeyInfo()
    public var padding: UInt16 = 0
    public var result: UInt8 = 0
    public var status: UInt8 = 0
    public var data8: UInt8 = 0
    public var data32: UInt32 = 0
    public var bytes: SMCByteTuple32 = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

    public func bytesArray(prefix count: Int) -> [UInt8] {
        Array(withUnsafeBytes(of: bytes) { Array($0) }.prefix(count))
    }

    public static func byteTuple32(_ input: [UInt8]) -> SMCByteTuple32 {
        var b = Array(input.prefix(32))
        b += Array(repeating: 0, count: max(0, 32 - b.count))
        return (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15], b[16], b[17], b[18], b[19], b[20], b[21], b[22], b[23], b[24], b[25], b[26], b[27], b[28], b[29], b[30], b[31])
    }
}

public struct SMCReadValue: Codable, Equatable, Sendable {
    public let key: String
    public let info: SMCKeyInfo
    public let bytes: [UInt8]
    public var decoded: SMCDecodedValue? { try? SMCDataDecoder.decode(key: key, bytes: bytes, dataType: info.dataType) }
}

public protocol SMCBackend: Sendable {
    func readKeyInfo(_ key: String) throws -> SMCKeyInfo
    func readValue(_ key: String) throws -> SMCReadValue
}

public protocol SMCWriteBackend: SMCBackend {
    func writeRawValue(_ key: String, bytes: [UInt8]) throws
}

public extension SMCWriteBackend {
    func writeKey(_ key: String, bytes: [UInt8]) throws {
        let info = try readKeyInfo(key)
        guard bytes.count == Int(info.dataSize) else { throw SMCError.keySizeMismatch }
        try writeRawValue(key, bytes: bytes)
        for _ in 0..<8 {
            let value = try readValue(key)
            if SMCWriteVerifier.matches(expected: bytes, actual: value.bytes, key: key, info: info) { return }
            Thread.sleep(forTimeInterval: 0.2)
        }
        throw SMCError.writeVerificationFailed(key)
    }
}

public enum SMCWriteVerifier {
    public static func matches(expected: [UInt8], actual: [UInt8], key: String, info: SMCKeyInfo) -> Bool {
        if actual.prefix(expected.count).elementsEqual(expected) { return true }
        guard let expectedNumber = try? SMCDataDecoder.decode(key: key, bytes: expected, dataType: info.dataType).doubleValue,
              let actualNumber = try? SMCDataDecoder.decode(key: key, bytes: actual, dataType: info.dataType).doubleValue,
              expectedNumber.isFinite,
              actualNumber.isFinite else { return false }
        // AppleSMC may quantize floating-point fan targets. One RPM is small
        // enough to detect a rejected write while accepting that normalization.
        return abs(expectedNumber - actualNumber) <= 1
    }
}

public final class SMCConnection: SMCWriteBackend, @unchecked Sendable {
    private var connection: io_connect_t = 0
    private let queue = DispatchQueue(label: "dev.melo.smc.connection")

    public init() throws {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { throw SMCError.serviceNotFound }
        defer { IOObjectRelease(service) }
        let result = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard result == KERN_SUCCESS else { throw SMCError.openFailed(result) }
    }

    deinit { if connection != 0 { _ = queue.sync { IOServiceClose(connection) } } }

    public func readKeyInfo(_ key: String) throws -> SMCKeyInfo {
        var input = SMCParamStruct()
        input.key = try FourCharCode.make(key)
        input.data8 = 9
        return try call(input).keyInfo
    }

    public func readValue(_ key: String) throws -> SMCReadValue {
        let info = try readKeyInfo(key)
        var input = SMCParamStruct()
        input.key = try FourCharCode.make(key)
        input.keyInfo = info
        input.data8 = 5
        return SMCReadValue(key: key, info: info, bytes: try call(input).bytesArray(prefix: Int(info.dataSize)))
    }

    public func writeRawValue(_ key: String, bytes: [UInt8]) throws {
        let info = try readKeyInfo(key)
        var input = SMCParamStruct()
        input.key = try FourCharCode.make(key)
        input.keyInfo = info
        input.data8 = 6
        input.bytes = SMCParamStruct.byteTuple32(bytes)
        _ = try call(input)
    }

    private func call(_ input: SMCParamStruct) throws -> SMCParamStruct {
        var mutableInput = input
        var output = SMCParamStruct()
        var outputSize = MemoryLayout<SMCParamStruct>.stride
        let result = queue.sync {
            withUnsafePointer(to: &mutableInput) { inputPointer in
                withUnsafeMutablePointer(to: &output) { outputPointer in
                    IOConnectCallStructMethod(connection, 2, inputPointer, MemoryLayout<SMCParamStruct>.stride, outputPointer, &outputSize)
                }
            }
        }
        guard result == KERN_SUCCESS else {
            if result == kIOReturnNotPrivileged { throw SMCError.notPrivileged }
            throw SMCError.callFailed(result)
        }
        if let error = SMCError.fromSMCResult(output.result) { throw error }
        return output
    }
}

public struct SMCKeyWrite: Codable, Equatable, Sendable { public let key: String; public let bytes: [UInt8] }
public struct SMCControlKeyGroup: Codable, Equatable, Sendable {
    public let identifier: String
    public let statusKey: String
    public let requiredKeys: [String]
    public let enableWrites: [SMCKeyWrite]
    public let disableWrites: [SMCKeyWrite]
}
public struct FanCapability: Codable, Equatable, Sendable {
    public let index: Int
    public let actualKey: String
    public let targetKey: String
    public let minimumKey: String
    public let maximumKey: String
    public let modeKey: String?
}
public struct Capabilities: Codable, Equatable, Sendable {
    public var fans: [FanCapability]
    public var ftstAvailable: Bool
    public var chargingControl: SMCControlKeyGroup?
    public init(fans: [FanCapability] = [], ftstAvailable: Bool = false, chargingControl: SMCControlKeyGroup? = nil) {
        self.fans = fans; self.ftstAvailable = ftstAvailable; self.chargingControl = chargingControl
    }
}

public struct KeyCatalog: Sendable {
    public init() {}
    public func detectCapabilities(using backend: any SMCBackend) -> Capabilities {
        let count = (try? backend.readValue("FNum").decoded?.doubleValue).flatMap { $0 }.map(Int.init) ?? probeFanCount(backend)
        let fans = (0..<max(0, count)).compactMap { index -> FanCapability? in
            let actual = "F\(index)Ac"
            guard probe(actual, backend) else { return nil }
            return FanCapability(
                index: index,
                actualKey: actual,
                targetKey: "F\(index)Tg",
                minimumKey: "F\(index)Mn",
                maximumKey: "F\(index)Mx",
                modeKey: ["F\(index)Md", "F\(index)md"].first { probe($0, backend) }
            )
        }
        let chargingCandidates = [
            SMCControlKeyGroup(identifier: "tahoe", statusKey: "CHTE", requiredKeys: ["CHTE"], enableWrites: [.init(key: "CHTE", bytes: [0, 0, 0, 0])], disableWrites: [.init(key: "CHTE", bytes: [1, 0, 0, 0])]),
            SMCControlKeyGroup(identifier: "legacy", statusKey: "CH0B", requiredKeys: ["CH0B", "CH0C"], enableWrites: [.init(key: "CH0B", bytes: [0]), .init(key: "CH0C", bytes: [0])], disableWrites: [.init(key: "CH0B", bytes: [2]), .init(key: "CH0C", bytes: [2])])
        ]
        return Capabilities(
            fans: fans,
            ftstAvailable: probe("Ftst", backend),
            chargingControl: chargingCandidates.first { $0.requiredKeys.allSatisfy { probe($0, backend) } }
        )
    }

    private func probeFanCount(_ backend: any SMCBackend) -> Int {
        (0..<8).reduce(0) { probe("F\($1)Ac", backend) ? $1 + 1 : $0 }
    }
    private func probe(_ key: String, _ backend: any SMCBackend) -> Bool { (try? backend.readKeyInfo(key)) != nil }
}

public enum FanMode: UInt8, Codable, Equatable, Sendable { case auto = 0, manual = 1, system = 3 }
public struct FanStatus: Codable, Equatable, Sendable {
    public let index: Int
    public let actualRPM: Double?
    public let targetRPM: Double?
    public let minimumRPM: Double?
    public let maximumRPM: Double?
    public let mode: FanMode?
}
public struct FtstGateManager: Codable, Equatable, Sendable {
    public private(set) var manualFanIndices = Set<Int>()
    public init() {}
    public var hasManualFans: Bool { !manualFanIndices.isEmpty }
    public mutating func enterManual(index: Int) { manualFanIndices.insert(index) }
    @discardableResult public mutating func leaveManual(index: Int) -> Bool { manualFanIndices.remove(index); return manualFanIndices.isEmpty }
    public func otherManualFansRemain(afterLeaving index: Int) -> Bool { manualFanIndices.contains { $0 != index } }
    public mutating func removeAll() { manualFanIndices.removeAll() }
}

public struct FanController: Sendable {
    private let backend: any SMCWriteBackend
    private let capabilities: Capabilities
    public init(backend: any SMCWriteBackend, capabilities: Capabilities) { self.backend = backend; self.capabilities = capabilities }

    public func status() -> [FanStatus] {
        capabilities.fans.map { fan in
            let raw = fan.modeKey.flatMap { numeric($0) }.map { UInt8(clamping: Int($0.rounded())) }
            return FanStatus(index: fan.index, actualRPM: numeric(fan.actualKey), targetRPM: numeric(fan.targetKey), minimumRPM: numeric(fan.minimumKey), maximumRPM: numeric(fan.maximumKey), mode: raw.flatMap(FanMode.init(rawValue:)))
        }
    }

    public func setManual(index: Int, rpm: Double) throws {
        guard let fan = capabilities.fans.first(where: { $0.index == index }), let modeKey = fan.modeKey else { throw SMCError.notFound }
        do {
            try backend.writeKey(modeKey, bytes: [FanMode.manual.rawValue])
        } catch {
            guard capabilities.ftstAvailable else { throw error }
            try backend.writeKey("Ftst", bytes: [1])
            Thread.sleep(forTimeInterval: 0.5)
            var lastError: Error = error
            for _ in 0..<95 {
                do { try backend.writeKey(modeKey, bytes: [FanMode.manual.rawValue]); lastError = SMCError.notFound; break }
                catch { lastError = error; Thread.sleep(forTimeInterval: 0.1) }
            }
            if (try? backend.readValue(modeKey).bytes.first) != FanMode.manual.rawValue { throw lastError }
        }
        let targetInfo = try backend.readKeyInfo(fan.targetKey)
        try backend.writeKey(
            fan.targetKey,
            bytes: SMCDataEncoder.encodeFanTarget(rpm, info: targetInfo)
        )
    }

    public func setAuto(index: Int, otherManualFansRemaining: Bool) throws {
        guard let fan = capabilities.fans.first(where: { $0.index == index }), let modeKey = fan.modeKey else { throw SMCError.notFound }
        try backend.writeKey(modeKey, bytes: [FanMode.auto.rawValue])
        if capabilities.ftstAvailable, !otherManualFansRemaining { try clearFtstIfSet() }
    }

    public func clearFtstIfSet() throws {
        guard capabilities.ftstAvailable else { return }
        if try backend.readValue("Ftst").bytes.first == 1 { try backend.writeKey("Ftst", bytes: [0]) }
    }

    private func numeric(_ key: String) -> Double? {
        guard let value = try? backend.readValue(key) else { return nil }
        return value.decoded?.doubleValue
    }
}
