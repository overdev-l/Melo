import AppKit
import SwiftUI

struct SoftwareView: View {
    @ObservedObject var model: AppModel
    @State private var page: SoftwarePage = .updates
    @State private var query = ""
    @State private var sort: ApplicationSort = .size
    @State private var selectedApplication: MoleApplication?
    @State private var selectedApplicationIDs = Set<String>()
    @State private var showBatchReview = false
    @State private var proposedUpdate: SoftwareUpdate?
    @State private var showUpdateAllConfirmation = false
    @State private var proposedStartupChange: StartupChange?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    title: "软件",
                    subtitle: page.subtitle,
                    actionTitle: pageActionTitle,
                    actionIcon: "arrow.clockwise",
                    isWorking: pageIsWorking,
                    action: pageAction
                )

                if let error = model.errorMessage {
                    ErrorBanner(message: error, dismiss: model.dismissError)
                }
                if let message = model.softwareOperationMessage {
                    HStack(spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(MeloTheme.safeGreen)
                        Text(message)
                            .font(.callout)
                            .textSelection(.enabled)
                        Spacer()
                        Button("关闭", action: model.dismissSoftwareOperationMessage)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(MeloTheme.safeGreen.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                }
                if page == .updates,
                   model.isCheckingSoftwareUpdates,
                   !model.softwareUpdates.isEmpty {
                    softwareCheckBanner
                }
                if page == .updates, let progress = model.softwareUpdateProgress {
                    softwareInstallBanner(progress)
                }

                Picker("软件功能", selection: $page) {
                    ForEach(SoftwarePage.allCases) { page in
                        Label(page.title, systemImage: page.systemImage).tag(page)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 520)

                switch page {
                case .updates:
                    updatesPage
                case .startup:
                    startupPage
                case .uninstall:
                    uninstallPage
                }
            }
            .padding(28)
            .frame(maxWidth: 1120, alignment: .leading)
        }
        .sheet(item: $selectedApplication, onDismiss: model.dismissUninstallPreview) { application in
            UninstallReviewView(model: model, application: application)
                .frame(minWidth: 680, minHeight: 560)
                .task {
                    await model.previewUninstall(application)
                }
        }
        .sheet(isPresented: $showBatchReview, onDismiss: {
            model.dismissBatchUninstall()
            if !model.batchUninstallResults.isEmpty {
                selectedApplicationIDs.removeAll()
            }
        }) {
            BatchUninstallReviewView(model: model, applications: selectedBatchApplications)
                .frame(minWidth: 760, minHeight: 620)
        }
        .task(id: page) {
            switch page {
            case .updates:
                break
            case .startup:
                if model.startupItems.isEmpty { await model.loadStartupItems() }
            case .uninstall:
                if model.applications.isEmpty { await model.loadApplications() }
            }
        }
        .confirmationDialog(
            proposedUpdate.map { "更新 \($0.name)？" } ?? "安装更新？",
            isPresented: Binding(
                get: { proposedUpdate != nil },
                set: { if !$0 { proposedUpdate = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let proposedUpdate {
                Button("安装 \(proposedUpdate.availableVersion)") {
                    Task { await model.installSoftwareUpdate(proposedUpdate) }
                    self.proposedUpdate = nil
                }
                Button("取消", role: .cancel) { self.proposedUpdate = nil }
            }
        } message: {
            if let proposedUpdate {
                Text(proposedUpdate.verifiedPackage == nil
                    ? "Melo 将通过 Homebrew 把 \(proposedUpdate.installedVersion) 更新到 \(proposedUpdate.availableVersion)。应用可能需要重新启动。"
                    : "Melo 会从应用声明的 HTTPS 地址下载 ZIP，核对 SHA-512、Bundle ID 和签名团队，要求应用正常退出后再原位替换；任一验证失败都会保留旧版本。")
            }
        }
        .confirmationDialog(
            "安装所有可直接更新的项目？",
            isPresented: $showUpdateAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("依次安装 \(directUpdateCount) 项更新") {
                Task { await model.installAllDirectSoftwareUpdates() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("Melo 会依次使用 Homebrew 或经过三重验证的应用包。某一项失败时会停止，其余未开始的项目保持不变。")
        }
        .confirmationDialog(
            proposedStartupChange?.title ?? "更改启动项？",
            isPresented: Binding(
                get: { proposedStartupChange != nil },
                set: { if !$0 { proposedStartupChange = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let change = proposedStartupChange {
                Button(change.enabled ? "启用启动项" : "停用并保留文件") {
                    Task { await model.setStartupItem(change.item, enabled: change.enabled) }
                    proposedStartupChange = nil
                }
                Button("取消", role: .cancel) { proposedStartupChange = nil }
            }
        } message: {
            if let change = proposedStartupChange {
                Text(change.enabled
                    ? "文件会移回 LaunchAgents 并由 launchd 载入。"
                    : "正在运行的后台任务会停止，配置文件会移到用户级 Disabled 文件夹，可随时恢复。")
            }
        }
    }

    private var pageActionTitle: String {
        switch page {
        case .updates: model.lastSoftwareUpdateCheck == nil ? "检查更新" : "重新检查"
        case .startup: "刷新启动项"
        case .uninstall: "刷新应用"
        }
    }

    private var pageIsWorking: Bool {
        switch page {
        case .updates: model.isCheckingSoftwareUpdates
        case .startup: model.isLoadingStartupItems
        case .uninstall: model.isLoadingApplications
        }
    }

    private var pageAction: () -> Void {
        {
            Task {
                switch page {
                case .updates: await model.checkSoftwareUpdates()
                case .startup: await model.loadStartupItems()
                case .uninstall: await model.loadApplications()
                }
            }
        }
    }

    @ViewBuilder
    private var updatesPage: some View {
        if model.isCheckingSoftwareUpdates && model.softwareUpdates.isEmpty {
            WorkingStateView(
                title: "正在检查软件更新",
                message: "Melo 正在原生枚举应用，并检查 App Store、Sparkle、Electron 与 Homebrew 更新源。",
                cancelTitle: "取消检查",
                isCancelling: model.isCancellingSoftwareUpdateCheck,
                cancelAction: model.cancelSoftwareUpdateCheck
            )
        } else if model.lastSoftwareUpdateCheck == nil {
            EmptyStateView(
                systemImage: "arrow.triangle.2.circlepath",
                title: "检查可用更新",
                message: "检查由你主动开始。本机应用与 Homebrew 信息不会上传；联网部分只访问 Apple 或各应用声明的官方更新源。",
                buttonTitle: "检查软件更新",
                buttonIcon: "magnifyingglass",
                action: { Task { await model.checkSoftwareUpdates() } }
            )
        } else if model.softwareUpdates.isEmpty {
            SectionSurface {
                Label("当前没有发现可用更新", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(MeloTheme.safeGreen)
                Text("检查了可用的 Sparkle 与 Homebrew 更新源。App Store 更新仍由 macOS 管理。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("打开 App Store 更新") {
                    model.openURL("macappstore://showUpdatesPage")
                }
                .buttonStyle(.bordered)
            }
            updateCoverageSummary
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("发现 \(model.softwareUpdates.count) 项更新")
                        .font(.headline)
                    if let date = model.lastSoftwareUpdateCheck {
                        Text("检查于 \(date.formatted(date: .omitted, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("打开 App Store 更新") {
                    model.openURL("macappstore://showUpdatesPage")
                }
                .buttonStyle(.bordered)
                if directUpdateCount > 0 {
                    Button("更新全部（\(directUpdateCount)）") {
                        showUpdateAllConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MeloTheme.brandRose)
                    .disabled(model.isInstallingAllSoftwareUpdates || model.installingSoftwareUpdateID != nil)
                }
            }

            updateCoverageSummary

            updateGroup("应用更新", updates: model.softwareUpdates.filter { $0.source != .homebrewFormula })
            updateGroup("命令行工具", updates: model.softwareUpdates.filter { $0.source == .homebrewFormula })
        }
    }

    @ViewBuilder
    private func updateGroup(_ title: String, updates: [SoftwareUpdate]) -> some View {
        if !updates.isEmpty {
            SectionSurface(title) {
                LazyVStack(spacing: 0) {
                    ForEach(updates) { update in
                        if update.id != updates.first?.id { Divider() }
                        updateRow(update)
                    }
                }
            }
        }
    }

    private func updateRow(_ update: SoftwareUpdate) -> some View {
        HStack(spacing: 12) {
            Image(systemName: update.source.systemImage)
                .foregroundStyle(update.source == .homebrewFormula ? Color.secondary : MeloTheme.brandRose)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(update.name).font(.callout.weight(.medium)).lineLimit(1)
                Text("\(update.installedVersion)  →  \(update.availableVersion) · \(update.source.title)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            if model.installingSoftwareUpdateID == update.id {
                ProgressView().controlSize(.small)
            } else if update.canInstallDirectly {
                Button("更新") { proposedUpdate = update }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.installingSoftwareUpdateID != nil || model.isInstallingAllSoftwareUpdates)
            } else {
                Button(update.source == .appStore ? "前往 App Store" : "打开应用更新") {
                    model.openSoftwareUpdate(update)
                }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(.vertical, 9)
    }

    private var softwareCheckBanner: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("正在重新检查软件更新").font(.callout.weight(.semibold))
                Text("现有结果仍可查看；完成后会按磁盘上的实际版本刷新。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(model.isCancellingSoftwareUpdateCheck ? "正在取消…" : "取消") {
                model.cancelSoftwareUpdateCheck()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isCancellingSoftwareUpdateCheck)
        }
        .padding(12)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private func softwareInstallBanner(_ progress: SoftwareUpdateProgress) -> some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(progress.name).font(.callout.weight(.semibold))
                    if let summary = progress.itemSummary {
                        Text(summary).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(progress.phase.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(model.isCancellingSoftwareInstallation ? "正在取消…" : "取消更新") {
                model.cancelSoftwareInstallation()
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isCancellingSoftwareInstallation || progress.phase == .installing)
            .help(progress.phase == .installing ? "原位替换期间不能中断，以保证可回滚" : "停止当前步骤，其余项目不会开始")
        }
        .padding(12)
        .background(MeloTheme.brandRose.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(progress.name)，\(progress.phase.title)")
    }

    private var updateCoverageSummary: some View {
        SectionSurface("本次检查范围") {
            HStack(spacing: 8) {
                StatusBadge(
                    title: "\(model.softwareUpdateCoverage.applicationsScanned) 个应用",
                    systemImage: "square.stack.3d.up",
                    color: .blue
                )
                StatusBadge(
                    title: "Sparkle \(model.softwareUpdateCoverage.sparkleFeedsChecked)",
                    systemImage: "sparkles",
                    color: .purple
                )
                StatusBadge(
                    title: "Electron \(model.softwareUpdateCoverage.electronFeedsChecked)",
                    systemImage: "bolt.horizontal.circle",
                    color: MeloTheme.brandRose
                )
                StatusBadge(
                    title: "App Store \(model.softwareUpdateCoverage.appStoreAppsChecked)",
                    systemImage: "apple.logo",
                    color: MeloTheme.safeGreen
                )
                Spacer()
            }
            if !model.softwareUpdateCoverage.unsupportedElectronApps.isEmpty {
                DisclosureGroup("\(model.softwareUpdateCoverage.unsupportedElectronApps.count) 个应用使用自定义更新器") {
                    Text(model.softwareUpdateCoverage.unsupportedElectronApps.joined(separator: "、"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .padding(.top, 6)
                }
                .font(.caption)
            }
        }
    }

    @ViewBuilder
    private var startupPage: some View {
        if model.isLoadingStartupItems && model.startupItems.isEmpty {
            WorkingStateView(title: "正在读取启动项", message: "Melo 正在检查用户和系统 LaunchAgents、LaunchDaemons。")
        } else {
            SectionSurface {
                HStack(spacing: 12) {
                    Image(systemName: "gearshape.arrow.triangle.2.circlepath")
                        .font(.title3)
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("macOS 登录项与后台扩展").font(.callout.weight(.semibold))
                        Text("由应用注册的现代后台项目继续在系统设置中管理。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("打开系统设置") { model.openLoginItemsSettings() }
                        .buttonStyle(.bordered)
                }
            }

            if model.startupItems.isEmpty {
                EmptyStateView(
                    systemImage: "power",
                    title: "没有发现传统启动项",
                    message: "用户和系统 LaunchAgents、LaunchDaemons 文件夹中没有可显示的项目。",
                    buttonTitle: "重新扫描",
                    buttonIcon: "arrow.clockwise",
                    action: { Task { await model.loadStartupItems() } }
                )
            } else {
                SectionSurface("启动项（\(model.startupItems.count)）") {
                    LazyVStack(spacing: 0) {
                        ForEach(model.startupItems) { item in
                            if item.id != model.startupItems.first?.id { Divider() }
                            startupRow(item)
                        }
                    }
                }
            }
        }
    }

    private func startupRow(_ item: StartupItem) -> some View {
        HStack(spacing: 12) {
            Image(systemName: item.kind == .systemDaemon ? "gearshape.2.fill" : "bolt.horizontal.circle")
                .foregroundStyle(item.isEnabled ? MeloTheme.safeGreen : Color.secondary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName).font(.callout.weight(.medium)).lineLimit(1)
                Text(item.label).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            StatusBadge(
                title: item.kind.title,
                systemImage: item.canToggleDirectly ? "person" : "lock.fill",
                color: item.canToggleDirectly ? .blue : .secondary
            )
            Button {
                model.revealInFinder(path: item.path)
            } label: {
                Image(systemName: "arrow.forward.square")
            }
            .buttonStyle(.plain)
            .help("在访达中显示")
            .accessibilityLabel("在访达中显示 \(item.displayName)")
            if model.changingStartupItemID == item.id {
                ProgressView().controlSize(.small).frame(width: 58)
            } else if item.canToggleDirectly {
                Button(item.isEnabled ? "停用" : "启用") {
                    proposedStartupChange = StartupChange(item: item, enabled: !item.isEnabled)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(width: 58)
                .accessibilityLabel("\(item.isEnabled ? "停用" : "启用") \(item.displayName)")
            } else {
                Text("只读")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 58)
            }
        }
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var uninstallPage: some View {
        if model.isLoadingApplications && model.applications.isEmpty {
            WorkingStateView(title: "正在读取应用", message: "Mole 正在统计应用大小和安装来源。")
        } else if model.applications.isEmpty {
            EmptyStateView(
                systemImage: "square.stack.3d.up",
                title: "读取已安装应用",
                message: "应用清单来自 mo uninstall --list，不会修改任何文件。若应用位于外置磁盘，macOS 可能询问访问权限。",
                buttonTitle: "扫描应用",
                buttonIcon: "magnifyingglass",
                action: { Task { await model.loadApplications() } }
            )
        } else {
            controls
            applicationList
        }
    }

    private var directUpdateCount: Int {
        model.softwareUpdates.filter(\.canInstallDirectly).count
    }

    private var controls: some View {
        HStack(spacing: 12) {
            TextField("搜索应用", text: $query)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 340)
            Picker("排序", selection: $sort) {
                ForEach(ApplicationSort.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            Spacer()
            Text("\(filteredApplications.count) 个应用")
                .font(.caption)
                .foregroundStyle(.secondary)
            if !selectedApplicationIDs.isEmpty {
                Button("批量检查（\(selectedApplicationIDs.count)）") {
                    showBatchReview = true
                }
                .buttonStyle(.borderedProminent)
                .tint(MeloTheme.brandRose)
            }
        }
    }

    private var applicationList: some View {
        SectionSurface {
            LazyVStack(spacing: 0) {
                HStack {
                    Button(allFilteredApplicationsSelected ? "取消全选" : "选择当前") {
                        toggleAllFilteredApplications()
                    }
                    .buttonStyle(.plain)
                    .frame(width: 72, alignment: .leading)
                    Text("应用").frame(maxWidth: .infinity, alignment: .leading)
                    Text("来源").frame(width: 90, alignment: .leading)
                    Text("大小").frame(width: 90, alignment: .trailing)
                    Color.clear.frame(width: 104)
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

                ForEach(filteredApplications) { application in
                    Divider()
                    applicationRow(application)
                }
            }
        }
    }

    private func applicationRow(_ application: MoleApplication) -> some View {
        HStack(spacing: 12) {
            Button {
                toggleApplicationSelection(application)
            } label: {
                Image(systemName: selectedApplicationIDs.contains(application.id) ? "checkmark.square.fill" : "square")
                    .foregroundStyle(selectedApplicationIDs.contains(application.id) ? MeloTheme.brandRose : Color.secondary)
            }
            .buttonStyle(.plain)
            .help(selectedApplicationIDs.contains(application.id) ? "取消选择" : "选择用于批量卸载")
            .accessibilityLabel(
                selectedApplicationIDs.contains(application.id)
                    ? "取消选择 \(application.name)"
                    : "选择 \(application.name) 用于批量卸载"
            )
            AppIcon(path: application.path, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(application.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(application.bundleID == "unknown" ? application.path : application.bundleID)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(application.source == "Homebrew" ? "Homebrew" : "应用")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 90, alignment: .leading)

            Text(application.size)
                .font(.system(.callout, design: .rounded))
                .monospacedDigit()
                .frame(width: 90, alignment: .trailing)

            HStack(spacing: 9) {
                Button {
                    model.revealInFinder(path: application.path)
                } label: {
                    Image(systemName: "arrow.forward.square")
                }
                .buttonStyle(.plain)
                .help("在访达中显示")
                .accessibilityLabel("在访达中显示 \(application.name)")

                Button("检查卸载") {
                    selectedApplication = application
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("检查 \(application.name) 的卸载项目")
            }
            .frame(width: 104, alignment: .trailing)
        }
        .padding(.vertical, 9)
    }

    private var filteredApplications: [MoleApplication] {
        let filtered = model.applications.filter {
            query.isEmpty
                || $0.name.localizedCaseInsensitiveContains(query)
                || $0.bundleID.localizedCaseInsensitiveContains(query)
        }
        switch sort {
        case .size:
            return filtered.sorted { ($0.sizeInBytes ?? 0) > ($1.sizeInBytes ?? 0) }
        case .name:
            return filtered.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private var selectedBatchApplications: [MoleApplication] {
        model.applications.filter { selectedApplicationIDs.contains($0.id) }
    }

    private var allFilteredApplicationsSelected: Bool {
        !filteredApplications.isEmpty
            && filteredApplications.allSatisfy { selectedApplicationIDs.contains($0.id) }
    }

    private func toggleApplicationSelection(_ application: MoleApplication) {
        if selectedApplicationIDs.contains(application.id) {
            selectedApplicationIDs.remove(application.id)
        } else {
            selectedApplicationIDs.insert(application.id)
        }
    }

    private func toggleAllFilteredApplications() {
        if allFilteredApplicationsSelected {
            filteredApplications.forEach { selectedApplicationIDs.remove($0.id) }
        } else {
            filteredApplications.forEach { selectedApplicationIDs.insert($0.id) }
        }
    }
}

private enum ApplicationSort: String, CaseIterable, Identifiable {
    case size
    case name

    var id: String { rawValue }
    var title: String { self == .size ? "按大小" : "按名称" }
}

private enum SoftwarePage: String, CaseIterable, Identifiable {
    case updates
    case startup
    case uninstall

    var id: String { rawValue }

    var title: String {
        switch self {
        case .updates: "更新"
        case .startup: "启动项"
        case .uninstall: "卸载"
        }
    }

    var subtitle: String {
        switch self {
        case .updates: "检查 Sparkle、Homebrew 与 App Store 来源，再由你决定是否安装。"
        case .startup: "区分可直接控制、由系统设置管理和只读的后台项目。"
        case .uninstall: "查看应用占用，预览关联文件，再通过 Mole 移到废纸篓。"
        }
    }

    var systemImage: String {
        switch self {
        case .updates: "arrow.triangle.2.circlepath"
        case .startup: "power"
        case .uninstall: "trash"
        }
    }
}

private struct StartupChange {
    let item: StartupItem
    let enabled: Bool

    var title: String {
        enabled ? "启用 \(item.displayName)？" : "停用 \(item.displayName)？"
    }
}

private struct AppIcon: View {
    let path: String
    let size: CGFloat

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: path))
            .resizable()
            .aspectRatio(contentMode: .fit)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

private struct BatchUninstallReviewView: View {
    @ObservedObject var model: AppModel
    let applications: [MoleApplication]
    @Environment(\.dismiss) private var dismiss
    @State private var showConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("批量卸载检查")
                        .font(.title2.weight(.semibold))
                    Text("\(applications.count) 个应用，先汇总每一项的关联文件")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.bordered)
                    .disabled(model.isPreviewingBatchUninstall || model.isBatchUninstalling)
            }

            Divider()

            if model.isPreviewingBatchUninstall {
                WorkingStateView(
                    title: "正在逐项检查关联文件",
                    message: "已经完成 \(model.batchUninstallPreviews.count) / \(applications.count)。共享数据和无法确认归属的内容会保留。",
                    cancelTitle: "停止检查",
                    cancelAction: model.cancelBatchUninstallPreview
                )
            } else if model.isBatchUninstalling {
                WorkingStateView(
                    title: "正在移到废纸篓",
                    message: "已经完成 \(model.batchUninstallResults.count) / \(applications.count)。如果某一项失败，后续项目不会开始。"
                )
            } else if !model.batchUninstallResults.isEmpty {
                VStack(spacing: 14) {
                    Image(systemName: model.batchUninstallResults.count == applications.count
                        ? "checkmark.circle.fill"
                        : "exclamationmark.circle.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(model.batchUninstallResults.count == applications.count
                            ? MeloTheme.safeGreen
                            : MeloTheme.warningAmber)
                    Text(model.batchUninstallResults.count == applications.count ? "批量卸载已完成" : "已完成部分卸载")
                        .font(.title3.weight(.semibold))
                    Text("\(model.batchUninstallResults.count) 个应用已移到废纸篓，可在清空废纸篓前恢复。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if let error = model.errorMessage {
                        ErrorBanner(message: error, dismiss: model.dismissError)
                    }
                    Button("完成") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .tint(MeloTheme.brandRose)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.batchUninstallPreviews.count == applications.count {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("检查完成").font(.headline)
                        Text("\(applications.count) 个应用，\(uniquePathCount) 个不重复路径")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Label("默认移到废纸篓", systemImage: "arrow.uturn.backward.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.batchUninstallPreviews, id: \.application.id) { preview in
                            DisclosureGroup {
                                VStack(alignment: .leading, spacing: 7) {
                                    ForEach(Array(preview.paths.enumerated()), id: \.offset) { _, path in
                                        Text(path)
                                            .font(.system(.caption2, design: .monospaced))
                                            .textSelection(.enabled)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .padding(.top, 8)
                            } label: {
                                HStack(spacing: 10) {
                                    AppIcon(path: preview.application.path, size: 28)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(preview.application.name).font(.callout.weight(.medium))
                                        Text("\(preview.paths.count) 个路径 · \(preview.summary)")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                            }
                            .padding(12)
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }

                HStack {
                    Text("执行前会再次验证应用与关联文件是否仍与预览一致。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("将 \(applications.count) 个应用移到废纸篓") {
                        showConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MeloTheme.brandRose)
                }
            } else if let error = model.errorMessage {
                ErrorBanner(message: error, dismiss: model.dismissError)
            }
        }
        .padding(24)
        .task {
            if model.batchUninstallPreviews.isEmpty, model.batchUninstallResults.isEmpty {
                await model.previewBatchUninstall(applications)
            }
        }
        .confirmationDialog(
            "卸载 \(applications.count) 个应用？",
            isPresented: $showConfirmation,
            titleVisibility: .visible
        ) {
            Button("全部移到废纸篓", role: .destructive) {
                Task { await model.uninstallPreviewedBatch() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("操作会逐项执行；遇到失败立即停止。已经完成的应用仍可从废纸篓恢复。")
        }
    }

    private var uniquePathCount: Int {
        Set(model.batchUninstallPreviews.flatMap(\.paths)).count
    }
}

private struct UninstallReviewView: View {
    @ObservedObject var model: AppModel
    let application: MoleApplication
    @Environment(\.dismiss) private var dismiss
    @State private var showConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                AppIcon(path: application.path, size: 54)
                VStack(alignment: .leading, spacing: 3) {
                    Text(application.name)
                        .font(.title2.weight(.semibold))
                    Text("\(application.size) · \(application.source)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") { dismiss() }
                    .buttonStyle(.bordered)
                    .disabled(model.isUninstalling)
            }

            Divider()

            if model.isPreviewingUninstall {
                WorkingStateView(title: "正在查找关联文件", message: "Mole 会保留其他应用仍在使用的共享数据。")
            } else if model.isUninstalling {
                WorkingStateView(title: "正在移到废纸篓", message: "请不要关闭窗口；Mole 正在验证应用和关联文件。")
            } else if let result = model.uninstallResult,
                      result.applicationName == application.name {
                VStack(spacing: 13) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 38))
                        .foregroundStyle(MeloTheme.safeGreen)
                    Text("卸载已完成").font(.title3.weight(.semibold))
                    Text(result.summary).font(.callout).foregroundStyle(.secondary)
                    Button("完成") { dismiss() }
                        .buttonStyle(.borderedProminent)
                        .tint(MeloTheme.brandRose)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let preview = model.uninstallPreview,
                      preview.application.id == application.id {
                Text("将处理的内容")
                    .font(.headline)
                Text(preview.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(preview.paths.enumerated()), id: \.offset) { _, path in
                            HStack(spacing: 10) {
                                Image(systemName: "doc.badge.minus")
                                    .foregroundStyle(MeloTheme.warningAmber)
                                Text(path)
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .lineLimit(2)
                                Spacer()
                            }
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 9))

                HStack {
                    Label("默认移入废纸篓，可恢复", systemImage: "arrow.uturn.backward.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("移到废纸篓") {
                        showConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MeloTheme.brandRose)
                }
            } else if let error = model.errorMessage {
                ErrorBanner(message: error, dismiss: model.dismissError)
            }
        }
        .padding(24)
        .confirmationDialog("卸载 \(application.name)？", isPresented: $showConfirmation, titleVisibility: .visible) {
            Button("移到废纸篓", role: .destructive) {
                Task { await model.uninstallPreviewedApplication() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("Mole 会再次验证刚才的预览计划。应用和可安全关联的文件将移到废纸篓。")
        }
    }
}
