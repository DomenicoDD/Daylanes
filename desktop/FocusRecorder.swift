import AppKit
import Combine
import CoreGraphics
import Darwin

@MainActor
final class FocusRecorder: NSObject, ObservableObject {
    enum Status: Equatable {
        case paused, recording(String), idle, away, waiting

        var label: String {
            switch self {
            case .paused: "Snoozed"
            case let .recording(app): "Tracking \(app)"
            case .idle: "Idle"
            case .away: "Session inactive"
            case .waiting: "Tracking"
            }
        }
    }

    @Published private(set) var enabled = false
    /// While set and in the future, tracking is snoozed; it resumes by itself at this time.
    @Published private(set) var snoozedUntil: Date? = UserDefaults.standard.object(forKey: "snoozedUntil") as? Date
    private var resumeTimer: Timer?
    @Published private(set) var status: Status = .paused
    @Published private(set) var revision = 0
    @Published private(set) var error: String?
    @Published private(set) var ready = false
    @Published private(set) var rules: [FocusRule] = []
    /// Window-title rules made from project and client names. Your own rules and GitHub routes win over them.
    @Published private(set) var autoRules: [FocusRule] = []
    /// Projects whose automatic name rules are turned off.
    @Published private(set) var autoRulesOff: Set<String> = []
    @Published private(set) var changing = false
    @Published private(set) var lastChromeTab: ChromeObservation?
    @Published private(set) var chromeProfileCatalog = ChromeProfile.Catalog(profiles: [], requiresImport: false)
    @Published private(set) var chromeProfileClients: [String: String] = [:]
    /// Settings → Your data: keep window titles and page addresses with recorded time.
    @Published private(set) var keepDetails = false
    var chromeProfiles: [ChromeProfile] { chromeProfileCatalog.profiles }
    /// Whether this app installed the Chrome helper, checked once at launch.
    @Published private(set) var chromeSetup: ChromeBridge.Setup?
    /// When the Chrome extension last answered a tab request.
    @Published private(set) var chromeExtensionReply: Date?

    private var session = FocusSession()
    private var githubRoutes: [String: GitHubRoute] = [:]
    private var lease: RecordingLease?
    private var timer: Timer?
    private var processActivity: NSObjectProtocol?
    private var suspended: Set<Notification.Name> = []
    private var pending: [UUID: FocusBlock] = [:]
    private var flushing: Task<Void, Never>?
    private var lastCheckpoint: TimeInterval = 0
    private var preferenceUpdate: Task<Void, Never>?
    private var ruleChangeTask: Task<Void, Never>?
    private var shuttingDown = false
    private var pendingTabRead: UUID?
    private var tabReadInFlight = false
    private var profileRefreshInFlight = false
    private var profileImportInFlight = false
    private var profileImportRevision = 0
    private var profileRefreshAfter: TimeInterval = 0

    /// Posted by the ledger model when projects or clients change, so name rules follow them.
    static let projectsChanged = Notification.Name("TrackerProjectsChanged")
    private var projectsObserver: NSObjectProtocol?
    private var externalRulesObserver: NSObjectProtocol?
    private var activeObserver: NSObjectProtocol?

    func prepare() async {
        guard lease == nil else { return }
        if projectsObserver == nil {
            projectsObserver = NotificationCenter.default.addObserver(forName: Self.projectsChanged, object: nil,
                                                                      queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.ready else { return }
                    try? await self.applyRuleChange(["config"])
                }
            }
        }
        if externalRulesObserver == nil {
            externalRulesObserver = DistributedNotificationCenter.default().addObserver(
                forName: Focus.rulesChanged, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.refreshRules() }
            }
        }
        if activeObserver == nil {
            activeObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in await self?.refreshRules() }
            }
        }
        if chromeSetup == nil, !Self.isDemo { Task { chromeSetup = await ChromeBridge.install() } }
        Task { await refreshChromeProfiles() }
        do {
            lease = try RecordingLease()
            _ = try await Ledger.run(["focus", "recover"])
            let preferences = try await config(["focus", "config"])
            let workspace = NSWorkspace.shared.notificationCenter
            workspace.addObserver(self, selector: #selector(systemEvent(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
            for name in Self.suspensions.keys {
                workspace.addObserver(self, selector: #selector(systemEvent(_:)), name: name, object: nil)
            }
            ready = true
            apply(preferences)
            revision += 1
            // Tracking is always on: a snooze is the only way to stop it, and it ends by itself.
            if !preferences.enabled { savePreference(true, startSampling: false) }
            if let until = snoozedUntil, until > Date() {
                scheduleResume(at: until)
            } else if !shuttingDown {
                clearSnooze()
                beginSampling()
            }
        } catch {
            lease = nil
            self.error = error.localizedDescription
        }
    }

    /// Ends a snooze now.
    func resume() {
        clearSnooze()
        guard ready, !enabled, !shuttingDown else { return }
        beginSampling()
    }

    /// Stops tracking for a while. Nil minutes means until tomorrow morning (midnight).
    func snooze(minutes: Int?) {
        guard ready else { return }
        let until: Date = if let minutes {
            Date().addingTimeInterval(TimeInterval(minutes * 60))
        } else {
            Calendar.current.startOfDay(for: Date().addingTimeInterval(86_400))
        }
        stopSampling()
        snoozedUntil = until
        UserDefaults.standard.set(until, forKey: "snoozedUntil")
        scheduleResume(at: until)
    }

    private func scheduleResume(at date: Date) {
        resumeTimer?.invalidate()
        let timer = Timer(fire: date, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.resume() }
        }
        RunLoop.main.add(timer, forMode: .common)
        resumeTimer = timer
    }

    private func clearSnooze() {
        resumeTimer?.invalidate()
        resumeTimer = nil
        snoozedUntil = nil
        UserDefaults.standard.removeObject(forKey: "snoozedUntil")
    }

    /// bin/demo sets DAYLANES_DEMO=1: the sample-data copy shows tracking as on but records nothing real.
    nonisolated static let isDemo = ProcessInfo.processInfo.environment["DAYLANES_DEMO"] == "1"

    private func beginSampling() {
        enabled = true
        if Self.isDemo { status = .waiting; return }
        processActivity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep, reason: "Recording foreground app time"
        )
        lastCheckpoint = ProcessInfo.processInfo.systemUptime
        sample()
        let timer = Timer(timeInterval: 1, target: self, selector: #selector(sample), userInfo: nil, repeats: true)
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopSampling() {
        guard enabled else { return }
        if suspended.isEmpty { sample() }
        pendingTabRead = nil
        timer?.invalidate()
        timer = nil
        enabled = false
        if let processActivity {
            ProcessInfo.processInfo.endActivity(processActivity)
            self.processActivity = nil
        }
        status = .paused
        queue(session.stop())
    }

    func finish() async {
        shuttingDown = true
        stopSampling()
        await preferenceUpdate?.value
        await flushing?.value
        if !pending.isEmpty {
            flush()
            await flushing?.value
        }
    }

    private func savePreference(_ enabled: Bool, startSampling: Bool = true) {
        changing = true
        preferenceUpdate = Task {
            defer { changing = false }
            do {
                _ = try await config(["focus", "config", "--enabled", enabled ? "on" : "off"])
                error = nil
                if enabled && startSampling && !shuttingDown { beginSampling() }
            } catch {
                self.error = enabled ? "Couldn’t start tracking. \(error.localizedDescription)"
                    : "Tracking paused, but Daylanes couldn’t save the preference. \(error.localizedDescription)"
            }
        }
    }

    func applyRuleChange(_ arguments: [String]) async throws {
        let previous = ruleChangeTask
        let change = Task {
            await previous?.value
            apply(try await config(["focus"] + arguments))
            if enabled { sample() }
        }
        ruleChangeTask = Task { _ = try? await change.value }
        try await change.value
    }

    private func refreshRules() async {
        guard ready, !shuttingDown else { return }
        try? await applyRuleChange(["config"])
    }

    private func apply(_ preferences: FocusConfig) {
        rules = preferences.rules
        autoRules = preferences.autoRules ?? []
        autoRulesOff = Set(preferences.autoRulesOff ?? [])
        githubRoutes = preferences.githubRoutes
        chromeProfileClients = preferences.chromeProfileClients ?? [:]
        keepDetails = preferences.keepDetails ?? false
        if var tab = lastChromeTab {
            tab.rematch(rules: rules, automatic: autoRules, routes: githubRoutes)
            if tab != lastChromeTab { lastChromeTab = tab }
        }
    }

    private func config(_ args: [String]) async throws -> FocusConfig {
        let data = try await Ledger.run(args)
        return try JSONDecoder().decode(FocusConfig.self, from: data)
    }

    func retry() {
        if ready {
            flush()
        } else {
            Task { await prepare() }
        }
    }

    private static let suspensions: [Notification.Name: Notification.Name] = [
        NSWorkspace.willSleepNotification: NSWorkspace.willSleepNotification,
        NSWorkspace.didWakeNotification: NSWorkspace.willSleepNotification,
        NSWorkspace.screensDidSleepNotification: NSWorkspace.screensDidSleepNotification,
        NSWorkspace.screensDidWakeNotification: NSWorkspace.screensDidSleepNotification,
        NSWorkspace.sessionDidResignActiveNotification: NSWorkspace.sessionDidResignActiveNotification,
        NSWorkspace.sessionDidBecomeActiveNotification: NSWorkspace.sessionDidResignActiveNotification,
    ]

    @objc nonisolated private func systemEvent(_ notification: Notification) {
        let name = notification.name
        Task { @MainActor in handleSystemEvent(name) }
    }

    private func handleSystemEvent(_ name: Notification.Name) {
        if let blockedBy = Self.suspensions[name] {
            if name == blockedBy {
                suspended.insert(blockedBy)
                pendingTabRead = nil
                queue(session.stop())
            } else {
                suspended.remove(blockedBy)
            }
        }
        if enabled { sample() }
    }

    @objc private func sample() {
        guard enabled, !Self.isDemo else { return }
        guard suspended.isEmpty else {
            updateStatus(.away)
            return
        }

        let frontmost = NSWorkspace.shared.frontmostApplication
        let id = frontmost?.bundleIdentifier
        let excluded = id == Bundle.main.bundleIdentifier
            || id == "com.apple.loginwindow" || id == "com.apple.ScreenSaver.Engine"
        let app: ForegroundApp?
        if !excluded, let name = frontmost?.localizedName {
            app = ForegroundApp(id: id ?? frontmost?.bundleURL?.lastPathComponent ?? name, name: name)
        } else {
            app = nil
        }

        let idle = Self.inputEvents.map {
            CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: $0)
        }.min() ?? FocusSession.idleLimit
        let observation = FocusObservation(at: Date(), uptime: ProcessInfo.processInfo.systemUptime, app: app, idle: idle)
        if TrackerChromeWire.isBrowser(app?.id), let pid = frontmost?.processIdentifier, idle < FocusSession.idleLimit {
            readChromeTab(observation, pid: pid)
        } else {
            pendingTabRead = nil
            record(observation, pid: frontmost?.processIdentifier)
        }
    }

    func refreshChromeProfiles() async {
        guard !profileRefreshInFlight, !profileImportInFlight else { return }
        profileRefreshInFlight = true
        defer { profileRefreshInFlight = false }
        let revision = profileImportRevision
        let catalog = await Task.detached(priority: .utility) { ChromeProfile.discover() }.value
        profileRefreshAfter = ProcessInfo.processInfo.systemUptime + 30
        if revision == profileImportRevision, chromeProfileCatalog != catalog { chromeProfileCatalog = catalog }
    }

    func importChromeProfiles(from url: URL) async throws {
        guard !profileImportInFlight else { return }
        profileImportInFlight = true
        defer { profileImportInFlight = false }
        let profiles = try await Task.detached(priority: .userInitiated) {
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            return try ChromeProfile.importCatalog(from: url)
        }.value
        profileImportRevision += 1
        chromeProfileCatalog = ChromeProfile.Catalog(profiles: profiles, requiresImport: true)
    }

    func chooseChromeProfiles() async throws {
        let panel = NSOpenPanel()
        panel.title = "Import Chrome profiles"
        panel.message = "Choose Chrome’s Local State file to import profile names and IDs."
        panel.prompt = "Import profiles"
        panel.directoryURL = ChromeProfile.localState().deletingLastPathComponent()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        guard await panel.begin() == .OK, let url = panel.url else { return }
        try await importChromeProfiles(from: url)
    }

    func setKeepDetails(_ keep: Bool) async throws {
        try await applyRuleChange(["details", "--state", keep ? "on" : "off"])
    }

    func setChromeProfileClient(_ client: String?, for profileID: String) async throws {
        let destination = client.map { "--client=\($0)" } ?? "--clear"
        try await applyRuleChange(["chrome-client", profileID, destination])
    }

    func chromeProfileName(_ id: String) -> String {
        chromeProfiles.first { $0.id == id }?.name ?? id
    }

    private func readChromeTab(_ observation: FocusObservation, pid: pid_t) {
        guard !tabReadInFlight else { return }
        tabReadInFlight = true
        let request = UUID()
        pendingTabRead = request
        Task {
            let canReadProfile = observation.app?.id == ChromeTabs.bundleID && WindowTitles.authorized
            if canReadProfile && observation.uptime >= profileRefreshAfter { await refreshChromeProfiles() }
            let title = if canReadProfile && !chromeProfiles.isEmpty {
                await WindowTitles.readFocusedTitle(pid: pid)
            } else {
                nil as String?
            }
            let extensionReading = await TrackerChromeClient.activeTab()
            if extensionReading != nil { chromeExtensionReply = Date() }
            let extensionAddress = extensionReading?.url.flatMap(TabAddress.init)
            let needsWindowName = rules.contains { $0.needsBrowserTab && $0.appScope != nil }
            // Only Google Chrome has the scripting dictionary ChromeTabs reads.
            let scriptable = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == ChromeTabs.bundleID
            let result = if scriptable && (extensionAddress == nil || needsWindowName) {
                await ChromeTabs.read(pid: pid)
            } else {
                ChromeTabs.Reading.unavailable
            }
            // Recheck the window around the tab read so switching profiles can't pair a stale title with a new tab.
            let confirmedTitle: String?
            if let title, result != .privateWindow, extensionAddress != nil || result != .unavailable,
               await WindowTitles.readFocusedTitle(pid: pid) == title {
                confirmedTitle = title
            } else {
                confirmedTitle = nil
            }
            let profileID = confirmedTitle.flatMap { chromeProfileCatalog.profile(forVerifiedWindowTitle: $0)?.id }
            tabReadInFlight = false
            guard pendingTabRead == request else { return }
            pendingTabRead = nil
            guard enabled, suspended.isEmpty, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                return
            }
            if result == .privateWindow {
                lastChromeTab = nil
                var excluded = observation
                excluded.app = nil
                record(excluded, pid: nil)
            } else if let extensionAddress {
                let windowName = if case let .tab(address, name) = result, address == extensionAddress {
                    name
                } else {
                    nil as String?
                }
                record(observation, pid: pid, tab: extensionAddress, chromeWindow: windowName,
                       chromeProfile: extensionReading?.profile, chromeProfileID: profileID, browserTitle: confirmedTitle)
            } else if case let .tab(address, windowName) = result {
                record(observation, pid: pid, tab: address, chromeWindow: windowName,
                       chromeProfileID: profileID, browserTitle: confirmedTitle)
            } else {
                lastChromeTab = nil
                record(observation, pid: pid, chromeProfileID: profileID, browserTitle: confirmedTitle)
            }
        }
    }

    private func record(_ raw: FocusObservation, pid: pid_t?, tab: TabAddress? = nil, chromeWindow: String? = nil,
                        chromeProfile: String? = nil, chromeProfileID: String? = nil, browserTitle: String? = nil) {
        var observation = raw
        if let app = observation.app, observation.idle < FocusSession.idleLimit {
            let shouldReadTitle = keepDetails || !autoRules.isEmpty || rules.contains {
                $0.needsWindowTitle && $0.appliesToApp(app.name, id: app.id)
            }
            let title = shouldReadTitle && WindowTitles.authorized ? browserTitle ?? pid.flatMap(WindowTitles.focusedTitle) : nil
            if keepDetails, title != nil || tab != nil {
                observation.detail = ActivityDetail(title: title ?? "", address: tab?.originAndPath ?? "")
            }
            observation.github = tab.flatMap { GitHubPage(tab: $0, routes: githubRoutes) }
            let githubMatch = observation.github?.match(in: githubRoutes)
            let resolution = FocusRule.resolve(rules: rules, app: app.name, appID: app.id, title: title, tab: tab,
                                               chromeWindow: chromeWindow, chromeProfile: chromeProfile,
                                               chromeProfileID: chromeProfileID, githubMatch: githubMatch, automatic: autoRules)
            observation.match = resolution.rule
            if observation.match?.isIgnored == true {
                observation.github = nil
            } else if let chromeProfileID {
                observation.client = chromeProfileClients[chromeProfileID]
            }
            if let tab {
                let seen = ChromeObservation(address: tab, windowName: chromeWindow, profile: chromeProfile,
                                             profileID: chromeProfileID, app: app, title: title, resolution: resolution)
                if lastChromeTab != seen { lastChromeTab = seen }
            }
        }
        queue(session.observe(observation))
        if let live = session.activeBlock, observation.uptime - lastCheckpoint >= 15 {
            queue([live])
            lastCheckpoint = observation.uptime
        }

        if observation.idle >= FocusSession.idleLimit {
            updateStatus(.idle)
        } else if let app = observation.app {
            let name = observation.match?.isIgnored == true ? "\(app.displayName) (ignored)" : app.displayName
            updateStatus(.recording(name))
        } else {
            updateStatus(.waiting)
        }
    }

    private static let inputEvents: [CGEventType] = [
        .keyDown, .flagsChanged, .mouseMoved, .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .leftMouseDragged, .rightMouseDragged, .otherMouseDragged, .scrollWheel, .tabletPointer,
    ]

    private func updateStatus(_ new: Status) {
        if status != new { status = new }
    }

    private func queue(_ blocks: [FocusBlock]) {
        guard !blocks.isEmpty else { return }
        for block in blocks { pending[block.id] = block }
        flush()
    }

    private func flush() {
        guard flushing == nil, !pending.isEmpty else { return }
        flushing = Task {
            while !pending.isEmpty {
                let batch = Array(pending.values.prefix(1000))
                for block in batch { pending.removeValue(forKey: block.id) }
                do {
                    let encoded = try JSONEncoder().encode(batch)
                    _ = try await Ledger.run(["focus", "record"], input: encoded)
                    error = nil
                    revision += 1
                } catch {
                    for block in batch where pending[block.id] == nil { pending[block.id] = block }
                    self.error = "Couldn’t save activity. \(error.localizedDescription)"
                    break
                }
            }
            flushing = nil
        }
    }
}

private final class RecordingLease {
    private let descriptor: Int32

    init() throws {
        let defaultPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/tracker/ledger.sqlite3").path
        let selected = ProcessInfo.processInfo.environment["TRACKER_DB"] ?? defaultPath
        let database = URL(fileURLWithPath: (selected as NSString).expandingTildeInPath).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: database.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let file = open(database.path + ".focus.lock", O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard file >= 0 else {
            throw Ledger.CommandError(message: "Daylanes couldn’t open its activity lock.")
        }
        guard flock(file, LOCK_EX | LOCK_NB) == 0 else {
            close(file)
            throw Ledger.CommandError(message: "Another Daylanes window is using this activity ledger.")
        }
        descriptor = file
    }

    deinit { close(descriptor) }
}
