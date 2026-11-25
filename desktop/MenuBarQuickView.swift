import AppKit
import SwiftUI

/// The icon Tracker shows in the macOS menu bar. It changes with the tracking state, so a
/// glance at the menu bar says whether time is being recorded.
struct MenuBarLabel: View {
    @ObservedObject var recorder: FocusRecorder
    #if TRACKER_PAYMENTS
    @ObservedObject private var licensing = Licensing.shared
    #endif

    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel(label)
    }

    private var label: String {
        #if TRACKER_PAYMENTS
        if licensing.isLocked { return "Daylanes, trial ended" }
        #endif
        return "Daylanes, \(TrackingStatusText.label(recorder, now: Date()))"
    }

    private var symbol: String {
        #if TRACKER_PAYMENTS
        if licensing.isLocked { return "lock.fill" }
        #endif
        guard recorder.enabled else { return "moon.zzz.fill" }
        switch recorder.status {
        case .recording, .waiting: return "timer"
        case .idle, .away: return "moon.zzz"
        case .paused: return "pause.circle"
        }
    }
}

/// Popover opened from the menu bar icon: what is being tracked now, today's time per project,
/// agent runtime today, and quick actions.
struct MenuBarQuickView: View {
    @ObservedObject var recorder: FocusRecorder
    @ObservedObject var model: LedgerModel
    #if TRACKER_PAYMENTS
    @ObservedObject private var licensing = Licensing.shared
    #endif
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab: SettingsSection = .general
    @State private var day: DayActivity?
    @State private var windows: [UsageWindow] = []
    @State private var planLimits: [PlanLimit] = []
    @State private var error: String?
    @State private var saving = false
    @State private var visible = false

    private static let width: CGFloat = 340

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    current
                    if let error {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    today
                    agents
                    usageWindows
                }
                .padding(14)
            }
            .frame(maxHeight: 420)
            Divider()
            footer
        }
        .frame(width: Self.width)
        .onAppear { visible = true }
        .onDisappear { visible = false }
        .task {
            await model.start()
            await recorder.prepare()
        }
        // The recorder bumps its revision whenever it saves activity, so the preview stays current while open.
        .task(id: "\(visible)-\(recorder.revision)-\(model.revision)") {
            guard visible else { return }
            await load()
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Circle().fill(tint).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text(recorder.enabled ? "Tracking" : "Snoozed").font(.headline)
                Group {
                    if let message = recorder.error {
                        Text(message)
                    } else {
                        TrackingStatusText(recorder: recorder)
                    }
                }
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Menu {
                SnoozeMenuItems(recorder: recorder)
            } label: {
                Label(recorder.enabled ? "Snooze" : "Resume", systemImage: recorder.enabled ? "moon.zzz" : "play.fill")
            }
            .fixedSize()
            .disabled(!recorder.ready)
            .help(recorder.enabled ? "Stop tracking for a while; it resumes by itself" : "Resume tracking now")
        }
        .padding(14)
    }

    private var tint: Color {
        guard recorder.enabled else { return .secondary }
        if case .recording = recorder.status { return .green }
        return .orange
    }

    private var statusDetail: String {
        if let message = recorder.error { return message }
        guard recorder.enabled else { return "Start to record the apps you use" }
        if case .waiting = recorder.status { return "Tracking the app you return to" }
        return recorder.status.label
    }

    // MARK: Current activity

    /// The block being recorded, or the one that just ended (opening this popover makes Tracker the
    /// frontmost app, which closes the block for the app you were in).
    private var latest: FocusRow? {
        day?.blocks.filter { $0.timeSource == .automatic }.max { $0.endedAt < $1.endedAt }
    }

    @ViewBuilder
    private var current: some View {
        if let block = latest {
            VStack(alignment: .leading, spacing: 8) {
                Text(block.closed ? "Last activity" : "Now").font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(block.ignored ? Color.secondary : ProjectColor.color(for: block.project))
                        .frame(width: 8, height: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(block.appName).font(.body.weight(.medium)).lineLimit(1)
                        Text(blockDetail(block)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        Text(duration(seconds(block, now: context.date)))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                assignMenu(block)
            }
        } else if day != nil {
            Text(recorder.enabled ? "Nothing recorded yet today." : "No tracked time today.")
                .font(.callout).foregroundStyle(.secondary)
        } else {
            ProgressView().controlSize(.small).frame(maxWidth: .infinity)
        }
    }

    private func blockDetail(_ block: FocusRow) -> String {
        let since = "since \(time(block.start))"
        if block.ignored { return "Ignored · \(since)" }
        return [block.assignmentLabel, block.tag, since].compactMap { $0 }.joined(separator: " · ")
    }

    private var projects: [Project] {
        (model.snapshot?.projects ?? []).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Chrome time is better routed by site than by app, so offer the current domain when there is one.
    private func ruleTarget(_ block: FocusRow) -> (field: String, keyword: String, label: String) {
        if block.appName == "Google Chrome", let host = recorder.lastChromeTab?.address.host {
            return ("domain", host, host)
        }
        return ("app", block.appName, block.appName)
    }

    private func assignMenu(_ block: FocusRow) -> some View {
        let target = ruleTarget(block)
        return Menu {
            if block.closed {
                Section("This block") {
                    ForEach(projects) { project in
                        Button(project.name) { classify(block, ["--project=\(project.name)"]) }
                    }
                    if block.project != nil || block.ignored {
                        Button("Unassign") { classify(block, ["--unassign"]) }
                    }
                    if !block.ignored {
                        Button("Ignore") { classify(block, ["--ignore"]) }
                    }
                }
            }
            Section("Always send \(target.label) to") {
                ForEach(projects) { project in
                    Button(project.name) { saveRule(target, project: project.name, also: block) }
                }
            }
            if projects.isEmpty {
                Button("Create a project…") { showMain() }
            }
        } label: {
            Label(block.project == nil ? "Assign to project" : "Change project", systemImage: "folder")
        }
        .menuStyle(.button)
        .controlSize(.small)
        .fixedSize()
        .disabled(saving || model.snapshot == nil)
    }

    // MARK: Today

    private struct ProjectTime: Identifiable {
        let project: String?
        let seconds: Double
        var id: String { project ?? "\u{1}unassigned" }
    }

    private func projectTimes(now: Date) -> [ProjectTime] {
        guard let day else { return [] }
        var totals: [String?: Double] = [:]
        for block in day.blocks where !block.ignored {
            totals[block.project, default: 0] += seconds(block, now: now)
        }
        return totals.map { ProjectTime(project: $0.key, seconds: $0.value) }
            .filter { $0.seconds >= 30 }
            .sorted { $0.seconds > $1.seconds }
    }

    @ViewBuilder
    private var today: some View {
        if day != nil {
            TimelineView(.periodic(from: .now, by: 30)) { context in
                let rows = projectTimes(now: context.date)
                let total = rows.reduce(0) { $0 + $1.seconds }
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("Today").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Text(duration(total)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if rows.isEmpty {
                        Text("No project time yet.").font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(rows.prefix(8)) { row in
                        HStack(spacing: 8) {
                            Circle().fill(row.project == nil ? Color.orange : ProjectColor.color(for: row.project))
                                .frame(width: 7, height: 7)
                            Text(row.project ?? "Unassigned").lineLimit(1)
                                .foregroundStyle(row.project == nil ? Color.secondary : Color.primary)
                            Spacer()
                            Text(duration(row.seconds)).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        .overlay(alignment: .bottom) {
                            GeometryReader { proxy in
                                Capsule()
                                    .fill((row.project == nil ? Color.orange : ProjectColor.color(for: row.project)).opacity(0.35))
                                    .frame(width: total > 0 ? proxy.size.width * row.seconds / total : 0, height: 2)
                            }
                            .frame(height: 2)
                            .offset(y: 4)
                        }
                        .padding(.bottom, 4)
                    }
                    if rows.count > 8 {
                        Text("\(rows.count - 8) more in Daylanes").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: Agents

    private struct AgentTime: Identifiable {
        let provider: String
        let millis: Double
        let tokens: Int
        var id: String { provider }
    }

    @ViewBuilder
    private var agents: some View {
        let rows = agentTimes
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text("Agents today").font(.caption).foregroundStyle(.secondary)
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles").font(.caption).foregroundStyle(.purple)
                        Text(providerName(row.provider)).lineLimit(1)
                        Spacer()
                        if row.tokens > 0 {
                            Text(tokensText(row.tokens) + " tokens").foregroundStyle(.tertiary)
                        }
                        Text(row.millis > 0 ? duration(row.millis / 1000) : "—")
                            .monospacedDigit().foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
            }
        }
    }

    private var agentTimes: [AgentTime] {
        guard let day else { return [] }
        var rows: [String: AgentTime] = [:]
        for agent in day.agents {
            let previous = rows[agent.provider]
            rows[agent.provider] = AgentTime(provider: agent.provider,
                                             millis: (previous?.millis ?? 0) + (agent.runtimeMillis ?? 0),
                                             tokens: (previous?.tokens ?? 0) + agent.tokens)
        }
        return rows.values.sorted { $0.millis > $1.millis }
    }

    // MARK: Usage windows

    /// The five-hour window each agent is in now, like the limits Claude and ChatGPT plans meter.
    @ViewBuilder
    private var usageWindows: some View {
        if !windows.isEmpty || !planLimits.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Text("Usage window").font(.caption).foregroundStyle(.secondary)
                ForEach(planLimits) { limit in
                    HStack(spacing: 8) {
                        Image(systemName: "chart.bar.fill").font(.caption).foregroundStyle(.purple)
                        Text(providerName(limit.provider) + (limit.planType.map { " \($0.capitalized)" } ?? "")).lineLimit(1)
                        Spacer()
                        Text(limit.windows.map(limitText).joined(separator: " · "))
                            .monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    }
                    .font(.callout)
                    .help("Plan usage as \(providerName(limit.provider)) reported it on its last request.")
                }
                ForEach(windows) { window in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Image(systemName: "gauge.with.dots.needle.33percent").font(.caption).foregroundStyle(.purple)
                            Text(providerName(window.provider)).lineLimit(1)
                            Spacer()
                            Text(tokensText(window.totalTokens) + " tokens").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.callout)
                        Text(windowDetail(window)).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .help("Estimated from local logs: a window opens at the hour of the first request and lasts five hours.")
                }
            }
        }
    }

    private func limitText(_ window: PlanLimit.Window) -> String {
        let minutes = window.windowMinutes ?? 0
        let name = minutes >= 10080 ? "week" : minutes >= 60 ? "\(minutes / 60)h" : window.name
        return "\(Int(window.usedPercent.rounded()))% of \(name)"
    }

    private func windowDetail(_ window: UsageWindow) -> String {
        let resets = Date(timeIntervalSince1970: window.end / 1000)
        var parts = ["Resets about \(time(resets))"]
        // The API value is only meaningful when every model in the window has a public price.
        let priced = window.tokensWithoutApiPrice == 0
        if priced { parts.append(costText(window.apiValueUsd, currency: "USD") + " API value") }
        if let rate = window.burnRate {
            parts.append(priced ? "\(costText(rate.apiValueUsdPerHour, currency: "USD"))/h"
                                : "\(tokensText(rate.tokensPerMinute))/min")
        }
        if let projection = window.projection {
            let pace = priced ? costText(projection.apiValueUsd, currency: "USD") : tokensText(projection.totalTokens)
            parts.append("on pace for \(pace)")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Footer

    #if TRACKER_PAYMENTS
    private var showBuy: Bool {
        switch licensing.status {
        case .trial, .trialEnded: true
        default: false
        }
    }
    #endif

    private var footer: some View {
        HStack(spacing: 4) {
            Button {
                showMain()
            } label: {
                Label("Open Daylanes", systemImage: "macwindow")
            }
            if let unassigned = unassignedCount, unassigned > 0 {
                Button {
                    showMain()
                } label: {
                    Text("\(unassigned) to review").foregroundStyle(.orange)
                }
                .help("Open Daylanes to assign agent work that has no project yet")
            }
            #if TRACKER_PAYMENTS
            if showBuy {
                Button {
                    settingsTab = .account
                    NSApplication.shared.activate()
                    openSettings()
                } label: {
                    Text("Buy Daylanes…").foregroundStyle(Color.accentColor)
                }
                .help("Buy Daylanes for \(licensing.price) USD")
            }
            #endif
            Spacer()
            Button {
                settingsTab = .general
                NSApplication.shared.activate()
                openSettings()
            } label: {
                Image(systemName: "gearshape")
            }
            .help("Settings")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .help("Quit Daylanes")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var unassignedCount: Int? { model.snapshot?.unassigned.count }

    // MARK: Actions

    private func showMain() {
        openWindow(id: "main")
        NSApplication.shared.activate()
    }

    private func load() async {
        do {
            let data = try await Ledger.run(["focus", "timeline"])
            let result = try JSONDecoder().decode(DayActivity.self, from: data)
            guard !Task.isCancelled else { return }
            day = result
            error = nil
            // Usage windows are a bonus: if they cannot be read, the rest of the popover still works.
            if let blocks = try? await Ledger.run(["blocks", "--active", "--hours", "5"]) {
                let decoder = JSONDecoder()
                decoder.keyDecodingStrategy = .convertFromSnakeCase
                if let decoded = try? decoder.decode(UsageWindows.self, from: blocks), !Task.isCancelled {
                    windows = decoded.blocks
                    planLimits = decoded.planLimits ?? []
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }

    private func classify(_ block: FocusRow, _ arguments: [String]) {
        run { _ = try await Ledger.run(["focus", "classify", block.id] + arguments) }
    }

    /// Saves a rule for future activity and, when the block has ended, assigns it too.
    private func saveRule(_ target: (field: String, keyword: String, label: String), project: String,
                          also block: FocusRow) {
        // Retarget an existing rule for the same app or domain: a second rule with another project
        // would tie with it, and tied rules that disagree leave the activity unassigned.
        let existing = recorder.rules.first {
            !$0.isIgnored && $0.field == target.field && $0.appScope == nil && $0.chromeProfile == nil && $0.chromeProfileID == nil
                && $0.keyword.caseInsensitiveCompare(target.keyword) == .orderedSame
        }
        run {
            if existing?.project != project {
                var arguments = ["save-rule", "--field=\(target.field)", "--keyword=\(target.keyword)",
                                 "--project=\(project)"]
                if let existing {
                    arguments += ["--id", existing.id]
                    if let tag = existing.tag { arguments.append("--tag=\(tag)") }
                }
                try await recorder.applyRuleChange(arguments)
            }
            if block.closed && block.project == nil && !block.ignored {
                _ = try await Ledger.run(["focus", "classify", block.id, "--project=\(project)"])
            }
        }
    }

    private func run(_ action: @escaping () async throws -> Void) {
        saving = true
        error = nil
        Task {
            defer { saving = false }
            do {
                try await action()
                await load()
                // Lets the main window's timeline and totals pick up the change.
                await model.reload()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: Formatting

    private func seconds(_ block: FocusRow, now: Date) -> Double {
        // The open block is saved every 15 seconds, so extend it to now while it is still running.
        block.closed ? block.seconds : max(block.seconds, now.timeIntervalSince(block.start))
    }

    private func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    private func duration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(Int(seconds.rounded(.down))) s" }
        return hoursText(String(seconds / 3600))
    }
}

/// Output of `tracker blocks`: agent usage grouped into five-hour windows.
struct UsageWindows: Decodable {
    let blocks: [UsageWindow]
    let planLimits: [PlanLimit]?
}

/// Plan usage a tool logged itself, such as Codex's 5-hour and weekly windows.
struct PlanLimit: Decodable, Identifiable {
    struct Window: Decodable {
        let name: String
        let windowMinutes: Int?
        let usedPercent: Double
        let resetsAt: Double?
    }

    let provider: String
    let planType: String?
    let windows: [Window]

    var id: String { provider }
}

struct UsageWindow: Decodable, Identifiable {
    struct BurnRate: Decodable {
        let tokensPerMinute: Int
        let apiValueUsdPerHour: String
    }

    struct Projection: Decodable {
        let totalTokens: Int
        let apiValueUsd: String
    }

    let provider: String
    let start: Double
    let end: Double
    let totalTokens: Int
    let apiValueUsd: String
    let tokensWithoutApiPrice: Int
    let burnRate: BurnRate?
    let projection: Projection?

    var id: String { "\(provider)-\(start)" }
}
