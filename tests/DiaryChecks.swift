import Foundation

// xcrun swiftc -parse-as-library core/*.swift tests/DiaryChecks.swift -o /tmp/diary-check && /tmp/diary-check
@main
struct DiaryChecks {
    static func check(_ condition: @autoclosure () throws -> Bool, _ message: String, line: Int = #line) throws {
        if try !condition() { throw EngineError.invalid("Line \(line): \(message)") }
    }

    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("diary-checks-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("ledger.sqlite3").path
        let db = try Schema.open(path)
        let rome = TimeZone(identifier: "Europe/Rome")!
        let clock = DiaryClock(zone: rome, cutoff: 300)
        try DiaryStore.saveClock(db, clock)
        let tuesday = try Day.parse("2025-11-25")
        let wednesday = tuesday.adding(days: 1)
        let thursday = tuesday.adding(days: 2)
        let early = clock.instant(wednesday, at: 195)
        let cutoff = clock.instant(wednesday, at: 300)

        try check(clock.workday(early) == tuesday && clock.workday(cutoff) == wednesday, "overnight boundary")
        let spring = clock.window(try Day.parse("2026-03-28"))
        let autumn = clock.window(try Day.parse("2026-10-24"))
        try check(spring.end - spring.start == 23 * 3_600_000 && autumn.end - autumn.start == 25 * 3_600_000,
                  "daylight saving uses wall clock cutoffs")
        let changeover = try Day.parse("2026-10-25")
        let ambiguous = DiaryClock(zone: rome, cutoff: 150).window(changeover)
        let first = try Day.parse("2026-03-29")
        let skipped = DiaryClock(zone: rome, cutoff: 150).window(first)
        try check(ambiguous.start == clock.window(changeover).start - 210 * 60_000
                  && skipped.start == clock.window(first).start - 2 * 3_600_000,
                  "ambiguous cutoff uses its first occurrence and skipped cutoff uses next valid wall time")

        let evening = DiaryClock(zone: rome, cutoff: 23 * 60)
        let lateWindow = evening.window(wednesday)
        try check(evening.namesByEnd && lateWindow.start == DiaryClock.millis(evening.instant(tuesday, at: 1380))
                  && lateWindow.end == DiaryClock.millis(evening.instant(wednesday, at: 1380))
                  && evening.workday(evening.instant(wednesday, at: 600)) == wednesday
                  && evening.workday(evening.instant(wednesday, at: 1380)) == thursday,
                  "a late cutoff names the workday after the day it ends on")
        try check(DiaryGuide.workday(evening).contains("Monday 23:00 to Tuesday 23:00")
                  && DiaryGuide.dailyRun(evening) == "23:05" && DiaryGuide.dailyRun(clock) == "05:05",
                  "the guide explains the naming and suggests a run just after the cutoff")

        let project = "Orchard"
        let peer = "Seedlings"
        let other = "Beacon"
        for (project, client) in [(project, "Example Gardens"), (peer, "Example Gardens"), (other, "Example Studio")] {
            try Store.createProject(db, name: project, client: client, kind: "billable", folder: nil)
        }
        var routine = DiaryRoutine(brief: "Lead with decisions.", runMinute: 180, firstDay: tuesday.iso)
        let peerRoutine = DiaryRoutine(firstDay: tuesday.iso)
        let otherRoutine = DiaryRoutine(brief: "Review the illustrations.", firstDay: tuesday.iso)
        try DiaryStore.saveRoutine(db, project: project, routine)
        try DiaryStore.saveRoutine(db, project: peer, peerRoutine)
        try DiaryStore.saveRoutine(db, project: other, otherRoutine)

        func due(_ time: Date, for profile: DiaryRoutine = routine) throws -> DiaryStore.Work? {
            try DiaryStore.work(db, project: project, routine: profile, now: time)
        }
        try check(try due(clock.instant(wednesday, at: 179)) == nil, "set time has not arrived")
        try check(try due(early)?.day == tuesday && due(early)?.through == DiaryClock.millis(early), "03:00 run has an early window")
        try check(try due(early, for: peerRoutine) == nil && due(cutoff, for: peerRoutine)?.day == tuesday,
                  "morning waits for the cutoff")
        let lateRoutine = DiaryRoutine(brief: "Write at eight.", runMinute: 480, firstDay: tuesday.iso)
        try check(try due(cutoff, for: lateRoutine) == nil && due(clock.instant(wednesday, at: 480), for: lateRoutine)?.day == tuesday,
                  "a run time after cutoff waits for the chosen time")

        let source = DiarySource(title: "Synthetic rehearsal notes", url: URL(string: "https://example.com/orchard/rehearsal")!)
        let initial = DiaryContent(headline: "Rehearsal completed", summary: "Two fixtures were checked.",
                                   standup: "I checked the draft fixtures.", sources: [source])
        guard let earlyWork = try due(early) else { throw EngineError.invalid("Missing early work") }
        _ = try db.transaction {
            try DiaryStore.submit(db, project: project, work: earlyWork, through: earlyWork.through, revision: 0, content: initial)
        }
        try check(try due(early) == nil, "an early draft waits for cutoff")
        guard let wake = try due(clock.instant(thursday, at: 615)), let earlyEntry = wake.draft else {
            throw EngineError.invalid("Missed final draft did not catch up")
        }
        try check(wake.day == tuesday && wake.through == earlyWork.window.end && earlyEntry.early,
                  "wake or sign-in offers the oldest unfinished day as a full refresh")
        try DiaryStore.saveEdits(db, entry: earlyEntry, edits: ["standup": "I rehearsed the fixtures with the team.",
                                                               "section/Discussion": "Ask about the spare fixture."])

        func session(_ profile: DiaryRoutine?, access: MCP.Access = .write) -> MCP.Session {
            var session = MCP.Session(options: .init(databasePath: path, access: access, diaryRoutine: profile?.id))
            let request = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}"
            _ = MCP.answer(request, session: &session)
            return session
        }
        func call(_ name: String, _ arguments: JSON = .object([]), using session: inout MCP.Session) throws -> JSON {
            let request = JSON.object([("jsonrpc", .string("2.0")), ("id", .int(2)), ("method", .string("tools/call")),
                                       ("params", .object([("name", .string(name)), ("arguments", arguments)]))])
            let reply = MCP.answer(request.pythonText(indent: nil), session: &session) ?? "{}"
            return try JSON.parse(reply)
        }

        var writer = session(routine)
        try check(writer.tools.map(\.name) == ["get_diary_work", "submit_diary_entry"], "diary writer exposes only two tools")
        try check(session(routine, access: .read).tools.map(\.name) == ["get_diary_work"], "read-only writer scope")
        try check(!session(nil).tools.contains { $0.toolset == "diary" }, "ordinary setup access cannot read prompts or write drafts")
        try check(try call("set_up_project", using: &writer)["error"]["code"].intValue == -32602, "diary cannot mutate the ledger")
        let requested: JSON = .object([("work_date", .string(tuesday.iso))])
        var defaultWriter = session(peerRoutine)
        let defaultBrief = try call("get_diary_work", requested, using: &defaultWriter)["result"]["structuredContent"]["data"]["brief"].stringValue
        try check(defaultBrief == DiaryRoutine.briefTemplate && defaultBrief?.contains("80–110 words") == true
                  && defaultBrief?.contains("notes, transcripts, or documented follow-ups") == true
                  && defaultBrief?.contains("Check that each blocker is still open") == true,
                  "a newly saved diary guides the writer on evidence, blockers and standup length")
        let instruction = DiarySchedule.instruction()
        try check(instruction.contains(DiarySchedule.server) && instruction.contains("get_diary_work({})")
                  && instruction.contains("submit_diary_entry") && instruction.contains("work_date, window, through and revision")
                  && instruction.contains("data.brief"), "the standing instruction points to the scoped tools and the live brief")
        let badProject: JSON = .object([("project", .string(other))])
        try check(try call("get_diary_work", badProject, using: &writer)["result"]["isError"].boolValue == true,
                  "the writer cannot supply another project")
        routine.brief = "Keep the spoken update to one sentence."
        try DiaryStore.saveRoutine(db, project: project, routine)
        let context = try call("get_diary_work", requested, using: &writer)["result"]["structuredContent"]["data"]
        let work = context["work"]
        try check(context["project"]["name"].stringValue == project && context["brief"].stringValue == routine.brief,
                  "an existing session fetches the updated brief")
        try check(work["start_inclusive"].stringValue == "2025-11-25T05:00:00+01:00"
                  && work["end_exclusive"].stringValue == "2025-11-26T05:00:00+01:00"
                  && work["draft"]["early"].boolValue == true, "MCP returns the exact interval and saved draft")

        let refreshed: JSON = try JSON.parse("""
            {"headline":"Rehearsal signed off","summary":"The workshop approved the test fixtures.",
             "standup":"Agent wording","outcomes":"Fixtures approved.","decisions":"Keep the sample short.",
             "blockers":"Waiting on the spare part.","next_steps":"Rehearse the handoff.",
             "sections":[{"title":"Discussion","text":"Review all fixtures.","sources":[{"title":"Synthetic rehearsal notes",
             "url":"https://example.com/orchard/rehearsal"}]}]}
            """)
        var submitted: JSON = .object([
            ("work_date", work["work_date"]), ("window", work["window"]), ("through", work["through"]),
            ("revision", work["revision"]), ("entry", refreshed),
        ])
        let result = try call("submit_diary_entry", submitted, using: &writer)["result"]["structuredContent"]["data"]
        try check(result["changed"].boolValue == true && result["early"].boolValue == false, "late draft refreshes the existing date")
        let retry = try call("submit_diary_entry", submitted, using: &writer)["result"]["structuredContent"]["data"]
        try check(retry["changed"].boolValue == false && retry["revision"] == result["revision"], "duplicate retry is a no-op")
        var stale = refreshed
        stale.set("summary", .string("An older writer tried to overwrite the final draft."))
        submitted.set("entry", stale)
        try check(try call("submit_diary_entry", submitted, using: &writer)["result"]["isError"].boolValue == true,
                  "concurrent stale writer cannot overwrite a newer draft")
        let next = try due(clock.instant(thursday, at: 615))
        try check(next?.day == wednesday, "catch-up continues to the next missed day")
        guard let final = try DiaryStore.entry(db, project: project, day: tuesday.iso) else {
            throw EngineError.invalid("Missing final diary")
        }
        try check(final.content.summary == "The workshop approved the test fixtures."
                  && final.standup == "I rehearsed the fixtures with the team."
                  && final.customSections.first?.text == "Ask about the spare fixture.", "agent refresh preserves user edits")

        for (profile, text) in [(peerRoutine, "I wrote workshop notes."), (otherRoutine, "I reviewed the cover artwork.")] {
            var writer = session(profile)
            let work = try call("get_diary_work", requested, using: &writer)["result"]["structuredContent"]["data"]["work"]
            let entry = try JSON.parse(DiaryStore.encode(DiaryContent(headline: "Synthetic outcome", summary: text, standup: text,
                sources: [.init(title: "Synthetic reference", url: URL(string: "https://example.com/\(profile.id)")!)])))
            let args = JSON.object([("work_date", work["work_date"]), ("window", work["window"]), ("through", work["through"]),
                                    ("revision", work["revision"]), ("entry", entry)])
            try check(try call("submit_diary_entry", args, using: &writer)["result"]["isError"].boolValue == false, "seed another diary over MCP")
        }
        let entries = try DiaryStore.entries(db, day: tuesday.iso)
        let byClient = DiaryPageData(entries, client: "Example Gardens", project: nil)
        let selected = DiaryPageData(entries, client: "Example Gardens", project: project)
        try check(entries.count == 3 && byClient.entries.count == 2 && !byClient.standup.contains("artwork"), "client scopes all entries")
        try check(selected.standup == final.standup && selected.entries.flatMap { $0.content.allSources } == [source]
                  && selected.entries.flatMap(\.details).map(\.title).contains("Suggested next"), "project scopes copy, details and sources")

        let ranged = try DiaryStore.entries(db, from: tuesday.adding(days: -3).iso, through: thursday.iso)
        let rows = DiaryTimeline.rows(ranged, from: tuesday.adding(days: -3), through: thursday)
        try check(ranged.count == entries.count && rows.map(\.id) == ["quiet/" + thursday.iso, "quiet/" + wednesday.iso,
                  tuesday.iso, "quiet/" + tuesday.adding(days: -3).iso], "timeline keeps today apart and folds quiet days")
        if case let .quiet(from, to) = rows[3] {
            try check(from == tuesday.adding(days: -3).iso && to == tuesday.adding(days: -1).iso, "quiet stretch spans its days")
        }

        let fake = root.appendingPathComponent("fake-agent")
        let marker = root.appendingPathComponent("receipt")
        try "#!/bin/sh\nprintf '%s\\n' \"$@\" > receipt\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fake.path)
        let runner = DiarySchedule.Runner(agent: .codex, executable: fake.path, directory: root.path)
        let cli = "/path/to/TrackerCLI"
        try DiarySchedule.run(database: path, id: routine.id, runner: runner, cli: cli, now: cutoff)
        try check(!FileManager.default.fileExists(atPath: marker.path), "scheduler is idle when nothing is due")
        try DiarySchedule.run(database: path, id: routine.id, runner: runner, cli: cli, now: clock.instant(thursday, at: 615))
        let receipt = try String(contentsOf: marker, encoding: .utf8)
        try check(receipt.hasPrefix("exec\n") && !receipt.contains("resume\n")
                  && receipt.contains("mcp_servers.daylanes_diary.command=\"/path/to/TrackerCLI\"")
                  && receipt.contains("\"--diary-project=\(routine.id.uuidString)\"")
                  && receipt.contains("get_diary_work({})"), "due work starts a fresh run with the Diary server inline")
        try check(try DiarySchedule.status(db, routine: routine.id)?.contains("without saving") == true, "failed handoff remains visible and pending")
        try check(try DiarySchedule.lastAttempt(db, routine: routine.id)?.running != true, "a finished run is no longer marked running")
        try FileManager.default.removeItem(at: marker)
        try DiarySchedule.run(database: path, id: routine.id, runner: runner, cli: cli, now: clock.instant(thursday, at: 616))
        try check(!FileManager.default.fileExists(atPath: marker.path), "a failed run pauses the schedule for 15 minutes")
        try DiarySchedule.run(database: path, id: routine.id, runner: runner, cli: cli, force: true,
                              now: clock.instant(thursday, at: 616))
        try check(FileManager.default.fileExists(atPath: marker.path), "Run now skips the pause")

        let claude = DiarySchedule.Runner(agent: .claude, executable: fake.path, directory: root.path)
            .arguments(cli: cli, database: path, routine: routine.id)
        let mcpConfig = try JSON.parse(claude[2])
        try check(claude.first == "--print" && claude.contains("--allowedTools") && !claude.contains("--resume")
                  && mcpConfig["mcpServers"]["daylanes_diary"]["command"].stringValue == cli,
                  "Claude Code runs get the Diary server through --mcp-config")
        let config = DiarySchedule.configuration(routine.id, database: path, cli: cli, runner: runner)
        try check((config["ProgramArguments"] as? [String])?.count == 7, "the schedule needs no conversation ID")
        try check(claude.contains { $0.contains("Bash(gh pr view:*)") && $0.contains("Bash(git log:*)") }
                  && !claude.contains { $0.contains("Bash(gh api") },
                  "scheduled Claude Code runs may read Git and GitHub, but not write through gh api")
        let prompt = DiaryGuide.prompt(project: project, routine: routine.id, cli: "/Apps/Day lanes/TrackerCLI", database: path)
        try check(prompt.contains("'/Apps/Day lanes/TrackerCLI' --db '\(path)' diary guide \(routine.id.uuidString.lowercased())"),
                  "the copied prompt runs the guide for this ledger and routine")
        let (guideStatus, guide) = DiaryCLI.run(["guide", routine.id.uuidString], database: path, cli: "/bin/TrackerCLI") { Data() }
        try check(guideStatus == 0 && guide.contains(routine.brief) && guide.contains("diary work \(routine.id.uuidString.lowercased())")
                  && guide.contains("diary submit") && guide.contains("evidence_before"),
                  "the guide explains the steps, shows the brief and the commands")
        let (workStatus, workText) = DiaryCLI.run(["work", routine.id.uuidString, "--date", tuesday.iso], database: path,
                                                  cli: "/bin/TrackerCLI") { Data() }
        let cliWork = try JSON.parse(workText)["work"]
        try check(workStatus == 0 && cliWork["work_date"].stringValue == tuesday.iso, "diary work returns the requested workday")
        let cliEntry = try JSON.parse(DiaryStore.encode(DiaryContent(headline: "Fixtures shipped", summary: "Written from a shell.")))
        let cliSubmission = JSON.object([("work_date", cliWork["work_date"]), ("window", cliWork["window"]),
                                         ("through", cliWork["through"]), ("revision", cliWork["revision"]), ("entry", cliEntry)])
        let (submitStatus, submitText) = DiaryCLI.run(["submit", routine.id.uuidString], database: path, cli: "/bin/TrackerCLI") {
            Data(cliSubmission.pythonText(indent: nil).utf8)
        }
        try check(submitStatus == 0 && (try JSON.parse(submitText))["changed"].boolValue == true
                  && (try DiaryStore.entry(db, project: project, day: tuesday.iso))?.content.headline == "Fixtures shipped",
                  "diary submit saves the piped entry")
        try check(DiaryCLI.run(["publish", routine.id.uuidString], database: path, cli: "x") { Data() }.0 == 2, "unknown diary commands show usage")
        let (listStatus, listText) = DiaryCLI.run(["list"], database: path, cli: "/bin/TrackerCLI") { Data() }
        try check(listStatus == 0 && listText.contains("\"routine_id\": \"\(routine.id.uuidString.lowercased())\"")
                  && listText.contains("\"project\": \"\(other)\"") && listText.contains("\"client\": \"Example Gardens\""),
                  "diary list names every saved diary with its routine ID and client")
        var greeted = MCP.Session(options: .init(databasePath: path, access: .write, diaryRoutine: routine.id))
        let hello = try JSON.parse(MCP.answer("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}", session: &greeted) ?? "{}")
        try check(hello["result"]["instructions"].stringValue?.contains(routine.brief) == true
                  && hello["result"]["instructions"].stringValue?.contains("submit_diary_entry") == true,
                  "a Diary MCP connection introduces itself with the guide and brief")
        try check(guide.contains("## Running it every day") && guide.contains("`gh`") && guide.contains("05:05"),
                  "the guide explains scheduling and the access an unattended run needs")

        try check(try DiaryStore.latestDay(db, now: clock.instant(wednesday, at: 360)) == tuesday
                  && DiaryStore.latestDay(db, now: clock.instant(wednesday, at: 900)) == wednesday,
                  "an entry asked for now covers the workday in progress, or the one that just ended")
        try check(DiarySchedule.instruction(server: "x", manual: true).contains("latest_work_date")
                  && !DiarySchedule.instruction().contains("latest_work_date"),
                  "only a manual connection writes the latest workday when nothing is due")

        // Entries saved under a late cutoff before workdays were named by their end move to that day.
        let lateProject = "Lanterns"
        try Store.createProject(db, name: lateProject, client: "Example Studio", kind: "billable", folder: nil)
        for day in [tuesday, wednesday] {
            try db.execute("INSERT INTO diary_entries (project, work_date, window, through, revision, content) VALUES (?, ?, ?, ?, 1, ?)",
                           [lateProject, day.iso, try DiaryStore.encode(DiaryWindow(
                               start: DiaryClock.millis(evening.instant(day, at: 1380)),
                               end: DiaryClock.millis(evening.instant(day.adding(days: 1), at: 1380)), timezone: rome.identifier)),
                            0, try DiaryStore.encode(DiaryContent(headline: day.iso, summary: "Late."))])
        }
        try DiaryStore.renameLateWorkdays(db)
        try DiaryStore.renameLateWorkdays(db)
        try check(try DiaryStore.entry(db, project: lateProject, day: thursday.iso)?.content.headline == wednesday.iso
                  && DiaryStore.entry(db, project: lateProject, day: wednesday.iso)?.content.headline == tuesday.iso
                  && DiaryStore.entry(db, project: lateProject, day: tuesday.iso) == nil
                  && DiaryStore.entry(db, project: project, day: tuesday.iso) != nil,
                  "late-cutoff entries move once to the day they end on, early ones stay")
        print("Diary checks passed")
    }
}
