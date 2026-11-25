import Foundation

/// The line items behind an invoice, with amounts that add up to the billing summary
/// (Python's `tracker/report_rows.py`).
enum ReportRows {
    static let activityCodes: Set<String> = ["prompting", "reviewing", "other"]
    static let genericBranches: Set<String> = ["head", "main", "master", "develop", "dev", "trunk"]

    final class Line {
        var id: String?
        var who: String
        var date: String
        var startedAt: Int?
        var endedAt: Int?
        var client: String?
        var project: String?
        var projectKind: String?
        var task: String?
        var tags: [String] = []
        var description = ""
        var provider: String?
        var models: [String] = []
        var thread: String?
        var millis = 0
        var billedMillis = 0
        var tokens = [0, 0, 0, 0]
        var apiUSD: String?
        var tokensWithoutAPIPrice = 0
        var agentMode: String?
        var rate: String?
        var timeAmount: Int?
        var usageAmount: Int?
        var amount: String?
        var reimbursable = false

        init(_ entry: Entry, who: String, day: Day) {
            self.who = who
            date = day.iso
            client = entry.client
            project = entry.project
            projectKind = entry.projectKind
            task = entry.task.nonEmpty
        }

        var json: JSON {
            .object([
                ("id", .optional(id)), ("who", .string(who)), ("date", .string(date)), ("started_at", .optional(startedAt)),
                ("ended_at", .optional(endedAt)), ("client", .optional(client)), ("project", .optional(project)),
                ("project_kind", .optional(projectKind)), ("task", .optional(task)), ("tags", .strings(tags)),
                ("description", .string(description)), ("provider", .optional(provider)), ("models", .strings(models)),
                ("thread", .optional(thread)), ("millis", .int(Int64(millis))), ("billed_millis", .int(Int64(billedMillis))),
                ("tokens", Reports.tokensJSON(tokens)), ("api_usd", .optional(apiUSD)),
                ("tokens_without_api_price", .int(Int64(tokensWithoutAPIPrice))), ("agent_mode", .optional(agentMode)),
                ("rate", .optional(rate)), ("time_amount", timeAmount.map { .string(PyDecimal.money($0)) } ?? .null),
                ("usage_amount", usageAmount.map { .string(PyDecimal.money($0)) } ?? .null), ("amount", .optional(amount)),
                ("reimbursable", .bool(reimbursable)),
            ])
        }
    }

    static func billable(_ entry: Entry) -> Bool { entry.projectKind == "billable" && entry.project.nonEmpty != nil }

    static func terms(_ entry: Entry, _ terms: Billing.StoredTerms) -> Billing.Effective? {
        billable(entry) ? Billing.effective(terms, client: entry.client, project: entry.project) : nil
    }

    /// Splits a span at local midnight into (day, start, end) pieces.
    static func pieces(_ start: Int, _ end: Int, _ zone: TimeZone) -> [(Day, Int, Int)] {
        var day = Day.local(start, zone)
        var start = start
        var result: [(Day, Int, Int)] = []
        while true {
            let midnight = day.adding(days: 1).midnight(zone)
            if end <= midnight {
                result.append((day, start, end))
                return result
            }
            result.append((day, start, midnight))
            day = day.adding(days: 1)
            start = midnight
        }
    }

    typealias Piece = (start: Int, end: Int, month: String, entry: Entry)

    static func humanRows(_ entries: [Entry], _ zone: TimeZone, _ stored: Billing.StoredTerms) -> [(Line, [String: PyDecimal])] {
        struct Key: Hashable { let project: String?, task: String?, day: Day }
        var groups = Ordered<Key, [Piece]>()
        for entry in entries {
            let month = Day.month(entry.at, zone)
            for (day, start, end) in pieces(entry.at, entry.at + (entry.millis ?? 0), zone) {
                groups.append((start, end, month, entry), to: Key(project: entry.project, task: entry.task.nonEmpty, day: day))
            }
        }
        var sessions: [(Day, [Piece])] = []
        for (key, items) in groups.pairs {
            var merged: [[Piece]] = []
            var reach = 0
            let ordered = items.stableSorted { a, b in
                if a.start != b.start { return a.start < b.start }
                if a.end != b.end { return a.end < b.end }
                return pyLess(a.entry.id, b.entry.id)
            }
            for piece in ordered {
                if !merged.isEmpty, piece.start - reach <= Billing.humanSpanGap {
                    merged[merged.count - 1].append(piece)
                    reach = max(reach, piece.end)
                } else {
                    merged.append([piece])
                    reach = piece.end
                }
            }
            sessions += merged.map { (key.day, $0) }
        }
        var rows: [(Line, [String: PyDecimal])] = []
        var covered: [String: [String: [Billing.Span]]] = [:]
        let ordered = sessions.stableSorted { a, b in
            if a.1[0].start != b.1[0].start { return a.1[0].start < b.1[0].start }
            return pyLess(a.1[0].entry.id, b.1[0].entry.id)
        }
        for (day, parts) in ordered {
            let first = parts[0].entry
            let row = Line(first, who: "you", day: day)
            let values = terms(first, stored)
            let projectKey = first.project ?? "\u{1}"
            var seen = covered[projectKey] ?? [:]
            var billed = 0
            var months: [String] = []
            for part in parts where !months.contains(part.month) { months.append(part.month) }
            for month in months {
                let previous = seen[month] ?? []
                let before = Billing.length(Billing.union(previous))
                let spans = Billing.union(previous + parts.filter { $0.month == month }.map { ($0.start, $0.end) })
                seen[month] = spans
                billed += Billing.length(spans) - before
            }
            covered[projectKey] = seen
            var labels: [String] = []
            for part in parts where part.entry.timeSource == nil {
                if let label = part.entry.label.nonEmpty, !activityCodes.contains(label), !labels.contains(label) {
                    labels.append(label)
                }
            }
            let tags = Set(parts.compactMap { $0.entry.tag.nonEmpty }).sorted(by: pyLess)
            var apps = Ordered<String, Int>()
            for part in parts where part.entry.timeSource != nil {
                if let label = part.entry.label.nonEmpty { apps[label] = (apps[label] ?? 0) + part.end - part.start }
            }
            let top = apps.pairs.stableSorted { a, b in a.1 != b.1 ? a.1 > b.1 : pyLess(a.0, b.0) }.prefix(3)
            row.id = "you:\(row.date):\(first.id)"
            row.startedAt = parts[0].start
            row.endedAt = parts.map(\.end).max()
            row.tags = tags
            row.millis = Billing.length(Billing.union(parts.map { ($0.start, $0.end) }))
            row.billedMillis = billed
            row.description = labels.joined(separator: ", ").nonEmptyString ?? row.task.nonEmpty
                ?? tags.joined(separator: ", ").nonEmptyString ?? top.map(\.0).joined(separator: ", ")
            if let values, let cents = values.humanCents { row.rate = PyDecimal.money(cents) }
            rows.append((row, ["you": PyDecimal(billed)]))
        }
        return rows
    }

    static func folderName(_ folder: String) -> String {
        var path = Substring(folder)
        while path.count > 1, path.hasSuffix("/") { path = path.dropLast() }
        if path == "/" { return "" }
        return String(path.split(separator: "/", omittingEmptySubsequences: true).last ?? "")
    }

    static func agentDescription(task: String?, branch: String?, folder: String?, project: String?) -> String {
        if let task = task.nonEmpty { return task }
        if let branch = branch.nonEmpty, !genericBranches.contains(branch.pythonStripped.lowercased()) { return branch }
        if project.nonEmpty == nil, let folder = folder.nonEmpty { return folderName(folder) }
        return ""
    }

    static func agentRows(_ entries: [Entry], _ zone: TimeZone, _ stored: Billing.StoredTerms,
                          _ catalog: Catalog) -> [(Line, [String: PyDecimal])] {
        struct Key: Hashable { let project: String?, thread: String, day: Day }
        final class Group {
            var entries: [Entry] = []
            var spans: [(Int, Int, String)] = []
            var stamps: [Int] = []
        }
        var groups = Ordered<Key, Group>()
        func group(_ key: Key) -> Group {
            if let found = groups[key] { return found }
            let created = Group()
            groups[key] = created
            return created
        }
        for entry in entries {
            let thread = Billing.threadKey(entry)
            if entry.kind == "runtime" {
                let month = Day.month(entry.at, zone)
                for (day, start, end) in pieces(entry.at, entry.at + (entry.millis ?? 0), zone) {
                    let item = group(Key(project: entry.project, thread: thread, day: day))
                    item.entries.append(entry)
                    item.spans.append((start, end, month))
                }
            } else {
                let item = group(Key(project: entry.project, thread: thread, day: Day.local(entry.at, zone)))
                item.entries.append(entry)
                item.stamps.append(entry.at)
            }
        }
        var rows: [(Line, [String: PyDecimal])] = []
        for (key, item) in groups.pairs {
            let items = item.entries
            let row = Line(items[0], who: "agent", day: key.day)
            let values = terms(items[0], stored)
            let spans = item.spans.map { ($0.0, $0.1) }
            var priced = PyDecimal.zero, usageUSD = PyDecimal.zero
            var models = Set<String>()
            var quoted = false
            for entry in items where entry.kind != "runtime" {
                if let model = entry.model.nonEmpty { models.insert(model) }
                let counts = [entry.input ?? 0, entry.cached ?? 0, entry.cacheWrite ?? 0, entry.output ?? 0]
                for index in 0..<4 { row.tokens[index] += counts[index] }
                if let quote = catalog.quote(entry) {
                    quoted = true
                    priced += quote
                    if entry.kind == "usage" { usageUSD += quote }
                } else {
                    row.tokensWithoutAPIPrice += counts.reduce(0, +)
                }
            }
            var tasks = Ordered<String, Int>()
            for entry in items { if let task = entry.task.nonEmpty { tasks[task] = (tasks[task] ?? 0) + 1 } }
            let branch = items.first { entry in
                guard let branch = entry.branch.nonEmpty else { return false }
                return !genericBranches.contains(branch.pythonStripped.lowercased())
            }?.branch
            let folder = items.first { $0.folder.nonEmpty != nil }?.folder
            let task = tasks.pairs.stableSorted { $0.1 > $1.1 }.first?.0
            let bounds = spans.isEmpty ? item.stamps.map { ($0, $0) } : spans
            var byMonth = Ordered<String, [Billing.Span]>()
            for (start, end, month) in item.spans { byMonth.append((start, end), to: month) }
            let billed = byMonth.values.reduce(0) { $0 + Billing.length(Billing.union($1)) }
            let earliest = items.stableSorted { a, b in a.at != b.at ? a.at < b.at : pyLess(a.id, b.id) }[0]
            row.id = "agent:\(row.date):\(earliest.id)"
            row.startedAt = bounds.map(\.0).min()
            row.endedAt = bounds.map(\.1).max()
            row.task = task
            row.description = agentDescription(task: task, branch: branch, folder: folder, project: row.project)
            row.provider = items[0].provider
            row.models = models.sorted(by: pyLess)
            row.thread = Billing.threadName(items[0])
            row.millis = Billing.length(Billing.union(spans))
            row.billedMillis = billed
            row.apiUSD = quoted ? priced.quantized(-6).plain : nil
            if let values {
                row.agentMode = values.agentMode
                if ["time", "hybrid"].contains(values.agentMode), let cents = values.agentCents { row.rate = PyDecimal.money(cents) }
            }
            rows.append((row, ["agent_time": PyDecimal(billed), "agent_usage": usageUSD]))
        }
        return rows
    }

    static func expenseRow(_ entry: Entry, _ zone: TimeZone) -> Line {
        let row = Line(entry, who: "expense", day: Day.local(entry.at, zone))
        row.id = "expense:\(entry.id)"
        row.startedAt = entry.at
        row.endedAt = entry.at
        row.description = entry.label ?? ""
        row.provider = entry.provider
        row.amount = PyDecimal.money(entry.cents ?? 0)
        row.reimbursable = (entry.reimbursable ?? 0) != 0
        return row
    }

    /// Splits `target` cents over (row, weight) pairs by largest remainder, ties by row id.
    static func share(_ target: Int, _ weighted: [(Line, PyDecimal)]) -> [(Line, Int)] {
        var weighted = weighted
        var total = PyDecimal.zero
        for (_, weight) in weighted { total = total + weight }
        if total.isZero {
            weighted = weighted.enumerated().map { ($0.element.0, $0.offset == 0 ? PyDecimal.one : PyDecimal.zero) }
            total = .one
        }
        let exact = weighted.map { ($0.0, PyDecimal(target) * $0.1 / total) }
        var parts = exact.map { $0.1.truncated }
        let order = exact.indices.stableSorted { a, b in
            let fa = PyDecimal(exact[a].1.truncated) - exact[a].1, fb = PyDecimal(exact[b].1.truncated) - exact[b].1
            if fa != fb { return fa < fb }
            return pyLess(exact[a].0.id ?? "", exact[b].0.id ?? "")
        }
        let extra = target - parts.reduce(0, +)
        // Python's order[:extra], including its meaning for a negative count.
        let count = extra >= 0 ? min(extra, order.count) : max(0, order.count + extra)
        for index in order.prefix(count) { parts[index] += 1 }
        return zip(exact, parts).map { ($0.0.0, $0.1) }
    }

    static func build(_ db: Database, start: String?, end: String?, period: String, client: String?,
                      projects: [String]?) throws -> JSON {
        let (bounds, all) = try EntryStore.scope(db, start: start, end: end, period: period)
        let entries = all.filter { entry in
            (client == nil || pyEqual(entry.client, client))
                && ((projects ?? []).isEmpty || projects!.contains { pyEqual($0, entry.project) })
        }
        let zone = try Values.zone(bounds["timezone"].stringValue ?? "UTC")
        let catalog = try Catalog(db)
        let stored = try Billing.storedTerms(db)
        let summary = try Billing.summary(db, entries, catalog)
        var rows = humanRows(entries.filter { $0.kind == "human" }, zone, stored)
        rows += agentRows(entries.filter { $0.kind != "human" && $0.kind != "expense" && $0.provider.nonEmpty != nil },
                          zone, stored, catalog)
        struct LineKey: Hashable { let client: String?, project: String?, item: String }
        var lines: [LineKey: String?] = [:]
        for client in summary["clients"].arrayValue ?? [] {
            for project in client["projects"].arrayValue ?? [] {
                for line in project["lines"].arrayValue ?? [] {
                    lines[LineKey(client: client["client"].stringValue, project: project["project"].stringValue,
                                  item: line["item"].stringValue ?? "")] = .some(line["amount"].stringValue)
                }
            }
        }
        let items: [(String, String)] = [("you", "you"), ("agent_time", "agent"), ("agent_usage", "agent")]
        var candidates = Ordered<LineKey, [(Line, PyDecimal)]>()
        for (row, weights) in rows where row.projectKind == "billable" && row.project.nonEmpty != nil {
            for (item, who) in items where row.who == who {
                candidates.append((row, weights[item]!), to: LineKey(client: row.client, project: row.project, item: item))
            }
        }
        for (key, weighted) in candidates.pairs {
            guard let found = lines[key], let amount = found else { continue }
            let target = (PyDecimal(amount)! * PyDecimal(100)).roundedHalfUp
            var chosen = weighted.filter { PyDecimal.zero < $0.1 }
            if chosen.isEmpty { chosen = target != 0 ? weighted : [] }
            for (row, cents) in share(target, chosen) {
                if key.item == "agent_usage" { row.usageAmount = cents } else { row.timeAmount = cents }
            }
        }
        var result: [Line] = []
        for (row, _) in rows {
            let parts = [row.timeAmount, row.usageAmount].compactMap { $0 }
            if !parts.isEmpty { row.amount = PyDecimal.money(parts.reduce(0, +)) }
            result.append(row)
        }
        result += entries.filter { $0.kind == "expense" }.map { expenseRow($0, zone) }
        result = result.stableSorted { a, b in
            if a.date != b.date { return pyLess(a.date, b.date) }
            if (a.startedAt ?? 0) != (b.startedAt ?? 0) { return (a.startedAt ?? 0) < (b.startedAt ?? 0) }
            if a.who != b.who { return pyLess(a.who, b.who) }
            if !pyEqual(a.project ?? "", b.project ?? "") { return pyLess(a.project ?? "", b.project ?? "") }
            return pyLess(a.id ?? "", b.id ?? "")
        }
        let adjustments: [JSON] = (summary["clients"].arrayValue ?? []).compactMap { client in
            guard let reduction = client["cap_reduction"].stringValue else { return nil }
            return .object([("client", client["client"]), ("kind", .string("monthly_cap")),
                            ("monthly_cap", client["monthly_cap"]), ("amount", .string("-" + reduction))])
        }
        var output = bounds
        output.set("usd_exchange_rate", summary["usd_exchange_rate"])
        output.set("needs_exchange_rate", summary["needs_exchange_rate"])
        output.set("missing_human_rate", summary["missing_human_rate"])
        output.set("client", .optional(client))
        output.set("projects", (projects ?? []).isEmpty ? .null : .strings(projects!))
        output.set("rows", .array(result.map(\.json)))
        output.set("adjustments", .array(adjustments))
        output.set("billing", summary)
        return output
    }
}

extension String {
    /// nil for "", like Python's `"" or other`.
    var nonEmptyString: String? { isEmpty ? nil : self }
}
