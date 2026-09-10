import Foundation
import Combine

enum AuthSource: String, Equatable, Sendable {
    case demo = "Demo Mode"
    case grokAuthFile = "Grok CLI (~/.grok/auth.json)"
    case environment = "Environment variable"
    case configFile = "Config file"
    case none = "Not signed in"
}

enum UsageLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded(SuperGrokUsage)
    case error(String)
}

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    @Published var demoMode: Bool {
        didSet {
            UserDefaults.standard.set(demoMode, forKey: Self.demoModeKey)
            Task { await refresh() }
        }
    }

    @Published private(set) var state: UsageLoadState = .idle
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var authSource: AuthSource = .none
    @Published private(set) var authDetail: String = ""

    private let client = UsageAPIClient()
    private let auth = AuthResolver()
    private var pollTask: Task<Void, Never>?

    private static let demoModeKey = "demoMode"
    private static let pollInterval: TimeInterval = 5 * 60

    private init() {
        // Default ON so the menu bar shows ~33% before credentials are configured.
        if UserDefaults.standard.object(forKey: Self.demoModeKey) == nil {
            self.demoMode = true
        } else {
            self.demoMode = UserDefaults.standard.bool(forKey: Self.demoModeKey)
        }
    }

    /// Menu-bar label: known percent, or `—` when loaded but API omitted the field.
    var usedPercentText: String {
        switch state {
        case .loaded(let s):
            return Self.formatPercentLabel(s)
        case .loading:
            if let snap = lastSnapshot {
                return Self.formatPercentLabel(snap)
            }
            return "…"
        case .error, .idle:
            return demoMode ? "33%" : "—"
        }
    }

    private static func formatPercentLabel(_ usage: SuperGrokUsage) -> String {
        if let pct = usage.displayUsedPercent {
            return String(format: "%.0f%%", pct)
        }
        return "—"
    }

    var currentStatus: SuperGrokUsage? {
        switch state {
        case .loaded(let s):
            return s
        default:
            return lastSnapshot
        }
    }

    private var lastSnapshot: SuperGrokUsage?

    func start() {
        Task { await refresh() }
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func refresh() async {
        state = .loading

        if demoMode {
            let demo = SuperGrokUsage(
                creditUsagePercent: 33,
                periodType: "USAGE_PERIOD_TYPE_WEEKLY",
                periodStart: ISO8601DateFormatter().string(
                    from: Date().addingTimeInterval(-3 * 24 * 3600)
                ),
                periodEnd: ISO8601DateFormatter().string(
                    from: Date().addingTimeInterval(4 * 24 * 3600)
                ),
                productUsage: [
                    ProductUsageShare(product: "GrokChat", usagePercent: 18),
                    ProductUsageShare(product: "GrokBuild", usagePercent: 12),
                    ProductUsageShare(product: "GrokImagine", usagePercent: 3),
                ],
                subscriptionTierDisplay: "SuperGrok"
            )
            lastSnapshot = demo
            authSource = .demo
            authDetail = "Showing fixed ~33% without credentials"
            lastRefresh = Date()
            state = .loaded(demo)
            return
        }

        do {
            var resolved = try await auth.resolve()
            authSource = resolved.source
            authDetail = resolved.detail

            do {
                let status = try await client.fetchWeeklyUsage(bearerToken: resolved.token)
                lastSnapshot = status
                lastRefresh = Date()
                state = .loaded(status)
            } catch UsageAPIError.unauthorized where resolved.canRefresh {
                // Access token rejected — OIDC refresh once, then retry.
                resolved = try await auth.refreshIfPossible()
                authSource = resolved.source
                authDetail = resolved.detail
                let status = try await client.fetchWeeklyUsage(bearerToken: resolved.token)
                lastSnapshot = status
                lastRefresh = Date()
                state = .loaded(status)
            }
        } catch let err as GrokAuthError {
            authSource = .none
            authDetail = err.localizedDescription
            state = .error(
                "\(err.localizedDescription) Install the Grok CLI, run `grok login`, turn off Demo Mode, then Refresh. Advanced: set SUPERGROK_USAGE_TOKEN or ~/.config/grokbot-usage/session."
            )
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}
