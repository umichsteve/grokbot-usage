import SwiftUI

@main
struct GrokBotUsageApp: App {
    @ObservedObject private var store = UsageStore.shared

    var body: some Scene {
        MenuBarExtra {
            UsagePanelView()
                .environmentObject(store)
        } label: {
            MenuBarLabelView()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        // Keep a hidden Settings scene so Quit / standard commands work cleanly.
        Settings {
            EmptyView()
        }
    }

    init() {
        Task { @MainActor in
            UsageStore.shared.start()
        }
    }
}
