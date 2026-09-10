import SwiftUI
import AppKit

struct UsagePanelView: View {
    @EnvironmentObject private var store: UsageStore

    private let dashboardURL = URL(string: "https://grok.com")!

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            metrics
            Divider()
            meta
            Divider()
            controls
        }
        .padding(14)
        .frame(width: 300)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "triangle.fill")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.tint)
                .frame(width: 32, height: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.headline)
                Text("Grok weekly usage")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }

    private var headerTitle: String {
        if let tier = store.currentStatus?.subscriptionTierDisplay, !tier.isEmpty {
            return tier
        }
        return "Super Grok"
    }

    @ViewBuilder
    private var metrics: some View {
        switch store.state {
        case .loading where store.currentStatus == nil:
            HStack {
                ProgressView()
                    .controlSize(.small)
                Text("Refreshing…")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

        case .error(let message) where store.currentStatus == nil:
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)

        default:
            if let status = store.currentStatus {
                if let used = status.displayUsedPercent {
                    metricRow(title: "Used", value: String(format: "%.0f%%", used))
                    ProgressView(value: used, total: 100)
                        .tint(progressTint(used))
                    if let remaining = status.displayRemainingPercent {
                        metricRow(title: "Remaining", value: String(format: "%.0f%%", remaining))
                    }
                } else {
                    metricRow(title: "Used", value: "—")
                    Text("Weekly % not reported by Grok CLI billing yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Period is known; percent omitted (not the same as 0%). Check grok.com → Settings → Usage, or wait until xAI includes creditUsagePercent.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                metricRow(title: "Resets", value: formatReset(status.resetDate))

                if let tier = status.subscriptionTierDisplay, !tier.isEmpty {
                    metricRow(title: "Plan", value: tier)
                }

                if !status.productUsage.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("By product")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        ForEach(status.productUsage) { item in
                            HStack {
                                Text(item.displayName)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(String(format: "%.0f%%", item.displayPercent))
                                    .monospacedDigit()
                            }
                            .font(.caption)
                        }
                    }
                }
            } else {
                Text("No data yet.")
                    .foregroundStyle(.secondary)
            }

            if case .error(let message) = store.state {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var meta: some View {
        VStack(alignment: .leading, spacing: 6) {
            metaRow(title: "Last refresh", value: formatDate(store.lastRefresh))
            metaRow(title: "Auth", value: store.authSource.rawValue)
            if !store.authDetail.isEmpty {
                Text(store.authDetail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 8) {
            Toggle("Demo Mode", isOn: $store.demoMode)
                .toggleStyle(.switch)
                .controlSize(.small)

            HStack(spacing: 8) {
                Button {
                    Task { await store.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)

                Spacer()

                Link(destination: dashboardURL) {
                    Label("grok.com", systemImage: "safari")
                }
                .help("Open grok.com → Settings → Usage")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button("Quit Super Grok Usage") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 2)
            .keyboardShortcut("q", modifiers: .command)
        }
    }

    private func metricRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .monospacedDigit()
        }
        .font(.subheadline)
    }

    private func metaRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(.primary)
        }
        .font(.caption)
    }

    private func progressTint(_ pct: Double) -> Color {
        switch pct {
        case ..<50: return .green
        case ..<80: return .orange
        default: return .red
        }
    }

    private func formatReset(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: date, relativeTo: Date())

        let absolute = DateFormatter()
        absolute.dateStyle = .medium
        absolute.timeStyle = .short
        return "\(absolute.string(from: date)) (\(relative))"
    }

    private func formatDate(_ date: Date?) -> String {
        guard let date else { return "Never" }
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f.string(from: date)
    }
}
