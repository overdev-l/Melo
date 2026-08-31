import AppKit
import CoreAudio
import CoreMediaIO
import Foundation
import IOKit.pwr_mgt

enum MenuBarDisplayStyle: String, CaseIterable, Identifiable, Sendable {
    case icon
    case metrics
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .icon: "仅图标"
        case .metrics: "仅指标"
        case .both: "图标与指标"
        }
    }
}

enum MenuBarCompanion: String, CaseIterable, Identifiable, Sendable {
    case pulse
    case runner
    case cat
    case hare

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pulse: "脉搏"
        case .runner: "跑步者"
        case .cat: "猫"
        case .hare: "野兔"
        }
    }

    var systemImage: String {
        switch self {
        case .pulse: "waveform.path.ecg"
        case .runner: "figure.run"
        case .cat: "cat.fill"
        case .hare: "hare.fill"
        }
    }
}

enum KeepAwakeMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case display
    case system
    case both

    var id: String { rawValue }

    var title: String {
        switch self {
        case .display: "保持屏幕亮起"
        case .system: "保持系统运行"
        case .both: "屏幕与系统"
        }
    }

    var shortTitle: String {
        switch self {
        case .display: "屏幕"
        case .system: "系统"
        case .both: "全部"
        }
    }

    var systemImage: String {
        switch self {
        case .display: "display"
        case .system: "gearshape.2"
        case .both: "cup.and.saucer.fill"
        }
    }
}

enum KeepAwakeDuration: String, CaseIterable, Codable, Identifiable, Sendable {
    case thirtyMinutes
    case oneHour
    case twoHours
    case fourHours
    case untilStopped

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thirtyMinutes: "30 分钟"
        case .oneHour: "1 小时"
        case .twoHours: "2 小时"
        case .fourHours: "4 小时"
        case .untilStopped: "直到手动停止"
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .thirtyMinutes: 30 * 60
        case .oneHour: 60 * 60
        case .twoHours: 2 * 60 * 60
        case .fourHours: 4 * 60 * 60
        case .untilStopped: nil
        }
    }
}

struct KeepAwakeSession: Codable, Equatable, Sendable {
    let mode: KeepAwakeMode
    let startedAt: Date
    let endDate: Date?

    var isActive: Bool {
        endDate.map { $0 > Date() } ?? true
    }

    var remainingText: String {
        guard let endDate else { return "直到手动停止" }
        let remaining = max(Int(endDate.timeIntervalSinceNow), 0)
        let hours = remaining / 3600
        let minutes = (remaining % 3600) / 60
        if hours > 0 {
            return "剩余 \(hours) 小时 \(minutes) 分钟"
        }
        return "剩余 \(max(minutes, 1)) 分钟"
    }
}

enum EverydayToolError: LocalizedError {
    case powerAssertionFailed(Int32)

    var errorDescription: String? {
        switch self {
        case let .powerAssertionFailed(code):
            "无法保持 Mac 唤醒（IOKit 错误 \(code)）。"
        }
    }
}

final class PowerAssertionController: @unchecked Sendable {
    private var assertionIDs: [IOPMAssertionID] = []

    func start(mode: KeepAwakeMode) throws {
        stop()

        let types: [CFString] = switch mode {
        case .display:
            [kIOPMAssertionTypeNoDisplaySleep as CFString]
        case .system:
            [kIOPMAssertionTypePreventSystemSleep as CFString]
        case .both:
            [
                kIOPMAssertionTypeNoDisplaySleep as CFString,
                kIOPMAssertionTypePreventSystemSleep as CFString
            ]
        }

        for type in types {
            var assertionID = IOPMAssertionID(0)
            let result = IOPMAssertionCreateWithName(
                type,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Melo Keep Screen On" as CFString,
                &assertionID
            )
            guard result == kIOReturnSuccess else {
                stop()
                throw EverydayToolError.powerAssertionFailed(result)
            }
            assertionIDs.append(assertionID)
        }
    }

    func stop() {
        assertionIDs.forEach { IOPMAssertionRelease($0) }
        assertionIDs.removeAll()
    }

    deinit {
        stop()
    }
}

struct PrivacyApplication: Identifiable, Equatable, Sendable {
    let pid: pid_t
    let name: String
    let bundleIdentifier: String?

    var id: pid_t { pid }
}

struct PrivacyActivity: Equatable, Sendable {
    let microphoneApplications: [PrivacyApplication]
    let isCameraActive: Bool
    let cameraName: String?

    static let idle = PrivacyActivity(
        microphoneApplications: [],
        isCameraActive: false,
        cameraName: nil
    )

    var isActive: Bool {
        !microphoneApplications.isEmpty || isCameraActive
    }

    var summary: String {
        if isCameraActive, !microphoneApplications.isEmpty {
            return "摄像头与麦克风正在使用"
        }
        if isCameraActive {
            return cameraName.map { "\($0) 正在使用" } ?? "摄像头正在使用"
        }
        if let first = microphoneApplications.first {
            return "\(first.name) 正在使用麦克风"
        }
        return "摄像头与麦克风未在使用"
    }
}

struct PrivacyAlertDeduplicator: Equatable, Sendable {
    private(set) var lastAttemptedActivity = PrivacyActivity.idle

    mutating func shouldSchedule(activity: PrivacyActivity, alertsEnabled: Bool) -> Bool {
        guard alertsEnabled, activity.isActive else {
            if !activity.isActive { lastAttemptedActivity = .idle }
            return false
        }
        guard activity != lastAttemptedActivity else { return false }
        lastAttemptedActivity = activity
        return true
    }

    mutating func reset() {
        lastAttemptedActivity = .idle
    }
}

actor PrivacyActivityMonitor {
    func sample() -> PrivacyActivity {
        let camera = cameraActivity()
        return PrivacyActivity(
            microphoneApplications: microphoneApplications(),
            isCameraActive: camera.active,
            cameraName: camera.name
        )
    }

    private func microphoneApplications() -> [PrivacyApplication] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize
        ) == noErr, dataSize > 0 else {
            return []
        }

        var processObjects = [AudioObjectID](
            repeating: 0,
            count: Int(dataSize) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &dataSize,
            &processObjects
        ) == noErr else {
            return []
        }

        return processObjects.compactMap { objectID in
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningInput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(
                objectID,
                &runningAddress,
                0,
                nil,
                &runningSize,
                &running
            ) == noErr, running != 0 else {
                return nil
            }

            var pid = pid_t(0)
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(
                objectID,
                &pidAddress,
                0,
                nil,
                &pidSize,
                &pid
            ) == noErr, pid > 0 else {
                return nil
            }

            let application = NSRunningApplication(processIdentifier: pid)
            return PrivacyApplication(
                pid: pid,
                name: application?.localizedName ?? processName(pid: pid),
                bundleIdentifier: application?.bundleIdentifier
            )
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private func cameraActivity() -> (active: Bool, name: String?) {
        var devicesAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject),
            &devicesAddress,
            0,
            nil,
            &dataSize
        ) == noErr, dataSize > 0 else {
            return (false, nil)
        }

        var devices = [CMIOObjectID](
            repeating: 0,
            count: Int(dataSize) / MemoryLayout<CMIOObjectID>.size
        )
        guard CMIOObjectGetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &devicesAddress,
            0,
            nil,
            dataSize,
            &dataSize,
            &devices
        ) == noErr else {
            return (false, nil)
        }

        for device in devices {
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
            )
            guard CMIOObjectGetPropertyData(
                device,
                &runningAddress,
                0,
                nil,
                runningSize,
                &runningSize,
                &running
            ) == noErr, running != 0 else {
                continue
            }
            return (true, cameraName(device: device))
        }
        return (false, nil)
    }

    private func cameraName(device: CMIOObjectID) -> String? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyName),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(
            device,
            &address,
            0,
            nil,
            dataSize,
            &dataSize,
            &value
        ) == noErr else {
            return nil
        }
        return value?.takeUnretainedValue() as String?
    }

    private func processName(pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return "进程 \(pid)" }
        return String(cString: buffer)
    }
}

@MainActor
final class CleanScreenController {
    private var windows: [CleanScreenWindow] = []
    private var onStop: (() -> Void)?
    private var lockInput = true
    private var screenObserver: NSObjectProtocol?

    var isActive: Bool { !windows.isEmpty }

    @discardableResult
    func start(lockInput: Bool, onStop: @escaping () -> Void) -> Bool {
        guard windows.isEmpty else { return true }
        guard !NSScreen.screens.isEmpty else { return false }
        self.onStop = onStop
        self.lockInput = lockInput
        rebuildWindows()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildWindows() }
        }
        return !windows.isEmpty
    }

    private func rebuildWindows() {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        let pointerLocation = NSEvent.mouseLocation
        let preferredScreen = screens.first(where: { $0.frame.contains(pointerLocation) }) ?? NSScreen.main

        windows.forEach { $0.orderOut(nil) }
        windows = screens.map { screen in
            let window = CleanScreenWindow(
                contentRect: screen.frame,
                styleMask: .borderless,
                backing: .buffered,
                defer: false,
                screen: screen
            )
            window.level = .screenSaver
            window.backgroundColor = .black
            window.isOpaque = true
            window.hasShadow = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.contentView = CleanScreenContentView(
                frame: NSRect(origin: .zero, size: screen.frame.size),
                lockInput: lockInput,
                exit: { [weak self] in self?.stop() }
            )
            window.orderFrontRegardless()
            return window
        }

        NSApp.activate(ignoringOtherApps: true)
        if let preferredScreen,
           let preferredWindow = windows.first(where: { $0.screen == preferredScreen }) {
            preferredWindow.makeKeyAndOrderFront(nil)
            preferredWindow.makeFirstResponder(preferredWindow.contentView)
        } else {
            windows.first?.makeKeyAndOrderFront(nil)
            windows.first?.makeFirstResponder(windows.first?.contentView)
        }
    }

    func stop() {
        guard !windows.isEmpty else { return }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
            self.screenObserver = nil
        }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        let completion = onStop
        onStop = nil
        completion?()
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
}

private final class CleanScreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class CleanScreenContentView: NSView {
    private let lockInput: Bool
    private let exit: () -> Void
    private let hint = NSTextField(labelWithString: "按 Escape 退出清洁模式")

    init(frame frameRect: NSRect, lockInput: Bool, exit: @escaping () -> Void) {
        self.lockInput = lockInput
        self.exit = exit
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor

        hint.textColor = NSColor.white.withAlphaComponent(0.72)
        hint.font = .systemFont(ofSize: 14, weight: .medium)
        hint.alignment = .center
        hint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hint)
        NSLayoutConstraint.activate([
            hint.centerXAnchor.constraint(equalTo: centerXAnchor),
            hint.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -44)
        ])

        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak hint] in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.3
                hint?.animator().alphaValue = 0
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            exit()
        }
    }

    override func mouseDown(with event: NSEvent) {
        if !lockInput {
            exit()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        if !lockInput {
            exit()
        }
    }
}
