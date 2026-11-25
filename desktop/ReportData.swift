import Foundation

/// Token counts of one report row.
struct ReportTokens: Codable, Equatable, Sendable {
    var input: Int = 0
    var cached: Int = 0
    var cacheWrite: Int = 0
    var output: Int = 0

    var total: Int { input + cached + cacheWrite + output }

    init(input: Int = 0, cached: Int = 0, cacheWrite: Int = 0, output: Int = 0) {
        self.input = input
        self.cached = cached
        self.cacheWrite = cacheWrite
        self.output = output
    }

    enum CodingKeys: String, CodingKey {
        case input, cached, cacheWrite, output
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        input = try c.decodeIfPresent(Int.self, forKey: .input) ?? 0
        cached = try c.decodeIfPresent(Int.self, forKey: .cached) ?? 0
        cacheWrite = try c.decodeIfPresent(Int.self, forKey: .cacheWrite) ?? 0
        output = try c.decodeIfPresent(Int.self, forKey: .output) ?? 0
    }
}

enum ReportRowKind: Equatable, Sendable {
    case you, agent, expense, other
}

/// One row of the engine's `report-rows` output: a work session of yours, one agent thread on one day,
/// or an expense. Amounts are whole cents already allocated by the engine: sum them, never re-derive them.
struct ReportRow: Equatable, Sendable {
    var id: String
    /// "you", "agent" or "expense".
    var who: String
    /// "yyyy-MM-dd" in the ledger time zone. A session that runs past the end of the period keeps its
    /// later pieces, so a date can fall on or after the period's `endExclusive`.
    var date: String
    /// Milliseconds since 1970. An expense has both set to the moment it was recorded.
    var startedAt: Int?
    var endedAt: Int?
    var client: String?
    var project: String?
    /// "billable", "internal", "personal", or nil without a project.
    var projectKind: String?
    var task: String?
    var tags: [String] = []
    var description: String = ""
    /// Agent tool id, such as "claude" or "codex".
    var provider: String?
    var models: [String] = []
    var thread: String?
    /// The length of the session (the union of its pieces).
    var millis: Int = 0
    /// The session's time once overlaps with earlier sessions of the same project are counted only once.
    /// The engine fills it for every row, billable or not. Across a month boundary it can slightly exceed
    /// `millis`, because billing unions each month separately.
    var billedMillis: Int = 0
    var tokens: ReportTokens = ReportTokens()
    /// API value in US dollars.
    var apiUsd: Decimal?
    var tokensWithoutApiPrice: Int = 0
    /// "none", "time", "usage" or "hybrid".
    var agentMode: String?
    var rate: Decimal?
    /// nil (never zero) when the row contributed nothing to that invoice line.
    var timeAmount: Decimal?
    var usageAmount: Decimal?
    var amount: Decimal?
    var reimbursable: Bool = false

    var kind: ReportRowKind {
        switch who {
        case "you": return .you
        case "agent": return .agent
        case "expense": return .expense
        default: return .other
        }
    }

    var isBillable: Bool { projectKind == "billable" }

    /// The time a report shows: the billed time, which the engine fills for every row, billable or not, so
    /// overlapping sessions are never counted twice. A fully overlapped session is zero on purpose.
    var reportMillis: Int { billedMillis }
}

/// A client-level line, such as the reduction from a monthly cap on agent charges (a negative amount).
struct ReportAdjustment: Equatable, Sendable {
    var client: String
    var kind: String
    var monthlyCap: Decimal?
    var amount: Decimal
}

/// The engine's `report-rows` output. The `billing` object it also carries is not decoded.
struct ReportData: Equatable, Sendable {
    var start: String
    var endExclusive: String
    var timezone: String
    var currency: String
    var usdExchangeRate: Decimal?
    var needsExchangeRate: Bool = false
    var missingHumanRate: Bool = false
    var client: String?
    var projects: [String]?
    var rows: [ReportRow] = []
    var adjustments: [ReportAdjustment] = []

    /// Decodes engine JSON with the app's usual settings (snake-case keys, money as decimal strings).
    static func decode(_ data: Data) throws -> ReportData {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ReportData.self, from: data)
    }
}

extension KeyedDecodingContainer {
    /// A money value the engine sends as a decimal string ("12.34"), or null. A JSON number is accepted too.
    func reportDecimal(forKey key: Key) throws -> Decimal? {
        guard contains(key) else { return nil }
        if try decodeNil(forKey: key) { return nil }
        if let text = try? decode(String.self, forKey: key) {
            let trimmed = text.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return nil }
            guard let value = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: self,
                                                       debugDescription: "Expected a decimal string, found \(text)")
            }
            return value
        }
        return try decode(Decimal.self, forKey: key)
    }

    func reportValue<T: Decodable>(_ type: T.Type, forKey key: Key, default fallback: T) throws -> T {
        try decodeIfPresent(type, forKey: key) ?? fallback
    }
}

extension ReportRow: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, who, date, startedAt, endedAt, client, project, projectKind, task, tags, description
        case provider, models, thread, millis, billedMillis, tokens, apiUsd, tokensWithoutApiPrice
        case agentMode, rate, timeAmount, usageAmount, amount, reimbursable
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        who = try c.decode(String.self, forKey: .who)
        date = try c.decode(String.self, forKey: .date)
        startedAt = try c.decodeIfPresent(Int.self, forKey: .startedAt)
        endedAt = try c.decodeIfPresent(Int.self, forKey: .endedAt)
        client = try c.decodeIfPresent(String.self, forKey: .client)
        project = try c.decodeIfPresent(String.self, forKey: .project)
        projectKind = try c.decodeIfPresent(String.self, forKey: .projectKind)
        task = try c.decodeIfPresent(String.self, forKey: .task)
        tags = try c.reportValue([String].self, forKey: .tags, default: [])
        description = try c.reportValue(String.self, forKey: .description, default: "")
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        models = try c.reportValue([String].self, forKey: .models, default: [])
        thread = try c.decodeIfPresent(String.self, forKey: .thread)
        millis = try c.reportValue(Int.self, forKey: .millis, default: 0)
        billedMillis = try c.reportValue(Int.self, forKey: .billedMillis, default: 0)
        tokens = try c.reportValue(ReportTokens.self, forKey: .tokens, default: ReportTokens())
        apiUsd = try c.reportDecimal(forKey: .apiUsd)
        tokensWithoutApiPrice = try c.reportValue(Int.self, forKey: .tokensWithoutApiPrice, default: 0)
        agentMode = try c.decodeIfPresent(String.self, forKey: .agentMode)
        rate = try c.reportDecimal(forKey: .rate)
        timeAmount = try c.reportDecimal(forKey: .timeAmount)
        usageAmount = try c.reportDecimal(forKey: .usageAmount)
        amount = try c.reportDecimal(forKey: .amount)
        reimbursable = try c.reportValue(Bool.self, forKey: .reimbursable, default: false)
    }
}

extension ReportAdjustment: Decodable {
    enum CodingKeys: String, CodingKey {
        case client, kind, monthlyCap, amount
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        client = try c.reportValue(String.self, forKey: .client, default: "")
        kind = try c.reportValue(String.self, forKey: .kind, default: "monthly_cap")
        monthlyCap = try c.reportDecimal(forKey: .monthlyCap)
        amount = try c.reportDecimal(forKey: .amount) ?? Decimal(0)
    }
}

extension ReportData: Decodable {
    enum CodingKeys: String, CodingKey {
        case start, endExclusive, timezone, currency, usdExchangeRate, needsExchangeRate, missingHumanRate
        case client, projects, rows, adjustments
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try c.decode(String.self, forKey: .start)
        endExclusive = try c.decode(String.self, forKey: .endExclusive)
        timezone = try c.reportValue(String.self, forKey: .timezone, default: "UTC")
        currency = try c.reportValue(String.self, forKey: .currency, default: "EUR")
        usdExchangeRate = try c.reportDecimal(forKey: .usdExchangeRate)
        needsExchangeRate = try c.reportValue(Bool.self, forKey: .needsExchangeRate, default: false)
        missingHumanRate = try c.reportValue(Bool.self, forKey: .missingHumanRate, default: false)
        client = try c.decodeIfPresent(String.self, forKey: .client)
        projects = try c.decodeIfPresent([String].self, forKey: .projects)
        rows = try c.reportValue([ReportRow].self, forKey: .rows, default: [])
        adjustments = try c.reportValue([ReportAdjustment].self, forKey: .adjustments, default: [])
    }
}
