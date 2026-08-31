import SwiftUI

struct RootView: View {
    @ObservedObject var model: AppModel
    @State private var showMissingMoleAlert = false

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 250)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .task {
            await model.bootstrap()
            showMissingMoleAlert = !model.isMoleInstalled
        }
        .alert("Mole 扩展功能尚未连接", isPresented: $showMissingMoleAlert) {
            Button("查看安装说明") {
                model.openURL("https://github.com/tw93/mole#quick-start")
            }
            Button("稍后", role: .cancel) {}
        } message: {
            Text("Melo 的实时系统监控可以直接使用。安装 Mole 后还可使用清理、软件卸载、系统维护和空间分析。")
        }
    }

    private var sidebar: some View {
        List(selection: $model.selection) {
            Section {
                ForEach(SidebarItem.allCases.filter { $0 != .settings }) { item in
                    Label(item.title, systemImage: item.systemImage)
                        .tag(item)
                }
            }

            Section {
                Label(SidebarItem.settings.title, systemImage: SidebarItem.settings.systemImage)
                    .tag(SidebarItem.settings)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .foregroundStyle(model.isLiveMonitoring ? MeloTheme.safeGreen : MeloTheme.warningAmber)
                    .frame(width: 7, height: 7)
                Text(model.isMoleInstalled ? "实时监控 · Mole \(model.moleVersion ?? "检测中")" : "实时监控 · Mole 未连接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
        .navigationTitle("Melo")
    }

    @ViewBuilder
    private var detail: some View {
        switch model.selection ?? .overview {
        case .overview:
            DashboardView(model: model)
        case .cleanup:
            CleanupView(model: model)
        case .software:
            SoftwareView(model: model)
        case .maintenance:
            MaintenanceView(model: model)
        case .storage:
            StorageView(model: model)
        case .status:
            SystemStatusView(model: model)
        case .doctor:
            DoctorView(model: model)
        case .history:
            HistoryView(model: model)
        case .settings:
            SettingsView(model: model)
        }
    }
}
