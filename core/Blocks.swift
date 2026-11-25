import Foundation

/// Five-hour usage windows with burn rate, and the plan limits agents report (Python's `tracker/blocks.py`).
enum Blocks {
    static let window = 5 * 3600 * 1000
    static let hour = 3600 * 1000
    static let minute = 60 * 1000

    struct Window {
        var start: Int
        var end: Int
        var firstAt: Int
        var lastAt: Int
        var entries: [Entry]
    }

    static func windows(_ entries: [Entry]) -> [Window] {
        var result: [Window] = []
        var current: Window?
        for entry in entries {
            let at = entry.at
            if current == nil || at >= current!.end || at - current!.lastAt >= window {
                if let current { result.append(current) }
                let start = at - pyMod(at, hour)
                current = Window(start: start, end: start + window, firstAt: at, lastAt: at, entries: [])
            }
            current!.lastAt = at
            current!.entries.append(entry)
        }
        if let current { result.append(current) }
        return result
    }

    /// Python's `%` (the result takes the divisor's sign).
    static func pyMod(_ a: Int, _ b: Int) -> Int {
        let r = a % b
        return r != 0 && (r < 0) != (b < 0) ? r + b : r
    }

    /// Python's `//`.
    static func pyDiv(_ a: Int, _ b: Int) -> Int {
        let q = a / b
        return (a % b != 0) && ((a < 0) != (b < 0)) ? q - 1 : q
    }

    static func money(_ amount: PyDecimal) -> String { amount.quantized(-4).plain }

    static func describe(_ window: Window, provider: String, catalog: Catalog, now: Int) -> JSON {
        var tokens = [0, 0, 0, 0]
        var models = Ordered<String, Int>()
        var apiValue = PyDecimal.zero
        var unpriced = 0
        for entry in window.entries {
            let counts = [entry.input ?? 0, entry.cached ?? 0, entry.cacheWrite ?? 0, entry.output ?? 0]
            for index in 0..<4 { tokens[index] += counts[index] }
            let count = counts.reduce(0, +)
            let model = entry.model.nonEmpty ?? "unknown"
            models[model] = (models[model] ?? 0) + count
            if let quote = catalog.quote(entry) { apiValue += quote } else { unpriced += count }
        }
        let total = tokens.reduce(0, +)
        let active = window.start <= now && now < window.end
        let ranked = models.pairs.stableSorted { $0.1 > $1.1 }.map(\.0)
        var result = JSON.object([
            ("provider", .string(provider)), ("start", .int(Int64(window.start))), ("end", .int(Int64(window.end))),
            ("first_at", .int(Int64(window.firstAt))), ("last_at", .int(Int64(window.lastAt))), ("active", .bool(active)),
            ("requests", .int(Int64(window.entries.count))), ("tokens", Reports.tokensJSON(tokens)),
            ("total_tokens", .int(Int64(total))), ("api_value_usd", .string(money(apiValue))),
            ("tokens_without_api_price", .int(Int64(unpriced))), ("models", .strings(ranked)),
        ])
        if active {
            let elapsed = window.lastAt - window.firstAt
            let remaining = window.end - now
            result.set("resets_in_minutes", .int(Int64(pyDiv(remaining, minute))))
            if elapsed >= minute {
                let minutes = PyDecimal(elapsed) / PyDecimal(minute)
                let perMinute = PyDecimal(total) / minutes
                let usdPerMinute = apiValue / minutes
                let minutesLeft = PyDecimal(remaining) / PyDecimal(minute)
                result.set("burn_rate", .object([
                    ("tokens_per_minute", .int(Int64(perMinute.truncated))),
                    ("api_value_usd_per_hour", .string(money(usdPerMinute * PyDecimal(60)))),
                ]))
                result.set("projection", .object([
                    ("total_tokens", .int(Int64((PyDecimal(total) + perMinute * minutesLeft).truncated))),
                    ("api_value_usd", .string(money(apiValue + usdPerMinute * minutesLeft))),
                ]))
            } else {
                result.set("burn_rate", .null)
                result.set("projection", .null)
            }
        }
        return result
    }

    static func usageBlocks(_ db: Database, hours: Int, activeOnly: Bool, now: Int) throws -> JSON {
        let cutoff = now - hours * hour
        let providers = try db.query(
            "SELECT DISTINCT provider FROM entries WHERE kind = 'usage' AND provider IS NOT NULL AND at > ? AND at <= ?",
            [cutoff - window, now]).compactMap { $0[0].string }
        var byProvider: [(String, [Entry])] = []
        for provider in providers {
            let anchor = try db.first(
                "SELECT max(at) FROM (SELECT at, at - lag(at) OVER (ORDER BY at) AS gap FROM entries "
                + "WHERE kind = 'usage' AND provider = ? AND at <= ?) WHERE gap IS NULL OR gap >= ?",
                [provider, cutoff, window])?[0].int
            let rows = try db.query(
                "SELECT * FROM entries WHERE kind = 'usage' AND provider = ? AND at >= ? AND at <= ? ORDER BY at",
                [provider, anchor ?? cutoff, now])
            byProvider.append((provider, rows.map(EntryStore.record)))
        }
        let catalog = try Catalog(db)
        var found: [JSON] = []
        for (provider, entries) in byProvider.stableSorted(by: { pyLess($0.0, $1.0) }) {
            for window in windows(entries) where window.end > cutoff {
                let block = describe(window, provider: provider, catalog: catalog, now: now)
                if block["active"].boolValue == true || !activeOnly { found.append(block) }
            }
        }
        // sort(key=(start, provider), reverse=True), which keeps equal keys in order.
        found = found.stableSorted { a, b in
            let sa = a["start"].intValue ?? 0, sb = b["start"].intValue ?? 0
            if sa != sb { return sa > sb }
            return pyLess(b["provider"].stringValue ?? "", a["provider"].stringValue ?? "")
        }
        return .object([("now", .int(Int64(now))), ("window_hours", .int(Int64(window / hour))), ("blocks", .array(found)),
                        ("plan_limits", try planLimits(db, now: now))])
    }

    static func planLimits(_ db: Database, now: Int) throws -> JSON {
        var found: [JSON] = []
        for provider in ["codex"] {
            guard let raw = try? JSON.parse(try Store.setting(db, "\(provider)_rate_limits", "{}")),
                  let pairs = raw.pairs, !pairs.isEmpty else { continue }
            let observed = raw["observed_at"]
            var windows: [JSON] = []
            for name in ["primary", "secondary"] {
                let window = raw[name]
                guard window.pairs != nil, let used = window["used_percent"].doubleValue,
                      window["used_percent"].boolValue == nil else { continue }
                _ = used
                var resetsAt: Int?
                switch window["resets_at"] {
                case let .int(value): resetsAt = value < 100_000_000_000 ? Int(value) * 1000 : Int(value)
                case let .double(value): resetsAt = value < 1e11 ? Int(value * 1000) : Int(value)
                default:
                    if let seconds = window["resets_in_seconds"].doubleValue, window["resets_in_seconds"].boolValue == nil,
                       case let .int(start) = observed {
                        switch window["resets_in_seconds"] {
                        case let .int(value): resetsAt = Int(start) + Int(value) * 1000
                        default: resetsAt = Int(start) + Int(seconds * 1000)
                        }
                    }
                }
                let reset = resetsAt.map { $0 <= now } ?? false
                windows.append(.object([
                    ("name", .string(name)), ("window_minutes", window["window_minutes"]),
                    ("used_percent", reset ? .int(0) : window["used_percent"]), ("resets_at", .optional(resetsAt)),
                    ("resets_in_minutes", resetsAt == nil || reset ? .null : .int(Int64(pyDiv(resetsAt! - now, minute)))),
                    ("reset_since_observed", .bool(reset)),
                ]))
            }
            if !windows.isEmpty {
                let credits = raw["credits"].pairs != nil ? raw["credits"] : .null
                found.append(.object([("provider", .string(provider)), ("observed_at", observed),
                                      ("plan_type", raw["plan_type"]), ("windows", .array(windows)), ("credits", credits)]))
            }
        }
        return .array(found)
    }
}
