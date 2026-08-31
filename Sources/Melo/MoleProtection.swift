import AppKit
import Darwin
import Foundation
import SwiftUI

enum MoleProtectionScope: String, CaseIterable, Identifiable, Sendable {
    case clean
    case optimize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .clean: "清理保护项"
        case .optimize: "维护排除项"
        }
    }

    var fileName: String {
        switch self {
        case .clean: "whitelist"
        case .optimize: "whitelist_optimize"
        }
    }

    var explanation: String {
        switch self {
        case .clean:
            "这些路径或模式会交给 Mole，在扫描与清理时一律跳过。"
        case .optimize:
            "这些任务 ID 或路径会交给 Mole，在生成计划与维护时跳过。"
        }
    }

    var header: String {
        switch self {
        case .clean:
            "# Mole Whitelist - managed by Melo\n# Protected paths will not be deleted."
        case .optimize:
            "# Mole Optimization Whitelist - managed by Melo\n# Listed checks and paths will be skipped."
        }
    }
}

struct MoleProtectedItem: Identifiable, Equatable, Sendable {
    let pattern: String
    var id: String { pattern }
}

enum MoleProtectionError: LocalizedError, Equatable {
    case emptyPattern
    case invalidPattern
    case unsafeConfiguration

    var errorDescription: String? {
        switch self {
        case .emptyPattern: "保护项不能为空。"
        case .invalidPattern: "保护项不能以 # 开头，也不能包含换行或空字符。"
        case .unsafeConfiguration: "Mole 配置目录或白名单不是普通本地文件，已拒绝读写。"
        }
    }
}

actor MoleProtectionService {
    private let fileManager: FileManager
    private let homeDirectory: URL

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    func load(scope: MoleProtectionScope) throws -> [MoleProtectedItem] {
        let url = configurationURL(scope: scope)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        try validateExistingConfigurationDirectory()
        try validateRegularItem(url)
        let text = try String(contentsOf: url, encoding: .utf8)
        return Self.parse(text)
    }

    func add(_ rawPattern: String, scope: MoleProtectionScope) throws -> [MoleProtectedItem] {
        let pattern = try normalized(rawPattern)
        var patterns = try load(scope: scope).map(\.pattern)
        if !patterns.contains(pattern) { patterns.append(pattern) }
        return try save(patterns, scope: scope)
    }

    func remove(_ pattern: String, scope: MoleProtectionScope) throws -> [MoleProtectedItem] {
        let patterns = try load(scope: scope).map(\.pattern).filter { $0 != pattern }
        return try save(patterns, scope: scope)
    }

    func pattern(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        let homePath = homeDirectory.standardizedFileURL.path
        if path == homePath { return "$HOME" }
        if path.hasPrefix(homePath + "/") {
            return "$HOME" + String(path.dropFirst(homePath.count))
        }
        return path
    }

    static func parse(_ text: String) -> [MoleProtectedItem] {
        var seen = Set<String>()
        return text.components(separatedBy: .newlines).compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), seen.insert(line).inserted else {
                return nil
            }
            return MoleProtectedItem(pattern: line)
        }
    }

    private func normalized(_ rawPattern: String) throws -> String {
        var pattern = rawPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else { throw MoleProtectionError.emptyPattern }
        guard pattern.count <= 4_096,
              !pattern.hasPrefix("#"),
              !pattern.contains("\n"),
              !pattern.contains("\r"),
              !pattern.contains("\0") else {
            throw MoleProtectionError.invalidPattern
        }
        if pattern == "~" { pattern = "$HOME" }
        if pattern.hasPrefix("~/") {
            pattern = "$HOME/" + pattern.dropFirst(2)
        }
        let homePath = homeDirectory.standardizedFileURL.path
        if pattern == homePath { pattern = "$HOME" }
        if pattern.hasPrefix(homePath + "/") {
            pattern = "$HOME" + String(pattern.dropFirst(homePath.count))
        }
        return pattern
    }

    private func save(
        _ patterns: [String],
        scope: MoleProtectionScope
    ) throws -> [MoleProtectedItem] {
        let configurationDirectory = try secureConfigurationDirectory()
        var seen = Set<String>()
        let unique = patterns.filter { seen.insert($0).inserted }.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
        let body = unique.isEmpty ? "" : "\n\n" + unique.joined(separator: "\n")
        let data = Data((scope.header + body + "\n").utf8)
        let url = configurationURL(scope: scope)
        if fileManager.fileExists(atPath: url.path) { try validateRegularItem(url) }
        let temporaryURL = configurationDirectory.appendingPathComponent(".melo-\(UUID().uuidString).tmp")
        defer { try? fileManager.removeItem(at: temporaryURL) }
        try data.write(to: temporaryURL, options: .withoutOverwriting)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporaryURL.path)
        let result = temporaryURL.path.withCString { source in
            url.path.withCString { destination in Darwin.rename(source, destination) }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try validateRegularItem(url)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return unique.map(MoleProtectedItem.init(pattern:))
    }

    private func secureConfigurationDirectory() throws -> URL {
        let configDirectory = homeDirectory.appendingPathComponent(".config", isDirectory: true)
        let moleDirectory = configDirectory.appendingPathComponent("mole", isDirectory: true)
        try ensureDirectory(configDirectory, permissionsIfCreated: 0o700)
        try ensureDirectory(moleDirectory, permissionsIfCreated: 0o700)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: moleDirectory.path)
        return moleDirectory
    }

    private func validateExistingConfigurationDirectory() throws {
        let configDirectory = homeDirectory.appendingPathComponent(".config", isDirectory: true)
        let moleDirectory = configDirectory.appendingPathComponent("mole", isDirectory: true)
        for directory in [configDirectory, moleDirectory] {
            let attributes = try fileManager.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw MoleProtectionError.unsafeConfiguration
            }
        }
    }

    private func ensureDirectory(_ url: URL, permissionsIfCreated: Int) throws {
        if fileManager.fileExists(atPath: url.path) {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw MoleProtectionError.unsafeConfiguration
            }
            return
        }
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: permissionsIfCreated]
        )
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw MoleProtectionError.unsafeConfiguration
        }
    }

    private func validateRegularItem(_ url: URL) throws {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw MoleProtectionError.unsafeConfiguration
        }
    }

    private func configurationURL(scope: MoleProtectionScope) -> URL {
        homeDirectory
            .appendingPathComponent(".config/mole", isDirectory: true)
            .appendingPathComponent(scope.fileName)
    }
}

struct MoleProtectionEditor: View {
    @ObservedObject var model: AppModel
    let scope: MoleProtectionScope
    @State private var draft = ""
    @State private var removalCandidate: MoleProtectedItem?

    private var items: [MoleProtectedItem] {
        model.protectedItems(for: scope)
    }

    var body: some View {
        SectionSurface(scope.title) {
            Text(scope.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField(scope == .clean ? "$HOME/Library/Caches/…" : "任务 ID 或路径", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addDraft)
                Button("添加", action: addDraft)
                    .buttonStyle(.bordered)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("选择路径") { model.chooseProtectedPath(scope: scope) }
                    .buttonStyle(.bordered)
            }

            if model.isLoadingProtectionSettings {
                ProgressView().controlSize(.small)
            } else if items.isEmpty {
                Label("没有自定义保护项；Mole 内置安全规则仍然生效。", systemImage: "shield.checkered")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        if item.id != items.first?.id { Divider() }
                        HStack(spacing: 10) {
                            Image(systemName: "lock.shield.fill")
                                .foregroundStyle(MeloTheme.safeGreen)
                            Text(item.pattern)
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(2)
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                removalCandidate = item
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .help("移除保护")
                            .accessibilityLabel("移除保护 \(item.pattern)")
                        }
                        .padding(.vertical, 8)
                    }
                }
            }
        }
        .task { await model.loadProtectionSettingsIfNeeded() }
        .disabled(isBusy)
        .confirmationDialog(
            removalCandidate.map { "不再保护 \($0.pattern)？" } ?? "移除保护项？",
            isPresented: Binding(
                get: { removalCandidate != nil },
                set: { if !$0 { removalCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let removalCandidate {
                Button("移除保护", role: .destructive) {
                    Task { await model.removeProtectedItem(removalCandidate, scope: scope) }
                    self.removalCandidate = nil
                }
            }
            Button("取消", role: .cancel) { removalCandidate = nil }
        } message: {
            Text("之后的扫描与操作可能再次包含这个项目。此操作不会立即删除任何文件。")
        }
    }

    private func addDraft() {
        let value = draft
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        draft = ""
        Task { await model.addProtectedPattern(value, scope: scope) }
    }

    private var isBusy: Bool {
        switch scope {
        case .clean: model.isScanningCleanup || model.isCleaning
        case .optimize: model.isScanningMaintenance || model.isPerformingMaintenance
        }
    }
}
