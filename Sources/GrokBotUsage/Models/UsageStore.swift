import Foundation
import Combine

enum AuthSource: String, Equatable, Sendable {
    case demo = "Demo Mode"
    case environment = "Environment variable"
    case configFile = "Config file"
    case chromeCookies = "Browser cookies"
    case none = "Not signed in"
}

enum UsageLoadState: Equatable, Sendable {
    case idle
    case loading
    case loaded(SandUsageStatus)
    case noAllowance(SandUsageStatus)
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

    var usedPercentText: String {
        switch state {
        case .loaded(let s), .noAllowance(let s):
            return String(format: "%.0f%%", s.displayUsedPercent)
        case .loading:
            return lastSnapshot.map { String(format: "%.0f%%", $0.displayUsedPercent) } ?? "…"
        case .error, .idle:
            return demoMode ? "33%" : "—"
        }
    }

    var currentStatus: SandUsageStatus? {
        switch state {
        case .loaded(let s), .noAllowance(let s):
            return s
        default:
            return lastSnapshot
        }
    }

    private var lastSnapshot: SandUsageStatus?

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
            let demo = SandUsageStatus(
                currentPeriodStart: ISO8601DateFormatter().string(
                    from: Date().addingTimeInterval(-3 * 24 * 3600)
                ),
                nextResetTimestampUtc: ISO8601DateFormatter().string(
                    from: Date().addingTimeInterval(4 * 24 * 3600)
                ),
                usagePercent: 33,
                hasAvailableUsage: true,
                hasNonZeroIncludedLimit: true
            )
            lastSnapshot = demo
            authSource = .demo
            authDetail = "Showing fixed ~33% without credentials"
            lastRefresh = Date()
            state = .loaded(demo)
            return
        }

        let resolved = auth.resolve()
        authSource = resolved.source
        authDetail = resolved.detail

        guard let cookie = resolved.cookie, !cookie.isEmpty else {
            state = .error(
                "No Cursor session found. Sign in at cursor.com, or paste WorkosCursorSessionToken into ~/.config/grokbot-usage/session (or set GROKBOT_USAGE_COOKIE). Toggle Demo Mode to preview the UI."
            )
            return
        }

        do {
            let status = try await client.fetchSandUsage(cookieHeader: cookie)
            lastSnapshot = status
            lastRefresh = Date()
            if status.hasIncludedAllowance == false {
                state = .noAllowance(status)
            } else if status.usagePercent == nil {
                state = .error("Response missing usagePercent")
            } else {
                state = .loaded(status)
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }
}
