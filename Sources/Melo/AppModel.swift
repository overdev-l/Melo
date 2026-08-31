import AppKit
import Darwin
import Foundation
import MeloHardwareProtocol
import ServiceManagement
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    @Published var selection: SidebarItem? = .overview
    @Published private(set) var moleExecutableURL: URL?
    @Published private(set) var moleVersion: String?
    @Published private(set) var status: MoleStatus?
    @Published private(set) var liveSnapshot: LiveSystemSnapshot?
    @Published private(set) var liveHistory = LiveMetricHistory()
    @Published private(set) var isLiveMonitoring = false
    @Published private(set) var privacyActivity = PrivacyActivity.idle
    @Published private(set) var privacyNotificationsAuthorized = false
    @Published private(set) var hardwareSnapshot: HardwareControlSnapshot?
    @Published private(set) var hardwareHelperState = HardwareHelperState.notInstalled
    @Published private(set) var isChangingHardwareControl = false
    @Published private(set) var hardwareControlMessage: String?
    @Published private(set) var keepAwakeSession: KeepAwakeSession?
    @Published private(set) var isCleanScreenActive = false
    @Published private(set) var ejectableVolumes: [URL] = []
    @Published private(set) var launchAtLoginEnabled: Bool
    @Published private(set) var terminatingProcessID: Int32?
    @Published private(set) var pinnedProcessIDs: Set<Int32>
    @Published private(set) var cleanupPreview: CleanupPreview?
    @Published private(set) var cleanupRunResult: CleanupRunResult?
    @Published private(set) var applications: [MoleApplication] = []
    @Published private(set) var softwareUpdates: [SoftwareUpdate] = []
    @Published private(set) var softwareUpdateCoverage = SoftwareUpdateCoverage.empty
    @Published private(set) var startupItems: [StartupItem] = []
    @Published private(set) var lastSoftwareUpdateCheck: Date?
    @Published private(set) var softwareOperationMessage: String?
    @Published private(set) var uninstallPreview: UninstallPreview?
    @Published private(set) var uninstallResult: UninstallResult?
    @Published private(set) var batchUninstallPreviews: [UninstallPreview] = []
    @Published private(set) var batchUninstallResults: [UninstallResult] = []
    @Published private(set) var maintenancePreview: MaintenancePreview?
    @Published private(set) var maintenanceResult: MaintenanceResult?
    @Published private(set) var cleanProtectedItems: [MoleProtectedItem] = []
    @Published private(set) var optimizeProtectedItems: [MoleProtectedItem] = []
    @Published private(set) var isLoadingProtectionSettings = false
    @Published private(set) var analysis: DiskAnalysis?
    @Published private(set) var isTrashingAnalysisEntry = false
    @Published private(set) var analysisTrashMessage: String?
    @Published private(set) var history: MoleHistory?
    @Published private(set) var doctorReport: DoctorReport?
    @Published private(set) var isRunningDoctor = false
    @Published private(set) var isBootstrapping = false
    @Published private(set) var isRefreshingStatus = false
    @Published private(set) var isScanningCleanup = false
    @Published private(set) var isCancellingCleanupScan = false
    @Published private(set) var isCleaning = false
    @Published private(set) var isCancellingCleanupRun = false
    @Published private(set) var isLoadingApplications = false
    @Published private(set) var isCheckingSoftwareUpdates = false
    @Published private(set) var isCancellingSoftwareUpdateCheck = false
    @Published private(set) var installingSoftwareUpdateID: String?
    @Published private(set) var isInstallingAllSoftwareUpdates = false
    @Published private(set) var isCancellingSoftwareInstallation = false
    @Published private(set) var softwareUpdateProgress: SoftwareUpdateProgress?
    @Published private(set) var isLoadingStartupItems = false
    @Published private(set) var changingStartupItemID: String?
    @Published private(set) var isPreviewingUninstall = false
    @Published private(set) var isUninstalling = false
    @Published private(set) var isPreviewingBatchUninstall = false
    @Published private(set) var isBatchUninstalling = false
    @Published private(set) var isScanningMaintenance = false
    @Published private(set) var isPerformingMaintenance = false
    @Published private(set) var isCancellingMaintenanceRun = false
    @Published private(set) var isAnalyzing = false
    @Published private(set) var isLoadingHistory = false
    @Published var errorMessage: String?
    @Published var analysisPath = FileManager.default.homeDirectoryForCurrentUser.path
    @Published var menuBarDisplayStyle: MenuBarDisplayStyle {
        didSet { UserDefaults.standard.set(menuBarDisplayStyle.rawValue, forKey: "menuBarDisplayStyle") }
    }
    @Published var menuBarCompanion: MenuBarCompanion {
        didSet { UserDefaults.standard.set(menuBarCompanion.rawValue, forKey: "menuBarCompanion") }
    }
    @Published var menuBarShowsCPU: Bool {
        didSet { UserDefaults.standard.set(menuBarShowsCPU, forKey: "menuBarShowsCPU") }
    }
    @Published var menuBarShowsMemory: Bool {
        didSet { UserDefaults.standard.set(menuBarShowsMemory, forKey: "menuBarShowsMemory") }
    }
    @Published var swapMenuBarClicks: Bool {
        didSet { UserDefaults.standard.set(swapMenuBarClicks, forKey: "swapMenuBarClicks") }
    }
    @Published var privacyAlertsEnabled: Bool {
        didSet { UserDefaults.standard.set(privacyAlertsEnabled, forKey: "privacyAlertsEnabled") }
    }
    @Published var keepAwakeMode: KeepAwakeMode {
        didSet { UserDefaults.standard.set(keepAwakeMode.rawValue, forKey: "keepAwakeMode") }
    }
    @Published var keepAwakeDuration: KeepAwakeDuration {
        didSet { UserDefaults.standard.set(keepAwakeDuration.rawValue, forKey: "keepAwakeDuration") }
    }
    @Published var cleanScreenLocksInput: Bool {
        didSet { UserDefaults.standard.set(cleanScreenLocksInput, forKey: "cleanScreenLocksInput") }
    }
    @Published var menuBarOnlyMode: Bool {
        didSet {
            UserDefaults.standard.set(menuBarOnlyMode, forKey: "menuBarOnlyMode")
            applyActivationPolicy()
        }
    }

    let client: MoleClient
    private let nativeSampler = NativeSystemSampler()
    private let privacyMonitor = PrivacyActivityMonitor()
    private let powerAssertionController = PowerAssertionController()
    private let cleanScreenController = CleanScreenController()
    private let softwareUpdateService = SoftwareUpdateService()
    private let startupItemService = StartupItemService()
    private let protectionService = MoleProtectionService()
    private let safeTrashService = SafeTrashService()
    private let hardwareControlCoordinator = HardwareControlCoordinator()
    private let processTerminationService = ProcessTerminationService()
    private var liveMonitoringTask: Task<Void, Never>?
    private var keepAwakeTask: Task<Void, Never>?
    private var privacyAlertDeduplicator = PrivacyAlertDeduplicator()
    private var liveSampleCount = 0
    private var cleanupScanOperationID: UUID?
    private var cleanupScanWasCancelled = false
    private var cleanupRunOperationID: UUID?
    private var cleanupRunWasCancelled = false
    private var uninstallPreviewOperationID: UUID?
    private var batchUninstallOperationID: UUID?
    private var maintenanceOperationID: UUID?
    private var maintenanceRunOperationID: UUID?
    private var analysisOperationID: UUID?
    private var softwareUpdateCheckTask: Task<SoftwareUpdateCheckResult, Error>?
    private var softwareInstallTask: Task<String, Error>?
    private var uninstallPreviewWasCancelled = false
    private var batchUninstallPreviewWasCancelled = false
    private var maintenanceScanWasCancelled = false
    private var maintenanceRunWasCancelled = false
    private var analysisWasCancelled = false
    private var hasLoadedProtectionSettings = false

    init(client: MoleClient = MoleClient()) {
        self.client = client
        let storedPins = UserDefaults.standard.array(forKey: "pinnedProcessIDs") as? [Int] ?? []
        pinnedProcessIDs = Set(storedPins.map(Int32.init))
        menuBarDisplayStyle = MenuBarDisplayStyle(
            rawValue: UserDefaults.standard.string(forKey: "menuBarDisplayStyle") ?? ""
        ) ?? .both
        menuBarCompanion = MenuBarCompanion(
            rawValue: UserDefaults.standard.string(forKey: "menuBarCompanion") ?? ""
        ) ?? .pulse
        menuBarShowsCPU = UserDefaults.standard.object(forKey: "menuBarShowsCPU") as? Bool ?? true
        menuBarShowsMemory = UserDefaults.standard.object(forKey: "menuBarShowsMemory") as? Bool ?? false
        swapMenuBarClicks = UserDefaults.standard.bool(forKey: "swapMenuBarClicks")
        privacyAlertsEnabled = UserDefaults.standard.object(forKey: "privacyAlertsEnabled") as? Bool ?? true
        keepAwakeMode = KeepAwakeMode(
            rawValue: UserDefaults.standard.string(forKey: "keepAwakeMode") ?? ""
        ) ?? .display
        keepAwakeDuration = KeepAwakeDuration(
            rawValue: UserDefaults.standard.string(forKey: "keepAwakeDuration") ?? ""
        ) ?? .oneHour
        cleanScreenLocksInput = UserDefaults.standard.object(forKey: "cleanScreenLocksInput") as? Bool ?? true
        menuBarOnlyMode = UserDefaults.standard.bool(forKey: "menuBarOnlyMode")
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    var isMoleInstalled: Bool { moleExecutableURL != nil }

    func bootstrap() async {
        guard !isBootstrapping else { return }
        isBootstrapping = true
        startLiveMonitoring()
        restoreKeepAwakeSession()
        applyActivationPolicy()
        refreshEjectableVolumes()
        refreshHardwareHelperState()
        Task { await refreshPrivacyNotificationAuthorization() }
        moleExecutableURL = client.locateExecutable()

        guard moleExecutableURL != nil else {
            isBootstrapping = false
            return
        }

        do {
            moleVersion = try await client.version()
        } catch {
            present(error)
        }

        await refreshHistory()
        isBootstrapping = false
    }

    func refreshStatus() async {
        guard isMoleInstalled, !isRefreshingStatus else { return }
        isRefreshingStatus = true
        defer { isRefreshingStatus = false }
        do {
            status = try await client.status()
        } catch {
            present(error)
        }
    }

    func startLiveMonitoring() {
        guard liveMonitoringTask == nil else { return }
        isLiveMonitoring = true
        liveMonitoringTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                async let snapshotTask = nativeSampler.sample()
                async let privacyTask = privacyMonitor.sample()
                async let hardwareTask = hardwareControlCoordinator.snapshot(
                    helperEnabled: hardwareHelperState == .enabled
                )
                let (snapshot, privacy, hardware) = await (snapshotTask, privacyTask, hardwareTask)
                liveSnapshot = snapshot
                hardwareSnapshot = hardware
                liveHistory.append(snapshot)
                updatePrivacyActivity(privacy)
                liveSampleCount += 1
                if liveSampleCount.isMultiple(of: 5) {
                    refreshHardwareHelperState()
                }
                if liveSampleCount.isMultiple(of: 10) {
                    refreshEjectableVolumes()
                }
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }
            }
            isLiveMonitoring = false
        }
    }

    func startKeepAwake() {
        do {
            try powerAssertionController.start(mode: keepAwakeMode)
            let endDate = keepAwakeDuration.seconds.map { Date().addingTimeInterval($0) }
            let session = KeepAwakeSession(mode: keepAwakeMode, startedAt: Date(), endDate: endDate)
            keepAwakeSession = session
            persistKeepAwakeSession(session)
            scheduleKeepAwakeExpiration(session)
        } catch {
            present(error)
        }
    }

    func stopKeepAwake() {
        powerAssertionController.stop()
        keepAwakeTask?.cancel()
        keepAwakeTask = nil
        keepAwakeSession = nil
        UserDefaults.standard.removeObject(forKey: "keepAwakeSession")
    }

    func startCleanScreen() {
        guard !isCleanScreenActive else { return }
        isCleanScreenActive = cleanScreenController.start(lockInput: cleanScreenLocksInput) { [weak self] in
            self?.isCleanScreenActive = false
        }
    }

    func stopCleanScreen() {
        cleanScreenController.stop()
    }

    func refreshHardwareHelperState() {
        hardwareHelperState = HardwareHelperEligibility.state()
    }

    func installHardwareHelper() {
        do {
            try HardwareHelperEligibility.register()
            refreshHardwareHelperState()
        } catch {
            present(error)
        }
    }

    func removeHardwareHelper() async {
        guard hardwareHelperState == .enabled || hardwareHelperState == .requiresApproval,
              !isChangingHardwareControl else { return }
        isChangingHardwareControl = true
        defer { isChangingHardwareControl = false }
        do {
            if hardwareHelperState == .enabled {
                _ = try await hardwareControlCoordinator.perform(.restoreFanAuto(index: nil))
                if hardwareSnapshot?.batteryCare.configuredUpperLimit != nil {
                    _ = try await hardwareControlCoordinator.perform(.stopBatteryCare)
                }
            }
            await hardwareControlCoordinator.disconnect()
            try HardwareHelperEligibility.unregister()
            refreshHardwareHelperState()
            hardwareSnapshot = await hardwareControlCoordinator.snapshot(helperEnabled: false)
            hardwareControlMessage = "风扇已交还 macOS，硬件 Helper 已注销。"
        } catch {
            await hardwareControlCoordinator.disconnect()
            refreshHardwareHelperState()
            present(error)
        }
    }

    func applyFanPreset(fraction: Double) async {
        guard hardwareHelperState == .enabled,
              let fan = hardwareSnapshot?.fans.first,
              let minimum = fan.minimumRPM,
              let maximum = fan.maximumRPM else { return }
        let target = minimum + (maximum - minimum) * min(max(fraction, 0), 1)
        await performHardwareCommand(.setFanTarget(index: nil, rpm: target))
    }

    func restoreAutomaticFans() async {
        await performHardwareCommand(.restoreFanAuto(index: nil))
    }

    func setBatteryCare(upperLimit: Int) async {
        await performHardwareCommand(.setBatteryCare(lower: max(50, upperLimit - 5), upper: upperLimit))
    }

    func chargeBatteryToFull() async {
        await performHardwareCommand(.chargeToFull)
    }

    func stopBatteryCare() async {
        await performHardwareCommand(.stopBatteryCare)
    }

    func dismissHardwareControlMessage() {
        hardwareControlMessage = nil
    }

    private func performHardwareCommand(_ command: HardwareControlCommand) async {
        guard hardwareHelperState == .enabled, !isChangingHardwareControl else { return }
        isChangingHardwareControl = true
        defer { isChangingHardwareControl = false }
        do {
            let response = try await hardwareControlCoordinator.perform(command)
            hardwareSnapshot = response.snapshot
            hardwareControlMessage = response.message
        } catch {
            present(error)
            refreshHardwareHelperState()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
        } catch {
            launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
            present(error)
        }
    }

    func openMainWindow(selection: SidebarItem? = nil) {
        if let selection {
            self.selection = selection
        }
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: { $0.canBecomeMain && $0.level == .normal })?.makeKeyAndOrderFront(nil)
    }

    func ejectAllVolumes() async {
        let volumes = ejectableVolumes
        guard !volumes.isEmpty else { return }
        for volume in volumes {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: volume)
            } catch {
                present(MoleClientError.launchFailed("无法推出 \(volume.lastPathComponent)：\(error.localizedDescription)"))
                break
            }
        }
        refreshEjectableVolumes()
    }

    func setPrivacyAlertsEnabled(_ enabled: Bool) {
        privacyAlertsEnabled = enabled
        privacyAlertDeduplicator.reset()
        if enabled {
            Task { await requestPrivacyNotificationAuthorization() }
        }
    }

    func requestPrivacyNotificationAuthorization() async {
        do {
            privacyNotificationsAuthorized = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            if privacyNotificationsAuthorized {
                privacyAlertDeduplicator.reset()
                updatePrivacyActivity(privacyActivity)
            }
        } catch {
            present(error)
        }
    }

    func refreshPrivacyNotificationAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let wasAuthorized = privacyNotificationsAuthorized
        privacyNotificationsAuthorized = settings.authorizationStatus == .authorized
            || settings.authorizationStatus == .provisional
        if privacyNotificationsAuthorized, !wasAuthorized {
            privacyAlertDeduplicator.reset()
            updatePrivacyActivity(privacyActivity)
        }
    }

    private func restoreKeepAwakeSession() {
        guard let data = UserDefaults.standard.data(forKey: "keepAwakeSession"),
              let session = try? JSONDecoder().decode(KeepAwakeSession.self, from: data),
              session.isActive else {
            UserDefaults.standard.removeObject(forKey: "keepAwakeSession")
            return
        }
        do {
            try powerAssertionController.start(mode: session.mode)
            keepAwakeSession = session
            scheduleKeepAwakeExpiration(session)
        } catch {
            UserDefaults.standard.removeObject(forKey: "keepAwakeSession")
            present(error)
        }
    }

    private func persistKeepAwakeSession(_ session: KeepAwakeSession) {
        guard let data = try? JSONEncoder().encode(session) else { return }
        UserDefaults.standard.set(data, forKey: "keepAwakeSession")
    }

    private func scheduleKeepAwakeExpiration(_ session: KeepAwakeSession) {
        keepAwakeTask?.cancel()
        guard let endDate = session.endDate else { return }
        keepAwakeTask = Task { [weak self] in
            let delay = max(endDate.timeIntervalSinceNow, 0)
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            self?.stopKeepAwake()
        }
    }

    private func updatePrivacyActivity(_ activity: PrivacyActivity) {
        privacyActivity = activity
        guard privacyAlertDeduplicator.shouldSchedule(
            activity: activity,
            alertsEnabled: privacyAlertsEnabled
        ) else { return }

        Task {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else { return }
            let content = UNMutableNotificationContent()
            content.title = "Melo 隐私提醒"
            content.body = activity.summary
            content.sound = .default
            let request = UNNotificationRequest(
                identifier: "privacy-\(UUID().uuidString)",
                content: content,
                trigger: nil
            )
            try? await UNUserNotificationCenter.current().add(request)
        }
    }

    private func refreshEjectableVolumes() {
        let keys: [URLResourceKey] = [
            .volumeIsEjectableKey,
            .volumeIsRemovableKey,
            .volumeIsInternalKey,
            .volumeLocalizedNameKey
        ]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []
        ejectableVolumes = urls.filter { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return false }
            return values.volumeIsEjectable == true
                || (values.volumeIsRemovable == true && values.volumeIsInternal != true)
        }
    }

    private func applyActivationPolicy() {
        guard NSApp != nil else { return }
        NSApp.setActivationPolicy(menuBarOnlyMode ? .accessory : .regular)
    }

    func toggleProcessPin(_ process: LiveProcess) {
        if pinnedProcessIDs.contains(process.pid) {
            pinnedProcessIDs.remove(process.pid)
        } else {
            pinnedProcessIDs.insert(process.pid)
        }
        UserDefaults.standard.set(pinnedProcessIDs.map(Int.init).sorted(), forKey: "pinnedProcessIDs")
    }

    func copyExecutablePath(_ process: LiveProcess) {
        guard let path = process.executablePath else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func terminateProcess(_ process: LiveProcess) async {
        guard process.canTerminate, terminatingProcessID == nil else { return }
        terminatingProcessID = process.pid
        defer { terminatingProcessID = nil }

        do {
            _ = try await processTerminationService.terminate(process)
        } catch {
            present(MoleClientError.launchFailed("无法终止 \(process.name)：\(error.localizedDescription)"))
        }
    }

    func scanCleanup() async {
        guard isMoleInstalled, !isScanningCleanup else { return }
        let operationID = UUID()
        cleanupScanOperationID = operationID
        cleanupScanWasCancelled = false
        isScanningCleanup = true
        cleanupRunResult = nil
        defer {
            if cleanupScanOperationID == operationID {
                cleanupScanOperationID = nil
                isScanningCleanup = false
                isCancellingCleanupScan = false
            }
        }
        do {
            let preview = try await client.previewCleanup(operationID: operationID)
            guard cleanupScanOperationID == operationID else { return }
            cleanupPreview = preview
        } catch {
            if cleanupScanOperationID == operationID, !cleanupScanWasCancelled {
                present(error)
            }
        }
    }

    func cancelCleanupScan() {
        guard let operationID = cleanupScanOperationID, isScanningCleanup else { return }
        cleanupScanWasCancelled = true
        isCancellingCleanupScan = true
        client.cancel(operationID: operationID)
    }

    func runCleanup() async {
        guard isMoleInstalled, !isCleaning else { return }
        let operationID = UUID()
        cleanupRunOperationID = operationID
        cleanupRunWasCancelled = false
        isCleaning = true
        defer {
            if cleanupRunOperationID == operationID {
                cleanupRunOperationID = nil
                isCleaning = false
                isCancellingCleanupRun = false
            }
        }
        do {
            let result = try await client.cleanUserLevelItems(operationID: operationID)
            guard cleanupRunOperationID == operationID else { return }
            cleanupRunResult = result
            cleanupPreview = nil
            await refreshHistory()
        } catch {
            if cleanupRunOperationID == operationID, !cleanupRunWasCancelled {
                present(error)
            }
        }
    }

    func cancelCleanupRun() {
        guard let cleanupRunOperationID, isCleaning else { return }
        cleanupRunWasCancelled = true
        isCancellingCleanupRun = true
        client.cancel(operationID: cleanupRunOperationID)
    }

    func loadApplications() async {
        guard isMoleInstalled, !isLoadingApplications else { return }
        isLoadingApplications = true
        defer { isLoadingApplications = false }
        do {
            applications = try await client.installedApplications()
                .sorted { ($0.sizeInBytes ?? 0) > ($1.sizeInBytes ?? 0) }
        } catch {
            present(error)
        }
    }

    func checkSoftwareUpdates() async {
        guard !isCheckingSoftwareUpdates else { return }
        isCheckingSoftwareUpdates = true
        isCancellingSoftwareUpdateCheck = false
        let service = softwareUpdateService
        let operation = Task { try await service.checkUpdates() }
        softwareUpdateCheckTask = operation
        defer {
            softwareUpdateCheckTask = nil
            isCheckingSoftwareUpdates = false
            isCancellingSoftwareUpdateCheck = false
        }
        do {
            let result = try await operation.value
            softwareUpdates = result.updates
            softwareUpdateCoverage = result.coverage
            lastSoftwareUpdateCheck = Date()
        } catch is CancellationError {
            softwareOperationMessage = "已取消软件更新检查，现有结果保持不变。"
        } catch {
            if operation.isCancelled {
                softwareOperationMessage = "已取消软件更新检查，现有结果保持不变。"
            } else {
                present(error)
            }
        }
    }

    func cancelSoftwareUpdateCheck() {
        guard let softwareUpdateCheckTask else { return }
        isCancellingSoftwareUpdateCheck = true
        softwareUpdateCheckTask.cancel()
    }

    func installSoftwareUpdate(_ update: SoftwareUpdate) async {
        guard update.canInstallDirectly, installingSoftwareUpdateID == nil else { return }
        installingSoftwareUpdateID = update.id
        defer { installingSoftwareUpdateID = nil }
        do {
            let message = try await performSoftwareInstall(update, itemIndex: 1, itemCount: 1)
            await checkSoftwareUpdates()
            softwareOperationMessage = "\(update.name)：\(message)"
        } catch is CancellationError {
            softwareOperationMessage = "已取消 \(update.name) 的更新；尚未替换的旧版本保持不变。"
        } catch {
            present(error)
        }
    }

    func installAllDirectSoftwareUpdates() async {
        guard !isInstallingAllSoftwareUpdates, installingSoftwareUpdateID == nil else { return }
        let updates = softwareUpdates.filter(\.canInstallDirectly)
        guard !updates.isEmpty else { return }
        isInstallingAllSoftwareUpdates = true
        defer {
            isInstallingAllSoftwareUpdates = false
            installingSoftwareUpdateID = nil
        }
        var installedCount = 0
        for (offset, update) in updates.enumerated() {
            installingSoftwareUpdateID = update.id
            do {
                _ = try await performSoftwareInstall(
                    update,
                    itemIndex: offset + 1,
                    itemCount: updates.count
                )
                installedCount += 1
            } catch is CancellationError {
                softwareOperationMessage = installedCount > 0
                    ? "已取消后续更新；已完成 \(installedCount) 项，其余项目未开始。"
                    : "已取消批量更新，尚未替换任何应用。"
                return
            } catch {
                present(error)
                await checkSoftwareUpdates()
                softwareOperationMessage = installedCount > 0
                    ? "已完成 \(installedCount) 项更新，其余项目因失败而停止。"
                    : nil
                return
            }
        }
        await checkSoftwareUpdates()
        softwareOperationMessage = "已完成 \(installedCount) 项更新，并重新核对了磁盘上的版本。"
    }

    func cancelSoftwareInstallation() {
        guard let softwareInstallTask else { return }
        isCancellingSoftwareInstallation = true
        softwareInstallTask.cancel()
    }

    private func performSoftwareInstall(
        _ update: SoftwareUpdate,
        itemIndex: Int,
        itemCount: Int
    ) async throws -> String {
        let service = softwareUpdateService
        isCancellingSoftwareInstallation = false
        let operation = Task<String, Error> { [weak self] in
            try await service.install(update) { phase in
                await MainActor.run {
                    self?.softwareUpdateProgress = SoftwareUpdateProgress(
                        updateID: update.id,
                        name: update.name,
                        phase: phase,
                        itemIndex: itemIndex,
                        itemCount: itemCount
                    )
                }
            }
        }
        softwareInstallTask = operation
        defer {
            softwareInstallTask = nil
            softwareUpdateProgress = nil
            isCancellingSoftwareInstallation = false
        }
        do {
            return try await operation.value
        } catch {
            if operation.isCancelled { throw CancellationError() }
            throw error
        }
    }

    func dismissSoftwareOperationMessage() {
        softwareOperationMessage = nil
    }

    func openSoftwareUpdate(_ update: SoftwareUpdate) {
        if update.source == .appStore, let releaseURL = update.releaseURL {
            NSWorkspace.shared.open(releaseURL)
        } else if update.source == .appStore,
                  let url = URL(string: "macappstore://showUpdatesPage") {
            NSWorkspace.shared.open(url)
        } else if let applicationPath = update.applicationPath {
            NSWorkspace.shared.openApplication(
                at: URL(fileURLWithPath: applicationPath),
                configuration: NSWorkspace.OpenConfiguration()
            )
        } else if let releaseURL = update.releaseURL {
            NSWorkspace.shared.open(releaseURL)
        }
    }

    func loadStartupItems() async {
        guard !isLoadingStartupItems else { return }
        isLoadingStartupItems = true
        startupItems = await startupItemService.scan()
        isLoadingStartupItems = false
    }

    func setStartupItem(_ item: StartupItem, enabled: Bool) async {
        guard changingStartupItemID == nil else { return }
        changingStartupItemID = item.id
        defer { changingStartupItemID = nil }
        do {
            try await startupItemService.setEnabled(enabled, item: item)
            startupItems = await startupItemService.scan()
        } catch {
            present(error)
        }
    }

    func openLoginItemsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    func previewUninstall(_ application: MoleApplication) async {
        guard isMoleInstalled, !isPreviewingUninstall else { return }
        let operationID = UUID()
        uninstallPreviewOperationID = operationID
        uninstallPreviewWasCancelled = false
        isPreviewingUninstall = true
        uninstallResult = nil
        defer {
            if uninstallPreviewOperationID == operationID {
                uninstallPreviewOperationID = nil
                isPreviewingUninstall = false
            }
        }
        do {
            let preview = try await client.previewUninstall(application, operationID: operationID)
            guard uninstallPreviewOperationID == operationID else { return }
            uninstallPreview = preview
        } catch {
            if uninstallPreviewOperationID == operationID, !uninstallPreviewWasCancelled {
                present(error)
            }
        }
    }

    func uninstallPreviewedApplication() async {
        guard let application = uninstallPreview?.application, !isUninstalling else { return }
        isUninstalling = true
        defer { isUninstalling = false }
        do {
            uninstallResult = try await client.uninstall(application)
            uninstallPreview = nil
            await loadApplications()
            await refreshHistory()
        } catch {
            present(error)
        }
    }

    func previewBatchUninstall(_ applications: [MoleApplication]) async {
        guard !applications.isEmpty, !isPreviewingBatchUninstall, !isBatchUninstalling else { return }
        isPreviewingBatchUninstall = true
        batchUninstallPreviewWasCancelled = false
        batchUninstallPreviews = []
        batchUninstallResults = []
        defer {
            batchUninstallOperationID = nil
            isPreviewingBatchUninstall = false
        }

        for application in applications {
            let operationID = UUID()
            batchUninstallOperationID = operationID
            do {
                let preview = try await client.previewUninstall(application, operationID: operationID)
                guard batchUninstallOperationID == operationID else { return }
                batchUninstallPreviews.append(preview)
            } catch {
                if !batchUninstallPreviewWasCancelled, !Task.isCancelled { present(error) }
                return
            }
        }
    }

    func cancelBatchUninstallPreview() {
        guard let batchUninstallOperationID else { return }
        batchUninstallPreviewWasCancelled = true
        client.cancel(operationID: batchUninstallOperationID)
        self.batchUninstallOperationID = nil
    }

    func uninstallPreviewedBatch() async {
        guard !batchUninstallPreviews.isEmpty, !isBatchUninstalling else { return }
        isBatchUninstalling = true
        batchUninstallResults = []
        defer { isBatchUninstalling = false }

        for preview in batchUninstallPreviews {
            do {
                let result = try await client.uninstall(preview.application)
                batchUninstallResults.append(result)
            } catch {
                present(error)
                break
            }
        }
        batchUninstallPreviews = []
        await loadApplications()
        await refreshHistory()
    }

    func dismissBatchUninstall() {
        cancelBatchUninstallPreview()
        guard !isBatchUninstalling else { return }
        batchUninstallPreviews = []
        batchUninstallResults = []
    }

    func dismissUninstallPreview() {
        if let operationID = uninstallPreviewOperationID {
            uninstallPreviewWasCancelled = true
            client.cancel(operationID: operationID)
        }
        uninstallPreview = nil
    }

    func scanMaintenance() async {
        guard isMoleInstalled, !isScanningMaintenance else { return }
        let operationID = UUID()
        maintenanceOperationID = operationID
        maintenanceScanWasCancelled = false
        isScanningMaintenance = true
        maintenanceResult = nil
        defer {
            if maintenanceOperationID == operationID {
                maintenanceOperationID = nil
                isScanningMaintenance = false
            }
        }
        do {
            let preview = try await client.previewMaintenance(operationID: operationID)
            guard maintenanceOperationID == operationID else { return }
            maintenancePreview = preview
        } catch {
            if maintenanceOperationID == operationID, !maintenanceScanWasCancelled {
                present(error)
            }
        }
    }

    func cancelMaintenanceScan() {
        guard let maintenanceOperationID else { return }
        maintenanceScanWasCancelled = true
        client.cancel(operationID: maintenanceOperationID)
    }

    func performMaintenance() async {
        guard !isPerformingMaintenance else { return }
        let operationID = UUID()
        maintenanceRunOperationID = operationID
        maintenanceRunWasCancelled = false
        isPerformingMaintenance = true
        defer {
            if maintenanceRunOperationID == operationID {
                maintenanceRunOperationID = nil
                isPerformingMaintenance = false
                isCancellingMaintenanceRun = false
            }
        }
        do {
            let result = try await client.performMaintenance(operationID: operationID)
            guard maintenanceRunOperationID == operationID else { return }
            maintenanceResult = result
            maintenancePreview = nil
            await refreshHistory()
        } catch {
            if maintenanceRunOperationID == operationID, !maintenanceRunWasCancelled {
                present(error)
            }
        }
    }

    func cancelMaintenanceRun() {
        guard let maintenanceRunOperationID, isPerformingMaintenance else { return }
        maintenanceRunWasCancelled = true
        isCancellingMaintenanceRun = true
        client.cancel(operationID: maintenanceRunOperationID)
    }

    func protectedItems(for scope: MoleProtectionScope) -> [MoleProtectedItem] {
        switch scope {
        case .clean: cleanProtectedItems
        case .optimize: optimizeProtectedItems
        }
    }

    func loadProtectionSettingsIfNeeded() async {
        guard !hasLoadedProtectionSettings else { return }
        await loadProtectionSettings()
    }

    func loadProtectionSettings() async {
        guard !isLoadingProtectionSettings else { return }
        isLoadingProtectionSettings = true
        defer { isLoadingProtectionSettings = false }
        do {
            async let clean = protectionService.load(scope: .clean)
            async let optimize = protectionService.load(scope: .optimize)
            let (cleanItems, optimizeItems) = try await (clean, optimize)
            cleanProtectedItems = cleanItems
            optimizeProtectedItems = optimizeItems
            hasLoadedProtectionSettings = true
        } catch {
            present(error)
        }
    }

    func addProtectedPattern(_ pattern: String, scope: MoleProtectionScope) async {
        do {
            let items = try await protectionService.add(pattern, scope: scope)
            setProtectedItems(items, scope: scope)
            invalidatePreview(for: scope)
            hasLoadedProtectionSettings = true
        } catch {
            present(error)
        }
    }

    func removeProtectedItem(_ item: MoleProtectedItem, scope: MoleProtectionScope) async {
        do {
            let items = try await protectionService.remove(item.pattern, scope: scope)
            setProtectedItems(items, scope: scope)
            invalidatePreview(for: scope)
        } catch {
            present(error)
        }
    }

    func chooseProtectedPath(scope: MoleProtectionScope) {
        let panel = NSOpenPanel()
        panel.title = scope == .clean ? "选择清理保护项" : "选择维护排除路径"
        panel.prompt = "保护"
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                let pattern = await protectionService.pattern(for: url)
                await addProtectedPattern(pattern, scope: scope)
            }
        }
    }

    private func setProtectedItems(_ items: [MoleProtectedItem], scope: MoleProtectionScope) {
        switch scope {
        case .clean: cleanProtectedItems = items
        case .optimize: optimizeProtectedItems = items
        }
    }

    private func invalidatePreview(for scope: MoleProtectionScope) {
        switch scope {
        case .clean: cleanupPreview = nil
        case .optimize: maintenancePreview = nil
        }
    }

    func analyzeSelectedPath() async {
        guard isMoleInstalled, !isAnalyzing, !analysisPath.isEmpty else { return }
        let operationID = UUID()
        let requestedPath = analysisPath
        analysisOperationID = operationID
        analysisWasCancelled = false
        isAnalyzing = true
        defer {
            if analysisOperationID == operationID {
                analysisOperationID = nil
                isAnalyzing = false
            }
        }
        do {
            let result = try await client.analyze(path: requestedPath, operationID: operationID)
            guard analysisOperationID == operationID, analysisPath == requestedPath else { return }
            analysis = result
        } catch {
            if analysisOperationID == operationID, !analysisWasCancelled {
                present(error)
            }
        }
    }

    func analyze(path: String) async {
        analysisPath = path
        analysis = nil
        await analyzeSelectedPath()
    }

    func analyzeParentFolder() async {
        let currentURL = URL(fileURLWithPath: analysisPath)
        let parentURL = currentURL.deletingLastPathComponent()
        guard parentURL.path != currentURL.path else { return }
        await analyze(path: parentURL.path)
    }

    func cancelAnalysis() {
        guard let analysisOperationID else { return }
        analysisWasCancelled = true
        client.cancel(operationID: analysisOperationID)
    }

    func analysisTrashProtectionReason(for entry: AnalysisEntry) -> String? {
        safeTrashService.protectionReason(
            candidatePath: entry.path,
            analysisRoot: analysis?.path ?? analysisPath
        )
    }

    func trashAnalysisEntry(_ entry: AnalysisEntry) async {
        guard !isTrashingAnalysisEntry, let currentAnalysis = analysis else { return }
        isTrashingAnalysisEntry = true
        analysisTrashMessage = nil
        defer { isTrashingAnalysisEntry = false }
        do {
            _ = try await safeTrashService.moveToTrash(
                candidatePath: entry.path,
                analysisRoot: currentAnalysis.path
            )
            analysisTrashMessage = "\(entry.name) 已移到废纸篓，可在访达中恢复。"
            analysis = try await client.analyze(path: currentAnalysis.path)
        } catch {
            present(error)
        }
    }

    func dismissAnalysisTrashMessage() {
        analysisTrashMessage = nil
    }

    func chooseAnalysisFolder() {
        guard !isAnalyzing else { return }
        let panel = NSOpenPanel()
        panel.title = "选择要分析的文件夹"
        panel.prompt = "选择文件夹"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: analysisPath)
        if panel.runModal() == .OK, let url = panel.url {
            analysisPath = url.path
            analysis = nil
        }
    }

    func refreshHistory() async {
        guard isMoleInstalled, !isLoadingHistory else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        do {
            history = try await client.history()
        } catch {
            present(error)
        }
    }

    func runDoctor() async {
        guard !isRunningDoctor else { return }
        isRunningDoctor = true
        defer { isRunningDoctor = false }
        if isMoleInstalled, status == nil {
            await refreshStatus()
        }
        if isMoleInstalled, history == nil {
            await refreshHistory()
        }
        if !hasLoadedProtectionSettings {
            await loadProtectionSettings()
        }
        doctorReport = await DoctorService.run(context: DoctorContext(
            live: liveSnapshot,
            status: status,
            hardware: hardwareSnapshot,
            history: history,
            moleURL: moleExecutableURL,
            moleVersion: moleVersion,
            helperState: hardwareHelperState,
            launchAtLogin: launchAtLoginEnabled,
            menuBarOnly: menuBarOnlyMode,
            privacyAlerts: privacyAlertsEnabled,
            cleanProtectedCount: cleanProtectedItems.count,
            optimizeProtectedCount: optimizeProtectedItems.count
        ))
    }

    func copyDoctorReport() {
        guard let report = doctorReport else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.plainText, forType: .string)
    }

    func openSystemSettings(_ target: SystemSettingsTarget) {
        openURL(target.urlString)
    }

    func revealInFinder(path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }

    func dismissError() {
        errorMessage = nil
    }

    private func present(_ error: Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
