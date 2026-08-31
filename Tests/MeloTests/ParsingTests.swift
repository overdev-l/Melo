import XCTest
@testable import Melo
import MeloHardwareProtocol
import SMCCore

final class ParsingTests: XCTestCase {
    func testCleanupPreviewParsesSectionsAndSummary() {
        let output = """
        Clean Your Mac

        Dry Run Mode, Preview only, no deletions
        ◎ System caches need sudo, run sudo -v for full preview

        ➤ User essentials
          → User app cache · 8 items, 536.4MB dry
          ◎ Mail Downloads · skipped (sizing unavailable)

        ➤ Browsers
          ✓ Nothing to clean

        Dry run complete - no changes made
        Potential space: 864.8MB | Items: 60 | Categories: 6
        """

        let preview = CleanupPreview.parse(output)

        XCTAssertEqual(preview.potentialSpace, "864.8MB")
        XCTAssertEqual(preview.itemCount, 60)
        XCTAssertEqual(preview.categoryCount, 6)
        XCTAssertEqual(preview.sections.map(\.title), ["User essentials", "Browsers"])
        XCTAssertEqual(preview.sections[0].items.count, 2)
        XCTAssertTrue(preview.sections[0].items[1].isSkipped)
        XCTAssertTrue(preview.requiresAdminForFullPreview)
    }

    func testCleanupRunFindsTrackedSummary() {
        let result = CleanupRunResult.parse("""
        Cleanup complete
        Tracked cleanup: 4.5GB | Items cleaned: 97 | Categories: 4
        """)

        XCTAssertEqual(result.summary, "Tracked cleanup: 4.5GB | Items cleaned: 97 | Categories: 4")
    }

    func testDiskAnalysisAllowsMissingLargeFiles() throws {
        let data = """
        {
          "path": "/tmp/example",
          "entries": [
            {"name":"Build","path":"/tmp/example/Build","size":4096,"is_dir":true}
          ],
          "total_size": 4096,
          "total_files": 2
        }
        """.data(using: .utf8)!

        let analysis = try JSONDecoder().decode(DiskAnalysis.self, from: data)
        XCTAssertEqual(analysis.entries.count, 1)
        XCTAssertEqual(analysis.largeFiles, [])
        XCTAssertEqual(analysis.totalSize, 4096)
    }

    func testHistoryAllowsSparseSessions() throws {
        let data = """
        {
          "sessions": [{"command":"clean","started_at":"2026-08-30 21:00:00"}],
          "deletions": []
        }
        """.data(using: .utf8)!

        let history = try JSONDecoder().decode(MoleHistory.self, from: data)
        XCTAssertEqual(history.sessions.first?.command, "clean")
        XCTAssertNil(history.sessions.first?.size)
    }

    func testApplicationInventoryAndSizeParsing() throws {
        let data = """
        [{
          "name":"Example",
          "bundle_id":"dev.example.app",
          "source":"Homebrew",
          "uninstall_name":"example",
          "path":"/Applications/Example.app",
          "size":"1.25GB"
        }]
        """.data(using: .utf8)!

        let applications = try JSONDecoder().decode([MoleApplication].self, from: data)
        XCTAssertEqual(applications.first?.uninstallName, "example")
        XCTAssertEqual(applications.first?.sizeInBytes, 1_342_177_280)
        XCTAssertNil(SizeStringParser.bytes(from: "--"))
    }

    func testMaintenancePreviewParsesPlan() {
        let output = """
        ➤ Finder Cache Refresh
          → QuickLook thumbnails refreshed
          → Icon services cache rebuilt

        ➤ Database Optimization
          ◎ Close Safari before database optimization

        Would apply 5 optimizations
        11 unchanged | 3 skipped | 1 unavailable | 1 failed
        """

        let preview = MaintenancePreview.parse(output)
        XCTAssertEqual(preview.applicableCount, 5)
        XCTAssertEqual(preview.unchangedCount, 11)
        XCTAssertEqual(preview.skippedCount, 3)
        XCTAssertEqual(preview.sections.count, 2)
        XCTAssertTrue(preview.sections[1].items[0].isSkipped)
    }

    func testUninstallPreviewExtractsPaths() {
        let application = MoleApplication(
            name: "Example",
            bundleID: "dev.example.app",
            source: "App",
            uninstallName: "Example",
            path: "/Applications/Example.app",
            size: "20MB"
        )
        let output = """
        Files to be removed:
          ✓ /Applications/Example.app , 20MB
          ✓ ~/Library/Preferences/dev.example.app.plist
        Would remove 1 app, would free 20MB: Example
        """

        let preview = UninstallPreview.parse(output, application: application)
        XCTAssertEqual(preview.paths.count, 2)
        XCTAssertTrue(preview.summary.contains("20MB"))
    }

    func testStatusDecodesExtendedHardwareMetrics() throws {
        let data = """
        {
          "health_score": 96,
          "cpu": {"usage": 22.5, "per_core": [10, 35], "load1": 1.2, "load5": 1.0, "load15": 0.8, "core_count": 2, "p_core_count": 1, "e_core_count": 1},
          "memory": {"used": 4096, "total": 8192, "used_percent": 50, "cached": 512, "pressure": "normal"},
          "gpu": [{"name": "Apple GPU", "usage": 18, "core_count": 10}],
          "network": [{"name": "en0", "rx_rate_mbs": 1.5, "tx_rate_mbs": 0.5, "ip": "192.0.2.1"}],
          "disk_io": {"read_rate": 1024, "write_rate": 2048},
          "batteries": [{"name": "Mac", "percent": 82, "status": "Discharging", "health": 94}],
          "bluetooth": [{"name": "Trackpad", "connected": true, "battery": "75%"}],
          "thermal": {"cpu_temp": 52, "gpu_temp": 48, "fan_speed": 1800, "fan_count": 2, "system_power": 17.5}
        }
        """.data(using: .utf8)!

        let status = try JSONDecoder().decode(MoleStatus.self, from: data)
        XCTAssertEqual(status.gpu.first?.coreCount, 10)
        XCTAssertEqual(status.network.first?.receiveRateMB, 1.5)
        XCTAssertEqual(status.batteries.first?.percent, 82)
        XCTAssertEqual(status.thermal?.fanCount, 2)
        XCTAssertEqual(status.cpu?.performanceCoreCount, 1)
    }

    func testLiveMetricHistoryKeepsSixtySamples() {
        var history = LiveMetricHistory()
        let start = Date(timeIntervalSince1970: 1_000)
        for offset in 0..<75 {
            history.append(
                LiveSystemSnapshot(
                    date: start.addingTimeInterval(Double(offset)),
                    cpuUsage: Double(offset),
                    perCoreUsage: [Double(offset)],
                    memoryUsed: 1,
                    memoryTotal: 2,
                    memoryUsedPercent: 50,
                    networkReceiveBytesPerSecond: Double(offset * 10),
                    networkSendBytesPerSecond: Double(offset * 5),
                    processes: []
                )
            )
        }

        XCTAssertEqual(history.cpu.count, 60)
        XCTAssertEqual(history.cpu.first?.value, 15)
        XCTAssertEqual(history.cpu.last?.value, 74)
        XCTAssertEqual(history.networkSend.count, 60)
    }

    func testNativeSamplerReturnsLocalMetrics() async throws {
        let sampler = NativeSystemSampler()
        _ = await sampler.sample()
        try await Task.sleep(for: .milliseconds(80))
        let snapshot = await sampler.sample()

        XCTAssertFalse(snapshot.perCoreUsage.isEmpty)
        XCTAssertGreaterThan(snapshot.memoryTotal, 0)
        XCTAssertGreaterThanOrEqual(snapshot.cpuUsage, 0)
        XCTAssertLessThanOrEqual(snapshot.cpuUsage, 100)
        XCTAssertGreaterThanOrEqual(snapshot.networkReceiveBytesPerSecond, 0)
    }

    func testNativeSamplerMeasuresBusyChildProcess() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/yes")
        child.standardOutput = FileHandle.nullDevice
        child.standardError = FileHandle.nullDevice
        try child.run()
        defer { stopTestProcess(child) }

        let sampler = NativeSystemSampler()
        _ = await sampler.sample()
        try await Task.sleep(for: .milliseconds(350))
        let snapshot = await sampler.sample()
        let measured = snapshot.processes.first { $0.pid == child.processIdentifier }

        XCTAssertNotNil(measured)
        XCTAssertGreaterThan(measured?.cpu ?? 0, 1)
    }

    func testProcessTerminationEndsOwnedChildGracefully() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["10"]
        try child.run()
        defer { stopTestProcess(child) }
        guard let identity = ProcessIdentity.current(pid: child.processIdentifier) else {
            return XCTFail("无法读取测试子进程身份")
        }
        let liveProcess = LiveProcess(
            pid: child.processIdentifier,
            parentPID: getpid(),
            name: "sleep",
            executablePath: "/bin/sleep",
            cpu: 0,
            memoryBytes: 0,
            isOwnedByCurrentUser: true,
            identity: identity
        )

        let outcome = try await ProcessTerminationService().terminate(
            liveProcess,
            gracePeriod: .milliseconds(500),
            pollInterval: .milliseconds(10)
        )

        XCTAssertEqual(outcome, .terminatedGracefully)
    }

    func testProcessTerminationForceKillsOnlyMatchingIdentity() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "trap '' TERM; exec /bin/sleep 10"]
        try child.run()
        defer { stopTestProcess(child) }
        try await Task.sleep(for: .milliseconds(100))
        guard let identity = ProcessIdentity.current(pid: child.processIdentifier) else {
            return XCTFail("无法读取测试子进程身份")
        }
        let liveProcess = LiveProcess(
            pid: child.processIdentifier,
            parentPID: getpid(),
            name: "sleep",
            executablePath: "/bin/sleep",
            cpu: 0,
            memoryBytes: 0,
            isOwnedByCurrentUser: true,
            identity: identity
        )

        let outcome = try await ProcessTerminationService().terminate(
            liveProcess,
            gracePeriod: .milliseconds(100),
            pollInterval: .milliseconds(10)
        )

        XCTAssertEqual(outcome, .forceKilled)
        let staleProcess = LiveProcess(
            pid: getpid(),
            parentPID: 1,
            name: "tests",
            executablePath: nil,
            cpu: 0,
            memoryBytes: 0,
            isOwnedByCurrentUser: true,
            identity: ProcessIdentity(pid: getpid(), startTimeMicroseconds: 0)
        )
        do {
            _ = try await ProcessTerminationService().terminate(
                staleProcess,
                gracePeriod: .milliseconds(1)
            )
            XCTFail("身份不匹配时不应发送信号")
        } catch let error as ProcessTerminationError {
            XCTAssertEqual(error, .protectedProcess)
        }
        let stalePID = Int32.max
        let staleIdentity = LiveProcess(
            pid: stalePID,
            parentPID: 1,
            name: "stale",
            executablePath: nil,
            cpu: 0,
            memoryBytes: 0,
            isOwnedByCurrentUser: true,
            identity: ProcessIdentity(pid: stalePID, startTimeMicroseconds: 1)
        )
        do {
            _ = try await ProcessTerminationService().terminate(
                staleIdentity,
                gracePeriod: .milliseconds(1)
            )
            XCTFail("过期 PID 身份不应收到任何信号")
        } catch let error as ProcessTerminationError {
            XCTAssertEqual(error, .staleIdentity)
        }
    }

    func testKeepAwakeSessionRoundTripsWithRemainingTime() throws {
        let session = KeepAwakeSession(
            mode: .both,
            startedAt: Date(),
            endDate: Date().addingTimeInterval(3_600)
        )
        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(KeepAwakeSession.self, from: data)

        XCTAssertEqual(decoded.mode, .both)
        XCTAssertTrue(decoded.isActive)
        XCTAssertTrue(decoded.remainingText.contains("剩余"))
    }

    func testPowerAssertionCanBeReleasedImmediately() throws {
        let controller = PowerAssertionController()
        defer { controller.stop() }

        try controller.start(mode: .display)
        controller.stop()
    }

    func testPrivacySamplerUsesPublicHardwareState() async {
        let activity = await PrivacyActivityMonitor().sample()
        let processIDs = activity.microphoneApplications.map(\.pid)

        XCTAssertEqual(Set(processIDs).count, processIDs.count)
        XCTAssertTrue(activity.microphoneApplications.allSatisfy { !$0.name.isEmpty })
    }

    func testPrivacyAlertDeduplicationResetsAfterIdleOrAuthorizationChange() {
        let activity = PrivacyActivity(
            microphoneApplications: [
                PrivacyApplication(pid: 123, name: "Fixture", bundleIdentifier: "dev.melo.fixture")
            ],
            isCameraActive: false,
            cameraName: nil
        )
        var deduplicator = PrivacyAlertDeduplicator()

        XCTAssertFalse(deduplicator.shouldSchedule(activity: activity, alertsEnabled: false))
        XCTAssertTrue(deduplicator.shouldSchedule(activity: activity, alertsEnabled: true))
        XCTAssertFalse(deduplicator.shouldSchedule(activity: activity, alertsEnabled: true))
        XCTAssertFalse(deduplicator.shouldSchedule(activity: .idle, alertsEnabled: true))
        XCTAssertTrue(deduplicator.shouldSchedule(activity: activity, alertsEnabled: true))
        deduplicator.reset()
        XCTAssertTrue(deduplicator.shouldSchedule(activity: activity, alertsEnabled: true))
    }

    func testSparkleFeedParserReadsLatestVersion() {
        let xml = """
        <?xml version="1.0" encoding="utf-8"?>
        <rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
          <channel><item>
            <sparkle:releaseNotesLink>https://example.com/releases/2</sparkle:releaseNotesLink>
            <enclosure sparkle:shortVersionString="2.4.0" url="https://example.com/app.zip" />
          </item></channel>
        </rss>
        """

        let release = SparkleFeedParser().parse(data: Data(xml.utf8))
        XCTAssertEqual(release?.version, "2.4.0")
        XCTAssertEqual(release?.infoURL?.absoluteString, "https://example.com/releases/2")
    }

    func testStartupItemServiceClassifiesUserAgent() async throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("melo-startup-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }
        let agents = temporaryHome.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try fileManager.createDirectory(at: agents, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "Label": "dev.melo.fixture",
            "ProgramArguments": ["/usr/bin/true"]
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: agents.appendingPathComponent("dev.melo.fixture.plist"))

        let items = await StartupItemService(
            fileManager: fileManager,
            homeDirectory: temporaryHome
        ).scan()
        let fixture = items.first { $0.label == "dev.melo.fixture" }

        XCTAssertEqual(fixture?.kind, .userAgent)
        XCTAssertEqual(fixture?.executablePath, "/usr/bin/true")
        XCTAssertEqual(fixture?.isEnabled, true)
        XCTAssertEqual(fixture?.canToggleDirectly, true)
    }

    func testStartupItemServiceMovesUserAgentInBothDirections() async throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("melo-startup-toggle-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }
        let enabledDirectory = temporaryHome.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        try fileManager.createDirectory(at: enabledDirectory, withIntermediateDirectories: true)
        let source = enabledDirectory.appendingPathComponent("dev.melo.fixture.plist")
        try startupFixtureData().write(to: source)
        let recorder = LaunchctlRecorder()
        let service = StartupItemService(
            fileManager: fileManager,
            homeDirectory: temporaryHome,
            launchctlRunner: { arguments in await recorder.run(arguments) }
        )
        guard let enabledItem = await service.scan().first(where: { $0.label == "dev.melo.fixture" }) else {
            return XCTFail("未扫描到测试启动项")
        }

        try await service.setEnabled(false, item: enabledItem)
        guard let disabledItem = await service.scan().first(where: { $0.label == "dev.melo.fixture" }) else {
            return XCTFail("停用后未扫描到测试启动项")
        }
        XCTAssertFalse(disabledItem.isEnabled)
        XCTAssertFalse(fileManager.fileExists(atPath: source.path))

        try await service.setEnabled(true, item: disabledItem)
        XCTAssertTrue(fileManager.fileExists(atPath: source.path))
        let commands = await recorder.commands
        XCTAssertEqual(commands.map(\.first), ["bootout", "bootstrap"])
    }

    func testStartupItemServiceRollsBackWhenBootstrapFails() async throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("melo-startup-rollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }
        let disabledDirectory = temporaryHome
            .appendingPathComponent("Library/LaunchAgents (Disabled)", isDirectory: true)
        try fileManager.createDirectory(at: disabledDirectory, withIntermediateDirectories: true)
        let source = disabledDirectory.appendingPathComponent("dev.melo.fixture.plist")
        try startupFixtureData().write(to: source)
        let service = StartupItemService(
            fileManager: fileManager,
            homeDirectory: temporaryHome,
            launchctlRunner: { arguments in
                if arguments.first == "bootstrap" {
                    throw MoleClientError.launchFailed("fixture bootstrap failure")
                }
            }
        )
        guard let item = await service.scan().first(where: { $0.label == "dev.melo.fixture" }) else {
            return XCTFail("未扫描到测试启动项")
        }

        do {
            try await service.setEnabled(true, item: item)
            XCTFail("bootstrap 失败时不应报告成功")
        } catch {
            XCTAssertTrue(fileManager.fileExists(atPath: source.path))
            let enabledPath = temporaryHome.appendingPathComponent("Library/LaunchAgents/dev.melo.fixture.plist")
            XCTAssertFalse(fileManager.fileExists(atPath: enabledPath.path))
        }
    }

    func testStartupItemServiceRejectsForgedPath() async throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("melo-startup-path-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }
        let outside = temporaryHome.appendingPathComponent("Documents/dev.melo.fixture.plist")
        try fileManager.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try startupFixtureData().write(to: outside)
        let service = StartupItemService(
            fileManager: fileManager,
            homeDirectory: temporaryHome,
            launchctlRunner: { _ in XCTFail("伪造路径不应调用 launchctl") }
        )
        let forged = StartupItem(
            label: "dev.melo.fixture",
            path: outside.path,
            executablePath: "/usr/bin/true",
            kind: .userAgent,
            isEnabled: true,
            canToggleDirectly: true
        )

        do {
            try await service.setEnabled(false, item: forged)
            XCTFail("伪造路径不应被接受")
        } catch {
            // Expected: validation happens before launchctl or file movement.
        }
        XCTAssertTrue(fileManager.fileExists(atPath: outside.path))
    }

    private func startupFixtureData() throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "Label": "dev.melo.fixture",
                "ProgramArguments": ["/usr/bin/true"]
            ],
            format: .xml,
            options: 0
        )
    }

    func testHomebrewUpdatesRequireExplicitInstall() {
        let update = SoftwareUpdate(
            source: .homebrewCask,
            identifier: "example",
            name: "Example",
            installedVersion: "1.0",
            availableVersion: "2.0",
            applicationPath: nil,
            releaseURL: nil
        )
        let sparkle = SoftwareUpdate(
            source: .sparkle,
            identifier: "dev.example",
            name: "Example",
            installedVersion: "1.0",
            availableVersion: "2.0",
            applicationPath: "/Applications/Example.app",
            releaseURL: nil
        )

        XCTAssertTrue(update.canInstallDirectly)
        XCTAssertFalse(sparkle.canInstallDirectly)
    }

    func testElectronUpdateConfigurationParsesGenericAndGitHubProviders() {
        let generic = ElectronUpdateConfiguration.parse(data: Data("""
        provider: generic
        url: 'https://updates.example.com/mac'
        channel: arm64
        """.utf8))
        let github = ElectronUpdateConfiguration.parse(data: Data("""
        owner: example
        repo: desktop
        provider: github
        """.utf8))

        XCTAssertEqual(generic?.provider, "generic")
        XCTAssertEqual(generic?.url?.absoluteString, "https://updates.example.com/mac")
        XCTAssertEqual(generic?.channel, "arm64")
        XCTAssertEqual(github?.owner, "example")
        XCTAssertEqual(github?.repo, "desktop")
    }

    func testElectronLatestYAMLParserReadsVersion() {
        let release = ElectronLatestYAMLParser.parse(data: Data("""
        version: 4.2.1
        path: Example-4.2.1-arm64.zip
        sha512: Zml4dHVyZS1zaGE1MTI=
        files:
          - url: Example-4.2.1-arm64.zip
        releaseDate: '2026-08-30T10:00:00Z'
        """.utf8))

        XCTAssertEqual(release?.version, "4.2.1")
        XCTAssertEqual(release?.releaseDate, "2026-08-30T10:00:00Z")
        XCTAssertEqual(release?.path, "Example-4.2.1-arm64.zip")
        XCTAssertEqual(release?.sha512, "Zml4dHVyZS1zaGE1MTI=")
    }

    func testSoftwareUpdateSafetyRejectsInsecureRedirectsAndOversizedDownloads() throws {
        XCTAssertTrue(SoftwareUpdateSafetyPolicy.acceptsDownload(
            finalURL: URL(string: "https://cdn.example.com/update.zip"),
            statusCode: 200,
            expectedContentLength: 100
        ))
        XCTAssertFalse(SoftwareUpdateSafetyPolicy.acceptsDownload(
            finalURL: URL(string: "http://cdn.example.com/update.zip"),
            statusCode: 200,
            expectedContentLength: 100
        ))
        XCTAssertFalse(SoftwareUpdateSafetyPolicy.acceptsDownload(
            finalURL: URL(string: "https://cdn.example.com/update.zip"),
            statusCode: 200,
            expectedContentLength: SoftwareUpdateSafetyPolicy.maximumArchiveBytes + 1
        ))
    }

    func testSoftwareUpdateSafetyRejectsArchiveTraversalPaths() {
        XCTAssertTrue(SoftwareUpdateSafetyPolicy.archiveEntriesAreSafe("""
        Example.app/
        Example.app/Contents/Info.plist
        __MACOSX/._Example.app
        """))
        XCTAssertFalse(SoftwareUpdateSafetyPolicy.archiveEntriesAreSafe("Example.app/../../Library/evil"))
        XCTAssertFalse(SoftwareUpdateSafetyPolicy.archiveEntriesAreSafe("/Applications/evil.app"))
        XCTAssertFalse(SoftwareUpdateSafetyPolicy.archiveEntriesAreSafe("..\\Library\\evil"))
        XCTAssertFalse(SoftwareUpdateSafetyPolicy.archiveEntriesAreSafe(""))
    }

    func testSoftwareUpdateCandidateMustBeRealDirectoryInsideExtractionRoot() throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent("melo-update-containment-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: workspace) }
        let root = workspace.appendingPathComponent("extracted", isDirectory: true)
        let candidate = root.appendingPathComponent("Example.app", isDirectory: true)
        let outside = workspace.appendingPathComponent("Outside.app", isDirectory: true)
        try fileManager.createDirectory(at: candidate, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)

        XCTAssertTrue(SoftwareUpdateSafetyPolicy.candidateBundleIsContained(
            candidate,
            in: root,
            fileManager: fileManager
        ))
        XCTAssertFalse(SoftwareUpdateSafetyPolicy.candidateBundleIsContained(
            outside,
            in: root,
            fileManager: fileManager
        ))
        let linked = root.appendingPathComponent("Linked.app")
        try fileManager.createSymbolicLink(at: linked, withDestinationURL: outside)
        XCTAssertFalse(SoftwareUpdateSafetyPolicy.candidateBundleIsContained(
            linked,
            in: root,
            fileManager: fileManager
        ))
    }

    func testNativeApplicationInventoryFindsHomeApplications() async throws {
        let fileManager = FileManager.default
        let temporaryHome = fileManager.temporaryDirectory
            .appendingPathComponent("melo-app-inventory-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporaryHome) }
        let appURL = temporaryHome
            .appendingPathComponent("Applications", isDirectory: true)
            .appendingPathComponent("Fixture.app", isDirectory: true)
        let contents = appURL.appendingPathComponent("Contents", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try fileManager.createDirectory(at: resources, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "dev.melo.inventory-fixture",
            "CFBundleName": "Inventory Fixture",
            "CFBundleShortVersionString": "1.2.3",
            "SUFeedURL": "https://updates.example.com/feed.xml"
        ]
        let infoData = try PropertyListSerialization.data(
            fromPropertyList: info,
            format: .xml,
            options: 0
        )
        try infoData.write(to: contents.appendingPathComponent("Info.plist"))
        try Data("provider: github\nowner: example\nrepo: fixture\n".utf8)
            .write(to: resources.appendingPathComponent("app-update.yml"))

        let inventory = await NativeApplicationInventoryService(
            fileManager: fileManager,
            homeDirectory: temporaryHome
        ).scan()
        let fixture = inventory.first { $0.bundleID == "dev.melo.inventory-fixture" }

        XCTAssertEqual(fixture?.name, "Inventory Fixture")
        XCTAssertEqual(fixture?.version, "1.2.3")
        XCTAssertEqual(fixture?.sparkleFeedURL?.host, "updates.example.com")
        XCTAssertNotNil(fixture?.electronConfigurationURL)
    }

    func testSoftwareCommandRunnerCancellationTerminatesChild() async throws {
        let runner = SoftwareCommandRunner()
        let start = Date()
        let operation = Task {
            try await runner.run(
                executable: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["10"]
            )
        }

        try await Task.sleep(for: .milliseconds(100))
        operation.cancel()

        do {
            _ = try await operation.value
            XCTFail("取消后的命令不应成功返回")
        } catch is CancellationError {
            // Expected: the runner terminates the child and preserves cancellation semantics.
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testCleanupForcesRecoverableTrashMode() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("melo-trash-mode-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-mo")
        try Data("#!/bin/sh\nprintf 'Tracked cleanup: 0B | mode=%s\\n' \"$MOLE_DELETE_MODE\"\n".utf8)
            .write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let result = try await MoleClient(executableURL: executable).cleanUserLevelItems()

        XCTAssertTrue(result.output.contains("mode=trash"))
    }

    func testMaintenanceForcesRecoverableTrashMode() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("melo-maintenance-trash-mode-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-mo")
        try Data("#!/bin/sh\nprintf 'Applied optimizations | mode=%s\\n' \"$MOLE_DELETE_MODE\"\n".utf8)
            .write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

        let result = try await MoleClient(executableURL: executable).performMaintenance()

        XCTAssertTrue(result.rawOutput.contains("mode=trash"))
    }

    func testAnalyzePassesUntrustedPathAsSingleArgument() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("melo-analyze-argument-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-mo")
        try Data("#!/bin/sh\nprintf '{\"path\":\"%s\",\"entries\":[],\"large_files\":[],\"total_size\":0,\"total_files\":0}\\n' \"$3\"\n".utf8)
            .write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let marker = directory.appendingPathComponent("should-not-exist")
        let untrustedPath = "/tmp/folder name;touch \(marker.path)"

        let result = try await MoleClient(executableURL: executable).analyze(path: untrustedPath)

        XCTAssertEqual(result.path, untrustedPath)
        XCTAssertFalse(fileManager.fileExists(atPath: marker.path))
    }

    func testCleanupRunCanBeInterrupted() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("melo-clean-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-mo")
        try Data("#!/bin/sh\nsleep 10\n".utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = MoleClient(executableURL: executable)
        let operationID = UUID()
        let start = Date()
        let operation = Task { try await client.cleanUserLevelItems(operationID: operationID) }

        try await Task.sleep(for: .milliseconds(100))
        client.cancel(operationID: operationID)

        do {
            _ = try await operation.value
            XCTFail("停止后的清理不应成功返回")
        } catch {
            // Expected: SIGINT stops the current Mole operation.
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testCancellingTaskTerminatesMoleChildAndThrowsCancellation() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("melo-task-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-mo")
        try Data("#!/bin/sh\nsleep 10\n".utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = MoleClient(executableURL: executable)
        let start = Date()
        let operation = Task { try await client.run(arguments: ["status"]) }

        try await Task.sleep(for: .milliseconds(100))
        operation.cancel()

        do {
            _ = try await operation.value
            XCTFail("取消 Task 后 Mole 命令不应成功返回")
        } catch is CancellationError {
            // Expected: structured cancellation stops the registered child.
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testSharedOperationIDCancellationStopsEveryRegisteredChild() async throws {
        let fileManager = FileManager.default
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("melo-shared-operation-cancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directory) }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("fake-mo")
        try Data("#!/bin/sh\nsleep 10\n".utf8).write(to: executable)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let client = MoleClient(executableURL: executable)
        let operationID = UUID()
        let first = Task { try await client.run(arguments: ["first"], operationID: operationID) }
        let second = Task { try await client.run(arguments: ["second"], operationID: operationID) }

        try await Task.sleep(for: .milliseconds(100))
        client.cancel(operationID: operationID)

        for operation in [first, second] {
            do {
                _ = try await operation.value
                XCTFail("同一操作中的子进程都应被停止")
            } catch is CancellationError {
                // Expected.
            }
        }
    }

    func testProtectionServiceRoundTripsAndNormalizesHomePaths() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("melo-protection-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        let service = MoleProtectionService(fileManager: fileManager, homeDirectory: home)

        _ = try await service.add(home.appendingPathComponent("Library/Caches/Fixture").path, scope: .clean)
        _ = try await service.add("~/Library/Caches/Fixture", scope: .clean)
        let loaded = try await service.load(scope: .clean)

        XCTAssertEqual(loaded.map(\.pattern), ["$HOME/Library/Caches/Fixture"])
        let removed = try await service.remove("$HOME/Library/Caches/Fixture", scope: .clean)
        XCTAssertTrue(removed.isEmpty)
    }

    func testProtectionServiceRejectsCommentInjection() async throws {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("melo-protection-invalid-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let service = MoleProtectionService(homeDirectory: home)

        do {
            _ = try await service.add("# hidden entry", scope: .clean)
            XCTFail("注释注入不应被接受")
        } catch let error as MoleProtectionError {
            XCTAssertEqual(error, .invalidPattern)
        }
    }

    func testProtectionServiceUsesPrivatePermissions() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("melo-protection-permissions-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }
        try fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        let service = MoleProtectionService(fileManager: fileManager, homeDirectory: home)

        _ = try await service.add("$HOME/Library/Caches/Fixture", scope: .clean)

        let directory = home.appendingPathComponent(".config/mole")
        let file = directory.appendingPathComponent("whitelist")
        let directoryMode = try fileManager.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        let fileMode = try fileManager.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual((directoryMode?.intValue ?? -1) & 0o777, 0o700)
        XCTAssertEqual((fileMode?.intValue ?? -1) & 0o777, 0o600)
    }

    func testProtectionServiceRejectsLinkedConfigurationFileAndDirectory() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("melo-protection-links-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }
        let moleDirectory = home.appendingPathComponent(".config/mole", isDirectory: true)
        let external = home.appendingPathComponent("external", isDirectory: true)
        try fileManager.createDirectory(at: moleDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: external, withIntermediateDirectories: true)
        let externalFile = external.appendingPathComponent("whitelist")
        try Data("external\n".utf8).write(to: externalFile)
        let linkedFile = moleDirectory.appendingPathComponent("whitelist")
        try fileManager.createSymbolicLink(at: linkedFile, withDestinationURL: externalFile)
        let service = MoleProtectionService(fileManager: fileManager, homeDirectory: home)

        do {
            _ = try await service.add("$HOME/Documents", scope: .clean)
            XCTFail("符号链接白名单不应被写入")
        } catch let error as MoleProtectionError {
            XCTAssertEqual(error, .unsafeConfiguration)
        }
        XCTAssertEqual(try String(contentsOf: externalFile, encoding: .utf8), "external\n")

        try fileManager.removeItem(at: moleDirectory)
        try fileManager.createSymbolicLink(at: moleDirectory, withDestinationURL: external)
        do {
            _ = try await service.load(scope: .clean)
            XCTFail("符号链接配置目录不应被读取")
        } catch let error as MoleProtectionError {
            XCTAssertEqual(error, .unsafeConfiguration)
        }
        do {
            _ = try await service.add("$HOME/Documents", scope: .clean)
            XCTFail("符号链接配置目录不应被写入")
        } catch let error as MoleProtectionError {
            XCTAssertEqual(error, .unsafeConfiguration)
        }
        XCTAssertFalse(fileManager.fileExists(atPath: external.appendingPathComponent("whitelist_optimize").path))
    }

    func testSafeTrashPolicyRejectsSensitiveAndOutOfScopePaths() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("melo-trash-policy-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }
        let root = home.appendingPathComponent("Documents", isDirectory: true)
        let safeFile = root.appendingPathComponent("large.iso")
        let sensitive = home.appendingPathComponent(".ssh/id_ed25519")
        let outside = home.appendingPathComponent("Downloads/outside.zip")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sensitive.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: outside.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: safeFile)
        try Data().write(to: sensitive)
        try Data().write(to: outside)
        let policy = SafeTrashPolicy(
            homeDirectory: home,
            applicationBundleURL: nil,
            fileManager: fileManager
        )

        XCTAssertNoThrow(try policy.validate(candidate: safeFile, analysisRoot: root))
        XCTAssertThrowsError(try policy.validate(candidate: sensitive, analysisRoot: home)) {
            XCTAssertEqual($0 as? SafeTrashError, .protectedUserPath)
        }
        XCTAssertThrowsError(try policy.validate(candidate: outside, analysisRoot: root)) {
            XCTAssertEqual($0 as? SafeTrashError, .outsideAnalysisRoot)
        }
    }

    func testSafeTrashServiceMovesOnlyValidatedItem() async throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("melo-trash-service-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }
        let root = home.appendingPathComponent("Documents/Analysis", isDirectory: true)
        let trash = home.appendingPathComponent("TestTrash", isDirectory: true)
        let file = root.appendingPathComponent("fixture.bin")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("fixture".utf8).write(to: file)
        let service = SafeTrashService(
            fileManager: fileManager,
            homeDirectory: home,
            applicationBundleURL: nil,
            testTrashDirectory: trash
        )

        let result = try await service.moveToTrash(candidatePath: file.path, analysisRoot: root.path)

        XCTAssertFalse(fileManager.fileExists(atPath: file.path))
        XCTAssertNotNil(result.trashedPath)
        XCTAssertTrue(fileManager.fileExists(atPath: result.trashedPath!))
    }

    func testSafeTrashRejectsSymbolicLinkPathsAndPackageDescendants() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("melo-trash-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: home) }
        let root = home.appendingPathComponent("Documents/Analysis", isDirectory: true)
        let sensitiveDirectory = home.appendingPathComponent(".ssh", isDirectory: true)
        let sensitiveFile = sensitiveDirectory.appendingPathComponent("id_ed25519")
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: sensitiveDirectory, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: sensitiveFile)
        let linkedDirectory = root.appendingPathComponent("linked")
        try fileManager.createSymbolicLink(at: linkedDirectory, withDestinationURL: sensitiveDirectory)
        let policy = SafeTrashPolicy(
            homeDirectory: home,
            applicationBundleURL: nil,
            fileManager: fileManager
        )

        XCTAssertThrowsError(
            try policy.validate(candidate: linkedDirectory.appendingPathComponent("id_ed25519"), analysisRoot: root)
        ) {
            XCTAssertEqual($0 as? SafeTrashError, .symbolicLink)
        }
        XCTAssertThrowsError(try policy.validate(candidate: linkedDirectory, analysisRoot: root)) {
            XCTAssertEqual($0 as? SafeTrashError, .symbolicLink)
        }

        let appContents = root.appendingPathComponent("Fixture.app/Contents", isDirectory: true)
        let appFile = appContents.appendingPathComponent("payload.bin")
        try fileManager.createDirectory(at: appContents, withIntermediateDirectories: true)
        try Data().write(to: appFile)
        XCTAssertThrowsError(try policy.validate(candidate: appFile, analysisRoot: root)) {
            XCTAssertEqual($0 as? SafeTrashError, .applicationPackage)
        }
    }

    func testHardwareProtocolRoundTripAndSafetyLimits() throws {
        let request = HardwareControlRequest(command: .setFanTarget(index: nil, rpm: 9_999))
        let decoded = try JSONDecoder().decode(
            HardwareControlRequest.self,
            from: JSONEncoder().encode(request)
        )

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(HardwareSafetyPolicy.clampedRPM(9_999, minimum: 1_200, maximum: 5_000), 5_000)
        XCTAssertEqual(HardwareSafetyPolicy.clampedRPM(100, minimum: 1_200, maximum: 5_000), 1_200)
        XCTAssertNil(HardwareSafetyPolicy.clampedRPM(.infinity, minimum: 1_200, maximum: 5_000))
        XCTAssertTrue(HardwareSafetyPolicy.isValidBatteryRange(lower: 75, upper: 80))
        XCTAssertFalse(HardwareSafetyPolicy.isValidBatteryRange(lower: 79, upper: 80))
        let fullCharge = HardwareControlRequest(command: .chargeToFull)
        XCTAssertEqual(
            try JSONDecoder().decode(HardwareControlRequest.self, from: JSONEncoder().encode(fullCharge)),
            fullCharge
        )
        XCTAssertEqual(
            HardwareSafetyPolicy.batteryChargeEvaluation(percent: 78, lower: 75, upper: 80, chargeToFull: false),
            BatteryChargeEvaluation(chargingAllowed: nil, completedChargeToFull: false)
        )
        XCTAssertEqual(
            HardwareSafetyPolicy.batteryChargeEvaluation(percent: 90, lower: 75, upper: 80, chargeToFull: true),
            BatteryChargeEvaluation(chargingAllowed: true, completedChargeToFull: false)
        )
        XCTAssertEqual(
            HardwareSafetyPolicy.batteryChargeEvaluation(percent: 100, lower: 75, upper: 80, chargeToFull: true),
            BatteryChargeEvaluation(chargingAllowed: false, completedChargeToFull: true)
        )
    }

    func testFanWatchdogRestoresOnDisconnectAndHeartbeatTimeout() {
        let heartbeat = Date(timeIntervalSince1970: 1_000)

        XCTAssertFalse(HardwareSafetyPolicy.shouldRestoreManualFans(
            hasManualFans: false,
            activeConnections: 0,
            lastHeartbeat: heartbeat,
            now: heartbeat.addingTimeInterval(30)
        ))
        XCTAssertTrue(HardwareSafetyPolicy.shouldRestoreManualFans(
            hasManualFans: true,
            activeConnections: 0,
            lastHeartbeat: heartbeat,
            now: heartbeat
        ))
        XCTAssertFalse(HardwareSafetyPolicy.shouldRestoreManualFans(
            hasManualFans: true,
            activeConnections: 1,
            lastHeartbeat: heartbeat,
            now: heartbeat.addingTimeInterval(4.999)
        ))
        XCTAssertTrue(HardwareSafetyPolicy.shouldRestoreManualFans(
            hasManualFans: true,
            activeConnections: 1,
            lastHeartbeat: heartbeat,
            now: heartbeat.addingTimeInterval(5)
        ))
        XCTAssertTrue(HardwareSafetyPolicy.shouldRestoreManualFans(
            hasManualFans: true,
            activeConnections: 1,
            lastHeartbeat: heartbeat,
            now: heartbeat,
            timeout: .nan
        ))
        XCTAssertTrue(HardwareSafetyPolicy.shouldRestoreManualFans(
            hasManualFans: true,
            activeConnections: 1,
            lastHeartbeat: heartbeat,
            now: heartbeat,
            thermalPressureIsUnsafe: true
        ))
    }

    func testHardwareClientTrustRequiresExactIdentityAndTeamOrNestedPath() {
        let expectedPath = "/Applications/Melo.app/Contents/MacOS/Melo"
        XCTAssertTrue(HardwareClientTrustPolicy.isTrusted(
            clientIdentifier: "dev.melo.companion",
            expectedIdentifier: "dev.melo.companion",
            clientTeamIdentifier: "TEAM123",
            helperTeamIdentifier: "TEAM123",
            clientExecutablePath: "/tmp/irrelevant",
            expectedAdHocExecutablePath: expectedPath
        ))
        XCTAssertFalse(HardwareClientTrustPolicy.isTrusted(
            clientIdentifier: "dev.attacker.app",
            expectedIdentifier: "dev.melo.companion",
            clientTeamIdentifier: "TEAM123",
            helperTeamIdentifier: "TEAM123",
            clientExecutablePath: expectedPath,
            expectedAdHocExecutablePath: expectedPath
        ))
        XCTAssertFalse(HardwareClientTrustPolicy.isTrusted(
            clientIdentifier: "dev.melo.companion",
            expectedIdentifier: "dev.melo.companion",
            clientTeamIdentifier: "OTHERTEAM",
            helperTeamIdentifier: "TEAM123",
            clientExecutablePath: expectedPath,
            expectedAdHocExecutablePath: expectedPath
        ))
        XCTAssertTrue(HardwareClientTrustPolicy.isTrusted(
            clientIdentifier: "dev.melo.companion",
            expectedIdentifier: "dev.melo.companion",
            clientTeamIdentifier: nil,
            helperTeamIdentifier: nil,
            clientExecutablePath: "/Applications/Melo.app/Contents/Library/../MacOS/Melo",
            expectedAdHocExecutablePath: expectedPath
        ))
        XCTAssertFalse(HardwareClientTrustPolicy.isTrusted(
            clientIdentifier: "dev.melo.companion",
            expectedIdentifier: "dev.melo.companion",
            clientTeamIdentifier: nil,
            helperTeamIdentifier: nil,
            clientExecutablePath: "/tmp/Melo",
            expectedAdHocExecutablePath: expectedPath
        ))
    }

    func testHardwareBundleTrustRequiresValidMatchingNestedSignatures() {
        XCTAssertTrue(HardwareBundleTrustPolicy.canRegisterHelper(
            appIsValid: true,
            appIdentifier: MeloHardwareProtocolInfo.appBundleIdentifier,
            appTeamIdentifier: "TEAM123",
            helperIsValid: true,
            helperIdentifier: MeloHardwareProtocolInfo.helperBundleIdentifier,
            helperTeamIdentifier: "TEAM123"
        ))
        XCTAssertFalse(HardwareBundleTrustPolicy.canRegisterHelper(
            appIsValid: true,
            appIdentifier: MeloHardwareProtocolInfo.appBundleIdentifier,
            appTeamIdentifier: "TEAM123",
            helperIsValid: true,
            helperIdentifier: MeloHardwareProtocolInfo.helperBundleIdentifier,
            helperTeamIdentifier: "OTHERTEAM"
        ))
        XCTAssertFalse(HardwareBundleTrustPolicy.canRegisterHelper(
            appIsValid: true,
            appIdentifier: MeloHardwareProtocolInfo.appBundleIdentifier,
            appTeamIdentifier: "TEAM123",
            helperIsValid: false,
            helperIdentifier: MeloHardwareProtocolInfo.helperBundleIdentifier,
            helperTeamIdentifier: "TEAM123"
        ))
        XCTAssertFalse(HardwareBundleTrustPolicy.canRegisterHelper(
            appIsValid: true,
            appIdentifier: MeloHardwareProtocolInfo.appBundleIdentifier,
            appTeamIdentifier: nil,
            helperIsValid: true,
            helperIdentifier: MeloHardwareProtocolInfo.helperBundleIdentifier,
            helperTeamIdentifier: nil
        ))
    }

    func testSMCDecoderHandlesAppleSiliconFanFloat() throws {
        let bits = Float(2_400).bitPattern
        let bytes = [
            UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff),
            UInt8((bits >> 16) & 0xff), UInt8((bits >> 24) & 0xff)
        ]
        let type = try FourCharCode.make("flt ")

        let decoded = try SMCDataDecoder.decode(key: "F0Ac", bytes: bytes, dataType: type)

        XCTAssertEqual(decoded.doubleValue, 2_400)
    }

    func testSMCFanTargetEncoderSupportsAppleSiliconFloatAndIntelFPE2() throws {
        let floatInfo = SMCKeyInfo(
            dataSize: 4,
            dataType: try FourCharCode.make("flt "),
            dataAttributes: 0
        )
        let fpe2Info = SMCKeyInfo(
            dataSize: 2,
            dataType: try FourCharCode.make("fpe2"),
            dataAttributes: 0
        )

        let floatBytes = try SMCDataEncoder.encodeFanTarget(2_400, info: floatInfo)
        let decodedFloat = try SMCDataDecoder.decode(
            key: "F0Tg",
            bytes: floatBytes,
            dataType: floatInfo.dataType
        )
        XCTAssertEqual(decodedFloat.doubleValue, 2_400)
        XCTAssertEqual(try SMCDataEncoder.encodeFanTarget(3_000, info: fpe2Info), [0x2e, 0xe0])
        XCTAssertThrowsError(try SMCDataEncoder.encodeFanTarget(.infinity, info: floatInfo))
    }

    func testSMCWriteVerifierAllowsOneRPMFloatQuantizationButRejectsLargerMismatch() throws {
        let type = try FourCharCode.make("flt ")
        let info = SMCKeyInfo(dataSize: 4, dataType: type, dataAttributes: 0)
        func bytes(_ value: Float) -> [UInt8] {
            let bits = value.bitPattern
            return [
                UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff),
                UInt8((bits >> 16) & 0xff), UInt8((bits >> 24) & 0xff)
            ]
        }

        XCTAssertTrue(SMCWriteVerifier.matches(
            expected: bytes(2_400), actual: bytes(2_399.5), key: "F0Tg", info: info
        ))
        XCTAssertFalse(SMCWriteVerifier.matches(
            expected: bytes(2_400), actual: bytes(2_350), key: "F0Tg", info: info
        ))
    }

    func testDoctorIssuesAreDeterministicAndSeveritySorted() {
        let issues = DoctorSignals.issues(for: DoctorSignals(
            moleInstalled: false,
            fullDiskAccess: .denied,
            accessibility: .granted,
            notifications: .denied,
            privacyAlertsEnabled: true,
            helperEnabled: false,
            hardwareControlAvailable: true,
            memoryUsedPercent: 92,
            diskUsedPercent: 95,
            thermalState: .critical,
            recentFailureCount: 2
        ))

        XCTAssertEqual(issues.first?.severity, .critical)
        XCTAssertTrue(issues.contains { $0.title == "Mole CLI 未连接" })
        XCTAssertTrue(issues.contains { $0.title == "硬件控制 Helper 未启用" })
        XCTAssertTrue(issues.contains { $0.title == "最近操作存在失败项" })
    }

    func testDoctorReportRedactsUserHomePath() {
        let text = DoctorPrivacy.redact(
            "Bundle: /Users/example/Applications/Melo.app",
            homeDirectory: URL(fileURLWithPath: "/Users/example")
        )
        XCTAssertEqual(text, "Bundle: ~/Applications/Melo.app")
    }

    private func stopTestProcess(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let terminateDeadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < terminateDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
        let killDeadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < killDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
    }
}

private actor LaunchctlRecorder {
    private(set) var commands: [[String]] = []

    func run(_ arguments: [String]) {
        commands.append(arguments)
    }
}
