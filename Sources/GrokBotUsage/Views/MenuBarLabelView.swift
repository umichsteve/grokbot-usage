import SwiftUI

struct MenuBarLabelView: View {
    @EnvironmentObject private var store: UsageStore

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "triangle.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            Text(store.usedPercentText)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .help(helpText)
    }

    private var tint: Color {
        guard let pct = store.currentStatus?.displayUsedPercent else {
            return store.demoMode ? .green : .secondary
        }
        switch pct {
        case ..<50: return .green
        case ..<80: return .orange
        default: return .red
        }
    }

    private var helpText: String {
        if store.demoMode { return "Super Grok weekly usage (Demo Mode)" }
        if let s = store.currentStatus {
            return "Super Grok weekly usage: \(Int(s.displayUsedPercent.rounded()))% used"
        }
        return "Grok weekly usage"
    }
}
