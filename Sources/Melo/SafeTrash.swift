import Foundation

struct SafeTrashResult: Equatable, Sendable {
    let originalPath: String
    let trashedPath: String?
}

enum SafeTrashError: LocalizedError, Equatable {
    case missingItem
    case analysisRoot
    case outsideAnalysisRoot
    case protectedSystemPath
    case protectedUserPath
    case applicationPackage
    case volumeRoot
    case symbolicLink
    case itemChanged

    var errorDescription: String? {
        switch self {
        case .missingItem: "项目已经不存在，请重新分析。"
        case .analysisRoot: "不能移动当前正在分析的根目录。"
        case .outsideAnalysisRoot: "项目不在当前分析范围内，已拒绝操作。"
        case .protectedSystemPath: "这是系统保护路径，Melo 不会从空间分析中移动它。"
        case .protectedUserPath: "这是账户或隐私敏感路径，请在访达中手动处理。"
        case .applicationPackage: "应用包请在“软件 → 卸载”中处理，以便检查关联文件。"
        case .volumeRoot: "不能把磁盘或卷根目录移到废纸篓。"
        case .symbolicLink: "项目路径包含符号链接，Melo 无法确认真实目标，已拒绝操作。"
        case .itemChanged: "项目在确认后发生了变化，请重新分析。"
        }
    }
}

struct SafeTrashPolicy: @unchecked Sendable {
    let homeDirectory: URL
    let applicationBundleURL: URL?
    private let fileManager: FileManager

    init(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationBundleURL: URL? = Bundle.main.bundleURL,
        fileManager: FileManager = .default
    ) {
        self.homeDirectory = homeDirectory.resolvingSymlinksInPath().standardizedFileURL
        self.applicationBundleURL = applicationBundleURL?
            .resolvingSymlinksInPath()
            .standardizedFileURL
        self.fileManager = fileManager
    }

    func validate(candidate: URL, analysisRoot: URL) throws -> URL {
        let requestedItem = candidate.standardizedFileURL
        let requestedRoot = analysisRoot.standardizedFileURL
        guard fileManager.fileExists(atPath: requestedItem.path) else { throw SafeTrashError.missingItem }
        guard requestedItem.path != requestedRoot.path else { throw SafeTrashError.analysisRoot }
        guard Self.isDescendant(requestedItem.path, of: requestedRoot.path) else {
            throw SafeTrashError.outsideAnalysisRoot
        }
        guard !containsSymbolicLink(from: requestedRoot, through: requestedItem) else {
            throw SafeTrashError.symbolicLink
        }
        let item = requestedItem.resolvingSymlinksInPath().standardizedFileURL
        let root = requestedRoot.resolvingSymlinksInPath().standardizedFileURL
        guard Self.isDescendant(item.path, of: root.path) else {
            throw SafeTrashError.outsideAnalysisRoot
        }

        let systemRoots = [
            "/System", "/Library", "/Applications", "/usr", "/bin", "/sbin",
            "/private", "/opt", "/Volumes", "/cores", "/dev"
        ]
        if systemRoots.contains(where: { Self.isSameOrDescendant(item.path, of: $0) }) {
            throw SafeTrashError.protectedSystemPath
        }

        let home = homeDirectory.path
        let exactUserRoots = [
            home,
            "\(home)/Desktop", "\(home)/Documents", "\(home)/Downloads",
            "\(home)/Library", "\(home)/Movies", "\(home)/Music", "\(home)/Pictures",
            "\(home)/Public", "\(home)/.Trash"
        ]
        if exactUserRoots.contains(item.path) { throw SafeTrashError.protectedUserPath }

        let sensitiveUserRoots = [
            "\(home)/.ssh", "\(home)/.gnupg",
            "\(home)/Library/Keychains", "\(home)/Library/Mail",
            "\(home)/Library/Messages", "\(home)/Library/Safari",
            "\(home)/Library/Accounts", "\(home)/Library/IdentityServices",
            "\(home)/Library/Group Containers", "\(home)/Library/Containers"
        ]
        if sensitiveUserRoots.contains(where: {
            Self.isSameOrDescendant(item.path, of: $0) || Self.isDescendant($0, of: item.path)
        }) {
            throw SafeTrashError.protectedUserPath
        }

        if let applicationBundleURL,
           Self.isSameOrDescendant(item.path, of: applicationBundleURL.path) {
            throw SafeTrashError.applicationPackage
        }
        if isInsidePackage(item, through: root) {
            throw SafeTrashError.applicationPackage
        }
        if let volumeURL = try? item.resourceValues(forKeys: [.volumeURLKey]).volume,
                  volumeURL.standardizedFileURL.path == item.path {
            throw SafeTrashError.volumeRoot
        }
        return item
    }

    func protectionReason(candidate: URL, analysisRoot: URL) -> String? {
        do {
            _ = try validate(candidate: candidate, analysisRoot: analysisRoot)
            return nil
        } catch {
            return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private static func isDescendant(_ path: String, of root: String) -> Bool {
        let normalizedRoot = root == "/"
            ? "/"
            : (root.hasSuffix("/") ? String(root.dropLast()) : root)
        if normalizedRoot == "/" { return path.hasPrefix("/") && path != "/" }
        return path.hasPrefix(normalizedRoot + "/")
    }

    private static func isSameOrDescendant(_ path: String, of root: String) -> Bool {
        path == root || isDescendant(path, of: root)
    }

    private func containsSymbolicLink(from root: URL, through item: URL) -> Bool {
        let relative = item.path.dropFirst(root.path.count)
        var current = root
        for component in relative.split(separator: "/") {
            current.appendPathComponent(String(component))
            guard let attributes = try? fileManager.attributesOfItem(atPath: current.path) else {
                return true
            }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink { return true }
        }
        return false
    }

    private func isInsidePackage(_ item: URL, through root: URL) -> Bool {
        var current = item
        while Self.isSameOrDescendant(current.path, of: root.path) {
            if current.pathExtension.localizedCaseInsensitiveCompare("app") == .orderedSame {
                return true
            }
            if (try? current.resourceValues(forKeys: [.isPackageKey]).isPackage) == true {
                return true
            }
            if current.path == root.path { break }
            current.deleteLastPathComponent()
        }
        return false
    }
}

actor SafeTrashService {
    private let fileManager: FileManager
    private let policy: SafeTrashPolicy
    private let testTrashDirectory: URL?

    init(
        fileManager: FileManager = .default,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        applicationBundleURL: URL? = Bundle.main.bundleURL,
        testTrashDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.policy = SafeTrashPolicy(
            homeDirectory: homeDirectory,
            applicationBundleURL: applicationBundleURL,
            fileManager: fileManager
        )
        self.testTrashDirectory = testTrashDirectory
    }

    nonisolated func protectionReason(candidatePath: String, analysisRoot: String) -> String? {
        policy.protectionReason(
            candidate: URL(fileURLWithPath: candidatePath),
            analysisRoot: URL(fileURLWithPath: analysisRoot)
        )
    }

    func moveToTrash(candidatePath: String, analysisRoot: String) throws -> SafeTrashResult {
        let root = URL(fileURLWithPath: analysisRoot)
        let requestedItem = URL(fileURLWithPath: candidatePath)
        let item = try policy.validate(
            candidate: requestedItem,
            analysisRoot: root
        )
        let identity = try Self.fileIdentity(item, fileManager: fileManager)
        let revalidated = try policy.validate(candidate: requestedItem, analysisRoot: root)
        guard revalidated == item,
              try Self.fileIdentity(revalidated, fileManager: fileManager) == identity else {
            throw SafeTrashError.itemChanged
        }
        if let testTrashDirectory {
            try fileManager.createDirectory(at: testTrashDirectory, withIntermediateDirectories: true)
            let destination = testTrashDirectory.appendingPathComponent(
                "\(UUID().uuidString)-\(item.lastPathComponent)"
            )
            try fileManager.moveItem(at: item, to: destination)
            return SafeTrashResult(originalPath: item.path, trashedPath: destination.path)
        }

        var resultingURL: NSURL?
        try fileManager.trashItem(at: item, resultingItemURL: &resultingURL)
        return SafeTrashResult(
            originalPath: item.path,
            trashedPath: (resultingURL as URL?)?.path
        )
    }

    private static func fileIdentity(_ item: URL, fileManager: FileManager) throws -> FileIdentity {
        let attributes = try fileManager.attributesOfItem(atPath: item.path)
        guard let device = attributes[.systemNumber] as? NSNumber,
              let inode = attributes[.systemFileNumber] as? NSNumber,
              let type = attributes[.type] as? FileAttributeType else {
            throw SafeTrashError.itemChanged
        }
        return FileIdentity(device: device.uint64Value, inode: inode.uint64Value, type: type)
    }

    private struct FileIdentity: Equatable {
        let device: UInt64
        let inode: UInt64
        let type: FileAttributeType
    }
}
