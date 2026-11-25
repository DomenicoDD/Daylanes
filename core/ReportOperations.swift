import Foundation

/// Billing, reports, report rows, usage windows, the desktop snapshot and the day view (port PR D).
enum ReportOperations {
    static func period(_ p: Params, _ fallback: String) throws -> (String?, String?, String) {
        (try p.string("start"), try p.string("end"), try p.string("period") ?? fallback)
    }

    /// Current time in epoch milliseconds; `TRACKER_NOW` pins it for the parity check.
    static func now() -> Int {
        if let value = ProcessInfo.processInfo.environment["TRACKER_NOW"], let pinned = Int(value) { return pinned }
        return Values.nowMillis()
    }

    static let all: [EngineOperation] = [
        EngineOperation(name: "list_billing_terms", summary: "Billing terms of clients and projects.", effect: .read) { _, db, _ in
            try Billing.termsListing(db)
        },
        EngineOperation(name: "set_billing_terms", summary: "Replace a client's or project's billing terms.", effect: .config) { params, db, _ in
            let p = Params(params)
            let client = try p.string("client")
            try Billing.saveTerms(db, scope: client != nil ? "client" : "project", name: client ?? (try p.string("project")),
                                  humanRate: try p.string("human_rate"), agentMode: try p.string("agent_mode"),
                                  agentRate: try p.string("agent_rate"), markup: try p.string("markup"), cap: try p.string("cap"))
            return try Billing.termsListing(db)
        },
        EngineOperation(name: "set_exchange_rate", summary: "Ledger currency per US dollar for usage billing.", effect: .config) { params, db, _ in
            try Billing.setExchangeRate(db, try Params(params).string("rate"))
            return try Billing.termsListing(db)
        },
        EngineOperation(name: "billing_summary", summary: "Invoice lines for a period.", effect: .read) { params, db, _ in
            let (start, end, period) = try period(Params(params), "month")
            let (_, entries) = try EntryStore.scope(db, start: start, end: end, period: period)
            return try Billing.summary(db, entries, try Catalog(db))
        },
        EngineOperation(name: "usage_report", summary: "Time, agent usage and expenses for a period.", effect: .read) { params, db, _ in
            let p = Params(params)
            let (start, end, period) = try period(p, "week")
            return try Reports.report(db, start: start, end: end, period: period, project: try p.string("project"),
                                      client: try p.string("client"), task: try p.string("task"))
        },
        EngineOperation(name: "usage_report_text", summary: "The period report as text.", effect: .read) { params, db, _ in
            let p = Params(params)
            let (start, end, period) = try period(p, "week")
            let report = try Reports.report(db, start: start, end: end, period: period, project: try p.string("project"),
                                            client: try p.string("client"), task: try p.string("task"))
            return .string(Reports.render(report) + "\n")
        },
        EngineOperation(name: "review_unassigned", summary: "Imported usage without a project.", effect: .read) { params, db, _ in
            let (start, end, period) = try period(Params(params), "week")
            return try Reports.review(db, start: start, end: end, period: period)
        },
        EngineOperation(name: "get_snapshot", summary: "Usage and project data for the desktop app.", effect: .read) { params, db, context in
            let (start, end, period) = try period(Params(params), "week")
            var result = try Desktop.snapshot(db, start: start, end: end, period: period,
                                              includeHumanTime: try Params(params).bool("with_human_time"))
            result.set("database", .string(context.databasePath))
            return result
        },
        EngineOperation(name: "export_entries", summary: "Time, usage and costs as CSV.", effect: .read) { params, db, _ in
            let p = Params(params)
            let (start, end, period) = try period(p, "week")
            return .string(try Desktop.exportCSV(db, start: start, end: end, period: period, project: try p.string("project"),
                                                 client: try p.string("client")))
        },
        EngineOperation(name: "report_rows", summary: "Billing report rows that add up to the invoice.", effect: .read) { params, db, _ in
            let p = Params(params)
            let (start, end, period) = try period(p, "month")
            return try ReportRows.build(db, start: start, end: end, period: period, client: try p.string("client"),
                                        projects: try p.strings("project"))
        },
        EngineOperation(name: "assign_group", summary: "Assign a group of agent entries in a time range.", effect: .reversible) { params, db, _ in
            let p = Params(params)
            return try Desktop.assignGroup(db, target: try p.required("target"), provider: try Store.harnessID(try p.required("provider")),
                                           folder: try p.string("folder"), branch: try p.string("branch"),
                                           project: try p.string("project"), task: try p.string("task"),
                                           start: try p.required("start"), end: try p.required("end"),
                                           saveFolder: try p.bool("save_folder"))
        },
        EngineOperation(name: "list_entries", summary: "Captured entries with their ids, for corrections.", effect: .read) { params, db, _ in
            let p = Params(params)
            let limit = try p.int("limit") ?? 50
            if limit < 1 { throw EngineError.invalid("Limit must be positive") }
            let (start, end, period) = try period(p, "week")
            let (bounds, all) = try EntryStore.scope(db, start: start, end: end, period: period)
            let project = try p.string("project")
            let unassigned = try p.bool("unassigned")
            let rows = all.filter { (project == nil || pyEqual($0.project, project)) && (!unassigned || $0.project == nil) }
            var result = bounds
            result.set("entry_count", .int(Int64(rows.count)))
            result.set("entries", .array(rows.suffix(limit).map(\.json)))
            return result
        },
        EngineOperation(name: "usage_blocks", summary: "Agent usage in five-hour windows, with burn rate.", effect: .read) { params, db, _ in
            let p = Params(params)
            let hours = try p.int("hours") ?? 24
            guard (1...(24 * 366)).contains(hours) else { throw EngineError.invalid("Hours must be between 1 and 8784") }
            return try Blocks.usageBlocks(db, hours: hours, activeOnly: try p.bool("active"), now: now())
        },
        EngineOperation(name: "get_day", summary: "One day's activity blocks, agent threads and billing blocks.", effect: .read) { params, db, _ in
            let p = Params(params)
            return try Desktop.dayTimeline(db, day: p.string("day"), includeHumanTime: p.bool("with_human_time"))
        },
    ]
}
