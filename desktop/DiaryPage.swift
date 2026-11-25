import SwiftUI

struct DiaryPage: View {
    let snapshot: Snapshot
    @State private var day: String?
    @State private var days: [String] = []
    @State private var currentDay: String?
    @State private var entries: [DiaryEntry] = []
    @State private var clock: DiaryClock?
    @State private var client: String?
    @State private var project: String?
    @State private var setup: SetupTarget?
    @State private var editing: DiaryEntry?
    @State private var copied = false
    @State private var error: String?

    private var filteredProjects: [Project] {
        snapshot.projects.filter { client == nil || $0.client == client }
    }

    private var pageData: DiaryPageData { DiaryPageData(entries, client: client, project: project) }
    private var zone: TimeZone { clock?.zone ?? TimeZone(identifier: snapshot.timezone) ?? .current }

    var body: some View {
        HStack(spacing: 0) {
            index
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) { reading }
                .padding(24)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .accessibilityIdentifier("diary-page")
        .task(id: snapshot.database) { reload() }
        .onReceive(DistributedNotificationCenter.default().publisher(for: DiaryStore.changed)) { _ in reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in reload() }
        .onChange(of: day) { _, _ in reload() }
        .onChange(of: snapshot.projects.map(\.name)) { _, names in
            if let project, !names.contains(project) { self.project = nil }
        }
        .onChange(of: pageData.standup) { _, _ in copied = false }
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

    private var index: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Diary", systemImage: "book")
                .font(.headline)
                .accessibilityAddTraits(.isHeader)
            if let currentDay {
                let date = Binding(get: { dateFor(day ?? currentDay) }, set: {
                    day = Day.local(DiaryClock.millis($0), zone).iso
                })
                DatePicker("Work date", selection: date, in: ...dateFor(currentDay), displayedComponents: .date)
                    .labelsHidden()
                    .accessibilityLabel("Work date")
                    .environment(\.timeZone, zone)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    let months = Dictionary(grouping: days, by: { String($0.prefix(7)) })
                    ForEach(months.keys.sorted(by: >), id: \.self) { month in
                        if let dates = months[month], let first = dates.first {
                            Text(dateFor(first), format: dateFormat(.dateTime.month(.wide).year()))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                                .padding(.top, 8)
                            ForEach(dates, id: \.self) { dateButton($0) }
                        }
                    }
                }
            }
            Button {
                setup = SetupTarget(project: project)
            } label: {
                Label("Set up diary…", systemImage: "gearshape")
            }
            .buttonStyle(.plain)
            .disabled(snapshot.projects.isEmpty)
            .padding(.vertical, 6)
        }
        .padding(14)
        .frame(width: 150)
        .background(Theme.block.opacity(0.5))
    }

    private func dateButton(_ value: String) -> some View {
        let selected = day == value
        return Button {
            day = value
        } label: {
            HStack(spacing: 7) {
                Text(dateFor(value), format: dateFormat(.dateTime.day()))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(dateFor(value), format: dateFormat(.dateTime.weekday(.wide)))
                Spacer(minLength: 0)
            }
            .font(.callout.weight(selected ? .semibold : .regular))
            .padding(.vertical, 6)
            .padding(.horizontal, 4)
            .background(selected ? Theme.blockHover : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(dateFor(value), format: dateFormat(.dateTime.weekday(.wide).month(.wide).day().year())))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var reading: some View {
        if let day {
            ViewThatFits(in: .horizontal) {
                HStack { dateHeading(day); Spacer(minLength: 14); filters }
                VStack(alignment: .leading, spacing: 10) { dateHeading(day); filters }
            }
            Divider()
        }
        if let error {
            Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.secondary)
            Button("Retry", action: reload)
        } else if day == nil {
            ProgressView("Loading diary…")
        } else if pageData.entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Awaiting a diary entry").font(.title2.bold())
                Text("No draft has arrived for \(project ?? client ?? "these projects") for this workday.")
                    .foregroundStyle(.secondary)
                Button(project.map { "Set up the \($0) diary" } ?? "Set up a project diary") {
                    setup = SetupTarget(project: project)
                }
                .buttonStyle(.link)
            }
        } else {
            if pageData.entries.count == 1, let entry = pageData.entries.first {
                entryHeading(entry)
            } else {
                Text("Workday notes").font(.system(.largeTitle, design: .serif).weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
            }
            standupPanel
            ForEach(pageData.entries) { entry in
                if pageData.entries.count > 1 {
                    Divider()
                    entryHeading(entry)
                }
                entryDetails(entry)
            }
        }
    }

    private func dateHeading(_ date: String) -> some View {
        Text(dateFor(date), format: dateFormat(.dateTime.weekday(.wide).day().month(.wide).year()))
            .font(.callout.weight(.medium))
            .foregroundStyle(.secondary)
            .fixedSize()
    }

    private var filters: some View {
        HStack(spacing: 8) {
            Picker("Client", selection: $client) {
                Text("All clients").tag(nil as String?)
                ForEach(snapshot.clients, id: \.self) { Text($0).tag(Optional($0)) }
            }
            .accessibilityLabel("Filter by client")
            .onChange(of: client) { _, _ in
                if !filteredProjects.contains(where: { $0.name == project }) { project = nil }
            }
            Picker("Project", selection: $project) {
                Text("All projects").tag(nil as String?)
                ForEach(filteredProjects) { Text($0.name).tag(Optional($0.name)) }
            }
            .accessibilityLabel("Filter by project")
        }
        .labelsHidden()
        .fixedSize(horizontal: true, vertical: false)
    }

    private var standupPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Standup draft", systemImage: "mic").font(.headline)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button(copied ? "Copied" : "Copy", systemImage: "document.on.document") {
                    NSPasteboard.general.clearContents()
                    copied = NSPasteboard.general.setString(pageData.standup, forType: .string)
                }
                .controlSize(.small)
                .accessibilityLabel("Copy standup")
                .accessibilityIdentifier("diary-copy-standup")
                .disabled(pageData.standup.isEmpty)
            }
            if pageData.standup.isEmpty {
                Text("This selection has no standup draft.").font(.callout).foregroundStyle(.secondary)
            } else {
                Text(pageData.standup)
                    .font(.system(size: 16))
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("diary-standup")
                    .id(pageData.standup)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.block, in: RoundedRectangle(cornerRadius: Theme.blockRadius))
    }

    private func entryHeading(_ entry: DiaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(entry.project).font(.callout.weight(.medium)).foregroundStyle(.secondary)
                if entry.early {
                    Label("Early draft", systemImage: "clock")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("This workday has not yet been refreshed through its cutoff.")
                }
                Spacer()
                Button("Edit…", systemImage: "pencil") { editing = entry }
                    .controlSize(.small)
                    .accessibilityLabel("Edit \(entry.project) diary")
            }
            Text(entry.headline).font(.system(.largeTitle, design: .serif).weight(.semibold))
                .accessibilityAddTraits(.isHeader)
                .textSelection(.enabled)
        }
    }

    private func entryDetails(_ entry: DiaryEntry) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if !entry.summary.isEmpty {
                Text(entry.summary).lineSpacing(3).textSelection(.enabled)
            }
            ForEach(Array(entry.details.enumerated()), id: \.offset) { _, section in
                VStack(alignment: .leading, spacing: 5) {
                    Text(section.title).font(.headline).accessibilityAddTraits(.isHeader)
                    if !section.text.isEmpty {
                        Text(section.text).lineSpacing(3).textSelection(.enabled)
                    }
                    sourceLinks(section.sources ?? [])
                }
            }
            if let sources = entry.content.sources, !sources.isEmpty {
                DisclosureGroup("Sources") { sourceLinks(sources).padding(.top, 6) }
                    .font(.callout.weight(.medium))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceLinks(_ sources: [DiarySource]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                Link(destination: source.url) { Label(source.title, systemImage: "arrow.up.right") }
                    .font(.callout)
                    .help(source.url.absoluteString)
            }
        }
    }

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
            let current = clock.workday(.now).iso
            currentDay = current
            let stored = try DiaryStore.days(db)
            let initial = stored.first ?? clock.calendarDay(.now).adding(days: -1).iso
            let selection = day ?? initial
            day = selection
            days = Set(stored + [current, initial, selection]).sorted(by: >)
            entries = try DiaryStore.entries(db, day: selection)
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
