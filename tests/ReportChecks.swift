import Foundation

@main
struct ReportChecks {
    static let fixture = #"""
    {
      "start": "2026-11-01", "end_exclusive": "2026-12-01", "timezone": "Europe/Rome", "currency": "EUR",
      "usd_exchange_rate": "0.92", "needs_exchange_rate": false, "missing_human_rate": true,
      "client": "Acme", "projects": null,
      "rows": [
        {"id": "y1", "who": "you", "date": "2026-11-02", "started_at": 1793606400000, "ended_at": 1793611800000,
         "client": "Acme", "project": "Site", "project_kind": "billable", "task": "Login", "tags": ["dev"],
         "description": "Fix login", "provider": null, "models": [], "thread": null,
         "millis": 5400000, "billed_millis": 5400000,
         "tokens": {"input": 0, "cached": 0, "cache_write": 0, "output": 0},
         "api_usd": null, "tokens_without_api_price": 0, "agent_mode": null,
         "rate": "80.00", "time_amount": "120.00", "usage_amount": null, "amount": "120.00", "reimbursable": false},
        {"id": "y2", "who": "you", "date": "2026-11-03", "started_at": 1793710800000, "ended_at": 1793718000000,
         "client": "Acme", "project": "Site", "project_kind": "billable", "task": "Login", "tags": [],
         "description": "Login tests, \"edge\"\nsecond line", "provider": null, "models": [], "thread": null,
         "millis": 7200000, "billed_millis": 7200000,
         "tokens": {"input": 0, "cached": 0, "cache_write": 0, "output": 0},
         "api_usd": null, "tokens_without_api_price": 0, "agent_mode": null,
         "rate": "80.00", "time_amount": "160.00", "usage_amount": null, "amount": "160.00", "reimbursable": false},
        {"id": "y3", "who": "you", "date": "2026-11-03", "started_at": 1793696400000, "ended_at": 1793700000000,
         "client": "Acme", "project": "App", "project_kind": "billable", "task": null, "tags": [],
         "description": "Planning", "provider": null, "models": [], "thread": null,
         "millis": 3600000, "billed_millis": 3600000,
         "tokens": {"input": 0, "cached": 0, "cache_write": 0, "output": 0},
         "api_usd": null, "tokens_without_api_price": 0, "agent_mode": null,
         "rate": "90.00", "time_amount": "90.00", "usage_amount": null, "amount": "90.00", "reimbursable": false},
        {"id": "a1", "who": "agent", "date": "2026-11-02", "started_at": 1793613600000, "ended_at": 1793617200000,
         "client": "Acme", "project": "Site", "project_kind": "billable", "task": "Login", "tags": [],
         "description": "Refactor auth", "provider": "claude", "models": ["claude-opus"], "thread": "t1",
         "millis": 3600000, "billed_millis": 3600000,
         "tokens": {"input": 1000, "cached": 2000, "cache_write": 300, "output": 400},
         "api_usd": "1.234567", "tokens_without_api_price": 0, "agent_mode": "hybrid",
         "rate": "40.00", "time_amount": "40.00", "usage_amount": "1.25", "amount": "41.25", "reimbursable": false},
        {"id": "a2", "who": "agent", "date": "2026-11-03", "started_at": 1793692800000, "ended_at": 1793694600000,
         "client": "Acme", "project": "App", "project_kind": "billable", "task": "API", "tags": [],
         "description": "Endpoints", "provider": "codex", "models": ["gpt-5"], "thread": "t2",
         "millis": 1800000, "billed_millis": 1800000,
         "tokens": {"input": 500, "cached": 0, "cache_write": 0, "output": 500},
         "api_usd": null, "tokens_without_api_price": 1000, "agent_mode": "time",
         "rate": "40.00", "time_amount": "20.00", "usage_amount": null, "amount": "20.00", "reimbursable": false},
        {"id": "a3", "who": "agent", "date": "2026-11-03", "started_at": 1793721600000, "ended_at": 1793725200000,
         "client": "Acme", "project": "Site", "project_kind": "billable", "task": "Login", "tags": [],
         "description": "Login tests", "provider": "claude", "models": ["claude-sonnet"], "thread": "t3",
         "millis": 3600000, "billed_millis": 3600000,
         "tokens": {"input": 100, "cached": 0, "cache_write": 0, "output": 100},
         "api_usd": "0.500000", "tokens_without_api_price": 0, "agent_mode": "hybrid",
         "rate": "40.00", "time_amount": "40.00", "usage_amount": "0.60", "amount": "40.60", "reimbursable": false},
        {"id": "i1", "who": "you", "date": "2026-11-02", "started_at": 1793628000000, "ended_at": 1793631600000,
         "client": null, "project": "Admin", "project_kind": "internal", "task": null, "tags": [],
         "description": "Bookkeeping", "provider": null, "models": [], "thread": null,
         "millis": 3600000, "billed_millis": 3600000,
         "tokens": {"input": 0, "cached": 0, "cache_write": 0, "output": 0},
         "api_usd": null, "tokens_without_api_price": 0, "agent_mode": null,
         "rate": null, "time_amount": null, "usage_amount": null, "amount": null, "reimbursable": false},
        {"id": "i2", "who": "you", "date": "2026-11-03", "started_at": 1793714400000, "ended_at": 1793716200000,
         "client": null, "project": "Admin", "project_kind": "internal", "task": "Mail", "tags": [],
         "description": "Mail", "provider": null, "models": [], "thread": null,
         "millis": 1800000, "billed_millis": 1800000,
         "tokens": {"input": 0, "cached": 0, "cache_write": 0, "output": 0},
         "api_usd": null, "tokens_without_api_price": 0, "agent_mode": null,
         "rate": null, "time_amount": null, "usage_amount": null, "amount": null, "reimbursable": false},
        {"id": "y4", "who": "you", "date": "2026-12-01", "started_at": 1796079600000, "ended_at": 1796083200000,
         "client": "Acme", "project": "Site", "project_kind": "billable", "task": "Login", "tags": [],
         "description": "Past the end", "provider": null, "models": [], "thread": null,
         "millis": 3600000, "billed_millis": 0,
         "tokens": {"input": 0, "cached": 0, "cache_write": 0, "output": 0},
         "api_usd": null, "tokens_without_api_price": 0, "agent_mode": null,
         "rate": "80.00", "time_amount": null, "usage_amount": null, "amount": null, "reimbursable": false},
        {"id": "u1", "who": "you", "date": "2026-11-02", "started_at": 1793635200000, "ended_at": 1793637000000,
         "client": null, "project": null, "project_kind": null, "task": null, "tags": [],
         "description": "Unsorted", "provider": null, "models": [], "thread": null,
         "millis": 1800000, "billed_millis": 0,
         "tokens": {"input": 0, "cached": 0, "cache_write": 0, "output": 0},
         "api_usd": null, "tokens_without_api_price": 0, "agent_mode": null,
         "rate": null, "time_amount": null, "usage_amount": null, "amount": null, "reimbursable": false},
        {"id": "e1", "who": "expense", "date": "2026-11-04", "started_at": 1793786400000, "ended_at": 1793786400000,
         "client": "Acme", "project": "Site", "project_kind": "billable", "task": null, "tags": [],
         "description": "Train ticket", "provider": null, "models": [], "thread": null,
         "millis": 0, "billed_millis": 0,
         "tokens": {"input": 0, "cached": 0, "cache_write": 0, "output": 0},
         "api_usd": null, "tokens_without_api_price": 0, "agent_mode": null,
         "rate": null, "time_amount": null, "usage_amount": null, "amount": "45.50", "reimbursable": true},
        {"id": "e2", "who": "expense", "date": "2026-11-05", "started_at": 1793872800000, "ended_at": 1793872800000,
         "client": "Acme", "project": "Site", "project_kind": "billable", "task": null, "tags": [],
         "description": "=SUM(A1)", "provider": null, "models": [], "thread": null,
         "millis": 0, "billed_millis": 0,
         "tokens": {"input": 0, "cached": 0, "cache_write": 0, "output": 0},
         "api_usd": null, "tokens_without_api_price": 0, "agent_mode": null,
         "rate": null, "time_amount": null, "usage_amount": null, "amount": "12.00", "reimbursable": false}
      ],
      "adjustments": [{"client": "Acme", "kind": "monthly_cap", "monthly_cap": "100.00", "amount": "-1.85"}],
      "billing": {"ignored": true}
    }
    """#

    static let generatedAt = Date(timeIntervalSince1970: 1_795_176_000)

    static func expect(_ condition: Bool, _ message: String, line: Int = #line) {
        if !condition {
            print("Report check failed (line \(line)): \(message)")
            exit(1)
        }
    }

    static func decimal(_ text: String) -> Decimal {
        Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) ?? Decimal(-999_999)
    }

    static func name(_ provider: String) -> String {
        switch provider {
        case "claude": return "Claude Code"
        case "codex": return "Codex"
        default: return provider
        }
    }

    static func build(_ data: ReportData, _ options: ReportOptions) -> ReportDocument {
        ReportBuilder.build(data: data, options: options, generatedAt: generatedAt, providerName: name)
    }

    /// The report total computed straight from the rows: work amounts + adjustments + included expenses.
    static func expectedTotal(_ data: ReportData, _ options: ReportOptions) -> Decimal? {
        guard options.showsMoney else { return nil }
        var total = Decimal(0)
        for row in data.rows {
            switch row.kind {
            case .you, .agent:
                if row.project == nil { continue }
                if options.billableOnly && row.projectKind != "billable" { continue }
                if row.kind == .you && options.who == .agents { continue }
                if row.kind == .agent && options.who == .you { continue }
                total += row.amount ?? Decimal(0)
            case .expense:
                if options.expenses == .none { continue }
                if options.expenses == .reimbursable && !row.reimbursable { continue }
                if options.billableOnly && row.project != nil && row.projectKind != "billable" { continue }
                total += row.amount ?? Decimal(0)
            case .other:
                continue
            }
        }
        if options.who != .you {
            for adjustment in data.adjustments { total += adjustment.amount }
        }
        return total
    }

    /// A small CSV reader that honours quotes, for checking the exports.
    static func parseCSV(_ text: String, separator: ReportCSVSeparator) -> [[String]] {
        let mark: Unicode.Scalar = separator == .comma ? "," : ";"
        var scalars = Array(text.unicodeScalars)
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        var index = 0
        while index < scalars.count {
            let scalar = scalars[index]
            if quoted {
                if scalar == "\"" {
                    if index + 1 < scalars.count && scalars[index + 1] == "\"" {
                        field.unicodeScalars.append("\"")
                        index += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.unicodeScalars.append(scalar)
                }
            } else if scalar == "\"" {
                quoted = true
            } else if scalar == mark {
                row.append(field)
                field = ""
            } else if scalar == "\r" {
                // Part of the CRLF line end.
            } else if scalar == "\n" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.unicodeScalars.append(scalar)
            }
            index += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    /// Report CSV columns: 7 hours, 8 rate, 9 time amount, 10 usage amount, 11 amount.
    static let csvHours = 7
    static let csvTimeAmount = 9
    static let csvUsageAmount = 10
    static let csvAmount = 11
    static let csvColumns = 16

    static func columnSum(_ rows: [[String]], _ column: Int, separator: ReportCSVSeparator) -> Decimal {
        var sum = Decimal(0)
        for row in rows.dropFirst() where row.count > column && !row[column].isEmpty {
            let text = separator == .semicolon ? row[column].replacingOccurrences(of: ",", with: ".") : row[column]
            sum += decimal(text)
        }
        return sum
    }

    static func amountSum(_ rows: [[String]], separator: ReportCSVSeparator) -> Decimal {
        columnSum(rows, csvAmount, separator: separator)
    }

    static func checkCSV(_ document: ReportDocument, strings: ReportStrings, separator: ReportCSVSeparator) {
        let csv = ReportCSV.report(document, strings: strings, separator: separator)
        expect(csv.hasPrefix("\u{FEFF}"), "CSV starts with a byte order mark")
        expect(csv.hasSuffix("\r\n"), "CSV ends lines with CRLF")
        let rows = parseCSV(csv, separator: separator)
        expect(rows.count >= 1 && rows[0].count == csvColumns, "CSV header has \(csvColumns) columns")
        for row in rows {
            expect(row.count == csvColumns, "every CSV row has \(csvColumns) columns, found \(row.count): \(row)")
        }
        if let total = document.grandTotal {
            expect(amountSum(rows, separator: separator) == total,
                   "CSV amounts add up to the total \(total) with \(document.options)")
        } else {
            expect(rows.dropFirst().allSatisfy { $0[csvAmount].isEmpty && $0[csvTimeAmount].isEmpty
                       && $0[csvUsageAmount].isEmpty }, "a timesheet CSV has no amounts")
        }
        // The CSV prints the same reconciled hours as the PDF: its lines add up to the summary's hours.
        if document.options.columns.contains(.hours) {
            let shown = document.shownHours?.hours ?? Decimal(0)
            expect(columnSum(rows, csvHours, separator: separator) == shown,
                   "CSV hours add up to the summary's \(shown) with \(document.options)")
        } else {
            expect(rows.dropFirst().allSatisfy { $0[csvHours].isEmpty }, "no hours without the Hours column")
        }
    }

    /// Printed hours add up at every level: lines to their subtotal, subtotals to the section total, which is
    /// the rounded true total; the summary's hours are what the lines show.
    static func checkHours(_ document: ReportDocument) {
        var youHours = Decimal(0)
        var youMinutes = 0
        var agentHours = Decimal(0)
        var agentMinutes = 0
        let workSections = document.sections.filter { $0.kind != .expenses }
        for section in workSections {
            var sectionHours = Decimal(0)
            var sectionMinutes = 0
            for group in section.groups {
                var groupHours = Decimal(0)
                var groupMinutes = 0
                for line in group.lines {
                    expect((line.displayHours == nil) == !line.hasTime && (line.displayMinutes == nil) == !line.hasTime,
                           "only a line without time has no printed hours")
                    let hours = line.displayHours ?? Decimal(0)
                    let minutes = line.displayMinutes ?? 0
                    expect(hours >= Decimal(0) && minutes >= 0, "printed hours are never negative")
                    expect(ReportNumber.rounded(hours, places: 2) == hours, "printed hours have two decimals")
                    groupHours += hours
                    groupMinutes += minutes
                    if line.who.you {
                        youHours += hours
                        youMinutes += minutes
                    } else {
                        agentHours += hours
                        agentMinutes += minutes
                    }
                }
                if let subtotal = group.subtotal {
                    expect((subtotal.displayHours ?? Decimal(0)) == groupHours,
                           "lines add up to their subtotal's hours with \(document.options)")
                    expect((subtotal.displayMinutes ?? 0) == groupMinutes,
                           "lines add up to their subtotal's minutes with \(document.options)")
                    sectionHours += subtotal.displayHours ?? Decimal(0)
                    sectionMinutes += subtotal.displayMinutes ?? 0
                } else {
                    sectionHours += groupHours
                    sectionMinutes += groupMinutes
                }
            }
            let total = section.total
            expect((total.displayHours ?? Decimal(0)) == sectionHours,
                   "subtotals add up to the section's hours with \(document.options)")
            expect((total.displayMinutes ?? 0) == sectionMinutes,
                   "subtotals add up to the section's minutes with \(document.options)")
            if total.hasTime {
                expect(total.displayHours == ReportNumber.hours(millis: total.billedMillis),
                       "the section's hours are its rounded true total")
                expect(total.displayMinutes == (total.billedMillis + 30_000) / 60_000,
                       "the section's minutes are its rounded true total")
            }
        }
        if !workSections.isEmpty {
            if let shown = document.youHours {
                expect(shown.hours == youHours && shown.minutes == youMinutes,
                       "the summary's hours for the person are what the table shows with \(document.options)")
            }
            if let shown = document.agentHours {
                expect(shown.hours == agentHours && shown.minutes == agentMinutes,
                       "the summary's hours for agents are what the table shows with \(document.options)")
            }
        }
        for item in document.summary {
            switch item {
            case .you(let millis, _):
                expect(document.youHours != nil, "the person's summary line has hours")
                if workSections.isEmpty {
                    expect(document.youHours?.hours == ReportNumber.hours(millis: millis), "summary hours without a table")
                }
            case .agents(let millis, _):
                expect(document.agentHours != nil, "the agents' summary line has hours")
                if workSections.isEmpty {
                    expect(document.agentHours?.hours == ReportNumber.hours(millis: millis), "summary hours without a table")
                }
            default:
                break
            }
        }
    }

    /// Time and usage columns appear, right before Amount, only when a section has both kinds of amount.
    static func checkAmountParts(_ document: ReportDocument) {
        for section in document.sections {
            var lines: [ReportLine] = []
            for group in section.groups {
                lines.append(contentsOf: group.lines)
                if let subtotal = group.subtotal { lines.append(subtotal) }
            }
            lines.append(section.total)
            if section.kind != .expenses {
                for line in lines {
                    let parts: Decimal? = line.timeAmount == nil && line.usageAmount == nil
                        ? nil : (line.timeAmount ?? Decimal(0)) + (line.usageAmount ?? Decimal(0))
                    expect(parts == line.amount, "time plus usage is the amount: \(line)")
                }
            }
            let tableLines: [ReportLine] = section.groups.flatMap { $0.lines }
            let split = section.kind != .expenses && document.options.columns.contains(.amount)
                && tableLines.contains { $0.timeAmount != nil } && tableLines.contains { $0.usageAmount != nil }
            expect(section.columns.contains(.timeAmount) == split && section.columns.contains(.usageAmount) == split,
                   "time and usage columns only for mixed amounts: \(section.columns) with \(document.options)")
            if split, let time = section.columns.firstIndex(of: .timeAmount),
               let usage = section.columns.firstIndex(of: .usageAmount),
               let amount = section.columns.firstIndex(of: .amount) {
                expect(usage == time + 1 && amount == usage + 1, "Time and Usage sit right before Amount")
            }
        }
    }

    static func checkDocument(_ data: ReportData, _ options: ReportOptions) {
        let document = build(data, options)
        let expected = expectedTotal(data, options)
        expect(document.grandTotal == expected,
               "total \(String(describing: document.grandTotal)) is \(String(describing: expected)) for \(options)")
        if options.detail == .totals {
            expect(document.sections.isEmpty, "totals detail has no table")
        }
        var sum = Decimal(0)
        for section in document.sections {
            var sectionSum = Decimal(0)
            var sectionMillis = 0
            for group in section.groups {
                expect((group.title == nil) == (group.subtotal == nil), "only grouped sections have subtotals")
                var groupSum = Decimal(0)
                var groupMillis = 0
                for line in group.lines {
                    expect(!line.isTotal, "table lines are not totals")
                    groupSum += line.amount ?? Decimal(0)
                    groupMillis += line.billedMillis
                }
                if let subtotal = group.subtotal {
                    expect((subtotal.amount ?? Decimal(0)) == groupSum, "subtotal adds up its lines")
                    expect(subtotal.billedMillis == groupMillis, "subtotal hours add up")
                    expect(subtotal.isTotal, "subtotal is marked as a total")
                }
                sectionSum += groupSum
                sectionMillis += groupMillis
            }
            expect((section.total.amount ?? Decimal(0)) == sectionSum, "section total adds up its lines")
            expect(section.total.billedMillis == sectionMillis, "section hours add up")
            sum += section.total.amount ?? Decimal(0)
            if options.groupBy.rawValue == options.detail.rawValue {
                expect(section.groups.count == 1 && section.groups[0].title == nil,
                       "grouping by the detail dimension collapses to no grouping")
            }
        }
        if options.showsMoney && options.detail != .totals {
            for item in document.adjustments {
                if case .capAdjustment(_, _, let amount) = item { sum += amount }
            }
            expect(sum == expected, "sections and adjustments add up to the total for \(options)")
        }
        checkHours(document)
        checkAmountParts(document)
        checkCSV(document, strings: ReportStrings(document: document), separator: .comma)
        checkCSV(document, strings: ReportStrings(document: document), separator: .semicolon)
    }

    /// Three 20-minute sessions (0.33 h each, 1.00 h in all) and an agent's usage with no run time.
    static func thirdsData(_ data: ReportData) -> ReportData {
        var result = data
        var rows: [ReportRow] = []
        let days: [String] = ["2026-11-02", "2026-11-03", "2026-11-04"]
        for (index, day) in days.enumerated() {
            var row = data.rows[0]
            row.id = "third\(index)"
            row.date = day
            row.millis = 1_200_000
            row.billedMillis = 1_200_000
            row.timeAmount = decimal("26.67")
            row.amount = decimal("26.67")
            rows.append(row)
        }
        var usage = data.rows[3]
        usage.id = "usage-only"
        usage.date = "2026-11-04"
        usage.millis = 0
        usage.billedMillis = 0
        usage.task = nil
        usage.description = ""
        usage.agentMode = "usage"
        usage.rate = nil
        usage.timeAmount = nil
        usage.usageAmount = decimal("17.41")
        usage.amount = decimal("17.41")
        rows.append(usage)
        result.rows = rows
        result.adjustments = []
        return result
    }

    static func lines(_ section: ReportSection) -> [ReportLine] {
        section.groups.flatMap { $0.lines }
    }

    static func checkRanges() {
        func range(_ range: ReportRange, _ timezone: String, _ now: Date, _ start: String, _ end: String) -> Bool {
            let bounds = range.bounds(timezone: timezone, now: now)
            return bounds.start == start && bounds.endExclusive == end
        }
        let friday = Date(timeIntervalSince1970: 1_795_176_000)  // 2026-11-20 12:00 UTC
        let rome = "Europe/Rome"
        expect(range(.thisMonth, rome, friday, "2026-11-01", "2026-12-01"), "this month")
        expect(range(.lastMonth, rome, friday, "2026-10-01", "2026-11-01"), "last month")
        expect(range(.thisWeek, rome, friday, "2026-11-16", "2026-11-23"), "this week")
        expect(range(.lastWeek, rome, friday, "2026-11-09", "2026-11-16"), "last week")

        let newYear = Date(timeIntervalSince1970: 1_767_355_200)  // 2026-01-02 12:00 UTC, a Friday
        expect(range(.lastMonth, rome, newYear, "2025-12-01", "2026-01-01"), "December")
        expect(range(.thisWeek, rome, newYear, "2025-12-29", "2026-01-05"), "week over new year")
        expect(range(.lastWeek, rome, newYear, "2025-12-22", "2025-12-29"), "last week of the year")

        let lateNight = Date(timeIntervalSince1970: 1_796_081_400)  // 2026-11-30 23:30 UTC, December 1 in Rome
        expect(range(.thisMonth, rome, lateNight, "2026-12-01", "2027-01-01"), "month in Rome")
        expect(range(.thisMonth, "UTC", lateNight, "2026-11-01", "2026-12-01"), "month in UTC")

        let sundayNight = Date(timeIntervalSince1970: 1_795_390_200)  // Sunday 23:30 UTC, Monday in Rome
        expect(range(.thisWeek, rome, sundayNight, "2026-11-23", "2026-11-30"), "Monday in Rome")
        expect(range(.thisWeek, "UTC", sundayNight, "2026-11-16", "2026-11-23"),
               "Sunday ends the week")

        expect(range(.custom(start: "2028-02-01", end: "2028-02-28"), rome, friday, "2028-02-01", "2028-02-29"), "custom range ends the day after its last day")
        expect(range(.custom(start: "2026-12-01", end: "2026-12-31"), rome, friday, "2026-12-01", "2027-01-01"), "custom range over new year")
    }

    static func checkOptionsCoding() {
        var options = ReportOptions()
        options.range = .custom(start: "2026-11-01", end: "2026-11-30")
        options.columns = [.hours, .tokens]
        options.language = .de
        options.title = "Bericht"
        options.personName = "Ada"
        do {
            let encoded = try JSONEncoder().encode(options)
            let decoded = try JSONDecoder().decode(ReportOptions.self, from: encoded)
            expect(decoded == options, "options survive a round trip")
            let empty = try JSONDecoder().decode(ReportOptions.self, from: Data("{}".utf8))
            expect(empty == ReportOptions(), "missing options fall back to the defaults")
            let odd = #"{"who": "robots", "columns": ["hours", "sparkles"], "detail": "day"}"#
            let partial = try JSONDecoder().decode(ReportOptions.self, from: Data(odd.utf8))
            expect(partial.who == .both && partial.columns == [.hours] && partial.detail == .day,
                   "unknown option values are ignored")
        } catch {
            expect(false, "options coding threw \(error)")
        }
    }

    static func main() {
        let data: ReportData
        do {
            data = try ReportData.decode(Data(fixture.utf8))
        } catch {
            print("Report fixture did not decode: \(error)")
            exit(1)
        }
        expect(data.rows.count == 12 && data.adjustments.count == 1, "fixture decodes")
        expect(data.rows[0].rate == decimal("80.00") && data.rows[0].tokens.total == 0, "money decodes as Decimal")
        expect(data.rows[3].tokens.cacheWrite == 300 && data.rows[3].apiUsd == decimal("1.234567"), "agent row decodes")
        expect(data.rows[1].description == "Login tests, \"edge\"\nsecond line", "description decodes")

        // Totals at every detail level, grouping and filter.
        let columnSets: [Set<ReportOptionalColumn>] = [ReportOptions().columns, [.hours], Set(ReportOptionalColumn.allCases)]
        for detail in ReportDetail.allCases {
            for groupBy in ReportGroupBy.allCases {
                for separateAgents in [false, true] {
                    for who in ReportWho.allCases {
                        for billableOnly in [true, false] {
                            for expenses in ReportExpenses.allCases {
                                for columns in columnSets {
                                    var options = ReportOptions()
                                    options.detail = detail
                                    options.groupBy = groupBy
                                    options.separateAgents = separateAgents
                                    options.who = who
                                    options.billableOnly = billableOnly
                                    options.expenses = expenses
                                    options.columns = columns
                                    checkDocument(data, options)
                                    if billableOnly && expenses == .none {
                                        checkDocument(thirdsData(data), options)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        // Default report: 370 of yours + 101.85 of agents - 1.85 cap + 45.50 reimbursable expense.
        let standard = build(data, ReportOptions())
        expect(standard.grandTotal == decimal("515.50"), "default total")
        expect(standard.summary.contains(.capAdjustment(client: "Acme", monthlyCap: decimal("100.00"),
                                                        amount: decimal("-1.85"))), "cap adjustment in the summary")
        expect(standard.summary.contains(.you(millis: 16_200_000, amount: decimal("370.00"))), "your hours and amount")
        expect(standard.summary.contains(.agents(millis: 9_000_000, amount: decimal("101.85"))), "agent hours and amount")
        expect(standard.summary.contains(.expenses(decimal("45.50"))), "reimbursable expenses only")
        expect(standard.warnings == [.tokensWithoutPrice(1000)], "only the relevant warnings: \(standard.warnings)")
        expect(standard.header.end == "2026-11-30" && standard.header.client == "Acme", "header period and client")
        expect(standard.sections.map { $0.kind } == [.work, .expenses], "one work table and the expenses")
        expect(standard.sections[0].columns == [.description, .who, .hours, .rate, .timeAmount, .usageAmount, .amount],
               "default columns, with time and usage split out for the hybrid agent lines")
        let projectTitles = standard.sections[0].groups.map { $0.title }
        expect(projectTitles == [.project("App"), .project("Site")], "projects in alphabetical order")
        let appLines = standard.sections[0].groups[0].lines.map { $0.label }
        expect(appLines == [.task(project: nil, task: "API"), .task(project: nil, task: nil)], "No task comes last")
        let siteLines = standard.sections[0].groups[1].lines
        expect(siteLines.count == 2 && siteLines[0].who == ReportWhoValue(you: true, agents: [])
               && siteLines[1].who == ReportWhoValue(you: false, agents: ["Claude Code"]),
               "you and agents never share a line")
        expect(siteLines[0].rate == decimal("80.00") && siteLines[0].amount == decimal("280.00"), "shared rate is kept")

        // Filters.
        var yours = ReportOptions()
        yours.who = .you
        let yourReport = build(data, yours)
        expect(yourReport.grandTotal == decimal("415.50") && yourReport.adjustments.isEmpty, "your time only")
        expect(yourReport.sections[0].kind == .you && !yourReport.sections[0].columns.contains(.who), "no Who column")
        expect(yourReport.sections[0].columns == [.description, .hours, .rate, .amount], "pure time billing: no split")
        var agentsOnly = ReportOptions()
        agentsOnly.who = .agents
        expect(build(data, agentsOnly).grandTotal == decimal("145.50"), "agents only")

        var everything = ReportOptions()
        everything.billableOnly = false
        everything.detail = .project
        everything.groupBy = .none
        let all = build(data, everything)
        let allRows = lines(all.sections[0]).reduce(0) { $0 + $1.rowCount }
        expect(allRows == 9, "internal work is in, unassigned work never is")
        expect(lines(all.sections[0]).contains { $0.label == .project("Admin") && $0.amount == nil
                   && $0.billedMillis == 5_400_000 }, "internal has no amount, and its hours are never zero")
        expect(lines(build(data, ReportOptions()).sections[0]).reduce(0) { $0 + $1.rowCount } == 7, "billable only")
        expect(!all.warnings.contains(.missingHumanRate), "internal work does not warn about rates")
        // A fully overlapped internal session (worked time, nothing billed) adds no hours.
        var overlapped = data
        if var shadow = data.rows.first(where: { $0.id == "i2" }) {
            shadow.id = "i2-overlap"
            shadow.millis = 1_800_000
            shadow.billedMillis = 0
            overlapped.rows.append(shadow)
        }
        expect(overlapped.rows.count == data.rows.count + 1, "overlap fixture row added")
        let overlapReport = build(overlapped, everything)
        expect(lines(overlapReport.sections[0]).contains { $0.label == .project("Admin") && $0.billedMillis == 5_400_000 },
               "a fully overlapped internal session contributes zero hours")
        expect(overlapReport.youHours == all.youHours, "the summary hours ignore the overlapped session too")

        // The person, as the client reads it.
        let neutral = ReportStrings(document: standard)
        expect(neutral.whoText(ReportWhoValue(you: true, agents: ["Codex"])) == "Consultant, Codex", "neutral person label")
        expect(neutral.sectionTitle(.you) == "Work hours" && neutral.sectionTitle(.agents) == "AI agents",
               "client-facing section titles")
        expect(neutral.summaryLabel(.you(millis: 0, amount: nil)) == "Consultant", "summary names the consultant")
        var named = ReportOptions()
        named.personName = "  Ada Lovelace "
        let namedReport = build(data, named)
        expect(namedReport.header.personName == "  Ada Lovelace ", "the header carries the name")
        let namedStrings = ReportStrings(document: namedReport)
        expect(namedStrings.whoText(ReportWhoValue(you: true, agents: [])) == "Ada Lovelace", "the name replaces You")
        let namedRows = parseCSV(ReportCSV.report(namedReport, strings: namedStrings, separator: .comma), separator: .comma)
        expect(namedRows.contains { $0[6] == "Ada Lovelace" } && !namedRows.contains { $0[6] == "You" },
               "the CSV Who column uses the name")
        expect(ReportStrings(language: .de).person == "Berater" && ReportStrings(language: .it).person == "Consulente",
               "localized neutral label")
        expect(!ReportPDF.render(document: namedReport, strings: namedStrings, paper: .a4, orientation: .portrait).isEmpty,
               "the PDF renders")

        // Rates: nil when merged rows differ.
        var days = ReportOptions()
        days.detail = .day
        days.groupBy = .none
        days.separateAgents = true
        let dayReport = build(data, days)
        let yourDays = lines(dayReport.sections[0])
        expect(dayReport.sections[0].kind == .you && yourDays.count == 3, "three days of yours, one past the end")
        expect(yourDays[0].label == .day("2026-11-02") && yourDays[0].rate == decimal("80.00"), "one rate")
        expect(yourDays[1].label == .day("2026-11-03") && yourDays[1].rate == nil, "different rates merge to nil")
        expect(yourDays[2].label == .day("2026-12-01") && yourDays[2].amount == nil && yourDays[2].billedMillis == 0,
               "a piece past the period end is kept, with no amount")
        let dayStrings = ReportStrings(document: dayReport)
        expect(yourDays[2].displayHours == Decimal(0) && dayStrings.formatLineHours(yourDays[2], style: .decimal) == "0.00",
               "a line with worked time but nothing billed still shows 0.00")
        expect(dayReport.sections[1].kind == .agents, "agents get their own section")

        // Printed hours add up: three sessions of 0.33 h each print 0.34 + 0.33 + 0.33 = 1.00.
        let thirds = thirdsData(data)
        var thirdDays = ReportOptions()
        thirdDays.detail = .day
        thirdDays.groupBy = .none
        thirdDays.separateAgents = true
        let thirdReport = build(thirds, thirdDays)
        let thirdLines = lines(thirdReport.sections[0])
        expect(thirdLines.map { $0.displayHours } == [decimal("0.34"), decimal("0.33"), decimal("0.33")],
               "largest remainder, ties to the earlier line: \(thirdLines.map { $0.displayHours })")
        expect(thirdLines.map { $0.displayMinutes } == [20, 20, 20], "clock minutes add up too")
        expect(thirdReport.sections[0].total.displayHours == decimal("1.00"), "the total is the rounded true total")
        expect(thirdReport.youHours == ReportShownHours(hours: decimal("1.00"), minutes: 60),
               "the summary's hours are the table's")
        let thirdStrings = ReportStrings(document: thirdReport)
        expect(thirdStrings.formatLineHours(thirdLines[1], style: .decimal) == "0.33", "a line prints its share")
        expect(thirdStrings.formatLineHours(thirdLines[0], style: .clock) == "0h 20m", "clock lines print minutes")
        // Usage with no run time: a dash in the PDF, nothing in the CSV.
        let usageSection = thirdReport.sections[1]
        let usageLines = lines(usageSection)
        expect(usageSection.kind == .agents && usageLines.count == 1 && usageLines[0].displayHours == nil
               && usageLines[0].displayMinutes == nil, "usage without run time has no hours")
        expect(thirdStrings.formatLineHours(usageLines[0], style: .decimal) == "—"
               && thirdStrings.formatLineHours(usageLines[0], style: .clock) == "—", "no time prints a dash")
        expect(thirdStrings.formatLineHours(usageSection.total, style: .decimal) == "—", "a total without time too")
        // Pure usage (agents) and pure time (you) sections keep the plain Amount column.
        expect(usageSection.columns == [.description, .who, .hours, .rate, .amount], "pure usage billing: no split")
        expect(thirdReport.sections[0].columns == [.description, .hours, .rate, .amount], "pure time billing: no split")
        let thirdCSV = parseCSV(ReportCSV.report(thirdReport, strings: thirdStrings, separator: .comma), separator: .comma)
        expect(thirdCSV.contains { $0[6] == "Claude Code" && $0[csvHours].isEmpty && $0[csvUsageAmount] == "17.41"
                   && $0[csvTimeAmount].isEmpty && $0[csvAmount] == "17.41" }, "no hours in the CSV for a line without time")
        expect(columnSum(thirdCSV, csvHours, separator: .comma) == decimal("1.00"), "CSV hours add up to 1.00")
        expect(!ReportPDF.render(document: thirdReport, strings: thirdStrings, paper: .a4, orientation: .landscape).isEmpty,
               "the PDF renders lines without time")
        var mixed = thirdDays
        mixed.separateAgents = false
        let mixedSection = build(thirds, mixed).sections[0]
        expect(mixedSection.columns == [.description, .who, .hours, .rate, .timeAmount, .usageAmount, .amount],
               "time and usage lines in one table split the amount")
        var noAmount = mixed
        noAmount.columns = [.hours, .rate]
        expect(!build(thirds, noAmount).sections[0].columns.contains(.timeAmount), "no split without the Amount column")

        // An agent entry with nothing to describe it is an agent session; your own keeps "No description".
        var thirdEntries = ReportOptions()
        thirdEntries.detail = .entry
        thirdEntries.groupBy = .project
        let entryLines = lines(build(thirds, thirdEntries).sections[0])
        let session = entryLines.first { $0.who.agents == ["Claude Code"] }
        expect(session?.label == .agentSession(project: nil, task: nil), "agent line without a description")
        if let label = session?.label {
            expect(thirdStrings.text(label).primary == "Agent session", "Agent session label")
            expect(ReportStrings(language: .it).text(label).primary == "Sessione dell’agente"
                   && ReportStrings(language: .fr).text(label).primary == "Session de l’agent"
                   && ReportStrings(language: .es).text(label).primary == "Sesión del agente"
                   && ReportStrings(language: .de).text(label).primary == "Agentensitzung", "localized agent session")
        }
        let sessionText = thirdStrings.text(.agentSession(project: "Site", task: nil))
        expect(sessionText.primary == "Agent session" && sessionText.secondary == "Site",
               "an agent session keeps its project underneath")
        expect(thirdStrings.text(.entry(description: " ", project: nil, task: nil)).primary == "No description",
               "your own line without a description")

        // Group by who: you first, then each provider.
        var byWho = ReportOptions()
        byWho.detail = .project
        byWho.groupBy = .who
        let whoTitles = build(data, byWho).sections[0].groups.map { $0.title }
        expect(whoTitles == [.who(ReportWhoValue(you: true, agents: [])),
                             .who(ReportWhoValue(you: false, agents: ["Claude Code"])),
                             .who(ReportWhoValue(you: false, agents: ["Codex"]))], "who groups: \(whoTitles)")

        // Grouping by the detail dimension collapses.
        var collapsed = ReportOptions()
        collapsed.detail = .project
        collapsed.groupBy = .project
        let collapsedSection = build(data, collapsed).sections[0]
        expect(collapsedSection.groups.count == 1 && collapsedSection.groups[0].subtotal == nil, "collapsed grouping")

        // Pure timesheet: no money anywhere.
        var timesheet = ReportOptions()
        timesheet.columns = [.hours]
        let sheet = build(data, timesheet)
        expect(sheet.grandTotal == nil && sheet.summary.allSatisfy { item in
            switch item {
            case .you(_, let amount), .agents(_, let amount): return amount == nil
            case .tokens, .aiCost: return true
            default: return false
            }
        }, "a timesheet shows no money")

        // CSV details.
        var entries = ReportOptions()
        entries.detail = .entry
        entries.expenses = .all
        entries.columns = [.hours, .rate, .amount, .timeRange]
        let entryReport = build(data, entries)
        let strings = ReportStrings(document: entryReport)
        let commaCSV = ReportCSV.report(entryReport, strings: strings, separator: .comma)
        expect(commaCSV.contains("\"Login tests, \"\"edge\"\"\nsecond line (Login)\""), "quoted field")
        let commaRows = parseCSV(commaCSV, separator: .comma)
        expect(commaRows[0][0] == "Section" && commaRows[0][csvAmount] == "Amount", "English header")
        expect(commaRows[0][csvTimeAmount] == "Time amount" && commaRows[0][csvUsageAmount] == "Usage amount",
               "time and usage amount headers")
        expect(commaRows.contains { $0[5] == "'=SUM(A1) (Site)" }, "formula guard on text")
        expect(commaRows.contains { $0[csvAmount] == "-1.85" }, "negative amounts stay numbers")
        expect(commaRows.contains { $0[5] == "Refactor auth (Login)" && $0[8] == "40.00"
                   && $0[csvTimeAmount] == "40.00" && $0[csvUsageAmount] == "1.25" && $0[csvAmount] == "41.25" },
               "a hybrid line carries its time and usage amounts")
        expect(commaRows.contains { $0[5] == "Fix login (Login)" && $0[csvTimeAmount] == "120.00"
                   && $0[csvUsageAmount].isEmpty }, "a time line has no usage amount")
        expect(commaRows.contains { $0[5] == "Fix login (Login)" && $0[3] == "09:00" && $0[4] == "10:30" && $0[7] == "1.50" },
               "entry times in the ledger time zone, decimal hours")
        let semicolonCSV = ReportCSV.report(entryReport, strings: strings, separator: .semicolon)
        let semicolonRows = parseCSV(semicolonCSV, separator: .semicolon)
        expect(semicolonCSV.hasPrefix("\u{FEFF}Section;Group;"), "semicolon separator")
        expect(semicolonRows.contains { $0[5] == "Fix login (Login)" && $0[7] == "1,50" && $0[csvAmount] == "120,00" },
               "decimal comma with semicolons")
        expect(amountSum(semicolonRows, separator: .semicolon) == entryReport.grandTotal, "semicolon amounts add up")
        expect(entryReport.grandTotal == decimal("527.50"), "all expenses included")

        // A money column that is off stays empty in the CSV on every row.
        let csvRate = 8
        var amountOnly = entries
        amountOnly.columns = [.hours, .amount]
        let amountOnlyReport = build(data, amountOnly)
        let amountOnlyRows = Array(parseCSV(ReportCSV.report(amountOnlyReport, strings: ReportStrings(document: amountOnlyReport),
                                                             separator: .comma), separator: .comma).dropFirst())
        expect(!amountOnlyRows.isEmpty && amountOnlyRows.allSatisfy { $0[csvRate].isEmpty },
               "no rate in the CSV without the Rate column")
        expect(amountOnlyRows.contains { !$0[csvAmount].isEmpty }, "amounts stay with the Amount column")
        var rateOnly = entries
        rateOnly.columns = [.hours, .rate]
        let rateOnlyReport = build(data, rateOnly)
        let rateOnlyRows = Array(parseCSV(ReportCSV.report(rateOnlyReport, strings: ReportStrings(document: rateOnlyReport),
                                                           separator: .comma), separator: .comma).dropFirst())
        expect(!rateOnlyRows.isEmpty && rateOnlyRows.allSatisfy {
                   $0[csvAmount].isEmpty && $0[csvTimeAmount].isEmpty && $0[csvUsageAmount].isEmpty
               }, "no amounts in the CSV without the Amount column")
        expect(rateOnlyRows.contains { !$0[csvRate].isEmpty }, "rates stay with the Rate column")

        let italian = ReportStrings(language: .it, currency: "EUR", timezone: "Europe/Rome")
        let italianRows = parseCSV(ReportCSV.report(entryReport, strings: italian, separator: .semicolon),
                                   separator: .semicolon)
        expect(italianRows[0][csvAmount] == "Importo" && italianRows[0][csvTimeAmount] == "Importo tempo"
               && italianRows[0][csvUsageAmount] == "Importo utilizzo", "localized header")

        let raw = ReportCSV.raw(data, separator: .comma)
        let rawRows = parseCSV(raw, separator: .comma)
        expect(raw.hasPrefix("\u{FEFF}id,who,date,"), "raw CSV header")
        expect(rawRows.count == data.rows.count + 1 && rawRows.allSatisfy { $0.count == rawRows[0].count }, "raw rows")
        expect(rawRows.contains { $0[10] == "'=SUM(A1)" }, "formula guard in the raw CSV")
        expect(rawRows[4][20] == "1.234567" && rawRows[1][23] == "80.00", "raw money keeps its decimals")

        // Strings and formatting.
        let english = ReportStrings(language: .en)
        expect(english.formatHours(5_400_000, style: .decimal) == "1.50", "English decimal hours")
        expect(italian.formatHours(5_400_000, style: .decimal) == "1,50", "Italian decimal hours")
        expect(english.formatHours(5_400_000, style: .clock) == "1h 30m", "clock hours")
        expect(english.formatHours(65 * 60_000, style: .clock) == "1h 05m", "clock minutes are padded")
        expect(italian.formatTimeRange(start: 1_793_606_400_000, end: 1_793_611_800_000) == "09:00–10:30", "time range")
        expect(english.pageLabel(page: 2, count: 3) == "Page 2 of 3", "page label")
        expect(ReportNumber.plain(decimal("-1.5"), places: 2, decimalComma: true) == "-1,50", "plain numbers")
        expect(ReportNumber.plain(decimal("0.004"), places: 2, decimalComma: false) == "0.00", "plain rounding")
        for language in ReportLanguage.allCases {
            let text = ReportStrings(language: language)
            expect(!text.defaultTitle.isEmpty && !text.noTask.isEmpty && text.formatDay("2026-11-02").count > 6,
                   "strings for \(language)")
        }
        expect(ReportLanguage.preferred(["fr-CA", "en"]) == .fr && ReportLanguage.preferred(["ja"]) == .en,
               "preferred language")
        let sameTask = english.text(.entry(description: "CYB-12", project: "Platform", task: "CYB-12"))
        expect(sameTask.primary == "CYB-12" && sameTask.secondary == "Platform", "a task equal to the description is not repeated")
        let otherTask = english.text(.entry(description: "Fix login", project: "Platform", task: "CYB-12"))
        expect(otherTask.secondary == "Platform · CYB-12", "a different task stays under the description")
        expect(italian.sectionTotal(.work) == "Totale lavoro" && english.sectionTotal(.agents) == "Total AI agents",
               "section totals name their section")
        expect(italian.continued("lun 2 nov 2026") == "lun 2 nov 2026 (continua)", "continued group title")

        // The cap stays on one line and names no client in a single-client report.
        let cap = ReportSummaryItem.capAdjustment(client: "Acme", monthlyCap: decimal("400.00"), amount: decimal("-12.00"))
        expect(english.summaryLabel(cap, singleClient: true) == "Monthly cap on agents (€400.00)",
               "single-client cap label: \(english.summaryLabel(cap, singleClient: true))")
        expect(english.summaryLabel(cap) == "Monthly cap on agents (Acme, €400.00)", "cap label with the client")
        let capRows = parseCSV(ReportCSV.report(standard, strings: neutral, separator: .comma), separator: .comma)
        expect(capRows.contains { $0[5] == "Monthly cap on agents (€100.00)" && $0[csvAmount] == "-1.85" },
               "the CSV cap line names no client in a single-client report")

        // Compact tokens: three significant digits at every magnitude.
        expect(english.formatCompactTokens(3_961_234_567) == "3.96B", "billions: \(english.formatCompactTokens(3_961_234_567))")
        expect(english.formatCompactTokens(337_200_000) == "337M", "hundreds of millions")
        expect(english.formatCompactTokens(7_100_000) == "7.10M", "millions keep three digits")
        expect(english.formatCompactTokens(659_400) == "659K", "thousands")
        expect(english.formatCompactTokens(42) == "42", "small counts stay whole")
        let italianTokens = italian.formatCompactTokens(3_961_234_567)
        expect(italianTokens.hasPrefix("3,96"), "Italian billions keep their notation: \(italianTokens)")

        checkRanges()
        checkOptionsCoding()
        print("Report checks passed")
    }
}
