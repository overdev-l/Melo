import SwiftUI

struct DoctorView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "Doctor",
                    subtitle: "一次只读体检：汇总环境、系统、权限、配置、安全与最近运行状态。",
                    actionTitle: "重新检查",
                    actionIcon: "stethoscope",
                    isWorking: model.isRunningDoctor,
                    action: { Task { await model.runDoctor() } }
                )

                if let error = model.errorMessage {
                    ErrorBanner(message: error, dismiss: model.dismissError)
                }

                if let report = model.doctorReport {
                    summary(report)
                    ForEach(report.sections) { section in
                        sectionView(section)
                    }
                } else {
                    WorkingStateView(title: "正在执行只读检查", message: "不会修改权限、系统设置、风扇或 Battery Care。")
                }
            }
            .padding(28)
            .frame(maxWidth: 1080, alignment: .leading)
        }
        .task {
            if model.doctorReport == nil {
                await model.runDoctor()
            }
        }
    }

    private func summary(_ report: DoctorReport) -> some View {
        SectionSurface {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: report.issues.isEmpty ? "checkmark.seal.fill" : report.highestSeverity.icon)
                    .font(.title2)
                    .foregroundStyle(report.issues.isEmpty ? MeloTheme.safeGreen : report.highestSeverity.color)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 5) {
                    Text(report.issues.isEmpty ? "没有发现明显问题" : "发现 \(report.issues.count) 项需要关注")
                        .font(.headline)
                    Text("检查于 \(report.generatedAt.formatted(date: .abbreviated, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    model.copyDoctorReport()
                } label: {
                    Label("复制报告", systemImage: "doc.on.doc")
                }
                .buttonStyle(.bordered)
                .help("复制已隐藏用户主目录的诊断报告")
            }

            if !report.issues.isEmpty {
                Divider()
                VStack(spacing: 0) {
                    ForEach(report.issues) { issue in
                        HStack(alignment: .top, spacing: 11) {
                            Image(systemName: issue.severity.icon)
                                .foregroundStyle(issue.severity.color)
                                .frame(width: 20)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(issue.title).font(.callout.weight(.semibold))
                                Text(issue.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 9)
                        .accessibilityElement(children: .combine)
                        if issue.id != report.issues.last?.id { Divider().padding(.leading, 31) }
                    }
                }
            }
        }
    }

    private func sectionView(_ section: DoctorSection) -> some View {
        SectionSurface(section.title) {
            VStack(spacing: 0) {
                ForEach(section.items) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Label(item.label, systemImage: item.severity.icon)
                                .font(.callout)
                                .foregroundStyle(item.severity == .healthy ? Color.primary : item.severity.color)
                                .frame(width: 170, alignment: .leading)
                            Text(item.value)
                                .font(.system(.callout, design: item.label == "Bundle" || item.label == "Mole CLI" ? .monospaced : .default))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            Spacer(minLength: 8)
                            permissionButton(for: item)
                        }
                        if let detail = item.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.leading, 182)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 9)
                    .accessibilityElement(children: .contain)
                    if item.id != section.items.last?.id { Divider() }
                }
            }
        }
    }

    @ViewBuilder
    private func permissionButton(for item: DoctorItem) -> some View {
        if item.severity != .healthy, let target = settingsTarget(for: item.label) {
            Button("系统设置") { model.openSystemSettings(target) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("打开\(item.label)系统设置")
        }
    }

    private func settingsTarget(for label: String) -> SystemSettingsTarget? {
        switch label {
        case "完全磁盘访问": .fullDiskAccess
        case "辅助功能": .accessibility
        case "通知": .notifications
        case "摄像头": .camera
        case "麦克风": .microphone
        default: nil
        }
    }
}

private extension DoctorSeverity {
    var icon: String {
        switch self {
        case .healthy: "checkmark.circle"
        case .information: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .critical: "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .healthy: MeloTheme.safeGreen
        case .information: .blue
        case .warning: MeloTheme.warningAmber
        case .critical: .red
        }
    }
}
