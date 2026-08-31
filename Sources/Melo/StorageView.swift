import SwiftUI

struct StorageView: View {
    @ObservedObject var model: AppModel
    @State private var trashCandidate: AnalysisEntry?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "空间分析",
                    subtitle: "使用 Mole 的 JSON 扫描查看文件夹占用，不会删除任何文件。"
                )

                if let error = model.errorMessage {
                    ErrorBanner(message: error, dismiss: model.dismissError)
                }
                if let message = model.analysisTrashMessage {
                    HStack(spacing: 10) {
                        Image(systemName: "trash.circle.fill")
                            .foregroundStyle(MeloTheme.safeGreen)
                        Text(message).font(.callout)
                        Spacer()
                        Button("关闭", action: model.dismissAnalysisTrashMessage)
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(MeloTheme.safeGreen.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
                }

                pathBar

                if model.isAnalyzing {
                    WorkingStateView(
                        title: "正在分析文件夹",
                        message: "文件越多，扫描所需时间越长。你可以继续使用其他应用。",
                        cancelTitle: "取消分析",
                        cancelAction: model.cancelAnalysis
                    )
                } else if let analysis = model.analysis {
                    analysisContent(analysis)
                } else {
                    EmptyStateView(
                        systemImage: "chart.bar.xaxis",
                        title: "找出空间去了哪里",
                        message: "选择一个文件夹后，Mole 会统计第一层目录和大型文件。扫描结果只保留在当前窗口。",
                        buttonTitle: "开始分析",
                        buttonIcon: "play.fill",
                        action: { Task { await model.analyzeSelectedPath() } }
                    )
                }
            }
            .padding(28)
            .frame(maxWidth: 1040, alignment: .leading)
        }
        .confirmationDialog(
            trashCandidate.map { "把 \($0.name) 移到废纸篓？" } ?? "移到废纸篓？",
            isPresented: Binding(
                get: { trashCandidate != nil },
                set: { if !$0 { trashCandidate = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let trashCandidate {
                Button("移到废纸篓", role: .destructive) {
                    Task { await model.trashAnalysisEntry(trashCandidate) }
                    self.trashCandidate = nil
                }
            }
            Button("取消", role: .cancel) { trashCandidate = nil }
        } message: {
            if let trashCandidate {
                Text("\(trashCandidate.path)\n大小：\(ByteFormatting.string(trashCandidate.size))。Melo 会在执行前再次验证路径；不会永久删除。")
            }
        }
    }

    private var pathBar: some View {
        HStack(spacing: 10) {
            Button {
                Task { await model.analyzeParentFolder() }
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)
            .disabled(model.analysisPath == "/" || model.isAnalyzing)
            .help("返回上一级")
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(model.analysisPath)
                .font(.system(.callout, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button("选择文件夹") {
                model.chooseAnalysisFolder()
            }
            .buttonStyle(.bordered)
            .disabled(model.isAnalyzing)
            Button("分析") {
                Task { await model.analyzeSelectedPath() }
            }
            .buttonStyle(.borderedProminent)
            .tint(MeloTheme.brandRose)
            .disabled(model.isAnalyzing)
        }
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private func analysisContent(_ analysis: DiskAnalysis) -> some View {
        HStack(spacing: 28) {
            summaryValue(ByteFormatting.string(analysis.totalSize), label: "扫描大小")
            Divider().frame(height: 32)
            summaryValue(analysis.totalFiles.formatted(), label: "文件数量")
            Divider().frame(height: 32)
            summaryValue(analysis.entries.count.formatted(), label: "顶层项目")
            Spacer()
            Button {
                model.revealInFinder(path: analysis.path)
            } label: {
                Label("在访达中打开", systemImage: "arrow.forward.square")
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 4)

        if !analysis.entries.isEmpty {
            SectionSurface("空间地图") {
                TreemapView(entries: Array(analysis.entries.sorted { $0.size > $1.size }.prefix(28))) { entry in
                    if entry.isDirectory == true {
                        Task { await model.analyze(path: entry.path) }
                    } else {
                        model.revealInFinder(path: entry.path)
                    }
                }
                .frame(height: 280)
            }
        }

        SectionSurface("目录占用") {
            if analysis.entries.isEmpty {
                Text("这个位置没有可显示的项目。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                let sorted = analysis.entries.sorted { $0.size > $1.size }
                let maximum = Double(sorted.first?.size ?? 1)
                VStack(spacing: 0) {
                    ForEach(sorted.prefix(100)) { entry in
                        analysisRow(entry, maximum: maximum)
                        if entry.id != sorted.prefix(100).last?.id {
                            Divider().padding(.leading, 34)
                        }
                    }
                }
            }
        }

        if !analysis.largeFiles.isEmpty {
            SectionSurface("大型文件") {
                VStack(spacing: 0) {
                    ForEach(analysis.largeFiles.prefix(40)) { entry in
                        HStack(spacing: 11) {
                            Image(systemName: "doc")
                                .foregroundStyle(.secondary)
                                .frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name).lineLimit(1)
                                Text(entry.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Text(ByteFormatting.string(entry.size))
                                .font(.system(.callout, design: .rounded, weight: .medium))
                                .monospacedDigit()
                            trashButton(entry)
                            Button {
                                model.revealInFinder(path: entry.path)
                            } label: {
                                Image(systemName: "arrow.forward.square")
                            }
                            .buttonStyle(.plain)
                            .help("在访达中显示")
                        }
                        .padding(.vertical, 9)
                    }
                }
            }
        }
    }

    private func analysisRow(_ entry: AnalysisEntry, maximum: Double) -> some View {
        VStack(spacing: 7) {
            HStack(spacing: 10) {
                Image(systemName: entry.isDirectory == true ? "folder.fill" : "doc.fill")
                    .foregroundStyle(entry.isDirectory == true ? MeloTheme.brandRose : .secondary)
                    .frame(width: 22)
                Text(entry.name)
                    .lineLimit(1)
                if entry.isDirectory == true {
                    Button {
                        Task { await model.analyze(path: entry.path) }
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .help("打开这个文件夹")
                }
                Spacer()
                Text(ByteFormatting.string(entry.size))
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .monospacedDigit()
                trashButton(entry)
                Button {
                    model.revealInFinder(path: entry.path)
                } label: {
                    Image(systemName: "arrow.forward.square")
                }
                .buttonStyle(.plain)
                .help("在访达中显示")
            }
            GeometryReader { proxy in
                Capsule()
                    .fill(Color.secondary.opacity(0.10))
                    .overlay(alignment: .leading) {
                        Capsule()
                            .fill(MeloTheme.brandRose.opacity(0.62))
                            .frame(width: max(3, proxy.size.width * (Double(entry.size) / max(maximum, 1))))
                    }
            }
            .frame(height: 4)
            .padding(.leading, 32)
        }
        .padding(.vertical, 10)
    }

    private func summaryValue(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func trashButton(_ entry: AnalysisEntry) -> some View {
        let reason = model.analysisTrashProtectionReason(for: entry)
        return Button {
            trashCandidate = entry
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.plain)
        .foregroundStyle(reason == nil ? MeloTheme.brandRose : Color.secondary)
        .disabled(reason != nil || model.isTrashingAnalysisEntry || model.isAnalyzing)
        .help(reason ?? "移到废纸篓")
        .accessibilityLabel(reason.map { "无法移动：\($0)" } ?? "把 \(entry.name) 移到废纸篓")
    }
}

private struct TreemapView: View {
    let entries: [AnalysisEntry]
    let action: (AnalysisEntry) -> Void

    var body: some View {
        GeometryReader { proxy in
            let items = TreemapLayout.layout(entries: entries, in: CGRect(origin: .zero, size: proxy.size))
            ZStack(alignment: .topLeading) {
                ForEach(Array(items.enumerated()), id: \.element.entry.id) { index, item in
                    Button {
                        action(item.entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.entry.name)
                                .font(.caption.weight(.semibold))
                                .lineLimit(2)
                            if item.rect.width > 90 && item.rect.height > 46 {
                                Text(ByteFormatting.string(item.entry.size))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(8)
                        .frame(width: max(0, item.rect.width - 3), height: max(0, item.rect.height - 3), alignment: .topLeading)
                        .background(treemapColor(index).opacity(0.20), in: RoundedRectangle(cornerRadius: 7))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: item.rect.minX, y: item.rect.minY)
                    .accessibilityLabel("\(item.entry.name)，\(ByteFormatting.string(item.entry.size))")
                    .accessibilityHint(item.entry.isDirectory == true ? "打开文件夹" : "在访达中显示")
                }
            }
        }
    }

    private func treemapColor(_ index: Int) -> Color {
        let colors: [Color] = [MeloTheme.brandRose, .blue, .purple, .teal, .indigo, .orange]
        return colors[index % colors.count]
    }
}

private enum TreemapLayout {
    struct Item {
        let entry: AnalysisEntry
        let rect: CGRect
    }

    static func layout(entries: [AnalysisEntry], in rect: CGRect) -> [Item] {
        guard !entries.isEmpty, rect.width > 0, rect.height > 0 else { return [] }
        return split(entries: entries, in: rect)
    }

    private static func split(entries: [AnalysisEntry], in rect: CGRect) -> [Item] {
        guard entries.count > 1 else {
            return entries.first.map { [Item(entry: $0, rect: rect)] } ?? []
        }

        let total = entries.reduce(0.0) { $0 + Double(max($1.size, 1)) }
        let target = total / 2
        var accumulated = 0.0
        var splitIndex = 1
        for index in 0..<(entries.count - 1) {
            accumulated += Double(max(entries[index].size, 1))
            splitIndex = index + 1
            if accumulated >= target { break }
        }

        let first = Array(entries[..<splitIndex])
        let second = Array(entries[splitIndex...])
        let firstWeight = first.reduce(0.0) { $0 + Double(max($1.size, 1)) }
        let ratio = min(max(firstWeight / total, 0.08), 0.92)

        if rect.width >= rect.height {
            let firstWidth = rect.width * ratio
            let firstRect = CGRect(x: rect.minX, y: rect.minY, width: firstWidth, height: rect.height)
            let secondRect = CGRect(x: rect.minX + firstWidth, y: rect.minY, width: rect.width - firstWidth, height: rect.height)
            return split(entries: first, in: firstRect) + split(entries: second, in: secondRect)
        } else {
            let firstHeight = rect.height * ratio
            let firstRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: firstHeight)
            let secondRect = CGRect(x: rect.minX, y: rect.minY + firstHeight, width: rect.width, height: rect.height - firstHeight)
            return split(entries: first, in: firstRect) + split(entries: second, in: secondRect)
        }
    }
}
