import Foundation

// MARK: - Document

/// The report's header. Free texts are the user's, unformatted; the renderers localize everything else.
struct ReportHeader: Equatable, Sendable {
    /// Empty means the localized default title.
    var title: String
    /// The person whose time the report shows; empty means the localized neutral label.
    var personName: String
    var from: String
    var client: String?
    var projects: [String]?
    /// "yyyy-MM-dd", both inclusive.
    var start: String
    var end: String
    var reference: String
    var note: String
    var generatedAt: Date
    var currency: String
    var timezone: String
    var language: ReportLanguage
}

enum ReportSectionKind: String, Equatable, Sendable {
    /// You and agents in one table, with a Who column.
    case work
    /// The person's own time ("Work hours" in the document).
    case you
    /// "AI agents" in the document.
    case agents
    case expenses
}

enum ReportColumn: String, Equatable, CaseIterable, Sendable {
    /// `timeAmount` and `usageAmount` split a hybrid amount (hours × rate, plus usage); the builder adds them
    /// right before `amount` only when a section mixes the two.
    case date, timeRange, description, who, model, tokens, aiCost, hours, rate, timeAmount, usageAmount, amount

    var isNumeric: Bool {
        switch self {
        case .tokens, .aiCost, .hours, .rate, .timeAmount, .usageAmount, .amount: return true
        case .date, .timeRange, .description, .who, .model: return false
        }
    }
}

/// Who did the work on a line: you, and the display names of the agent providers.
struct ReportWhoValue: Equatable, Hashable, Sendable {
    var you: Bool
    var agents: [String]
}

/// What a line or a group title says, typed so the renderers can localize it.
enum ReportLabel: Equatable, Hashable, Sendable {
    case project(String)
    /// A nil task is "No task". The project is set when the line is not already under a project.
    case task(project: String?, task: String?)
    /// "yyyy-MM-dd"
    case day(String)
    case who(ReportWhoValue)
    /// One entry or expense. Project and task are set when the line is not already under them.
    case entry(description: String, project: String?, task: String?)
    /// One agent entry without a description ("Agent session"). Project and task as for `entry`.
    case agentSession(project: String?, task: String?)
    case subtotal
    case total
}

struct ReportLine: Equatable, Sendable {
    var label: ReportLabel
    /// "yyyy-MM-dd" when every merged row is on the same day.
    var date: String?
    /// Milliseconds since 1970, entry detail only.
    var startedAt: Int?
    var endedAt: Int?
    var who: ReportWhoValue
    /// The time the report shows (billed time on billable work).
    var billedMillis: Int
    var workedMillis: Int
    /// The hours the document prints, with two decimals, reconciled so lines add up to their subtotal and
    /// subtotals to the section total. nil when no merged row has any time (printed as a dash).
    var displayHours: Decimal?
    /// The same in whole minutes, for the clock format.
    var displayMinutes: Int?
    /// The one rate every merged row shares, or nil when they differ or have none.
    var rate: Decimal?
    /// The time part of the amount (hours × rate), nil when no merged row has one.
    var timeAmount: Decimal?
    /// The usage part of the amount (API value × markup), nil when no merged row has one.
    var usageAmount: Decimal?
    /// nil when no merged row has an amount.
    var amount: Decimal?
    var tokens: Int
    /// API value in US dollars, nil when no merged row has one.
    var apiUsd: Decimal?
    var models: [String]
    var rowCount: Int
    var isTotal: Bool

    /// Some merged row has time, worked or billed. Agent usage without run time and expenses have none.
    var hasTime: Bool { billedMillis > 0 || workedMillis > 0 }
}

/// Hours as the document prints them, already reconciled with the tables.
struct ReportShownHours: Equatable, Sendable {
    /// Hours with two decimals.
    var hours: Decimal
    /// Whole minutes, for the clock format.
    var minutes: Int
}

struct ReportGroup: Equatable, Sendable {
    /// nil when the section is not grouped.
    var title: ReportLabel?
    var lines: [ReportLine]
    /// Only when the section is grouped.
    var subtotal: ReportLine?
}

struct ReportSection: Equatable, Sendable {
    var kind: ReportSectionKind
    var columns: [ReportColumn]
    var groups: [ReportGroup]
    var total: ReportLine
}

enum ReportSummaryItem: Equatable, Sendable {
    case you(millis: Int, amount: Decimal?)
    case agents(millis: Int, amount: Decimal?)
    case tokens(Int)
    /// API value in US dollars.
    case aiCost(Decimal)
    /// A negative amount: what a client's monthly cap on agent charges takes off.
    case capAdjustment(client: String, monthlyCap: Decimal?, amount: Decimal)
    case expenses(Decimal)
    /// Work amounts + adjustments + included expenses.
    case total(Decimal)
}

enum ReportWarning: Equatable, Sendable {
    case missingHumanRate
    case needsExchangeRate
    case tokensWithoutPrice(Int)
}

/// Everything the PDF and CSV renderers need, as typed values: nothing in it is formatted or localized yet.
struct ReportDocument: Equatable, Sendable {
    var header: ReportHeader
    var options: ReportOptions
    var summary: [ReportSummaryItem]
    var sections: [ReportSection]
    var warnings: [ReportWarning]
    /// The hours the summary prints for the person and for agents: the sum of what their table lines show
    /// (rounded true totals with no table). nil when the summary has no such line.
    var youHours: ReportShownHours?
    var agentHours: ReportShownHours?

    /// The person's and the agents' hours together, nil when the summary shows neither.
    var shownHours: ReportShownHours? {
        if youHours == nil && agentHours == nil { return nil }
        let you = youHours ?? ReportShownHours(hours: Decimal(0), minutes: 0)
        let agents = agentHours ?? ReportShownHours(hours: Decimal(0), minutes: 0)
        return ReportShownHours(hours: you.hours + agents.hours, minutes: you.minutes + agents.minutes)
    }

    var grandTotal: Decimal? {
        for item in summary {
            if case .total(let amount) = item { return amount }
        }
        return nil
    }

    var adjustments: [ReportSummaryItem] {
        summary.filter { item in
            if case .capAdjustment = item { return true }
            return false
        }
    }
}

// MARK: - Builder

enum ReportBuilder {
    /// Turns engine rows into a report. Deterministic: the same input gives the same document.
    static func build(data: ReportData, options: ReportOptions, generatedAt: Date,
                      providerName: (String) -> String = { $0 }) -> ReportDocument {
        var names: [String: String] = [:]
        for row in data.rows {
            if let provider = row.provider, names[provider] == nil {
                names[provider] = providerName(provider)
            }
        }
        let includeYou = options.who != .agents
        let includeAgents = options.who != .you
        let showsMoney = options.showsMoney

        var youRows: [ReportRow] = []
        var agentRows: [ReportRow] = []
        var expenseRows: [ReportRow] = []
        for row in data.rows {
            switch row.kind {
            case .you, .agent:
                guard row.project != nil else { continue }
                if options.billableOnly && !row.isBillable { continue }
                if row.kind == .you {
                    if includeYou { youRows.append(row) }
                } else if includeAgents {
                    agentRows.append(row)
                }
            case .expense:
                guard showsMoney else { continue }
                switch options.expenses {
                case .none: continue
                case .reimbursable: if !row.reimbursable { continue }
                case .all: break
                }
                if options.billableOnly && row.project != nil && !row.isBillable { continue }
                expenseRows.append(row)
            case .other:
                continue
            }
        }

        var sections: [ReportSection] = []
        if options.detail != .totals {
            var parts: [(ReportSectionKind, [ReportRow])] = []
            if options.separateAgents {
                parts.append((.you, youRows))
                parts.append((.agents, agentRows))
            } else {
                let kind: ReportSectionKind = includeYou && includeAgents ? .work : (includeYou ? .you : .agents)
                parts.append((kind, youRows + agentRows))
            }
            for (kind, rows) in parts where !rows.isEmpty {
                sections.append(workSection(kind: kind, rows: rows, options: options, names: names))
            }
            if !expenseRows.isEmpty {
                sections.append(expenseSection(rows: expenseRows, names: names))
            }
        }

        var summary: [ReportSummaryItem] = []
        let showsAgents = includeAgents && !agentRows.isEmpty
        var youHours: ReportShownHours? = nil
        var agentHours: ReportShownHours? = nil
        if includeYou && !youRows.isEmpty {
            youHours = shownHours(sections: sections, you: true, rows: youRows)
        }
        if showsAgents {
            agentHours = shownHours(sections: sections, you: false, rows: agentRows)
        }
        if includeYou && !youRows.isEmpty {
            summary.append(.you(millis: youRows.reduce(0) { $0 + $1.reportMillis },
                                amount: showsMoney ? sumAmounts(youRows) : nil))
        }
        if showsAgents {
            summary.append(.agents(millis: agentRows.reduce(0) { $0 + $1.reportMillis },
                                   amount: showsMoney ? sumAmounts(agentRows) : nil))
            let tokens = agentRows.reduce(0) { $0 + $1.tokens.total }
            if options.columns.contains(.tokens) && tokens > 0 {
                summary.append(.tokens(tokens))
            }
            if options.columns.contains(.aiCost), let usd = sumDecimals(agentRows.map { $0.apiUsd }) {
                summary.append(.aiCost(usd))
            }
        }
        var total = Decimal(0)
        for row in youRows + agentRows {
            if let amount = row.amount { total += amount }
        }
        if includeAgents && showsMoney {
            for adjustment in data.adjustments {
                summary.append(.capAdjustment(client: adjustment.client, monthlyCap: adjustment.monthlyCap,
                                              amount: adjustment.amount))
                total += adjustment.amount
            }
        }
        if !expenseRows.isEmpty {
            let expenses = sumAmounts(expenseRows) ?? Decimal(0)
            summary.append(.expenses(expenses))
            total += expenses
        }
        if showsMoney {
            summary.append(.total(total))
        }

        var warnings: [ReportWarning] = []
        // A row that only overlaps time already billed has no amount even with a rate: only a missing rate warns.
        if showsMoney && data.missingHumanRate
            && youRows.contains(where: { $0.isBillable && $0.rate == nil && $0.reportMillis > 0 }) {
            warnings.append(.missingHumanRate)
        }
        if showsMoney && data.needsExchangeRate
            && agentRows.contains(where: { $0.agentMode == "usage" || $0.agentMode == "hybrid" }) {
            warnings.append(.needsExchangeRate)
        }
        let unpriced = agentRows.reduce(0) { $0 + $1.tokensWithoutApiPrice }
        let usageBilled = showsMoney && agentRows.contains(where: { $0.agentMode == "usage" || $0.agentMode == "hybrid" })
        if unpriced > 0 && (options.columns.contains(.aiCost) || usageBilled) {
            warnings.append(.tokensWithoutPrice(unpriced))
        }

        let header = ReportHeader(
            title: options.title, personName: options.personName, from: options.from, client: data.client,
            projects: data.projects,
            start: data.start, end: ReportCalendar.adding(days: -1, to: data.endExclusive),
            reference: options.reference, note: options.note, generatedAt: generatedAt,
            currency: data.currency, timezone: data.timezone, language: options.language)
        return ReportDocument(header: header, options: options, summary: summary, sections: sections,
                              warnings: warnings, youHours: youHours, agentHours: agentHours)
    }

    // MARK: Keys

    /// Who a line belongs to: you and agents never share a line, and providers only split when grouped by who.
    fileprivate enum WhoClass: Hashable {
        case you
        case agents
        case provider(String)

        var rank: Int {
            switch self {
            case .you: return 0
            case .agents: return 1
            case .provider: return 2
            }
        }
    }

    /// One grouping or detail dimension of a row.
    fileprivate enum Dimension: Hashable {
        case project(String)
        case day(String)
        case task(String, String?)
        case who(WhoClass)
        case entry(id: String, date: String, start: Int?)

        var rank: Int {
            switch self {
            case .project: return 0
            case .day: return 1
            case .task: return 2
            case .who: return 3
            case .entry: return 4
            }
        }
    }

    fileprivate struct LineKey: Hashable {
        var detail: Dimension
        var who: WhoClass
    }

    private static func providerLabel(_ row: ReportRow, names: [String: String]) -> String {
        guard let provider = row.provider else { return "" }
        return names[provider] ?? provider
    }

    private static func whoClass(_ row: ReportRow, splitProviders: Bool, names: [String: String]) -> WhoClass {
        if row.kind == .you { return .you }
        return splitProviders ? .provider(providerLabel(row, names: names)) : .agents
    }

    private static func groupDimension(_ row: ReportRow, groupBy: ReportGroupBy, names: [String: String]) -> Dimension? {
        switch groupBy {
        case .none: return nil
        case .project: return .project(row.project ?? "")
        case .day: return .day(row.date)
        case .task: return .task(row.project ?? "", row.task)
        case .who: return .who(whoClass(row, splitProviders: true, names: names))
        }
    }

    private static func detailDimension(_ row: ReportRow, detail: ReportDetail) -> Dimension {
        switch detail {
        case .totals, .project: return .project(row.project ?? "")
        case .day: return .day(row.date)
        case .task: return .task(row.project ?? "", row.task)
        case .entry: return .entry(id: row.id, date: row.date, start: row.startedAt)
        }
    }

    // MARK: Ordering

    /// Case-insensitive order, with the exact text as a tie-break so the order is always the same.
    private static func textPrecedes(_ a: String, _ b: String) -> Bool {
        let order = a.caseInsensitiveCompare(b)
        if order != .orderedSame { return order == .orderedAscending }
        return a < b
    }

    /// Tasks alphabetically, with "No task" last.
    private static func taskPrecedes(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case (let x?, let y?): return textPrecedes(x, y)
        }
    }

    private static func whoPrecedes(_ a: WhoClass, _ b: WhoClass) -> Bool {
        if a.rank != b.rank { return a.rank < b.rank }
        if case .provider(let x) = a, case .provider(let y) = b { return textPrecedes(x, y) }
        return false
    }

    private static func dimensionPrecedes(_ a: Dimension, _ b: Dimension) -> Bool {
        switch (a, b) {
        case (.project(let x), .project(let y)):
            return textPrecedes(x, y)
        case (.day(let x), .day(let y)):
            return x < y
        case (.task(let p, let t), .task(let q, let u)):
            if p != q { return textPrecedes(p, q) }
            if t == u { return false }
            return taskPrecedes(t, u)
        case (.who(let x), .who(let y)):
            return whoPrecedes(x, y)
        case (.entry(let i, let d, let s), .entry(let j, let e, let t)):
            if d != e { return d < e }
            if s != t {
                guard let s else { return false }
                guard let t else { return true }
                return s < t
            }
            return i < j
        default:
            return a.rank < b.rank
        }
    }

    private static func linePrecedes(_ a: LineKey, _ b: LineKey) -> Bool {
        if a.detail != b.detail { return dimensionPrecedes(a.detail, b.detail) }
        return whoPrecedes(a.who, b.who)
    }

    // MARK: Sections

    private static func effectiveGroupBy(_ options: ReportOptions, kind: ReportSectionKind) -> ReportGroupBy {
        switch (options.groupBy, options.detail) {
        case (.project, .project), (.day, .day), (.task, .task):
            return .none
        default:
            break
        }
        if options.groupBy == .who && kind == .you { return .none }
        return options.groupBy
    }

    private static func columns(kind: ReportSectionKind, groupBy: ReportGroupBy, options: ReportOptions) -> [ReportColumn] {
        var result: [ReportColumn] = []
        let entries = options.detail == .entry
        if entries && groupBy != .day { result.append(.date) }
        if entries && options.columns.contains(.timeRange) { result.append(.timeRange) }
        result.append(.description)
        if (kind == .work || kind == .agents) && groupBy != .who { result.append(.who) }
        if kind != .you {
            if options.columns.contains(.model) { result.append(.model) }
            if options.columns.contains(.tokens) { result.append(.tokens) }
            if options.columns.contains(.aiCost) { result.append(.aiCost) }
        }
        if options.columns.contains(.hours) { result.append(.hours) }
        if options.columns.contains(.rate) { result.append(.rate) }
        if options.columns.contains(.amount) { result.append(.amount) }
        return result
    }

    /// A hybrid amount is unreadable as rate × hours: when a section has both time and usage amounts,
    /// show them as two columns before the amount.
    private static func splitsAmount(_ groups: [ReportGroup]) -> Bool {
        var time = false
        var usage = false
        for group in groups {
            for line in group.lines {
                if line.timeAmount != nil { time = true }
                if line.usageAmount != nil { usage = true }
            }
        }
        return time && usage
    }

    private static func withAmountParts(_ columns: [ReportColumn], groups: [ReportGroup]) -> [ReportColumn] {
        guard let index = columns.firstIndex(of: .amount), splitsAmount(groups) else { return columns }
        var result = columns
        result.insert(contentsOf: [ReportColumn.timeAmount, ReportColumn.usageAmount], at: index)
        return result
    }

    private static func workSection(kind: ReportSectionKind, rows: [ReportRow], options: ReportOptions,
                                    names: [String: String]) -> ReportSection {
        let groupBy = effectiveGroupBy(options, kind: kind)
        let splitProviders = groupBy == .who
        var grouped: [Dimension?: [LineKey: [ReportRow]]] = [:]
        for row in rows {
            let group = groupDimension(row, groupBy: groupBy, names: names)
            let key = LineKey(detail: detailDimension(row, detail: options.detail),
                              who: whoClass(row, splitProviders: splitProviders, names: names))
            var lines = grouped[group] ?? [:]
            var members = lines[key] ?? []
            members.append(row)
            lines[key] = members
            grouped[group] = lines
        }

        let groupKeys: [Dimension?] = grouped.keys.sorted { a, b in
            guard let a else { return false }
            guard let b else { return true }
            return dimensionPrecedes(a, b)
        }
        var groups: [ReportGroup] = []
        for groupKey in groupKeys {
            let lines = grouped[groupKey] ?? [:]
            let lineKeys = lines.keys.sorted { linePrecedes($0, $1) }
            var built: [ReportLine] = []
            var groupRows: [ReportRow] = []
            for lineKey in lineKeys {
                let members = lines[lineKey] ?? []
                groupRows.append(contentsOf: members)
                let label = lineLabel(lineKey.detail, rows: members, groupBy: groupBy)
                built.append(merge(members, label: label, isTotal: false, entry: options.detail == .entry, names: names))
            }
            let title: ReportLabel? = groupKey.map { groupLabel($0) }
            let subtotal: ReportLine? = groupKey == nil
                ? nil : merge(groupRows, label: .subtotal, isTotal: true, entry: false, names: names)
            groups.append(ReportGroup(title: title, lines: built, subtotal: subtotal))
        }
        let shownColumns: [ReportColumn] = withAmountParts(columns(kind: kind, groupBy: groupBy, options: options),
                                                           groups: groups)
        let section = ReportSection(kind: kind, columns: shownColumns, groups: groups,
                                    total: merge(rows, label: .total, isTotal: true, entry: false, names: names))
        return reconcileHours(section)
    }

    private static func expenseSection(rows: [ReportRow], names: [String: String]) -> ReportSection {
        let sorted = rows.sorted { a, b in
            dimensionPrecedes(.entry(id: a.id, date: a.date, start: a.startedAt),
                              .entry(id: b.id, date: b.date, start: b.startedAt))
        }
        let lines = sorted.map { row in
            merge([row], label: .entry(description: row.description, project: row.project, task: row.task),
                  isTotal: false, entry: true, names: names)
        }
        return ReportSection(kind: .expenses, columns: [.date, .description, .amount],
                             groups: [ReportGroup(title: nil, lines: lines, subtotal: nil)],
                             total: merge(rows, label: .total, isTotal: true, entry: false, names: names))
    }

    private static func groupLabel(_ dimension: Dimension) -> ReportLabel {
        switch dimension {
        case .project(let name): return .project(name)
        case .day(let day): return .day(day)
        case .task(let project, let task): return .task(project: project, task: task)
        case .who(let who):
            switch who {
            case .you: return .who(ReportWhoValue(you: true, agents: []))
            case .agents: return .who(ReportWhoValue(you: false, agents: []))
            case .provider(let name): return .who(ReportWhoValue(you: false, agents: [name]))
            }
        case .entry(let id, _, _): return .entry(description: id, project: nil, task: nil)
        }
    }

    private static func lineLabel(_ dimension: Dimension, rows: [ReportRow], groupBy: ReportGroupBy) -> ReportLabel {
        let underProject = groupBy == .project || groupBy == .task
        switch dimension {
        case .project(let name):
            return .project(name)
        case .day(let day):
            return .day(day)
        case .task(let project, let task):
            return .task(project: underProject ? nil : project, task: task)
        case .entry:
            let row = rows.first
            let description: String = row?.description ?? ""
            let project: String? = underProject ? nil : row?.project
            let task: String? = groupBy == .task ? nil : row?.task
            if row?.kind == .agent && description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .agentSession(project: project, task: task)
            }
            return .entry(description: description, project: project, task: task)
        case .who(let who):
            return groupLabel(.who(who))
        }
    }

    // MARK: Hours

    /// Hundredths of an hour, rounded half up like `ReportNumber.hours`.
    static func roundedHundredths(_ millis: Int) -> Int {
        (max(0, millis) + 18_000) / 36_000
    }

    /// Whole minutes, rounded half up like the clock format.
    static func roundedMinutes(_ millis: Int) -> Int {
        (max(0, millis) + 30_000) / 60_000
    }

    /// Splits `target` units over `weights` in proportion, by largest remainder; ties go to the earlier one.
    /// The parts always add up to `target`, and a zero weight gets nothing.
    static func allocate(_ target: Int, weights: [Int]) -> [Int] {
        var parts: [Int] = Array(repeating: 0, count: weights.count)
        guard !weights.isEmpty else { return parts }
        let total: Int = weights.reduce(0) { $0 + max(0, $1) }
        guard total > 0 else {
            parts[0] = target
            return parts
        }
        var remainders: [(index: Int, remainder: Int)] = []
        var assigned = 0
        for (index, weight) in weights.enumerated() {
            let product: Int = target * max(0, weight)
            parts[index] = product / total
            assigned += parts[index]
            remainders.append((index: index, remainder: product % total))
        }
        let order = remainders.sorted { a, b in
            if a.remainder != b.remainder { return a.remainder > b.remainder }
            return a.index < b.index
        }
        var left = target - assigned
        var position = 0
        while left > 0 && position < order.count {
            parts[order[position].index] += 1
            left -= 1
            position += 1
        }
        return parts
    }

    private static func shown(_ line: ReportLine, hundredths: Int, minutes: Int) -> ReportLine {
        var result = line
        if line.hasTime {
            result.displayHours = Decimal(hundredths) / Decimal(100)
            result.displayMinutes = minutes
        } else {
            result.displayHours = nil
            result.displayMinutes = nil
        }
        return result
    }

    /// Printed hours that add up: the section total is the rounded true total, group subtotals share it out
    /// by largest remainder, and lines share out their group's subtotal the same way.
    private static func reconcileHours(_ section: ReportSection) -> ReportSection {
        var result = section
        let totalHundredths: Int = roundedHundredths(section.total.billedMillis)
        let totalMinutes: Int = roundedMinutes(section.total.billedMillis)
        result.total = shown(section.total, hundredths: totalHundredths, minutes: totalMinutes)
        let groupWeights: [Int] = section.groups.map { group in
            group.lines.reduce(0) { $0 + $1.billedMillis }
        }
        let groupHundredths: [Int] = allocate(totalHundredths, weights: groupWeights)
        let groupMinutes: [Int] = allocate(totalMinutes, weights: groupWeights)
        var groups: [ReportGroup] = []
        for (index, group) in section.groups.enumerated() {
            var next = group
            if let subtotal = group.subtotal {
                next.subtotal = shown(subtotal, hundredths: groupHundredths[index], minutes: groupMinutes[index])
            }
            let weights: [Int] = group.lines.map { $0.billedMillis }
            let hundredths: [Int] = allocate(groupHundredths[index], weights: weights)
            let minutes: [Int] = allocate(groupMinutes[index], weights: weights)
            var lines: [ReportLine] = []
            for (position, line) in group.lines.enumerated() {
                lines.append(shown(line, hundredths: hundredths[position], minutes: minutes[position]))
            }
            next.lines = lines
            groups.append(next)
        }
        result.groups = groups
        return result
    }

    /// The summary's hours for the person (`you`) or the agents: what their table lines show, added up,
    /// or the rounded true total when there is no table.
    private static func shownHours(sections: [ReportSection], you: Bool, rows: [ReportRow]) -> ReportShownHours {
        let workSections = sections.filter { $0.kind != .expenses }
        if workSections.isEmpty {
            let millis = rows.reduce(0) { $0 + $1.reportMillis }
            return ReportShownHours(hours: Decimal(roundedHundredths(millis)) / Decimal(100),
                                    minutes: roundedMinutes(millis))
        }
        var hours = Decimal(0)
        var minutes = 0
        for section in workSections {
            for group in section.groups {
                for line in group.lines where line.who.you == you {
                    hours += line.displayHours ?? Decimal(0)
                    minutes += line.displayMinutes ?? 0
                }
            }
        }
        return ReportShownHours(hours: hours, minutes: minutes)
    }

    // MARK: Sums

    private static func sumAmounts(_ rows: [ReportRow]) -> Decimal? {
        sumDecimals(rows.map { $0.amount })
    }

    /// The sum of the values that are set, or nil when none is.
    private static func sumDecimals(_ values: [Decimal?]) -> Decimal? {
        var total: Decimal? = nil
        for value in values {
            if let value { total = (total ?? Decimal(0)) + value }
        }
        return total
    }

    private static func merge(_ rows: [ReportRow], label: ReportLabel, isTotal: Bool, entry: Bool,
                              names: [String: String]) -> ReportLine {
        var billed = 0
        var worked = 0
        var tokens = 0
        var you = false
        var agents = Set<String>()
        var models = Set<String>()
        var dates = Set<String>()
        var rate: Decimal? = nil
        var rateConflict = false
        for (index, row) in rows.enumerated() {
            billed += row.reportMillis
            worked += row.millis
            tokens += row.tokens.total
            if row.kind == .you { you = true }
            if row.kind == .agent, row.provider != nil { agents.insert(providerLabel(row, names: names)) }
            for model in row.models { models.insert(model) }
            dates.insert(row.date)
            if index == 0 {
                rate = row.rate
            } else if row.rate != rate {
                rateConflict = true
            }
        }
        let first = rows.first
        return ReportLine(
            label: label,
            date: dates.count == 1 ? dates.first : nil,
            startedAt: entry ? first?.startedAt : nil,
            endedAt: entry ? first?.endedAt : nil,
            who: ReportWhoValue(you: you, agents: agents.sorted { textPrecedes($0, $1) }),
            billedMillis: billed,
            workedMillis: worked,
            displayHours: nil,
            displayMinutes: nil,
            rate: rateConflict ? nil : rate,
            timeAmount: sumDecimals(rows.map { $0.timeAmount }),
            usageAmount: sumDecimals(rows.map { $0.usageAmount }),
            amount: sumAmounts(rows),
            tokens: tokens,
            apiUsd: sumDecimals(rows.map { $0.apiUsd }),
            models: models.sorted { textPrecedes($0, $1) },
            rowCount: rows.count,
            isTotal: isTotal)
    }
}
