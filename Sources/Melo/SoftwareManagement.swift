import AppKit
import CoreServices
import CryptoKit
import Foundation
import Security

enum SoftwareUpdateSource: String, Equatable, Sendable {
    case sparkle
    case electron
    case homebrewCask
    case homebrewFormula
    case appStore

    var title: String {
        switch self {
        case .sparkle: "应用内更新"
        case .electron: "Electron 更新"
        case .homebrewCask: "Homebrew App"
        case .homebrewFormula: "Homebrew 工具"
        case .appStore: "App Store"
        }
    }

    var systemImage: String {
        switch self {
        case .sparkle: "sparkles"
        case .electron: "bolt.horizontal.circle"
        case .homebrewCask, .homebrewFormula: "mug.fill"
        case .appStore: "apple.logo"
        }
    }
}

struct SoftwareUpdateCoverage: Equatable, Sendable {
    let applicationsScanned: Int
    let sparkleFeedsChecked: Int
    let electronFeedsChecked: Int
    let appStoreAppsChecked: Int
    let unsupportedElectronApps: [String]

    static let empty = SoftwareUpdateCoverage(
        applicationsScanned: 0,
        sparkleFeedsChecked: 0,
        electronFeedsChecked: 0,
        appStoreAppsChecked: 0,
        unsupportedElectronApps: []
    )
}

struct SoftwareUpdateCheckResult: Equatable, Sendable {
    let updates: [SoftwareUpdate]
    let coverage: SoftwareUpdateCoverage
}

struct NativeInstalledApplication: Identifiable, Equatable, Sendable {
    let name: String
    let bundleID: String
    let path: String
    let version: String
    let sparkleFeedURL: URL?
    let electronConfigurationURL: URL?
    let appStoreID: Int?

    var id: String { path }
    var isAppStoreApplication: Bool { appStoreID != nil }
}

actor NativeApplicationInventoryService {
    private let fileManager: FileManager
    private let homeDirectory: URL

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
    }

    func scan() -> [NativeInstalledApplication] {
        var roots = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            homeDirectory.appendingPathComponent("Applications", isDirectory: true)
        ]
        let volumeKeys: [URLResourceKey] = [.volumeIsInternalKey, .volumeIsLocalKey]
        let volumes = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: volumeKeys,
            options: [.skipHiddenVolumes]
        ) ?? []
        for volume in volumes {
            guard volume.path != "/",
                  let values = try? volume.resourceValues(forKeys: Set(volumeKeys)),
                  values.volumeIsInternal != true,
                  values.volumeIsLocal == true else {
                continue
            }
            roots.append(volume.appendingPathComponent("Applications", isDirectory: true))
        }

        var seenPaths = Set<String>()
        var applications: [NativeInstalledApplication] = []
        for root in roots where fileManager.fileExists(atPath: root.path) {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let url as URL in enumerator {
                guard url.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame else { continue }
                enumerator.skipDescendants()
                let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
                guard seenPaths.insert(canonicalPath).inserted,
                      let application = describe(url: URL(fileURLWithPath: canonicalPath)) else {
                    continue
                }
                applications.append(application)
            }
        }
        return applications.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private func describe(url: URL) -> NativeInstalledApplication? {
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let info = try? PropertyListSerialization.propertyList(
                from: data,
                options: [],
                format: nil
              ) as? [String: Any],
              let bundleID = info["CFBundleIdentifier"] as? String,
              !bundleID.hasPrefix("com.apple.installer") else {
            return nil
        }
        let name = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let version = (info["CFBundleShortVersionString"] as? String)
            ?? (info["CFBundleVersion"] as? String)
            ?? "未知"
        let sparkleFeed = (info["SUFeedURL"] as? String)
            .flatMap(URL.init(string:))
        let electronConfiguration = ["app-update.yml", "app-update.yaml"]
            .map { url.appendingPathComponent("Contents/Resources/\($0)") }
            .first { fileManager.fileExists(atPath: $0.path) }

        return NativeInstalledApplication(
            name: name,
            bundleID: bundleID,
            path: url.path,
            version: version,
            sparkleFeedURL: sparkleFeed,
            electronConfigurationURL: electronConfiguration,
            appStoreID: appStoreIdentifier(path: url.path)
        )
    }

    private func appStoreIdentifier(path: String) -> Int? {
        let receipt = URL(fileURLWithPath: path).appendingPathComponent("Contents/_MASReceipt/receipt")
        guard fileManager.fileExists(atPath: receipt.path),
              let item = MDItemCreate(kCFAllocatorDefault, path as CFString),
              let value = MDItemCopyAttribute(item, "kMDItemAppStoreAdamID" as CFString) else {
            return nil
        }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

struct SoftwareUpdate: Identifiable, Equatable, Sendable {
    let source: SoftwareUpdateSource
    let identifier: String
    let name: String
    let installedVersion: String
    let availableVersion: String
    let applicationPath: String?
    let releaseURL: URL?
    let verifiedPackage: VerifiedUpdatePackage?

    init(
        source: SoftwareUpdateSource,
        identifier: String,
        name: String,
        installedVersion: String,
        availableVersion: String,
        applicationPath: String?,
        releaseURL: URL?,
        verifiedPackage: VerifiedUpdatePackage? = nil
    ) {
        self.source = source
        self.identifier = identifier
        self.name = name
        self.installedVersion = installedVersion
        self.availableVersion = availableVersion
        self.applicationPath = applicationPath
        self.releaseURL = releaseURL
        self.verifiedPackage = verifiedPackage
    }

    var id: String { "\(source.rawValue):\(identifier)" }
    var canInstallDirectly: Bool {
        source == .homebrewCask || source == .homebrewFormula || verifiedPackage != nil
    }
}

struct VerifiedUpdatePackage: Equatable, Sendable {
    let downloadURL: URL
    let sha512: String
}

enum SoftwareUpdateSafetyPolicy {
    static let maximumArchiveBytes: Int64 = 4 * 1_024 * 1_024 * 1_024

    static func acceptsDownload(
        finalURL: URL?,
        statusCode: Int,
        expectedContentLength: Int64
    ) -> Bool {
        guard finalURL?.scheme?.lowercased() == "https",
              (200..<300).contains(statusCode) else {
            return false
        }
        return expectedContentLength < 0 || expectedContentLength <= maximumArchiveBytes
    }

    static func archiveEntriesAreSafe(_ listing: String) -> Bool {
        let entries = listing.split(whereSeparator: \.isNewline).map(String.init)
        guard !entries.isEmpty else { return false }
        return entries.allSatisfy { rawEntry in
            guard !rawEntry.contains("\0"), !rawEntry.contains("\u{FFFD}") else { return false }
            let entry = rawEntry.replacingOccurrences(of: "\\", with: "/")
            guard !entry.hasPrefix("/") else { return false }
            let components = entry.split(separator: "/", omittingEmptySubsequences: false)
            return !components.contains("..")
        }
    }

    static func candidateBundleIsContained(
        _ candidate: URL,
        in extractionRoot: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        guard candidate.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame,
              let attributes = try? fileManager.attributesOfItem(atPath: candidate.path),
              attributes[.type] as? FileAttributeType == .typeDirectory else {
            return false
        }
        let root = extractionRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let resolved = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        return resolved.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}

enum SoftwareUpdateInstallPhase: String, Equatable, Sendable {
    case preparing
    case downloading
    case verifyingPackage
    case extracting
    case verifyingApplication
    case waitingForApplication
    case installing
    case reopening
    case completed

    var title: String {
        switch self {
        case .preparing: "正在准备"
        case .downloading: "正在下载更新包"
        case .verifyingPackage: "正在核对 SHA-512"
        case .extracting: "正在安全解压"
        case .verifyingApplication: "正在验证应用身份与签名"
        case .waitingForApplication: "正在等待应用正常退出"
        case .installing: "正在安装并保留回滚副本"
        case .reopening: "正在重新打开应用"
        case .completed: "更新完成"
        }
    }
}

struct SoftwareUpdateProgress: Equatable, Sendable {
    let updateID: String
    let name: String
    let phase: SoftwareUpdateInstallPhase
    let itemIndex: Int
    let itemCount: Int

    var itemSummary: String? {
        itemCount > 1 ? "第 \(itemIndex) / \(itemCount) 项" : nil
    }
}

private struct HomebrewOutdatedResponse: Decodable {
    let formulae: [HomebrewOutdatedItem]
    let casks: [HomebrewOutdatedItem]
}

private struct HomebrewOutdatedItem: Decodable {
    let name: String
    let installedVersions: [String]
    let currentVersion: String

    enum CodingKeys: String, CodingKey {
        case name
        case installedVersions = "installed_versions"
        case currentVersion = "current_version"
    }
}

actor SoftwareUpdateService {
    private let fileManager: FileManager
    private let inventoryService: NativeApplicationInventoryService
    private let commandRunner = SoftwareCommandRunner()

    init(
        fileManager: FileManager = .default,
        inventoryService: NativeApplicationInventoryService? = nil
    ) {
        self.fileManager = fileManager
        self.inventoryService = inventoryService
            ?? NativeApplicationInventoryService(fileManager: fileManager)
    }

    func checkUpdates() async throws -> SoftwareUpdateCheckResult {
        try Task.checkCancellation()
        let applications = await inventoryService.scan()
        try Task.checkCancellation()
        async let homebrew: [SoftwareUpdate] = {
            (try? await self.homebrewUpdates()) ?? []
        }()
        async let sparkle = sparkleUpdates(applications: applications)
        async let electron = electronUpdates(applications: applications)
        async let appStore = appStoreUpdates(applications: applications)
        let (homebrewResult, sparkleResult, electronResult, appStoreResult) = await (
            homebrew,
            sparkle,
            electron,
            appStore
        )
        try Task.checkCancellation()
        let combined = homebrewResult
            + sparkleResult.updates
            + electronResult.updates
            + appStoreResult.updates
        let updates = deduplicated(combined).sorted { left, right in
            if left.source == right.source {
                return left.name.localizedStandardCompare(right.name) == .orderedAscending
            }
            return sourceOrder(left.source) < sourceOrder(right.source)
        }
        return SoftwareUpdateCheckResult(
            updates: updates,
            coverage: SoftwareUpdateCoverage(
                applicationsScanned: applications.count,
                sparkleFeedsChecked: sparkleResult.checkedCount,
                electronFeedsChecked: electronResult.checkedCount,
                appStoreAppsChecked: appStoreResult.checkedCount,
                unsupportedElectronApps: electronResult.unsupportedApplications
            )
        )
    }

    func install(
        _ update: SoftwareUpdate,
        progress: @escaping @Sendable (SoftwareUpdateInstallPhase) async -> Void = { _ in }
    ) async throws -> String {
        try Task.checkCancellation()
        await progress(.preparing)
        if let package = update.verifiedPackage {
            let message = try await installVerifiedApplicationPackage(
                update: update,
                package: package,
                progress: progress
            )
            await progress(.completed)
            return message
        }
        guard update.source == .homebrewCask || update.source == .homebrewFormula,
              let brew = locateBrew() else {
            throw MoleClientError.launchFailed("此更新需要在对应应用或 App Store 中完成。")
        }
        let arguments = update.source == .homebrewCask
            ? ["upgrade", "--cask", update.identifier]
            : ["upgrade", update.identifier]
        await progress(.installing)
        let result = try await commandRunner.run(executable: brew, arguments: arguments)
        try Task.checkCancellation()
        await progress(.completed)
        return (result.standardOutput + result.standardError)
            .strippingANSISequences()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func installVerifiedApplicationPackage(
        update: SoftwareUpdate,
        package: VerifiedUpdatePackage,
        progress: @escaping @Sendable (SoftwareUpdateInstallPhase) async -> Void
    ) async throws -> String {
        guard package.downloadURL.scheme?.lowercased() == "https",
              let installedPath = update.applicationPath else {
            throw MoleClientError.launchFailed("更新包来源不安全或缺少已安装应用路径。")
        }
        let installedURL = URL(fileURLWithPath: installedPath)
        guard let installedBundle = Bundle(url: installedURL),
              let installedBundleID = installedBundle.bundleIdentifier,
              installedBundleID == update.identifier,
              let installedTeamID = Self.signingTeamIdentifier(url: installedURL) else {
            throw MoleClientError.launchFailed("无法验证现有应用的签名身份，未下载更新。")
        }

        var request = URLRequest(url: package.downloadURL)
        request.timeoutInterval = 120
        request.cachePolicy = .reloadIgnoringLocalCacheData
        await progress(.downloading)
        let (downloadedURL, response) = try await URLSession.shared.download(for: request)
        try Task.checkCancellation()
        guard let httpResponse = response as? HTTPURLResponse,
              SoftwareUpdateSafetyPolicy.acceptsDownload(
                finalURL: httpResponse.url,
                statusCode: httpResponse.statusCode,
                expectedContentLength: httpResponse.expectedContentLength
              ) else {
            throw MoleClientError.launchFailed("更新包下载失败，服务器没有返回可用文件。")
        }

        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("melo-update-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: workspace) }
        let archiveURL = workspace.appendingPathComponent("update.zip")
        try fileManager.moveItem(at: downloadedURL, to: archiveURL)
        let archiveSize = try archiveURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard Int64(archiveSize) <= SoftwareUpdateSafetyPolicy.maximumArchiveBytes else {
            throw MoleClientError.launchFailed("更新包超过 4 GB 安全上限，文件已丢弃。")
        }

        await progress(.verifyingPackage)
        let actualHash = try sha512Base64(url: archiveURL)
        guard actualHash == package.sha512.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw MoleClientError.launchFailed("更新包校验值不匹配，文件已丢弃。")
        }

        let archiveListing = try await commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/zipinfo"),
            arguments: ["-1", archiveURL.path]
        )
        guard SoftwareUpdateSafetyPolicy.archiveEntriesAreSafe(archiveListing.standardOutput) else {
            throw MoleClientError.launchFailed("更新包包含不安全的解压路径，文件已丢弃。")
        }

        let extractedDirectory = workspace.appendingPathComponent("extracted", isDirectory: true)
        try fileManager.createDirectory(at: extractedDirectory, withIntermediateDirectories: true)
        await progress(.extracting)
        _ = try await commandRunner.run(
            executable: URL(fileURLWithPath: "/usr/bin/ditto"),
            arguments: ["-x", "-k", archiveURL.path, extractedDirectory.path]
        )
        try Task.checkCancellation()
        await progress(.verifyingApplication)
        guard let candidateURL = applicationBundle(
            in: extractedDirectory,
            matchingBundleID: installedBundleID
        ),
              SoftwareUpdateSafetyPolicy.candidateBundleIsContained(
                candidateURL,
                in: extractedDirectory,
                fileManager: fileManager
              ),
              let candidateBundle = Bundle(url: candidateURL),
              candidateBundle.bundleIdentifier == installedBundleID,
              Self.signingTeamIdentifier(url: candidateURL) == installedTeamID else {
            throw MoleClientError.launchFailed("更新包的应用身份或签名团队与现有安装不一致。")
        }
        let candidateVersion = (candidateBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
            ?? (candidateBundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? ""
        guard Self.version(candidateVersion, isNewerThan: update.installedVersion),
              !Self.version(update.availableVersion, isNewerThan: candidateVersion) else {
            throw MoleClientError.launchFailed("下载包版本与更新目录不一致，未替换现有应用。")
        }

        try Task.checkCancellation()
        await progress(.waitingForApplication)
        try await stopApplication(bundleID: installedBundleID)
        try Task.checkCancellation()
        let parentDirectory = installedURL.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: parentDirectory.path) else {
            throw MoleClientError.launchFailed("应用所在文件夹需要管理员权限；请使用应用自己的更新器。")
        }

        let backupName = ".\(installedURL.lastPathComponent).melo-backup-\(UUID().uuidString)"
        let backupURL = parentDirectory.appendingPathComponent(backupName)
        await progress(.installing)
        do {
            _ = try fileManager.replaceItemAt(
                installedURL,
                withItemAt: candidateURL,
                backupItemName: backupName,
                options: []
            )
            guard Bundle(url: installedURL)?.bundleIdentifier == installedBundleID,
                  Self.signingTeamIdentifier(url: installedURL) == installedTeamID else {
                throw MoleClientError.launchFailed("替换后的签名复核失败，正在恢复旧版本。")
            }
            try? fileManager.removeItem(at: backupURL)
        } catch {
            if fileManager.fileExists(atPath: backupURL.path) {
                try? fileManager.removeItem(at: installedURL)
                try? fileManager.moveItem(at: backupURL, to: installedURL)
            }
            throw error
        }

        await progress(.reopening)
        await MainActor.run {
            NSWorkspace.shared.openApplication(
                at: installedURL,
                configuration: NSWorkspace.OpenConfiguration()
            )
        }
        return "已验证 SHA-512、Bundle ID 与签名团队，并更新到 \(candidateVersion)。"
    }

    private func sha512Base64(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA512()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hasher.update(data: data)
        }
        return Data(hasher.finalize()).base64EncodedString()
    }

    private func applicationBundle(in directory: URL, matchingBundleID: String) -> URL? {
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return nil }
        for case let url as URL in enumerator {
            guard url.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame else { continue }
            enumerator.skipDescendants()
            if Bundle(url: url)?.bundleIdentifier == matchingBundleID { return url }
        }
        return nil
    }

    private func stopApplication(bundleID: String) async throws {
        let didRequestTermination = await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .allSatisfy { $0.terminate() }
        }
        guard didRequestTermination else {
            throw MoleClientError.launchFailed("应用拒绝退出；更新未开始，请保存工作后重试。")
        }
        for _ in 0..<40 {
            let isRunning = await MainActor.run {
                !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
            }
            if !isRunning { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw MoleClientError.launchFailed("应用仍在运行；Melo 不会强制结束它。")
    }

    private static func signingTeamIdentifier(url: URL) -> String? {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, SecCSFlags(), &staticCode) == errSecSuccess,
              let staticCode,
              SecStaticCodeCheckValidity(
                staticCode,
                SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures),
                nil
              ) == errSecSuccess else {
            return nil
        }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        ) == errSecSuccess,
              let dictionary = information as? [String: Any] else {
            return nil
        }
        return dictionary[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private func homebrewUpdates() async throws -> [SoftwareUpdate] {
        guard let brew = locateBrew() else { return [] }
        let result = try await commandRunner.run(executable: brew, arguments: ["outdated", "--json=v2"])
        guard let data = result.standardOutput.data(using: .utf8) else { return [] }
        let response = try JSONDecoder().decode(HomebrewOutdatedResponse.self, from: data)
        let casks = response.casks.map {
            SoftwareUpdate(
                source: .homebrewCask,
                identifier: $0.name,
                name: displayName(for: $0.name),
                installedVersion: $0.installedVersions.last ?? "未知",
                availableVersion: $0.currentVersion,
                applicationPath: nil,
                releaseURL: URL(string: "https://formulae.brew.sh/cask/\($0.name)")
            )
        }
        let formulae = response.formulae.map {
            SoftwareUpdate(
                source: .homebrewFormula,
                identifier: $0.name,
                name: $0.name,
                installedVersion: $0.installedVersions.last ?? "未知",
                availableVersion: $0.currentVersion,
                applicationPath: nil,
                releaseURL: URL(string: "https://formulae.brew.sh/formula/\($0.name)")
            )
        }
        return casks + formulae
    }

    private func sparkleUpdates(applications: [NativeInstalledApplication]) async -> FeedCheckResult {
        let candidates = applications.compactMap { application -> SparkleCandidate? in
            guard !application.isAppStoreApplication,
                  let feedURL = application.sparkleFeedURL,
                  ["https", "http"].contains(feedURL.scheme?.lowercased() ?? ""),
                  application.electronConfigurationURL == nil else {
                return nil
            }
            return SparkleCandidate(
                application: application,
                feedURL: feedURL,
                currentVersion: application.version
            )
        }

        let updates = await withTaskGroup(of: SoftwareUpdate?.self) { group in
            for candidate in candidates {
                group.addTask { await Self.checkSparkle(candidate) }
            }
            var updates: [SoftwareUpdate] = []
            for await update in group {
                if let update { updates.append(update) }
            }
            return updates
        }
        return FeedCheckResult(updates: updates, checkedCount: candidates.count)
    }

    private static func checkSparkle(_ candidate: SparkleCandidate) async -> SoftwareUpdate? {
        var request = URLRequest(url: candidate.feedURL)
        request.timeoutInterval = 8
        request.cachePolicy = .reloadRevalidatingCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode ?? 500 < 400 else {
            return nil
        }
        let parser = SparkleFeedParser()
        guard let release = parser.parse(data: data),
              release.version.compare(candidate.currentVersion, options: .numeric) == .orderedDescending else {
            return nil
        }
        return SoftwareUpdate(
            source: .sparkle,
            identifier: candidate.application.bundleID,
            name: candidate.application.name,
            installedVersion: candidate.currentVersion,
            availableVersion: release.version,
            applicationPath: candidate.application.path,
            releaseURL: release.infoURL ?? candidate.feedURL
        )
    }

    private func electronUpdates(applications: [NativeInstalledApplication]) async -> ElectronCheckResult {
        var candidates: [ElectronCandidate] = []
        var unsupported: [String] = []

        for application in applications {
            guard !application.isAppStoreApplication,
                  let configurationURL = application.electronConfigurationURL,
                  let data = try? Data(contentsOf: configurationURL),
                  let configuration = ElectronUpdateConfiguration.parse(data: data) else {
                continue
            }
            switch configuration.provider {
            case "generic" where configuration.url != nil:
                candidates.append(ElectronCandidate(application: application, configuration: configuration))
            case "github" where configuration.owner != nil && configuration.repo != nil:
                candidates.append(ElectronCandidate(application: application, configuration: configuration))
            default:
                unsupported.append(application.name)
            }
        }

        let updates = await withTaskGroup(of: SoftwareUpdate?.self) { group in
            for candidate in candidates {
                group.addTask { await Self.checkElectron(candidate) }
            }
            var updates: [SoftwareUpdate] = []
            for await update in group {
                if let update { updates.append(update) }
            }
            return updates
        }
        return ElectronCheckResult(
            updates: updates,
            checkedCount: candidates.count,
            unsupportedApplications: unsupported.sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
        )
    }

    private static func checkElectron(_ candidate: ElectronCandidate) async -> SoftwareUpdate? {
        switch candidate.configuration.provider {
        case "generic":
            return await checkElectronGeneric(candidate)
        case "github":
            return await checkElectronGitHub(candidate)
        default:
            return nil
        }
    }

    private static func checkElectronGeneric(_ candidate: ElectronCandidate) async -> SoftwareUpdate? {
        guard let baseURL = candidate.configuration.url else { return nil }
        let channel = candidate.configuration.channel?.isEmpty == false
            ? candidate.configuration.channel!
            : "latest"
        var feedURLs: [URL] = []
        if ["yml", "yaml"].contains(baseURL.pathExtension.lowercased()) {
            feedURLs.append(baseURL)
        } else {
            feedURLs.append(baseURL.appendingPathComponent("\(channel)-mac.yml"))
            if channel != "latest" {
                feedURLs.append(baseURL.appendingPathComponent("latest-mac.yml"))
            }
        }

        for feedURL in feedURLs {
            var request = URLRequest(url: feedURL)
            request.timeoutInterval = 8
            request.cachePolicy = .reloadRevalidatingCacheData
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode ?? 500 < 400,
                  let release = ElectronLatestYAMLParser.parse(data: data),
                  version(release.version, isNewerThan: candidate.application.version) else {
                continue
            }
            let verifiedPackage: VerifiedUpdatePackage?
            if let path = release.path,
               path.lowercased().hasSuffix(".zip"),
               let sha512 = release.sha512,
               !sha512.isEmpty,
               baseURL.scheme?.lowercased() == "https",
               signingTeamIdentifier(url: URL(fileURLWithPath: candidate.application.path)) != nil {
                verifiedPackage = VerifiedUpdatePackage(
                    downloadURL: baseURL.appendingPathComponent(path),
                    sha512: sha512
                )
            } else {
                verifiedPackage = nil
            }
            return SoftwareUpdate(
                source: .electron,
                identifier: candidate.application.bundleID,
                name: candidate.application.name,
                installedVersion: candidate.application.version,
                availableVersion: release.version,
                applicationPath: candidate.application.path,
                releaseURL: baseURL,
                verifiedPackage: verifiedPackage
            )
        }
        return nil
    }

    private static func checkElectronGitHub(_ candidate: ElectronCandidate) async -> SoftwareUpdate? {
        guard let owner = candidate.configuration.owner,
              let repo = candidate.configuration.repo,
              let url = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases/latest") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("Melo/0.2", forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode ?? 500 < 400,
              let release = try? JSONDecoder().decode(GitHubReleaseResponse.self, from: data),
              !release.draft,
              !release.prerelease,
              version(release.tagName, isNewerThan: candidate.application.version) else {
            return nil
        }
        return SoftwareUpdate(
            source: .electron,
            identifier: candidate.application.bundleID,
            name: candidate.application.name,
            installedVersion: candidate.application.version,
            availableVersion: normalizedVersion(release.tagName),
            applicationPath: candidate.application.path,
            releaseURL: release.htmlURL
        )
    }

    private func appStoreUpdates(applications: [NativeInstalledApplication]) async -> AppStoreCheckResult {
        let candidates = applications.filter(\.isAppStoreApplication)
        guard !candidates.isEmpty else {
            return AppStoreCheckResult(updates: [], checkedCount: 0)
        }
        let byStoreID = Dictionary(uniqueKeysWithValues: candidates.compactMap { application in
            application.appStoreID.map { ($0, application) }
        })
        let identifiers = byStoreID.keys.sorted()
        let country = Locale.current.region?.identifier.lowercased() ?? "us"
        var updates: [SoftwareUpdate] = []

        for batchStart in stride(from: 0, to: identifiers.count, by: 40) {
            let batch = identifiers[batchStart..<min(batchStart + 40, identifiers.count)]
            var components = URLComponents()
            components.scheme = "https"
            components.host = "itunes.apple.com"
            components.path = "/lookup"
            components.queryItems = [
                URLQueryItem(name: "id", value: batch.map(String.init).joined(separator: ",")),
                URLQueryItem(name: "entity", value: "macSoftware"),
                URLQueryItem(name: "country", value: country)
            ]
            guard let url = components.url else { continue }
            var request = URLRequest(url: url)
            request.timeoutInterval = 10
            request.cachePolicy = .reloadRevalidatingCacheData
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode ?? 500 < 400,
                  let lookup = try? JSONDecoder().decode(AppStoreLookupResponse.self, from: data) else {
                continue
            }

            for result in lookup.results {
                guard result.kind == "mac-software",
                      let application = byStoreID[result.trackID],
                      result.bundleID == application.bundleID,
                      Self.version(result.version, isNewerThan: application.version),
                      Self.supportsCurrentMac(minimumVersion: result.minimumOSVersion) else {
                    continue
                }
                updates.append(SoftwareUpdate(
                    source: .appStore,
                    identifier: String(result.trackID),
                    name: result.trackName,
                    installedVersion: application.version,
                    availableVersion: result.version,
                    applicationPath: application.path,
                    releaseURL: result.trackViewURL
                ))
            }
        }
        return AppStoreCheckResult(updates: updates, checkedCount: candidates.count)
    }

    private static func supportsCurrentMac(minimumVersion: String?) -> Bool {
        guard let minimumVersion, !minimumVersion.isEmpty else { return true }
        let current = Foundation.ProcessInfo.processInfo.operatingSystemVersion
        let currentString = "\(current.majorVersion).\(current.minorVersion).\(current.patchVersion)"
        return currentString.compare(minimumVersion, options: .numeric) != .orderedAscending
    }

    private static func version(_ candidate: String, isNewerThan installed: String) -> Bool {
        normalizedVersion(candidate).compare(
            normalizedVersion(installed),
            options: .numeric
        ) == .orderedDescending
    }

    private static func normalizedVersion(_ version: String) -> String {
        var normalized = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalized.lowercased().hasPrefix("version ") {
            normalized.removeFirst("version ".count)
        }
        if normalized.lowercased().hasPrefix("v"),
           normalized.dropFirst().first?.isNumber == true {
            normalized.removeFirst()
        }
        return normalized
    }

    private func locateBrew() -> URL? {
        ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]
            .map(URL.init(fileURLWithPath:))
            .first { fileManager.isExecutableFile(atPath: $0.path) }
    }

    private func deduplicated(_ updates: [SoftwareUpdate]) -> [SoftwareUpdate] {
        var seen = Set<String>()
        return updates.filter { seen.insert($0.id).inserted }
    }

    private func sourceOrder(_ source: SoftwareUpdateSource) -> Int {
        switch source {
        case .sparkle: 0
        case .electron: 1
        case .homebrewCask: 2
        case .appStore: 3
        case .homebrewFormula: 4
        }
    }

    private func displayName(for token: String) -> String {
        token.split(separator: "-")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }
}

struct SoftwareCommandRunner: Sendable {
    func run(executable: URL, arguments: [String]) async throws -> CommandResult {
        let processBox = SoftwareProcessBox()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let process = Process()
                    let output = Pipe()
                    let error = Pipe()
                    process.executableURL = executable
                    process.arguments = arguments
                    process.standardOutput = output
                    process.standardError = error
                    process.standardInput = FileHandle.nullDevice
                    var environment = Foundation.ProcessInfo.processInfo.environment
                    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                    environment["TERM"] = "dumb"
                    environment["NO_COLOR"] = "1"
                    environment["HOMEBREW_NO_AUTO_UPDATE"] = "1"
                    environment["LANG"] = "en_US.UTF-8"
                    process.environment = environment
                    do {
                        try process.run()
                        processBox.set(process)
                    } catch {
                        continuation.resume(throwing: MoleClientError.launchFailed(error.localizedDescription))
                        return
                    }
                    let group = DispatchGroup()
                    let outputBox = SoftwareDataBox()
                    let errorBox = SoftwareDataBox()
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        outputBox.data = output.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    group.enter()
                    DispatchQueue.global(qos: .utility).async {
                        errorBox.data = error.fileHandleForReading.readDataToEndOfFile()
                        group.leave()
                    }
                    process.waitUntilExit()
                    group.wait()
                    if processBox.isCancelled {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let result = CommandResult(
                        standardOutput: String(decoding: outputBox.data, as: UTF8.self),
                        standardError: String(decoding: errorBox.data, as: UTF8.self),
                        exitCode: process.terminationStatus
                    )
                    guard process.terminationStatus == 0 else {
                        continuation.resume(throwing: MoleClientError.commandFailed(
                            arguments: arguments,
                            code: process.terminationStatus,
                            message: result.standardError.isEmpty ? result.standardOutput : result.standardError
                        ))
                        return
                    }
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            processBox.cancel()
        }
    }
}

private struct FeedCheckResult: Sendable {
    let updates: [SoftwareUpdate]
    let checkedCount: Int
}

private struct ElectronCheckResult: Sendable {
    let updates: [SoftwareUpdate]
    let checkedCount: Int
    let unsupportedApplications: [String]
}

private struct AppStoreCheckResult: Sendable {
    let updates: [SoftwareUpdate]
    let checkedCount: Int
}

private struct SparkleCandidate: Sendable {
    let application: NativeInstalledApplication
    let feedURL: URL
    let currentVersion: String
}

private struct ElectronCandidate: Sendable {
    let application: NativeInstalledApplication
    let configuration: ElectronUpdateConfiguration
}

struct ElectronUpdateConfiguration: Equatable, Sendable {
    let provider: String
    let url: URL?
    let channel: String?
    let owner: String?
    let repo: String?

    static func parse(data: Data) -> ElectronUpdateConfiguration? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var values: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#"), let separator = line.firstIndex(of: ":") else {
                continue
            }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if (value.hasPrefix("'") && value.hasSuffix("'"))
                || (value.hasPrefix("\"") && value.hasSuffix("\"")) {
                value.removeFirst()
                value.removeLast()
            }
            values[key] = value
        }
        guard let provider = values["provider"]?.lowercased(), !provider.isEmpty else { return nil }
        return ElectronUpdateConfiguration(
            provider: provider,
            url: values["url"].flatMap(URL.init(string:)),
            channel: values["channel"],
            owner: values["owner"],
            repo: values["repo"]
        )
    }
}

struct ElectronLatestRelease: Equatable, Sendable {
    let version: String
    let releaseDate: String?
    let path: String?
    let sha512: String?
}

enum ElectronLatestYAMLParser {
    static func parse(data: Data) -> ElectronLatestRelease? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var version: String?
        var releaseDate: String?
        var path: String?
        var sha512: String?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("version:") {
                version = cleanValue(String(line.dropFirst("version:".count)))
            } else if line.hasPrefix("releaseDate:") {
                releaseDate = cleanValue(String(line.dropFirst("releaseDate:".count)))
            } else if line.hasPrefix("path:") {
                path = cleanValue(String(line.dropFirst("path:".count)))
            } else if line.hasPrefix("sha512:"), sha512 == nil {
                sha512 = cleanValue(String(line.dropFirst("sha512:".count)))
            }
        }
        guard let version, !version.isEmpty else { return nil }
        return ElectronLatestRelease(
            version: version,
            releaseDate: releaseDate,
            path: path,
            sha512: sha512
        )
    }

    private static func cleanValue(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if (value.hasPrefix("'") && value.hasSuffix("'"))
            || (value.hasPrefix("\"") && value.hasSuffix("\"")) {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }
}

private struct GitHubReleaseResponse: Decodable {
    let tagName: String
    let htmlURL: URL?
    let draft: Bool
    let prerelease: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case draft
        case prerelease
    }
}

private struct AppStoreLookupResponse: Decodable {
    let results: [AppStoreLookupResult]
}

private struct AppStoreLookupResult: Decodable {
    let trackID: Int
    let trackName: String
    let bundleID: String
    let version: String
    let trackViewURL: URL?
    let minimumOSVersion: String?
    let kind: String?

    enum CodingKeys: String, CodingKey {
        case trackID = "trackId"
        case trackName
        case bundleID = "bundleId"
        case version
        case trackViewURL = "trackViewUrl"
        case minimumOSVersion = "minimumOsVersion"
        case kind
    }
}

struct SparkleRelease {
    let version: String
    let infoURL: URL?
}

final class SparkleFeedParser: NSObject, XMLParserDelegate {
    private var release: SparkleRelease?
    private var currentInfoURLText = ""
    private var pendingVersion: String?
    private var insideItem = false
    private var insideInfoURL = false

    func parse(data: Data) -> SparkleRelease? {
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
        return release
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        if elementName == "item" {
            insideItem = release == nil
            pendingVersion = nil
            currentInfoURLText = ""
        }
        guard insideItem else { return }
        if elementName == "enclosure" {
            pendingVersion = attributeDict["sparkle:shortVersionString"]
                ?? attributeDict["shortVersionString"]
                ?? attributeDict["sparkle:version"]
                ?? attributeDict["version"]
        } else if elementName == "sparkle:releaseNotesLink" || elementName == "releaseNotesLink" {
            insideInfoURL = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if insideInfoURL { currentInfoURLText += string }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "sparkle:releaseNotesLink" || elementName == "releaseNotesLink" {
            insideInfoURL = false
        }
        if elementName == "item", insideItem {
            if let pendingVersion {
                release = SparkleRelease(
                    version: pendingVersion,
                    infoURL: URL(string: currentInfoURLText.trimmingCharacters(in: .whitespacesAndNewlines))
                )
                parser.abortParsing()
            }
            insideItem = false
        }
    }
}

enum StartupItemKind: String, Equatable, Sendable {
    case userAgent
    case systemAgent
    case systemDaemon

    var title: String {
        switch self {
        case .userAgent: "用户启动项"
        case .systemAgent: "系统启动项"
        case .systemDaemon: "系统服务"
        }
    }
}

struct StartupItem: Identifiable, Equatable, Sendable {
    let label: String
    let path: String
    let executablePath: String?
    let kind: StartupItemKind
    let isEnabled: Bool
    let canToggleDirectly: Bool

    var id: String { path }
    var displayName: String {
        label.split(separator: ".").last.map(String.init) ?? label
    }
}

actor StartupItemService {
    private let fileManager: FileManager
    private let homeDirectory: URL
    private let launchctlRunner: @Sendable ([String]) async throws -> Void

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        launchctlRunner: (@Sendable ([String]) async throws -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.homeDirectory = homeDirectory
        self.launchctlRunner = launchctlRunner ?? { arguments in
            try await Self.runLaunchctl(arguments: arguments)
        }
    }

    func scan() -> [StartupItem] {
        let directories: [(URL, StartupItemKind, Bool, Bool)] = [
            (homeDirectory.appendingPathComponent("Library/LaunchAgents"), .userAgent, true, true),
            (homeDirectory.appendingPathComponent("Library/LaunchAgents (Disabled)"), .userAgent, false, true),
            (URL(fileURLWithPath: "/Library/LaunchAgents"), .systemAgent, true, false),
            (URL(fileURLWithPath: "/Library/LaunchDaemons"), .systemDaemon, true, false)
        ]

        return directories.flatMap { directory, kind, enabled, canToggle in
            items(in: directory, kind: kind, enabled: enabled, canToggle: canToggle)
        }
        .sorted { left, right in
            if left.kind == right.kind {
                return left.label.localizedStandardCompare(right.label) == .orderedAscending
            }
            return kindOrder(left.kind) < kindOrder(right.kind)
        }
    }

    func setEnabled(_ enabled: Bool, item: StartupItem) async throws {
        guard item.canToggleDirectly, item.kind == .userAgent else {
            throw MoleClientError.launchFailed("此项目由 macOS 或管理员管理，请在系统设置中更改。")
        }
        guard enabled != item.isEnabled else { return }

        let source = URL(fileURLWithPath: item.path).standardizedFileURL
        let enabledDirectory = homeDirectory
            .appendingPathComponent("Library/LaunchAgents")
            .standardizedFileURL
        let disabledDirectory = homeDirectory
            .appendingPathComponent("Library/LaunchAgents (Disabled)")
            .standardizedFileURL
        let expectedSourceDirectory = item.isEnabled ? enabledDirectory : disabledDirectory
        guard source.pathExtension == "plist",
              source.deletingLastPathComponent() == expectedSourceDirectory,
              let attributes = try? fileManager.attributesOfItem(atPath: source.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw MoleClientError.launchFailed("启动项路径无效或已经变化，未更改任何文件。")
        }
        let destinationDirectory = enabled ? enabledDirectory : disabledDirectory
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destination = destinationDirectory.appendingPathComponent(source.lastPathComponent)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw MoleClientError.launchFailed("目标位置已存在同名启动项，未更改任何文件。")
        }

        let domain = "gui/\(getuid())"
        var bootedOut = false
        if !enabled {
            if (try? await launchctlRunner(["bootout", domain, source.path])) != nil {
                bootedOut = true
            }
        }
        do {
            try fileManager.moveItem(at: source, to: destination)
        } catch {
            if bootedOut {
                try? await launchctlRunner(["bootstrap", domain, source.path])
            }
            throw error
        }
        if enabled {
            do {
                try await launchctlRunner(["bootstrap", domain, destination.path])
            } catch {
                try? fileManager.moveItem(at: destination, to: source)
                throw error
            }
        }
    }

    private func items(
        in directory: URL,
        kind: StartupItemKind,
        enabled: Bool,
        canToggle: Bool
    ) -> [StartupItem] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return urls.filter { $0.pathExtension == "plist" }.compactMap { url in
            guard let data = try? Data(contentsOf: url),
                  let dictionary = try? PropertyListSerialization.propertyList(
                    from: data,
                    options: [],
                    format: nil
                  ) as? [String: Any] else {
                return nil
            }
            let label = dictionary["Label"] as? String ?? url.deletingPathExtension().lastPathComponent
            let program = dictionary["Program"] as? String
                ?? (dictionary["ProgramArguments"] as? [String])?.first
            let plistDisabled = dictionary["Disabled"] as? Bool == true
            return StartupItem(
                label: label,
                path: url.path,
                executablePath: program,
                kind: kind,
                isEnabled: enabled && !plistDisabled,
                canToggleDirectly: canToggle && !plistDisabled
            )
        }
    }

    private static func runLaunchctl(arguments: [String]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let error = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
                process.arguments = arguments
                process.standardOutput = FileHandle.nullDevice
                process.standardError = error
                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let data = error.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    continuation.resume(throwing: MoleClientError.commandFailed(
                        arguments: arguments,
                        code: process.terminationStatus,
                        message: String(decoding: data, as: UTF8.self)
                    ))
                    return
                }
                continuation.resume()
            }
        }
    }

    private func kindOrder(_ kind: StartupItemKind) -> Int {
        switch kind {
        case .userAgent: 0
        case .systemAgent: 1
        case .systemDaemon: 2
        }
    }
}

private final class SoftwareDataBox: @unchecked Sendable {
    var data = Data()
}

private final class SoftwareProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func set(_ process: Process) {
        lock.lock()
        self.process = process
        let shouldTerminate = cancelled
        lock.unlock()
        if shouldTerminate, process.isRunning { process.terminate() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let runningProcess = process
        lock.unlock()
        if let runningProcess, runningProcess.isRunning { runningProcess.terminate() }
    }
}
