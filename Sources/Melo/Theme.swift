import SwiftUI

enum MeloTheme {
    // Canonical anchor: oklch(0.60 0.20 354.5), converted to sRGB for SwiftUI.
    static let brandRose = Color(red: 0.79, green: 0.16, blue: 0.38)
    static let brandRoseSoft = Color(red: 0.79, green: 0.16, blue: 0.38).opacity(0.11)
    static let safeGreen = Color(red: 0.12, green: 0.56, blue: 0.36)
    static let warningAmber = Color(red: 0.86, green: 0.49, blue: 0.10)
}

struct PageHeader: View {
    let title: String
    let subtitle: String
    var actionTitle: String?
    var actionIcon: String = "arrow.clockwise"
    var isWorking = false
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.system(size: 28, weight: .semibold))
                    .tracking(-0.5)
                Text(subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 24)
            if let actionTitle, let action {
                Button(action: action) {
                    HStack(spacing: 7) {
                        if isWorking {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Image(systemName: actionIcon)
                        }
                        Text(actionTitle)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(isWorking)
            }
        }
    }
}

struct SectionSurface<Content: View>: View {
    let title: String?
    let content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let title {
                Text(title)
                    .font(.headline)
            }
            content
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }
}

struct MetricRow: View {
    let label: String
    let value: Double
    let valueText: String
    var tint: Color = MeloTheme.brandRose

    var body: some View {
        VStack(spacing: 7) {
            HStack {
                Text(label)
                    .font(.callout)
                Spacer()
                Text(valueText)
                    .font(.system(.callout, design: .rounded, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: min(max(value, 0), 100), total: 100)
                .tint(tint)
                .accessibilityLabel(label)
                .accessibilityValue(valueText)
        }
    }
}

struct StatusBadge: View {
    let title: String
    let systemImage: String
    let color: Color

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(color.opacity(0.11), in: Capsule())
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String
    let buttonTitle: String
    var buttonIcon: String = "arrow.right"
    let action: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 38, weight: .regular))
                .foregroundStyle(MeloTheme.brandRose)
                .symbolRenderingMode(.hierarchical)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)
            Button(action: action) {
                Label(buttonTitle, systemImage: buttonIcon)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
            }
            .buttonStyle(.borderedProminent)
            .tint(MeloTheme.brandRose)
            .controlSize(.large)
        }
        .padding(.vertical, 50)
        .frame(maxWidth: .infinity)
    }
}

struct WorkingStateView: View {
    let title: String
    let message: String
    var cancelTitle: String?
    var isCancelling = false
    var cancelAction: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.title3.weight(.semibold))
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let cancelTitle, let cancelAction {
                Button(isCancelling ? "正在取消…" : cancelTitle, action: cancelAction)
                    .buttonStyle(.bordered)
                    .disabled(isCancelling)
            }
        }
        .padding(.vertical, 64)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
    }
}

struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(MeloTheme.warningAmber)
            Text(message)
                .font(.callout)
                .textSelection(.enabled)
            Spacer()
            Button("关闭", action: dismiss)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(MeloTheme.warningAmber.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
    }
}
