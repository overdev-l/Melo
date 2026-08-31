import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private let model: AppModel
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private lazy var quickMenu = makeQuickMenu()
    private var cancellable: AnyCancellable?

    init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = NSSize(width: 350, height: 620)
        popover.contentViewController = NSHostingController(rootView: MenuBarStatusView(model: model))

        if let button = statusItem.button {
            button.target = self
            button.action = #selector(handleStatusItemClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        cancellable = model.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.updateStatusItem() }
        }
        updateStatusItem()
    }

    @objc private func handleStatusItemClick() {
        let isRightClick = NSApp.currentEvent?.type == .rightMouseUp
        let shouldShowMenu = model.swapMenuBarClicks ? !isRightClick : isRightClick
        if shouldShowMenu {
            showQuickMenu()
        } else {
            togglePopover()
        }
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        if model.menuBarDisplayStyle == .metrics {
            button.image = nil
        } else {
            let symbol = model.privacyActivity.isActive
                ? "record.circle.fill"
                : model.menuBarCompanion.systemImage
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            image?.isTemplate = !model.privacyActivity.isActive
            button.image = image
            button.imagePosition = model.menuBarDisplayStyle == .both ? .imageLeading : .imageOnly
        }

        if model.menuBarDisplayStyle == .icon {
            button.title = ""
        } else if let live = model.liveSnapshot {
            var readings: [String] = []
            if model.menuBarShowsCPU {
                readings.append("CPU \(Int(live.cpuUsage.rounded()))%")
            }
            if model.menuBarShowsMemory {
                readings.append("MEM \(Int(live.memoryUsedPercent.rounded()))%")
            }
            let title = readings.isEmpty ? "Melo" : readings.joined(separator: " ")
            button.title = (model.menuBarDisplayStyle == .both ? " " : "") + title
            button.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .medium)
        } else {
            button.title = model.menuBarDisplayStyle == .both ? " …" : "…"
        }

        var accessibilityParts = ["Melo 系统监控"]
        if let live = model.liveSnapshot {
            if model.menuBarShowsCPU {
                accessibilityParts.append("CPU \(Int(live.cpuUsage.rounded()))%")
            }
            if model.menuBarShowsMemory {
                accessibilityParts.append("内存 \(Int(live.memoryUsedPercent.rounded()))%")
            }
        }
        if model.privacyActivity.isActive {
            accessibilityParts.append(model.privacyActivity.summary)
        }
        if let session = model.keepAwakeSession {
            accessibilityParts.append("保持唤醒，\(session.remainingText)")
        }
        button.setAccessibilityLabel(accessibilityParts.joined(separator: "，"))
        updateQuickMenuState()
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard !popover.isShown, let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        if model.isMoleInstalled {
            Task { await model.refreshStatus() }
        }
    }

    private func showQuickMenu() {
        popover.performClose(nil)
        updateQuickMenuState()
        statusItem.menu = quickMenu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    private func makeQuickMenu() -> NSMenu {
        let menu = NSMenu(title: "Melo")
        menu.autoenablesItems = false
        menu.addItem(item("打开 Melo", action: #selector(openMelo), key: ""))
        menu.addItem(.separator())
        menu.addItem(item("智能清理", action: #selector(openCleanup), key: ""))
        menu.addItem(item("软件", action: #selector(openSoftware), key: ""))
        menu.addItem(item("系统维护", action: #selector(openMaintenance), key: ""))
        menu.addItem(item("空间分析", action: #selector(openAnalyze), key: ""))
        menu.addItem(item("系统状态", action: #selector(openStatus), key: ""))
        menu.addItem(.separator())
        menu.addItem(item("状态栏常驻 CPU", action: #selector(toggleMenuBarCPU), key: ""))
        menu.addItem(item("状态栏常驻内存", action: #selector(toggleMenuBarMemory), key: ""))
        menu.addItem(.separator())
        menu.addItem(item("保持唤醒", action: #selector(toggleKeepAwake), key: ""))
        menu.addItem(item("清洁屏幕…", action: #selector(startCleanScreen), key: ""))
        menu.addItem(item("推出所有可移动磁盘", action: #selector(ejectAll), key: ""))
        menu.addItem(.separator())
        menu.addItem(item("退出 Melo", action: #selector(quitMelo), key: "q"))
        return menu
    }

    private func item(_ title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    private func updateQuickMenuState() {
        guard quickMenu.items.count >= 13 else { return }
        let requiresMoleIndices = [2, 3, 4, 5]
        for index in requiresMoleIndices where quickMenu.items.indices.contains(index) {
            quickMenu.items[index].isEnabled = model.isMoleInstalled
        }

        if let keepAwakeItem = quickMenu.items.first(where: { $0.action == #selector(toggleKeepAwake) }) {
            if let session = model.keepAwakeSession {
                keepAwakeItem.title = "停止保持唤醒（\(session.mode.shortTitle)）"
                keepAwakeItem.image = NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: nil)
            } else {
                keepAwakeItem.title = "保持唤醒 \(model.keepAwakeDuration.title)"
                keepAwakeItem.image = NSImage(systemSymbolName: "cup.and.saucer", accessibilityDescription: nil)
            }
        }
        if let ejectItem = quickMenu.items.first(where: { $0.action == #selector(ejectAll) }) {
            ejectItem.title = "推出所有可移动磁盘（\(model.ejectableVolumes.count)）"
            ejectItem.isEnabled = !model.ejectableVolumes.isEmpty
        }
        quickMenu.items.first(where: { $0.action == #selector(toggleMenuBarCPU) })?.state =
            model.menuBarShowsCPU ? .on : .off
        quickMenu.items.first(where: { $0.action == #selector(toggleMenuBarMemory) })?.state =
            model.menuBarShowsMemory ? .on : .off
    }

    private func open(_ destination: SidebarItem?) {
        popover.performClose(nil)
        model.openMainWindow(selection: destination)
    }

    @objc private func openMelo() { open(nil) }
    @objc private func openCleanup() { open(.cleanup) }
    @objc private func openSoftware() { open(.software) }
    @objc private func openMaintenance() { open(.maintenance) }
    @objc private func openAnalyze() { open(.storage) }
    @objc private func openStatus() { open(.status) }

    @objc private func toggleMenuBarCPU() {
        model.menuBarShowsCPU.toggle()
    }

    @objc private func toggleMenuBarMemory() {
        model.menuBarShowsMemory.toggle()
    }

    @objc private func toggleKeepAwake() {
        if model.keepAwakeSession == nil {
            model.startKeepAwake()
        } else {
            model.stopKeepAwake()
        }
    }

    @objc private func startCleanScreen() {
        popover.performClose(nil)
        model.startCleanScreen()
    }

    @objc private func ejectAll() {
        Task { await model.ejectAllVolumes() }
    }

    @objc private func quitMelo() {
        NSApp.terminate(nil)
    }
}
