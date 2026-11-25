import Foundation

/// Time, agent usage and expenses for a period (Python's `tracker/reports.py`).
enum Reports {
    static let tokenFields = ["input", "cached", "cache_write", "output"]

    struct Price {
        let row: Row
        let input: Int, cached: Int, cacheWrite: Int, output: Int
    }

    /// Manual model rates by (provider, model), in cents per million tokens.
    static func prices(_ db: Database) throws -> [String: Price] {
        var result: [String: Price] = [:]
        for row in try db.query("SELECT * FROM model_rates") {
            result[priceKey(row["provider"].string, row["model"].string)] = Price(
                row: row, input: row["input"].int ?? 0, cached: row["cached"].int ?? 0,
                cacheWrite: row["cache_write"].int ?? 0, output: row["output"].int ?? 0)
        }
        return result
    }

    static func priceKey(_ provider: String?, _ model: String?) -> String {
        "\(provider ?? "\u{1}")\u{0}\(model ?? "\u{1}")"
    }

    static func tokenCents(_ entry: Entry, _ price: Price) -> PyDecimal {
        let sum = (entry.input ?? 0) * price.input + (entry.cached ?? 0) * price.cached
            + (entry.cacheWrite ?? 0) * price.cacheWrite + (entry.output ?? 0) * price.output
        return PyDecimal(sum) / PyDecimal(1_000_000)
    }

    static func usd(_ amount: PyDecimal) -> String { PyDecimal.money((amount * PyDecimal(100)).roundedHalfUp) }

    private final class Agent {
        var tokens = [0, 0, 0, 0]
        var runtimeMillis = 0
        var runtimeKind: String?
        var models = Ordered<String, [Int]>()
        var estimates = Ordered<String, PyDecimal>()
    }

    static func tokensJSON(_ values: [Int]) -> JSON {
        .object(zip(tokenFields, values).map { ($0, .int(Int64($1))) })
    }

    /// Python's `reports.time_and_usage`.
    static func timeAndUsage(_ entries: [Entry], _ prices: [String: Price], _ catalog: Catalog) -> JSON {
        var human = 0
        var activities: [String: Int] = [:]
        var agents = Ordered<String, Agent>()
        var expenses = 0
        var estimated = PyDecimal.zero
        var unpriced = 0
        var apiValue = PyDecimal.zero
        var apiUnpriced = 0
        var apiPriced = 0
        var taskIDs = Set<String>()
        for entry in entries {
            if let task = entry.task.nonEmpty { taskIDs.insert(task) }
            if entry.kind == "human" {
                human += entry.millis ?? 0
                activities[entry.label ?? "null", default: 0] += entry.millis ?? 0
            } else if entry.kind == "expense" {
                expenses += entry.cents ?? 0
            } else {
                let provider = entry.provider ?? "null"
                let agent: Agent
                if let found = agents[provider] { agent = found } else { agent = Agent(); agents[provider] = agent }
                if entry.kind == "runtime" {
                    agent.runtimeMillis += entry.millis ?? 0
                    agent.runtimeKind = entry.label
                    continue
                }
                let model = entry.model.nonEmpty ?? "unknown"
                var usage = agent.models[model] ?? [0, 0, 0, 0]
                let counts = [entry.input ?? 0, entry.cached ?? 0, entry.cacheWrite ?? 0, entry.output ?? 0]
                for index in 0..<4 {
                    usage[index] += counts[index]
                    agent.tokens[index] += counts[index]
                }
                agent.models[model] = usage
                let count = counts.reduce(0, +)
                if let price = prices[priceKey(entry.provider, entry.model)] {
                    estimated += tokenCents(entry, price)
                } else {
                    unpriced += count
                }
                if let quote = catalog.quote(entry) {
                    apiPriced += count
                    apiValue += quote
                    agent.estimates[model] = (agent.estimates[model] ?? .zero) + quote
                } else {
                    apiUnpriced += count
                }
            }
        }
        let agentJSON = JSON.object(agents.pairs.map { provider, agent in
            var total = PyDecimal.zero
            for value in agent.estimates.values { total = total + value }
            // Python pops runtime_millis only when the agent has a runtime kind.
            let kept: [(String, JSON)] = agent.runtimeKind.nonEmpty == nil ? [("runtime_millis", .int(Int64(agent.runtimeMillis)))] : []
            return (provider, .object([("tokens", tokensJSON(agent.tokens))] + kept + [
                ("runtime_kind", .optional(agent.runtimeKind)),
                ("models", .object(agent.models.pairs.map { ($0.0, tokensJSON($0.1)) })),
                ("runtime_hours", agent.runtimeKind.nonEmpty != nil ? .string(PyDecimal.hours(agent.runtimeMillis)) : .null),
                ("api_equivalent_usd", agent.estimates.isEmpty ? .null : .string(usd(total))),
                ("model_api_equivalent_usd", .object(agent.estimates.pairs.map { ($0.0, .string(usd($0.1))) })),
            ]))
        })
        return .object([
            ("human_hours", .string(PyDecimal.hours(human))),
            ("human_by_activity", .object(activities.keys.sorted(by: pyLess).map { ($0, .string(PyDecimal.hours(activities[$0]!))) })),
            ("agents", agentJSON),
            ("task_ids", .strings(taskIDs.sorted(by: pyLess))),
            ("provider_expenses", .string(PyDecimal.money(expenses))),
            ("estimated_token_value", .string(PyDecimal.money(estimated.roundedHalfUp))),
            ("tokens_without_price", .int(Int64(unpriced))),
            ("api_equivalent_usd", apiPriced != 0 ? .string(usd(apiValue)) : .null),
            ("tokens_without_api_price", .int(Int64(apiUnpriced))),
        ])
    }

    /// Python's `str.casefold()`, close enough for task keys.
    static func casefold(_ text: String) -> String { text.folding(options: [.caseInsensitive], locale: nil) }

    static func report(_ db: Database, start: String?, end: String?, period: String, project: String?, client: String?,
                       task: String?) throws -> JSON {
        let (bounds, all) = try EntryStore.scope(db, start: start, end: end, period: period)
        let entries = all.filter { entry in
            (project == nil || pyEqual(entry.project, project)) && (client == nil || pyEqual(entry.client, client))
                && (task == nil || casefold(entry.task ?? "") == casefold(task!))
        }
        var grouped = Ordered<String?, [Entry]>()
        for entry in entries { grouped.append(entry, to: entry.project) }
        let prices = try prices(db)
        let catalog = try Catalog(db)
        let sorted = grouped.pairs.stableSorted { a, b in
            if (a.0 == nil) != (b.0 == nil) { return a.0 != nil }
            return pyLess(a.0 ?? "", b.0 ?? "")
        }
        var projects: [JSON] = []
        for (name, rows) in sorted {
            var object = JSON.object([("project", .optional(name)), ("client", .optional(rows[0].client)),
                                      ("kind", .optional(rows[0].projectKind))])
            for (key, value) in timeAndUsage(rows, prices, catalog).pairs ?? [] { object.set(key, value) }
            projects.append(object)
        }
        let accountScope = project == nil && client == nil && task == nil
        var result = bounds
        result.set("totals", timeAndUsage(entries, prices, catalog))
        result.set("projects", .array(projects))
        result.set("api_prices_fetched_at", catalog.fetchedAt)
        result.set("billing", try Billing.summary(db, entries, catalog))
        result.set("subscriptions", accountScope ? try Store.subscriptions(db) : .null)
        result.set("openrouter_account", accountScope
            ? try openRouterSummary(db, start: bounds["start"].stringValue!, end: bounds["end_exclusive"].stringValue!) : .null)
        if task == nil,
           let usage = try ProviderUsage.report(db, start: bounds["start"].stringValue!, end: bounds["end_exclusive"].stringValue!,
                                                project: project, client: client) {
            result.set("provider_usage", usage)
        }
        return result
    }

    static func review(_ db: Database, start: String?, end: String?, period: String) throws -> JSON {
        let (bounds, entries) = try EntryStore.scope(db, start: start, end: end, period: period)
        struct Key: Hashable { let provider: String?, folder: String?, branch: String? }
        var rows = Ordered<Key, (events: Int, tokens: Int, runtime: Int, sample: String?)>()
        for entry in entries where entry.project == nil {
            let key = Key(provider: entry.provider, folder: entry.folder, branch: entry.branch)
            var item = rows[key] ?? (0, 0, 0, nil)
            item.events += 1
            item.tokens += entry.tokenTotal
            item.runtime += entry.millis ?? 0
            item.sample = entry.id
            rows[key] = item
        }
        var result = bounds
        result.set("unassigned", .array(rows.pairs.map { key, value in
            .object([("provider", .optional(key.provider)), ("folder", .optional(key.folder)), ("branch", .optional(key.branch)),
                     ("event_count", .int(Int64(value.events))), ("tokens", .int(Int64(value.tokens))),
                     ("runtime_millis", .int(Int64(value.runtime))), ("sample_entry_id", .optional(value.sample))])
        }))
        return result
    }

    // MARK: OpenRouter account activity (cached)

    static func openRouterSummary(_ db: Database, start: String, end: String) throws -> JSON {
        guard let saved = try Store.setting(db, "openrouter_account_activity") else { return .null }
        let cache = try JSON.parse(saved)
        let cacheStart = cache["start"].stringValue ?? "", cacheEnd = cache["end_exclusive"].stringValue ?? ""
        let first = pyLess(cacheStart, start) ? start : cacheStart
        let until = pyLess(end, cacheEnd) ? end : cacheEnd
        struct Totals { var requests = 0, tokens = 0, spend = PyDecimal.zero }
        var total = Totals()
        var models = Ordered<String, Totals>()
        for row in cache["records"].arrayValue ?? [] {
            let day = row["day"].stringValue ?? ""
            guard !pyLess(day, first), pyLess(day, until) else { continue }
            let spend = PyDecimal(json: row["spend_usd"]) ?? .zero
            total.requests += row["requests"].intValue ?? 0
            total.tokens += row["tokens"].intValue ?? 0
            total.spend += spend
            let model = row["model"].stringValue ?? ""
            var item = models[model] ?? Totals()
            item.requests += row["requests"].intValue ?? 0
            item.tokens += row["tokens"].intValue ?? 0
            item.spend += spend
            models[model] = item
        }
        func display(_ value: Totals) -> [(String, JSON)] {
            [("requests", .int(Int64(value.requests))), ("tokens", .int(Int64(value.tokens))),
             ("spend_usd", .string(PyDecimal.money((value.spend * PyDecimal(100)).roundedHalfUp)))]
        }
        let open = pyLess(first, until)
        let sorted = models.pairs.stableSorted { a, b in
            if a.1.spend != b.1.spend { return b.1.spend < a.1.spend }
            return pyLess(a.0, b.0)
        }
        return .object([
            ("fetched_at", cache["fetched_at"]),
            ("start", open ? .string(first) : .null),
            ("end_exclusive", open ? .string(until) : .null),
            ("totals", .object(display(total))),
            ("models", .array(sorted.map { .object([("model", .string($0.0))] + display($0.1)) })),
        ])
    }

    // MARK: Text report

    static func clean(_ value: String) -> String {
        value.unicodeScalars.split { $0.properties.isWhitespace || (0x1C...0x1F).contains($0.value) }
            .map { String(String.UnicodeScalarView($0)) }.joined(separator: " ")
    }

    /// `f"{n:,}"`.
    static func grouped(_ number: Int) -> String {
        let digits = String(number.magnitude)
        var out = ""
        for (index, character) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(",") }
            out.append(character)
        }
        return (number < 0 ? "-" : "") + out
    }

    static func render(_ report: JSON) -> String {
        let currency = report["currency"].stringValue ?? ""
        var lines = ["\(report["start"].stringValue ?? "") to \(report["end_exclusive"].stringValue ?? "") (exclusive, \(report["timezone"].stringValue ?? ""))"]
        let plans = report["subscriptions"]
        if let list = plans["plans"].arrayValue, !list.isEmpty {
            lines.append("Current subscriptions: \(currency) \(plans["monthly_total"].stringValue ?? "") per month")
            for plan in list {
                lines.append("  \(clean(plan["name"].stringValue ?? "")): \(currency) \(plan["monthly"].stringValue ?? "") per month")
            }
        }
        let account = report["openrouter_account"]
        if !account.isNull, let start = account["start"].stringValue, !start.isEmpty {
            let total = account["totals"]
            lines.append("OpenRouter account, \(start) to \(account["end_exclusive"].stringValue ?? "") (exclusive, UTC)")
            lines.append("  USD \(total["spend_usd"].stringValue ?? "") reported spend · \(grouped(total["requests"].intValue ?? 0)) requests · \(grouped(total["tokens"].intValue ?? 0)) tokens")
        } else if !account.isNull {
            lines.append("OpenRouter account activity is unavailable for these dates.")
        }
        for usage in report["provider_usage"].arrayValue ?? [] {
            guard let id = usage["provider"].stringValue, let provider = AIProvider(rawValue: id) else { continue }
            let name = provider == .openrouter ? "OpenRouter API key usage" : provider.name
            guard let start = usage["from"].stringValue, let end = usage["until"].stringValue else {
                lines.append("\(name) usage is unavailable for these dates.")
                continue
            }
            let metrics = usage["totals"]
            let costs = (metrics["spend"].pairs ?? []).sorted { $0.0 < $1.0 }
                .map { "\($0.0) \($0.1.pythonText(indent: nil))" }
            let quantities = (metrics["quantities"].pairs ?? []).sorted { $0.0 < $1.0 }
                .map { "\($0.1.pythonText(indent: nil)) \(clean($0.0))" }
            let details = (costs + quantities).joined(separator: " · ")
            lines.append("\(name), \(start) to \(end) (exclusive, UTC)")
            lines.append("  " + (details.isEmpty ? "No recorded usage" : details))
        }
        var all = report["projects"].arrayValue ?? []
        var totals = report["totals"]
        totals.set("project", .string("Total"))
        all.append(totals)
        for project in all {
            var name = clean(project["project"].stringValue.nonEmpty ?? "Unassigned")
            if let client = project["client"].stringValue.nonEmpty { name += " / " + clean(client) }
            lines.append("\n\(name) — \(project["human_hours"].stringValue ?? "") human hours")
            if let activities = project["human_by_activity"].pairs, !activities.isEmpty {
                lines.append("  " + activities.map { "\($0.0): \($0.1.stringValue ?? "") h" }.joined(separator: ", "))
            }
            for (provider, metrics) in (project["agents"].pairs ?? []).stableSorted(by: { pyLess($0.0, $1.0) }) {
                let tokens = (metrics["tokens"].pairs ?? []).reduce(0) { $0 + ($1.1.intValue ?? 0) }
                let runtime = metrics["runtime_hours"].isNull ? "runtime unavailable"
                    : "\(metrics["runtime_hours"].stringValue ?? "") h (\(metrics["runtime_kind"].stringValue ?? "None"))"
                lines.append("  \(provider): \(grouped(tokens)) tokens · \(runtime)")
            }
            if project["provider_expenses"].stringValue != "0.00" {
                lines.append("  Provider expenses: \(currency) \(project["provider_expenses"].stringValue ?? "")")
            }
            if project["estimated_token_value"].stringValue != "0.00" {
                lines.append("  Estimate at manual rates: \(currency) \(project["estimated_token_value"].stringValue ?? "")")
            }
            if let value = project["api_equivalent_usd"].stringValue {
                lines.append("  API equivalent (OpenRouter base token rates): USD \(value)")
            }
            if let count = project["tokens_without_api_price"].intValue, count != 0 {
                lines.append("  Tokens without an API estimate: \(grouped(count))")
            }
            if let tasks = project["task_ids"].arrayValue, !tasks.isEmpty {
                lines.append("  Tasks: " + tasks.compactMap(\.stringValue).joined(separator: ", "))
            }
        }
        return lines.joined(separator: "\n")
    }
}
