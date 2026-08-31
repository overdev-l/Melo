import Foundation

struct CommandResult: Equatable {
    let standardOutput: String
    let standardError: String
    let exitCode: Int32
}

enum MoleClientError: LocalizedError {
    case notInstalled
    case launchFailed(String)
    case commandFailed(arguments: [String], code: Int32, message: String)
    case invalidOutput(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "未找到 Mole。请先运行 brew install mole。"
        case .launchFailed(let message):
            "无法启动 Mole：\(message)"
        case .commandFailed(_, _, let message):
            message.isEmpty ? "Mole 命令执行失败。" : message
        case .invalidOutput(let message):
            "Mole 返回了无法识别的数据：\(message)"
        }
    }
}

final class MoleClient: @unchecked Sendable {
    private let fileManager: FileManager
    private let explicitExecutableURL: URL?
    private let processRegistry = ProcessRegistry()

    init(executableURL: URL? = nil, fileManager: FileManager = .default) {
        explicitExecutableURL = executableURL
        self.fileManager = fileManager
    }

    func locateExecutable() -> URL? {
        if let explicitExecutableURL,
           fileManager.isExecutableFile(atPath: explicitExecutableURL.path) {
            return explicitExecutableURL
        }

        let candidates = [
            "/opt/homebrew/bin/mo",
            "/usr/local/bin/mo",
            "\(NSHomeDirectory())/.local/bin/mo"
        ]
        return candidates
            .map(URL.init(fileURLWithPath:))
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    func version() async throws -> String {
        let result = try await run(arguments: ["--version"])
        let line = result.standardOutput
            .components(separatedBy: .newlines)
            .first(where: { $0.localizedCaseInsensitiveContains("Mole version") })
        return line?
            .replacingOccurrences(of: "Mole version", with: "", options: .caseInsensitive)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            ?? "未知版本"
    }

    func status() async throws -> MoleStatus {
        let result = try await run(
            arguments: ["status", "--json"],
            pathPrefix: automationSafeToolDirectory()?.path
        )
        return try decode(MoleStatus.self, from: result.standardOutput)
    }

    func analyze(path: String, operationID: UUID? = nil) async throws -> DiskAnalysis {
        let result = try await run(
            arguments: ["analyze", "--json", path],
            operationID: operationID
        )
        return try decode(DiskAnalysis.self, from: result.standardOutput)
    }

    func history(limit: Int = 30) async throws -> MoleHistory {
        let boundedLimit = min(max(limit, 1), 200)
        let result = try await run(arguments: ["history", "--json", "--limit", String(boundedLimit)])
        return try decode(MoleHistory.self, from: result.standardOutput)
    }

    func installedApplications() async throws -> [MoleApplication] {
        let result = try await run(arguments: ["uninstall", "--list"])
        let output = result.standardOutput
        guard let start = output.firstIndex(of: "["), let end = output.lastIndex(of: "]") else {
            throw MoleClientError.invalidOutput("应用清单不是 JSON")
        }
        return try decode([MoleApplication].self, from: String(output[start...end]))
    }

    func previewUninstall(_ application: MoleApplication, operationID: UUID) async throws -> UninstallPreview {
        let result = try await run(
            arguments: ["uninstall", "--dry-run", application.uninstallName],
            operationID: operationID,
            standardInput: "y\n"
        )
        return UninstallPreview.parse(
            result.standardOutput + result.standardError,
            application: application
        )
    }

    func uninstall(_ application: MoleApplication) async throws -> UninstallResult {
        let result = try await run(
            arguments: ["uninstall", application.uninstallName],
            standardInput: "y\n",
            environmentOverrides: ["MOLE_DELETE_MODE": "trash"]
        )
        return UninstallResult.parse(
            result.standardOutput + result.standardError,
            applicationName: application.name
        )
    }

    func previewMaintenance(operationID: UUID) async throws -> MaintenancePreview {
        let result = try await run(
            arguments: ["optimize", "--dry-run"],
            operationID: operationID,
            acceptedExitCodes: [0, 1]
        )
        return MaintenancePreview.parse(result.standardOutput + result.standardError)
    }

    func performMaintenance(operationID: UUID? = nil) async throws -> MaintenanceResult {
        let result = try await run(
            arguments: ["optimize"],
            operationID: operationID,
            acceptedExitCodes: [0, 1],
            environmentOverrides: ["MOLE_DELETE_MODE": "trash"]
        )
        return MaintenanceResult.parse(result.standardOutput + result.standardError)
    }

    func previewCleanup(operationID: UUID) async throws -> CleanupPreview {
        let result = try await run(arguments: ["clean", "--dry-run"], operationID: operationID)
        return CleanupPreview.parse(result.standardOutput + result.standardError)
    }

    func cancel(operationID: UUID) {
        processRegistry.cancel(operationID)
    }

    func cleanUserLevelItems(operationID: UUID? = nil) async throws -> CleanupRunResult {
        let result = try await run(
            arguments: ["clean"],
            operationID: operationID,
            environmentOverrides: ["MOLE_DELETE_MODE": "trash"]
        )
        return CleanupRunResult.parse(result.standardOutput + result.standardError)
    }

    func run(
        arguments: [String],
        pathPrefix: String? = nil,
        operationID: UUID? = nil,
        acceptedExitCodes: Set<Int32> = [0],
        standardInput: String? = nil,
        environmentOverrides: [String: String] = [:]
    ) async throws -> CommandResult {
        guard let executableURL = locateExecutable() else {
            throw MoleClientError.notInstalled
        }

        let executionID = operationID ?? UUID()
        processRegistry.begin(executionID)
        defer { processRegistry.end(executionID) }

        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    let standardOutput = Pipe()
                    let standardError = Pipe()
                    let inputPipe = standardInput.map { _ in Pipe() }
                    process.executableURL = executableURL
                    process.arguments = arguments
                    process.standardOutput = standardOutput
                    process.standardError = standardError
                    process.standardInput = inputPipe ?? FileHandle.nullDevice

                    var environment = Foundation.ProcessInfo.processInfo.environment
                    let systemPath = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                    environment["PATH"] = pathPrefix.map { "\($0):\(systemPath)" } ?? systemPath
                    environment["TERM"] = "dumb"
                    environment["NO_COLOR"] = "1"
                    environment["CLICOLOR"] = "0"
                    environment["LANG"] = "en_US.UTF-8"
                    environment["LC_ALL"] = "en_US.UTF-8"
                    environment.removeValue(forKey: "MOLE_DELETE_MODE")
                    for (key, value) in environmentOverrides {
                        environment[key] = value
                    }
                    process.environment = environment

                    do {
                        try process.run()
                    } catch {
                        continuation.resume(throwing: MoleClientError.launchFailed(error.localizedDescription))
                        return
                    }

                    let registered = self.processRegistry.register(process, for: executionID)
                    if !registered {
                        self.processRegistry.stop(process)
                    }
                    if let standardInput, let inputPipe {
                        inputPipe.fileHandleForWriting.write(Data(standardInput.utf8))
                        try? inputPipe.fileHandleForWriting.close()
                    }

                    let group = DispatchGroup()
                    let outputBox = DataBox()
                    let errorBox = DataBox()

                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        outputBox.data = standardOutput.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }

                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        errorBox.data = standardError.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }

                    process.waitUntilExit()
                    group.wait()
                    self.processRegistry.unregister(process, for: executionID)

                    if self.processRegistry.isCancelled(executionID) {
                        continuation.resume(throwing: CancellationError())
                        return
                    }

                    let stdout = String(decoding: outputBox.data, as: UTF8.self)
                    let stderr = String(decoding: errorBox.data, as: UTF8.self)
                    let result = CommandResult(
                        standardOutput: stdout,
                        standardError: stderr,
                        exitCode: process.terminationStatus
                    )

                    guard acceptedExitCodes.contains(process.terminationStatus) else {
                        let message = stderr.isEmpty ? stdout : stderr
                        continuation.resume(throwing: MoleClientError.commandFailed(
                            arguments: arguments,
                            code: process.terminationStatus,
                            message: message.strippingANSISequences().trimmingCharacters(in: .whitespacesAndNewlines)
                        ))
                        return
                    }

                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            self.processRegistry.cancel(executionID)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        guard let data = string.data(using: .utf8) else {
            throw MoleClientError.invalidOutput("不是 UTF-8 文本")
        }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw MoleClientError.invalidOutput(error.localizedDescription)
        }
    }

    private func automationSafeToolDirectory() -> URL? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("bin", isDirectory: true),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Resources/bin", isDirectory: true)
        ].compactMap { $0 }

        return candidates.first {
            fileManager.isExecutableFile(atPath: $0.appendingPathComponent("osascript").path)
        }
    }
}

private final class DataBox: @unchecked Sendable {
    var data = Data()
}

private final class ProcessRegistry: @unchecked Sendable {
    private struct State {
        var activeRuns = 0
        var cancelled = false
        var processes: [ObjectIdentifier: Process] = [:]
    }

    private let lock = NSLock()
    private var states: [UUID: State] = [:]

    func begin(_ operationID: UUID) {
        lock.lock()
        var state = states[operationID] ?? State()
        state.activeRuns += 1
        states[operationID] = state
        lock.unlock()
    }

    func register(_ process: Process, for operationID: UUID) -> Bool {
        lock.lock()
        guard var state = states[operationID], !state.cancelled else {
            lock.unlock()
            return false
        }
        state.processes[ObjectIdentifier(process)] = process
        states[operationID] = state
        lock.unlock()
        return true
    }

    func unregister(_ process: Process, for operationID: UUID) {
        lock.lock()
        if var state = states[operationID] {
            state.processes.removeValue(forKey: ObjectIdentifier(process))
            states[operationID] = state
        }
        lock.unlock()
    }

    func end(_ operationID: UUID) {
        lock.lock()
        guard var state = states[operationID] else {
            lock.unlock()
            return
        }
        state.activeRuns = max(state.activeRuns - 1, 0)
        if state.activeRuns == 0 {
            states.removeValue(forKey: operationID)
        } else {
            states[operationID] = state
        }
        lock.unlock()
    }

    func cancel(_ operationID: UUID) {
        lock.lock()
        guard var state = states[operationID] else {
            lock.unlock()
            return
        }
        state.cancelled = true
        let processes = Array(state.processes.values)
        states[operationID] = state
        lock.unlock()
        for process in processes {
            stop(process)
        }
    }

    func isCancelled(_ operationID: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return states[operationID]?.cancelled == true
    }

    func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.interrupt()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.75) {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}
