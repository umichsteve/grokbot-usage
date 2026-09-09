import Foundation

/// Response from `POST /api/dashboard/get-sand-usage-status`.
/// Field names match CodexBar's `CursorSandUsageStatus` (usagePercent,
/// nextResetTimestampUtc, hasNonZeroIncludedLimit, …). Parsed flexibly.
struct SandUsageStatus: Decodable, Equatable, Sendable {
    var currentPeriodStart: String?
    var nextResetTimestampUtc: String?
    var usagePercent: Double?
    var hasAvailableUsage: Bool?
    var hasNonZeroIncludedLimit: Bool?

    enum CodingKeys: String, CodingKey {
        case currentPeriodStart
        case nextResetTimestampUtc
        case usagePercent
        case hasAvailableUsage
        case hasNonZeroIncludedLimit
        // Alternate / future keys
        case usage_percent
        case next_reset_timestamp_utc
        case percentUsed
        case usedPercent
    }

    init(
        currentPeriodStart: String? = nil,
        nextResetTimestampUtc: String? = nil,
        usagePercent: Double? = nil,
        hasAvailableUsage: Bool? = nil,
        hasNonZeroIncludedLimit: Bool? = nil
    ) {
        self.currentPeriodStart = currentPeriodStart
        self.nextResetTimestampUtc = nextResetTimestampUtc
        self.usagePercent = usagePercent
        self.hasAvailableUsage = hasAvailableUsage
        self.hasNonZeroIncludedLimit = hasNonZeroIncludedLimit
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)

        currentPeriodStart = Self.decodeOptionalString(c, .currentPeriodStart)
        nextResetTimestampUtc =
            Self.decodeOptionalString(c, .nextResetTimestampUtc)
            ?? Self.decodeOptionalString(c, .next_reset_timestamp_utc)

        usagePercent =
            Self.decodeFlexibleDouble(c, .usagePercent)
            ?? Self.decodeFlexibleDouble(c, .usage_percent)
            ?? Self.decodeFlexibleDouble(c, .percentUsed)
            ?? Self.decodeFlexibleDouble(c, .usedPercent)

        hasAvailableUsage = try c.decodeIfPresent(Bool.self, forKey: .hasAvailableUsage)
        hasNonZeroIncludedLimit = try c.decodeIfPresent(Bool.self, forKey: .hasNonZeroIncludedLimit)
    }

    /// Clamp for display (API may return 0–100 or 0–1 fractions).
    var displayUsedPercent: Double {
        guard let raw = usagePercent else { return 0 }
        let pct = raw <= 1.0 && raw >= 0 ? raw * 100.0 : raw
        return min(100, max(0, pct))
    }

    var displayRemainingPercent: Double {
        max(0, 100 - displayUsedPercent)
    }

    /// Accounts with no Bot allowance should be treated as "no meter".
    var hasIncludedAllowance: Bool {
        hasNonZeroIncludedLimit ?? true
    }

    var resetDate: Date? {
        Self.parseISO8601(nextResetTimestampUtc)
    }

    var periodStartDate: Date? {
        Self.parseISO8601(currentPeriodStart)
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

    private static func decodeOptionalString(
        _ c: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> String? {
        if let s = try? c.decodeIfPresent(String.self, forKey: key) { return s }
        return nil
    }

    private static func decodeFlexibleDouble(
        _ c: KeyedDecodingContainer<CodingKeys>,
        _ key: CodingKeys
    ) -> Double? {
        if let d = try? c.decodeIfPresent(Double.self, forKey: key) { return d }
        if let i = try? c.decodeIfPresent(Int.self, forKey: key) { return Double(i) }
        if let s = try? c.decodeIfPresent(String.self, forKey: key),
           let d = Double(s.trimmingCharacters(in: .whitespaces))
        {
            return d
        }
        return nil
    }
}
