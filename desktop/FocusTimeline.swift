#if TRACKER_PAYMENTS
import Combine
#endif
import SwiftUI

@MainActor
final class TrackerLifecycle: NSObject, NSApplicationDelegate {
    let recorder = FocusRecorder()
    let ledger = LedgerModel()
    #if TRACKER_GOOGLE_CALENDAR
    let googleCalendar = GoogleCalendarConnection(ledger: Values.resolvedPath(Values.databasePath()))
    #endif
    #if TRACKER_PAYMENTS
    private var licenceChanges: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Tracking keeps running behind the lock. The recorder normally starts with the dashboard, which
        // a locked copy never builds, so start it here (prepare does nothing once it is running).
        // objectWillChange fires before the change, so read the status on the next main-loop turn.
        licenceChanges = Licensing.shared.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] in
                guard let self, Licensing.shared.isLocked else { return }
                Task { await self.recorder.prepare() }
            }
        Task { await Licensing.shared.start() }
    }
    #endif

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await recorder.finish()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

enum TimeSource: String, Decodable, CaseIterable {
    case automatic, toggl

    var label: String {
        switch self {
        case .automatic: "Auto-tracked"
        case .toggl: "Toggl Track"
        }
    }

    var icon: String {
        switch self {
        case .automatic: "app"
        case .toggl: "arrow.down.circle"
        }
    }

    var calendarLabel: String { self == .toggl ? "\(label) · Imported" : label }
    var calendarTint: Color { self == .toggl ? .teal : .accentColor }
}

struct FocusRow: Decodable, Identifiable {
    let id: String
    let appID: String?
    let recordedAppName: String
    let startedAt: Double
    let endedAt: Double
    let closed: Bool
    let project: String?
    let client: String?
    let ignored: Bool
    let keyword: String?
    let tag: String?
    let githubRepo: String?
    let githubPr: Int?
    let timeSource: TimeSource

    enum CodingKeys: String, CodingKey {
        case id, appID = "app_id", recordedAppName = "app_name", startedAt = "started_at", endedAt = "ended_at"
        case closed, project, client, ignored, keyword, tag
        case githubRepo = "github_repo", githubPr = "github_pr"
        case timeSource = "time_source"
    }

    var appName: String { ForegroundApp.displayName(recordedAppName, bundleID: appID) }
    var start: Date { Date(timeIntervalSince1970: startedAt / 1000) }
    var end: Date { Date(timeIntervalSince1970: endedAt / 1000) }
    var seconds: Double { (endedAt - startedAt) / 1000 }
    var assignmentLabel: String {
        project ?? client.map { "\($0) · Project unassigned" } ?? "Unassigned"
    }
    var tint: Color {
        if timeSource == .toggl { return .teal }
        if ignored { return .secondary }
        return project.map { ProjectColor.color(for: $0) } ?? .orange
    }
}

struct DayActivity: Decodable, Identifiable {
    let day: String
    let dayStart: Double
    let dayEnd: Double
    let blocks: [FocusRow]
    let agents: [DayAgent]
    let agentThreads: [AgentThread]?
    let billing: DayBilling?
    let loggedHumanMillis: Double?

    enum CodingKeys: String, CodingKey {
        case day, dayStart = "day_start", dayEnd = "day_end", blocks, agents, billing
        case agentThreads = "agent_threads"
        case loggedHumanMillis = "logged_human_millis"
    }

    var id: String { day }
    var date: Date { Date(timeIntervalSince1970: dayStart / 1000) }
    var completedAppTime: [FocusRow] { blocks.filter { $0.timeSource == .automatic && $0.closed && !$0.ignored } }
    var unassignedAppSeconds: Double {
        completedAppTime.filter { $0.project == nil }.reduce(0) { $0 + $1.seconds }
    }
}

struct DayAgent: Decodable, Identifiable {
    let provider: String
    let project: String?
    let folder: String?
    let client: String?
    let tokens: Int
    let runtimeMillis: Double?
    let runtimeMethod: String?

    var id: [String?] { [provider, project, folder] }

    enum CodingKeys: String, CodingKey {
        case provider, project, folder, client, tokens
        case runtimeMillis = "runtime_millis", runtimeMethod = "runtime_method"
    }

    var destination: String {
        [client, project ?? folder.map { URL(fileURLWithPath: $0).lastPathComponent }]
            .compactMap { $0 }.joined(separator: " / ")
    }
}

private enum FocusFilter: String, CaseIterable, Identifiable {
    case tracked = "Tracked"
    case unassigned = "To review"
    case assigned = "Assigned"
    case ignored = "Ignored"
    var id: Self { self }

    func includes(_ row: FocusRow) -> Bool {
        switch self {
        case .tracked: !row.ignored
        case .unassigned: row.project == nil && !row.ignored
        case .assigned: row.project != nil && !row.ignored
        case .ignored: row.ignored
        }
    }

    var emptyMessage: String {
        switch self {
        case .tracked: "No tracked entries for this day."
        case .unassigned: "No entries to review for this day."
        case .assigned: "No assigned entries for this day."
        case .ignored: "No ignored entries for this day."
        }
    }
}

private struct FocusEntryGroup: Identifiable {
    struct Key: Hashable {
        let source: TimeSource
        let app: String
        let project: String?
        let client: String?
        let ignored: Bool

        init(_ entry: FocusRow) {
            source = entry.timeSource
            app = entry.appID ?? entry.appName
            project = entry.project
            client = entry.project == nil ? entry.client : nil
            ignored = entry.ignored
        }
    }

    let id: Key
    let entries: [FocusRow]

    var title: String { id.source == .toggl ? id.project ?? entries[0].appName : entries[0].appName }
    var subtitle: String {
        let status = id.ignored ? "Ignored" : id.project ?? id.client.map { "\($0) · Project unassigned" } ?? "To review"
        let count = entries.count == 1 ? "1 entry" : "\(entries.count) entries"
        var parts = [id.source == .toggl ? id.source.label : status, count]
        if entries.contains(where: { !$0.closed }) { parts.append("In progress") }
        return parts.joined(separator: " · ")
    }

    static func groups(_ rows: [FocusRow]) -> [Self] {
        var groups = Ordered<Key, [FocusRow]>()
        for row in rows { groups.append(row, to: Key(row)) }
        return groups.pairs.map { Self(id: $0.0, entries: $0.1) }
    }
}

private enum ActivitySpan: String, CaseIterable, Identifiable {
    case day = "Day"
    case week = "Week"

    var id: Self { self }
    var step: Int { self == .week ? 7 : 1 }
}

struct FocusTimeline: View {
    @EnvironmentObject private var recorder: FocusRecorder
    @EnvironmentObject private var ledger: LedgerModel
    let projects: [Project]
    let timezone: String
    /// A day another page asked to open, such as a day in the Overview's week strip.
    @Binding var jump: Date?
    let didClassify: () -> Void

    @State private var date = Date()
    @AppStorage("activitySpan") private var span: ActivitySpan = .day
    @State private var filter = FocusFilter.tracked
    @State private var expandedGroups: Set<FocusEntryGroup.Key> = []
    @State private var days: [DayActivity] = []
    @State private var loadedRange: String?
    @State private var saving = false
    @State private var error: String?
    @State private var reloadCount = 0
    @State private var showRules = false
    @State private var ruleHint: RuleHint?
    @State private var showQuickProject = false
    @State private var assignAfterCreate: [FocusRow] = []

    private enum RuleHint: Identifiable {
        case app(FocusRow)
        case tab(ChromeObservation)

        var id: String {
            switch self {
            case let .app(block): block.id
            case let .tab(tab): tab.address.originAndPath
            }
        }
    }

    private var zone: TimeZone { TimeZone(identifier: timezone) ?? .current }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.firstWeekday = 2
        return calendar
    }

    private var periodStart: Date {
        if span == .week { return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date }
        return calendar.startOfDay(for: date)
    }

    private var periodIsCurrent: Bool {
        calendar.isDate(periodStart, equalTo: Date(), toGranularity: span == .week ? .weekOfYear : .day)
    }

    private var dateKey: String {
        let parts = calendar.dateComponents([.year, .month, .day], from: periodStart)
        return String(format: "%04d-%02d-%02d", parts.year ?? 1, parts.month ?? 1, parts.day ?? 1)
    }

    private var rangeKey: String { "\(span.rawValue)-\(dateKey)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 21) {
            heading
            #if TRACKER_GOOGLE_CALENDAR
            ScheduledMeetings(
                start: periodStart,
                end: calendar.date(byAdding: .day, value: span.step, to: periodStart) ?? periodStart
            )
            #endif
            if span == .day, periodIsCurrent, let tab = recorder.lastChromeTab, let prompt = tab.rulePrompt {
                chromeRulePrompt(tab, prompt)
            }
            if let failure = error ?? recorder.error {
                HStack {
                    Label(failure, systemImage: "exclamationmark.circle").foregroundStyle(Color.red)
                    Spacer()
                    Button("Retry") {
                        error = nil
                        recorder.retry()
                        reloadCount += 1
                    }
                }
                .font(.callout)
            }
            if loadedRange == rangeKey {
                if span == .week {
                    ActivityWeek(days: days, calendar: calendar) { day in
                        date = min(day, Date())
                        span = .day
                    }
                } else if let day = days.first {
                    dayContent(day)
                }
            } else if error == nil {
                ProgressView("Loading activity…").controlSize(.small)
            }
        }
        .environment(\.calendar, calendar)
        .environment(\.timeZone, zone)
        .onAppear(perform: applyJump)
        .onChange(of: jump) { _, _ in applyJump() }
        .onChange(of: rangeKey) { _, _ in expandedGroups = [] }
        .onChange(of: filter) { _, _ in expandedGroups = [] }
        .task(id: "\(rangeKey)-\(recorder.revision)-\(ledger.revision)-\(reloadCount)") {
            await load(dateKey, span: span, range: rangeKey)
        }
        .sheet(isPresented: $showRules) {
            TrackingRulesSheet(projects: projects, didCreateProject: didClassify)
        }
        .sheet(item: $ruleHint) { hint in
            switch hint {
            case let .app(block):
                RuleSheet(rule: nil, projects: projects, appHint: block, didCreateProject: didClassify)
            case let .tab(tab):
                RuleSheet(rule: nil, projects: projects, tabHint: tab, didCreateProject: didClassify)
            }
        }
        .sheet(isPresented: $showQuickProject) {
            QuickProjectEditor { item in
                if assignAfterCreate.isEmpty {
                    didClassify()
                } else {
                    change(assignAfterCreate, ["--project=\(item.name)"])
                }
            }
        }
    }

    private var title: String {
        if span == .week {
            return periodIsCurrent ? "This week" : weekRange
        }
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(zoned(.dateTime.weekday(.wide)))
    }

    private func zoned(_ style: Date.FormatStyle) -> Date.FormatStyle {
        var style = style
        style.timeZone = zone
        return style
    }

    private var weekRange: String {
        let formatter = DateIntervalFormatter()
        formatter.timeZone = zone
        formatter.dateTemplate = "d MMM"
        let end = calendar.date(byAdding: .day, value: 6, to: periodStart) ?? periodStart
        return formatter.string(from: periodStart, to: end)
    }

    /// Two weeks of days, starting on the Monday before the selected date's week.
    private var stripDays: [DateStripDay] {
        let monday = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        return (0..<14).compactMap { offset in
            calendar.date(byAdding: .day, value: offset, to: monday).map { DateStripDay(date: $0) }
        }
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 16) {
            PageHeader(title: title,
                       subtitle: span == .week ? weekRange : date.formatted(zoned(.dateTime.weekday(.wide).day().month(.wide).year()))) {
                HStack(spacing: 6) {
                    HStack(spacing: 2) {
                        ForEach(ActivitySpan.allCases) { item in
                            Button(item.rawValue) { span = item }
                                .buttonStyle(SegmentStyle(selected: span == item))
                        }
                    }
                    .padding(2)
                    .background(Theme.block, in: Capsule())
                    Button("Rules") { showRules = true }
                        .buttonStyle(PillButtonStyle())
                        .disabled(!recorder.ready)
                        .help("Manage tracking rules")
                    Button(span == .week ? "This week" : "Today") { date = Date() }
                        .buttonStyle(PillButtonStyle())
                        .disabled(periodIsCurrent)
                    Button(span == .week ? "Previous week" : "Previous day", systemImage: "chevron.left") { movePeriod(-1) }
                        .buttonStyle(CircleButtonStyle())
                    Button(span == .week ? "Next week" : "Next day", systemImage: "chevron.right") { movePeriod(1) }
                        .buttonStyle(CircleButtonStyle())
                        .disabled(periodIsCurrent)
                }
                .fixedSize()
            }
            if span == .day {
                DateStrip(days: stripDays, selected: date, calendar: calendar) { day in
                    date = min(day, Date())
                }
                if loadedRange == rangeKey, let day = days.first {
                    daySentence(day)
                }
            }
        }
    }

    private func daySentence(_ day: DayActivity) -> some View {
        let review = day.unassignedAppSeconds
        let threads = day.agentThreads ?? []
        let projects = Set(threads.compactMap(\.project))
        let billed = (day.billing?.you ?? []).reduce(0.0) { $0 + $1.billedMillis } / 1000
        var parts: [SummarySentence.Part] = [
            .text("Logged time"), .chip(hoursText(day.loggedHumanMillis.map { String($0 / 3_600_000) }), .blue),
        ]
        if review > 0 {
            parts += [.text("·"), .chip(duration(review), .amber), .text("to assign")]
        }
        if !threads.isEmpty {
            parts += [.text("· Agents ran"), .chip("\(threads.count) \(threads.count == 1 ? "thread" : "threads")", .neutral)]
            if !projects.isEmpty {
                parts += [.text("on"), .chip("\(projects.count) \(projects.count == 1 ? "project" : "projects")", .blue)]
            }
        }
        if billed >= 60 {
            parts += [.text("· billable"), .chip(hoursText(String(billed / 3600)), .green)]
        }
        return SummarySentence(parts: parts)
    }

    @ViewBuilder
    private func dayContent(_ day: DayActivity) -> some View {
        if !day.blocks.isEmpty || day.agentThreads?.isEmpty == false {
            DayCalendar(day: day, projects: projects, currency: ledger.snapshot?.currency ?? "EUR",
                        isToday: periodIsCurrent, zone: zone, saving: saving) { blocks, arguments in
                change(blocks, arguments)
            }
        }
        if !day.blocks.isEmpty {
            list(day)
        } else if error == nil && day.agentThreads?.isEmpty != false {
            VStack(alignment: .leading, spacing: 6) {
                Label("No time recorded for this day", systemImage: "clock").font(.headline)
                Text(periodIsCurrent
                     ? (recorder.enabled ? "Switch to another app and use it for a little while."
                        : "Tracking is snoozed. It resumes by itself.")
                     : "Choose another day to view auto-tracked or imported time.")
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 13)
        }
        if !day.agents.isEmpty {
            agentActivity(day.agents)
        }
    }

    private func chromeRulePrompt(_ tab: ChromeObservation, _ prompt: ChromeObservation.RulePrompt) -> some View {
        let status = prompt == .reviewConflict ? "Conflicting rules" : "No matching rule"
        let profile = tab.profileID.map(recorder.chromeProfileName) ?? tab.profile
        return HStack(spacing: 12) {
            Image(systemName: "globe").foregroundStyle(.secondary).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Last Chrome tab").font(.caption).foregroundStyle(.secondary)
                Text(tab.address.originAndPath).font(.callout.weight(.medium))
                    .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Text([profile.map { "Profile: \($0)" }, tab.windowName, status]
                    .compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .privacySensitive()
            Spacer()
            switch prompt {
            case .create:
                Button("Create tab rule…") { ruleHint = .tab(tab) }
            case .reviewConflict:
                Button("Review rules…") { showRules = true }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private func agentActivity(_ agents: [DayAgent]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Agent totals").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Text("Run time and tokens per project from Codex, Claude Code and OpenCode history.")
                .font(.callout).foregroundStyle(.secondary)
            LazyVStack(spacing: 0) {
                Divider()
                ForEach(agents) { agent in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(providerName(agent.provider)).fontWeight(.medium)
                            Text(agent.destination.isEmpty ? "Unassigned" :
                                 agent.destination + (agent.project == nil ? " · Unassigned" : ""))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 3) {
                            Text("\(tokensText(agent.tokens)) tokens").monospacedDigit()
                            if let millis = agent.runtimeMillis {
                                Text(duration(millis / 1000) + (agent.runtimeMethod == "turn elapsed" ? " run time" : " est. request time"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 9)
                    Divider()
                }
            }
        }
    }

    private func list(_ day: DayActivity) -> some View {
        let rows = day.blocks.filter(filter.includes)
        return VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Entries").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Picker("Filter activity", selection: $filter) {
                    ForEach(FocusFilter.allCases) { value in Text(value.rawValue).tag(value) }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
            }

            if rows.isEmpty {
                Text(filter.emptyMessage).foregroundStyle(.secondary).padding(.vertical, 10)
            } else {
                if projects.isEmpty && rows.contains(where: { $0.timeSource == .automatic && $0.closed && !$0.ignored }) {
                    HStack {
                        Text("Create a project to assign this time.").foregroundStyle(.secondary)
                        Button("New project…") { createProject() }.buttonStyle(.link)
                    }
                }
                LazyVStack(spacing: 0) {
                    Divider()
                    ForEach(FocusEntryGroup.groups(rows)) { group in
                        groupRow(group)
                        Divider()
                        if expandedGroups.contains(group.id) {
                            ForEach(group.entries) { block in
                                row(block).padding(.leading, 24)
                                Divider().padding(.leading, 24)
                            }
                        }
                    }
                }
            }
        }
    }

    private func groupRow(_ group: FocusEntryGroup) -> some View {
        let expanded = expandedGroups.contains(group.id)
        let seconds = group.entries.reduce(0) { $0 + $1.seconds }
        return HStack(spacing: 15) {
            Button {
                if expanded { expandedGroups.remove(group.id) } else { expandedGroups.insert(group.id) }
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 14)
                        .accessibilityHidden(true)
                    Image(systemName: group.id.source.icon)
                        .frame(width: 18).foregroundStyle(group.entries[0].tint).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(group.title).fontWeight(.medium).lineLimit(1)
                        Text(group.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Text(duration(seconds)).monospacedDigit()
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(expanded ? "Collapse entries" : "Show individual entries")
            if group.id.source == .automatic {
                assignmentMenu(group.entries)
                    .frame(width: 74, alignment: .trailing)
            }
        }
    }

    private func row(_ block: FocusRow) -> some View {
        HStack(spacing: 15) {
            VStack(alignment: .leading, spacing: 3) {
                Text(time(block.start)).monospacedDigit()
                Text(time(block.end)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            .frame(width: 78, alignment: .leading)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("From \(time(block.start)) to \(time(block.end))")
            .accessibilityAddTraits(.isStaticText)
            Image(systemName: block.timeSource.icon)
                .frame(width: 18).foregroundStyle(block.tint).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(block.timeSource == .toggl ? block.project ?? block.appName : block.appName)
                    .fontWeight(.medium).lineLimit(1)
                Text(blockDescription(block))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(block.keyword.map { "Matched keyword: \($0)" } ?? "")
                if let repo = block.githubRepo {
                    let path = block.githubPr.map { "\(repo)/pull/\($0)" } ?? repo
                    let label = block.githubPr.map { "\(repo)#\($0)" } ?? repo
                    if let url = URL(string: "https://github.com/" + path) {
                        Link(label, destination: url).font(.caption).lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(duration(block.seconds)).monospacedDigit()
            Group {
                if block.timeSource == .automatic {
                    assignmentMenu([block])
                }
            }
            .frame(width: 74, alignment: .trailing)
        }
        .padding(.vertical, 10)
    }

    private func assignmentMenu(_ blocks: [FocusRow]) -> some View {
        let block = blocks[0]
        let completed = blocks.filter(\.closed)
        let count = completed.count
        let scope = count == 1 ? "entry" : "\(count) entries"
        return Menu(block.ignored ? "Actions" : block.project == nil ? "Assign" : "Change") {
            ForEach(projects) { project in
                Button {
                    change(completed, ["--project=\(project.name)"])
                } label: {
                    Label { Text(project.name) } icon: { ProjectColor.menuDot(for: project.name) }
                }
            }
            Button("New project and assign…") { createProject(assigning: completed) }
            Divider()
            if block.ignored {
                Button("Restore \(scope) to review") { change(completed, ["--unassign"]) }
            } else {
                if block.project != nil {
                    Button("Unassign \(scope)") { change(completed, ["--unassign"]) }
                }
                Button("Ignore \(scope)") { change(completed, ["--ignore"]) }
            }
            Divider()
            Button("Create app rule for future time…") { ruleHint = .app(block) }
        }
        .fixedSize()
        .controlSize(.small)
        .disabled(completed.isEmpty || saving)
        .help(blocks.count == count ? "Actions for \(block.appName)" : "Actions apply to completed entries")
        .accessibilityLabel("Actions for \(block.appName), \(scope)")
    }

    private func createProject(assigning blocks: [FocusRow] = []) {
        assignAfterCreate = blocks
        showQuickProject = true
    }

    private func blockDescription(_ block: FocusRow) -> String {
        let source = block.timeSource.label
        if block.timeSource == .toggl { return block.timeSource.calendarLabel }
        if block.ignored { return "\(source) · Ignored" }
        if !block.closed { return "\(source) · In progress" }
        return [source, block.assignmentLabel, block.tag].compactMap { $0 }.joined(separator: " · ")
    }

    private func applyJump() {
        guard let target = jump else { return }
        span = .day
        date = min(target, Date())
        jump = nil
    }

    private func movePeriod(_ direction: Int) {
        if let next = calendar.date(byAdding: .day, value: direction * span.step, to: date) {
            date = min(next, Date())
        }
    }

    private func time(_ date: Date) -> String {
        var format = Date.FormatStyle(date: .omitted, time: .shortened)
        format.timeZone = zone
        return date.formatted(format)
    }

    private func duration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded(.down))) s" }
        return hoursText(String(seconds / 3600))
    }

    private func load(_ key: String, span: ActivitySpan, range: String) async {
        struct Week: Decodable { let days: [DayActivity] }
        do {
            var arguments = ["focus", "timeline", "--day", key]
            arguments.append(span == .week ? "--week" : "--with-human-time")
            let data = try await Ledger.run(arguments)
            let decoder = JSONDecoder()
            let result = span == .week ? try decoder.decode(Week.self, from: data).days
                : [try decoder.decode(DayActivity.self, from: data)]
            guard !Task.isCancelled else { return }
            days = result
            loadedRange = range
            error = nil
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func change(_ blocks: [FocusRow], _ arguments: [String]) {
        guard !saving, let first = blocks.first else { return }
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                let additional = blocks.dropFirst().map { "--also=\($0.id)" }
                _ = try await Ledger.run(["focus", "classify", first.id] + arguments + additional)
                reloadCount += 1
                didClassify()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// One option in a pill-shaped segmented control (Day / Week).
private struct SegmentStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.medium))
            .foregroundStyle(selected ? Theme.text : Theme.secondary)
            .padding(.horizontal, 11)
            .frame(height: 22)
            .background(selected ? Theme.card : Color.clear, in: Capsule())
            .shadow(color: .black.opacity(selected ? 0.08 : 0), radius: 1, y: 0.5)
            .contentShape(Capsule())
    }
}
