import Foundation

/// A calendar day like Python's `datetime.date` (proleptic Gregorian), independent of time zones.
struct Day: Hashable, Comparable, Sendable {
    let year: Int, month: Int, day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// Days since 0001-01-01 is day 1, like `date.toordinal()`.
    init(ordinal: Int) {
        // Algorithm from Python's datetime module (_ord2ymd).
        var n = ordinal - 1
        let n400 = n / 146_097; n %= 146_097
        var year = n400 * 400 + 1
        let n100 = n / 36524; n %= 36524
        let n4 = n / 1461; n %= 1461
        let n1 = n / 365; n %= 365
        year += n100 * 100 + n4 * 4 + n1
        if n1 == 4 || n100 == 4 {
            self.init(year: year - 1, month: 12, day: 31)
            return
        }
        let leap = n1 == 3 && (n4 != 24 || n100 == 3)
        var month = (n + 50) >> 5
        var preceding = Day.daysBefore[month] + (month > 2 && leap ? 1 : 0)
        if preceding > n {
            month -= 1
            preceding -= Day.daysIn(month, leap: leap)
        }
        self.init(year: year, month: month, day: n - preceding + 1)
    }

    private static let daysBefore = [0, 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334, 365]
    private static func daysIn(_ month: Int, leap: Bool) -> Int {
        [0, 31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31][month]
    }
    static func isLeap(_ year: Int) -> Bool { year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) }

    var ordinal: Int {
        let y = year - 1
        return y * 365 + y / 4 - y / 100 + y / 400 + Day.daysBefore[month] + (month > 2 && Day.isLeap(year) ? 1 : 0) + day
    }

    func adding(days: Int) -> Day { Day(ordinal: ordinal + days) }

    /// Monday is 0, like `date.weekday()`.
    var weekday: Int { (ordinal + 6) % 7 }

    var iso: String { String(format: "%04d-%02d-%02d", year, month, day) }

    var firstOfMonth: Day { Day(year: year, month: month, day: 1) }
    var firstOfNextMonth: Day { month == 12 ? Day(year: year + 1, month: 1, day: 1) : Day(year: year, month: month + 1, day: 1) }

    static func < (lhs: Day, rhs: Day) -> Bool { lhs.ordinal < rhs.ordinal }

    /// `date.fromisoformat` (Python 3.9: exactly YYYY-MM-DD).
    static func parse(_ text: String) throws -> Day {
        let scalars = Array(text.unicodeScalars)
        func digits(_ range: Range<Int>) -> Int? {
            guard range.upperBound <= scalars.count else { return nil }
            var value = 0
            for scalar in scalars[range] {
                guard scalar.value >= 48, scalar.value <= 57 else { return nil }
                value = value * 10 + Int(scalar.value - 48)
            }
            return value
        }
        guard scalars.count == 10, scalars[4] == "-", scalars[7] == "-",
              let year = digits(0..<4), let month = digits(5..<7), let day = digits(8..<10) else {
            throw EngineError.invalid("Invalid isoformat string: \(pythonRepr(text))")
        }
        guard year >= 1 else { throw EngineError.invalid("year \(year) is out of range") }
        guard (1...12).contains(month) else { throw EngineError.invalid("month must be in 1..12") }
        guard day >= 1, day <= daysIn(month, leap: isLeap(year)) else { throw EngineError.invalid("day is out of range for month") }
        return Day(year: year, month: month, day: day)
    }

    /// The local day of an epoch-millisecond timestamp.
    static func local(_ millis: Int, _ zone: TimeZone) -> Day {
        let parts = TimeZones.calendar(zone).dateComponents([.year, .month, .day],
                                                          from: Date(timeIntervalSince1970: Double(millis) / 1000))
        return Day(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    /// Epoch milliseconds of this day's local midnight (`datetime.combine(day, time.min, tz).timestamp()`).
    func midnight(_ zone: TimeZone) -> Int {
        Focus.midnight(DateComponents(year: year, month: month, day: day), zone: zone)
    }

    /// "YYYY-MM" of a timestamp in the zone (`strftime("%Y-%m")`).
    static func month(_ millis: Int, _ zone: TimeZone) -> String {
        let day = local(millis, zone)
        return String(format: "%04d-%02d", day.year, day.month)
    }
}

enum TimeZones {
    private static var calendars: [String: Calendar] = [:]
    private static let lock = NSLock()

    static func calendar(_ zone: TimeZone) -> Calendar {
        lock.lock()
        defer { lock.unlock() }
        if let found = calendars[zone.identifier] { return found }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendars[zone.identifier] = calendar
        return calendar
    }
}

/// Python's `repr()` of a string, for messages that quote input.
func pythonRepr(_ text: String) -> String {
    let quote: Character = text.contains("'") && !text.contains("\"") ? "\"" : "'"
    var out = String(quote)
    for scalar in text.unicodeScalars {
        switch scalar {
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        case "\t": out += "\\t"
        default:
            if Character(scalar) == quote {
                out += "\\" + String(quote)
            } else if scalar.value < 0x20 || scalar.value == 0x7F {
                out += String(format: "\\x%02x", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
    }
    out.append(quote)
    return out
}

/// Python's ordering of strings: by code point.
@inline(__always)
func pyLess(_ a: String, _ b: String) -> Bool {
    a.unicodeScalars.lexicographicallyPrecedes(b.unicodeScalars)
}

@inline(__always)
func pyEqual(_ a: String?, _ b: String?) -> Bool {
    switch (a, b) {
    case (nil, nil): true
    case let (x?, y?): x.utf8.elementsEqual(y.utf8)
    default: false
    }
}

extension Sequence {
    /// A stable sort, like Python's `sorted`.
    func stableSorted(by less: (Element, Element) -> Bool) -> [Element] {
        Array(self).enumerated().sorted { a, b in
            if less(a.element, b.element) { return true }
            if less(b.element, a.element) { return false }
            return a.offset < b.offset
        }.map(\.element)
    }
}

/// Insertion-ordered dictionary, like Python's dict.
struct Ordered<Key: Hashable, Value> {
    private(set) var keys: [Key] = []
    private var storage: [Key: Value] = [:]

    subscript(_ key: Key) -> Value? {
        get { storage[key] }
        set {
            if storage[key] == nil, newValue != nil { keys.append(key) }
            if newValue == nil, storage[key] != nil { keys.removeAll { $0 == key } }
            storage[key] = newValue
        }
    }

    subscript(_ key: Key, default fallback: @autoclosure () -> Value) -> Value {
        get { storage[key] ?? fallback() }
        set {
            if storage[key] == nil { keys.append(key) }
            storage[key] = newValue
        }
    }

    /// Appends to the list stored under `key` in place (no copy of the list).
    mutating func append<Element>(_ element: Element, to key: Key) where Value == [Element] {
        if storage[key] == nil { keys.append(key) }
        storage[key, default: []].append(element)
    }

    var values: [Value] { keys.map { storage[$0]! } }
    var pairs: [(Key, Value)] { keys.map { ($0, storage[$0]!) } }
    var count: Int { keys.count }
    var isEmpty: Bool { keys.isEmpty }
}

/// One ledger record as `store.entries_for` yields it: a stored entry, an approved activity block,
/// or Toggl time, with the project resolved and the client and project kind added.
struct Entry {
    enum Source { case record, automatic, toggl }

    var source: Source
    var id: String
    var kind: String
    var at: Int
    var provider: String?
    var model: String?
    var session: String?
    var folder: String?
    var branch: String?
    var task: String?
    var project: String?
    var label: String?
    var millis: Int?
    var input: Int?
    var cached: Int?
    var cacheWrite: Int?
    var output: Int?
    var cents: Int?
    var reimbursable: Int?
    var promptTokens: Int?
    var cacheWrite1h: Int?
    var reasoning: Int?
    var tier: String?
    var recordedUSD: String?
    var webSearches: Int?
    var dedupeKey: String?
    var replica: Int?
    /// The stored row, kept for output in column order (records only).
    var row: Row?
    // Fields added for automatic and agent entries.
    var tag: String?
    var hasGitHub = false
    var githubRepo: String?
    var githubPR: Int?
    var hasPullRequest = false
    var pullRequest: JSON = .null
    var client: String?
    var projectKind: String?

    /// Python's `entry.get("time_source")`: None for stored records.
    var timeSource: String? {
        switch source {
        case .record: nil
        case .automatic: "automatic"
        case .toggl: "toggl"
        }
    }

    /// The token count fields (`TOKEN_FIELDS`), with missing values as zero.
    var tokenTotal: Int { (input ?? 0) + (cached ?? 0) + (cacheWrite ?? 0) + (output ?? 0) }

    func tokens(_ field: String) -> Int? {
        switch field {
        case "input": input
        case "cached": cached
        case "cache_write": cacheWrite
        case "output": output
        default: nil
        }
    }

    static let fields = ["id", "kind", "at", "provider", "model", "session", "folder", "branch", "task", "project",
                         "label", "millis", "input", "cached", "cache_write", "output", "cents", "reimbursable",
                         "prompt_tokens", "cache_write_1h", "reasoning", "tier", "recorded_usd", "web_searches",
                         "dedupe_key", "replica"]

    private func value(_ field: String) -> JSON {
        switch field {
        case "id": .string(id)
        case "kind": .string(kind)
        case "at": .int(Int64(at))
        case "provider": .optional(provider)
        case "model": .optional(model)
        case "session": .optional(session)
        case "folder": .optional(folder)
        case "branch": .optional(branch)
        case "task": .optional(task)
        case "project": .optional(project)
        case "label": .optional(label)
        case "millis": .optional(millis)
        case "input": .optional(input)
        case "cached": .optional(cached)
        case "cache_write": .optional(cacheWrite)
        case "output": .optional(output)
        case "cents": .optional(cents)
        case "reimbursable": .optional(reimbursable)
        case "prompt_tokens": .optional(promptTokens)
        case "cache_write_1h": .optional(cacheWrite1h)
        case "reasoning": .optional(reasoning)
        case "tier": .optional(tier)
        case "recorded_usd": .optional(recordedUSD)
        case "web_searches": .optional(webSearches)
        case "dedupe_key": .optional(dedupeKey)
        case "replica": .optional(replica)
        default: .null
        }
    }

    /// The entry as the Python dict prints it, keys in the same order.
    var json: JSON {
        var object: JSON
        if let row {
            object = row.object
            object.set("project", .optional(project))
        } else {
            object = .object(Entry.fields.map { ($0, value($0)) })
        }
        if source != .record {
            object.set("time_source", .optional(timeSource))
        }
        if source == .automatic {
            object.set("tag", .optional(tag))
        }
        if hasGitHub {
            object.set("github_repo", .optional(githubRepo))
            object.set("github_pr", .optional(githubPR))
        }
        if hasPullRequest { object.set("pull_request", pullRequest) }
        object.set("client", .optional(client))
        object.set("project_kind", .optional(projectKind))
        return object
    }
}

extension Optional where Wrapped == String {
    /// Python truthiness of an optional string: nil and "" are false.
    var nonEmpty: String? {
        guard let value = self, !value.isEmpty else { return nil }
        return value
    }
}

enum EntryStore {
    /// Python's `store.day_range`: the local dates and epoch bounds of a week, a month or explicit dates.
    static func dayRange(_ db: Database, start: String?, end: String?, period: String) throws
        -> (first: String, last: String, since: Int, until: Int) {
        let zone = try Store.timezone(db)
        let first: Day, last: Day
        if start == nil && end == nil {
            let today = Day.local(Values.nowMillis(), zone)
            switch period {
            case "month":
                first = today.firstOfMonth
                last = first.firstOfNextMonth
            case "week":
                first = today.adding(days: -today.weekday)
                last = first.adding(days: 7)
            default:
                throw EngineError.invalid("Period must be week or month")
            }
        } else {
            guard let start, !start.isEmpty, let end, !end.isEmpty else {
                throw EngineError.invalid("Provide both start and end dates (end is exclusive)")
            }
            first = try Day.parse(start)
            last = try Day.parse(end)
        }
        guard first < last else { throw EngineError.invalid("End must be later than start") }
        return (first.iso, last.iso, first.midnight(zone), last.midnight(zone))
    }

    /// Python's `reports.scope`: the period's bounds and its entries.
    static func scope(_ db: Database, start: String?, end: String?, period: String,
                      worktreeRepos: (String) -> [String] = GitHub.worktreeRepos) throws -> (bounds: JSON, entries: [Entry]) {
        let range = try dayRange(db, start: start, end: end, period: period)
        let bounds = JSON.object([
            ("start", .string(range.first)), ("end_exclusive", .string(range.last)),
            ("timezone", .string(try Store.timezoneName(db))), ("currency", .string(try Store.currency(db))),
        ])
        return (bounds, try entries(db, since: range.since, until: range.until, worktreeRepos: worktreeRepos))
    }

    private static func int(_ value: SQLValue) -> Int? {
        switch value {
        case let .integer(number): Int(number)
        case let .real(number): Int(number)
        default: nil
        }
    }

    /// A stored entry row as an `Entry` (Python's `dict(row)`).
    static func record(_ row: Row) -> Entry {
        Entry(source: .record, id: row["id"].string ?? "", kind: row["kind"].string ?? "", at: int(row["at"]) ?? 0,
              provider: row["provider"].string, model: row["model"].string, session: row["session"].string,
              folder: row["folder"].string, branch: row["branch"].string, task: row["task"].string,
              project: row["project"].string, label: row["label"].string, millis: int(row["millis"]),
              input: int(row["input"]), cached: int(row["cached"]), cacheWrite: int(row["cache_write"]),
              output: int(row["output"]), cents: int(row["cents"]), reimbursable: int(row["reimbursable"]),
              promptTokens: int(row["prompt_tokens"]), cacheWrite1h: int(row["cache_write_1h"]),
              reasoning: int(row["reasoning"]), tier: row["tier"].string, recordedUSD: row["recorded_usd"].string,
              webSearches: int(row["web_searches"]), dedupeKey: row["dedupe_key"].string, replica: int(row["replica"]),
              row: row)
    }

    /// Python's `store.entries_for`: every record in [since, until), sorted by time and id.
    static func entries(_ db: Database, since: Int, until: Int,
                        worktreeRepos: (String) -> [String] = GitHub.worktreeRepos) throws -> [Entry] {
        var projects: [String: (client: String?, kind: String?)] = [:]
        for row in try db.query("SELECT * FROM projects") {
            if let name = row["name"].string { projects[name] = (row["client"].string, row["kind"].string) }
        }
        let folders: [(path: String, prefix: String, project: String)] = try db.query("SELECT * FROM folders ORDER BY length(path) DESC, path")
            .compactMap { row in
                guard let path = row["path"].string, let project = row["project"].string else { return nil }
                var trimmed = Substring(path)
                while trimmed.hasSuffix("/") { trimmed = trimmed.dropLast() }
                return (path, trimmed + "/", project)
            }
        var entries: [Entry] = []
        for row in try db.query("SELECT * FROM entries WHERE at >= ? AND at < ?", [since, until]) {
            entries.append(record(row))
        }
        let approved = try db.query(
            "SELECT focus_blocks.*, focus_matches.tag, focus_github.repo, focus_github.number "
            + "FROM focus_blocks LEFT JOIN focus_matches ON focus_matches.block_id = focus_blocks.id "
            + "LEFT JOIN focus_github ON focus_github.block_id = focus_blocks.id "
            + "WHERE project IS NOT NULL AND closed = 1 "
            + "AND ignored = 0 AND ended_at > ? AND started_at < ?", [since, until])
        for row in approved {
            let started = int(row["started_at"]) ?? 0, ended = int(row["ended_at"]) ?? 0
            var entry = Entry(source: .automatic, id: "focus:" + (row["id"].string ?? ""), kind: "human",
                              at: max(started, since), project: row["project"].string, label: row["app_name"].string,
                              millis: min(ended, until) - max(started, since), input: 0, cached: 0, cacheWrite: 0,
                              output: 0, reimbursable: 0)
            entry.tag = row["tag"].string
            entry.hasGitHub = true
            entry.githubRepo = row["repo"].string
            entry.githubPR = int(row["number"])
            entries.append(entry)
        }
        for row in try Focus.togglIntervals(db, start: since, end: until) {
            let started = int(row["started_at"]) ?? 0, ended = int(row["ended_at"]) ?? 0
            entries.append(Entry(source: .toggl, id: row["id"].string ?? "", kind: "human", at: started,
                                 project: row["project"].string, label: "Toggl Track", millis: ended - started,
                                 input: 0, cached: 0, cacheWrite: 0, output: 0, reimbursable: 0))
        }
        entries = entries.stableSorted { a, b in a.at != b.at ? a.at < b.at : pyLess(a.id, b.id) }

        let routes = try GitHub.routes(db)
        let byBranch = routes.isEmpty ? [:] : try GitHub.linksByBranch(db)
        var worktrees: [String: [String]] = [:]
        var folderProjects: [Data: String?] = [:]
        func projectForFolder(_ folder: String) -> String? {
            let key = Data(folder.utf8)
            if let checked = folderProjects[key] { return checked }
            let project = folders.first { folder.utf8.elementsEqual($0.path.utf8) || folder.utf8.starts(with: $0.prefix.utf8) }?.project
            folderProjects.updateValue(project, forKey: key)
            return project
        }
        for index in entries.indices {
            var entry = entries[index]
            var name = entry.project
            let folderProject = entry.folder.nonEmpty.flatMap(projectForFolder)
            if !routes.isEmpty, entry.provider.nonEmpty != nil {
                if let folder = entry.folder.nonEmpty, worktrees[folder] == nil {
                    worktrees[folder] = worktreeRepos(folder)
                }
                let local = entry.folder.nonEmpty.flatMap { worktrees[$0] } ?? []
                let context = GitHub.agentContext(routes: routes, byBranch: byBranch, localRepos: local,
                                                  project: name.nonEmpty ?? folderProject.nonEmpty, branch: entry.branch)
                if let repo = context.repo, let route = routes.first(where: { $0.0 == repo })?.1 {
                    let number = context.pullRequest?["number"].intValue
                    name = name.nonEmpty ?? route.project(forPullRequest: number).nonEmpty ?? folderProject.nonEmpty ?? route.project
                    entry.hasGitHub = true
                    entry.githubRepo = repo
                    entry.githubPR = number
                    entry.hasPullRequest = true
                    entry.pullRequest = context.pullRequest ?? .null
                }
            }
            name = name.nonEmpty ?? folderProject
            entry.project = name
            let project = name.flatMap { projects[$0] }
            entry.client = project?.client
            entry.projectKind = project?.kind
            entries[index] = entry
        }
        return entries
    }
}
