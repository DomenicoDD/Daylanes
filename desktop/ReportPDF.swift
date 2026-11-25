import AppKit
import CoreText
import Foundation

/// A print-friendly vector PDF of a report, drawn with Core Graphics and Core Text (selectable text).
/// It does not touch SwiftUI or any window, so it can run off the main thread.
///
/// Rendering runs in two passes: layout measures everything into positioned draw operations per page,
/// then drawing replays them and adds the footers, which need the page count.
enum ReportPDF {
    static func render(document: ReportDocument, strings: ReportStrings, paper: ReportPaper,
                       orientation: ReportOrientation) -> Data {
        let size = pageSize(paper: paper, orientation: orientation)
        var layout = Layout(document: document, strings: strings, size: size)
        layout.run()
        return draw(pages: layout.pages, document: document, strings: strings, size: size)
    }

    static func pageSize(paper: ReportPaper, orientation: ReportOrientation) -> CGSize {
        let portrait: CGSize
        switch paper {
        case .a4: portrait = CGSize(width: 595.28, height: 841.89)
        case .letter: portrait = CGSize(width: 612, height: 792)
        }
        switch orientation {
        case .portrait: return portrait
        case .landscape: return CGSize(width: portrait.height, height: portrait.width)
        }
    }

    // MARK: Text

    fileprivate struct Style {
        let font: CTFont
        let color: CGColor
        let ascent: CGFloat
        let descent: CGFloat
        let lineHeight: CGFloat

        init(size: CGFloat, weight: NSFont.Weight, gray: CGFloat, digits: Bool = false) {
            let nsFont: NSFont = digits
                ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                : NSFont.systemFont(ofSize: size, weight: weight)
            let ctFont = nsFont as CTFont
            font = ctFont
            color = CGColor(gray: gray, alpha: 1)
            ascent = CTFontGetAscent(ctFont)
            descent = CTFontGetDescent(ctFont)
            lineHeight = ceil((CTFontGetAscent(ctFont) + CTFontGetDescent(ctFont)) * 1.22)
        }

        func attributed(_ text: String) -> NSAttributedString {
            let attributes: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            ]
            return NSAttributedString(string: text, attributes: attributes)
        }

        func make(_ line: CTLine) -> TextLine {
            let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
            let baseline = (lineHeight - ascent - descent) / 2 + ascent
            return TextLine(line: line, width: width, height: lineHeight, baseline: baseline)
        }

        /// One unwrapped line.
        func line(_ text: String) -> TextLine {
            make(CTLineCreateWithAttributedString(attributed(text) as CFAttributedString))
        }

        func width(_ text: String) -> CGFloat {
            text.isEmpty ? 0 : line(text).width
        }

        /// Lines broken to fit `width`, keeping the text's own line breaks. Never truncates.
        func wrap(_ text: String, width: CGFloat) -> [TextLine] {
            if text.isEmpty { return [] }
            let string = attributed(text) as CFAttributedString
            let typesetter = CTTypesetterCreateWithAttributedString(string)
            let length = CFAttributedStringGetLength(string)
            var lines: [TextLine] = []
            var start = 0
            while start < length {
                var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(max(width, 4)))
                if count <= 0 { count = 1 }
                if start + count > length { count = length - start }
                lines.append(make(CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))))
                start += count
            }
            return lines
        }

        /// The widest word, the narrowest a wrapped column can get.
        func widestWord(_ text: String) -> CGFloat {
            var widest: CGFloat = 0
            for word in text.split(whereSeparator: { $0.isWhitespace }) {
                widest = max(widest, width(String(word)))
            }
            return widest
        }
    }

    fileprivate struct TextLine {
        let line: CTLine
        let width: CGFloat
        let height: CGFloat
        /// Distance from the top of the line box to the baseline.
        let baseline: CGFloat
    }

    // MARK: Layout model

    fileprivate enum Op {
        /// `baseline` is measured from the top of the page.
        case text(CTLine, x: CGFloat, baseline: CGFloat)
        case rule(x: CGFloat, y: CGFloat, width: CGFloat, thickness: CGFloat, gray: CGFloat)
        case band(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, gray: CGFloat)
    }

    fileprivate struct Rule {
        let gray: CGFloat
        let thickness: CGFloat
    }

    fileprivate struct Cell {
        var lines: [TextLine]
        var x: CGFloat
        var width: CGFloat
        var alignRight: Bool = false

        var height: CGFloat { lines.reduce(0) { $0 + $1.height } }
    }

    /// A block that never splits across pages: a table row, a header block, a summary line.
    fileprivate struct Row {
        var cells: [Cell]
        var x: CGFloat
        var width: CGFloat
        var padTop: CGFloat = 0
        var padBottom: CGFloat = 0
        var band: CGFloat? = nil
        var ruleAbove: Rule? = nil
        var ruleBelow: Rule? = nil

        var height: CGFloat { (cells.map { $0.height }.max() ?? 0) + padTop + padBottom }
    }

    fileprivate struct TableStyles {
        let body: Style
        let numeric: Style
        let secondary: Style
        let header: Style
        let bold: Style
        let boldNumeric: Style
        let group: Style
        let padding: CGFloat

        init(size: CGFloat) {
            body = Style(size: size, weight: .regular, gray: 0.1)
            numeric = Style(size: size, weight: .regular, gray: 0.1, digits: true)
            secondary = Style(size: size - 1, weight: .regular, gray: 0.45)
            header = Style(size: size - 0.5, weight: .medium, gray: 0.4)
            bold = Style(size: size, weight: .semibold, gray: 0.08)
            boldNumeric = Style(size: size, weight: .semibold, gray: 0.08, digits: true)
            group = Style(size: size + 0.5, weight: .semibold, gray: 0.08)
            padding = max(2.5, size * 0.4)
        }
    }

    fileprivate struct Table {
        let columns: [ReportColumn]
        let xs: [CGFloat]
        let widths: [CGFloat]
        let styles: TableStyles
        let descriptionWidth: CGFloat
    }

    // MARK: Layout

    fileprivate struct Layout {
        let document: ReportDocument
        let strings: ReportStrings
        let size: CGSize
        let margin: CGFloat
        /// Room kept at the bottom of every page for the footer.
        let footerSpace: CGFloat
        let gap: CGFloat
        var pages: [[Op]]
        var y: CGFloat
        /// Nothing but table headers on this page yet, so breaking again would not help.
        var fresh: Bool

        init(document: ReportDocument, strings: ReportStrings, size: CGSize) {
            self.document = document
            self.strings = strings
            self.size = size
            margin = 40
            footerSpace = 28
            gap = 10
            pages = [[]]
            y = 40
            fresh = true
        }

        var contentWidth: CGFloat { size.width - 2 * margin }
        var bottom: CGFloat { size.height - margin - footerSpace }

        mutating func add(_ op: Op) {
            pages[pages.count - 1].append(op)
        }

        mutating func newPage() {
            pages.append([])
            y = margin
            fresh = true
        }

        mutating func space(_ height: CGFloat) {
            y = min(y + height, bottom)
        }

        func fits(_ height: CGFloat) -> Bool {
            y + height <= bottom
        }

        mutating func emit(_ row: Row) {
            let top = y
            let height = row.height
            if let band = row.band {
                add(.band(x: row.x, y: top, width: row.width, height: height, gray: band))
            }
            if let rule = row.ruleAbove {
                add(.rule(x: row.x, y: top, width: row.width, thickness: rule.thickness, gray: rule.gray))
            }
            for cell in row.cells {
                var lineTop = top + row.padTop
                for line in cell.lines {
                    let x = cell.alignRight ? cell.x + cell.width - line.width : cell.x
                    add(.text(line.line, x: x, baseline: lineTop + line.baseline))
                    lineTop += line.height
                }
            }
            if let rule = row.ruleBelow {
                add(.rule(x: row.x, y: top + height, width: row.width, thickness: rule.thickness, gray: rule.gray))
            }
            y = top + height
        }

        /// Places a row on this page, or on a new one (repeating the table header) when it does not fit.
        /// `keepWith` is the height of what must follow on the same page, such as a group's first line.
        /// `continued` is emitted under the repeated header when the row starts a new page inside a group.
        mutating func place(_ row: Row, keepWith extra: CGFloat = 0, header: Row? = nil, continued: Row? = nil) {
            if !fits(row.height + extra) && !fresh {
                newPage()
                if let header { emit(header) }
                if let continued { emit(continued) }
            }
            emit(row)
            fresh = false
        }

        mutating func run() {
            header()
            summary()
            let sections = document.sections
            if sections.isEmpty && document.options.detail != .totals {
                let style = Style(size: 9.5, weight: .regular, gray: 0.45)
                place(Row(cells: [Cell(lines: style.wrap(strings.noEntries, width: contentWidth), x: margin,
                                       width: contentWidth)], x: margin, width: contentWidth))
            }
            for section in sections {
                self.section(section)
            }
        }

        // MARK: Header

        mutating func header() {
            let head = document.header
            let titleStyle = Style(size: 20, weight: .semibold, gray: 0.08)
            let periodStyle = Style(size: 11, weight: .regular, gray: 0.38)
            let smallStyle = Style(size: 7.5, weight: .regular, gray: 0.5)
            let labelStyle = Style(size: 7.5, weight: .medium, gray: 0.5)
            let bodyStyle = Style(size: 9.5, weight: .regular, gray: 0.1)
            let strongStyle = Style(size: 9.5, weight: .semibold, gray: 0.08)

            let generated = smallStyle.line(strings.generated(head.generatedAt))
            let titleWidth = max(contentWidth - generated.width - 24, contentWidth * 0.5)
            place(Row(cells: [
                Cell(lines: titleStyle.wrap(strings.title(head), width: titleWidth), x: margin, width: titleWidth),
                Cell(lines: [generated], x: margin, width: contentWidth, alignRight: true),
            ], x: margin, width: contentWidth))
            place(Row(cells: [Cell(lines: periodStyle.wrap(strings.formatPeriod(start: head.start, end: head.end),
                                                           width: contentWidth), x: margin, width: contentWidth)],
                      x: margin, width: contentWidth, padTop: 2))
            space(18)

            let half = (contentWidth - 24) / 2
            var fromLines: [TextLine] = []
            let fromText = head.from.trimmingCharacters(in: .whitespacesAndNewlines)
            let personName = head.personName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fromText.isEmpty || !personName.isEmpty {
                fromLines.append(labelStyle.line(strings.from))
                if !personName.isEmpty {
                    fromLines.append(contentsOf: strongStyle.wrap(personName, width: half))
                }
                if !fromText.isEmpty {
                    fromLines.append(contentsOf: bodyStyle.wrap(fromText, width: half))
                }
            }
            var clientLines: [TextLine] = []
            if let client = head.client, !client.isEmpty {
                clientLines.append(labelStyle.line(strings.client))
                clientLines.append(contentsOf: strongStyle.wrap(client, width: half))
                if let projects = head.projects, !projects.isEmpty {
                    let text = "\(strings.projects): \(projects.joined(separator: ", "))"
                    clientLines.append(contentsOf: smallStyle.wrap(text, width: half))
                }
            }
            if !fromLines.isEmpty || !clientLines.isEmpty {
                // Without a From block the client starts at the left margin instead of floating mid-page.
                let clientX = fromLines.isEmpty ? margin : margin + half + 24
                place(Row(cells: [
                    Cell(lines: fromLines, x: margin, width: half),
                    Cell(lines: clientLines, x: clientX, width: half),
                ], x: margin, width: contentWidth))
                space(12)
            }

            let reference = head.reference.trimmingCharacters(in: .whitespacesAndNewlines)
            let note = head.note.trimmingCharacters(in: .whitespacesAndNewlines)
            if !reference.isEmpty {
                place(Row(cells: [Cell(lines: [labelStyle.line(strings.reference)]
                                        + bodyStyle.wrap(reference, width: contentWidth),
                                       x: margin, width: contentWidth)], x: margin, width: contentWidth))
                space(8)
            }
            if !note.isEmpty {
                // A long note may run over several rows: place it paragraph by paragraph.
                place(Row(cells: [Cell(lines: [labelStyle.line(strings.note)], x: margin, width: contentWidth)],
                          x: margin, width: contentWidth), keepWith: bodyStyle.lineHeight)
                for paragraph in note.components(separatedBy: "\n") {
                    let lines = paragraph.isEmpty ? [bodyStyle.line(" ")] : bodyStyle.wrap(paragraph, width: contentWidth)
                    place(Row(cells: [Cell(lines: lines, x: margin, width: contentWidth)], x: margin, width: contentWidth))
                }
                space(8)
            }
            space(10)
        }

        // MARK: Summary

        mutating func summary() {
            let items = document.summary
            guard !items.isEmpty || !document.warnings.isEmpty else { return }
            let hoursFormat = document.options.hoursFormat
            let titleStyle = Style(size: 11.5, weight: .semibold, gray: 0.08)
            let labelStyle = Style(size: 9.5, weight: .regular, gray: 0.1)
            let valueStyle = Style(size: 9.5, weight: .regular, gray: 0.1, digits: true)
            let totalLabel = Style(size: 11, weight: .semibold, gray: 0.05)
            let totalValue = Style(size: 11, weight: .semibold, gray: 0.05, digits: true)
            let warningStyle = Style(size: 7.5, weight: .regular, gray: 0.42)

            let singleClient = document.header.client != nil
            var entries: [(label: String, hours: String, value: String, isTotal: Bool)] = []
            for item in items {
                let label = strings.summaryLabel(item, singleClient: singleClient)
                switch item {
                case .you(let millis, let amount), .agents(let millis, let amount):
                    let value = document.options.showsMoney ? (amount.map { strings.formatMoney($0) } ?? "—") : ""
                    // The hours the tables print, added up, so the summary agrees with them.
                    let shown: ReportShownHours?
                    if case .you = item {
                        shown = document.youHours
                    } else {
                        shown = document.agentHours
                    }
                    let hours: String = shown.map { strings.formatShownWithUnit($0, style: hoursFormat) }
                        ?? strings.formatHoursWithUnit(millis, style: hoursFormat)
                    entries.append((label, hours, value, false))
                case .tokens(let count):
                    entries.append((label, "", strings.formatTokens(count), false))
                case .aiCost(let usd):
                    entries.append((label, "", strings.formatUSD(usd), false))
                case .capAdjustment(_, _, let amount):
                    entries.append((label, "", strings.formatMoney(amount), false))
                case .expenses(let amount):
                    entries.append((label, "", strings.formatMoney(amount), false))
                case .total(let amount):
                    entries.append((label, "", strings.formatMoney(amount), true))
                }
            }

            var valueWidth: CGFloat = 0
            var hoursWidth: CGFloat = 0
            var labelNeed: CGFloat = 0
            for entry in entries {
                valueWidth = max(valueWidth, (entry.isTotal ? totalValue : valueStyle).width(entry.value))
                hoursWidth = max(hoursWidth, valueStyle.width(entry.hours))
                labelNeed = max(labelNeed, (entry.isTotal ? totalLabel : labelStyle).width(entry.label))
            }
            valueWidth = ceil(valueWidth)
            hoursWidth = ceil(hoursWidth)
            // Wide enough that every label (such as the monthly cap) stays on one line, within the page.
            let hoursSpace: CGFloat = hoursWidth > 0 ? 16 + hoursWidth : 0
            let fitted: CGFloat = ceil(labelNeed) + 14 + hoursSpace + valueWidth
            let width = min(contentWidth, max(300, valueWidth + hoursWidth + 200, fitted))
            let valueX = margin + width - valueWidth
            let hoursX = valueX - (hoursWidth > 0 ? 16 + hoursWidth : 0)
            let labelWidth = max(hoursX - margin - 12, 80)

            if !entries.isEmpty {
                let titleRow = Row(cells: [Cell(lines: [titleStyle.line(strings.summary)], x: margin, width: width)],
                                   x: margin, width: width, padBottom: 4)
                place(titleRow, keepWith: labelStyle.lineHeight + 8)
            }
            for entry in entries {
                let label = entry.isTotal ? totalLabel : labelStyle
                let value = entry.isTotal ? totalValue : valueStyle
                var row = Row(cells: [
                    Cell(lines: label.wrap(entry.label, width: labelWidth), x: margin, width: labelWidth),
                    Cell(lines: entry.hours.isEmpty ? [] : [valueStyle.line(entry.hours)], x: hoursX, width: hoursWidth,
                         alignRight: true),
                    Cell(lines: entry.value.isEmpty ? [] : [value.line(entry.value)], x: valueX, width: valueWidth,
                         alignRight: true),
                ], x: margin, width: width, padTop: entry.isTotal ? 6 : 3.5, padBottom: entry.isTotal ? 4 : 3.5)
                if entry.isTotal {
                    row.ruleAbove = Rule(gray: 0.25, thickness: 0.75)
                } else {
                    row.ruleBelow = Rule(gray: 0.88, thickness: 0.25)
                }
                place(row)
            }
            if !document.warnings.isEmpty {
                space(6)
                for warning in document.warnings {
                    let text = "• " + strings.warning(warning)
                    place(Row(cells: [Cell(lines: warningStyle.wrap(text, width: contentWidth), x: margin,
                                           width: contentWidth)], x: margin, width: contentWidth, padBottom: 1.5))
                }
            }
            space(24)
        }

        // MARK: Tables

        func cellText(_ line: ReportLine, _ column: ReportColumn) -> String {
            switch column {
            case .date:
                guard !line.isTotal, let date = line.date else { return "" }
                return strings.formatDate(date)
            case .timeRange:
                return line.isTotal ? "" : strings.formatTimeRange(start: line.startedAt, end: line.endedAt)
            case .description:
                return strings.singleLine(line.label)
            case .who:
                return line.isTotal ? "" : strings.whoText(line.who)
            case .model:
                return line.isTotal ? "" : line.models.joined(separator: ", ")
            case .tokens:
                return line.tokens > 0 ? strings.formatCompactTokens(line.tokens) : ""
            case .aiCost:
                return line.apiUsd.map { strings.formatUSD($0) } ?? ""
            case .hours:
                return strings.formatLineHours(line, style: document.options.hoursFormat)
            case .rate:
                return line.isTotal ? "" : (line.rate.map { strings.formatMoney($0) } ?? "")
            case .timeAmount:
                return line.timeAmount.map { strings.formatMoney($0) } ?? ""
            case .usageAmount:
                return line.usageAmount.map { strings.formatMoney($0) } ?? ""
            case .amount:
                return line.amount.map { strings.formatMoney($0) } ?? "—"
            }
        }

        func allLines(_ section: ReportSection) -> [ReportLine] {
            var lines: [ReportLine] = []
            for group in section.groups {
                lines.append(contentsOf: group.lines)
                if let subtotal = group.subtotal { lines.append(subtotal) }
            }
            lines.append(section.total)
            return lines
        }

        func table(_ section: ReportSection, size fontSize: CGFloat, textCap: CGFloat) -> Table {
            let styles = TableStyles(size: fontSize)
            let lines = allLines(section)
            var widths: [CGFloat] = []
            for column in section.columns {
                if column == .description {
                    widths.append(0)
                    continue
                }
                var widest: CGFloat = 0
                for line in lines {
                    let style: Style
                    if column.isNumeric {
                        style = line.isTotal ? styles.boldNumeric : styles.numeric
                    } else {
                        style = line.isTotal ? styles.bold : styles.body
                    }
                    widest = max(widest, style.width(cellText(line, column)))
                }
                if column == .who || column == .model {
                    widest = min(widest, textCap)
                }
                let title = strings.columnTitle(column)
                // Headers wrap onto two lines rather than widen a narrow numeric column.
                let headerWidth = styles.header.width(title)
                let headerFloor = headerWidth <= max(widest, 40) ? headerWidth : styles.header.widestWord(title)
                widths.append(ceil(max(widest, headerFloor, 24)))
            }
            // Unwrap the headers again when the description keeps plenty of room (landscape, few columns).
            var fullWidths = widths
            for (index, column) in section.columns.enumerated() where column != .description {
                fullWidths[index] = max(widths[index], ceil(styles.header.width(strings.columnTitle(column))))
            }
            let gaps = gap * CGFloat(max(section.columns.count - 1, 0))
            if contentWidth - fullWidths.reduce(0, +) - gaps >= max(260, contentWidth * 0.4) { widths = fullWidths }
            let fixed = widths.reduce(0, +) + gaps
            let descriptionWidth = contentWidth - fixed
            var xs: [CGFloat] = []
            var x = margin
            for (index, column) in section.columns.enumerated() {
                if column == .description { widths[index] = max(descriptionWidth, 60) }
                xs.append(x)
                x += widths[index] + gap
            }
            return Table(columns: section.columns, xs: xs, widths: widths, styles: styles,
                         descriptionWidth: descriptionWidth)
        }

        /// The largest font size at which the description column keeps a readable width.
        func chooseTable(_ section: ReportSection) -> Table {
            let wanted = min(170, contentWidth * 0.3)
            let sizes: [CGFloat] = [8.5, 8, 7.5, 7]
            var last: Table? = nil
            for size in sizes {
                let candidate = table(section, size: size, textCap: size >= 8 ? 120 : 90)
                if candidate.descriptionWidth >= wanted { return candidate }
                last = candidate
            }
            return last ?? table(section, size: 7, textCap: 90)
        }

        func headerRow(_ table: Table) -> Row {
            var cells: [Cell] = []
            for (index, column) in table.columns.enumerated() {
                let lines = table.styles.header.wrap(strings.columnTitle(column), width: table.widths[index])
                cells.append(Cell(lines: lines, x: table.xs[index], width: table.widths[index],
                                  alignRight: column.isNumeric))
            }
            let pad = table.styles.padding
            return Row(cells: cells, x: margin, width: contentWidth, padTop: pad, padBottom: pad, band: 0.955,
                       ruleBelow: Rule(gray: 0.75, thickness: 0.5))
        }

        func lineRow(_ line: ReportLine, table: Table, emphasis: Bool, title: String? = nil) -> Row {
            let styles = table.styles
            var cells: [Cell] = []
            for (index, column) in table.columns.enumerated() {
                let width = table.widths[index]
                let x = table.xs[index]
                if column == .description {
                    let parts = strings.text(line.label)
                    var lines = (emphasis ? styles.bold : styles.body).wrap(title ?? parts.primary, width: width)
                    if let secondary = parts.secondary, !line.isTotal {
                        lines.append(contentsOf: styles.secondary.wrap(secondary, width: width))
                    }
                    cells.append(Cell(lines: lines, x: x, width: width))
                    continue
                }
                let text = cellText(line, column)
                if text.isEmpty {
                    cells.append(Cell(lines: [], x: x, width: width, alignRight: column.isNumeric))
                    continue
                }
                let lines: [TextLine]
                if column.isNumeric {
                    lines = [(emphasis ? styles.boldNumeric : styles.numeric).line(text)]
                } else if column == .date || column == .timeRange {
                    lines = [(emphasis ? styles.bold : styles.body).line(text)]
                } else {
                    lines = (emphasis ? styles.bold : styles.body).wrap(text, width: width)
                }
                cells.append(Cell(lines: lines, x: x, width: width, alignRight: column.isNumeric))
            }
            let pad = styles.padding
            return Row(cells: cells, x: margin, width: contentWidth, padTop: pad, padBottom: pad)
        }

        func groupRow(_ title: ReportLabel, table: Table, continued: Bool = false) -> Row {
            let text = continued ? strings.continued(strings.singleLine(title)) : strings.singleLine(title)
            let lines = table.styles.group.wrap(text, width: contentWidth)
            return Row(cells: [Cell(lines: lines, x: margin, width: contentWidth)], x: margin, width: contentWidth,
                       padTop: 9, padBottom: 3, ruleBelow: Rule(gray: 0.82, thickness: 0.5))
        }

        mutating func section(_ section: ReportSection) {
            let table = chooseTable(section)
            let header = headerRow(table)
            let titleStyle = Style(size: 12.5, weight: .semibold, gray: 0.08)
            let title = Row(cells: [Cell(lines: titleStyle.wrap(strings.sectionTitle(section.kind), width: contentWidth),
                                         x: margin, width: contentWidth)],
                            x: margin, width: contentWidth, padBottom: 6)

            // Keep the title, the header, the first group title and the first line together.
            var opening = title.height + header.height
            if let first = section.groups.first {
                if let groupTitle = first.title { opening += groupRow(groupTitle, table: table).height }
                if let line = first.lines.first { opening += lineRow(line, table: table, emphasis: false).height }
            }
            if !fits(opening) && !fresh { newPage() }
            emit(title)
            emit(header)

            let lineRule = Rule(gray: 0.9, thickness: 0.25)
            for group in section.groups {
                let continued = group.title.map { groupRow($0, table: table, continued: true) }
                var subtotalRow: Row? = nil
                // With one group the section total right below says the same thing.
                if let subtotal = group.subtotal, section.groups.count > 1 {
                    var row = lineRow(subtotal, table: table, emphasis: true)
                    row.ruleAbove = Rule(gray: 0.55, thickness: 0.5)
                    row.padBottom += 4
                    subtotalRow = row
                }
                let rows: [Row] = group.lines.map { line in
                    var row = lineRow(line, table: table, emphasis: false)
                    row.ruleBelow = lineRule
                    return row
                }
                // The last line goes with the subtotal, so a subtotal never starts a page on its own.
                func keep(_ index: Int) -> CGFloat { index == rows.count - 1 ? (subtotalRow?.height ?? 0) : 0 }
                if let groupTitle = group.title {
                    // The title goes with what its first line keeps with, so it never ends a page alone.
                    let next = rows.first.map { $0.height + keep(0) } ?? (subtotalRow?.height ?? 0)
                    place(groupRow(groupTitle, table: table), keepWith: next, header: header)
                }
                for (index, row) in rows.enumerated() {
                    place(row, keepWith: keep(index), header: header, continued: continued)
                }
                if let subtotalRow { place(subtotalRow, header: header, continued: continued) }
            }
            // A bare "Total" only when this table's total is the document's: with a cap, expenses or separate
            // sections it would contradict the summary's total, so it names the section instead.
            let isDocumentTotal = document.sections.count == 1 && section.total.amount == document.grandTotal
            var total = lineRow(section.total, table: table, emphasis: true,
                                title: isDocumentTotal ? nil : strings.sectionTotal(section.kind))
            total.band = 0.955
            total.ruleAbove = Rule(gray: 0.3, thickness: 0.75)
            place(total, header: header)
            space(22)
        }
    }

    // MARK: Drawing

    private static func draw(pages: [[Op]], document: ReportDocument, strings: ReportStrings, size: CGSize) -> Data {
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData) else { return Data() }
        var mediaBox = CGRect(origin: .zero, size: size)
        let title = strings.title(document.header)
        let info: [String: Any] = [
            kCGPDFContextTitle as String: title,
            kCGPDFContextCreator as String: "Daylanes",
        ]
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, info as CFDictionary) else { return Data() }

        let margin: CGFloat = 40
        let footerStyle = Style(size: 7.5, weight: .regular, gray: 0.5)
        let reference = document.header.reference.trimmingCharacters(in: .whitespacesAndNewlines)
        let footerLeft = footerStyle.line(reference.isEmpty ? title : reference)
        let count = pages.count

        for (index, ops) in pages.enumerated() {
            context.beginPDFPage(nil)
            context.textMatrix = .identity
            for op in ops {
                switch op {
                case .text(let line, let x, let baseline):
                    context.textPosition = CGPoint(x: x, y: size.height - baseline)
                    CTLineDraw(line, context)
                case .rule(let x, let y, let width, let thickness, let gray):
                    context.setStrokeColor(gray: gray, alpha: 1)
                    context.setLineWidth(thickness)
                    context.move(to: CGPoint(x: x, y: size.height - y))
                    context.addLine(to: CGPoint(x: x + width, y: size.height - y))
                    context.strokePath()
                case .band(let x, let y, let width, let height, let gray):
                    context.setFillColor(gray: gray, alpha: 1)
                    context.fill(CGRect(x: x, y: size.height - y - height, width: width, height: height))
                }
            }

            // Footer: a hairline, the reference (or title) on the left, the page number on the right.
            let ruleY = margin + 14
            context.setStrokeColor(gray: 0.85, alpha: 1)
            context.setLineWidth(0.25)
            context.move(to: CGPoint(x: margin, y: ruleY))
            context.addLine(to: CGPoint(x: size.width - margin, y: ruleY))
            context.strokePath()
            let pageLine = footerStyle.line(strings.pageLabel(page: index + 1, count: count))
            let baselineY = margin + 2
            context.textPosition = CGPoint(x: margin, y: baselineY)
            CTLineDraw(footerLeft.line, context)
            context.textPosition = CGPoint(x: size.width - margin - pageLine.width, y: baselineY)
            CTLineDraw(pageLine.line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }
}
