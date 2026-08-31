import SwiftUI

struct MaintenanceView: View {
    @ObservedObject var model: AppModel
    @State private var showConfirmation = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "系统维护",
                    subtitle: "检查 Quick Look、网络缓存、Spotlight 和常见 macOS 服务。",
                    actionTitle: model.maintenancePreview == nil ? nil : "重新检查",
                    isWorking: model.isScanningMaintenance,
                    action: { Task { await model.scanMaintenance() } }
                )

                if let error = model.errorMessage {
                    ErrorBanner(message: error, dismiss: model.dismissError)
                }

                if model.isScanningMaintenance {
                    WorkingStateView(
                        title: "正在生成维护计划",
                        message: "当前只检查，不会修改任何系统设置。",
                        cancelTitle: "取消检查",
                        cancelAction: model.cancelMaintenanceScan
                    )
                } else if model.isPerformingMaintenance {
                    WorkingStateView(
                        title: "正在执行系统维护",
                        message: "不适用或无法确认安全的任务会自动跳过并说明原因。",
                        cancelTitle: "停止维护",
                        isCancelling: model.isCancellingMaintenanceRun,
                        cancelAction: model.cancelMaintenanceRun
                    )
                } else if let result = model.maintenanceResult {
                    completion(result)
                } else if let preview = model.maintenancePreview {
                    previewContent(preview)
                } else {
                    EmptyStateView(
                        systemImage: "wrench.and.screwdriver",
                        title: "先检查维护项目",
                        message: "使用 mo optimize --dry-run 诊断系统，并把可执行、跳过和失败项分别列出。",
                        buttonTitle: "检查系统维护",
                        buttonIcon: "stethoscope",
                        action: { Task { await model.scanMaintenance() } }
                    )
                }

                MoleProtectionEditor(model: model, scope: .optimize)
            }
            .padding(28)
            .frame(maxWidth: 1040, alignment: .leading)
        }
        .confirmationDialog("执行已检查的维护任务？", isPresented: $showConfirmation, titleVisibility: .visible) {
            Button("开始维护") {
                Task { await model.performMaintenance() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("Mole 会刷新缓存和服务。正在使用、不可用或存在风险的任务会跳过。")
        }
    }

    @ViewBuilder
    private func previewContent(_ preview: MaintenancePreview) -> some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 3) {
                Text("维护计划").font(.callout).foregroundStyle(.secondary)
                Text("\(preview.applicableCount ?? 0) 项可执行")
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
            }
            Spacer()
            summaryValue(preview.unchangedCount ?? 0, label: "无需改动")
            summaryValue(preview.skippedCount ?? 0, label: "已跳过")
            Button {
                showConfirmation = true
            } label: {
                Label("执行维护", systemImage: "wrench.adjustable")
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .tint(MeloTheme.brandRose)
            .controlSize(.large)
        }
        .padding(20)
        .background(MeloTheme.brandRoseSoft, in: RoundedRectangle(cornerRadius: 12))

        VStack(spacing: 10) {
            ForEach(preview.sections) { section in
                DisclosureGroup {
                    VStack(spacing: 0) {
                        ForEach(section.items) { item in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: item.isSkipped ? "exclamationmark.circle" : "checkmark.circle")
                                    .foregroundStyle(item.isSkipped ? MeloTheme.warningAmber : MeloTheme.safeGreen)
                                Text(item.text)
                                    .font(.callout)
                                    .textSelection(.enabled)
                                Spacer()
                            }
                            .padding(.vertical, 8)
                        }
                    }
                    .padding(.top, 8)
                } label: {
                    HStack {
                        Text(localizedSection(section.title)).font(.callout.weight(.semibold))
                        Spacer()
                        Text("\(section.items.count) 项").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(15)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            }
        }

        DisclosureGroup("查看 Mole 原始输出") {
            Text(preview.rawOutput)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func completion(_ result: MaintenanceResult) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 40))
                .foregroundStyle(MeloTheme.safeGreen)
            Text("系统维护已完成").font(.title2.weight(.semibold))
            Text(result.summary).font(.callout).foregroundStyle(.secondary)
            Button("再次检查") { Task { await model.scanMaintenance() } }
                .buttonStyle(.bordered)
        }
        .padding(.vertical, 60)
        .frame(maxWidth: .infinity)
    }

    private func summaryValue(_ value: Int, label: String) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(value.formatted()).font(.system(.title3, design: .rounded, weight: .semibold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func localizedSection(_ section: String) -> String {
        let names = [
            "DNS & Spotlight Check": "DNS 与 Spotlight 检查",
            "Finder Cache Refresh": "Finder 缓存刷新",
            "App State Cleanup": "应用状态整理",
            "Broken Config Repair": "损坏配置修复",
            "Network Cache Refresh": "网络缓存刷新",
            "Database Optimization": "数据库优化",
            "LaunchServices Repair": "LaunchServices 修复",
            "Prevent Finder .DS_Store": "Finder 元数据设置",
            "Network Stack Refresh": "网络栈刷新",
            "Permission Repair": "权限检查",
            "Spotlight Optimization": "Spotlight 优化",
            "Periodic Maintenance": "系统周期维护",
            "Disk Health": "磁盘健康",
            "Login Items": "登录项",
            "Launch Agents Cleanup": "启动代理清理",
            "Notifications": "通知数据库",
            "Usage Data": "使用数据"
        ]
        return names[section] ?? section
    }
}
