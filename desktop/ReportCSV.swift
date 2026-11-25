import Foundation

/// CSV exports of a report: UTF-8 with a byte order mark, CRLF line ends, quoted where needed.
enum ReportCSV {
    static let byteOrderMark = "\u{FEFF}"
    static let lineEnd = "\r\n"

    /// One row per table line of the report, then the cap adjustments and the expenses, so the amount
    /// column adds up to the report total. The columns are the same whichever optional columns are on;
    /// values of columns that are off stay empty.
    static func report(_ document: ReportDocument, strings: ReportStrings, separator: ReportCSVSeparator) -> String {
        let options = document.options
        let decimalComma = separator.usesDecimalComma
        let money = options.showsMoney
        // A money column that is off stays empty, so the CSV never discloses what the PDF leaves out.
        let showRate: Bool = options.columns.contains(.rate)
        let showAmount: Bool = options.columns.contains(.amount)
        let currency = money ? document.header.currency : ""

        func number(_ value: Decimal?, places: Int = 2) -> String {
            guard let value else { return "" }
            return ReportNumber.plain(value, places: places, decimalComma: decimalComma)
        }

        /// The builder's reconciled hours, so the CSV adds up like the PDF; empty for a line with no time.
        func hours(_ value: Decimal?) -> String {
            options.columns.contains(.hours) ? number(value) : ""
        }

        var rows: [[String]] = [[
            strings.columnSection, strings.columnGroup, strings.columnDate, strings.columnStart, strings.columnEnd,
            strings.columnDescription, strings.columnWho, strings.columnHours, strings.columnRate,
            strings.csvTimeAmount, strings.csvUsageAmount, strings.columnAmount, strings.columnCurrency, strings.columnTokens, strings.columnAPIValue,
            strings.columnModels,
        ]]

        func lineRow(_ line: ReportLine, section: ReportSectionKind, group: ReportLabel?) -> [String] {
            let isExpense = section == .expenses
            // Expenses carry a single moment (start == end), never a time range.
            let timed = options.columns.contains(.timeRange) && !isExpense
            let groupText: String = group.map { strings.singleLine($0) } ?? ""
            var start = ""
            var end = ""
            if timed {
                if let value = line.startedAt { start = strings.formatTime(value) }
                if let value = line.endedAt { end = strings.formatTime(value) }
            }
            let who: String = isExpense ? "" : spreadsheetText(strings.whoText(line.who))
            let lineHours: String = isExpense ? "" : hours(line.displayHours)
            let rate: String = showRate && !isExpense ? number(line.rate) : ""
            let timeAmount: String = showAmount && !isExpense ? number(line.timeAmount) : ""
            let usageAmount: String = showAmount && !isExpense ? number(line.usageAmount) : ""
            let amount: String = showAmount ? number(line.amount) : ""
            let tokens: String = options.columns.contains(.tokens) && line.tokens > 0 ? String(line.tokens) : ""
            let apiValue: String = options.columns.contains(.aiCost) ? number(line.apiUsd) : ""
            let models: String = options.columns.contains(.model)
                ? spreadsheetText(line.models.joined(separator: ", ")) : ""
            var fields: [String] = []
            fields.append(spreadsheetText(strings.sectionTitle(section)))
            fields.append(spreadsheetText(groupText))
            fields.append(line.date ?? "")
            fields.append(start)
            fields.append(end)
            fields.append(spreadsheetText(strings.singleLine(line.label)))
            fields.append(who)
            fields.append(lineHours)
            fields.append(rate)
            fields.append(timeAmount)
            fields.append(usageAmount)
            fields.append(amount)
            fields.append(currency)
            fields.append(tokens)
            fields.append(apiValue)
            fields.append(models)
            return fields
        }

        func summaryRow(section: String, group: String, description: String, who: String = "",
                        shown: ReportShownHours?, amount: Decimal?) -> [String] {
            let summaryHours: String = shown.map { hours($0.hours) } ?? ""
            let summaryAmount: String = showAmount ? number(amount) : ""
            return [
                spreadsheetText(section), spreadsheetText(group), "", "", "", spreadsheetText(description),
                spreadsheetText(who), summaryHours, "", "", "", summaryAmount, currency, "", "", "",
            ]
        }

        let workSections = document.sections.filter { $0.kind != .expenses }
        let expenseSections = document.sections.filter { $0.kind == .expenses }
        for section in workSections {
            for group in section.groups {
                for line in group.lines {
                    rows.append(lineRow(line, section: section.kind, group: group.title))
                }
            }
        }
        if document.sections.isEmpty {
            // Totals only: the summary's work lines stand in for the table.
            for item in document.summary {
                switch item {
                case .you(_, let amount):
                    rows.append(summaryRow(section: strings.sectionYou, group: "", description: strings.sectionYou,
                                           who: strings.person, shown: document.youHours, amount: amount))
                case .agents(_, let amount):
                    rows.append(summaryRow(section: strings.sectionAgents, group: "", description: strings.sectionAgents,
                                           who: strings.agents, shown: document.agentHours, amount: amount))
                default:
                    break
                }
            }
        }
        for item in document.summary {
            if case .capAdjustment(let client, let cap, let amount) = item {
                let singleClient = document.header.client != nil
                rows.append(summaryRow(section: strings.monthlyCap, group: client,
                                       description: strings.capLabel(client: singleClient ? "" : client, monthlyCap: cap),
                                       shown: nil, amount: amount))
            }
        }
        if expenseSections.isEmpty {
            for item in document.summary {
                if case .expenses(let amount) = item {
                    rows.append(summaryRow(section: strings.sectionExpenses, group: "", description: strings.sectionExpenses,
                                           shown: nil, amount: amount))
                }
            }
        }
        for section in expenseSections {
            for group in section.groups {
                for line in group.lines {
                    rows.append(lineRow(line, section: section.kind, group: group.title))
                }
            }
        }
        return encode(rows, separator: separator)
    }

    /// Every engine row with every field, English snake_case headers.
    static func raw(_ data: ReportData, separator: ReportCSVSeparator) -> String {
        let decimalComma = separator.usesDecimalComma
        func number(_ value: Decimal?, places: Int) -> String {
            guard let value else { return "" }
            return ReportNumber.plain(value, places: places, decimalComma: decimalComma)
        }
        func optionalInt(_ value: Int?) -> String {
            value.map { String($0) } ?? ""
        }
        func text(_ value: String?) -> String {
            spreadsheetText(value ?? "")
        }

        var rows: [[String]] = [[
            "id", "who", "date", "started_at", "ended_at", "client", "project", "project_kind", "task", "tags",
            "description", "provider", "models", "thread", "millis", "billed_millis", "input_tokens",
            "cached_tokens", "cache_write_tokens", "output_tokens", "api_usd", "tokens_without_api_price",
            "agent_mode", "rate", "time_amount", "usage_amount", "amount", "reimbursable", "currency",
        ]]
        for row in data.rows {
            let fields: [String] = [
                text(row.id), text(row.who), row.date, optionalInt(row.startedAt), optionalInt(row.endedAt),
                text(row.client), text(row.project), text(row.projectKind), text(row.task),
                text(row.tags.joined(separator: ", ")), text(row.description), text(row.provider),
                text(row.models.joined(separator: ", ")), text(row.thread), String(row.millis),
                String(row.billedMillis), String(row.tokens.input), String(row.tokens.cached),
                String(row.tokens.cacheWrite), String(row.tokens.output), number(row.apiUsd, places: 6),
                String(row.tokensWithoutApiPrice), text(row.agentMode), number(row.rate, places: 2),
                number(row.timeAmount, places: 2), number(row.usageAmount, places: 2), number(row.amount, places: 2),
                row.reimbursable ? "true" : "false", data.currency,
            ]
            rows.append(fields)
        }
        return encode(rows, separator: separator)
    }

    static func encode(_ rows: [[String]], separator: ReportCSVSeparator) -> String {
        let mark = separator.character
        let lines: [String] = rows.map { row in
            row.map { quoted($0, separator: mark) }.joined(separator: mark)
        }
        return byteOrderMark + lines.joined(separator: lineEnd) + lineEnd
    }

    /// Quotes a field that holds the separator, a quote or a line break, doubling its quotes.
    static func quoted(_ field: String, separator: String) -> String {
        let needsQuotes = field.contains(separator) || field.unicodeScalars.contains { scalar in
            scalar == "\"" || scalar == "\n" || scalar == "\r"
        }
        guard needsQuotes else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Keeps spreadsheets from running text as a formula, like the engine's CSV export.
    static func spreadsheetText(_ text: String) -> String {
        if let first = text.unicodeScalars.first, first == "\t" || first == "\r" || first == "\n" {
            return "'" + text
        }
        let start = text.drop(while: { $0.isWhitespace })
        if let first = start.first, "=+-@".contains(first) {
            return "'" + text
        }
        return text
    }
}
