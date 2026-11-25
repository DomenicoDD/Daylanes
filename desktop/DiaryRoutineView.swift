import SwiftUI

struct DiaryRoutineView: View {
    let database: String
    let projects: [Project]
    let initialProject: String?
    let openDiary: (String) -> Void

    @State private var project = ""
    @State private var routine: DiaryRoutine?
    @State private var saved: DiaryRoutine?
    @State private var zone = ""
    @State private var cutoff = ""
    @State private var scheduled = false
    @State private var runAt = "03:00"
    @State private var baseline: Settings?
    @State private var executable = ""
    @State private var directory = ""
    @State private var session = ""
    @State private var installed: DiarySchedule.Conversation?
    @State private var status: String?
    @State private var error: String?
    @State private var notice: String?

    private struct Settings: Equatable {
        var agent: DiaryAgent
        var brief: String
        var zone: String
        var cutoff: String
        var scheduled: Bool
        var runAt: String
    }

    private var settings: Settings? {
        routine.map { Settings(agent: $0.agent, brief: $0.brief, zone: zone, cutoff: cutoff, scheduled: scheduled, runAt: runAt) }
    }

    private var dirty: Bool { settings != baseline }
    private var cli: String? { Bundle.main.url(forAuxiliaryExecutable: "TrackerCLI")?.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Project routine").font(.system(.largeTitle, design: .serif).weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Button("View project diary") { openDiary(project) }
                    .disabled(project.isEmpty)
            }
            if projects.isEmpty {
                Text("Create a Daylanes project to give it a diary routine.").foregroundStyle(.secondary)
            } else {
                Picker("Project", selection: $project) {
                    ForEach(projects) { Text($0.name).tag($0.name) }
                }
                .disabled(dirty)
                if let routine {
                    briefForm(routine)
                    if let saved, !dirty {
                        Divider()
                        agentSetup(saved)
                    }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red)
            }
            if let notice {
                Label(notice, systemImage: "checkmark.circle").foregroundStyle(.secondary)
            }
        }
        .task {
            project = initialProject.flatMap { name in projects.contains { $0.name == name } ? name : nil }
                ?? projects.first?.name ?? ""
            if !project.isEmpty { load() }
        }
        .onChange(of: project) { _, _ in load() }
        .onReceive(DistributedNotificationCenter.default().publisher(for: DiaryStore.changed)) { _ in refreshStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refreshStatus() }
    }

    private func briefForm(_ value: DiaryRoutine) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("In Daylanes").font(.headline).accessibilityAddTraits(.isHeader)
            Picker("Writing agent", selection: Binding(get: { value.agent }, set: { routine?.agent = $0 })) {
                ForEach(DiaryAgent.allCases) { Text($0.title).tag($0) }
            }
            HStack {
                Text("Project brief").font(.callout.weight(.medium))
                Spacer()
                if value.brief != DiaryRoutine.briefTemplate {
                    Button("Use template") { routine?.brief = DiaryRoutine.briefTemplate }
                        .buttonStyle(.link)
                }
            }
            Text("Save the template as-is or add details such as specific repos, Slack channels, and sections. The agent reads the saved brief on every run.")
                .font(.callout).foregroundStyle(.secondary)
            TextEditor(text: Binding(get: { value.brief }, set: { routine?.brief = $0 }))
                .font(.body)
                .padding(5)
                .frame(minHeight: 180)
                .scrollContentBackground(.hidden)
                .background(Theme.block.opacity(0.65), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityLabel("Project diary brief")
            Picker("Run this project", selection: $scheduled) {
                Text("First morning availability").tag(false)
                Text("At a set time").tag(true)
            }
            if scheduled {
                TextField("Run at (HH:mm)", text: $runAt).frame(maxWidth: 230)
            }
            TextField("Workday starts at (HH:mm)", text: $cutoff).frame(maxWidth: 280)
            TextField("Diary time zone", text: $zone, prompt: Text("Europe/Rome")).frame(maxWidth: 280)
            Text(timingNote)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.block, in: RoundedRectangle(cornerRadius: 7))
            HStack {
                Button("Save routine") { save() }.buttonStyle(.borderedProminent)
                    .disabled(value.brief.pythonStripped.isEmpty || (saved != nil && !dirty))
                if dirty { Button("Discard changes") { load() } }
            }
        }
    }

    private var timingNote: String {
        guard let boundary = try? DiaryClock.minutes(cutoff) else {
            return "The cutoff and time zone apply across your diary."
        }
        let example = 3 * 60 + 15 < boundary ? "Tuesday" : "Wednesday"
        let timing: String
        if scheduled, let run = try? DiaryClock.minutes(runAt) {
            timing = run < boundary
                ? "At \(runAt), the agent can save an early draft and refresh it after \(cutoff)."
                : "At \(runAt), the completed workday is ready to write."
        } else {
            timing = "The completed day is ready to write at \(cutoff)."
        }
        return "Wednesday at 03:15 belongs to \(example). \(timing) The cutoff and time zone apply across your diary."
    }

    @ViewBuilder
    private func agentSetup(_ saved: DiaryRoutine) -> some View {
        if let cli {
            let command = AgentMCPCommand(executable: cli, database: database, diaryRoutine: saved.id)
            let name = DiarySchedule.serverName(saved.id)
            let prefix = saved.agent == .codex ? "codex mcp add \(name)" : "claude mcp add --scope user --transport stdio \(name)"
            VStack(alignment: .leading, spacing: 12) {
                Text("In \(saved.agent.title)").font(.headline).accessibilityAddTraits(.isHeader)
                Text("Run the registration command in Terminal, then open a dedicated local conversation in your project folder. Connect and authorize the sources named in your prompt. Paste the standing instruction into that conversation once.")
                    .foregroundStyle(.secondary)
                Text("This project’s MCP connection exposes two tools. get_diary_work reads the brief and due draft. submit_diary_entry saves the result.")
                    .font(.callout).foregroundStyle(.secondary)
                DisclosureGroup("MCP registration and standing instruction") {
                    VStack(alignment: .leading, spacing: 10) {
                        SetupCodeBlock(title: "Registration command", values: [command.registration(using: prefix)])
                        SetupCodeBlock(title: "Standing instruction", values: [DiarySchedule.instruction(saved.id)])
                    }
                    .padding(.top, 8)
                }
                Divider()
                Text("Local schedule").font(.headline).accessibilityAddTraits(.isHeader)
                if let installed {
                    Label(installed.agent == saved.agent ? "Schedule enabled" : "Schedule needs to be updated",
                          systemImage: installed.agent == saved.agent ? "clock.badge.checkmark" : "exclamationmark.circle")
                    Text("Conversation \(installed.session.uuidString.lowercased())")
                        .font(.caption.monospaced()).textSelection(.enabled)
                    if let status, !status.isEmpty { Text(status).foregroundStyle(.secondary) }
                    Button("Turn off schedule") { disable(saved) }
                } else {
                    Text("Enter the ID of that conversation and the folder where you opened it. Daylanes will resume it when the workday is due, including after wake or sign-in. Use a local conversation that can access its sources in an unattended run.")
                        .foregroundStyle(.secondary)
                    TextField("Conversation ID", text: $session)
                    TextField("Agent executable", text: $executable, prompt: Text("Full path from command -v \(saved.agent.rawValue)"))
                    HStack {
                        TextField("Conversation folder", text: $directory)
                        Button("Choose…") { chooseFolder() }
                    }
                    Button("Enable local schedule") { enable(saved, cli: cli) }
                        .disabled(session.pythonStripped.isEmpty || directory.pythonStripped.isEmpty || executable.pythonStripped.isEmpty)
                }
            }
        } else {
            Text("This Daylanes build is missing the command-line tool.").foregroundStyle(.secondary)
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.begin { response in
            if response == .OK, let url = panel.url { directory = url.path }
        }
    }

    private func load() {
        notice = nil
        error = nil
        do {
            let db = try Schema.open(database)
            let clock = try DiaryStore.clock(db)
            saved = try DiaryStore.routine(db, project: project)
            routine = saved ?? DiaryRoutine(firstDay: clock.calendarDay(.now).adding(days: -1).iso)
            zone = clock.zone.identifier
            cutoff = DiaryClock.label(clock.cutoff)
            scheduled = routine?.runMinute != nil
            runAt = DiaryClock.label(routine?.runMinute ?? 180)
            baseline = settings
            installed = saved.flatMap { DiarySchedule.installed($0.id, database: database) }
            executable = installed?.executable ?? ""
            directory = installed?.directory ?? projects.first { $0.name == project }?.folders.first ?? ""
            session = installed?.session.uuidString.lowercased() ?? ""
            refreshStatus()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func save() {
        guard var routine else { return }
        do {
            let clock = DiaryClock(zone: try Values.zone(zone.pythonStripped), cutoff: try DiaryClock.minutes(cutoff))
            routine.runMinute = scheduled ? try DiaryClock.minutes(runAt) : nil
            if saved == nil { routine.firstDay = clock.calendarDay(.now).adding(days: -1).iso }
            let db = try Schema.open(database)
            try db.transaction {
                try DiaryStore.saveClock(db, clock)
                try DiaryStore.saveRoutine(db, project: project, routine)
            }
            load()
            notice = "Routine saved"
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func enable(_ saved: DiaryRoutine, cli: String) {
        guard let id = UUID(uuidString: session.pythonStripped) else {
            error = "Enter the local conversation’s UUID."
            return
        }
        do {
            let conversation = DiarySchedule.Conversation(agent: saved.agent, executable: executable.pythonStripped,
                                                          directory: directory.pythonStripped, session: id)
            try DiarySchedule.install(saved.id, database: database, cli: cli, conversation: conversation)
            installed = conversation
            notice = nil
            error = nil
            refreshStatus()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func disable(_ saved: DiaryRoutine) {
        do {
            try DiarySchedule.uninstall(saved.id)
            installed = nil
            notice = nil
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func refreshStatus() {
        guard let saved, let db = try? Database.readOnly(database) else { return }
        status = try? DiarySchedule.status(db, routine: saved.id)
    }
}
