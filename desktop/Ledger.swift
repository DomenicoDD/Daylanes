import AppKit
import Combine
import Foundation

struct Tokens: Decodable {
    var input: Int = 0
    var cached: Int = 0
    var cacheWrite: Int = 0
    var output: Int = 0
    var total: Int { input + cached + cacheWrite + output }
}

struct AgentUsage: Decodable {
    let tokens: Tokens
    let runtimeHours: String?
    let runtimeKind: String?
    let models: [String: Tokens]
    let apiEquivalentUsd: String?
    let modelApiEquivalentUsd: [String: String]
}

struct Summary: Decodable {
    let humanHours: String
    let agents: [String: AgentUsage]
    let providerExpenses: String
    let estimatedTokenValue: String
    let tokensWithoutPrice: Int
    let apiEquivalentUsd: String?
    let tokensWithoutApiPrice: Int

    var allTokens: Int { agents.values.reduce(0) { $0 + $1.tokens.total } }
    var pricedTokens: Int { allTokens - tokensWithoutPrice }
}

struct Project: Decodable, Identifiable {
    let name: String
    let client: String?
    let kind: String
    let folders: [String]
    let githubRepo: String?
    let githubRefreshedAt: Double?
    let githubRoutedPrs: [Int]?
    let githubPullRequests: [PullRequest]?
    /// Mapped folders, each with the GitHub repository its Git remote points to.
    let folderSources: [FolderSource]?
    var id: String { name }

    var category: String {
        switch kind {
        case "billable": "Client work"
        case "internal": "Internal"
        default: "Personal"
        }
    }
}

struct FolderSource: Decodable, Identifiable {
    let path: String
    let repo: String?
    var id: String { path }
}

struct PullRequest: Decodable {
    let number: Int
    let title: String
    let state: String
    let url: URL
}

struct Activity: Decodable, Identifiable {
    let provider: String
    let folder: String?
    let branch: String?
    let project: String?
    let task: String?
    var sessions: [AgentChat]?
    /// The first and last entry of this work in the period, in milliseconds since 1970.
    let firstAt: Double?
    let lastAt: Double
    /// When the work ended: the latest entry, or the end of the latest runtime span.
    let endedAt: Double?
    let entryCount: Int
    let summary: Summary
    let pullRequest: PullRequest?
    let githubRepo: String?
    let client: String?
    /// The GitHub repository the folder's Git remote points to, and its checked-out commit.
    let folderRepo: String?
    let headCommit: String?

    var id: [String?] { [provider, folder, branch, project, task] }
    var repo: String? { githubRepo ?? folderRepo }
    var folderName: String {
        guard let folder else { return "Unknown folder" }
        return URL(fileURLWithPath: folder).lastPathComponent
    }
    var displayTitle: String { sessions?.count == 1 ? sessions?.first?.title ?? folderName : folderName }
    var sourceContext: String? {
        let contexts = Set(sessions?.map(\.sourceContext) ?? [])
        if contexts.count == 1, let context = contexts.first ?? nil { return context }
        return folder != nil && displayTitle != folderName ? folderName : nil
    }
    var usage: AgentUsage? { summary.agents[provider] }
}

struct ModelPrice: Decodable, Identifiable {
    let provider: String
    let model: String
    let prices: Tokens?
    let openrouterModel: String?
    var id: String { "\(provider):\(model)" }
}

struct Subscription: Decodable, Identifiable {
    let name: String
    let monthly: String
    let provider: String?
    var id: String { name }
}

struct Subscriptions: Decodable {
    let plans: [Subscription]
    let monthlyTotal: String
}

struct OpenRouterAccount: Decodable {
    struct Totals: Decodable {
        let spendUsd: String
        let requests: Int
        let tokens: Int
    }

    struct ModelUsage: Decodable, Identifiable {
        let model: String
        let spendUsd: String
        let requests: Int
        let tokens: Int
        var id: String { model }
    }

    let start: String?
    let endExclusive: String?
    let fetchedAt: Double
    let totals: Totals
    let models: [ModelUsage]
}

/// A colour chosen for a project, or an icon chosen for a client.
struct Appearance: Decodable {
    let scope: String
    let name: String
    let color: String?
    let icon: String?
}

/// The Toggl Track account Tracker verified when you connected. The token itself stays in Keychain.
struct TogglAccount: Decodable {
    struct Workspace: Decodable, Identifiable, Hashable {
        let id: Int
        let name: String
    }

    let name: String
    let email: String
    let workspaceId: Int?
    let workspaces: [Workspace]

    var workspaceName: String? { workspaces.first { $0.id == workspaceId }?.name }
}

/// Invoice lines for the selected period (decoded with snake-case conversion, like the rest of the snapshot).
struct BillingSummary: Decodable {
    struct Line: Decodable, Identifiable {
        let item: String
        let hours: String?
        let rate: String?
        let apiUsd: String?
        let markup: String?
        let tokensWithoutApiPrice: Int?
        let amount: String?
        var id: String { item }
    }

    struct ProjectBill: Decodable, Identifiable {
        let project: String
        let agentMode: String
        let lines: [Line]
        let subtotal: String
        var id: String { project }
    }

    struct ClientBill: Decodable, Identifiable {
        let client: String?
        let projects: [ProjectBill]
        let monthlyCap: String?
        let capReduction: String?
        let total: String
        var id: String { client ?? "" }
    }

    let currency: String
    let usdExchangeRate: String?
    let needsExchangeRate: Bool
    let missingHumanRate: Bool
    let clients: [ClientBill]
    let total: String
}

/// Billing terms as stored: on a project, a nil field means "use the client's".
struct BillingTerms: Decodable {
    var name: String? = nil
    let humanRate: String?
    let agentMode: String?
    let agentRate: String?
    let usageMarkup: String?
    let monthlyCap: String?

    static let empty = BillingTerms(humanRate: nil, agentMode: nil, agentRate: nil, usageMarkup: nil, monthlyCap: nil)
}

struct BillingTermsListing: Decodable {
    let clients: [BillingTerms]
    let projects: [BillingTerms]
    let usdExchangeRate: String?

    func client(_ name: String) -> BillingTerms? { clients.first { $0.name == name } }
    func project(_ name: String) -> BillingTerms? { projects.first { $0.name == name } }
}

struct TogglProject: Decodable, Identifiable {
    let id: Int
    let name: String
    let archived: Bool
    let workspaceId: Int?

    enum CodingKeys: String, CodingKey {
        case id, name, archived, workspaceId = "workspace_id"
    }

    var label: String {
        "\(name)\(archived ? " (archived)" : "") · #\(id)"
    }
}

enum GitHubStatus: String, Decodable {
    case connected, missing, unverified, unavailable

    var description: String {
        switch self {
        case .connected: "GitHub CLI is signed in."
        case .missing: "Install GitHub CLI, then run gh auth login in Terminal."
        case .unverified: "GitHub sign-in could not be verified. Run gh auth status in Terminal to check."
        case .unavailable: "GitHub CLI did not respond. Check your connection and try again."
        }
    }
}

struct Snapshot: Decodable {
    let start: String
    let endExclusive: String
    let timezone: String
    let currency: String
    let database: String
    let totals: Summary
    let dailyHumanMillis: [String: Double]
    let unassignedFocusMillis: Double
    var activity: [Activity]
    let clients: [String]
    let selfClient: String?
    let projects: [Project]
    let projectTotals: [String: Summary]
    let models: [ModelPrice]
    let subscriptions: Subscriptions
    let billing: BillingSummary?
    let billingTerms: BillingTermsListing?
    let togglAccount: TogglAccount?
    let appearance: [Appearance]?
    let apiPricesFetchedAt: Double?
    let openrouterAccount: OpenRouterAccount?
    let providerUsage: [ProviderUsage.Account]?

    var range: [String] { ["--start", start, "--end", endExclusive] }
    var unassigned: [Activity] { activity.filter { $0.project == nil } }

    var dateLabel: String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: 0)
        fmt.dateFormat = "yyyy-MM-dd"
        guard let first = fmt.date(from: start), let end = fmt.date(from: endExclusive) else { return start }
        let last = end.addingTimeInterval(-86_400)
        fmt.setLocalizedDateFormatFromTemplate("dMMM")
        let a = fmt.string(from: first)
        let b = fmt.string(from: last)
        fmt.dateFormat = "yyyy"
        let firstYear = fmt.string(from: first), lastYear = fmt.string(from: last)
        return firstYear == lastYear ? "\(a) – \(b), \(lastYear)" : "\(a), \(firstYear) – \(b), \(lastYear)"
    }
}

enum Period: Hashable, Identifiable, Sendable {
    case week, month, lastWeek, lastMonth, quarter, last12Months
    case custom(first: Day, last: Day)

    static let presets: [Self] = [.week, .month, .lastWeek, .lastMonth, .quarter, .last12Months]

    var id: Self { self }

    /// The latest custom range occupies one slot, alongside the six preset snapshots.
    var cacheSlot: String {
        switch self {
        case .week: "This week"
        case .month: "This month"
        case .lastWeek: "Last week"
        case .lastMonth: "Last month"
        case .quarter: "Current quarter"
        case .last12Months: "Latest 12 months"
        case .custom: "Custom range"
        }
    }

    func title(timezone: String, now: Date = Date()) -> String {
        guard self == .quarter else { return cacheSlot }
        let zone = TimeZone(identifier: timezone) ?? .current
        let month = Day.local(Int(now.timeIntervalSince1970 * 1000), zone).month
        return "\(cacheSlot) (Q\((month - 1) / 3 + 1))"
    }

    func range(timezone: String, now: Date = Date()) -> LedgerRange {
        let zone = TimeZone(identifier: timezone) ?? .current
        let today = Day.local(Int(now.timeIntervalSince1970 * 1000), zone)
        let monday = today.adding(days: -today.weekday)
        let month = today.firstOfMonth
        let bounds: (Day, Day)
        switch self {
        case .week: bounds = (monday, monday.adding(days: 7))
        case .month: bounds = (month, month.firstOfNextMonth)
        case .lastWeek: bounds = (monday.adding(days: -7), monday)
        case .lastMonth: bounds = (month.adding(days: -1).firstOfMonth, month)
        case .quarter:
            let first = Day(year: today.year, month: ((today.month - 1) / 3) * 3 + 1, day: 1)
            bounds = (first, first.firstOfNextMonth.firstOfNextMonth.firstOfNextMonth)
        case .last12Months:
            let end = today.adding(days: 1)
            let lastYear = Day(year: end.year - 1, month: end.month, day: 1)
            let lastDay = lastYear.firstOfNextMonth.adding(days: -1).day
            bounds = (lastYear.adding(days: min(end.day, lastDay) - 1), end)
        case let .custom(first, last):
            bounds = (first, last.adding(days: 1))
        }
        return LedgerRange(start: bounds.0.iso, endExclusive: bounds.1.iso, timezone: timezone)
    }
}

enum Ledger {
    struct CommandError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run(_ arguments: [String], input: Data? = nil, secretInput: Data? = nil) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            // Every command runs in process on the Swift engine.
            do {
                guard let output = try CLI.run(arguments, input: secretInput ?? input) else {
                    throw CommandError(message: "Daylanes doesn't know the command \(arguments.prefix(2).joined(separator: " ")).")
                }
                return output
            } catch let error as EngineError {
                throw CommandError(message: error.message)
            }
        }.value
    }

    static func decodeSnapshot(_ data: Data) throws -> Snapshot {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        var snapshot = try decoder.decode(Snapshot.self, from: data)
        AgentChatMetadata.enrich(&snapshot.activity)
        return snapshot
    }
}

@MainActor
final class LedgerModel: ObservableObject {
    @Published var snapshot: Snapshot?
    @Published var period: Period = .week
    @Published var busy: String?
    @Published var error: String?
    @Published var notice: String?
    @Published var sourceMessage: String?
    @Published var openRouterConnected = false
    @Published var openRouterMessage: String?
    @Published var providerUsageMessages: [AIProvider: String] = [:]
    @Published var togglConnected = false
    @Published var togglKeychainMessage: String?
    @Published var togglProjects: [TogglProject]?
    @Published var gitHubStatus: GitHubStatus?
    @Published var gitHubLogin: String?
    /// Bumped after every successful snapshot load, so views that cache their own ledger reads can refresh.
    @Published private(set) var revision = 0
    @Published private(set) var loadingPeriod = false

    private let snapshots = LedgerSnapshots()
    private var selectionLoad: UUID?
    private var lastWarmDay: String?
    private var warming: Task<Void, Never>?
    private var lastExplicitRefresh = Date.distantPast
    private var togglSessionKey: String?

    var showingSelectedPeriod: Bool {
        guard let snapshot else { return false }
        return period.range(timezone: snapshot.timezone).matches(snapshot)
    }

    func selectPeriod(automatically: Bool = false) async {
        guard snapshot != nil, busy == nil, !(automatically && loadingPeriod) else { return }
        do {
            try await loadSelectedPeriod(useCache: true, deferChangedLedgerFor: automatically ? 300 : 60)
        } catch {
            if !Task.isCancelled && !automatically { self.error = error.localizedDescription }
        }
    }

    func maintainSnapshots() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            await selectPeriod(automatically: true)
            warmPeriods()
        }
    }

    func reload() async {
        await perform("Loading usage…") {
            try await self.update()
        }
    }

    func start() async {
        guard snapshot == nil else { return }
        await perform("Loading usage…") {
            _ = try await Ledger.run(["init", "--default-timezone", TimeZone.current.identifier])
            let request = await snapshots.request(period, timezone: TimeZone.current.identifier)
            if let cached = await snapshots.cached(for: request) { display(cached.snapshot) }
            // Folders added before repositories were linked automatically get their link now.
            _ = try? await Ledger.run(["github", "autolink"])
            if snapshot == nil { try await loadSelectedPeriod(useCache: false) }
            if snapshot?.togglAccount != nil {
                togglConnected = true
            } else {
                togglConnected = await Task.detached(priority: .utility) { IntegrationKeychain.toggl.hasSavedItem() }.value
            }
            self.busy = "Importing local agent history…"
            try await self.importUsage(useCache: true)
            Task { await self.loadNewLinks() }
        }
        warmPeriods()
    }

    func refresh() async {
        await perform("Importing local agent history…") {
            try await self.importUsage()
        }
    }

    func refreshPrices() async {
        await perform("Refreshing OpenRouter prices…") {
            _ = try await Ledger.run(["refresh-prices"])
            try await self.update()
            self.notice = "OpenRouter prices refreshed"
        }
    }

    func setOpenRouterKey(_ key: String?) async {
        await perform(key == nil ? "Disconnecting OpenRouter…" : "Connecting OpenRouter…") {
            if let key {
                try await self.syncOpenRouter(key)
                try IntegrationKeychain.openRouter.save(key)
                self.openRouterConnected = true
                do {
                    try await Self.readProviderUsage(.openrouter, credential: key)
                    self.providerUsageMessages[.openrouter] = nil
                } catch {
                    try await Self.clearProviderUsage(.openrouter)
                    self.providerUsageMessages[.openrouter] = error.localizedDescription
                }
                self.notice = "OpenRouter account connected"
            } else {
                try IntegrationKeychain.openRouter.remove()
                self.openRouterConnected = false
                _ = try await Ledger.run(["openrouter-sync", "--clear"])
                try await Self.clearProviderUsage(.openrouter)
                self.providerUsageMessages[.openrouter] = nil
                self.notice = "OpenRouter account disconnected"
            }
            self.openRouterMessage = nil
            try await self.update()
        }
    }

    private func syncOpenRouter(_ key: String) async throws {
        guard key.utf8.count <= 512 else {
            throw Ledger.CommandError(message: "Enter an OpenRouter management key.")
        }
        _ = try await Ledger.run(["openrouter-sync", "--key-stdin"], secretInput: Data(key.utf8))
    }

    func setTogglKey(_ key: String?) async {
        await perform(key == nil ? "Disconnecting Toggl Track…" : "Connecting Toggl Track…") {
            if let key {
                guard key.utf8.count <= 512 else { throw Ledger.CommandError(message: "Enter a Toggl Track API token.") }
                // Verifies the token with Toggl first, so a wrong token is never saved.
                _ = try await Ledger.run(["toggl", "link"], secretInput: Data(key.utf8))
                let projects = try await self.fetchTogglProjects(key)
                try IntegrationKeychain.toggl.save(key)
                self.togglSessionKey = key
                self.togglProjects = projects
                self.togglConnected = true
                self.notice = "Toggl Track connected"
            } else {
                try IntegrationKeychain.toggl.remove()
                self.togglSessionKey = nil
                _ = try await Ledger.run(["toggl", "unlink"])
                self.togglConnected = false
                self.togglProjects = nil
                self.notice = "Toggl Track disconnected"
            }
            self.togglKeychainMessage = nil
            try await self.update()
        }
    }

    func chooseTogglWorkspace(_ workspace: Int) async {
        await perform("Switching Toggl workspace…") {
            _ = try await Ledger.run(["toggl", "workspace", String(workspace)])
            try await self.update()
        }
    }

    func loadTogglProjects() async {
        await perform("Loading Toggl Track projects…") {
            let key = try await self.togglKey()
            let projects = try await self.fetchTogglProjects(key)
            if self.snapshot?.togglAccount == nil {
                // Populate account details for tokens stored before Daylanes saved account metadata.
                _ = try await Ledger.run(["toggl", "link"], secretInput: Data(key.utf8))
                try await self.update()
            }
            self.togglProjects = projects
        }
    }

    func importToggl(_ source: TogglProject, into project: String, start: String, end: String) async {
        struct Result: Decodable { let entries: Int }
        await perform("Importing Toggl Track time…") {
            let args = ["toggl", "import", "--source", String(source.id), "--project=\(project)",
                        "--start", start, "--end", end]
            let data = try await Ledger.run(args, secretInput: Data(self.togglKey().utf8))
            let result = try JSONDecoder().decode(Result.self, from: data)
            try await self.update()
            self.notice = result.entries == 1 ? "Imported 1 Toggl time entry" : "Imported \(result.entries) Toggl time entries"
        }
    }

    private func togglKey() async throws -> String {
        if let togglSessionKey { return togglSessionKey }
        do {
            guard let key = try await IntegrationKeychain.toggl.loadInBackground() else {
                togglConnected = false
                togglProjects = nil
                throw Ledger.CommandError(message: "Connect Toggl Track in Settings first.")
            }
            togglSessionKey = key
            togglKeychainMessage = nil
            return key
        } catch {
            togglKeychainMessage = error.localizedDescription
            throw error
        }
    }

    private func fetchTogglProjects(_ key: String) async throws -> [TogglProject] {
        guard key.utf8.count <= 512 else {
            throw Ledger.CommandError(message: "Enter a Toggl Track API token.")
        }
        let data = try await Ledger.run(["toggl", "projects"], secretInput: Data(key.utf8))
        return try JSONDecoder().decode([TogglProject].self, from: data)
    }

    func updateRepository(_ project: Project, repo: String?, recorder: FocusRecorder) async {
        await perform(repo == nil ? "Unlinking GitHub repository…" : "Loading GitHub pull requests…") {
            if let repo {
                _ = try await Ledger.run(["github", "refresh", "--repo=\(repo)", "--", project.name])
            } else {
                _ = try await Ledger.run(["github", "unlink", "--", project.name])
            }
            try await recorder.applyRuleChange(["config"])
            try await self.update()
            self.notice = repo == nil ? "Repository unlinked" : "Pull requests refreshed"
        }
    }

    /// Loads pull requests for repositories that were linked but never loaded, such as those linked from a folder's
    /// git remote. Quiet: without GitHub CLI or a sign-in the link stays and the pull requests wait for a manual refresh.
    func loadNewLinks() async {
        let pending = snapshot?.projects.filter { $0.githubRepo != nil && $0.githubRefreshedAt == nil } ?? []
        guard !pending.isEmpty else { return }
        var loaded = false
        for project in pending {
            if (try? await Ledger.run(["github", "refresh", "--", project.name])) != nil { loaded = true }
        }
        if loaded { try? await update() }
    }

    /// Asks GitHub CLI whether you are signed in, and as whom. Quiet: it runs whenever Integrations opens.
    func checkGitHub() async {
        struct Result: Decodable { let status: GitHubStatus; let login: String? }
        do {
            let data = try await Ledger.run(["github", "status"])
            let result = try JSONDecoder().decode(Result.self, from: data)
            gitHubStatus = result.status
            gitHubLogin = result.login
        } catch {
            gitHubStatus = .unavailable
        }
    }

    private func importOpenRouter() async -> Bool {
        do {
            let key = try await IntegrationKeychain.openRouter.loadInBackground()
            openRouterConnected = key != nil
            guard let key else { return false }
            try await syncOpenRouter(key)
            openRouterMessage = nil
            await importProviderUsage(.openrouter, credential: key)
            return true
        } catch {
            openRouterMessage = error.localizedDescription
            return false
        }
    }

    private func importUsage(useCache: Bool = false) async throws {
        let data = try await Ledger.run(["sync", "--recent-days", "64"])
        let result = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let sources = result?["directories"] as? [String: [String]] ?? [:]
        let deferred = result?["files_deferred"] as? Int ?? 0
        let sourceErrors = result?["source_errors"] as? [String] ?? []
        if let error = sourceErrors.first {
            sourceMessage = error
        } else if sources.values.allSatisfy(\.isEmpty) {
            sourceMessage = "No local agent history found."
        } else if deferred > 0 {
            sourceMessage = "\(deferred) history files are still changing. Refresh again when the runs finish."
        } else {
            sourceMessage = nil
        }
        if snapshot?.models.isEmpty == false || (result?["events_processed"] as? Int ?? 0) > 0 {
            _ = try? await Ledger.run(["refresh-prices", "--if-stale"])
        }
        if await importOpenRouter() {
            if sourceMessage == "No local agent history found." { sourceMessage = nil }
        }
        for provider in AIProvider.allCases where provider != .openrouter {
            await importProviderUsage(provider)
        }
        try await loadSelectedPeriod(useCache: useCache)
        if sourceMessage == nil { notice = "Usage refreshed" }
    }

    func update() async throws {
        lastExplicitRefresh = .now
        try await loadSelectedPeriod(useCache: false)
    }

    private func loadSelectedPeriod(useCache: Bool, deferChangedLedgerFor: TimeInterval = 0) async throws {
        let selected = period
        let id = UUID()
        selectionLoad = id
        loadingPeriod = true
        defer {
            if selectionLoad == id {
                selectionLoad = nil
                loadingPeriod = false
            }
        }

        let request = await snapshots.request(selected, timezone: snapshot?.timezone ?? TimeZone.current.identifier)
        if useCache, let cached = await snapshots.cached(for: request), cached.createdAt >= lastExplicitRefresh {
            guard selectionLoad == id, period == selected, !Task.isCancelled else { return }
            if !showingSelectedPeriod || snapshot?.timezone != cached.snapshot.timezone { display(cached.snapshot) }
            if cached.madeToday() && (cached.version == request.version || Date.now.timeIntervalSince(cached.createdAt) < deferChangedLedgerFor) {
                return
            }
        }
        guard selectionLoad == id, period == selected, !Task.isCancelled else { return }
        let next = try await snapshots.rebuild(request, afterEdit: !useCache, earliestBuild: lastExplicitRefresh)
        if selectionLoad == id, period == selected, !Task.isCancelled { display(next) }
    }

    private func warmPeriods() {
        guard busy == nil, warming == nil, let timezone = snapshot?.timezone, let zone = TimeZone(identifier: timezone) else { return }
        let day = timezone + ":" + Day.local(Values.nowMillis(), zone).iso
        guard lastWarmDay != day else { return }
        lastWarmDay = day
        warming = Task(priority: .utility) {
            defer { warming = nil }
            for option in [.week, .month, .quarter, .last12Months, .lastWeek, .lastMonth] as [Period] {
                let request = await snapshots.request(option, timezone: timezone)
                if await snapshots.cached(for: request)?.madeToday() != true {
                    _ = try? await snapshots.rebuild(request, priority: .utility)
                }
            }
        }
    }

    private func display(_ next: Snapshot) {
        ProjectColor.choices.update(next.appearance ?? [])
        let names = { (snapshot: Snapshot?) in snapshot?.projects.map { "\($0.name)\u{1}\($0.client ?? "")" } }
        let projectsChanged = snapshot != nil && names(snapshot) != names(next)
        snapshot = next
        if projectsChanged { NotificationCenter.default.post(name: FocusRecorder.projectsChanged, object: nil) }
        revision += 1
    }

    func perform(_ status: String, action: () async throws -> Void) async {
        guard busy == nil else { return }
        busy = status
        error = nil
        notice = nil
        defer { busy = nil }
        do {
            try await action()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

func providerName(_ provider: String) -> String {
    switch provider {
    case "codex": "Codex"
    case "claude": "Claude Code"
    case "opencode": "OpenCode"
    case "amp": "Amp"
    case "droid": "Droid"
    case "codebuff": "Codebuff"
    case "cline": "Cline"
    case "hermes": "Hermes Agent"
    case "pi": "pi"
    case "openclaw": "OpenClaw"
    case "goose": "Goose"
    case "kilo": "Kilo"
    case "kimi": "Kimi"
    case "qwen": "Qwen Code"
    case "copilot": "GitHub Copilot CLI"
    case "gemini": "Gemini CLI"
    case "antigravity": "Antigravity"
    case "grok": "Grok Build"
    case "zcode": "ZCode"
    case "dsh": "DeepSeek Harness"
    default: provider
    }
}

func tokensText(_ count: Int) -> String {
    switch count {
    case 1_000_000_000...: (Double(count) / 1_000_000_000).formatted(.number.precision(.fractionLength(0...2))) + "B"
    case 1_000_000...: (Double(count) / 1_000_000).formatted(.number.precision(.fractionLength(0...2))) + "M"
    case 1_000...: (Double(count) / 1_000).formatted(.number.precision(.fractionLength(0...1))) + "K"
    default: count.formatted()
    }
}

func hoursText(_ hours: String?) -> String {
    guard let hours, let value = Double(hours) else { return "—" }
    let minutes = Int((value * 60).rounded())
    if value > 0 && minutes == 0 { return "< 1 min" }
    if minutes < 60 { return "\(minutes) min" }
    let rest = minutes % 60
    return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
}

func costText(_ amount: String, currency: String) -> String {
    guard let value = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")) else { return "—" }
    return value.formatted(.currency(code: currency))
}
