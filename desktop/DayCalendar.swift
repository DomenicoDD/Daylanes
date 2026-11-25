import SwiftUI

/// One agent thread (a Codex, Claude Code or OpenCode session) with its runs for a day.
struct AgentThread: Decodable, Identifiable {
    struct Run: Decodable {
        let startedAt: Double
        let endedAt: Double
        let tokens: Int

        enum CodingKeys: String, CodingKey {
            case startedAt = "started_at", endedAt = "ended_at", tokens
        }
    }

    let id: String
    let provider: String
    let session: String?
    let project: String?
    let client: String?
    let folder: String?
    let branch: String?
    let runs: [Run]
    let tokens: Int
    let runtimeMillis: Double
    /// Column within the provider, so threads that overlap sit side by side.
    let lane: Int

    enum CodingKeys: String, CodingKey {
        case id, provider, session, project, client, folder, branch, runs, tokens, lane
        case runtimeMillis = "runtime_millis"
    }

    var title: String {
        let name = folder.map { URL(fileURLWithPath: $0).lastPathComponent } ?? providerName(provider)
        return [name, branch].compactMap { $0 }.joined(separator: " · ")
    }
}

/// What a day bills, per billable project: your time (projects may overlap) and agent time.
struct DayBilling: Decodable {
    let you: [BillingSpan]
    let ai: [BillingSpan]
}

struct BillingSpan: Decodable, Identifiable {
    let project: String
    let client: String?
    let startedAt: Double
    let endedAt: Double
    /// Exact billed time inside the block: gaps are left out, parallel agent threads add up.
    let billedMillis: Double
    let threads: Int?
    let agentMode: String?
    let amount: String?
    let lane: Int

    enum CodingKeys: String, CodingKey {
        case project, client, threads, amount, lane
        case startedAt = "started_at", endedAt = "ended_at", billedMillis = "billed_millis", agentMode = "agent_mode"
    }

    var id: String { "\(project)-\(startedAt)" }
}

/// A stable colour per project, so a project looks the same in every column and on every day.
enum ProjectColor {
    private static let palette: [Color] = [.blue, .teal, .orange, .purple, .pink, .green, .indigo, .brown, .mint, .cyan]

    /// Colours and icons chosen in the app, refreshed with every snapshot.
    /// Views that draw an icon or a chosen colour observe it, so they redraw when a choice changes.
    final class Choices: ObservableObject, @unchecked Sendable {
        private let lock = NSLock()
        private var colors: [String: Color] = [:]
        private var hex: [String: String] = [:]
        private var icons: [String: String] = [:]

        @MainActor func update(_ rows: [Appearance]) {
            var nextHex: [String: String] = [:]
            var nextIcons: [String: String] = [:]
            for row in rows {
                if row.scope == "project", let value = row.color, Color(hex: value) != nil { nextHex[row.name] = value }
                if row.scope == "client", let icon = row.icon { nextIcons[row.name] = icon }
            }
            lock.lock()
            let changed = nextHex != hex || nextIcons != icons
            if changed {
                hex = nextHex
                icons = nextIcons
                colors = nextHex.compactMapValues { Color(hex: $0) }
            }
            lock.unlock()
            if changed { objectWillChange.send() }
        }

        func color(_ project: String) -> Color? { lock.lock(); defer { lock.unlock() }; return colors[project] }
        func hex(_ project: String) -> String? { lock.lock(); defer { lock.unlock() }; return hex[project] }
        func icon(_ client: String) -> String? { lock.lock(); defer { lock.unlock() }; return icons[client] }
    }

    static let choices = Choices()

    static func color(for project: String?) -> Color {
        guard let project else { return .secondary }
        if let chosen = choices.color(project) { return chosen }
        return automatic(project)
    }

    /// Native pop-up menus apply the accent to template symbols. Supply an original-color icon.
    static func menuDot(for project: String) -> Image {
        let color = NSColor(Self.color(for: project))
        let dot = NSImage(size: NSSize(width: 12, height: 12), flipped: false) { bounds in
            color.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 2, dy: 2)).fill()
            return true
        }
        return Image(nsImage: dot).renderingMode(.original)
    }

    /// The colour a project gets when none is chosen: stable, from its name.
    static func automatic(_ name: String) -> Color {
        let seed = name.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        return palette[seed % palette.count]
    }
}

extension Color {
    init?(hex: String) {
        let digits = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: Double((value >> 16) & 0xff) / 255, green: Double((value >> 8) & 0xff) / 255,
                  blue: Double(value & 0xff) / 255)
    }

    /// "#RRGGBB" in sRGB, for saving a picked colour.
    var hexString: String? {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(rgb.redComponent), channel(rgb.greenComponent), channel(rgb.blueComponent))
    }
}

/// A client's icon: the image chosen for it, or its initials on a tinted square.
/// A project's coloured folder glyph for list rows; redraws when its colour is changed.
struct ProjectGlyph: View {
    let project: String
    var personal = false
    @ObservedObject var choices = ProjectColor.choices

    var body: some View {
        Image(systemName: personal ? "person.fill" : "folder.fill")
            .foregroundStyle(ProjectColor.color(for: project))
    }
}

struct ClientIcon: View {
    @ObservedObject var choices = ProjectColor.choices
    let client: String?
    var size: CGFloat = 16
    /// false draws the initial even when the client has an icon.
    var showsImage = true

    var body: some View {
        let radius = size * 0.22
        if showsImage, let client, let path = ProjectColor.choices.icon(client), let image = NSImage(contentsOfFile: path) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: radius))
                .accessibilityHidden(true)
        } else {
            let name = client ?? "?"
            let tint = ProjectColor.automatic(name)
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: size * 0.55, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: size, height: size)
                .background(tint.opacity(0.16), in: RoundedRectangle(cornerRadius: radius))
                .accessibilityHidden(true)
        }
    }
}

/// Toggl-style vertical day calendar: your time, imported Toggl time, and one column per
/// agent thread that was running at the same time.
struct DayCalendar: View {
    enum Source: String, CaseIterable {
        case you, codex, claude

        var title: String { self == .you ? "You" : providerName(rawValue) }
    }

    private struct Editing {
        let projects: [Project]
        let currency: String
        let saving: Bool
        let classify: ([FocusRow], [String]) -> Void
    }

    private enum Scope {
        case timeline(Editing)
        case preview(Source, query: String)
    }

    @EnvironmentObject private var recorder: FocusRecorder
    @State private var ruleSaveError: String?
    private let day: DayActivity
    private let isToday: Bool
    private let zone: TimeZone
    private let scope: Scope

    @EnvironmentObject private var inspector: Inspector

    init(day: DayActivity, projects: [Project], currency: String, isToday: Bool, zone: TimeZone,
         saving: Bool, classify: @escaping ([FocusRow], [String]) -> Void) {
        self.day = day
        self.isToday = isToday
        self.zone = zone
        scope = .timeline(Editing(projects: projects, currency: currency, saving: saving, classify: classify))
    }

    init(day: DayActivity, source: Source, query: String, zone: TimeZone) {
        self.day = day
        isToday = true
        self.zone = zone
        scope = .preview(source, query: query)
    }

    private let hourHeight: CGFloat = 48
    private var headerHeight: CGFloat { previewSource == nil ? 40 : 34 }
    private let axisWidth: CGFloat = 44
    private let visibleHeight: CGFloat = 576
    private let minimumBlock: CGFloat = 14

    private struct Item: Identifiable {
        enum Kind { case block(FocusRow), agent(AgentThread, AgentThread.Run), billing(BillingSpan, agents: Bool), session([FocusRow]) }
        let id: String
        let start: Double
        let end: Double
        let lane: Int
        let kind: Kind
    }

    /// One column per source. Agent threads that overlap share their provider's column as side-by-side tracks.
    private struct Column: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let lanes: Int
        var items: [Item]
    }

    private var threads: [AgentThread] { day.agentThreads ?? [] }
    private var previewSource: Source? {
        if case let .preview(source, _) = scope { return source }
        return nil
    }

    /// Activity shorter than this stays off the calendar: a quick glance or a short reply to an agent
    /// adds noise, and the agent work it starts is tracked in the agent's own column.
    static let minimumSeconds = 30.0
    /// Back-to-back activity for the same project, with gaps up to this long, is drawn as one block.
    static let sessionGap = 2.0 * 60 * 1000

    /// Groups consecutive blocks with the same assignment and ignored status
    /// into one calendar block, so a stretch of app switching reads as one piece of work.
    private func sessions(_ rows: [FocusRow]) -> [[FocusRow]] {
        var result: [[FocusRow]] = []
        for row in rows.sorted(by: { $0.startedAt < $1.startedAt }) {
            if let tail = result.last?.last, row.startedAt - tail.endedAt <= Self.sessionGap,
               tail.project == row.project, tail.client == row.client, tail.ignored == row.ignored {
                result[result.count - 1].append(row)
            } else {
                result.append([row])
            }
        }
        return result
    }

    private var columns: [Column] {
        if case let .preview(source, query) = scope {
            var column = source == .you ? humanColumn(includeImports: true)
                : agentColumn(source.rawValue, threads.filter { $0.provider == source.rawValue })
            if !query.isEmpty && !column.title.localizedCaseInsensitiveContains(query) {
                column.items = column.items.filter { matches($0, query: query) }
            }
            column.items.sort { ($0.start, $0.lane, $0.id) < ($1.start, $1.lane, $1.id) }
            return [column]
        }

        var result = [humanColumn(includeImports: false)]
        let toggl = togglBlocks
        if !toggl.isEmpty {
            result.append(Column(
                id: "toggl", title: "Toggl Track",
                subtitle: "\(duration(toggl.reduce(0.0) { $0 + $1.seconds })) imported", lanes: 1,
                items: toggl.map(importedItem)))
        }
        let providers = ["codex", "claude"] + Set(threads.map(\.provider)).subtracting(["codex", "claude"]).sorted()
        for provider in providers {
            let rows = threads.filter { $0.provider == provider }
            if !rows.isEmpty { result.append(agentColumn(provider, rows)) }
        }
        if case let .timeline(editing) = scope, let billing = day.billing {
            result.append(billingColumn(id: "billing-you", title: "Billing · you", spans: billing.you,
                                        agents: false, currency: editing.currency))
            if !billing.ai.isEmpty || !threads.isEmpty {
                result.append(billingColumn(id: "billing-ai", title: "Billing · AI", spans: billing.ai,
                                            agents: true, currency: editing.currency))
            }
        }
        return result
    }

    private var togglBlocks: [FocusRow] { day.blocks.filter { $0.timeSource == .toggl } }

    private func importedItem(_ row: FocusRow) -> Item {
        Item(id: row.id, start: row.startedAt, end: row.endedAt, lane: 0, kind: .block(row))
    }

    private func humanColumn(includeImports: Bool) -> Column {
        let automatic = day.blocks.filter { $0.timeSource == .automatic && $0.seconds >= Self.minimumSeconds }
        let assigned = day.completedAppTime.filter { $0.project != nil }.reduce(0.0) { $0 + $1.seconds }
        let review = day.unassignedAppSeconds
        var summary = assigned == 0 && review == 0 ? (recorder.enabled ? "No completed app time" : "Snoozed")
            : review > 0 ? "\(duration(assigned)) assigned · \(duration(review)) to assign" : "\(duration(assigned)) assigned"
        var items = sessions(automatic).filter { previewSource == nil || !$0[0].ignored }.map { rows in
            Item(id: rows[0].id, start: rows[0].startedAt, end: rows.map(\.endedAt).max() ?? rows[0].endedAt,
                 lane: 0, kind: rows.count == 1 ? .block(rows[0]) : .session(rows))
        }
        if includeImports, !togglBlocks.isEmpty {
            items += togglBlocks.map(importedItem)
            summary += " · \(duration(togglBlocks.reduce(0.0) { $0 + $1.seconds })) imported"
        }
        return Column(id: "you", title: "You", subtitle: summary, lanes: 1, items: items)
    }

    private func agentColumn(_ provider: String, _ rows: [AgentThread]) -> Column {
        let lanes = rows.map(\.lane).max() ?? 0
        let runtime = rows.reduce(0.0) { $0 + $1.runtimeMillis } / 1000
        let parallel = lanes > 0 ? " · up to \(lanes + 1) at once" : ""
        return Column(id: provider, title: providerName(provider),
                      subtitle: "\(rows.count) \(rows.count == 1 ? "thread" : "threads") · \(duration(runtime))\(parallel)",
                      lanes: lanes + 1, items: rows.flatMap { thread in
                          thread.runs.enumerated().map { index, run in
                              Item(id: "\(thread.id)-\(index)", start: run.startedAt, end: run.endedAt,
                                   lane: thread.lane, kind: .agent(thread, run))
                          }
                      })
    }

    private func matches(_ item: Item, query: String) -> Bool {
        let style = appearance(item)
        var terms = [style.title, style.subtitle]
        switch item.kind {
        case let .block(row): terms += [row.appName, row.assignmentLabel]
        case let .session(rows): terms += rows.flatMap { [$0.appName, $0.assignmentLabel] }
        case let .agent(thread, _): terms += [thread.client, thread.folder, thread.branch].compactMap { $0 }
        case .billing: break
        }
        return terms.contains { $0.localizedCaseInsensitiveContains(query) }
    }

    /// Billable time per project. Your projects can overlap (context switching bills each one),
    /// so overlapping blocks sit side by side like parallel agent threads.
    private func billingColumn(id: String, title: String, spans: [BillingSpan], agents: Bool, currency: String) -> Column {
        let seconds = spans.reduce(0.0) { $0 + $1.billedMillis } / 1000
        let amounts = spans.compactMap { Decimal(string: $0.amount ?? "", locale: Locale(identifier: "en_US_POSIX")) }
        let money: String? = amounts.isEmpty ? nil : amounts.reduce(0, +).formatted(.currency(code: currency))
        let subtitle = spans.isEmpty ? (agents ? "Agents not billed" : "Nothing billable")
            : [duration(seconds), money ?? "no rate set"].joined(separator: " · ")
        return Column(id: id, title: title, subtitle: subtitle, lanes: (spans.map(\.lane).max() ?? 0) + 1,
                      items: spans.map { Item(id: "\(id)-\($0.id)", start: $0.startedAt, end: $0.endedAt,
                                              lane: $0.lane, kind: .billing($0, agents: agents)) })
    }

    /// Hours shown: the working day, stretched to include everything recorded.
    private func hours(for columns: [Column]) -> ClosedRange<Int> {
        let items = columns.flatMap(\.items)
        var first = 8
        var last = 19
        if let start = items.map(\.start).min(), let end = items.map(\.end).max() {
            first = min(first, Int(floor(hourOffset(start))))
            last = max(last, Int(ceil(hourOffset(end))))
        }
        return max(0, first)...min(24, max(last, first + 1))
    }

    /// The hour to scroll to first: the current hour today, otherwise the first activity.
    private func anchorHour(in range: ClosedRange<Int>, for columns: [Column]) -> Int {
        // Night-time agent runs shouldn't pull the view away from the working day.
        let starts = columns.flatMap(\.items).map { hourOffset($0.start) }
        let daytime = starts.filter { $0 >= 7 }.min() ?? starts.min()
        if isToday {
            let now = Int(hourOffset(Date().timeIntervalSince1970 * 1000))
            let first = daytime.map { Int($0) } ?? now
            return max(range.lowerBound, min(first, now - 4) - 1)
        }
        if let daytime { return max(range.lowerBound, Int(daytime) - 1) }
        return max(range.lowerBound, 8)
    }

    /// An empty column stays narrow so the columns with activity get the room.
    private func maxWidth(_ column: Column) -> CGFloat {
        previewSource == nil && column.items.isEmpty ? 120 : .infinity
    }

    private struct Placement {
        let slot: Int
        let slots: Int
    }

    /// Places blocks side by side wherever they overlap on screen. Short blocks are drawn taller than
    /// they last, so overlap is measured on the drawn height. A block keeps its thread's lane when that
    /// lane is free, and a stretch with no overlap gets the full column width.
    private func placements(_ column: Column) -> [String: Placement] {
        let drawnMinimum = Double(minimumBlock + 2) / Double(hourHeight) * 3_600_000
        func drawnEnd(_ item: Item) -> Double { max(item.end, item.start + drawnMinimum) }
        var result: [String: Placement] = [:]
        var cluster: [(item: Item, lane: Int)] = []
        var laneEnds: [Int: Double] = [:]
        var clusterEnd = -Double.infinity
        func flush() {
            let lanes = Set(cluster.map(\.lane)).sorted()
            for entry in cluster {
                result[entry.item.id] = Placement(slot: lanes.firstIndex(of: entry.lane) ?? 0, slots: max(1, lanes.count))
            }
            cluster = []
            laneEnds = [:]
        }
        let sorted = column.items.sorted { ($0.start, $0.lane, $0.id) < ($1.start, $1.lane, $1.id) }
        for item in sorted {
            if !cluster.isEmpty && item.start >= clusterEnd { flush() }
            var lane = item.lane
            if let end = laneEnds[lane], end > item.start {
                lane = (0...).first { (laneEnds[$0] ?? -Double.infinity) <= item.start } ?? 0
            }
            laneEnds[lane] = drawnEnd(item)
            cluster.append((item, lane))
            clusterEnd = max(clusterEnd, drawnEnd(item))
        }
        flush()
        return result
    }

    var body: some View {
        let columns = columns
        Group {
            if case let .preview(_, query) = scope, columns.allSatisfy({ $0.items.isEmpty }) {
                Text(query.isEmpty ? "No activity here today." : "No matching activity.")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(20)
            } else {
                calendar(columns)
            }
        }
        .background(Theme.card)
        .alert("Couldn’t save tracking rule", isPresented: Binding(get: { ruleSaveError != nil },
                                                                 set: { if !$0 { ruleSaveError = nil } })) {
            Button("OK") { ruleSaveError = nil }
        } message: {
            Text(ruleSaveError ?? "")
        }
    }

    private func calendar(_ columns: [Column]) -> some View {
        let range = hours(for: columns)
        let height = CGFloat(range.count - 1) * hourHeight
        let firstHour = anchorHour(in: range, for: columns)
        // Scrolling to the first hour would put its blocks behind the pinned summary.
        let anchor = previewSource != nil && firstHour == range.lowerBound ? "calendar-top" : "hour-\(firstHour)"
        return ScrollViewReader { proxy in
            // The header is pinned inside the scroll view, so it shares the columns' width
            // whether or not a scrollbar takes room on the right.
            ScrollView(.vertical, showsIndicators: previewSource != nil) {
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    if previewSource != nil {
                        Color.clear.frame(height: 1).id("calendar-top").accessibilityHidden(true)
                    }
                    Section {
                        HStack(alignment: .top, spacing: 0) {
                            axis(range).frame(width: axisWidth)
                            ForEach(columns) { column in
                                track(column, range: range, height: height)
                                    .background(column.id.hasPrefix("billing") ? Theme.block.opacity(0.45) : Color.clear)
                                    .frame(minWidth: 0, maxWidth: maxWidth(column))
                                    .overlay(alignment: .leading) { Divider() }
                            }
                        }
                        .frame(height: height)
                    } header: {
                        HStack(spacing: 0) {
                            Color.clear.frame(width: axisWidth, height: headerHeight)
                            ForEach(columns) { column in
                                header(column)
                                    .frame(minWidth: 0, maxWidth: maxWidth(column))
                                    .overlay(alignment: .leading) { Divider() }
                            }
                        }
                        .background(Theme.card)
                        .overlay(alignment: .bottom) { Divider().overlay(Theme.hairline) }
                    }
                }
            }
            .frame(height: previewSource == nil ? min(height, visibleHeight) + headerHeight : nil)
            .onAppear { proxy.scrollTo(anchor, anchor: .top) }
            .onChange(of: day.id) { _, _ in proxy.scrollTo(anchor, anchor: .top) }
            .onChange(of: previewSource) { _, _ in proxy.scrollTo(anchor, anchor: .top) }
        }
    }

    private func header(_ column: Column) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            if previewSource == nil {
                Text(column.title).font(.callout.weight(.semibold)).foregroundStyle(column.id == "you" ? Theme.accent : Theme.text)
                    .lineLimit(1)
            }
            Text(column.subtitle).font(.caption).foregroundStyle(Theme.secondary)
                .lineLimit(previewSource == nil ? 1 : 2).truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: headerHeight, maxHeight: headerHeight, alignment: .leading)
        .help("\(column.title) · \(column.subtitle)")
        .accessibilityElement(children: .combine)
    }

    private func axis(_ range: ClosedRange<Int>) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            ForEach(Array(range.dropLast()), id: \.self) { hour in
                let isFirst = hour == range.lowerBound
                Text(isFirst && previewSource == nil ? "" : String(format: "%02d:00", hour))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .offset(y: isFirst && previewSource != nil ? 1 : -7)
                    .padding(.trailing, 6)
                    .frame(maxWidth: .infinity, minHeight: hourHeight, maxHeight: hourHeight, alignment: .topTrailing)
                    .id("hour-\(hour)")
            }
        }
        .accessibilityHidden(true)
    }

    private func track(_ column: Column, range: ClosedRange<Int>, height: CGFloat) -> some View {
        GeometryReader { proxy in
            let layout = placements(column)
            ZStack(alignment: .topLeading) {
                grid(range)
                if isToday, let now = nowOffset(range) {
                    Rectangle().fill(Theme.accent).frame(height: 1.5).offset(y: now)
                }
                ForEach(column.items) { item in
                    let place = layout[item.id] ?? Placement(slot: 0, slots: 1)
                    let width = proxy.size.width / CGFloat(place.slots)
                    block(item, range: range)
                        .frame(width: max(8, width - 4))
                        .offset(x: CGFloat(place.slot) * width + 2)
                }
            }
            .frame(width: proxy.size.width, height: height, alignment: .topLeading)
        }
        .frame(height: height)
        .clipped()
    }

    private func grid(_ range: ClosedRange<Int>) -> some View {
        Canvas { context, size in
            for index in 1..<max(1, range.count - 1) {
                let y = CGFloat(index) * hourHeight + 0.5
                var line = Path()
                line.move(to: CGPoint(x: 0, y: y))
                line.addLine(to: CGPoint(x: size.width, y: y))
                context.stroke(line, with: .color(.secondary.opacity(0.12)), lineWidth: 1)
            }
        }
        .accessibilityHidden(true)
    }

    private func block(_ item: Item, range: ClosedRange<Int>) -> some View {
        let top = (hourOffset(item.start) - Double(range.lowerBound)) * hourHeight
        let size = max(minimumBlock, (item.end - item.start) / 3_600_000 * hourHeight - 2)
        let style = appearance(item)
        return Group {
            if case let .timeline(editing) = scope {
                Button {
                    if inspector.id == item.id {
                        inspector.close()
                    } else {
                        inspector.show(id: item.id, title: style.title, AnyView(detail(item, editing: editing).environmentObject(recorder)))
                    }
                } label: {
                    blockLabel(style, size: size, selected: inspector.id == item.id)
                }
                .buttonStyle(.plain)
            } else {
                blockLabel(style, size: size, selected: false)
                    .accessibilityElement(children: .ignore)
            }
        }
        .frame(height: size)
        .offset(y: top + 1)
        .help("\(style.title) · \(style.subtitle) · \(timeText(item.start))–\(timeText(item.end))")
        .accessibilityLabel("\(style.title), \(style.subtitle), \(timeText(item.start)) to \(timeText(item.end))")
    }

    private func blockLabel(_ style: Appearance, size: CGFloat, selected: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 5) {
                Circle().fill(style.tint).frame(width: 6, height: 6).accessibilityHidden(true)
                Text(style.title).font(size >= 20 ? .caption.weight(.semibold) : .caption2.weight(.semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1).truncationMode(.tail)
            }
            if size >= 32 {
                Text(style.subtitle).font(.caption2).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.tail)
                    .padding(.leading, 11)
            }
        }
        .padding(.leading, 7)
        .padding(.trailing, 4)
        .padding(.vertical, size >= 20 ? 4 : 0)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(style.fill, in: RoundedRectangle(cornerRadius: Theme.blockRadius, style: .continuous))
        .overlay {
            if style.dashed {
                RoundedRectangle(cornerRadius: Theme.blockRadius, style: .continuous)
                    .strokeBorder(Theme.secondary.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            if selected {
                RoundedRectangle(cornerRadius: Theme.blockRadius, style: .continuous)
                    .strokeBorder(Theme.accent, lineWidth: 2)
            }
        }
        .contentShape(Rectangle())
    }

    /// What the inspector panel shows for a block: an editor for your own time, details for everything else.
    @ViewBuilder
    private func detail(_ item: Item, editing: Editing) -> some View {
            switch item.kind {
            case let .block(row) where row.timeSource == .automatic:
                BlockEditor(block: row, projects: editing.projects, range: rangeText(item), saving: editing.saving) { arguments, rule in
                    inspector.close()
                    editing.classify([row], arguments)
                    if let rule {
                        Task {
                            do { try await recorder.applyRuleChange(rule) }
                            catch { ruleSaveError = error.localizedDescription }
                        }
                    }
                }
            case let .session(rows):
                SessionEditor(rows: rows, projects: editing.projects, range: rangeText(item), saving: editing.saving) { arguments in
                    inspector.close()
                    editing.classify(rows.filter(\.closed), arguments)
                }
            case let .block(row):
                details(title: row.project ?? "Toggl Track", lines: [rangeText(item), "Imported from Toggl Track",
                                                                       "Re-import from Settings → Integrations to change it."])
            case let .billing(span, agents):
                details(title: span.project, lines: [
                    rangeText(item),
                    [span.client, agents ? "Agent time" : "Your time"].compactMap { $0 }.joined(separator: " · "),
                    "\(duration(span.billedMillis / 1000)) billed"
                        + (span.amount.map { " · \(costText($0, currency: editing.currency))" } ?? " · no rate set"),
                    agents ? "\(span.threads ?? 1) \(span.threads == 1 ? "thread" : "threads") · parallel threads each bill their running time"
                        : "Overlaps with other projects bill each project; overlaps within this project count once",
                    span.agentMode == "usage" ? "Billed by usage: see Overview for the API-credit amount" : "",
                    "Set rates on the client or project.",
                ].filter { !$0.isEmpty })
            case let .agent(thread, run):
                details(title: thread.title, lines: [
                    rangeText(item),
                    [providerName(thread.provider), thread.client, thread.project ?? "Unassigned"].compactMap { $0 }.joined(separator: " · "),
                    "\(tokensText(run.tokens)) tokens in this run · \(tokensText(thread.tokens)) in the thread today",
                    thread.folder ?? "",
                ].filter { !$0.isEmpty })
            }
    }

    private struct Appearance {
        let title: String
        let subtitle: String
        let tint: Color
        let fill: Color
        let dashed: Bool
    }

    private func appearance(_ item: Item) -> Appearance {
        switch item.kind {
        case let .block(row) where row.timeSource == .toggl:
            let tint = ProjectColor.color(for: row.project)
            return Appearance(title: row.project ?? "Toggl entry", subtitle: "Toggl · imported",
                              tint: tint.opacity(0.7), fill: tint.opacity(0.1), dashed: false)
        case let .block(row):
            if row.ignored {
                return Appearance(title: row.appName, subtitle: "Ignored", tint: .secondary.opacity(0.4),
                                  fill: Theme.block.opacity(0.5), dashed: false)
            }
            guard let project = row.project else {
                let title = [row.client, row.appName].compactMap { $0 }.joined(separator: " · ")
                return Appearance(title: title, subtitle: row.closed ? "Needs a project" : "In progress",
                                  tint: .secondary.opacity(0.5), fill: Theme.card, dashed: true)
            }
            let tint = ProjectColor.color(for: project)
            let source = row.githubPr.map { "PR #\($0)" } ?? row.keyword.map { "rule “\($0)”" }
            return Appearance(title: row.appName, subtitle: [project, source].compactMap { $0 }.joined(separator: " · "),
                              tint: tint, fill: Theme.block, dashed: false)
        case let .session(rows):
            let apps = SessionEditor.apps(rows)
            // The count leads, so it survives truncation in a narrow column.
            let title = apps.count > 1 ? "\(apps.count) apps · \(apps[0].name)" : apps.first?.name ?? "Activity"
            let first = rows[0]
            if first.ignored {
                return Appearance(title: title, subtitle: "Ignored", tint: .secondary.opacity(0.4),
                                  fill: Theme.block.opacity(0.5), dashed: false)
            }
            guard let project = first.project else {
                return Appearance(title: [first.client, title].compactMap { $0 }.joined(separator: " · "),
                                  subtitle: "Needs a project", tint: .secondary.opacity(0.5),
                                  fill: Theme.card, dashed: true)
            }
            let tint = ProjectColor.color(for: project)
            return Appearance(title: title, subtitle: project, tint: tint, fill: Theme.block, dashed: false)
        case let .billing(span, _):
            let tint = ProjectColor.color(for: span.project)
            let money: String? = if case let .timeline(editing) = scope {
                span.amount.map { costText($0, currency: editing.currency) }
            } else { nil }
            return Appearance(title: span.project,
                              subtitle: [duration(span.billedMillis / 1000), money].compactMap { $0 }.joined(separator: " · "),
                              tint: tint, fill: tint.opacity(0.14), dashed: span.amount == nil)
        case let .agent(thread, run):
            let tint = ProjectColor.color(for: thread.project)
            return Appearance(title: thread.title,
                              subtitle: [thread.project ?? "Unassigned", "\(tokensText(run.tokens)) tokens"].joined(separator: " · "),
                              tint: tint.opacity(thread.project == nil ? 0.5 : 1),
                              fill: thread.project == nil ? Theme.card : Theme.block,
                              dashed: thread.project == nil)
        }
    }

    private func details(title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            ForEach(lines, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func hourOffset(_ milliseconds: Double) -> Double {
        if milliseconds >= day.dayEnd { return 24 }
        return max(0, (milliseconds - day.dayStart) / 3_600_000)
    }

    private func nowOffset(_ range: ClosedRange<Int>) -> CGFloat? {
        let hour = hourOffset(Date().timeIntervalSince1970 * 1000)
        guard hour >= Double(range.lowerBound), hour <= Double(range.upperBound) else { return nil }
        return (hour - Double(range.lowerBound)) * hourHeight
    }

    private func rangeText(_ item: Item) -> String {
        "\(timeText(item.start))–\(timeText(item.end)) · \(duration((item.end - item.start) / 1000))"
    }

    private func timeText(_ milliseconds: Double) -> String {
        var format = Date.FormatStyle(date: .omitted, time: .shortened)
        format.timeZone = zone
        return Date(timeIntervalSince1970: milliseconds / 1000).formatted(format)
    }

    private func duration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded(.down))) s" }
        return hoursText(String(seconds / 3600))
    }
}

/// Popover for one auto-tracked block: pick a project, optionally route the app there from now on.
private struct BlockEditor: View {
    let block: FocusRow
    let projects: [Project]
    let range: String
    let saving: Bool
    /// Classification arguments, plus rule arguments when the person asked to remember the choice.
    let save: ([String], [String]?) -> Void

    @State private var project: String
    @State private var remember = false

    init(block: FocusRow, projects: [Project], range: String, saving: Bool,
         save: @escaping ([String], [String]?) -> Void) {
        self.block = block
        self.projects = projects
        self.range = range
        self.saving = saving
        self.save = save
        _project = State(initialValue: block.project ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(block.appName).font(.headline)
                Text(range).font(.callout).foregroundStyle(.secondary)
                if let client = block.client {
                    Text(client).font(.callout).foregroundStyle(.secondary)
                }
                if let keyword = block.keyword {
                    Text("Matched rule “\(keyword)”").font(.caption).foregroundStyle(.secondary)
                }
                if let repo = block.githubRepo {
                    let path = block.githubPr.map { "\(repo)/pull/\($0)" } ?? repo
                    if let url = URL(string: "https://github.com/" + path) {
                        Link(block.githubPr.map { "\(repo)#\($0)" } ?? repo, destination: url).font(.caption)
                    }
                }
            }
            if !block.closed {
                Text("This block is still recording. You can assign it once it closes.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                Picker("Project", selection: $project) {
                    Text("No project").tag("")
                    ForEach(projects) { item in
                        Label {
                            Text(item.name)
                        } icon: {
                            ProjectColor.menuDot(for: item.name)
                        }
                        .tag(item.name)
                    }
                }
                Toggle("Always send \(block.appName) here", isOn: $remember)
                    .disabled(project.isEmpty)
                    .help("Creates an app rule, so future \(block.appName) time goes to this project automatically.")
                HStack {
                    Button(block.ignored ? "Restore entry" : "Ignore entry") {
                        save([block.ignored ? "--unassign" : "--ignore"], nil)
                    }
                    Spacer()
                    Button("Save") {
                        let arguments = project.isEmpty ? ["--unassign"] : ["--project=\(project)"]
                        let rule = remember && !project.isEmpty
                            ? ["save-rule", "--field=app", "--keyword=\(block.appName)", "--project=\(project)"]
                                + (block.appID.map { ["--app-id=\($0)"] } ?? [])
                            : nil
                        save(arguments, rule)
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(project == (block.project ?? "") && !remember)
                }
                .disabled(saving)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Popover for a stretch of back-to-back activity: shows the apps in it and assigns them all at once.
private struct SessionEditor: View {
    let rows: [FocusRow]
    let projects: [Project]
    let range: String
    let saving: Bool
    let save: ([String]) -> Void

    @State private var project: String

    init(rows: [FocusRow], projects: [Project], range: String, saving: Bool, save: @escaping ([String]) -> Void) {
        self.rows = rows
        self.projects = projects
        self.range = range
        self.saving = saving
        self.save = save
        _project = State(initialValue: rows.first?.project ?? "")
    }

    /// Apps in the stretch, longest first.
    static func apps(_ rows: [FocusRow]) -> [(name: String, seconds: Double)] {
        Dictionary(grouping: rows, by: \.appName)
            .map { (name: $0.key, seconds: $0.value.reduce(0.0) { $0 + $1.seconds }) }
            .sorted { $0.seconds > $1.seconds }
    }

    var body: some View {
        let apps = Self.apps(rows)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(apps.count == 1 ? apps[0].name : "\(apps.count) apps").font(.headline)
                Text(range).font(.callout).foregroundStyle(.secondary)
                if let client = rows[0].client {
                    Text(client).font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(apps.prefix(6), id: \.name) { app in
                    HStack {
                        Text(app.name).lineLimit(1)
                        Spacer()
                        Text(hoursText(String(app.seconds / 3600))).foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.callout)
                }
                if apps.count > 6 {
                    Text("and \(apps.count - 6) more").font(.caption).foregroundStyle(.secondary)
                }
                let span = ((rows.map(\.endedAt).max() ?? 0) - rows[0].startedAt) / 1000
                let other = span - apps.reduce(0.0) { $0 + $1.seconds }
                if other >= 60 {
                    Text("\(hoursText(String(other / 3600))) in gaps and switches under 30 s")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Picker("Project for this block", selection: $project) {
                Text("No project").tag("")
                ForEach(projects) { item in
                    Label {
                        Text(item.name)
                    } icon: {
                        ProjectColor.menuDot(for: item.name)
                    }
                    .tag(item.name)
                }
            }
            HStack {
                Button(rows[0].ignored ? "Restore entries" : "Ignore entries") {
                    save([rows[0].ignored ? "--unassign" : "--ignore"])
                }
                Spacer()
                Button("Save") { save(project.isEmpty ? ["--unassign"] : ["--project=\(project)"]) }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(project == (rows[0].project ?? ""))
            }
            .disabled(saving)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
