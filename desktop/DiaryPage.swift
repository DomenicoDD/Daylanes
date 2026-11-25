import SwiftUI

/// The project diary as one reading column: a header, then the recent workdays newest first, each on a timeline
/// with its date on the left. Days without an entry fold into a quiet row.
struct DiaryPage: View {
    let snapshot: Snapshot
    @State private var span = DiaryPage.step
    @State private var entries: [DiaryEntry] = []
    @State private var oldest: String?
    @State private var currentDay: String?
    @State private var clock: DiaryClock?
    @State private var client: String?
    @State private var project: String?
    @State private var setup: SetupTarget?
    @State private var editing: DiaryEntry?
    @State private var copied: String?
    @State private var error: String?

    private static let step = 14

    private var filteredProjects: [Project] {
        snapshot.projects.filter { client == nil || $0.client == client }
    }

    private var shown: [DiaryEntry] { DiaryPageData(entries, client: client, project: project).entries }
    private var zone: TimeZone { clock?.zone ?? TimeZone(identifier: snapshot.timezone) ?? .current }

    private var range: (first: Day, last: Day)? {
        guard let currentDay, let last = try? Day.parse(currentDay) else { return nil }
        return (last.adding(days: 1 - span), last)
    }

    private var rows: [DiaryTimeline.Row] {
        guard let range else { return [] }
        return DiaryTimeline.rows(shown, from: range.first, through: range.last)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                header
                content
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .padding(.bottom, 40)
            .frame(maxWidth: 860, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("diary-page")
        .task(id: snapshot.database) { reload() }
        .onReceive(DistributedNotificationCenter.default().publisher(for: DiaryStore.changed)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
        .onChange(of: span) { _, _ in reload() }
        .onChange(of: snapshot.projects.map(\.name)) { _, names in
            if let project, !names.contains(project) { self.project = nil }
        }
        .sheet(item: $editing) { entry in
            DiaryEntryEditor(database: snapshot.database, entry: entry, didSave: reload)
        }
        .sheet(item: $setup) { target in
            DiarySetupSheet(database: snapshot.database, projects: snapshot.projects, project: target.project) { name in
                client = snapshot.projects.first { $0.name == name }?.client
                project = name
                reload()
            }
        }
    }

    // MARK: Header

    private var eyebrow: String {
        (project ?? client ?? "All projects") + " · daily log"
    }

    private var status: String {
        var parts: [String] = []
        if let latest = shown.first {
            parts.append("Latest entry " + dateFor(latest.day).formatted(dateFormat(.dateTime.weekday(.wide).day().month(.wide))))
        }
        if let clock {
            parts.append("each workday ends at \(DiaryClock.label(clock.cutoff))")
        }
        return parts.joined(separator: " · ")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1.1)
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    title
                    Spacer(minLength: 12)
                    actions
                }
                VStack(alignment: .leading, spacing: 12) {
                    title
                    actions
                }
            }
            if !status.isEmpty {
                Text(status).font(.callout).foregroundStyle(Theme.secondary)
            }
        }
    }

    private var title: some View {
        Text("What shipped, day by day")
            .font(.system(size: 30, weight: .semibold, design: .serif))
            .foregroundStyle(Theme.text)
            .accessibilityAddTraits(.isHeader)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Menu {
                Picker("Client", selection: $client) {
                    Text("All clients").tag(nil as String?)
                    ForEach(snapshot.clients, id: \.self) { Text($0).tag(Optional($0)) }
                }
                .pickerStyle(.inline)
                Picker("Project", selection: $project) {
                    Text("All projects").tag(nil as String?)
                    ForEach(filteredProjects) { Text($0.name).tag(Optional($0.name)) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(project ?? client ?? "All projects", systemImage: "line.3.horizontal.decrease")
            }
            .menuStyle(.button)
            .buttonStyle(PillButtonStyle())
            .fixedSize()
            .accessibilityLabel("Filter by client or project")
            .onChange(of: client) { _, _ in
                if !filteredProjects.contains(where: { $0.name == project }) { project = nil }
            }
            Button {
                setup = SetupTarget(project: project)
            } label: {
                Label("Set up diary…", systemImage: "gearshape")
            }
            .buttonStyle(PillButtonStyle())
            .disabled(snapshot.projects.isEmpty)
        }
    }

    // MARK: Timeline

    @ViewBuilder
    private var content: some View {
        if let error {
            VStack(alignment: .leading, spacing: 8) {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
                Button("Retry", action: reload)
            }
        } else if currentDay == nil {
            ProgressView("Loading diary…")
        } else if oldest == nil {
            emptyState
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    timelineRow(row, last: index == rows.count - 1)
                }
            }
            if let oldest, let range, oldest < range.first.iso {
                Button("Show earlier days") { span += Self.step }
                    .buttonStyle(PillButtonStyle())
                    .padding(.leading, 112)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "book.pages").font(.system(size: 26)).foregroundStyle(Theme.accent)
            Text("Your diary starts here").font(.system(size: 22, weight: .semibold, design: .serif))
            Text("Pick a project and copy its prompt into Codex, Claude Code or any agent. It writes a short entry for each workday from your commits, pull requests and notes, and it shows up here.")
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button(project.map { "Set up the \($0) diary" } ?? "Set up a project diary") {
                setup = SetupTarget(project: project)
            }
            .buttonStyle(PillButtonStyle(prominent: true))
            .disabled(snapshot.projects.isEmpty)
            .padding(.top, 4)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .blockSurface()
    }

    private func timelineRow(_ row: DiaryTimeline.Row, last: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            when(row).frame(width: 84, alignment: .leading)
            rail(row, last: last).frame(width: 28)
            Group {
                switch row {
                case let .day(_, entries):
                    VStack(alignment: .leading, spacing: 26) {
                        ForEach(entries) { entryView($0) }
                    }
                case let .quiet(from, to):
                    Text(quietText(from: from, to: to))
                        .font(.callout)
                        .foregroundStyle(Theme.secondary)
                        .padding(.top, 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, quiet(row) ? 28 : 36)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func quiet(_ row: DiaryTimeline.Row) -> Bool {
        if case .quiet = row { return true }
        return false
    }

    private func quietText(from: String, to: String) -> String {
        if to == currentDay { return "Today’s entry lands here after the workday ends." }
        return from == to ? "No entry" : "No entries"
    }

    @ViewBuilder
    private func when(_ row: DiaryTimeline.Row) -> some View {
        switch row {
        case let .day(day, entries):
            VStack(alignment: .leading, spacing: 3) {
                Text(dateFor(day), format: dateFormat(.dateTime.day().month(.abbreviated)))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.text)
                Text(dateFor(day), format: dateFormat(.dateTime.weekday(.wide)))
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
                if day == currentDay {
                    tag("today", tint: .purple)
                } else if entries.contains(where: \.early) {
                    tag("early", tint: .amber)
                        .help("This workday has not yet been refreshed through its cutoff.")
                }
            }
            .padding(.top, 2)
            .accessibilityElement(children: .combine)
        case let .quiet(from, to):
            VStack(alignment: .leading, spacing: 3) {
                Text(quietRange(from: from, to: to))
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Theme.secondary)
                if to == currentDay { tag("today", tint: .purple) }
            }
            .padding(.top, 2)
        }
    }

    private func quietRange(from: String, to: String) -> String {
        let style = dateFormat(.dateTime.day().month(.abbreviated))
        if from == to { return dateFor(from).formatted(style) }
        // ISO days: the same "YYYY-MM" prefix means the same month, so the start can drop it.
        let start = from.prefix(7) == to.prefix(7) ? dateFor(from).formatted(dateFormat(.dateTime.day()))
            : dateFor(from).formatted(from.prefix(4) == to.prefix(4) ? style : dateFormat(.dateTime.day().month(.abbreviated).year()))
        return start + "–" + dateFor(to).formatted(from.prefix(4) == to.prefix(4) ? style : dateFormat(.dateTime.day().month(.abbreviated).year()))
    }

    private func tag(_ text: String, tint: Theme.Tint) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundStyle(tint.ink)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.fill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .padding(.top, 2)
    }

    private func rail(_ row: DiaryTimeline.Row, last: Bool) -> some View {
        VStack(spacing: 0) {
            Circle()
                .fill(quiet(row) ? Theme.secondary.opacity(0.45) : Theme.accent)
                .frame(width: quiet(row) ? 7 : 9, height: quiet(row) ? 7 : 9)
                .padding(.top, quiet(row) ? 6 : 5)
            Rectangle()
                .fill(last ? Color.clear : Theme.secondary.opacity(0.25))
                .frame(width: 1)
                .frame(maxHeight: .infinity)
                .padding(.top, 4)
        }
        .accessibilityHidden(true)
    }

    // MARK: Entry

    private func entryView(_ entry: DiaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if project == nil {
                Chip(text: entry.project, tint: .forProject(entry.project))
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(entry.headline)
                    .font(.system(size: 22, weight: .semibold, design: .serif))
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                Button("Edit…", systemImage: "pencil") { editing = entry }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(Theme.secondary)
                    .accessibilityLabel("Edit \(entry.project) diary")
            }
            if !entry.summary.isEmpty {
                Text(entry.summary)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.text.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if !entry.standup.pythonStripped.isEmpty { standup(entry) }
            ForEach(Array(entry.details.enumerated()), id: \.offset) { _, section in
                detail(section)
            }
            let sources = entry.content.sources ?? []
            if !sources.isEmpty {
                FlowLayout(spacing: 6, lineSpacing: 6) {
                    ForEach(Array(sources.enumerated()), id: \.offset) { _, source in sourceChip(source) }
                }
            }
        }
    }

    private func standup(_ entry: DiaryEntry) -> some View {
        let text = entry.standup.pythonStripped
        let seconds = max(10, Int((Double(text.split(whereSeparator: \.isWhitespace).count) / 150 * 60 / 10).rounded()) * 10)
        let isCopied = copied == entry.day + "/" + entry.project
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Read aloud · about \(seconds) sec", systemImage: "mic")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Theme.accent)
                Spacer()
                Button(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "document.on.document") {
                    NSPasteboard.general.clearContents()
                    if NSPasteboard.general.setString(text, forType: .string) { copied = entry.day + "/" + entry.project }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel("Copy standup")
                .accessibilityIdentifier("diary-copy-standup")
            }
            Text(text)
                .font(.system(size: 15))
                .lineSpacing(4)
                .foregroundStyle(Theme.text)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .accessibilityIdentifier("diary-standup")
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func detail(_ section: DiarySection) -> some View {
        switch section.title {
        case "Waiting on":
            callout(section, icon: "hourglass", tint: Theme.Tint.amber.ink)
        case "Suggested next":
            callout(section, icon: "arrow.turn.down.right", tint: Theme.accent)
        default:
            VStack(alignment: .leading, spacing: 4) {
                Text(section.title.uppercased())
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(Theme.secondary)
                    .accessibilityAddTraits(.isHeader)
                if !section.text.isEmpty {
                    Text(section.text)
                        .font(.system(size: 14))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                sourceRow(section.sources ?? [])
            }
            .padding(.top, 2)
        }
    }

    private func callout(_ section: DiarySection, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(section.title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityAddTraits(.isHeader)
            if !section.text.isEmpty {
                Text(section.text)
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .foregroundStyle(Theme.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            sourceRow(section.sources ?? [])
        }
        .padding(.vertical, 10)
        .padding(.leading, 15)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack(alignment: .leading) {
                tint.opacity(0.07)
                tint.frame(width: 3)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    @ViewBuilder
    private func sourceRow(_ sources: [DiarySource]) -> some View {
        if !sources.isEmpty {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(Array(sources.enumerated()), id: \.offset) { _, source in sourceChip(source) }
            }
            .padding(.top, 2)
        }
    }

    private func sourceChip(_ source: DiarySource) -> some View {
        Link(destination: source.url) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold))
                // FlowLayout measures chips at their ideal width, so shorten long titles here; the full one is in the tooltip.
                Text(source.title.count > 48 ? String(source.title.prefix(47)) + "…" : source.title).lineLimit(1)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.text.opacity(0.8))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.block, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(source.title + "\n" + source.url.absoluteString)
    }

    // MARK: Data

    private func dateFor(_ key: String) -> Date {
        guard let day = try? Day.parse(key) else { return .now }
        return DiaryClock.date(day.midnight(zone))
    }

    private func dateFormat(_ style: Date.FormatStyle) -> Date.FormatStyle {
        var result = style
        result.timeZone = zone
        result.calendar = TimeZones.calendar(zone)
        return result
    }

    private func reload() {
        do {
            let db = try Schema.open(snapshot.database)
            let clock = try DiaryStore.clock(db)
            self.clock = clock
            let last = clock.workday(.now)
            currentDay = last.iso
            oldest = try DiaryStore.days(db).last
            entries = try DiaryStore.entries(db, from: last.adding(days: 1 - span).iso, through: last.iso)
            error = nil
        } catch {
            self.error = "Couldn’t load the diary. \(error.localizedDescription)"
        }
    }
}

private struct SetupTarget: Identifiable {
    let id = UUID()
    let project: String?
}

private struct DiaryEntryEditor: View {
    let database: String
    let entry: DiaryEntry
    let didSave: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var values: [String: String] = [:]
    @State private var overrides: [String: String] = [:]
    @State private var error: String?

    private var fields: [(key: String, title: String, text: String, generated: String)] {
        let core = [("headline", "Headline", entry.headline, entry.content.headline),
                    ("summary", "Summary", entry.summary, entry.content.summary),
                    ("standup", "Standup", entry.standup, entry.content.standup ?? "")]
        let details = DiaryContent.fields.map { field in
            let generated = entry.content[keyPath: field.value] ?? ""
            return (field.key, field.title, entry.edits[field.key] ?? generated, generated)
        }
        let custom = entry.customSections.map { section in
            ("section/" + section.title, section.title, section.text,
             entry.content.sections?.first(where: { $0.title == section.title })?.text ?? "")
        }
        return core + details + custom
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Edit \(entry.project) diary").font(.title2.bold())
            Text("Edited fields keep your wording when the agent refreshes the draft.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(fields, id: \.key) { field in
                        HStack {
                            Text(field.title).font(.headline)
                            Spacer()
                            if overrides[field.key] != nil {
                                Button("Use agent version") {
                                    values[field.key] = field.generated
                                    overrides[field.key] = nil
                                }
                                .buttonStyle(.link)
                            }
                        }
                        let binding = Binding(get: { values[field.key] ?? field.text }, set: { value in
                            guard value != (values[field.key] ?? field.text) else { return }
                            values[field.key] = value
                            if value == field.text {
                                overrides[field.key] = entry.edits[field.key]
                            } else {
                                overrides[field.key] = value == field.generated ? nil : value
                            }
                        })
                        TextField(field.title, text: binding, axis: .vertical)
                            .lineLimit(field.key == "headline" ? 1...3 : 2...8)
                            .accessibilityLabel(field.title)
                    }
                }
                .padding(.vertical, 4)
            }
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save edits") { save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 560, height: 540)
        .onAppear { overrides = entry.edits }
    }

    private func save() {
        do {
            let db = try Schema.open(database)
            try db.transaction { try DiaryStore.saveEdits(db, entry: entry, edits: overrides) }
            didSave()
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
