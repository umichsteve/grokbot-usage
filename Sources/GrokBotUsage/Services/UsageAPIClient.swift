import Foundation

enum UsageAPIError: LocalizedError {
    case badURL
    case unauthorized
    case httpStatus(Int, String)
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Invalid API URL"
        case .unauthorized:
            return "Not authenticated (HTTP 401/403). Run `grok login` or refresh your token."
        case .httpStatus(let code, let body):
            let snippet = body.prefix(180).replacingOccurrences(of: "\n", with: " ")
            if code == 412 {
                return "Billing unavailable for this account (HTTP 412). Personal Super Grok weekly usage may not apply to team logins."
            }
            return "HTTP \(code): \(snippet)"
        case .decoding(let err):
            return "Could not parse usage response: \(err.localizedDescription)"
        case .transport(let err):
            return err.localizedDescription
        }
    }
}

struct UsageAPIClient: Sendable {
    /// Primary weekly pool endpoint used by Grok CLI / GrokUsageBar / OpenUsage.
    var creditsURL: URL = URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
    /// Optional plan/tier display (e.g. SuperGrok) — best-effort, non-fatal if missing.
    var settingsURL: URL = URL(string: "https://cli-chat-proxy.grok.com/v1/settings")!
    var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    func fetchWeeklyUsage(bearerToken: String) async throws -> SuperGrokUsage {
        var usage = try await fetchCredits(bearerToken: bearerToken)
        if let tier = try? await fetchSubscriptionTierDisplay(bearerToken: bearerToken) {
            usage.subscriptionTierDisplay = tier
        }
        return usage
    }

    private func fetchCredits(bearerToken: String) async throws -> SuperGrokUsage {
        let data = try await authorizedGET(creditsURL, bearerToken: bearerToken)
        do {
            return try SuperGrokUsage.decode(from: data)
        } catch let err as UsageAPIError {
            throw err
        } catch {
            throw UsageAPIError.decoding(error)
        }
    }

    /// Best-effort: `subscription_tier_display` from `/v1/settings` (e.g. "SuperGrok").
    func fetchSubscriptionTierDisplay(bearerToken: String) async throws -> String? {
        let data = try await authorizedGET(settingsURL, bearerToken: bearerToken)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        // Nested or flat shapes seen across CLI proxies.
        let candidates: [Any?] = [
            root["subscription_tier_display"],
            root["subscriptionTierDisplay"],
            (root["settings"] as? [String: Any])?["subscription_tier_display"],
            (root["settings"] as? [String: Any])?["subscriptionTierDisplay"],
            (root["user"] as? [String: Any])?["subscription_tier_display"],
            (root["account"] as? [String: Any])?["subscription_tier_display"],
        ]
        for value in candidates {
            if let s = value as? String {
                let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { return trimmed }
            }
        }
        return nil
    }

    private func authorizedGET(_ url: URL, bearerToken: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearerToken)", forHTTPHeaderField: "Authorization")
        // Best-effort headers commonly used by Grok CLI / public meters.
        request.setValue("xai-grok-cli", forHTTPHeaderField: "X-XAI-Token-Auth")
        request.setValue("menu-bar", forHTTPHeaderField: "x-grok-client-surface")
        request.setValue("GrokBotUsage/1.0", forHTTPHeaderField: "x-grok-client-version")
        request.setValue("GrokBotUsage/1.0", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageAPIError.transport(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageAPIError.httpStatus(-1, "Non-HTTP response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageAPIError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw UsageAPIError.httpStatus(http.statusCode, body)
        }
        return data
    }
}
