import SwiftUI

struct HistoryView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "操作记录",
                    subtitle: "来自 Mole 本地日志，用于核对清理结果与失败项目。",
                    actionTitle: "刷新",
                    isWorking: model.isLoadingHistory,
                    action: { Task { await model.refreshHistory() } }
                )

                if let error = model.errorMessage {
                    ErrorBanner(message: error, dismiss: model.dismissError)
                }

                if model.isLoadingHistory && model.history == nil {
                    WorkingStateView(title: "正在读取操作记录", message: "只读取 Mole 保存在本机的日志。")
                } else if let history = model.history {
                    historyContent(history)
                } else {
                    EmptyStateView(
                        systemImage: "clock.arrow.circlepath",
                        title: "还没有操作记录",
                        message: "完成一次扫描或清理后，Mole 的记录会显示在这里。",
                        buttonTitle: "读取记录",
                        buttonIcon: "arrow.clockwise",
                        action: { Task { await model.refreshHistory() } }
                    )
                }
            }
            .padding(28)
            .frame(maxWidth: 1040, alignment: .leading)
        }
    }

    @ViewBuilder
    private func historyContent(_ history: MoleHistory) -> some View {
        SectionSurface("最近运行") {
            if history.sessions.isEmpty {
                Text("暂时没有运行记录。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(history.sessions) { session in
                        sessionRow(session)
                        if session.id != history.sessions.last?.id {
                            Divider().padding(.leading, 40)
                        }
                    }
                }
            }
        }

        SectionSurface("最近文件操作") {
            if history.deletions.isEmpty {
                Text("暂时没有删除或移入废纸篓的记录。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(spacing: 0) {
                    ForEach(history.deletions.prefix(40)) { record in
                        deletionRow(record)
                        if record.id != history.deletions.prefix(40).last?.id {
                            Divider().padding(.leading, 34)
                        }
                    }
                }
            }
        }
    }

    private func sessionRow(_ session: HistorySession) -> some View {
        HStack(spacing: 12) {
            Image(systemName: commandIcon(session.command))
                .font(.title3)
                .foregroundStyle(commandColor(session))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(commandTitle(session.command))
                        .font(.callout.weight(.semibold))
                    if (session.actions?.failed ?? 0) > 0 {
                        StatusBadge(title: "有失败项", systemImage: "exclamationmark", color: MeloTheme.warningAmber)
                    }
                }
                Text(session.startedAt)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(session.size ?? "0B")
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .monospacedDigit()
                Text(session.items.map { "\($0) 项" } ?? "项目数未知")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 10)
    }

    private func deletionRow(_ record: DeletionRecord) -> some View {
        HStack(spacing: 11) {
            Image(systemName: record.mode == "trash" ? "trash" : "doc.badge.minus")
                .foregroundStyle(record.status == "ok" ? MeloTheme.safeGreen : MeloTheme.warningAmber)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(URL(fileURLWithPath: record.path).lastPathComponent)
                    .lineLimit(1)
                Text(record.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(ByteFormatting.string(kilobytes: record.sizeKB))
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Button {
                model.revealInFinder(path: record.path)
            } label: {
                Image(systemName: "arrow.forward.square")
            }
            .buttonStyle(.plain)
            .help("在访达中显示")
            .accessibilityLabel("在访达中显示 \(URL(fileURLWithPath: record.path).lastPathComponent)")
        }
        .padding(.vertical, 9)
    }

    private func commandTitle(_ command: String) -> String {
        switch command {
        case "clean": "清理"
        case "uninstall": "卸载应用"
        case "purge": "项目产物清理"
        case "installer": "安装包清理"
        default: command.capitalized
        }
    }

    private func commandIcon(_ command: String) -> String {
        switch command {
        case "clean": "sparkles"
        case "uninstall": "app.badge"
        case "purge": "hammer"
        default: "terminal"
        }
    }

    private func commandColor(_ session: HistorySession) -> Color {
        (session.actions?.failed ?? 0) > 0 ? MeloTheme.warningAmber : MeloTheme.brandRose
    }
}
