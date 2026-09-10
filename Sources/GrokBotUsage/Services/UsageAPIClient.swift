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
    var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    func fetchWeeklyUsage(bearerToken: String) async throws -> SuperGrokUsage {
        var request = URLRequest(url: creditsURL)
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

        do {
            return try SuperGrokUsage.decode(from: data)
        } catch let err as UsageAPIError {
            throw err
        } catch {
            throw UsageAPIError.decoding(error)
        }
    }
}
