import Foundation

enum UsageAPIError: LocalizedError {
    case badURL
    case httpStatus(Int, String)
    case decoding(Error)
    case transport(Error)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "Invalid API URL"
        case .httpStatus(let code, let body):
            if code == 401 || code == 403 {
                return "Not authenticated (HTTP \(code)). Refresh your Cursor session cookie."
            }
            let snippet = body.prefix(180).replacingOccurrences(of: "\n", with: " ")
            return "HTTP \(code): \(snippet)"
        case .decoding(let err):
            return "Could not parse usage response: \(err.localizedDescription)"
        case .transport(let err):
            return err.localizedDescription
        }
    }
}

struct UsageAPIClient: Sendable {
    var baseURL: URL = URL(string: "https://cursor.com")!
    var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 15
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    func fetchSandUsage(cookieHeader: String) async throws -> SandUsageStatus {
        guard let url = URL(string: "/api/dashboard/get-sand-usage-status", relativeTo: baseURL)?.absoluteURL else {
            throw UsageAPIError.badURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("https://cursor.com", forHTTPHeaderField: "Origin")
        request.setValue("https://cursor.com", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        request.httpBody = Data("{}".utf8)

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
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw UsageAPIError.httpStatus(http.statusCode, body)
        }

        do {
            return try JSONDecoder().decode(SandUsageStatus.self, from: data)
        } catch {
            throw UsageAPIError.decoding(error)
        }
    }
}
