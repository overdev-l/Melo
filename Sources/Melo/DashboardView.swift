import SwiftUI

struct DashboardView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                PageHeader(
                    title: "电脑状态",
                    subtitle: dashboardSubtitle,
                    actionTitle: model.isMoleInstalled ? "刷新硬件" : nil,
                    isWorking: model.isRefreshingStatus,
                    action: { Task { await model.refreshStatus() } }
                )

                if let error = model.errorMessage {
                    ErrorBanner(message: error, dismiss: model.dismissError)
                }

                connectionStrip

                if let live = model.liveSnapshot {
                    liveOverview(live, hardware: model.status)
                } else {
                    WorkingStateView(title: "正在启动实时监控", message: "Melo 正在本机读取 CPU、内存、网络和活跃进程。")
                }

                quickActions
            }
            .padding(28)
            .frame(maxWidth: 1040, alignment: .leading)
        }
    }

    private var dashboardSubtitle: String {
        if let modelName = model.status?.hardware?.model,
           let os = model.status?.hardware?.osVersion {
            return "\(modelName) · \(os)"
        }
        return "每秒更新关键资源，最近 60 秒趋势可在系统状态中查看。"
    }

    private var connectionStrip: some View {
        HStack(spacing: 12) {
            Image(systemName: model.isMoleInstalled ? "checkmark.seal.fill" : "waveform.path.ecg")
                .font(.title3)
                .foregroundStyle(model.isMoleInstalled ? MeloTheme.safeGreen : .blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isMoleInstalled ? "本机监控与 Mole 已就绪" : "本机实时监控已就绪")
                    .font(.callout.weight(.semibold))
                Text(model.isMoleInstalled ? "所有监控与扫描都在本机完成，Melo 不上传文件或结果。" : "状态监控无需 Mole；安装 Mole 后可使用清理、卸载、维护和空间分析。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if model.isMoleInstalled {
                StatusBadge(title: model.moleVersion ?? "检测中", systemImage: "terminal", color: MeloTheme.safeGreen)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .background((model.isMoleInstalled ? MeloTheme.safeGreen : Color.blue).opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
    }

    private func liveOverview(_ live: LiveSystemSnapshot, hardware: MoleStatus?) -> some View {
        SectionSurface("实时资源") {
            VStack(spacing: 16) {
                MetricRow(
                    label: "处理器",
                    value: live.cpuUsage,
                    valueText: live.cpuUsage.formatted(.number.precision(.fractionLength(0))) + "%"
                )
                MetricRow(
                    label: "内存",
                    value: live.memoryUsedPercent,
                    valueText: ByteFormatting.string(live.memoryUsed) + " / " + ByteFormatting.string(live.memoryTotal),
                    tint: .blue
                )
                if let disk = hardware.flatMap({ primaryDisk(in: $0.disks) }) {
                    MetricRow(
                        label: "磁盘",
                        value: disk.usedPercent,
                        valueText: ByteFormatting.string(disk.total - min(disk.used, disk.total)) + " 可用",
                        tint: disk.usedPercent > 85 ? MeloTheme.warningAmber : .purple
                    )
                }

                HStack {
                    Label("网络 ↓\(ByteFormatting.speed(live.networkReceiveBytesPerSecond))  ↑\(ByteFormatting.speed(live.networkSendBytesPerSecond))", systemImage: "arrow.up.arrow.down")
                    Spacer()
                    Text("\(live.processes.count) 个活跃进程")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var quickActions: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("常用操作")
                .font(.headline)
            HStack(spacing: 10) {
                if model.isMoleInstalled {
                    Button {
                        model.selection = .cleanup
                    } label: {
                        Label("扫描可清理空间", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(MeloTheme.brandRose)

                    Button {
                        model.selection = .software
                    } label: {
                        Label("管理软件", systemImage: "square.stack.3d.up")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        model.selection = .maintenance
                    } label: {
                        Label("系统维护", systemImage: "wrench.and.screwdriver")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        model.selection = .storage
                    } label: {
                        Label("分析文件夹", systemImage: "folder.badge.gearshape")
                    }
                    .buttonStyle(.bordered)
                }

                Button {
                    model.selection = .status
                } label: {
                    Label("系统状态", systemImage: "waveform.path.ecg")
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
    }

    private func primaryDisk(in disks: [DiskStatus]) -> DiskStatus? {
        disks.first(where: { $0.mount == "/Volumes/Macintosh HD" })
            ?? disks.first(where: { $0.external != true })
            ?? disks.first
    }

}
