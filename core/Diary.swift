import Foundation

struct DiaryClock: Equatable, Sendable {
    var zone: TimeZone
    var cutoff: Int

    static func minutes(_ text: String) throws -> Int {
        let digits = Array(text.utf8)
        guard digits.count == 5, digits[2] == 58,
              [0, 1, 3, 4].allSatisfy({ (48...57).contains(digits[$0]) }) else {
            throw EngineError.invalid("Use a time in HH:mm format.")
        }
        let hour = Int(digits[0] - 48) * 10 + Int(digits[1] - 48)
        let minute = Int(digits[3] - 48) * 10 + Int(digits[4] - 48)
        guard hour < 24, minute < 60 else { throw EngineError.invalid("Use a valid 24-hour time.") }
        return hour * 60 + minute
    }

    static func label(_ minutes: Int) -> String {
        String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    func calendarDay(_ date: Date) -> Day { Day.local(Self.millis(date), zone) }

    /// A workday is named after the calendar day it mostly covers. With an early cutoff (before noon, such as
    /// 05:00) that is the day it starts on, so work done after midnight counts toward the previous day. With a
    /// late cutoff (noon or later, such as 23:00) it is the day it ends on, so work after the cutoff counts
    /// toward the next day.
    var namesByEnd: Bool { cutoff >= 12 * 60 }

    func workday(_ date: Date) -> Day {
        let day = calendarDay(date)
        if namesByEnd { return date < instant(day, at: cutoff) ? day : day.adding(days: 1) }
        return date < instant(day, at: cutoff) ? day.adding(days: -1) : day
    }

    func instant(_ day: Day, at minutes: Int) -> Date {
        let midnight = Self.date(day.midnight(zone))
        if minutes == 0 { return midnight }
        // Use the first occurrence on a fall transition and the next valid wall time in a spring gap.
        return TimeZones.calendar(zone).date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0,
                                             of: midnight, matchingPolicy: .nextTime,
                                             repeatedTimePolicy: .first) ?? midnight
    }

    func window(_ day: Day) -> DiaryWindow {
        let first = namesByEnd ? day.adding(days: -1) : day
        return DiaryWindow(start: Self.millis(instant(first, at: cutoff)),
                           end: Self.millis(instant(first.adding(days: 1), at: cutoff)), timezone: zone.identifier)
    }

    /// The calendar day a workday ends on, when a run time on that day falls.
    func endDay(_ day: Day) -> Day { namesByEnd ? day : day.adding(days: 1) }

    static func millis(_ date: Date) -> Int { Int((date.timeIntervalSince1970 * 1000).rounded(.down)) }
    static func date(_ millis: Int) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }
}

struct DiaryWindow: Codable, Equatable, Sendable {
    let start: Int
    let end: Int
    let timezone: String
}

enum DiaryAgent: String, CaseIterable, Identifiable, Codable, Sendable {
    case codex, claude
    var id: Self { self }
    var title: String { self == .codex ? "Codex" : "Claude Code" }
}

struct DiaryRoutine: Codable, Equatable, Sendable {
    static let briefTemplate = """
    Evidence. Review my work for this project in GitHub, project chats, Slack, the calendar, and meeting notes \
    from Granola or another connected tool. Stick to the project’s repos, channels, and events. Keep other \
    clients and personal activity out. Use PR descriptions and reviews to check why a change mattered and \
    what shipped. Summarize discussions only when notes, transcripts, or documented follow-ups support them.

    Diary. Lead with one outcome in the headline and summarize why it mattered in one or two sentences. \
    Group related work by ticket or area when helpful. Link to the evidence for outcomes and decisions. \
    Add a short “Calls” or “If asked” section when the details would help a teammate. Flag important gaps in the evidence.

    Blockers and next steps. Check that each blocker is still open. Say what is blocked, what or whom it \
    waits on, and since when if you can verify it. Put my own to-dos under Suggested next. Give up to three \
    concrete next steps, each with a reason grounded in the current evidence.

    Standup. On active days, write a 30–45 second first-person update, roughly 80–110 words. Give a sentence \
    of context, explain why the main outcome mattered, mention any real blocker, and end with what I plan to do \
    next. Name PRs by what they change. Use plain spoken language.
    """

    var id = UUID()
    var agent: DiaryAgent = .codex
    var brief = DiaryRoutine.briefTemplate
    /// nil makes the completed day due at the cutoff.
    var runMinute: Int?
    var firstDay: String
}

struct DiarySource: Codable, Equatable, Hashable, Sendable {
    let title: String
    let url: URL

    var isValid: Bool {
        !title.pythonStripped.isEmpty && title.count <= 250 && url.absoluteString.count <= 4096
            && ["https", "http"].contains(url.scheme?.lowercased() ?? "")
            && url.host?.isEmpty == false && url.user == nil && url.password == nil && url.baseURL == nil
    }
}

struct DiarySection: Codable, Equatable, Sendable {
    let title: String
    let text: String
    var sources: [DiarySource]?
}

struct DiaryContent: Codable, Equatable, Sendable {
    var headline: String
    var summary: String
    var standup: String?
    var outcomes: String?
    var decisions: String?
    var blockers: String?
    var nextSteps: String?
    var sections: [DiarySection]?
    var sources: [DiarySource]?

    enum CodingKeys: String, CodingKey {
        case headline, summary, standup, outcomes, decisions, blockers, sections, sources
        case nextSteps = "next_steps"
    }

    static let fields: [(key: String, title: String, value: KeyPath<Self, String?>)] = [
        ("outcomes", "What changed", \.outcomes), ("decisions", "Decisions", \.decisions),
        ("blockers", "Waiting on", \.blockers), ("next_steps", "Suggested next", \.nextSteps),
    ]

    var allSources: [DiarySource] {
        var seen = Set<DiarySource>()
        return ((sources ?? []) + (sections ?? []).flatMap { $0.sources ?? [] }).filter { seen.insert($0).inserted }
    }

    func validate() throws {
        let sections = sections ?? []
        guard !headline.pythonStripped.isEmpty, headline.count <= 250, !summary.pythonStripped.isEmpty,
              ([summary, standup] + Self.fields.map { self[keyPath: $0.value] }).compactMap({ $0 })
                  .allSatisfy({ $0.count <= 12_000 }),
              sections.count <= 20,
              Set(sections.map(\.title)).count == sections.count,
              sections.allSatisfy({ !$0.title.pythonStripped.isEmpty && $0.title.count <= 100 && $0.text.count <= 12_000 }),
              (sources ?? []).count + sections.reduce(0, { $0 + ($1.sources ?? []).count }) <= 100,
              allSources.allSatisfy(\.isValid) else {
            throw EngineError.invalid("Provide a headline, a summary, distinct section titles, and valid HTTP or HTTPS source links.")
        }
    }
}

struct DiaryEntry: Identifiable, Sendable {
    let project: String
    let client: String?
    let day: String
    let window: DiaryWindow
    let through: Int
    let revision: Int
    let content: DiaryContent
    let edits: [String: String]

    var id: String { project }
    var early: Bool { through < window.end }
    var headline: String { edits["headline"] ?? content.headline }
    var summary: String { edits["summary"] ?? content.summary }
    var standup: String { edits["standup"] ?? content.standup ?? "" }

    var details: [DiarySection] {
        let standard = DiaryContent.fields.compactMap { field -> DiarySection? in
            guard let text = edits[field.key] ?? content[keyPath: field.value], !text.isEmpty else { return nil }
            return DiarySection(title: field.title, text: text)
        }
        return standard + customSections.filter { !$0.text.isEmpty || !($0.sources ?? []).isEmpty }
    }

    var customSections: [DiarySection] {
        let written = content.sections ?? []
        let keys = Set(written.map { "section/" + $0.title })
        let retained = edits.keys.filter { $0.hasPrefix("section/") && !keys.contains($0) }.sorted()
        return written.map { DiarySection(title: $0.title, text: edits["section/" + $0.title] ?? $0.text, sources: $0.sources) }
            + retained.map { DiarySection(title: String($0.dropFirst(8)), text: edits[$0] ?? "") }
    }
}

struct DiaryPageData {
    let entries: [DiaryEntry]

    init(_ entries: [DiaryEntry], client: String?, project: String?) {
        self.entries = entries.filter { (client == nil || $0.client == client) && (project == nil || $0.project == project) }
    }

    var standup: String {
        entries.compactMap { entry in
            let copy = entry.standup.pythonStripped
            return copy.isEmpty ? nil : copy
        }.joined(separator: "\n\n")
    }
}

/// The Diary page's timeline, newest first: one row per workday with entries, and quiet stretches folded into
/// a single row. The current workday always gets its own row, since its entry is still to come.
enum DiaryTimeline {
    enum Row: Identifiable {
        case day(String, [DiaryEntry])
        /// Days with no entry, from the oldest to the newest.
        case quiet(from: String, to: String)

        var id: String {
            switch self {
            case let .day(day, _): day
            case let .quiet(from, _): "quiet/" + from
            }
        }
    }

    static func rows(_ entries: [DiaryEntry], from first: Day, through last: Day) -> [Row] {
        guard first <= last else { return [] }
        let byDay = Dictionary(grouping: entries, by: \.day)
        var rows: [Row] = []
        for ordinal in stride(from: last.ordinal, through: first.ordinal, by: -1) {
            let day = Day(ordinal: ordinal).iso
            if let entries = byDay[day], !entries.isEmpty {
                rows.append(.day(day, entries))
            } else if case let .quiet(_, to)? = rows.last, to != last.iso {
                // Rows run newest first, so a quiet stretch grows backwards to an older `from`.
                rows[rows.count - 1] = .quiet(from: day, to: to)
            } else {
                rows.append(.quiet(from: day, to: day))
            }
        }
        return rows
    }
}

enum DiaryStore {
    static let changed = Notification.Name("com.domenicodidonna.tracker.diaryChanged")

    static func clock(_ db: Database) throws -> DiaryClock {
        let zone = try Store.setting(db, "diary_timezone") ?? Store.timezoneName(db)
        let cutoff = try DiaryClock.minutes(Store.setting(db, "diary_cutoff", "05:00"))
        return DiaryClock(zone: try Values.zone(zone), cutoff: cutoff)
    }

    static func saveClock(_ db: Database, _ clock: DiaryClock) throws {
        try Store.setSetting(db, "diary_timezone", clock.zone.identifier)
        try Store.setSetting(db, "diary_cutoff", DiaryClock.label(clock.cutoff))
    }

    /// Entries written before late cutoffs were named by the day they end on carry the day they start on, such
    /// as "Nov 24" for 24 Nov 23:00 to 25 Nov 23:00. Renames them to the day they mostly cover. Safe to run on
    /// every open: a renamed entry no longer starts on its own date.
    static func renameLateWorkdays(_ db: Database) throws {
        let rows = try db.query("SELECT project, work_date, window FROM diary_entries ORDER BY work_date DESC")
        var renames: [(project: String, from: String, to: String)] = []
        for row in rows {
            guard let project = row["project"].string, let key = row["work_date"].string,
                  let day = try? Day.parse(key),
                  let window = try? decode(DiaryWindow.self, row["window"].string),
                  let zone = TimeZone(identifier: window.timezone) else { continue }
            let start = DiaryClock.date(window.start)
            let parts = TimeZones.calendar(zone).dateComponents([.hour], from: start)
            guard Day.local(window.start, zone) == day, (parts.hour ?? 0) >= 12 else { continue }
            renames.append((project, key, day.adding(days: 1).iso))
        }
        guard !renames.isEmpty else { return }
        try db.transaction {
            for rename in renames {
                guard try db.first("SELECT 1 FROM diary_entries WHERE project = ? AND work_date = ?",
                                   [rename.project, rename.to]) == nil else { continue }
                try db.execute("UPDATE diary_entries SET work_date = ? WHERE project = ? AND work_date = ?",
                               [rename.to, rename.project, rename.from])
            }
        }
    }

    static func routine(_ db: Database, project: String) throws -> DiaryRoutine? {
        guard let row = try db.first("SELECT * FROM diary_routines WHERE project = ?", [project]) else { return nil }
        return try decode(DiaryRoutine.self, row["profile"].string)
    }

    static func saveRoutine(_ db: Database, project: String, _ routine: DiaryRoutine) throws {
        try db.execute("""
            INSERT INTO diary_routines (project, id, profile) VALUES (?, ?, ?)
            ON CONFLICT(project) DO UPDATE SET profile = excluded.profile
            """, [project, routine.id.uuidString, try encode(routine)])
    }

    static func project(_ db: Database, routine id: UUID) throws -> String {
        guard let name = try db.first("SELECT project FROM diary_routines WHERE id = ?", [id.uuidString])?[0].string else {
            throw EngineError.notFound("This Diary routine could not be found. Check its setup in Daylanes.")
        }
        return name
    }

    static func days(_ db: Database) throws -> [String] {
        try db.query("SELECT DISTINCT work_date FROM diary_entries ORDER BY work_date DESC").compactMap { $0[0].string }
    }

    private static let entriesSQL = """
        SELECT e.*, p.client FROM diary_entries e JOIN projects p ON p.name = e.project
        """

    static func entries(_ db: Database, day: String) throws -> [DiaryEntry] {
        try db.query(entriesSQL + " WHERE work_date = ? ORDER BY p.name COLLATE NOCASE, p.name", [day]).map(entry)
    }

    /// Entries from `first` through `last` (ISO days), newest day first.
    static func entries(_ db: Database, from first: String, through last: String) throws -> [DiaryEntry] {
        try db.query(entriesSQL + " WHERE work_date BETWEEN ? AND ? ORDER BY work_date DESC, p.name COLLATE NOCASE, p.name",
                     [first, last]).map(entry)
    }

    static func entry(_ db: Database, project: String, day: String) throws -> DiaryEntry? {
        try db.first(entriesSQL + " WHERE e.project = ? AND work_date = ?", [project, day]).map(entry)
    }

    private static func entry(_ row: Row) throws -> DiaryEntry {
        DiaryEntry(project: row["project"].string ?? "", client: row["client"].string, day: row["work_date"].string ?? "",
                   window: try decode(DiaryWindow.self, row["window"].string), through: row["through"].int ?? 0,
                   revision: row["revision"].int ?? 0, content: try decode(DiaryContent.self, row["content"].string),
                   edits: try decode([String: String].self, row["edits"].string))
    }

    static func saveEdits(_ db: Database, entry: DiaryEntry, edits: [String: String]) throws {
        try db.execute("UPDATE diary_entries SET edits = ? WHERE project = ? AND work_date = ?",
                       [try encode(edits), entry.project, entry.day])
    }

    struct Work {
        let day: Day
        let window: DiaryWindow
        let through: Int
        let draft: DiaryEntry?
    }

    static func work(_ db: Database, project: String, routine: DiaryRoutine, day requested: Day? = nil,
                     now: Date = .now) throws -> Work? {
        let clock = try clock(db)
        let first = try Day.parse(routine.firstDay)
        let stamp = DiaryClock.millis(now)
        func workFor(_ day: Day) throws -> Work? {
            let draft = try entry(db, project: project, day: day.iso)
            let window = draft?.window ?? clock.window(day)
            guard stamp > window.start else { return nil }
            return Work(day: day, window: window, through: min(stamp, window.end), draft: draft)
        }
        if let requested { return try workFor(requested) }
        // The newest workday that may have started a scheduled run: yesterday, or today when days are named
        // by the day they end on.
        let last = clock.namesByEnd ? clock.calendarDay(now) : clock.calendarDay(now).adding(days: -1)
        guard first <= last else { return nil }
        let complete = Set(try db.query("""
            SELECT work_date FROM diary_entries WHERE project = ? AND work_date BETWEEN ? AND ?
            AND through >= json_extract(window, '$.end')
            """, [project, first.iso, last.iso]).compactMap { $0[0].string })
        for ordinal in first.ordinal...last.ordinal {
            let day = Day(ordinal: ordinal)
            if complete.contains(day.iso) { continue }
            guard let work = try workFor(day) else { continue }
            // An existing draft keeps its original boundary even if the diary clock was changed.
            let zone = TimeZone(identifier: work.window.timezone) ?? clock.zone
            let runClock = DiaryClock(zone: zone, cutoff: clock.cutoff)
            let next = runClock.endDay(day)
            let scheduled = routine.runMinute.map { DiaryClock.millis(runClock.instant(next, at: $0)) } ?? work.window.end
            if stamp >= max(scheduled, work.window.end) { return work }
            if stamp >= scheduled, stamp < work.window.end, work.draft == nil { return work }
        }
        return nil
    }

    /// Called under the engine's immediate transaction. The writer never touches the user's edits.
    static func submit(_ db: Database, project: String, work: Work, through: Int, revision: Int,
                       content: DiaryContent) throws -> Bool {
        try content.validate()
        guard through > work.window.start, through <= work.through else {
            throw EngineError.invalid("Use the evidence cutoff returned by get_diary_work.")
        }
        let old = work.draft
        if let old, old.through == through, old.content == content { return false }
        guard revision == (old?.revision ?? 0), through >= (old?.through ?? work.window.start) else {
            throw EngineError.conflict("The agent draft changed. Fetch the current work date and draft before submitting again.")
        }
        try db.execute("""
            INSERT INTO diary_entries (project, work_date, window, through, revision, content)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(project, work_date) DO UPDATE
            SET through = excluded.through, revision = excluded.revision, content = excluded.content
            """, [project, work.day.iso, try encode(work.window), through, revision + 1, try encode(content)])
        return true
    }

    static func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    }

    static func decode<T: Decodable>(_ type: T.Type, _ text: String?) throws -> T {
        try JSONDecoder().decode(type, from: Data((text ?? "").utf8))
    }
}
