import SwiftUI

struct CleanupView: View {
    @ObservedObject var model: AppModel
    @State private var showCleanupConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "智能清理",
                    subtitle: "先用 Mole 的 dry-run 完整扫描，确认后才会清理用户级项目。",
                    actionTitle: model.cleanupPreview == nil ? nil : "重新扫描",
                    actionIcon: "arrow.clockwise",
                    isWorking: model.isScanningCleanup,
                    action: { Task { await model.scanCleanup() } }
                )

                if let error = model.errorMessage {
                    ErrorBanner(message: error, dismiss: model.dismissError)
                }

                if model.isScanningCleanup {
                    WorkingStateView(
                        title: "正在检查可清理项目",
                        message: "Mole 会检查缓存、日志、浏览器和开发工具。大型目录可能需要几分钟。",
                        cancelTitle: "取消扫描",
                        isCancelling: model.isCancellingCleanupScan,
                        cancelAction: model.cancelCleanupScan
                    )
                } else if model.isCleaning {
                    WorkingStateView(
                        title: "正在执行清理",
                        message: "可清理项目会移入当前用户的废纸篓；废纸篓不可用时会停止，不会改成永久删除。",
                        cancelTitle: "停止清理",
                        isCancelling: model.isCancellingCleanupRun,
                        cancelAction: model.cancelCleanupRun
                    )
                } else if let result = model.cleanupRunResult {
                    cleanupComplete(result)
                } else if let preview = model.cleanupPreview {
                    previewContent(preview)
                } else {
                    scanStart
                }

                MoleProtectionEditor(model: model, scope: .clean)
            }
            .padding(28)
            .frame(maxWidth: 1040, alignment: .leading)
        }
        .confirmationDialog(
            "把已检查的用户级项目移到废纸篓？",
            isPresented: $showCleanupConfirmation,
            titleVisibility: .visible
        ) {
            Button("移到废纸篓", role: .destructive) {
                Task { await model.runCleanup() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("Melo 会强制使用 Mole 的可恢复删除模式。废纸篓不可用时操作会失败并保留原文件；系统级缓存不会在没有管理员授权时处理。")
        }
    }

    private var scanStart: some View {
        VStack(spacing: 0) {
            EmptyStateView(
                systemImage: "sparkles.rectangle.stack",
                title: "先扫描，不做改动",
                message: "扫描使用 mo clean --dry-run。你会看到预计空间、分类和跳过原因，然后再决定是否清理。",
                buttonTitle: "扫描可清理空间",
                buttonIcon: "magnifyingglass",
                action: { Task { await model.scanCleanup() } }
            )

            HStack(spacing: 28) {
                safetyPoint(icon: "eye", title: "结果可检查", detail: "分类与原始输出都可展开")
                safetyPoint(icon: "hand.raised", title: "危险项会跳过", detail: "沿用 Mole 的路径保护规则")
                safetyPoint(icon: "externaldrive", title: "完全本地", detail: "不会上传文件或扫描结果")
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 30)
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    @ViewBuilder
    private func previewContent(_ preview: CleanupPreview) -> some View {
        HStack(alignment: .center, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("预计可释放")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(preview.potentialSpace ?? "待确认")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .tracking(-0.6)
                    .accessibilityLabel("预计可释放 \(preview.potentialSpace ?? "未知")")
            }
            Spacer()
            if let count = preview.itemCount {
                summaryFact(value: String(count), label: "项目")
            }
            if let count = preview.categoryCount {
                summaryFact(value: String(count), label: "分类")
            }
            Button {
                showCleanupConfirmation = true
            } label: {
                Label("移到废纸篓", systemImage: "trash")
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .tint(MeloTheme.brandRose)
            .controlSize(.large)
        }
        .padding(20)
        .background(MeloTheme.brandRoseSoft, in: RoundedRectangle(cornerRadius: 12))

        if preview.requiresAdminForFullPreview {
            HStack(alignment: .top, spacing: 11) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(MeloTheme.warningAmber)
                VStack(alignment: .leading, spacing: 3) {
                    Text("这次结果不包含系统级缓存")
                        .font(.callout.weight(.semibold))
                    Text("Melo 不会索取或保存管理员密码。没有现成授权时，Mole 会只处理用户级项目。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(MeloTheme.warningAmber.opacity(0.09), in: RoundedRectangle(cornerRadius: 10))
        }

        VStack(spacing: 10) {
            ForEach(preview.sections) { section in
                DisclosureGroup {
                    VStack(spacing: 0) {
                        ForEach(section.items) { item in
                            cleanupRow(item)
                            if item.id != section.items.last?.id {
                                Divider().padding(.leading, 28)
                            }
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    HStack {
                        Text(localizedSection(section.title))
                            .font(.callout.weight(.semibold))
                        Spacer()
                        Text("\(section.items.count) 项")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(15)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
        }

        DisclosureGroup("查看 Mole 原始输出") {
            ScrollView(.horizontal) {
                Text(preview.rawOutput)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .padding(.top, 8)
        }
        .font(.callout)
    }

    private func cleanupComplete(_ result: CleanupRunResult) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(MeloTheme.safeGreen)
                VStack(alignment: .leading, spacing: 4) {
                    Text("已移到废纸篓")
                        .font(.title2.weight(.semibold))
                    Text(result.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("再次扫描") {
                    Task { await model.scanCleanup() }
                }
                .buttonStyle(.bordered)
            }
            .padding(20)
            .background(MeloTheme.safeGreen.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))

            DisclosureGroup("查看本次输出") {
                ScrollView(.horizontal) {
                    Text(result.output)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .padding(.top, 8)
            }
        }
    }

    private func safetyPoint(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: icon)
                .foregroundStyle(MeloTheme.brandRose)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold))
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryFact(value: String, label: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func cleanupRow(_ item: CleanupItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.isSkipped ? "minus.circle" : (item.isInformational ? "info.circle" : "checkmark.circle"))
                .foregroundStyle(item.isSkipped ? MeloTheme.warningAmber : (item.isInformational ? .secondary : MeloTheme.safeGreen))
                .frame(width: 18)
            Text(item.text.replacingOccurrences(of: " dry", with: ""))
                .font(.callout)
                .foregroundStyle(item.isSkipped ? .secondary : .primary)
                .textSelection(.enabled)
            Spacer()
        }
        .padding(.vertical, 9)
    }

    private func localizedSection(_ section: String) -> String {
        let names = [
            "User essentials": "用户常用数据",
            "App caches": "应用缓存",
            "Browsers": "浏览器",
            "Cloud & Office": "云服务与办公",
            "Developer tools": "开发工具",
            "Apps & utilities": "应用与实用工具",
            "Virtualization": "虚拟化",
            "Application Support": "应用支持文件",
            "App leftovers": "应用残留",
            "Apple Silicon updates": "Apple 芯片更新",
            "Device backups & firmware": "设备备份与固件",
            "Time Machine": "时间机器",
            "Large files": "大型文件",
            "Project artifacts": "项目构建产物"
        ]
        return names[section] ?? section
    }
}
