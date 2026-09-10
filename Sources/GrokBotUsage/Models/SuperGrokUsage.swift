import Foundation

/// Per-product share of the unified Super Grok weekly pool (Chat / Build / Imagine / …).
struct ProductUsageShare: Equatable, Sendable, Identifiable {
    var product: String
    var usagePercent: Double

    var id: String { product }

    var displayName: String {
        switch product {
        case "GrokBuild": return "Build"
        case "GrokImagine": return "Imagine"
        case "GrokVoice": return "Voice"
        case "GrokChat": return "Chat"
        default:
            return product.hasPrefix("Grok")
                ? String(product.dropFirst(4))
                : product
        }
    }

    /// Clamp for display (API may return 0–100 or 0–1 fractions).
    var displayPercent: Double {
        Self.normalizePercent(usagePercent)
    }

    static func normalizePercent(_ raw: Double) -> Double {
        let pct = raw <= 1.0 && raw >= 0 ? raw * 100.0 : raw
        return min(100, max(0, pct))
    }
}

/// Snapshot from `GET /v1/billing?format=credits` (`config.creditUsagePercent`).
///
/// Some SuperGrok accounts return a weekly `currentPeriod` but omit
/// `creditUsagePercent` / `productUsage` (xAI unified-billing drift). That is
/// **unknown** usage — never invent 0%. Only treat as 0% when the API sends an
/// explicit `creditUsagePercent: 0`.
struct SuperGrokUsage: Equatable, Sendable {
    /// Explicit percent from the API, or `nil` when omitted (unknown).
    var creditUsagePercent: Double?
    var periodType: String?
    var periodStart: String?
    var periodEnd: String?
    var productUsage: [ProductUsageShare]
    /// From `GET /v1/settings` (`subscription_tier_display`), e.g. "SuperGrok".
    var subscriptionTierDisplay: String?

    init(
        creditUsagePercent: Double? = nil,
        periodType: String? = nil,
        periodStart: String? = nil,
        periodEnd: String? = nil,
        productUsage: [ProductUsageShare] = [],
        subscriptionTierDisplay: String? = nil
    ) {
        self.creditUsagePercent = creditUsagePercent
        self.periodType = periodType
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.productUsage = productUsage
        self.subscriptionTierDisplay = subscriptionTierDisplay
    }

    /// True when the billing payload included an explicit percent (including 0).
    var hasReportedPercent: Bool {
        creditUsagePercent != nil
    }

    /// Clamp for display when percent is known; `nil` when unknown.
    var displayUsedPercent: Double? {
        guard let raw = creditUsagePercent else { return nil }
        return ProductUsageShare.normalizePercent(raw)
    }

    var displayRemainingPercent: Double? {
        guard let used = displayUsedPercent else { return nil }
        return max(0, 100 - used)
    }

    var resetDate: Date? {
        Self.parseISO8601(periodEnd)
    }

    var periodStartDate: Date? {
        Self.parseISO8601(periodStart)
    }

    var isWeeklyPeriod: Bool {
        (periodType ?? "").uppercased().contains("WEEKLY")
    }

    static func parseISO8601(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: raw) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    /// Parse the credits billing JSON flexibly.
    /// Omitted `creditUsagePercent` + valid weekly `currentPeriod` → unknown
    /// (nil percent), not 0%. Explicit `0` still decodes as 0%.
    static func decode(from data: Data) throws -> SuperGrokUsage {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageAPIError.decoding(NSError(
                domain: "SuperGrokUsage",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Root is not an object"]
            ))
        }
        let config = (root["config"] as? [String: Any]) ?? root

        let period = config["currentPeriod"] as? [String: Any]
        let periodType = period?["type"] as? String
        let periodStart = (period?["start"] as? String)
            ?? (config["billingPeriodStart"] as? String)
        let periodEnd = (period?["end"] as? String)
            ?? (config["billingPeriodEnd"] as? String)

        let rawPercent = Self.flexibleDouble(config["creditUsagePercent"])
            ?? Self.flexibleDouble(config["credit_usage_percent"])
            ?? Self.flexibleDouble(config["usagePercent"])

        let hasWeeklyPeriod: Bool = {
            if let periodType, periodType.uppercased().contains("WEEKLY") { return true }
            return period != nil && (periodStart != nil || periodEnd != nil)
        }()

        if let rawPercent {
            return SuperGrokUsage(
                creditUsagePercent: rawPercent,
                periodType: periodType,
                periodStart: periodStart,
                periodEnd: periodEnd,
                productUsage: Self.decodeProducts(config["productUsage"])
            )
        }

        if hasWeeklyPeriod {
            // Period-only payload (known drift): unknown %, not fabricated 0%.
            return SuperGrokUsage(
                creditUsagePercent: nil,
                periodType: periodType ?? "USAGE_PERIOD_TYPE_WEEKLY",
                periodStart: periodStart,
                periodEnd: periodEnd,
                productUsage: Self.decodeProducts(config["productUsage"])
            )
        }

        throw UsageAPIError.decoding(NSError(
            domain: "SuperGrokUsage",
            code: 2,
            userInfo: [NSLocalizedDescriptionKey: "Missing creditUsagePercent and no weekly period"]
        ))
    }

    private static func decodeProducts(_ raw: Any?) -> [ProductUsageShare] {
        guard let arr = raw as? [[String: Any]] else { return [] }
        return arr.compactMap { row in
            let name = (row["product"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let name, !name.isEmpty else { return nil }
            // Per-product percent: only include when explicitly present.
            guard let pct = flexibleDouble(row["usagePercent"])
                ?? flexibleDouble(row["usage_percent"])
            else { return nil }
            return ProductUsageShare(product: name, usagePercent: pct)
        }
    }

    private static func flexibleDouble(_ raw: Any?) -> Double? {
        switch raw {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let n as NSNumber: return n.doubleValue
        case let s as String:
            return Double(s.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }
}
