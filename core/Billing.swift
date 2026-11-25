import Foundation

/// What you charge clients for your time and your agents' work (Python's `tracker/billing.py`).
enum Billing {
    static let modes = ["none", "time", "usage", "hybrid"]
    static let humanSpanGap = 10 * 60 * 1000
    static let agentSpanGap = 20 * 60 * 1000
    static let laneClearance = 20 * 60 * 1000
    static let hour = PyDecimal(3_600_000)

    struct Terms {
        var humanCents: Int?
        var agentMode: String?
        var agentCents: Int?
        var usageMarkup: String?
        var capCents: Int?
    }

    struct Effective {
        var humanCents: Int?
        var agentMode: String
        var agentCents: Int?
        var markup: PyDecimal
        var capCents: Int?
    }

    struct StoredTerms {
        var clients: [String: Terms] = [:]
        var projects: [String: Terms] = [:]
        var clientOrder: [String] = []
        var projectOrder: [String] = []
    }

    // MARK: Saving terms

    static func blank(_ value: String?) -> Bool { value?.pythonStripped.isEmpty ?? true }

    static func decimalValue(_ text: String, _ label: String, _ maximum: Int) throws -> PyDecimal {
        guard let amount = PyDecimal(text.pythonStripped), PyDecimal.zero < amount, amount <= PyDecimal(maximum) else {
            throw EngineError.invalid("\(label) must be a number above 0 and at most \(maximum)")
        }
        return amount
    }

    static func saveTerms(_ db: Database, scope: String, name rawName: String?, humanRate: String?, agentMode: String?,
                          agentRate: String?, markup: String?, cap: String?) throws {
        guard scope == "client" || scope == "project" else {
            throw EngineError.invalid("Billing terms belong to a client or a project")
        }
        let name = try Values.required(rawName, "Name")
        if scope == "project" {
            _ = try Store.project(db, name)
            if !blank(cap) { throw EngineError.invalid("The monthly cap is set on the client") }
        } else if !(try Store.clientList(db)).contains(where: { pyEqual($0, name) }) {
            throw EngineError.invalid("Unknown client: \(name)")
        }
        if !blank(agentMode), !modes.contains(agentMode ?? "") {
            throw EngineError.invalid("Bill agents by none, time, usage, or hybrid")
        }
        let values: [SQLValue] = [
            blank(humanRate) ? .null : .integer(Int64(try Values.cents(humanRate!))),
            blank(agentMode) ? .null : .text(agentMode!),
            blank(agentRate) ? .null : .integer(Int64(try Values.cents(agentRate!))),
            blank(markup) ? .null : .text(try decimalValue(markup!, "The usage markup", 100).description),
            blank(cap) ? .null : .integer(Int64(try Values.cents(cap!))),
        ]
        if values.allSatisfy(\.isNull) {
            try db.execute("DELETE FROM billing_terms WHERE scope = ? AND name = ?", [scope, name])
        } else {
            try db.execute("INSERT OR REPLACE INTO billing_terms VALUES (?, ?, ?, ?, ?, ?, ?)",
                           [SQLValue.text(scope), SQLValue.text(name)] + values)
        }
    }

    static func setExchangeRate(_ db: Database, _ value: String?) throws {
        if blank(value) {
            try db.execute("DELETE FROM settings WHERE key = 'usd_exchange_rate'")
        } else {
            try Store.setSetting(db, "usd_exchange_rate", try decimalValue(value!, "The exchange rate", 1000).description)
        }
    }

    /// Ledger currency per US dollar.
    static func exchangeRate(_ db: Database) throws -> PyDecimal? {
        if try Store.currency(db) == "USD" { return .one }
        guard let value = try Store.setting(db, "usd_exchange_rate"), !value.isEmpty else { return nil }
        return PyDecimal(value)
    }

    static func storedTerms(_ db: Database) throws -> StoredTerms {
        var terms = StoredTerms()
        for row in try db.query("SELECT * FROM billing_terms") {
            guard let name = row["name"].string else { continue }
            let values = Terms(humanCents: row["human_cents"].int, agentMode: row["agent_mode"].string,
                               agentCents: row["agent_cents"].int, usageMarkup: row["usage_markup"].string,
                               capCents: row["monthly_cap_cents"].int)
            if row["scope"].string == "client" {
                if terms.clients[name] == nil { terms.clientOrder.append(name) }
                terms.clients[name] = values
            } else {
                if terms.projects[name] == nil { terms.projectOrder.append(name) }
                terms.projects[name] = values
            }
        }
        return terms
    }

    static func displayTerms(_ name: String, _ values: Terms) -> JSON {
        .object([
            ("name", .string(name)),
            ("human_rate", values.humanCents.map { .string(PyDecimal.money($0)) } ?? .null),
            ("agent_mode", .optional(values.agentMode)),
            ("agent_rate", values.agentCents.map { .string(PyDecimal.money($0)) } ?? .null),
            ("usage_markup", .optional(values.usageMarkup)),
            ("monthly_cap", values.capCents.map { .string(PyDecimal.money($0)) } ?? .null),
        ])
    }

    static func termsListing(_ db: Database) throws -> JSON {
        let terms = try storedTerms(db)
        return .object([
            ("clients", .array(terms.clientOrder.stableSorted(by: pyLess).map { displayTerms($0, terms.clients[$0]!) })),
            ("projects", .array(terms.projectOrder.stableSorted(by: pyLess).map { displayTerms($0, terms.projects[$0]!) })),
            ("usd_exchange_rate", .optional(try Store.setting(db, "usd_exchange_rate"))),
        ])
    }

    static func effective(_ terms: StoredTerms, client: String?, project: String?) -> Effective {
        var human: Int?, mode: String?, agent: Int?, markup: String?
        for values in [client.flatMap { terms.clients[$0] }, project.flatMap { terms.projects[$0] }] {
            guard let values else { continue }
            if let value = values.humanCents { human = value }
            if let value = values.agentMode { mode = value }
            if let value = values.agentCents { agent = value }
            if let value = values.usageMarkup { markup = value }
        }
        let cap = client.flatMap { terms.clients[$0] }?.capCents
        return Effective(humanCents: human, agentMode: mode.nonEmpty ?? "none", agentCents: agent,
                         markup: markup.nonEmpty.flatMap { PyDecimal($0) } ?? .one, capCents: cap)
    }

    // MARK: Spans

    typealias Span = (start: Int, end: Int)

    static func union(_ spans: [Span]) -> [Span] {
        var merged: [Span] = []
        for span in spans.sorted(by: { $0.start != $1.start ? $0.start < $1.start : $0.end < $1.end }) {
            if span.end <= span.start { continue }
            if let last = merged.last, span.start <= last.end {
                merged[merged.count - 1].end = max(last.end, span.end)
            } else {
                merged.append(span)
            }
        }
        return merged
    }

    static func length(_ spans: [Span]) -> Int { spans.reduce(0) { $0 + $1.end - $1.start } }

    /// (provider, session or folder or id).
    static func threadKey(_ entry: Entry) -> String {
        (entry.provider ?? "") + "\u{0}" + (entry.session.nonEmpty ?? entry.folder.nonEmpty ?? entry.id)
    }

    static func threadName(_ entry: Entry) -> String { entry.session.nonEmpty ?? entry.folder.nonEmpty ?? entry.id }

    // MARK: Usage and charges

    final class Usage {
        var human: [Span] = []
        var threads = Ordered<String, [Span]>()
        var apiUSD = PyDecimal.zero
        var unpricedTokens = 0

        var humanMillis: Int { Billing.length(Billing.union(human)) }
        var agentMillis: Int { threads.values.reduce(0) { $0 + Billing.length(Billing.union($1)) } }
    }

    struct UsageKey: Hashable {
        let client: String?
        let project: String
        let month: String
    }

    static func collect(_ entries: [Entry], _ catalog: Catalog, _ zone: TimeZone) -> Ordered<UsageKey, Usage> {
        var usage = Ordered<UsageKey, Usage>()
        for entry in entries {
            guard entry.projectKind == "billable", let project = entry.project.nonEmpty else { continue }
            let key = UsageKey(client: entry.client, project: project, month: Day.month(entry.at, zone))
            let item: Usage
            if let found = usage[key] { item = found } else { item = Usage(); usage[key] = item }
            if entry.kind == "human" {
                item.human.append((entry.at, entry.at + (entry.millis ?? 0)))
            } else if entry.kind == "runtime", entry.provider.nonEmpty != nil {
                item.threads.append((entry.at, entry.at + (entry.millis ?? 0)), to: threadKey(entry))
            } else if entry.kind == "usage", entry.provider.nonEmpty != nil {
                if let quote = catalog.quote(entry) {
                    item.apiUSD += quote
                } else {
                    item.unpricedTokens += entry.tokenTotal
                }
            }
        }
        return usage
    }

    /// Python's `x or 0` for an optional Decimal in a sum: None and zero both become `Decimal(0)`.
    static func orZero(_ value: PyDecimal?) -> PyDecimal {
        guard let value, !value.isZero else { return .zero }
        return value
    }

    static func charges(_ item: Usage, _ terms: Effective, _ fx: PyDecimal?) -> (you: PyDecimal?, time: PyDecimal?, usage: PyDecimal?) {
        let you = terms.humanCents.map { PyDecimal(item.humanMillis) / hour * PyDecimal($0) }
        var time: PyDecimal?, usage: PyDecimal?
        if ["time", "hybrid"].contains(terms.agentMode), let cents = terms.agentCents {
            time = PyDecimal(item.agentMillis) / hour * PyDecimal(cents)
        }
        if ["usage", "hybrid"].contains(terms.agentMode), let fx {
            usage = item.apiUSD * terms.markup * fx * PyDecimal(100)
        }
        return (you, time, usage)
    }

    static func monthBounds(_ month: String, _ zone: TimeZone) -> (Int, Int) {
        let parts = month.split(separator: "-").compactMap { Int($0) }
        let first = Day(year: parts[0], month: parts[1], day: 1)
        return (first.midnight(zone), first.firstOfNextMonth.midnight(zone))
    }

    struct CapKey: Hashable {
        let client: String?
        let month: String
    }

    static func capFactors(_ db: Database, _ usage: Ordered<UsageKey, Usage>, _ terms: StoredTerms, _ fx: PyDecimal?,
                           _ catalog: Catalog, _ zone: TimeZone) throws -> [CapKey: PyDecimal] {
        var factors: [CapKey: PyDecimal] = [:]
        var seen = Set<CapKey>()
        for key in usage.keys {
            let capKey = CapKey(client: key.client, month: key.month)
            guard seen.insert(capKey).inserted else { continue }
            guard let cap = key.client.flatMap({ terms.clients[$0] })?.capCents else { continue }
            let (start, end) = monthBounds(key.month, zone)
            let monthUsage = collect(try EntryStore.entries(db, since: start, until: end), catalog, zone)
            var total = PyDecimal.zero
            for (other, item) in monthUsage.pairs where pyEqual(other.client, key.client) {
                let (_, time, usage) = charges(item, effective(terms, client: key.client, project: other.project), fx)
                total += orZero(time) + orZero(usage)
            }
            if total.isZero {
                factors[capKey] = .one
            } else {
                let share = PyDecimal(cap) / total
                factors[capKey] = share < .one ? share : .one
            }
        }
        return factors
    }

    static func centsText(_ amount: PyDecimal) -> String { PyDecimal.centsText(amount) }

    // MARK: Summary

    final class ProjectTotals {
        var terms: Effective?
        var humanMillis = 0
        var agentMillis = 0
        var apiUSD = PyDecimal.zero
        var unpriced = 0
        var you: PyDecimal?
        var time: PyDecimal?
        var usage: PyDecimal?
        var capped = PyDecimal.zero
    }

    struct ProjectKey: Hashable {
        let client: String?
        let project: String
    }

    /// Invoice lines per client and project for these entries (already limited to a period).
    static func summary(_ db: Database, _ entries: [Entry], _ catalog: Catalog) throws -> JSON {
        let zone = try Store.timezone(db)
        let fx = try exchangeRate(db)
        let terms = try storedTerms(db)
        let usage = collect(entries, catalog, zone)
        let factors = try capFactors(db, usage, terms, fx, catalog, zone)

        var projects = Ordered<ProjectKey, ProjectTotals>()
        for (key, item) in usage.pairs {
            let values = effective(terms, client: key.client, project: key.project)
            let projectKey = ProjectKey(client: key.client, project: key.project)
            let row: ProjectTotals
            if let found = projects[projectKey] { row = found } else { row = ProjectTotals(); projects[projectKey] = row }
            row.terms = values
            row.humanMillis += item.humanMillis
            row.agentMillis += item.agentMillis
            row.apiUSD += item.apiUSD
            row.unpriced += item.unpricedTokens
            let (you, time, agentUsage) = charges(item, values, fx)
            let factor = factors[CapKey(client: key.client, month: key.month)] ?? .one
            if let you { row.you = orZero(row.you) + you }
            if let time { row.time = orZero(row.time) + time }
            if let agentUsage { row.usage = orZero(row.usage) + agentUsage }
            row.capped += (orZero(time) + orZero(agentUsage)) * (PyDecimal.one - factor)
        }

        var clientOrder: [String?] = []
        var clientProjects: [String?: [JSON]] = [:]
        var clientCaps: [String?: JSON] = [:]
        var clientReductions: [String?: PyDecimal] = [:]
        var missingRate = false
        let sortedProjects = projects.pairs.stableSorted { a, b in
            let ca = a.0.client ?? "", cb = b.0.client ?? ""
            if !pyEqual(ca, cb) { return pyLess(ca, cb) }
            return pyLess(a.0.project, b.0.project)
        }
        for (key, row) in sortedProjects {
            let values = row.terms!
            var lines: [JSON] = []
            if row.humanMillis != 0 {
                if values.humanCents == nil { missingRate = true }
                lines.append(.object([
                    ("item", .string("you")), ("hours", .string(PyDecimal.hours(row.humanMillis))),
                    ("rate", values.humanCents.map { .string(PyDecimal.money($0)) } ?? .null),
                    ("amount", row.you.map { .string(centsText($0)) } ?? .null),
                ]))
            }
            let mode = values.agentMode
            if ["time", "hybrid"].contains(mode), row.agentMillis != 0 {
                lines.append(.object([
                    ("item", .string("agent_time")), ("hours", .string(PyDecimal.hours(row.agentMillis))),
                    ("rate", values.agentCents.map { .string(PyDecimal.money($0)) } ?? .null),
                    ("amount", row.time.map { .string(centsText($0)) } ?? .null),
                ]))
            }
            if ["usage", "hybrid"].contains(mode), !row.apiUSD.isZero || row.unpriced != 0 {
                lines.append(.object([
                    ("item", .string("agent_usage")), ("api_usd", .string(row.apiUSD.quantized(-2).plain)),
                    ("markup", .string(values.markup.normalized().plain)),
                    ("tokens_without_api_price", .int(Int64(row.unpriced))),
                    ("amount", row.usage.map { .string(centsText($0)) } ?? .null),
                ]))
            }
            if lines.isEmpty { continue }
            var total = PyDecimal.zero
            for line in lines {
                if let amount = line["amount"].stringValue { total = total + PyDecimal(amount)! }
            }
            if clientProjects[key.client] == nil {
                clientOrder.append(key.client)
                clientProjects[key.client] = []
                clientReductions[key.client] = .zero
            }
            let cap = key.client.flatMap { terms.clients[$0] }?.capCents
            clientCaps[key.client] = cap.map { .string(PyDecimal.money($0)) } ?? .null
            clientReductions[key.client]! += row.capped
            clientProjects[key.client]!.append(.object([
                ("project", .string(key.project)), ("agent_mode", .string(mode)), ("lines", .array(lines)),
                ("subtotal", .string(total.fixedText(2))),
            ]))
        }

        var result: [JSON] = []
        var grand = PyDecimal.zero
        for client in clientOrder {
            let projects = clientProjects[client]!
            var subtotal = PyDecimal.zero
            for project in projects { subtotal = subtotal + PyDecimal(project["subtotal"].stringValue!)! }
            let reduction = PyDecimal(centsText(clientReductions[client]!))!
            let net = subtotal - reduction
            grand += net
            result.append(.object([
                ("client", .optional(client)), ("projects", .array(projects)), ("monthly_cap", clientCaps[client] ?? .null),
                ("cap_reduction", reduction.isZero ? .null : .string(reduction.fixedText(2))),
                ("total", .string(net.fixedText(2))),
            ]))
        }
        let needsRate = fx == nil && result.contains { client in
            client["projects"].arrayValue!.contains { project in
                project["lines"].arrayValue!.contains { $0["item"].stringValue == "agent_usage" }
            }
        }
        return .object([
            ("currency", .string(try Store.currency(db))),
            ("usd_exchange_rate", fx.map { .string($0.plain) } ?? .null),
            ("needs_exchange_rate", .bool(needsRate)),
            ("missing_human_rate", .bool(missingRate)),
            ("clients", .array(result)),
            ("total", .string(grand.fixedText(2))),
        ])
    }

    // MARK: Day view

    struct Block {
        var project: String
        var client: String?
        var startedAt: Int
        var endedAt: Int
        var billedMillis: Int
        var threads: Int?
        var agentMode: String?
        var amount: String?
        var lane = 0

        var json: JSON {
            var pairs: [(String, JSON)] = [("project", .string(project)), ("client", .optional(client)),
                                           ("started_at", .int(Int64(startedAt))), ("ended_at", .int(Int64(endedAt))),
                                           ("billed_millis", .int(Int64(billedMillis)))]
            if let threads { pairs.append(("threads", .int(Int64(threads)))) }
            if let agentMode { pairs.append(("agent_mode", .string(agentMode))) }
            pairs.append(("amount", .optional(amount)))
            pairs.append(("lane", .int(Int64(lane))))
            return .object(pairs)
        }
    }

    static func grouped(_ spans: [Span], _ gap: Int) -> [Span] {
        var blocks: [Span] = []
        for span in union(spans) {
            if let last = blocks.last, span.start - last.end <= gap {
                blocks[blocks.count - 1].end = span.end
            } else {
                blocks.append(span)
            }
        }
        return blocks
    }

    static func clip(_ spans: [Span], _ start: Int, _ end: Int) -> [Span] {
        spans.filter { $0.end > start && $0.start < end }.map { (max($0.start, start), min($0.end, end)) }
    }

    static func daySpans(_ db: Database, _ entries: [Entry]) throws -> JSON {
        let terms = try storedTerms(db)
        var human = Ordered<String, [Span]>()
        var threads = Ordered<String, Ordered<String, [Span]>>()
        var clients: [String: String?] = [:]
        for entry in entries {
            guard entry.projectKind == "billable", let project = entry.project.nonEmpty else { continue }
            clients[project] = .some(entry.client)
            if entry.kind == "human" {
                human.append((entry.at, entry.at + (entry.millis ?? 0)), to: project)
            } else if entry.kind == "runtime", entry.provider.nonEmpty != nil, let millis = entry.millis, millis != 0 {
                var byThread = threads[project, default: Ordered()]
                byThread.append((entry.at, entry.at + millis), to: threadKey(entry))
                threads[project] = byThread
            }
        }
        var you: [Block] = []
        for (project, spans) in human.pairs {
            let exact = union(spans)
            let client = clients[project] ?? nil
            let rate = effective(terms, client: client, project: project).humanCents
            for (start, end) in grouped(spans, humanSpanGap) {
                let millis = length(clip(exact, start, end))
                you.append(Block(project: project, client: client, startedAt: start, endedAt: end, billedMillis: millis,
                                 amount: rate.map { centsText(PyDecimal(millis) / hour * PyDecimal($0)) }))
            }
        }
        var ai: [Block] = []
        for (project, byThread) in threads.pairs {
            let client = clients[project] ?? nil
            let values = effective(terms, client: client, project: project)
            if values.agentMode == "none" { continue }
            let busy = byThread.pairs.map { ($0.0, union($0.1)) }
            let everything = busy.flatMap(\.1)
            for (start, end) in grouped(everything, agentSpanGap) {
                let inside = busy.map { clip($0.1, start, end) }
                let millis = inside.reduce(0) { $0 + length($1) }
                let rate = ["time", "hybrid"].contains(values.agentMode) ? values.agentCents : nil
                ai.append(Block(project: project, client: client, startedAt: start, endedAt: end, billedMillis: millis,
                                threads: inside.filter { !$0.isEmpty }.count, agentMode: values.agentMode,
                                amount: rate.map { centsText(PyDecimal(millis) / hour * PyDecimal($0)) }))
            }
        }
        return .object([("you", .array(packed(you).map(\.json))), ("ai", .array(packed(ai).map(\.json)))])
    }

    /// Lanes for blocks in their original order (Python's `pack` sets them in place).
    static func packed(_ spans: [Block]) -> [Block] {
        var result = spans
        var lanes: [Int] = []
        let order = spans.indices.stableSorted { a, b in
            spans[a].startedAt != spans[b].startedAt ? spans[a].startedAt < spans[b].startedAt
                : pyLess(spans[a].project, spans[b].project)
        }
        for index in order {
            let span = spans[index]
            let lane: Int
            if let free = lanes.firstIndex(where: { span.startedAt >= $0 + laneClearance }) {
                lane = free
            } else {
                lanes.append(0)
                lane = lanes.count - 1
            }
            lanes[lane] = span.endedAt
            result[index].lane = lane
        }
        return result
    }
}
