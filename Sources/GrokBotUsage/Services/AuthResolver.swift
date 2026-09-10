import Foundation

struct ResolvedAuth: Sendable {
    let token: String
    let source: AuthSource
    let detail: String
    /// When true, token came from `~/.grok/auth.json` and can be OIDC-refreshed.
    let canRefresh: Bool
}

enum GrokAuthError: LocalizedError, Equatable {
    case authFileMissing
    case authFileUnreadable
    case noSession
    case tokenExpired
    case malformedAuthFile
    case refreshUnavailable
    case refreshFailed(String)

    var errorDescription: String? {
        switch self {
        case .authFileMissing:
            return "No Grok session. Run `grok login`, then refresh."
        case .authFileUnreadable:
            return "Could not read ~/.grok/auth.json."
        case .noSession:
            return "auth.json has no usable session."
        case .tokenExpired:
            return "Grok session expired. Run `grok login` again."
        case .malformedAuthFile:
            return "auth.json is not in the expected format."
        case .refreshUnavailable:
            return "Session has no refresh token. Run `grok login` again."
        case .refreshFailed(let message):
            return "Could not refresh Grok session: \(message)"
        }
    }
}

/// Resolves a Super Grok Bearer token.
/// Priority: `~/.grok/auth.json` (Grok CLI) → `SUPERGROK_USAGE_TOKEN` →
/// `~/.config/grokbot-usage/session` (advanced fallback).
struct AuthResolver: Sendable {
    static let envVarName = "SUPERGROK_USAGE_TOKEN"
    static let configRelativePath = ".config/grokbot-usage/session"
    static let defaultOIDCIssuer = "https://auth.x.ai"
    /// Public Grok CLI / GrokUsageBar device-login client id.
    static let defaultOIDCClientID = "b1a00492-073a-47ea-816f-4c329264a828"
    /// Refresh when fewer than this many seconds remain (5 minutes).
    static let refreshSkew: TimeInterval = 300

    private struct AuthFileSession: Sendable {
        var entryKey: String
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var oidcIssuer: String?
        var oidcClientId: String?

        func isExpiring(within skew: TimeInterval = AuthResolver.refreshSkew) -> Bool {
            guard let expiresAt else { return true }
            return expiresAt.timeIntervalSinceNow <= skew
        }
    }

    static var authFileURL: URL {
        if let grokHome = ProcessInfo.processInfo.environment["GROK_HOME"], !grokHome.isEmpty {
            return URL(fileURLWithPath: grokHome, isDirectory: true)
                .appendingPathComponent("auth.json")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
    }

    /// Resolve a usable access token, refreshing from auth.json when near expiry.
    func resolve(forceRefresh: Bool = false) async throws -> ResolvedAuth {
        if let session = try? loadAuthFileSession() {
            var current = session
            if forceRefresh || current.isExpiring() {
                do {
                    current = try await refresh(current)
                } catch {
                    // If not forced and token still has life, keep using it.
                    if forceRefresh || current.isExpiring(within: 0) {
                        throw error
                    }
                }
            }
            return ResolvedAuth(
                token: current.accessToken,
                source: .grokAuthFile,
                detail: "~/.grok/auth.json",
                canRefresh: current.refreshToken?.isEmpty == false
            )
        }

        if let env = ProcessInfo.processInfo.environment[Self.envVarName]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !env.isEmpty
        {
            return ResolvedAuth(
                token: Self.normalizeBearerToken(env),
                source: .environment,
                detail: Self.envVarName,
                canRefresh: false
            )
        }

        let home = FileManager.default.homeDirectoryForCurrentUser
        let configURL = home.appendingPathComponent(Self.configRelativePath)
        if let raw = try? String(contentsOf: configURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty
        {
            // Skip comment-only templates.
            let lines = raw
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            if let first = lines.first, !first.isEmpty {
                return ResolvedAuth(
                    token: Self.normalizeBearerToken(first),
                    source: .configFile,
                    detail: "~/\(Self.configRelativePath)",
                    canRefresh: false
                )
            }
        }

        throw GrokAuthError.authFileMissing
    }

    /// Force OIDC refresh when auth.json is the source (e.g. after HTTP 401/403).
    func refreshIfPossible() async throws -> ResolvedAuth {
        guard let session = try? loadAuthFileSession() else {
            throw GrokAuthError.refreshUnavailable
        }
        let updated = try await refresh(session)
        return ResolvedAuth(
            token: updated.accessToken,
            source: .grokAuthFile,
            detail: "~/.grok/auth.json (refreshed)",
            canRefresh: updated.refreshToken?.isEmpty == false
        )
    }

    /// Accept bare JWT / opaque token or `Bearer …`.
    static func normalizeBearerToken(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("bearer ") {
            trimmed = String(trimmed.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        }
        if let eq = trimmed.firstIndex(of: "="),
           trimmed[..<eq].lowercased().contains("token")
        {
            trimmed = String(trimmed[trimmed.index(after: eq)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return trimmed
    }

    // MARK: - auth.json

    private func loadAuthFileSession(from url: URL = AuthResolver.authFileURL) throws -> AuthFileSession {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GrokAuthError.authFileMissing
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw GrokAuthError.authFileUnreadable
        }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GrokAuthError.malformedAuthFile
        }

        // Typical shape: { "<issuer>::<client_id>": { key, refresh_token, … }, … }
        for (entryKey, value) in root {
            guard let entry = value as? [String: Any] else { continue }
            if let session = parseEntry(entryKey: entryKey, entry: entry) {
                return session
            }
        }

        // Flat / alternate: top-level key / access_token.
        if let session = parseEntry(entryKey: "default", entry: root) {
            return session
        }

        throw GrokAuthError.noSession
    }

    private func parseEntry(entryKey: String, entry: [String: Any]) -> AuthFileSession? {
        let token = (entry["key"] as? String)
            ?? (entry["access_token"] as? String)
            ?? (entry["accessToken"] as? String)
        guard let token, !token.isEmpty else { return nil }

        return AuthFileSession(
            entryKey: entryKey,
            accessToken: token,
            refreshToken: (entry["refresh_token"] as? String) ?? (entry["refreshToken"] as? String),
            expiresAt: parseExpiry(entry["expires_at"] as? String ?? entry["expiresAt"] as? String),
            oidcIssuer: (entry["oidc_issuer"] as? String) ?? (entry["oidcIssuer"] as? String),
            oidcClientId: (entry["oidc_client_id"] as? String) ?? (entry["oidcClientId"] as? String)
        )
    }

    private func refresh(
        _ session: AuthFileSession,
        authFileURL url: URL = AuthResolver.authFileURL
    ) async throws -> AuthFileSession {
        guard let refreshToken = session.refreshToken, !refreshToken.isEmpty else {
            throw GrokAuthError.refreshUnavailable
        }
        let clientId = (session.oidcClientId?.isEmpty == false)
            ? session.oidcClientId!
            : Self.defaultOIDCClientID
        let issuer = (session.oidcIssuer?.isEmpty == false)
            ? session.oidcIssuer!
            : Self.defaultOIDCIssuer
        let trimmedIssuer = issuer.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let tokenURL = URL(string: trimmedIssuer + "/oauth2/token") else {
            throw GrokAuthError.refreshFailed("Invalid OIDC issuer.")
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("GrokBotUsage/1.0", forHTTPHeaderField: "User-Agent")

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "refresh_token", value: refreshToken),
        ]
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw GrokAuthError.refreshFailed(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw GrokAuthError.refreshFailed("No HTTP response.")
        }
        guard (200...299).contains(http.statusCode) else {
            let snippet = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if http.statusCode == 400 || http.statusCode == 401 {
                throw GrokAuthError.tokenExpired
            }
            let short = snippet.isEmpty
                ? "HTTP \(http.statusCode)"
                : "HTTP \(http.statusCode): \(snippet.prefix(160))"
            throw GrokAuthError.refreshFailed(String(short))
        }

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let accessToken = (json["access_token"] as? String) ?? (json["key"] as? String),
            !accessToken.isEmpty
        else {
            throw GrokAuthError.refreshFailed("Token response missing access_token.")
        }

        let newRefresh = (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? refreshToken
        let expiresIn = (json["expires_in"] as? Double)
            ?? (json["expires_in"] as? Int).map(Double.init)
            ?? 21600
        let expiresAt = Date().addingTimeInterval(expiresIn)

        try persistTokens(
            entryKey: session.entryKey,
            accessToken: accessToken,
            refreshToken: newRefresh,
            expiresAt: expiresAt,
            issuer: issuer,
            clientId: clientId,
            to: url
        )

        var updated = session
        updated.accessToken = accessToken
        updated.refreshToken = newRefresh
        updated.expiresAt = expiresAt
        updated.oidcIssuer = issuer
        updated.oidcClientId = clientId
        return updated
    }

    private func persistTokens(
        entryKey: String,
        accessToken: String,
        refreshToken: String,
        expiresAt: Date,
        issuer: String,
        clientId: String,
        to url: URL
    ) throws {
        var root: [String: Any] = [:]
        if FileManager.default.fileExists(atPath: url.path),
           let data = try? Data(contentsOf: url),
           let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            root = existing
        }

        var entry = (root[entryKey] as? [String: Any]) ?? [:]
        // Flat file (entryKey == "default"): write token fields at top level.
        if entryKey == "default", root["key"] != nil || root["access_token"] != nil {
            entry = root
        }

        entry["key"] = accessToken
        entry["access_token"] = accessToken
        entry["refresh_token"] = refreshToken
        entry["expires_at"] = ISO8601DateFormatter.grokFractional.string(from: expiresAt)
        if entry["oidc_issuer"] == nil { entry["oidc_issuer"] = issuer }
        if entry["oidc_client_id"] == nil { entry["oidc_client_id"] = clientId }

        if entryKey == "default", root[entryKey] == nil {
            root = entry
        } else {
            root[entryKey] = entry
        }

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try atomicWrite(data, to: url, mode: 0o600)
    }

    private func atomicWrite(_ data: Data, to url: URL, mode: UInt16) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o700)],
            ofItemAtPath: dir.path
        )
        let temp = dir.appendingPathComponent(".auth.json.\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp, options: .withoutOverwriting)
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: mode)],
                ofItemAtPath: temp.path
            )
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
            } else {
                try FileManager.default.moveItem(at: temp, to: url)
            }
            try? FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: mode)],
                ofItemAtPath: url.path
            )
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw GrokAuthError.authFileUnreadable
        }
    }

    private func parseExpiry(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return ISO8601DateFormatter.grokFractional.date(from: raw)
            ?? ISO8601DateFormatter.grok.date(from: raw)
    }
}

private extension ISO8601DateFormatter {
    static let grok: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static let grokFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
