import Foundation

/// Whose work a report includes.
enum ReportWho: String, Codable, CaseIterable, Equatable, Sendable {
    case both, you, agents
}

/// Which expenses a report includes.
enum ReportExpenses: String, Codable, CaseIterable, Equatable, Sendable {
    case none, reimbursable, all
}

/// How fine the table lines are. `totals` prints the summary only, with no table.
enum ReportDetail: String, Codable, CaseIterable, Equatable, Sendable {
    case totals, project, day, task, entry
}

/// What the table lines are grouped under (a title row and a subtotal row per group).
enum ReportGroupBy: String, Codable, CaseIterable, Equatable, Sendable {
    case none, project, day, task, who
}

/// Columns a report can show besides the description (and the date at entry detail).
enum ReportOptionalColumn: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case timeRange, hours, rate, amount, tokens, aiCost, model
}

enum ReportHoursFormat: String, Codable, CaseIterable, Equatable, Sendable {
    /// "1.50"
    case decimal
    /// "1h 30m"
    case clock
}

enum ReportLanguage: String, Codable, CaseIterable, Equatable, Sendable {
    case en, it, fr, es, de

    /// The first supported language among preferred language identifiers such as "it-IT", or English.
    static func preferred(_ identifiers: [String]) -> ReportLanguage {
        for identifier in identifiers {
            let code = String(identifier.lowercased().prefix(2))
            if let language = ReportLanguage(rawValue: code) { return language }
        }
        return .en
    }
}

enum ReportPaper: String, Codable, CaseIterable, Equatable, Sendable {
    case a4, letter
}

enum ReportOrientation: String, Codable, CaseIterable, Equatable, Sendable {
    case portrait, landscape
}

enum ReportCSVSeparator: String, Codable, CaseIterable, Equatable, Sendable {
    case comma, semicolon

    var character: String { self == .comma ? "," : ";" }
    /// Spreadsheets that expect semicolons (Italian, German, French Excel) also expect a decimal comma.
    var usesDecimalComma: Bool { self == .semicolon }
}

/// Calendar-day helpers on "yyyy-MM-dd" strings. Day arithmetic runs in UTC, so it never meets a DST change.
enum ReportCalendar {
    static func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        return calendar
    }

    static func parts(_ day: String) -> (year: Int, month: Int, day: Int)? {
        let pieces = day.split(separator: "-", omittingEmptySubsequences: false)
        guard pieces.count == 3, let year = Int(pieces[0]), let month = Int(pieces[1]), let dayNumber = Int(pieces[2]),
              (1...12).contains(month), (1...31).contains(dayNumber) else { return nil }
        return (year, month, dayNumber)
    }

    static func text(year: Int, month: Int, day: Int) -> String {
        String(format: "%04ld-%02ld-%02ld", year, month, day)
    }

    /// Noon UTC of the day, for formatting a calendar day in UTC without a time zone shift.
    static func date(_ day: String) -> Date? {
        guard let value = parts(day) else { return nil }
        var components = DateComponents()
        components.year = value.year
        components.month = value.month
        components.day = value.day
        components.hour = 12
        return utcCalendar().date(from: components)
    }

    static func adding(days: Int, to day: String) -> String {
        let calendar = utcCalendar()
        guard let noon = ReportCalendar.date(day), let moved = calendar.date(byAdding: .day, value: days, to: noon) else {
            return day
        }
        let components = calendar.dateComponents([.year, .month, .day], from: moved)
        return text(year: components.year ?? 0, month: components.month ?? 1, day: components.day ?? 1)
    }

    /// The calendar day `date` falls on in `timeZone`.
    static func day(of date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return text(year: components.year ?? 0, month: components.month ?? 1, day: components.day ?? 1)
    }

    /// 1 = Monday ... 7 = Sunday.
    static func isoWeekday(_ day: String) -> Int {
        guard let noon = ReportCalendar.date(day) else { return 1 }
        let weekday = utcCalendar().component(.weekday, from: noon)  // 1 = Sunday
        return (weekday + 5) % 7 + 1
    }
}

/// The period a report covers. The UI turns it into the engine's --start/--end arguments.
enum ReportRange: Codable, Equatable, Hashable, Sendable {
    case thisMonth
    case lastMonth
    case thisWeek
    case lastWeek
    /// Both days are "yyyy-MM-dd" and inclusive: `end` is the last day in the report.
    case custom(start: String, end: String)

    /// The first day and the day after the last one, as "yyyy-MM-dd". Weeks start on Monday.
    func bounds(timezone: String, now: Date) -> (start: String, endExclusive: String) {
        let zone = TimeZone(identifier: timezone) ?? TimeZone(secondsFromGMT: 0) ?? TimeZone.current
        let today = ReportCalendar.day(of: now, timeZone: zone)
        let parts = ReportCalendar.parts(today) ?? (year: 1970, month: 1, day: 1)
        switch self {
        case .thisMonth:
            return Self.month(year: parts.year, month: parts.month)
        case .lastMonth:
            let year = parts.month == 1 ? parts.year - 1 : parts.year
            let month = parts.month == 1 ? 12 : parts.month - 1
            return Self.month(year: year, month: month)
        case .thisWeek:
            let monday = ReportCalendar.adding(days: 1 - ReportCalendar.isoWeekday(today), to: today)
            return (monday, ReportCalendar.adding(days: 7, to: monday))
        case .lastWeek:
            let monday = ReportCalendar.adding(days: 1 - ReportCalendar.isoWeekday(today), to: today)
            return (ReportCalendar.adding(days: -7, to: monday), monday)
        case .custom(let start, let end):
            return (start, ReportCalendar.adding(days: 1, to: end))
        }
    }

    private static func month(year: Int, month: Int) -> (start: String, endExclusive: String) {
        let next = month == 12 ? (year + 1, 1) : (year, month + 1)
        return (ReportCalendar.text(year: year, month: month, day: 1), ReportCalendar.text(year: next.0, month: next.1, day: 1))
    }
}

/// What a report includes and how it looks. Codable so the UI can remember it per client.
struct ReportOptions: Codable, Equatable, Sendable {
    var range: ReportRange = .lastMonth
    var who: ReportWho = .both
    /// Drop rows whose project is not billable. Rows without a project are always dropped.
    var billableOnly: Bool = true
    var expenses: ReportExpenses = .reimbursable
    var detail: ReportDetail = .task
    var groupBy: ReportGroupBy = .project
    /// false: one "Work" table with a Who column. true: a "Work hours" section and an "AI agents" section.
    var separateAgents: Bool = false
    var columns: Set<ReportOptionalColumn> = [.hours, .rate, .amount]
    var hoursFormat: ReportHoursFormat = .decimal
    /// Empty means the localized default ("Work report").
    var title: String = ""
    /// The person whose time the report shows, as the client reads it ("Who" column, group titles, summary).
    /// Empty means the localized neutral label ("Consultant").
    var personName: String = ""
    /// Your business details, several lines.
    var from: String = ""
    var reference: String = ""
    var note: String = ""
    var language: ReportLanguage = .en
    var paper: ReportPaper = .a4
    var orientation: ReportOrientation = .portrait
    var csvSeparator: ReportCSVSeparator = .comma

    /// With both rate and amount turned off the report is a pure timesheet and shows no money anywhere.
    var showsMoney: Bool { columns.contains(.rate) || columns.contains(.amount) }

    enum CodingKeys: String, CodingKey {
        case range, who, billableOnly, expenses, detail, groupBy, separateAgents, columns, hoursFormat
        case title, personName, from, reference, note, language, paper, orientation, csvSeparator
    }
}

extension ReportOptions {
    /// Missing or unknown values fall back to the defaults, so saved options survive new fields and cases.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = ReportOptions()
        self.init()
        range = Self.value(container, .range, defaults.range)
        who = Self.value(container, .who, defaults.who)
        billableOnly = Self.value(container, .billableOnly, defaults.billableOnly)
        expenses = Self.value(container, .expenses, defaults.expenses)
        detail = Self.value(container, .detail, defaults.detail)
        groupBy = Self.value(container, .groupBy, defaults.groupBy)
        separateAgents = Self.value(container, .separateAgents, defaults.separateAgents)
        if let names = try? container.decodeIfPresent([String].self, forKey: .columns) {
            columns = Set(names.compactMap { ReportOptionalColumn(rawValue: $0) })
        }
        hoursFormat = Self.value(container, .hoursFormat, defaults.hoursFormat)
        title = Self.value(container, .title, defaults.title)
        personName = Self.value(container, .personName, defaults.personName)
        from = Self.value(container, .from, defaults.from)
        reference = Self.value(container, .reference, defaults.reference)
        note = Self.value(container, .note, defaults.note)
        language = Self.value(container, .language, defaults.language)
        paper = Self.value(container, .paper, defaults.paper)
        orientation = Self.value(container, .orientation, defaults.orientation)
        csvSeparator = Self.value(container, .csvSeparator, defaults.csvSeparator)
    }

    private static func value<T: Decodable>(_ container: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys,
                                            _ fallback: T) -> T {
        if let decoded = try? container.decodeIfPresent(T.self, forKey: key) {
            return decoded
        }
        return fallback
    }
}
