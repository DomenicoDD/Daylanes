import SwiftUI
import UniformTypeIdentifiers

@main
struct TrackerApp: App {
    @NSApplicationDelegateAdaptor(TrackerLifecycle.self) private var lifecycle

    var body: some Scene {
        Window("Daylanes", id: "main") {
            Dashboard()
                .licenceGate()
                .environmentObject(lifecycle.recorder)
                .environmentObject(lifecycle.ledger)
                .withGoogleCalendar(lifecycle)
                .frame(minWidth: 870, minHeight: 620)
        }
        .defaultSize(width: 1100, height: 750)
        .commands {
            UpdateCommands()
            AppMenuCommands(recorder: lifecycle.recorder)
        }
        Settings {
            SettingsWindow()
                .licenceGate()
                .environmentObject(lifecycle.recorder)
                .environmentObject(lifecycle.ledger)
                .withGoogleCalendar(lifecycle)
        }
        MenuBarExtra {
            MenuBarQuickView(recorder: lifecycle.recorder, model: lifecycle.ledger)
                .licenceGate(compact: true)
        } label: {
            MenuBarLabel(recorder: lifecycle.recorder)
        }
        .menuBarExtraStyle(.window)
    }
}

private extension View {
    @MainActor
    func withGoogleCalendar(_ lifecycle: TrackerLifecycle) -> some View {
        #if TRACKER_GOOGLE_CALENDAR
        environmentObject(lifecycle.googleCalendar)
        #else
        self
        #endif
    }
}

enum Page: Hashable {
    case timeline, diary, review, reports, overview, clients, projects, project(String), client(String)

    var title: String {
        switch self {
        case .timeline: "Timeline"
        case .diary: "Diary"
        case .review: "Review"
        case .reports: "Reports"
        case .overview: "Overview"
        case .clients: "Clients"
        case .projects: "Projects"
        case let .project(name): name
        case let .client(name): name
        }
    }
}

enum Sheet: Identifiable {
    case project(Activity?, Project?, client: String? = nil)
    case assign(Activity)
    case entry(Project, Bool)
    case repository(Project)
    case client(String?)
    case billing(BillingEditor.Scope, String)
    case rule(FocusRule?, String)
    case customPeriod(LedgerRange)

    var id: String {
        switch self {
        case .project: "project"
        case .assign: "assign"
        case .entry: "entry"
        case .repository: "github-repository"
        case .client: "client"
        case .billing: "billing"
        case .rule: "rule"
        case .customPeriod: "custom-period"
        }
    }
}

/// The two views of a project page: what happened, and how the project is set up.
enum ProjectTab: String, CaseIterable, Identifiable {
    case activity = "Activity"
    case settings = "Settings"
    var id: String { rawValue }
}

struct ProjectGroup: Identifiable {
    let title: String
    let client: String?
    let projects: [Project]
    var id: String { client.map { "client:" + $0 } ?? "kind:" + title }
}

/// Toolbar control for automatic tracking, modelled on a running timer.
struct TrackingPill: View {
    @ObservedObject var recorder: FocusRecorder

    var showRules: (() -> Void)?

    private var tint: Color {
        guard recorder.enabled else { return Color.white.opacity(0.55) }
        if case .recording = recorder.status { return Color(nsColor: NSColor(hex: 0x30D158)) }
        return .orange
    }

    var body: some View {
        Menu {
            SnoozeMenuItems(recorder: recorder, showRules: showRules)
        } label: {
            HStack(spacing: 7) {
                Circle().fill(tint).frame(width: 8, height: 8)
                TrackingStatusText(recorder: recorder).lineLimit(1).truncationMode(.tail).monospacedDigit()
                Image(systemName: recorder.enabled ? "moon.zzz" : "play.fill")
                    .font(.caption2).foregroundStyle(Color.white.opacity(0.6))
            }
            .font(.callout.weight(.medium))
            .foregroundStyle(Color.white.opacity(0.9))
            .padding(.horizontal, 11)
            .frame(height: 26)
            .frame(minWidth: 190, maxWidth: 260, alignment: .leading)
            .modifier(LegacyCapsule())
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(.plain)
        .fixedSize()
        .disabled(!recorder.ready)
        .help("Tracking is always on. Snooze it for a while, or add a don’t-track rule for apps and sites.")
        .accessibilityLabel(TrackingStatusText.label(recorder, now: Date()))
    }
}

struct Dashboard: View {
    @EnvironmentObject private var recorder: FocusRecorder
    @EnvironmentObject private var model: LedgerModel
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab: SettingsSection = .general
    @AppStorage("collapsedSidebarGroups") private var collapsedSidebarGroups = Data()
    @State private var page: Page? = .overview
    @State private var projectFilter = ""
    private static let noClient = "\u{1}no-client"
    @State private var sheet: Sheet?
    @State private var lastCustomPeriod: Period?
    @State private var showWelcome = false
    @AppStorage("hasSeenWelcome") private var hasSeenWelcome = false
    @State private var projectTab: ProjectTab = .activity
    @State private var filter = ""

    @FocusState private var searchFocused: Bool
    @StateObject private var inspector = Inspector()
    @StateObject private var reports = ReportModel()
    @State private var backStack: [Page] = []
    @State private var forwardStack: [Page] = []
    @State private var movingInHistory = false
    @State private var timelineJump: Date?
    @State private var columns = NavigationSplitViewVisibility.all
    @AppStorage("showInspector") private var showsTodayPanel = true

    var body: some View {
        NavigationSplitView(columnVisibility: $columns) {
            sidebar
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
                .toolbar(removing: .sidebarToggle)
        } detail: {
            HStack(spacing: Theme.cardInset) {
                Group {
                    if let snapshot = model.snapshot {
                        content(snapshot)
                    } else if model.busy != nil {
                        ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        VStack(spacing: 12) {
                            Text("Daylanes couldn’t load the ledger.").font(.headline)
                            Button("Try again") { Task { await model.start() } }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .cardSurface()
                .overlay(alignment: .bottom) { toast }
                if showsTodayPanel, (page ?? .overview) == .overview, let snapshot = model.snapshot {
                    TodayPanel(timezone: snapshot.timezone, filter: filter) {
                        openTimeline(on: Date())
                    }
                    .frame(width: 300)
                    .frame(maxHeight: .infinity)
                    .cardSurface()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
                if page == .timeline, inspector.content != nil {
                    InspectorPanel(inspector: inspector)
                        .frame(width: 300)
                        .frame(maxHeight: .infinity)
                        .cardSurface()
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .environmentObject(inspector)
            .animation(.snappy(duration: 0.2), value: inspector.id)
            .padding([.horizontal, .bottom], Theme.cardInset)
            .background(Theme.chrome)
            .navigationTitle((page ?? .overview).title)
            .toolbar { toolbar }
            .toolbarBackground(Theme.chrome, for: .windowToolbar)
            .toolbarBackground(.visible, for: .windowToolbar)
            .toolbarColorScheme(.dark, for: .windowToolbar)
            .modifier(HiddenWindowTitle())
            .onAppear {
                // The search field would otherwise take focus when the window opens.
                DispatchQueue.main.async { searchFocused = false; NSApp.keyWindow?.makeFirstResponder(nil) }
            }
        }
        .background(Theme.chrome)
        .tint(Theme.accent)
        .task { await model.start() }
        .task(id: model.period) { await model.selectPeriod() }
        .task { await model.maintainSnapshots() }
        .onChange(of: model.snapshot != nil, initial: true) { _, loaded in
            guard loaded, !hasSeenWelcome, let snapshot = model.snapshot else { return }
            if snapshot.projects.isEmpty { showWelcome = true }
            else { hasSeenWelcome = true }
        }
        .task { await recorder.prepare() }
        .task(id: model.notice) {
            guard model.notice != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { model.notice = nil }
        }
        .onChange(of: page) { previous, next in
            filter = ""
            projectTab = .activity
            inspector.close()
            if movingInHistory {
                movingInHistory = false
            } else if let previous, previous != next {
                backStack.append(previous)
                forwardStack.removeAll()
            }
            if previous == .timeline, next != .timeline { Task { await model.selectPeriod() } }
        }
        .alert("Daylanes", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: {
            Text(model.error ?? "")
        }
        .sheet(item: $sheet) { item in editor(item) }
        .onReceive(AppRoute.shared.$request) { request in
            guard let request else { return }
            DispatchQueue.main.async { AppRoute.shared.request = nil }
            handle(request)
        }
        .sheet(isPresented: $showWelcome, onDismiss: { hasSeenWelcome = true }) {
            WelcomeScreen { page = .project($0) }
        }
    }

    private var headerSubtitle: String {
        guard page == .overview || page == nil else { return subtitle }
        return "\(periodTitle(model.period)) · \(subtitle)"
    }

    private func periodTitle(_ period: Period) -> String {
        period.title(timezone: model.snapshot?.timezone ?? TimeZone.current.identifier)
    }

    private var subtitle: String {
        guard let snapshot = model.snapshot else { return "" }
        switch page ?? .overview {
        case .timeline, .diary: return ""
        case .reports: return reports.subtitle
        case .review: return "\(snapshot.unassigned.count.formatted()) unassigned · \(snapshot.dateLabel)"
        case let .project(name):
            let project = snapshot.projects.first { $0.name == name }
            return [project?.client, project?.category, snapshot.dateLabel].compactMap { $0 }.joined(separator: " · ")
        default: return snapshot.dateLabel
        }
    }

    /// Projects grouped the way the sidebar shows them: by client, then internal and personal work.
    private func projectGroups(_ snapshot: Snapshot) -> [ProjectGroup] {
        let byClient = Dictionary(grouping: snapshot.projects.filter { $0.client != nil }, by: { $0.client ?? "" })
        var groups = Set(snapshot.clients).union(byClient.keys).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }.map { ProjectGroup(title: $0, client: $0, projects: byClient[$0] ?? []) }
        for kind in ["billable", "internal", "personal"] {
            let rows = snapshot.projects.filter { $0.client == nil && $0.kind == kind }
            if let first = rows.first { groups.append(ProjectGroup(title: first.category, client: nil, projects: rows)) }
        }
        return groups
    }

    private var sidebar: some View {
        List {
            navRow(.overview) { Label("Overview", systemImage: "chart.bar") }
            navRow(.timeline) { Label("Timeline", systemImage: "calendar") }
            navRow(.diary) { Label("Diary", systemImage: "book") }
            navRow(.review, count: model.snapshot?.unassigned.count ?? 0) { Label("Review", systemImage: "tray") }
            navRow(.reports) { Label("Reports", systemImage: "doc.text") }
            navRow(.clients) { Label("Clients", systemImage: "person") }
            navRow(.projects) { Label("Projects", systemImage: "folder") }
            if let snapshot = model.snapshot {
                ForEach(projectGroups(snapshot)) { group in
                    Section(isExpanded: sidebarExpansion(for: group.id)) {
                        ForEach(group.projects) { project in
                            navRow(.project(project.name)) {
                                Label { Text(project.name) } icon: {
                                    Circle().fill(ProjectColor.color(for: project.name)).frame(width: 7, height: 7)
                                }
                            }
                                .contextMenu {
                                    Button("Edit project…") { sheet = .project(nil, project) }
                                    Button("Billing rates…") { sheet = .billing(.project, project.name) }
                                }
                        }
                        if let client = group.client, group.projects.isEmpty {
                            Text("No projects").foregroundStyle(.tertiary)
                                .selectionDisabled()
                                .contextMenu { clientMenu(client) }
                        }
                    } header: {
                        Text(group.title)
                            .contextMenu { if let client = group.client { clientMenu(client) } }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .tint(Color(white: 0.6))
        .scrollContentBackground(.hidden)
        .background(Theme.chrome)
        .environment(\.colorScheme, .dark)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                UpdateAvailableNotice()
                HStack {
                    Menu {
                        Button("New project…") { sheet = .project(nil, nil) }
                        Button("New client…") { sheet = .client(nil) }
                    } label: {
                        Image(systemName: "plus")
                            .frame(width: 26, height: 26)
                            .background(Theme.sidebarSelected, in: Circle())
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.white.opacity(0.85))
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Add a project or client")
                    .disabled(model.busy != nil)
                    Spacer()
                    Button {
                        openSettings()
                    } label: {
                        Label("Settings", systemImage: "slider.horizontal.3")
                    }
                    .buttonStyle(CircleButtonStyle(dark: true))
                    .help("Settings (⌘,)")
                    .accessibilityLabel("Settings")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Theme.chrome)
            .environment(\.colorScheme, .dark)
        }
        .task { UpdateChecker.shared.start() }
        .accessibilityIdentifier("tracker-navigation")
    }

    private func sidebarExpansion(for id: String) -> Binding<Bool> {
        Binding {
            let collapsed = (try? JSONDecoder().decode(Set<String>.self, from: collapsedSidebarGroups)) ?? []
            return !collapsed.contains(id)
        } set: { expanded in
            var collapsed = (try? JSONDecoder().decode(Set<String>.self, from: collapsedSidebarGroups)) ?? []
            if expanded { collapsed.remove(id) } else { collapsed.insert(id) }
            if let data = try? JSONEncoder().encode(collapsed) { collapsedSidebarGroups = data }
        }
    }

    /// A sidebar row drawn by hand, so the selection is a subtle dark pill rather than the system accent bar.
    private func navRow<Content: View>(_ target: Page, count: Int = 0, @ViewBuilder label: () -> Content) -> some View {
        let current: Page = {
            // A client's page has no sidebar row of its own, so keep Clients highlighted.
            if case .client = page { return .clients }
            return page ?? .overview
        }()
        let selected = current == target
        return Button { page = target } label: {
            HStack {
                label()
                    .labelStyle(SidebarLabelStyle(selected: selected))
                Spacer(minLength: 4)
                if count > 0 {
                    Text(count.formatted()).font(.caption).foregroundStyle(Color.white.opacity(0.45))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(selected ? Theme.sidebarSelected : Color.clear)
                .padding(.horizontal, 10)
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func clientMenu(_ client: String) -> some View {
        Button("Show \(client)") { page = .client(client) }
        Button("New project for \(client)…") { sheet = .project(nil, nil, client: client) }
        Button("Edit client…") { sheet = .client(client) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        // macOS 26 and later put each item on a light glass capsule; the design wants dark controls drawn by us.
        if #available(macOS 26.0, *) {
            ToolbarItem(placement: .navigation) { historyButtons }
                .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .principal) { SearchPill(text: $filter, focused: $searchFocused) }
                .sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .primaryAction) { trailingButtons }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .navigation) { historyButtons }
            ToolbarItem(placement: .principal) { SearchPill(text: $filter, focused: $searchFocused) }
            ToolbarItem(placement: .primaryAction) { trailingButtons }
        }
    }

    private var historyButtons: some View {
        HStack(spacing: 6) {
            Button("Toggle sidebar", systemImage: "sidebar.left") {
                withAnimation { columns = columns == .detailOnly ? .all : .detailOnly }
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .padding(.trailing, 4)
            Button("Back", systemImage: "chevron.left") { goBack() }
                .disabled(backStack.isEmpty)
                .keyboardShortcut("[", modifiers: .command)
            Button("Forward", systemImage: "chevron.right") { goForward() }
                .disabled(forwardStack.isEmpty)
                .keyboardShortcut("]", modifiers: .command)
        }
        .buttonStyle(CircleButtonStyle(dark: true))
    }

    private var trailingButtons: some View {
        HStack(spacing: 6) {
            TrackingPill(recorder: recorder)
            Button {
                Task { await model.refresh() }
            } label: {
                if model.busy != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .help(model.busy ?? "Import local agent history and refresh connected accounts (⌘R)")
            .disabled(model.busy != nil)
            .keyboardShortcut("r", modifiers: .command)
            Button {
                if let snapshot = model.snapshot { export(snapshot) }
            } label: {
                Label("Export CSV", systemImage: "square.and.arrow.up")
            }
            .help("Export the selected period as CSV")
            .disabled(model.busy != nil || model.snapshot == nil)
            if (page ?? .overview) == .overview {
                Button {
                    withAnimation(.snappy) { showsTodayPanel.toggle() }
                } label: {
                    Label(showsTodayPanel ? "Hide Today panel" : "Show Today panel", systemImage: "sidebar.right")
                }
                .help("Show or hide Today beside the Overview")
            }
        }
        .buttonStyle(CircleButtonStyle(dark: true))
    }

    private func goBack() {
        guard let target = backStack.popLast() else { return }
        if let page { forwardStack.append(page) }
        movingInHistory = true
        page = target
    }

    private func goForward() {
        guard let target = forwardStack.popLast() else { return }
        if let page { backStack.append(page) }
        movingInHistory = true
        page = target
    }

    private func openTimeline(on day: Date) {
        timelineJump = day
        page = .timeline
    }

    /// The period menu shown in page headers.
    private var periodMenu: some View {
        Menu {
            Section("Time range") {
                ForEach(Period.presets) { period in
                    Button { model.period = period } label: {
                        periodMenuLabel(periodTitle(period), selected: model.period == period)
                    }
                }
                Divider()
                Button {
                    let timezone = model.snapshot?.timezone ?? TimeZone.current.identifier
                    sheet = .customPeriod((lastCustomPeriod ?? model.period).range(timezone: timezone))
                } label: {
                    let applyingCustom: Bool = if case .custom = model.period { true } else { false }
                    periodMenuLabel("Custom…", selected: applyingCustom)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(periodTitle(model.period))
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(PillButtonStyle())
        .fixedSize()
        .disabled(model.busy != nil)
    }

    @ViewBuilder
    private func periodMenuLabel(_ title: String, selected: Bool) -> some View {
        if selected {
            Label(title, systemImage: "checkmark").accessibilityAddTraits(.isSelected)
        } else {
            Text(title)
        }
    }

    @ViewBuilder
    private func pageActions(_ snapshot: Snapshot) -> some View {
        switch page ?? .overview {
        case let .project(name):
            if let project = snapshot.projects.first(where: { $0.name == name }) {
                Menu {
                    Button("Log time…") { sheet = .entry(project, false) }
                    Button("Add expense…") { sheet = .entry(project, true) }
                    Divider()
                    Button("Edit project…") { sheet = .project(nil, project) }
                    Button("Project settings") { projectTab = .settings }
                    Button(project.githubRepo == nil ? "Link GitHub repository…" : "Manage GitHub repository…") {
                        sheet = .repository(project)
                    }
                    Button("Integrations settings…") {
                        settingsTab = .integrations
                        openSettings()
                    }
                } label: {
                    Label("Add", systemImage: "plus")
                }
                .help("Log time, add an expense, or edit this project")
                .disabled(model.busy != nil)
            }
        case .clients:
            Button { sheet = .client(nil) } label: { Label("New client", systemImage: "plus") }
                .help("Create a client")
                .disabled(model.busy != nil)
        case .projects:
            Button {
                sheet = .project(nil, nil, client: projectFilter.isEmpty || projectFilter == Self.noClient ? nil : projectFilter)
            } label: { Label("New project", systemImage: "plus") }
                .help("Create a project for a client")
                .disabled(model.busy != nil)
        case .reports:
            ReportExportActions(report: reports, ledger: model)
        case let .client(name):
            Button { sheet = .project(nil, nil, client: name) } label: { Label("New project", systemImage: "plus") }
                .help("Create a project for \(name)")
                .disabled(model.busy != nil)
            Button("Edit…") { sheet = .client(name) }
                .buttonStyle(PillButtonStyle())
                .help("Rename \(name) or change its icon")
                .disabled(model.busy != nil)
            if name != model.snapshot?.selfClient {
                Button("Billing…") { sheet = .billing(.client, name) }
                    .buttonStyle(PillButtonStyle())
                    .help("Rates and the monthly cap for \(name)")
                    .disabled(model.busy != nil)
            }
        default:
            EmptyView()
        }
    }

    /// Short-lived status shown over the bottom of the window instead of a permanent status bar.
    @ViewBuilder
    private var toast: some View {
        let message: (String, String)? = if let notice = model.notice {
            (notice, "checkmark.circle")
        } else if let source = model.sourceMessage, page == .overview || page == .review {
            (source, "info.circle")
        } else {
            nil
        }
        if let message, model.busy == nil {
            Label(message.0, systemImage: message.1)
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator))
                .padding(.bottom, 14)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder
    private func content(_ snapshot: Snapshot) -> some View {
        if page == .reports {
            reportsContent(snapshot)
        } else if page == .diary {
            DiaryPage(snapshot: snapshot)
        } else {
            scrollingContent(snapshot)
        }
    }

    /// Reports fill the card: the options column and the preview scroll on their own, and the report has its own
    /// period, so the header has no period menu.
    private func reportsContent(_ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            PageHeader(title: Page.reports.title, subtitle: headerSubtitle, icon: nil) {
                pageActions(snapshot)
            }
            ReportPage(report: reports, snapshot: snapshot, revision: model.revision)
        }
        .padding(.horizontal, 28)
        .padding(.top, 24)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("tracker-content")
    }

    private func scrollingContent(_ snapshot: Snapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if case .client = page {
                    Button { page = .clients } label: { Label("All clients", systemImage: "chevron.left") }
                        .buttonStyle(.link)
                        .padding(.bottom, -14)
                }
                if page != .timeline {
                    PageHeader(title: (page ?? .overview).title, subtitle: model.showingSelectedPeriod ? headerSubtitle : "",
                               icon: { if case let .client(name) = page { AnyView(ClientIcon(client: name, size: 30)) } else { nil } }(),
                               openProjectSettings: projectSettingsAction) {
                        if model.showingSelectedPeriod { pageActions(snapshot) }
                        periodMenu
                    }
                }
                if page == .timeline || model.showingSelectedPeriod {
                    switch page ?? .overview {
                    case .timeline:
                        FocusTimeline(projects: snapshot.projects, timezone: snapshot.timezone, jump: $timelineJump) {
                            Task { await model.reload() }
                        }
                    case .overview:
                        usage(snapshot)
                    case .review:
                        review(snapshot)
                    case .reports, .diary:
                        EmptyView()
                    case let .project(name):
                        if let project = snapshot.projects.first(where: { $0.name == name }) {
                            projectPage(project, snapshot)
                        } else {
                            empty("Project not found", "It may have been renamed. Choose it again in the sidebar.", "folder")
                        }
                    case .clients:
                        clientsPage(snapshot)
                    case .projects:
                        projectsPage(snapshot)
                    case let .client(name):
                        clientPage(name, snapshot)
                    }
                } else if model.loadingPeriod || model.busy != nil {
                    ProgressView("Loading time range…").padding(.vertical, 16)
                } else {
                    Button("Reload time range") { Task { await model.selectPeriod() } }
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 24)
            .frame(maxWidth: 1120)
            .frame(maxWidth: .infinity)
        }
        .scrollContentBackground(.hidden)
        .scrollIndicators(.never)
        .accessibilityIdentifier("tracker-content")
    }

    private var projectSettingsAction: (() -> Void)? {
        guard case .project = page else { return nil }
        return { projectTab = .settings }
    }

    /// Period totals for a set of projects, used by the Clients and Projects lists.
    private struct Totals {
        var hours = 0.0
        var tokens = 0
        var apiUsd = 0.0
        var priced = false
    }

    private func totals(_ projects: [Project], _ snapshot: Snapshot) -> Totals {
        var result = Totals()
        for project in projects {
            guard let summary = snapshot.projectTotals[project.name] else { continue }
            result.hours += Double(summary.humanHours) ?? 0
            result.tokens += summary.allTokens
            if let api = summary.apiEquivalentUsd.flatMap(Double.init) {
                result.apiUsd += api
                result.priced = true
            }
        }
        return result
    }

    private func clientNames(_ snapshot: Snapshot) -> [String] {
        Set(snapshot.clients).union(snapshot.projects.compactMap(\.client))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private func columnHeader(_ first: String) -> some View {
        HStack(spacing: 12) {
            Text(first).frame(maxWidth: .infinity, alignment: .leading)
            Text("Time").frame(width: 90, alignment: .trailing)
            Text("Agent tokens").frame(width: 100, alignment: .trailing)
            Text("API equivalent").frame(width: 110, alignment: .trailing)
            Color.clear.frame(width: 12)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.bottom, 4)
    }

    private func totalsRow(title: String, subtitle: String, dot: Color?, client: String? = nil, totals: Totals,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                HStack(spacing: 8) {
                    if let client { ClientIcon(client: client, size: 24) }
                    if let dot { Circle().fill(dot).frame(width: 9, height: 9) }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(title).fontWeight(.medium).lineLimit(1)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(totals.hours > 0 ? hoursText(String(totals.hours)) : "—").frame(width: 90, alignment: .trailing)
                Text(totals.tokens > 0 ? tokensText(totals.tokens) : "—").frame(width: 100, alignment: .trailing)
                Text(totals.priced ? costText(String(format: "%.2f", totals.apiUsd), currency: "USD") : "—")
                    .frame(width: 110, alignment: .trailing)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary).frame(width: 12)
                    .accessibilityHidden(true)
            }
            .monospacedDigit()
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func clientsPage(_ snapshot: Snapshot) -> some View {
        let names = clientNames(snapshot)
        if names.isEmpty {
            empty("No clients yet", "Create a client with New client, then add its projects.", "person.2")
        } else {
            VStack(spacing: 0) {
                columnHeader("Client")
                Divider()
                ForEach(names, id: \.self) { name in
                    let projects = snapshot.projects.filter { $0.client == name }
                    let count = projects.isEmpty ? "No projects yet"
                        : projects.count == 1 ? "1 project" : "\(projects.count) projects"
                    totalsRow(title: name,
                              subtitle: name == snapshot.selfClient ? "Your own work · \(count)" : count,
                              dot: nil, client: name, totals: totals(projects, snapshot)) { page = .client(name) }
                    Divider()
                }
            }
            let unclient = snapshot.projects.filter { $0.client == nil }
            if !unclient.isEmpty {
                Button("\(unclient.count) internal or personal \(unclient.count == 1 ? "project has" : "projects have") no client") {
                    projectFilter = Self.noClient
                    page = .projects
                }
                .buttonStyle(.link)
                .font(.callout)
            }
        }
    }

    @ViewBuilder
    private func projectsPage(_ snapshot: Snapshot) -> some View {
        let names = clientNames(snapshot)
        Menu {
            Picker("Client", selection: $projectFilter) {
                Text("All clients").tag("")
                ForEach(names, id: \.self) { Text($0).tag($0) }
                if snapshot.projects.contains(where: { $0.client == nil }) {
                    Divider()
                    Text("No client").tag(Self.noClient)
                }
            }
            .pickerStyle(.inline)
        } label: {
            HStack(spacing: 4) {
                Text(projectFilter.isEmpty ? "All clients" : projectFilter == Self.noClient ? "No client" : projectFilter)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(PillButtonStyle())
        .fixedSize()
        .help("Show the projects of one client")
        let groups = projectGroups(snapshot).filter { group in
            projectFilter.isEmpty || group.client == projectFilter || (projectFilter == Self.noClient && group.client == nil)
        }
        if snapshot.projects.isEmpty {
            empty("No projects yet", "Create a project with New project. Each one belongs to a client.", "folder")
        } else {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(groups) { group in
                    VStack(spacing: 0) {
                        columnHeader(group.title)
                        Divider()
                        if group.projects.isEmpty {
                            Button("Add a project for \(group.title)…") { sheet = .project(nil, nil, client: group.client) }
                                .buttonStyle(.link)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 10)
                            Divider()
                        }
                        ForEach(group.projects) { project in
                            totalsRow(title: project.name,
                                      subtitle: [project.category, project.githubRepo].compactMap { $0 }.joined(separator: " · "),
                                      dot: ProjectColor.color(for: project.name),
                                      totals: totals([project], snapshot)) { page = .project(project.name) }
                            Divider()
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func clientPage(_ name: String, _ snapshot: Snapshot) -> some View {
        let projects = snapshot.projects.filter { $0.client == name }
        if projects.isEmpty {
            empty("No projects for this client", "Create the first project for \(name).", "folder")
            Button { sheet = .project(nil, nil, client: name) } label: { Label("New project…", systemImage: "plus") }
                .buttonStyle(.borderedProminent)
                .disabled(model.busy != nil)
        } else {
            let sum = totals(projects, snapshot)
            HStack(spacing: 0) {
                stat("Time", sum.hours > 0 ? hoursText(String(sum.hours)) : "—")
                Divider().frame(height: 37)
                stat("Agent tokens", sum.tokens > 0 ? tokensText(sum.tokens) : "—")
                Divider().frame(height: 37)
                stat("API equivalent", sum.priced ? costText(String(format: "%.2f", sum.apiUsd), currency: "USD") : "—")
            }
            .padding(.vertical, 13)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            ProviderUsageSection(snapshot: snapshot, projects: Set(projects.map(\.name)))
            if name != snapshot.selfClient, let bill = snapshot.billing {
                billingSection(bill, title: "Billing", clients: bill.clients.filter { $0.client == name },
                               edit: .billing(.client, name))
            }
            HStack {
                Text("Projects").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                Button { sheet = .project(nil, nil, client: name) } label: { Label("New project…", systemImage: "plus") }
                    .disabled(model.busy != nil)
            }
            VStack(spacing: 0) {
                columnHeader("Project")
                Divider()
                ForEach(projects) { project in
                    totalsRow(title: project.name,
                              subtitle: [project.category, project.githubRepo].compactMap { $0 }.joined(separator: " · "),
                              dot: ProjectColor.color(for: project.name),
                              totals: totals([project], snapshot)) { page = .project(project.name) }
                    Divider()
                }
            }
        }
    }

    @ViewBuilder
    private func usage(_ snapshot: Snapshot) -> some View {
        if model.period == .week || model.period == .lastWeek {
            OverviewWeekStrip(snapshot: snapshot, open: openTimeline(on:))
        }
        let summaryParts = overviewSummaryParts(snapshot)
        if !summaryParts.isEmpty { SummarySentence(parts: summaryParts) }
        HStack(spacing: 12) {
            let totals = snapshot.totals
            let loggedHours = snapshot.dailyHumanMillis.values.reduce(0, +) / 3_600_000
            StatTile(title: "Logged human time", value: hoursText(String(loggedHours)),
                     detail: snapshot.billing.map { bill in
                         let hours = bill.clients.flatMap(\.projects).flatMap(\.lines)
                             .filter { $0.item == "you" }.compactMap { Double($0.hours ?? "") }.reduce(0, +)
                         return hours > 0 ? "\(hoursText(String(hours))) billable" : "Nothing billable yet"
                     })
                .help("Assigned app time, manually logged time, and imported Toggl Track time")
            StatTile(title: "Expenses", value: costText(totals.providerExpenses, currency: snapshot.currency),
                     detail: "Actual provider charges")
            StatTile(title: "API equivalent", value: totals.apiEquivalentUsd.map { costText($0, currency: "USD") } ?? "—",
                     detail: totals.tokensWithoutApiPrice > 0
                        ? "\(tokensText(totals.tokensWithoutApiPrice)) unpriced tokens · USD" : "OpenRouter base rates · USD")
        }
        ProviderUsageSection(snapshot: snapshot)
        if let account = snapshot.openrouterAccount {
            openRouterActivity(account)
        }
        agentsSection(snapshot.totals)
        if let bill = snapshot.billing, !bill.clients.isEmpty {
            billingSection(bill, title: "Billing", clients: bill.clients)
        }

        HStack {
            SectionTitle(title: "Recent activity")
            if !snapshot.unassigned.isEmpty {
                Button("Review \(snapshot.unassigned.count.formatted()) unassigned") { page = .review }
                    .buttonStyle(PillButtonStyle())
            }
        }
        if snapshot.activity.isEmpty {
            empty("No agent activity in this period", "Refresh local history or choose another time range.", "clock")
        } else {
            activityList(Array(snapshot.activity.prefix(12)), currency: snapshot.currency, compact: true)
        }
    }

    private func overviewSummaryParts(_ snapshot: Snapshot) -> [SummarySentence.Part] {
        var parts: [SummarySentence.Part] = []
        if snapshot.unassignedFocusMillis > 0 {
            parts += [.chip(hoursText(String(snapshot.unassignedFocusMillis / 3_600_000)), .amber),
                      .text("of app time to assign")]
        }
        if !snapshot.activity.isEmpty {
            if !parts.isEmpty { parts.append(.text("·")) }
            let runs = snapshot.activity.count
            parts += [.text("Agent activity"), .chip("\(runs) \(runs == 1 ? "group" : "groups")", .neutral)]
            if let api = snapshot.totals.apiEquivalentUsd {
                parts += [.text("worth"), .chip(costText(api, currency: "USD"), .green)]
            }
        }
        if !snapshot.unassigned.isEmpty {
            parts += [.text("·"), .chip("\(snapshot.unassigned.count) to review", .amber)]
        }
        return parts
    }

    private func agentsSection(_ summary: Summary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            SectionTitle(title: "Agents", note: "Tokens · API value · run time")
                .padding(.bottom, 6)
            let providers = ["codex", "claude"] + summary.agents.keys.filter { !["codex", "claude"].contains($0) }.sorted()
            ForEach(providers, id: \.self) { provider in
                providerRow(provider, usage: summary.agents[provider], maximum: summary.allTokens)
                Divider().overlay(Theme.hairline)
            }
            if summary.pricedTokens > 0 {
                Text("Manual-rate estimate: \(costText(summary.estimatedTokenValue, currency: "USD"))")
                    .font(.caption).foregroundStyle(Theme.secondary).padding(.top, 4)
            }
        }
    }

    private func openRouterActivity(_ account: OpenRouterAccount) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("OpenRouter activity").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if let start = account.start, let end = account.endExclusive {
                HStack(spacing: 0) {
                    stat("Reported spend", costText(account.totals.spendUsd, currency: "USD"))
                    Divider().frame(height: 37)
                    stat("Requests", account.totals.requests.formatted())
                    Divider().frame(height: 37)
                    stat("Tokens", tokensText(account.totals.tokens))
                }
                .padding(.vertical, 10)
                .background(Color(nsColor: .controlBackgroundColor))
                Text("\(start) to \(end) (end excluded, UTC)")
                    .font(.caption).foregroundStyle(.secondary)
                if !account.models.isEmpty {
                    DisclosureGroup("Usage by model") {
                        VStack(spacing: 8) {
                            ForEach(account.models) { row in
                                HStack {
                                    Text(row.model)
                                    Spacer()
                                    Text("\(row.requests.formatted()) requests · \(tokensText(row.tokens)) tokens")
                                        .foregroundStyle(.secondary)
                                    Text(costText(row.spendUsd, currency: "USD"))
                                        .monospacedDigit().frame(minWidth: 84, alignment: .trailing)
                                }
                                .font(.callout)
                            }
                        }
                        .padding(.top, 8)
                    }
                }
            } else {
                Text("OpenRouter has no synced days in this period.").foregroundStyle(.secondary)
            }
            Text("Last synced \(Date(timeIntervalSince1970: account.fetchedAt).formatted(date: .abbreviated, time: .shortened))")
                .font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func usageSummary(_ summary: Summary, currency: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                stat("Human time", hoursText(summary.humanHours))
                Divider().frame(height: 37)
                stat("Actual expenses", costText(summary.providerExpenses, currency: currency))
                Divider().frame(height: 37)
                stat("API equivalent",
                     summary.apiEquivalentUsd.map { costText($0, currency: "USD") } ?? "—",
                     detail: summary.tokensWithoutApiPrice > 0
                        ? "\(tokensText(summary.tokensWithoutApiPrice)) unpriced tokens · USD" : "OpenRouter base rates · USD")
            }
            .padding(.vertical, 13)
            .background(Color(nsColor: .controlBackgroundColor))
            Divider()
            if summary.pricedTokens > 0 {
                Text("Manual-rate estimate: \(costText(summary.estimatedTokenValue, currency: currency))")
                    .font(.caption).foregroundStyle(.secondary).padding(.vertical, 8).padding(.horizontal, 16)
                Divider()
            }
            ForEach(["codex", "claude"] + summary.agents.keys.filter { !["codex", "claude"].contains($0) }.sorted(), id: \.self) { provider in
                providerRow(provider, usage: summary.agents[provider], maximum: summary.allTokens)
                Divider()
            }
        }
    }

    private func stat(_ title: String, _ value: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).font(.title2.weight(.semibold).monospacedDigit())
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
        .accessibilityElement(children: .combine)
    }

    private func providerRow(_ provider: String, usage: AgentUsage?, maximum: Int) -> some View {
        let count = usage?.tokens.total ?? 0
        let proportion = Double(count) / Double(max(1, maximum))
        return HStack(spacing: 12) {
            Image(systemName: provider == "claude" ? "asterisk" : "terminal")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.text)
                .frame(width: 26, height: 26)
                .background(Theme.block, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .accessibilityHidden(true)
            Text(providerName(provider)).fontWeight(.medium)
                .frame(width: 102, alignment: .leading)
            GeometryReader { proxy in
                Capsule().fill(Theme.block)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.accent.opacity(provider == "codex" ? 1 : 0.75))
                            .frame(width: proxy.size.width * proportion)
                    }
            }
            .frame(height: 5)
            .accessibilityHidden(true)
            Text("\(tokensText(count)) tokens")
                .font(.body.monospacedDigit())
                .help("\(count.formatted()) tokens")
                .frame(width: 116, alignment: .trailing)
            Text(usage?.apiEquivalentUsd.map { costText($0, currency: "USD") } ?? "—").monospacedDigit()
                .frame(width: 98, alignment: .trailing)
                .help("API equivalent")
            Text(hoursText(usage?.runtimeHours)).monospacedDigit().foregroundStyle(Theme.secondary)
                .frame(width: 90, alignment: .trailing)
                .help(usage?.runtimeKind == "turn elapsed" ? "Elapsed turns" : "Estimated request time")
        }
        .frame(height: 49)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func review(_ snapshot: Snapshot) -> some View {
        if snapshot.unassigned.isEmpty {
            empty("Nothing to review", "Agent runs without a project appear here. Review unassigned app time on the Timeline.", "tray")
        } else {
            TextField("Search chats, folders, branches or agents", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 350)
            let rows = snapshot.unassigned.filter(matches)
            if rows.isEmpty {
                empty("No matching activity", "Try another search.", "magnifyingglass")
            } else {
                activityList(rows, currency: snapshot.currency)
            }
        }
    }

    @ViewBuilder
    private func projectPage(_ project: Project, _ snapshot: Snapshot) -> some View {
        let rows = snapshot.activity.filter { $0.project == project.name }
        Picker("Section", selection: $projectTab) {
            ForEach(ProjectTab.allCases) { tab in Text(tab.rawValue).tag(tab) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        if projectTab == .activity {
            if let summary = snapshot.projectTotals[project.name] {
                usageSummary(summary, currency: snapshot.currency)
            }
            ProviderUsageSection(snapshot: snapshot, projects: [project.name])
            if let repo = project.githubRepo {
                ProjectGitHubActivity(repo: repo, start: snapshot.start, end: snapshot.endExclusive,
                                      timezone: snapshot.timezone, refreshedAt: project.githubRefreshedAt)
            }
            Text("Agent activity").font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            if rows.isEmpty {
                empty("No agent activity in this period", "Assign work from Review to see it here.", "folder")
            } else {
                activityList(rows, currency: snapshot.currency)
            }
        } else {
            projectSettings(project, snapshot)
        }
    }

    /// GitHub, folders, tracking rules and billing for a project, kept off the activity view.
    @ViewBuilder
    private func projectSettings(_ project: Project, _ snapshot: Snapshot) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(project.githubRepo ?? "GitHub").fontWeight(.medium)
                Spacer()
                manageGitHub(project, title: project.githubRepo == nil ? "Link repository…" : "Manage…")
            }
            if project.githubRepo != nil, let updated = project.githubRefreshedAt {
                Text("GitHub loaded \(Date(timeIntervalSince1970: updated / 1000).formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            projectSources(project)
            ProjectRules(project: project) { sheet = .rule($0, project.name) }
        }
        .padding(.bottom, 4)
        if project.kind == "billable", let bill = snapshot.billing {
            let clients = bill.clients.filter { $0.client == project.client }.map { client in
                BillingSummary.ClientBill(client: client.client, projects: client.projects.filter { $0.project == project.name },
                                          monthlyCap: client.monthlyCap, capReduction: nil, total: client.total)
            }.filter { !$0.projects.isEmpty }
            billingSection(bill, title: "Billing", clients: clients, edit: .billing(.project, project.name), showTotals: false)
        }
    }

    /// Invoice lines for the period: your time, agent time and agent usage per project, then the client total.
    @ViewBuilder
    private func billingSection(_ bill: BillingSummary, title: String, clients: [BillingSummary.ClientBill],
                                edit: Sheet? = nil, showTotals: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
                Spacer()
                if let edit {
                    Button("Billing rates…") { sheet = edit }.disabled(model.busy != nil)
                }
            }
            if clients.isEmpty {
                Text("No billable time or agent work in this period.")
                    .foregroundStyle(.secondary)
            }
            ForEach(clients) { client in
                VStack(alignment: .leading, spacing: 0) {
                    if showTotals && clients.count > 1 || edit == nil {
                        Text(client.client ?? "No client").font(.headline).padding(.horizontal, 16).padding(.vertical, 9)
                        Divider()
                    }
                    ForEach(client.projects) { project in
                        ForEach(project.lines) { line in
                            billingLine(project.project, line, currency: bill.currency)
                            Divider()
                        }
                    }
                    if let reduction = client.capReduction {
                        HStack {
                            Text("Monthly cap on agents\(client.monthlyCap.map { " (\(costText($0, currency: bill.currency)))" } ?? "")")
                            Spacer()
                            Text("−" + costText(reduction, currency: bill.currency)).monospacedDigit()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 8)
                        Divider()
                    }
                    if showTotals {
                        HStack {
                            Text("Total").fontWeight(.semibold)
                            Spacer()
                            Text(costText(client.total, currency: bill.currency)).fontWeight(.semibold).monospacedDigit()
                        }
                        .padding(.horizontal, 16).padding(.vertical, 9)
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            }
            if bill.needsExchangeRate {
                Button("Usage lines need a USD exchange rate: set it in Settings → AI costs") {
                    settingsTab = .ai
                    openSettings()
                }
                .buttonStyle(.link).font(.callout)
            }
        }
    }

    private func billingLine(_ project: String, _ line: BillingSummary.Line, currency: String) -> some View {
        let label = switch line.item {
        case "you": "Your time"
        case "agent_time": "AI agents, time"
        default: "AI agents, usage"
        }
        let detail: String = switch line.item {
        case "agent_usage":
            "\(line.apiUsd.map { costText($0, currency: "USD") } ?? "—") API value × \(line.markup ?? "1")"
                + ((line.tokensWithoutApiPrice ?? 0) > 0 ? " · \(tokensText(line.tokensWithoutApiPrice ?? 0)) tokens unpriced" : "")
        default:
            "\(hoursText(line.hours)) × \(line.rate.map { costText($0, currency: currency) + "/h" } ?? "no rate set")"
        }
        return HStack(spacing: 10) {
            Circle().fill(ProjectColor.color(for: project)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(project) · \(label)")
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text(line.amount.map { costText($0, currency: currency) } ?? "—").monospacedDigit()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    /// The folders and worktrees whose agent work and app time go to this project, with each folder's repository.
    @ViewBuilder
    private func projectSources(_ project: Project) -> some View {
        let sources = project.folderSources ?? project.folders.map { FolderSource(path: $0, repo: nil) }
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Folders").fontWeight(.medium)
                Spacer()
                Button("Add folder…") { addFolder(project) }.disabled(model.busy != nil)
            }
            Text(sources.isEmpty
                 ? "Add the folders you work in for \(project.client.map { "\($0) › " } ?? "")\(project.name). Agent work in them and their worktrees is matched to this project automatically."
                 : "Agent work in these folders and their worktrees goes to \(project.client.map { "\($0) › " } ?? "")\(project.name).")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(sources) { source in
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(.secondary).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(URL(fileURLWithPath: source.path).lastPathComponent).lineLimit(1)
                        Text(source.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    if let repo = source.repo {
                        if repo.caseInsensitiveCompare(project.githubRepo ?? "") == .orderedSame {
                            Label(repo, systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
                        } else if project.githubRepo == nil {
                            Button("Link \(repo)") { linkRepository(project, repo) }
                                .controlSize(.small).disabled(model.busy != nil)
                                .help("Use this folder's GitHub repository for pull request matching")
                        } else {
                            Text(repo).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Button { removeFolder(project, source.path) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Stop sending this folder's work to \(project.name)")
                        .accessibilityLabel("Remove folder \(source.path)")
                        .disabled(model.busy != nil)
                }
                .padding(.vertical, 2)
            }
        }
        .padding(.top, 6)
    }

    private func addFolder(_ project: Project) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add to \(project.name)"
        guard panel.runModal() == .OK else { return }
        let paths = panel.urls.map(\.path)
        Task {
            await model.perform("Adding folders…") {
                for path in paths { _ = try await Ledger.run(["project", "map", "--", project.name, path]) }
                // Linked once every folder is in, so folders naming different repositories leave the choice to you.
                _ = try? await Ledger.run(["github", "autolink", "--project", project.name])
                try await model.update()
                let linked = model.snapshot?.projects.first { $0.name == project.name }?.githubRepo
                model.notice = (paths.count == 1 ? "Folder added" : "\(paths.count) folders added")
                    + (project.githubRepo == nil ? linked.map { ", linked to \($0)" } ?? "" : "")
            }
            await model.loadNewLinks()
        }
    }

    private func removeFolder(_ project: Project, _ path: String) {
        Task {
            await model.perform("Removing folder…") {
                _ = try await Ledger.run(["project", "unmap", "--", project.name, path])
                try await model.update()
                model.notice = "Folder removed"
            }
        }
    }

    private func linkRepository(_ project: Project, _ repo: String) {
        Task { await model.updateRepository(project, repo: repo, recorder: recorder) }
    }

    private func manageGitHub(_ project: Project, title: String) -> some View {
        Button(title) { sheet = .repository(project) }
        .disabled(model.busy != nil)
    }

    private func activityList(_ rows: [Activity], currency: String, compact: Bool = false) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(rows) { activity in
                ActivityRow(activity: activity, currency: currency, disabled: model.busy != nil, compact: compact,
                            openChat: { url in
                    if !NSWorkspace.shared.open(url) {
                        model.error = "Couldn’t open this chat. Check that \(providerName(activity.provider)) is installed."
                    }
                }) {
                    sheet = .assign(activity)
                }
                Divider().overlay(Theme.hairline)
            }
        }
    }

    private func empty(_ title: String, _ detail: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon).font(.headline)
            Text(detail).foregroundStyle(.secondary)
        }
        .padding(.vertical, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func matches(_ activity: Activity) -> Bool {
        let chats = (activity.sessions ?? []).flatMap { [$0.title, $0.sourceContext] }
        return filter.isEmpty || ([activity.folder, activity.branch, activity.task, providerName(activity.provider)] + chats)
            .compactMap { $0 }.contains { $0.localizedCaseInsensitiveContains(filter) }
    }

    @ViewBuilder
    private func editor(_ item: Sheet) -> some View {
        switch item {
        case let .customPeriod(range):
            CustomPeriodEditor(range: range) { period in
                lastCustomPeriod = period
                model.period = period
                sheet = nil
            }
        case let .project(activity, existing, client):
            ProjectEditor(folder: activity?.folder, existing: existing,
                          clients: model.snapshot?.clients ?? [], initialClient: client,
                          selfClient: model.snapshot?.selfClient ?? "Me") { name, client, kind, folder, color in
                sheet = nil
                Task {
                    await model.perform("Saving project…") {
                        var args = ["project", "add", "--kind", kind]
                        if existing == nil { args += ["--new-only"] }
                        if !client.isEmpty { args += ["--client=\(client)"] }
                        if activity == nil, let folder { args += ["--folder=\(folder)"] }
                        args += ["--", name]
                        _ = try await Ledger.run(args)
                        if let color { _ = try await Ledger.run(["appearance", "--project=\(name)", "--color=\(color)"]) }
                        if let activity, let snapshot = model.snapshot {
                            _ = try await Ledger.run(assignment(activity, name, snapshot, remember: folder != nil))
                        }
                        if folder != nil { _ = try? await Ledger.run(["github", "autolink", "--project", name]) }
                        try await model.update()
                        page = .project(name)
                        model.notice = "Project saved"
                    }
                    await model.loadNewLinks()
                }
            }
        case let .assign(activity):
            AssignmentEditor(activity: activity, projects: model.snapshot?.projects ?? []) { project, remember in
                guard let snapshot = model.snapshot else { return }
                sheet = nil
                Task {
                    await model.perform("Assigning activity…") {
                        _ = try await Ledger.run(assignment(activity, project, snapshot, remember: remember))
                        if remember { _ = try? await Ledger.run(["github", "autolink", "--project", project]) }
                        try await model.update()
                        model.notice = "Activity assigned to \(project)"
                    }
                    if remember { await model.loadNewLinks() }
                }
            } new: {
                sheet = .project(activity, nil)
            }
        case let .entry(project, expense):
            EntryEditor(project: project, isExpense: expense, currency: model.snapshot?.currency ?? "EUR") {
                amount, description, task, reimbursable in
                sheet = nil
                Task {
                    await model.perform("Saving entry…") {
                        var args = expense ? ["expense", project.name, description, "--amount", amount]
                            : ["time", project.name, "--minutes", amount, "--activity", description]
                        if !task.isEmpty { args += ["--task", task] }
                        if expense && reimbursable { args += ["--reimburse"] }
                        _ = try await Ledger.run(args)
                        try await model.update()
                        model.notice = "Entry saved"
                    }
                }
            }
        case let .repository(project):
            RepoEditor(project: project) { repo in
                sheet = nil
                Task { await model.updateRepository(project, repo: repo, recorder: recorder) }
            }
        case let .client(previous):
            ClientEditor(previous: previous) { name, icon in
                sheet = nil
                Task {
                    await model.perform("Saving client…") {
                        var args = ["client", "save"]
                        if let previous { args += ["--previous=\(previous)"] }
                        if name != previous { _ = try await Ledger.run(args + ["--", name]) }
                        if let icon { _ = try await Ledger.run(["appearance", "--client=\(name)", "--icon=\(icon)"]) }
                        try await model.update()
                        page = .client(name)
                        model.notice = previous == nil ? "Client created" : name == previous ? "Client updated" : "Client renamed"
                    }
                }
            }
        case let .billing(scope, name):
            billingEditor(scope, name)
        case let .rule(rule, project):
            RuleSheet(rule: rule, projects: model.snapshot?.projects ?? [], initialProject: project) {
                Task { await model.reload() }
            }
            .environmentObject(recorder)
        }
    }

    private func billingEditor(_ scope: BillingEditor.Scope, _ name: String) -> some View {
        let listing = model.snapshot?.billingTerms
        let client = scope == .project ? model.snapshot?.projects.first { $0.name == name }?.client : nil
        let existing = (scope == .client ? listing?.client(name) : listing?.project(name)) ?? .empty
        let inherited = client.flatMap { listing?.client($0) } ?? .empty
        return BillingEditor(scope: scope, name: name, client: client, existing: existing, inherited: inherited,
                             currency: model.snapshot?.currency ?? "EUR") { arguments in
            sheet = nil
            Task {
                await model.perform("Saving billing rates…") {
                    _ = try await Ledger.run(arguments)
                    try await model.update()
                    model.notice = "Billing rates saved"
                }
            }
        }
    }

    private func assignment(_ activity: Activity, _ project: String, _ snapshot: Snapshot, remember: Bool) -> [String] {
        var args = ["assign-group", project, "--provider", activity.provider] + snapshot.range
        for (flag, value) in [("--folder", activity.folder), ("--branch", activity.branch),
                              ("--project", activity.project), ("--task", activity.task)] {
            if let value { args.append("\(flag)=\(value)") }
        }
        if remember { args += ["--save-folder"] }
        return args
    }

    /// Runs a request from the Help menu.
    private func handle(_ request: AppRoute.Request) {
        switch request {
        case let .page(target): page = target
        case .newProject: sheet = .project(nil, nil)
        case .newClient: sheet = .client(nil)
        case .welcome: showWelcome = true
        case .diarySetup:
            page = .diary
            AppRoute.shared.diarySetup = true
        case .exportCSV:
            if let snapshot = model.snapshot, model.busy == nil {
                DispatchQueue.main.async { export(snapshot) }
            }
        }
    }

    private func export(_ snapshot: Snapshot) {
        let dialog = NSSavePanel()
        dialog.allowedContentTypes = [.commaSeparatedText]
        dialog.nameFieldStringValue = "Daylanes-\(snapshot.start).csv"
        dialog.prompt = "Export"
        var args = ["export"] + snapshot.range
        if case let .project(name) = page { args += ["--project=\(name)"] }
        if case let .client(name) = page { args += ["--client=\(name)"] }
        guard dialog.runModal() == .OK, let destination = dialog.url else { return }
        Task {
            await model.perform("Exporting CSV…") {
                let data = try await Ledger.run(args)
                try data.write(to: destination, options: .atomic)
                model.notice = "CSV exported"
            }
        }
    }
}

struct ActivityRow: View {
    let activity: Activity
    let currency: String
    let disabled: Bool
    var compact = false
    let openChat: (URL) -> Void
    let assign: () -> Void
    @State private var showDetails = false

    private var chatLinks: [(chat: AgentChat, url: URL)] {
        (activity.sessions ?? []).compactMap { chat in
            chat.url(provider: activity.provider).map { (chat, $0) }
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle().fill(activity.project == nil ? Theme.secondary.opacity(0.5) : ProjectColor.color(for: activity.project))
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(activity.displayTitle)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .help(activity.displayTitle)
                    if !compact || activity.project != nil {
                        ProjectTag(client: activity.client, project: activity.project)
                    }
                }
                HStack(spacing: 8) {
                    Text([providerName(activity.provider), activity.sourceContext, activity.branch]
                        .compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary).lineLimit(1)
                        .help(activity.folder ?? "")
                    if !compact { chatAction }
                }
                .font(.caption)
                Label(activity.whenText + " · " + activity.durationText, systemImage: "clock")
                    .labelStyle(CompactLabelStyle())
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    .help(activity.durationHelp)
                if let repo = activity.repo {
                    RepoLine(repo: repo, pullRequest: activity.pullRequest, commit: activity.headCommit)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                Text("\(tokensText(activity.usage?.tokens.total ?? 0)) tokens")
                    .monospacedDigit()
                if let equivalent = activity.summary.apiEquivalentUsd {
                    Text(costText(equivalent, currency: "USD") + " API equivalent")
                        .foregroundStyle(.secondary).font(.caption)
                } else if activity.summary.pricedTokens > 0 {
                    Text(costText(activity.summary.estimatedTokenValue, currency: currency) + " at manual rates")
                        .foregroundStyle(.secondary).font(.caption)
                } else if let runtime = activity.usage?.runtimeHours {
                    Text(hoursText(runtime)).foregroundStyle(.secondary).font(.caption)
                }
            }
            if !compact {
                Button {
                    showDetails.toggle()
                } label: {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Activity details")
                .accessibilityLabel("Details for \(activity.folderName)")
                .popover(isPresented: $showDetails, arrowEdge: .bottom) { details }
                Button(activity.project == nil ? "Assign…" : "Move…", action: assign)
                    .disabled(disabled)
                    .controlSize(.small)
                    .frame(width: 72, alignment: .trailing)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if compact && !disabled { assign() } }
        .contextMenu {
            Button(activity.project == nil ? "Assign…" : "Move…", action: assign).disabled(disabled)
        }
        .padding(.vertical, 10)
        .frame(minHeight: 57)
    }

    @ViewBuilder
    private var chatAction: some View {
        let links = chatLinks
        if links.count == 1, let link = links.first {
            Button { openChat(link.url) } label: {
                Label("Open chat", systemImage: "arrow.up.right")
                    .labelStyle(CompactLabelStyle())
            }
            .buttonStyle(.link)
            .fixedSize()
            .help("Open this chat in \(providerName(activity.provider))")
        } else if !links.isEmpty {
            Menu {
                ForEach(links, id: \.chat.id) { link in
                    Button(link.chat.menuTitle) { openChat(link.url) }
                }
            } label: {
                Label("Chats (\(links.count))", systemImage: "arrow.up.right")
                    .labelStyle(CompactLabelStyle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help("Choose a chat to open in \(providerName(activity.provider))")
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(activity.displayTitle).font(.headline)
            if let path = activity.folder { Text(path).font(.caption).textSelection(.enabled) }
            if let task = activity.task { Text("Task \(task)").font(.caption) }
            if let usage = activity.usage {
                Text("\(usage.tokens.input.formatted()) input · \(usage.tokens.output.formatted()) output")
                Text("\(usage.tokens.cached.formatted()) cache reads · \(usage.tokens.cacheWrite.formatted()) cache writes")
                if let kind = usage.runtimeKind { Text("\(hoursText(usage.runtimeHours)) · \(kind)") }
                ForEach(usage.models.keys.sorted(), id: \.self) { model in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(model) · \(usage.models[model]?.total.formatted() ?? "0") tokens")
                        if let equivalent = usage.modelApiEquivalentUsd[model] {
                            Text("\(costText(equivalent, currency: "USD")) API equivalent")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if activity.summary.tokensWithoutApiPrice > 0 {
                    Text("\(activity.summary.tokensWithoutApiPrice.formatted()) tokens without an API estimate")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("\(activity.whenText) · \(activity.durationText)").foregroundStyle(.secondary)
        }
        .font(.callout)
        .frame(width: 310, alignment: .leading)
        .padding(16)
    }
}

/// A small icon tightly followed by its title, for caption lines.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

extension Activity {
    var firstDate: Date { Date(timeIntervalSince1970: (firstAt ?? lastAt) / 1000) }
    var lastDate: Date { Date(timeIntervalSince1970: max(endedAt ?? lastAt, lastAt) / 1000) }

    /// When the work happened: "Today, 14:02–16:40", or a start and end day when it crosses midnight.
    var whenText: String {
        let calendar = Calendar.current
        func day(_ date: Date) -> String {
            if calendar.isDateInToday(date) { return "Today" }
            if calendar.isDateInYesterday(date) { return "Yesterday" }
            return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        }
        let time = Date.FormatStyle(date: .omitted, time: .shortened)
        let (start, end) = (firstDate, lastDate)
        if end.timeIntervalSince(start) < 60 { return "\(day(end)), \(end.formatted(time))" }
        if calendar.isDate(start, inSameDayAs: end) {
            return "\(day(start)), \(start.formatted(time))–\(end.formatted(time))"
        }
        return "\(day(start)) \(start.formatted(time)) – \(day(end)) \(end.formatted(time))"
    }

    /// How long the agent worked: its measured runtime when the logs have one, otherwise the first-to-last span.
    var durationText: String {
        if let runtime = usage?.runtimeHours, let hours = Double(runtime), hours > 0 {
            return hoursText(runtime) + " active"
        }
        let span = lastDate.timeIntervalSince(firstDate) / 3600
        return span > 0 ? hoursText(String(span)) + " span" : "single update"
    }

    var durationHelp: String {
        let span = hoursText(String(lastDate.timeIntervalSince(firstDate) / 3600))
        let kind = switch usage?.runtimeKind {
        case "turn elapsed": "elapsed turns"
        case "active session estimate": "active session estimate"
        default: "estimated request time"
        }
        return usage?.runtimeHours == nil ? "Start to end: \(span)"
            : "Active: \(kind). Start to end: \(span)"
    }
}

/// "[Client / Project]" pill in the project's colour, or a dashed "Unassigned" pill.
struct ProjectTag: View {
    let client: String?
    let project: String?

    var body: some View {
        let tint = ProjectColor.color(for: project)
        Text(project.map { [client, $0].compactMap { $0 }.joined(separator: " / ") } ?? "Unassigned")
            .font(.caption2.weight(.medium))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(project == nil ? Color.secondary : tint)
            .background(project == nil ? Color.clear : tint.opacity(0.14), in: Capsule())
            .overlay {
                if project == nil {
                    Capsule().strokeBorder(Color.secondary.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                }
            }
            .fixedSize()
    }
}

/// GitHub mark, then owner/repo with the matched pull request or the checked-out commit, each a link.
struct RepoLine: View {
    let repo: String
    let pullRequest: PullRequest?
    let commit: String?

    var body: some View {
        HStack(spacing: 5) {
            GitHubMark().frame(width: 12, height: 12).foregroundStyle(.secondary)
            if let url = URL(string: "https://github.com/\(repo)") {
                Link(repo, destination: url)
            }
            if let pullRequest {
                Text("·").foregroundStyle(.tertiary)
                Link("#\(pullRequest.number) \(pullRequest.title)", destination: pullRequest.url).lineLimit(1)
            } else if let commit, let url = URL(string: "https://github.com/\(repo)/commit/\(commit)") {
                Text("·").foregroundStyle(.tertiary)
                Link(String(commit.prefix(7)), destination: url).monospaced()
            }
        }
        .font(.caption)
        .lineLimit(1)
    }
}

/// The GitHub mark (Octicons "mark-github", 16×16), drawn as a shape so it takes the text colour.
struct GitHubMark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 8.000, y: 0.000))
        p.addCurve(to: CGPoint(x: 16.000, y: 8.000), control1: CGPoint(x: 12.420, y: 0.000), control2: CGPoint(x: 16.000, y: 3.580))
        p.addCurve(to: CGPoint(x: 15.828, y: 9.651), control1: CGPoint(x: 16.000, y: 8.554), control2: CGPoint(x: 15.942, y: 9.108))
        p.addCurve(to: CGPoint(x: 15.319, y: 11.230), control1: CGPoint(x: 15.713, y: 10.193), control2: CGPoint(x: 15.543, y: 10.723))
        p.addCurve(to: CGPoint(x: 14.496, y: 12.672), control1: CGPoint(x: 15.095, y: 11.738), control2: CGPoint(x: 14.819, y: 12.221))
        p.addCurve(to: CGPoint(x: 13.393, y: 13.912), control1: CGPoint(x: 14.173, y: 13.122), control2: CGPoint(x: 13.802, y: 13.538))
        p.addCurve(to: CGPoint(x: 12.059, y: 14.899), control1: CGPoint(x: 12.984, y: 14.286), control2: CGPoint(x: 12.536, y: 14.618))
        p.addCurve(to: CGPoint(x: 10.550, y: 15.590), control1: CGPoint(x: 11.582, y: 15.181), control2: CGPoint(x: 11.075, y: 15.413))
        p.addCurve(to: CGPoint(x: 10.000, y: 15.210), control1: CGPoint(x: 10.150, y: 15.670), control2: CGPoint(x: 10.000, y: 15.420))
        p.addCurve(to: CGPoint(x: 10.010, y: 13.010), control1: CGPoint(x: 10.000, y: 14.940), control2: CGPoint(x: 10.010, y: 14.080))
        p.addCurve(to: CGPoint(x: 9.470, y: 11.530), control1: CGPoint(x: 10.010, y: 12.260), control2: CGPoint(x: 9.760, y: 11.780))
        p.addCurve(to: CGPoint(x: 13.120, y: 7.580), control1: CGPoint(x: 11.250, y: 11.330), control2: CGPoint(x: 13.120, y: 10.650))
        p.addCurve(to: CGPoint(x: 12.300, y: 5.430), control1: CGPoint(x: 13.120, y: 6.700), control2: CGPoint(x: 12.810, y: 5.990))
        p.addCurve(to: CGPoint(x: 12.220, y: 3.310), control1: CGPoint(x: 12.380, y: 5.230), control2: CGPoint(x: 12.660, y: 4.410))
        p.addCurve(to: CGPoint(x: 10.020, y: 4.130), control1: CGPoint(x: 12.220, y: 3.310), control2: CGPoint(x: 11.550, y: 3.090))
        p.addCurve(to: CGPoint(x: 8.020, y: 3.860), control1: CGPoint(x: 9.380, y: 3.950), control2: CGPoint(x: 8.700, y: 3.860))
        p.addCurve(to: CGPoint(x: 6.020, y: 4.130), control1: CGPoint(x: 7.340, y: 3.860), control2: CGPoint(x: 6.660, y: 3.950))
        p.addCurve(to: CGPoint(x: 3.820, y: 3.310), control1: CGPoint(x: 4.490, y: 3.100), control2: CGPoint(x: 3.820, y: 3.310))
        p.addCurve(to: CGPoint(x: 3.740, y: 5.430), control1: CGPoint(x: 3.380, y: 4.410), control2: CGPoint(x: 3.660, y: 5.230))
        p.addCurve(to: CGPoint(x: 2.920, y: 7.580), control1: CGPoint(x: 3.230, y: 5.990), control2: CGPoint(x: 2.920, y: 6.710))
        p.addCurve(to: CGPoint(x: 6.560, y: 11.530), control1: CGPoint(x: 2.920, y: 10.640), control2: CGPoint(x: 4.780, y: 11.330))
        p.addCurve(to: CGPoint(x: 6.050, y: 12.600), control1: CGPoint(x: 6.330, y: 11.730), control2: CGPoint(x: 6.120, y: 12.080))
        p.addCurve(to: CGPoint(x: 3.720, y: 11.940), control1: CGPoint(x: 5.590, y: 12.810), control2: CGPoint(x: 4.440, y: 13.150))
        p.addCurve(to: CGPoint(x: 2.490, y: 11.120), control1: CGPoint(x: 3.570, y: 11.700), control2: CGPoint(x: 3.120, y: 11.110))
        p.addCurve(to: CGPoint(x: 2.500, y: 11.650), control1: CGPoint(x: 1.820, y: 11.130), control2: CGPoint(x: 2.220, y: 11.500))
        p.addCurve(to: CGPoint(x: 3.320, y: 12.780), control1: CGPoint(x: 2.840, y: 11.840), control2: CGPoint(x: 3.230, y: 12.550))
        p.addCurve(to: CGPoint(x: 6.010, y: 13.720), control1: CGPoint(x: 3.480, y: 13.230), control2: CGPoint(x: 4.000, y: 14.090))
        p.addCurve(to: CGPoint(x: 6.020, y: 15.210), control1: CGPoint(x: 6.010, y: 14.390), control2: CGPoint(x: 6.020, y: 15.020))
        p.addCurve(to: CGPoint(x: 5.470, y: 15.590), control1: CGPoint(x: 6.020, y: 15.420), control2: CGPoint(x: 5.870, y: 15.660))
        p.addCurve(to: CGPoint(x: 3.956, y: 14.904), control1: CGPoint(x: 4.943, y: 15.415), control2: CGPoint(x: 4.435, y: 15.184))
        p.addCurve(to: CGPoint(x: 2.616, y: 13.919), control1: CGPoint(x: 3.476, y: 14.623), control2: CGPoint(x: 3.027, y: 14.293))
        p.addCurve(to: CGPoint(x: 1.509, y: 12.679), control1: CGPoint(x: 2.205, y: 13.546), control2: CGPoint(x: 1.834, y: 13.129))
        p.addCurve(to: CGPoint(x: 0.682, y: 11.236), control1: CGPoint(x: 1.184, y: 12.228), control2: CGPoint(x: 0.907, y: 11.744))
        p.addCurve(to: CGPoint(x: 0.172, y: 9.654), control1: CGPoint(x: 0.458, y: 10.728), control2: CGPoint(x: 0.287, y: 10.197))
        p.addCurve(to: CGPoint(x: -0.000, y: 8.000), control1: CGPoint(x: 0.057, y: 9.110), control2: CGPoint(x: -0.000, y: 8.555))
        p.addCurve(to: CGPoint(x: 8.000, y: 0.000), control1: CGPoint(x: 0.000, y: 3.580), control2: CGPoint(x: 3.580, y: 0.000))
        p.closeSubpath()
        let scale = min(rect.width, rect.height) / 16
        return p.applying(CGAffineTransform(scaleX: scale, y: scale)).offsetBy(dx: rect.minX, dy: rect.minY)
    }
}

/// Thin grey icon and light text, brighter when the row is selected.
struct SidebarLabelStyle: LabelStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 9) {
            configuration.icon
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Color.white.opacity(selected ? 0.9 : 0.55))
                .frame(width: 18)
            configuration.title
                .font(.system(size: 13, weight: selected ? .semibold : .regular))
                .foregroundStyle(Color.white.opacity(selected ? 1 : 0.82))
        }
    }
}
