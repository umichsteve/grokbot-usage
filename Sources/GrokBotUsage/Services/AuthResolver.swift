import Foundation

struct ResolvedAuth: Sendable {
    let cookie: String?
    let source: AuthSource
    let detail: String
}

/// Resolves `WorkosCursorSessionToken` without prompting in chat.
/// Priority: env → local config file → Chromium cookie DB (best-effort).
struct AuthResolver: Sendable {
    static let envVarName = "GROKBOT_USAGE_COOKIE"
    static let configRelativePath = ".config/grokbot-usage/session"
    static let cookieName = "WorkosCursorSessionToken"

    func resolve() -> ResolvedAuth {
        if let env = ProcessInfo.processInfo.environment[Self.envVarName]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty
        {
            return ResolvedAuth(
                cookie: Self.normalizeCookieHeader(env),
                source: .environment,
                detail: "GROKBOT_USAGE_COOKIE"
            )
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home.appendingPathComponent(Self.configRelativePath)
        if let raw = try? String(contentsOf: configURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty
        {
            return ResolvedAuth(
                cookie: Self.normalizeCookieHeader(raw),
                source: .configFile,
                detail: "~/\(Self.configRelativePath)"
            )
        }

        if let fromBrowser = ChromeCookieReader.readWorkosSessionToken() {
            return ResolvedAuth(
                cookie: "\(Self.cookieName)=\(fromBrowser)",
                source: .chromeCookies,
                detail: "Chromium Cookies DB"
            )
        }

        return ResolvedAuth(
            cookie: nil,
            source: .none,
            detail: "No session cookie found"
        )
    }

    /// Accept either a bare token value or a full `Cookie:` / `name=value` string.
    static func normalizeCookieHeader(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("cookie:") {
            return String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        if trimmed.contains("=") {
            // Already a cookie header fragment; ensure Workos token is present as-is.
            return trimmed
        }
        return "\(cookieName)=\(trimmed)"
    }
}
