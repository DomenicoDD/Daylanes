import AppKit
import SwiftUI

/// Sets up a project's diary in one sheet: who writes it, what to look at, and when. Turning it on saves the
/// routine and installs the local schedule. Daylanes finds the agent's CLI and passes its Diary connection to
/// each run, so there is nothing to register or paste.
struct DiarySetupSheet: View {
    let database: String
    let projects: [Project]
    let didChange: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var project: String
    @State private var routine = DiaryRoutine(firstDay: "")
    @State private var saved: DiaryRoutine?
    @State private var installed: DiarySchedule.Runner?
    @State private var executable = ""
    @State private var locating = false
    @State private var folder = ""
    @State private var setTime = false
    @State private var runAt = "08:00"
    @State private var cutoff = "05:00"
    @State private var zone = ""
    @State private var showsWorkday = false
    @State private var attempt: DiarySchedule.Attempt?
    @State private var busy = false
    @State private var error: String?
    @State private var copied = false

    init(database: String, projects: [Project], project: String?, didChange: @escaping (String) -> Void) {
        self.database = database
        self.projects = projects
        self.didChange = didChange
        _project = State(initialValue: project.flatMap { name in projects.contains { $0.name == name } ? name : nil }
                         ?? projects.first?.name ?? "")
    }

    private var cli: String? { Bundle.main.url(forAuxiliaryExecutable: "TrackerCLI")?.path }
    private var isOn: Bool { installed != nil }
    private var canSubmit: Bool {
        !project.isEmpty && !routine.brief.pythonStripped.isEmpty && !executable.isEmpty && !folder.isEmpty
    }

    var body: some View {
        SheetFrame(title: project.isEmpty ? "Diary" : "\(project) diary",
                   chips: isOn ? ["On", routine.agent.title] : [],
                   subtitle: "An agent writes a daily entry and standup from your project's activity.",
                   primary: isOn ? "Save" : "Turn on", canSubmit: canSubmit, busy: busy, width: 580,
                   submit: { save() }) {
            if projects.isEmpty {
                Text("Create a project first, then give it a diary.").foregroundStyle(SheetTheme.muted)
            } else {
                form
            }
        } leading: {
            if isOn {
                Button("Turn off") { turnOff() }
                    .buttonStyle(SheetButtonStyle(kind: .destructive))
                    .disabled(busy)
                Button("Write now") { runNow() }
                    .buttonStyle(SheetButtonStyle(kind: .link))
                    .disabled(busy)
                    .help("Write any workday that is due now")
            }
        }
        .task { load() }
        .onChange(of: project) { _, _ in load() }
        .onChange(of: routine.agent) { old, new in if old != new { locate() } }
        .onReceive(DistributedNotificationCenter.default().publisher(for: DiaryStore.changed)) { _ in refreshStatus() }
    }

    @ViewBuilder
    private var form: some View {
        if projects.count > 1 {
            SheetField(label: "Project") {
                SheetMenu(selection: $project, groups: [projects.map { ($0.name, $0.name) }])
            }
        }
        SheetField(label: "Brief", note: "what to read and how to write") {
            TextEditor(text: $routine.brief)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(8)
                .frame(height: 150)
                .background(SheetTheme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SheetTheme.border))
                .accessibilityLabel("Diary brief")
            if routine.brief != DiaryRoutine.briefTemplate {
                Button("Restore the default brief") { routine.brief = DiaryRoutine.briefTemplate }
                    .buttonStyle(SheetButtonStyle(kind: .link))
            }
        }
        SheetGroup {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Write it from any agent").font(.system(size: 13, weight: .semibold))
                    Text("Paste one prompt into Codex, Claude Code or another agent. It gets the steps and this brief from Daylanes and saves the entry here.")
                        .font(.system(size: 12)).foregroundStyle(SheetTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(copied ? "Copied" : "Copy prompt", systemImage: copied ? "checkmark" : "doc.on.doc") { copyPrompt() }
                    .buttonStyle(SheetButtonStyle(kind: .primary))
                    .disabled(busy || project.isEmpty || routine.brief.pythonStripped.isEmpty)
                    .accessibilityIdentifier("diary-copy-prompt")
            }
        }
        Text("Or let Daylanes write it every day").font(.system(size: 13, weight: .semibold))
            .padding(.top, 4)
        SheetField(label: "Written by") {
            SheetSegments(selection: $routine.agent, options: DiaryAgent.allCases.map { ($0, $0.title) })
            agentLine
        }
        SheetField(label: "When") {
            SheetSegments(selection: $setTime, options: [(false, "When the workday ends"), (true, "At a set time")])
            HStack(spacing: 8) {
                if setTime {
                    SheetTextField(placeholder: "08:00", text: $runAt, mono: true).frame(width: 90)
                }
                Text(timing).font(.system(size: 12)).foregroundStyle(SheetTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(showsWorkday ? "Done" : "Change workday…") { showsWorkday.toggle() }
                    .buttonStyle(SheetButtonStyle(kind: .link))
            }
            if showsWorkday {
                SheetGroup {
                    HStack(spacing: 10) {
                        SheetField(label: "Workday ends at") {
                            SheetTextField(placeholder: "05:00", text: $cutoff, mono: true)
                        }
                        SheetField(label: "Time zone") {
                            SheetTextField(placeholder: "Europe/Rome", text: $zone)
                        }
                    }
                    Text("Applies to every diary. Work after midnight and before this time counts toward the previous day.")
                        .font(.system(size: 12)).foregroundStyle(SheetTheme.muted)
                }
            }
        }
        SheetField(label: "Works in", note: "the agent starts here") {
            HStack(spacing: 8) {
                Text(folder.isEmpty ? "Choose a folder" : (folder as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(folder.isEmpty ? SheetTheme.muted : Theme.text)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(FieldBox(focused: false))
                Button("Choose…") { chooseFolder() }
                    .buttonStyle(SheetButtonStyle(kind: .secondary))
            }
        }
        if let attempt { statusLine(attempt) }
        if let error {
            Label(error, systemImage: "exclamationmark.circle")
                .font(.system(size: 12)).foregroundStyle(Theme.recording)
                .fixedSize(horizontal: false, vertical: true)
        }
        if let saved, let cli {
            DisclosureGroup("Connect over MCP instead") {
                manualSetup(saved, cli: cli).padding(.top, 8)
            }
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(SheetTheme.label)
        }
    }

    @ViewBuilder
    private var agentLine: some View {
        HStack(spacing: 6) {
            if locating {
                ProgressView().controlSize(.small)
                Text("Looking for \(routine.agent.title)…")
            } else if executable.isEmpty {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.recording)
                Text("\(routine.agent.title) isn't installed, or Daylanes can't find it.")
            } else {
                Image(systemName: "checkmark.circle").foregroundStyle(.green)
                Text((executable as NSString).abbreviatingWithTildeInPath)
                    .font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button("Locate…") { chooseExecutable() }
                .buttonStyle(SheetButtonStyle(kind: .link))
                .disabled(locating)
        }
        .font(.system(size: 12))
        .foregroundStyle(SheetTheme.muted)
    }

    private func statusLine(_ attempt: DiarySchedule.Attempt) -> some View {
        let when = Date(timeIntervalSince1970: attempt.at).formatted(.relative(presentation: .named))
        let failed = !attempt.message.isEmpty
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            if attempt.running == true {
                ProgressView().controlSize(.small)
                Text("Writing now… started \(when).")
            } else {
                Image(systemName: failed ? "exclamationmark.circle" : "checkmark.circle")
                    .foregroundStyle(failed ? Theme.recording : .green)
                Text(failed ? "Last run \(when): \(attempt.message)" : "Last run \(when) saved the diary.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if let saved, FileManager.default.fileExists(atPath: DiarySchedule.logURL(saved.id).path) {
                Button("Run log") { NSWorkspace.shared.open(DiarySchedule.logURL(saved.id)) }
                    .buttonStyle(SheetButtonStyle(kind: .link))
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(SheetTheme.muted)
    }

    private func manualSetup(_ saved: DiaryRoutine, cli: String) -> some View {
        let name = DiarySchedule.manualServer(saved.id)
        let command = AgentMCPCommand(executable: cli, database: database, diaryRoutine: saved.id)
        let prefix = saved.agent == .codex ? "codex mcp add \(name)" : "claude mcp add --scope user --transport stdio \(name)"
        return VStack(alignment: .leading, spacing: 10) {
            Text("Register this project's Diary connection, then send the instruction from any \(saved.agent.title) conversation that should write it.")
                .font(.system(size: 12)).foregroundStyle(SheetTheme.muted)
            SetupCodeBlock(title: "Registration command", values: [command.registration(using: prefix)])
            SetupCodeBlock(title: "Instruction", values: [DiarySchedule.instruction(server: name)])
        }
    }

    private var timing: String {
        guard let end = try? DiaryClock.minutes(cutoff) else { return "Workdays end at \(cutoff)." }
        let zoneLabel = zone.isEmpty ? "" : " (\(zone))"
        guard setTime else { return "Writes each day at \(cutoff)\(zoneLabel), when the workday ends." }
        guard let run = try? DiaryClock.minutes(runAt) else { return "Use a time like 08:00." }
        return run < end
            ? "Drafts at \(runAt), then refreshes after the workday ends at \(cutoff)."
            : "Writes the finished workday at \(runAt)\(zoneLabel)."
    }

    private func load() {
        error = nil
        guard !project.isEmpty else { return }
        do {
            let db = try Schema.open(database)
            let clock = try DiaryStore.clock(db)
            saved = try DiaryStore.routine(db, project: project)
            routine = saved ?? DiaryRoutine(firstDay: clock.calendarDay(.now).adding(days: -1).iso)
            zone = clock.zone.identifier
            cutoff = DiaryClock.label(clock.cutoff)
            setTime = routine.runMinute != nil
            runAt = DiaryClock.label(routine.runMinute ?? 480)
            installed = saved.flatMap { DiarySchedule.installed($0.id, database: database) }
            folder = installed?.directory ?? projects.first { $0.name == project }?.folders.first
                ?? FileManager.default.homeDirectoryForCurrentUser.path
            if let installed, installed.agent == routine.agent {
                executable = installed.executable
                locating = false
            } else {
                locate()
            }
            refreshStatus()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func locate() {
        let agent = routine.agent
        let target = project
        if let installed, installed.agent == agent {
            executable = installed.executable
            locating = false
            return
        }
        locating = true
        executable = ""
        Task.detached {
            let found = DiarySchedule.locate(agent)
            await MainActor.run {
                // A lookup started for another project or agent no longer applies.
                guard routine.agent == agent, project == target else { return }
                executable = found ?? ""
                locating = false
            }
        }
    }

    /// Saves the routine. With `schedule`, also installs or updates the local schedule.
    private func save(schedule: Bool = true) {
        guard let cli else {
            error = "This Daylanes build is missing its command-line tool."
            return
        }
        busy = true
        defer { busy = false }
        do {
            let clock = DiaryClock(zone: try Values.zone(zone.pythonStripped), cutoff: try DiaryClock.minutes(cutoff))
            var value = routine
            value.runMinute = setTime ? try DiaryClock.minutes(runAt) : nil
            if saved == nil { value.firstDay = clock.calendarDay(.now).adding(days: -1).iso }
            // Saving without the schedule keeps the scheduled agent, so a running schedule doesn't stop matching.
            if !schedule, let installed { value.agent = installed.agent }
            let runner = DiarySchedule.Runner(agent: value.agent, executable: executable, directory: folder)
            if schedule { try DiarySchedule.validate(runner) }
            let db = try Schema.open(database)
            try db.transaction {
                try DiaryStore.saveClock(db, clock)
                try DiaryStore.saveRoutine(db, project: project, value)
            }
            if schedule, installed != runner {
                try DiarySchedule.install(value.id, database: database, cli: cli, runner: runner)
            }
            didChange(project)
            if schedule { dismiss() } else { load() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Saves the brief, then copies a prompt that has the agent run `diary guide` for this project.
    private func copyPrompt() {
        guard let cli else {
            error = "This Daylanes build is missing its command-line tool."
            return
        }
        error = nil
        save(schedule: false)
        guard error == nil, let saved else { return }
        NSPasteboard.general.clearContents()
        copied = NSPasteboard.general.setString(DiaryGuide.prompt(project: project, routine: saved.id, cli: cli,
                                                                  database: database), forType: .string)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { copied = false }
    }

    private func turnOff() {
        guard let saved else { return }
        do {
            try DiarySchedule.uninstall(saved.id)
            installed = nil
            didChange(project)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Starts a run in the background, the same way the schedule does, without the pause after a failed run.
    private func runNow() {
        guard let saved, let installed, let cli else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["diary-run", database, saved.id.uuidString, installed.agent.rawValue,
                             installed.executable, installed.directory, "--force"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            error = nil
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { refreshStatus() }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func refreshStatus() {
        guard let saved, let db = try? Database.readOnly(database) else { attempt = nil; return }
        attempt = try? DiarySchedule.lastAttempt(db, routine: saved.id)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if !folder.isEmpty { panel.directoryURL = URL(fileURLWithPath: folder) }
        panel.begin { response in
            if response == .OK, let url = panel.url { folder = url.path }
        }
    }

    private func chooseExecutable() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose the \(routine.agent.title) command-line tool"
        panel.begin { response in
            if response == .OK, let url = panel.url { executable = url.path }
        }
    }
}
