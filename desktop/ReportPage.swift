import AppKit
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Rendering

/// A built report and its PDF. Made off the main thread from value types only.
struct ReportRendering: Sendable {
    let document: ReportDocument
    let pdf: Data

    static func make(data: ReportData, options: ReportOptions, generatedAt: Date) -> ReportRendering {
        let document: ReportDocument = ReportBuilder.build(data: data, options: options, generatedAt: generatedAt,
                                                           providerName: providerName)
        let strings = ReportStrings(document: document)
        let pdf: Data = ReportPDF.render(document: document, strings: strings, paper: options.paper,
                                         orientation: options.orientation)
        return ReportRendering(document: document, pdf: pdf)
    }

    /// Nothing to show: no work and no expenses (a money report still carries a zero total).
    var isEmpty: Bool {
        for item in document.summary {
            switch item {
            case .you, .agents, .expenses:
                return false
            case .tokens, .aiCost, .capAdjustment, .total:
                continue
            }
        }
        return document.sections.isEmpty
    }
}

/// The period menu's choices; `custom` keeps the days already chosen.
enum ReportRangeChoice: String, CaseIterable, Hashable {
    case thisMonth, lastMonth, thisWeek, lastWeek, custom

    init(_ range: ReportRange) {
        switch range {
        case .thisMonth: self = .thisMonth
        case .lastMonth: self = .lastMonth
        case .thisWeek: self = .thisWeek
        case .lastWeek: self = .lastWeek
        case .custom: self = .custom
        }
    }

    var title: String {
        switch self {
        case .thisMonth: return "This month"
        case .lastMonth: return "Last month"
        case .thisWeek: return "This week"
        case .lastWeek: return "Last week"
        case .custom: return "Custom"
        }
    }
}

/// Labels for the option controls. The app's own text is English; the PDF language is a separate option.
enum ReportChoices {
    static let ranges: [[(ReportRangeChoice, String)]] = [
        [(ReportRangeChoice.thisMonth, "This month"), (ReportRangeChoice.lastMonth, "Last month"),
         (ReportRangeChoice.thisWeek, "This week"), (ReportRangeChoice.lastWeek, "Last week")],
        [(ReportRangeChoice.custom, "Custom")],
    ]
    static let who: [(ReportWho, String)] = [(ReportWho.both, "Both"), (ReportWho.you, "You"), (ReportWho.agents, "Agents")]
    static let expenses: [(ReportExpenses, String)] = [
        (ReportExpenses.none, "None"), (ReportExpenses.reimbursable, "Reimbursable"), (ReportExpenses.all, "All"),
    ]
    static let detail: [(ReportDetail, String)] = [
        (ReportDetail.totals, "Totals"), (ReportDetail.project, "Project"), (ReportDetail.day, "Day"),
        (ReportDetail.task, "Task"), (ReportDetail.entry, "Entry"),
    ]
    static let groupBy: [(ReportGroupBy, String)] = [
        (ReportGroupBy.none, "None"), (ReportGroupBy.project, "Project"), (ReportGroupBy.day, "Day"),
        (ReportGroupBy.task, "Task"), (ReportGroupBy.who, "Who"),
    ]
    static let hoursFormat: [(ReportHoursFormat, String)] = [
        (ReportHoursFormat.decimal, "1.50"), (ReportHoursFormat.clock, "1h 30m"),
    ]
    static let languages: [[(ReportLanguage, String)]] = [[
        (ReportLanguage.en, "English"), (ReportLanguage.it, "Italiano"), (ReportLanguage.fr, "Français"),
        (ReportLanguage.es, "Español"), (ReportLanguage.de, "Deutsch"),
    ]]
    static let paper: [(ReportPaper, String)] = [(ReportPaper.a4, "A4"), (ReportPaper.letter, "Letter")]
    static let orientation: [(ReportOrientation, String)] = [
        (ReportOrientation.portrait, "Portrait"), (ReportOrientation.landscape, "Landscape"),
    ]
    static let separator: [(ReportCSVSeparator, String)] = [
        (ReportCSVSeparator.comma, "Comma"), (ReportCSVSeparator.semicolon, "Semicolon"),
    ]

    static func title(_ column: ReportOptionalColumn) -> String {
        switch column {
        case .timeRange: return "Time range"
        case .hours: return "Hours"
        case .rate: return "Rate"
        case .amount: return "Amount"
        case .tokens: return "Tokens"
        case .aiCost: return "AI cost"
        case .model: return "Model"
        }
    }
}

// MARK: - Model

/// The Reports page's state: the chosen client, projects and options, the engine rows, and the rendered PDF.
/// Options are remembered per client; your name and details are shared by every client.
@MainActor
final class ReportModel: ObservableObject {
    @Published private(set) var clients: [String] = []
    @Published private(set) var client: String = ""
    /// Empty means all of the client's projects.
    @Published private(set) var projects: Set<String> = []
    @Published var options: ReportOptions = ReportOptions() {
        didSet { optionsChanged(from: oldValue) }
    }
    @Published private(set) var data: ReportData?
    @Published private(set) var rendering: ReportRendering?
    @Published private(set) var preview: PDFDocument?
    /// Fetching engine rows.
    @Published private(set) var loading = false
    /// Rebuilding the PDF after an option changed.
    @Published private(set) var updating = false
    @Published private(set) var loadError: String?
    @Published private(set) var rangeError: String?

    private(set) var timezone = "UTC"
    private var projectsByClient: [String: [String]] = [:]
    private var billableClients: Set<String> = []
    private var lastRevision: Int?
    private var restoring = false
    private var fetchTask: Task<Void, Never>?
    private var renderTask: Task<Void, Never>?
    private var fetchGeneration = 0
    private var renderGeneration = 0
    private let defaults = UserDefaults.standard

    private static let lastClientKey = "report.lastClient"
    private static let personNameKey = "report.personName"
    private static let fromKey = "report.from"
    private static func optionsKey(_ client: String) -> String { "report.options.\(client)" }
    private static func projectsKey(_ client: String) -> String { "report.projects.\(client)" }

    /// English formatting for the app's own labels.
    static let interfaceStrings = ReportStrings(language: .en)

    // MARK: Ledger

    /// Called when the page appears and whenever the ledger snapshot reloads.
    func configure(snapshot: Snapshot, revision: Int) {
        timezone = snapshot.timezone
        var byClient: [String: [String]] = [:]
        var billable: Set<String> = []
        for project in snapshot.projects {
            guard let owner = project.client else { continue }
            byClient[owner, default: []].append(project.name)
            if project.kind == "billable" { billable.insert(owner) }
        }
        projectsByClient = byClient.mapValues { names in
            names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
        billableClients = billable
        let names: [String] = Set(snapshot.clients).union(byClient.keys).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        if names != clients { clients = names }

        if client.isEmpty || !names.contains(client) {
            lastRevision = revision
            let initial = defaultClient()
            if initial.isEmpty {
                clear()
            } else {
                apply(client: initial)
                fetch()
            }
            return
        }
        let pruned = projects.intersection(projectNames)
        if pruned != projects { projects = pruned }
        if lastRevision != revision {
            lastRevision = revision
            fetch()
        }
    }

    /// The last client you made a report for, else the first one with a billable project.
    private func defaultClient() -> String {
        if let last = defaults.string(forKey: Self.lastClientKey), clients.contains(last) { return last }
        if let billable = clients.first(where: { billableClients.contains($0) }) { return billable }
        return clients.first ?? ""
    }

    private func clear() {
        fetchTask?.cancel()
        renderTask?.cancel()
        fetchGeneration += 1
        renderGeneration += 1
        client = ""
        projects = []
        data = nil
        rendering = nil
        preview = nil
        loading = false
        updating = false
        loadError = nil
    }

    // MARK: Choices

    var projectNames: [String] { projectsByClient[client] ?? [] }

    func select(client name: String) {
        guard name != client, !name.isEmpty else { return }
        apply(client: name)
        fetch()
    }

    private func apply(client name: String) {
        client = name
        defaults.set(name, forKey: Self.lastClientKey)
        restoring = true
        options = savedOptions(for: name)
        restoring = false
        let saved: [String] = defaults.stringArray(forKey: Self.projectsKey(name)) ?? []
        projects = Set(saved).intersection(projectNames)
    }

    func includes(project: String) -> Bool {
        projects.isEmpty || projects.contains(project)
    }

    /// Checks or unchecks one project. Checking them all, or unchecking the last one, goes back to all projects.
    func toggle(project: String) {
        let all = Set(projectNames)
        var next: Set<String> = projects.isEmpty ? all : projects
        if next.contains(project) {
            next.remove(project)
        } else {
            next.insert(project)
        }
        if next.isEmpty || next == all { next = [] }
        setProjects(next)
    }

    func selectAllProjects() {
        setProjects([])
    }

    private func setProjects(_ next: Set<String>) {
        guard next != projects else { return }
        projects = next
        if !client.isEmpty {
            defaults.set(next.sorted(), forKey: Self.projectsKey(client))
        }
        fetch()
    }

    func toggle(column: ReportOptionalColumn) {
        if options.columns.contains(column) {
            options.columns.remove(column)
        } else {
            options.columns.insert(column)
        }
    }

    func choose(range choice: ReportRangeChoice) {
        switch choice {
        case .thisMonth: options.range = .thisMonth
        case .lastMonth: options.range = .lastMonth
        case .thisWeek: options.range = .thisWeek
        case .lastWeek: options.range = .lastWeek
        case .custom:
            if case .custom = options.range { return }
            let days = customDays
            options.range = .custom(start: days.start, end: days.end)
        }
    }

    var isCustomRange: Bool {
        if case .custom = options.range { return true }
        return false
    }

    /// The first and last day (inclusive) of the chosen period.
    var customDays: (start: String, end: String) {
        if case .custom(let start, let end) = options.range { return (start, end) }
        let bounds = options.range.bounds(timezone: timezone, now: Date())
        return (bounds.start, ReportCalendar.adding(days: -1, to: bounds.endExclusive))
    }

    func setCustom(start: String? = nil, end: String? = nil) {
        let current = customDays
        options.range = .custom(start: start ?? current.start, end: end ?? current.end)
    }

    // MARK: Persistence

    private func savedOptions(for name: String) -> ReportOptions {
        var result = ReportOptions()
        result.language = ReportLanguage.preferred(Locale.preferredLanguages)
        // A first report for a client: one line per day, under each project.
        result.detail = .day
        result.groupBy = .project
        if let stored = defaults.data(forKey: Self.optionsKey(name)),
           let decoded = try? JSONDecoder().decode(ReportOptions.self, from: stored) {
            result = decoded
        }
        result.personName = defaults.string(forKey: Self.personNameKey) ?? ""
        result.from = defaults.string(forKey: Self.fromKey) ?? ""
        return result
    }

    private func persist() {
        guard !client.isEmpty else { return }
        var stored = options
        // Shared by every client, so kept once rather than per client.
        stored.personName = ""
        stored.from = ""
        if let encoded = try? JSONEncoder().encode(stored) {
            defaults.set(encoded, forKey: Self.optionsKey(client))
        }
        defaults.set(options.personName, forKey: Self.personNameKey)
        defaults.set(options.from, forKey: Self.fromKey)
    }

    private func optionsChanged(from previous: ReportOptions) {
        guard !restoring else { return }
        persist()
        if previous.range != options.range {
            fetch()
        } else if previous != options {
            scheduleRender(delay: true)
        }
    }

    // MARK: Loading and rendering

    func fetch() {
        fetchTask?.cancel()
        fetchGeneration += 1
        let generation = fetchGeneration
        guard !client.isEmpty else {
            loading = false
            return
        }
        let bounds = options.range.bounds(timezone: timezone, now: Date())
        guard bounds.start < bounds.endExclusive else {
            loading = false
            rangeError = "The last day is before the first day."
            return
        }
        rangeError = nil
        loading = true
        let name = client
        let chosen: [String] = projects.sorted()
        let start = bounds.start
        let endExclusive = bounds.endExclusive
        fetchTask = Task { [weak self] in
            do {
                let result: ReportData = try await Ledger.reportRows(start: start, endExclusive: endExclusive,
                                                                     client: name, projects: chosen)
                guard let self, generation == self.fetchGeneration else { return }
                self.loading = false
                self.loadError = nil
                self.data = result
                self.scheduleRender(delay: false)
            } catch {
                guard let self, generation == self.fetchGeneration else { return }
                self.loading = false
                self.loadError = error.localizedDescription
            }
        }
    }

    /// Rebuilds the document and the PDF off the main thread. Option changes wait ~150 ms so typing stays smooth;
    /// a result that a newer change has overtaken is dropped.
    private func scheduleRender(delay: Bool) {
        renderTask?.cancel()
        renderGeneration += 1
        let generation = renderGeneration
        guard let rows = data else {
            updating = false
            return
        }
        let chosen = options
        updating = true
        renderTask = Task { [weak self] in
            if delay {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if Task.isCancelled { return }
            }
            let made: ReportRendering = await Task.detached(priority: .userInitiated) { () -> ReportRendering in
                ReportRendering.make(data: rows, options: chosen, generatedAt: Date())
            }.value
            guard let self, generation == self.renderGeneration else { return }
            self.rendering = made
            self.preview = PDFDocument(data: made.pdf)
            self.updating = false
        }
    }

    // MARK: Summary for the page

    var hasContent: Bool {
        guard let rendering else { return false }
        return !rendering.isEmpty
    }

    var canExport: Bool {
        data != nil && hasContent && !loading && loadError == nil && rangeError == nil
    }

    /// "Acme · Nov 1, 2026 – Nov 30, 2026", or empty without a client.
    var subtitle: String {
        guard !client.isEmpty else { return "" }
        let days = customDays
        return "\(client) · \(Self.interfaceStrings.formatPeriod(start: days.start, end: days.end))"
    }

    /// The hours the document prints (person and agents together), so the strip agrees with the PDF.
    var hoursText: String? {
        guard let document = rendering?.document, let shown = document.shownHours else { return nil }
        return Self.interfaceStrings.formatShownWithUnit(shown, style: document.options.hoursFormat)
    }

    var amountText: String? {
        guard let document = rendering?.document, let total = document.grandTotal else { return nil }
        let strings = ReportStrings(language: .en, currency: document.header.currency, timezone: document.header.timezone)
        return strings.formatMoney(total)
    }

    var pageCount: Int { preview?.pageCount ?? 0 }

    /// The document's warnings, in the app's plain words.
    var warningTexts: [String] {
        guard let document = rendering?.document else { return [] }
        return document.warnings.map { (warning: ReportWarning) -> String in
            switch warning {
            case .missingHumanRate:
                return "Some billable hours have no hourly rate, so they show no amount. Set a rate in the client’s billing."
            case .needsExchangeRate:
                return "Agent usage shows no amount because no USD exchange rate is set. Set one in Settings → AI costs."
            case .tokensWithoutPrice(let count):
                return "\(count.formatted()) tokens have no API price, so the API value leaves them out."
            }
        }
    }

    // MARK: Export

    /// The suggested file name; `suffix` keeps the raw-entries CSV from defaulting onto the report-rows CSV.
    private func fileName(_ fileExtension: String, suffix: String = "") -> String {
        let start = data?.start ?? customDays.start
        return "Report-\(Self.fileSafe(client))-\(start)\(suffix).\(fileExtension)"
    }

    /// Letters, digits and underscores, with any run of other characters turned into one hyphen.
    static func fileSafe(_ text: String) -> String {
        var result = ""
        var pendingDash = false
        for scalar in text.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) || scalar == "_" {
                if pendingDash && !result.isEmpty { result.append("-") }
                pendingDash = false
                result.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        let trimmed = String(result.prefix(60))
        return trimmed.isEmpty ? "Client" : trimmed
    }

    private func save(_ contents: Data, type: UTType, name: String, notice: String, ledger: LedgerModel) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = name
        panel.prompt = "Export"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            try contents.write(to: destination, options: .atomic)
            ledger.notice = notice
        } catch {
            ledger.error = error.localizedDescription
        }
    }

    func exportPDF(ledger: LedgerModel) {
        guard canExport, let rows = data else { return }
        // Rendered again so the file has every option, even one changed within the preview's debounce.
        let made = ReportRendering.make(data: rows, options: options, generatedAt: Date())
        save(made.pdf, type: .pdf, name: fileName("pdf"), notice: "PDF exported", ledger: ledger)
    }

    func exportCSV(raw: Bool, ledger: LedgerModel) {
        guard canExport, let rows = data else { return }
        let text: String
        if raw {
            text = ReportCSV.raw(rows, separator: options.csvSeparator)
        } else {
            let document = ReportBuilder.build(data: rows, options: options, generatedAt: Date(),
                                               providerName: providerName)
            text = ReportCSV.report(document, strings: ReportStrings(document: document), separator: options.csvSeparator)
        }
        save(Data(text.utf8), type: .commaSeparatedText, name: fileName("csv", suffix: raw ? "-entries" : ""),
             notice: "CSV exported", ledger: ledger)
    }
}

// MARK: - Page

/// Export CSV (report rows or raw entries) and Export PDF, for the page header.
struct ReportExportActions: View {
    @ObservedObject var report: ReportModel
    let ledger: LedgerModel

    var body: some View {
        HStack(spacing: 6) {
            csvMenu
            pdfButton
        }
    }

    private var csvMenu: some View {
        Menu {
            Button("Report rows") { report.exportCSV(raw: false, ledger: ledger) }
            Button("Raw entries") { report.exportCSV(raw: true, ledger: ledger) }
        } label: {
            HStack(spacing: 4) {
                Text("Export CSV")
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        .buttonStyle(PillButtonStyle())
        .fixedSize()
        .disabled(!report.canExport)
        .help("Export the report lines, or every raw entry, as a spreadsheet")
        .accessibilityLabel("Export CSV")
    }

    private var pdfButton: some View {
        Button {
            report.exportPDF(ledger: ledger)
        } label: {
            Label("Export PDF", systemImage: "arrow.down.doc")
        }
        .buttonStyle(PillButtonStyle(prominent: true))
        .keyboardShortcut("e", modifiers: .command)
        .disabled(!report.canExport)
        .help("Export the report as a PDF (⌘E)")
    }
}

/// The Reports page body: options on the left, the live PDF on the right.
struct ReportPage: View {
    @ObservedObject var report: ReportModel
    let snapshot: Snapshot
    let revision: Int

    var body: some View {
        content
            .onAppear { report.configure(snapshot: snapshot, revision: revision) }
            .onChange(of: revision) { _, next in report.configure(snapshot: snapshot, revision: next) }
    }

    @ViewBuilder
    private var content: some View {
        if snapshot.clients.isEmpty && !snapshot.projects.contains(where: { $0.client != nil }) {
            ReportNotice(title: "No clients yet",
                         detail: "Create a client and give it a billable project, then come back to build its report.",
                         icon: "person.2")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            HStack(alignment: .top, spacing: 20) {
                ReportOptionsColumn(report: report)
                    .frame(width: 360)
                    .frame(maxHeight: .infinity, alignment: .top)
                ReportPreviewPane(report: report)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// An empty or error state in the app's style: an icon and a title, grey text under it.
private struct ReportNotice: View {
    let title: String
    let detail: String
    let icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(Theme.text)
            Text(detail).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 22)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Options

private struct ReportOptionsColumn: View {
    @ObservedObject var report: ReportModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                ReportWhatOptions(report: report)
                ReportHowOptions(report: report)
                ReportHeaderOptions(report: report)
                ReportPageOptions(report: report)
            }
            .padding(.trailing, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }
}

/// A small section title over a group of options, with a chevron that folds the group away.
/// Whether it is open is remembered across launches.
private struct ReportOptionGroup<Content: View>: View {
    let title: String
    let content: () -> Content
    @AppStorage private var isOpen: Bool

    init(title: String, key: String, openByDefault: Bool, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
        _isOpen = AppStorage(wrappedValue: openByDefault, "report.group.\(key)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if isOpen {
                content()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        let hint: String = isOpen ? "Hide \(title)" : "Show \(title)"
        let state: String = isOpen ? "Expanded" : "Collapsed"
        return Button {
            withAnimation(.easeInOut(duration: 0.15)) { isOpen.toggle() }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(SheetTheme.muted)
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .frame(width: 12, height: 12)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(state)
        .accessibilityAddTraits(.isHeader)
        .help(hint)
    }
}

/// A title, an optional grey line and a small switch on the right.
private struct ReportSwitch: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    init(title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.text)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(SheetTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .controlSize(.small)
        }
    }
}

/// One row of the project list: a colour dot, the name and a checkmark when it is in the report.
private struct ReportCheckRow: View {
    let title: String
    let dot: Color?
    let checked: Bool
    let action: () -> Void

    init(title: String, dot: Color? = nil, checked: Bool, action: @escaping () -> Void) {
        self.title = title
        self.dot = dot
        self.checked = checked
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let dot {
                    Circle().fill(dot).frame(width: 7, height: 7).accessibilityHidden(true)
                }
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.text).lineLimit(1)
                Spacer(minLength: 6)
                Image(systemName: "checkmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.text)
                    .opacity(checked ? 1 : 0)
                    .accessibilityHidden(true)
            }
            .frame(height: 30)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityAddTraits(checked ? .isSelected : [])
    }
}

/// A multi-line field in the sheets' style.
private struct ReportTextArea: View {
    let label: String
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool

    init(label: String, placeholder: String, text: Binding<String>) {
        self.label = label
        self.placeholder = placeholder
        _text = text
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if text.isEmpty {
                Text(placeholder)
                    .font(.system(size: 13))
                    .foregroundStyle(SheetTheme.muted)
                    .padding(.leading, 5)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
            TextEditor(text: $text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .scrollIndicators(.never)
                .focused($focused)
                .accessibilityLabel(label)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 8)
        .frame(height: 78)
        .background(focused ? SheetTheme.fieldFocused : SheetTheme.field,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .strokeBorder(focused ? SheetTheme.accent : SheetTheme.border, lineWidth: focused ? 1.5 : 1))
    }
}

/// A day ("yyyy-MM-dd") picked with a compact date field. Days are kept at noon UTC, so no time zone moves them.
struct ReportDayPicker: View {
    let label: String
    @Binding var day: String

    private static let utc: TimeZone = TimeZone(secondsFromGMT: 0) ?? TimeZone.current

    init(label: String, day: Binding<String>) {
        self.label = label
        _day = day
    }

    private var date: Binding<Date> {
        Binding<Date>(
            get: { ReportCalendar.date(day) ?? Date() },
            set: { newValue in day = ReportCalendar.day(of: newValue, timeZone: ReportDayPicker.utc) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(SheetTheme.muted)
            DatePicker(label, selection: date, displayedComponents: .date)
                .labelsHidden()
                .datePickerStyle(.field)
                .environment(\.timeZone, ReportDayPicker.utc)
                .accessibilityLabel("\(label) day")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ReportWhatOptions: View {
    @ObservedObject var report: ReportModel

    var body: some View {
        ReportOptionGroup(title: "What", key: "what", openByDefault: true) {
            clientField
            projectsField
            periodField
            whoField
            ReportSwitch(title: "Billable work only", detail: "Leave out internal and personal projects.",
                         isOn: $report.options.billableOnly)
            expensesField
        }
    }

    private var clientBinding: Binding<String> {
        Binding<String>(get: { report.client }, set: { name in report.select(client: name) })
    }

    private var clientChoices: [[(String, String)]] {
        let names: [(String, String)] = report.clients.map { name in (name, name) }
        return [names]
    }

    private var clientField: some View {
        SheetField(label: "Client") {
            SheetMenu(selection: clientBinding, groups: clientChoices, placeholder: "Choose a client")
                .accessibilityLabel("Client")
        }
    }

    private var projectsNote: String {
        let count = report.projectNames.count
        if report.projects.isEmpty { return count == 1 ? "1 project" : "all \(count)" }
        return "\(report.projects.count) of \(count)"
    }

    private var projectsField: some View {
        SheetField(label: "Projects", note: projectsNote) {
            projectList
        }
    }

    @ViewBuilder
    private var projectList: some View {
        if report.projectNames.isEmpty {
            Text("This client has no projects yet.")
                .font(.system(size: 12))
                .foregroundStyle(SheetTheme.muted)
        } else {
            VStack(spacing: 0) {
                ReportCheckRow(title: "All projects", checked: report.projects.isEmpty) {
                    report.selectAllProjects()
                }
                ForEach(report.projectNames, id: \.self) { name in
                    Divider().overlay(Theme.hairline)
                    ReportCheckRow(title: name, dot: ProjectColor.color(for: name),
                                   checked: report.includes(project: name)) {
                        report.toggle(project: name)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 3)
            .background(SheetTheme.field, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(SheetTheme.border, lineWidth: 1))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Projects")
        }
    }

    private var rangeBinding: Binding<ReportRangeChoice> {
        Binding<ReportRangeChoice>(get: { ReportRangeChoice(report.options.range) },
                                   set: { choice in report.choose(range: choice) })
    }

    private var startBinding: Binding<String> {
        Binding<String>(get: { report.customDays.start }, set: { day in report.setCustom(start: day) })
    }

    private var endBinding: Binding<String> {
        Binding<String>(get: { report.customDays.end }, set: { day in report.setCustom(end: day) })
    }

    private var periodField: some View {
        SheetField(label: "Period") {
            VStack(alignment: .leading, spacing: 10) {
                SheetMenu(selection: rangeBinding, groups: ReportChoices.ranges)
                    .accessibilityLabel("Period")
                if report.isCustomRange {
                    HStack(spacing: 10) {
                        ReportDayPicker(label: "First day", day: startBinding)
                        ReportDayPicker(label: "Last day", day: endBinding)
                    }
                }
                if let message = report.rangeError {
                    Text(message).font(.system(size: 12)).foregroundStyle(Theme.Tint.red.ink)
                }
            }
        }
    }

    private var whoField: some View {
        SheetField(label: "Who") {
            SheetSegments(selection: $report.options.who, options: ReportChoices.who)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Who")
        }
    }

    private var expensesField: some View {
        SheetField(label: "Expenses", note: report.options.showsMoney ? nil : "needs Rate or Amount") {
            SheetSegments(selection: $report.options.expenses, options: ReportChoices.expenses)
                .disabled(!report.options.showsMoney)
                .opacity(report.options.showsMoney ? 1 : 0.5)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Expenses")
        }
    }
}

private struct ReportHowOptions: View {
    @ObservedObject var report: ReportModel

    var body: some View {
        ReportOptionGroup(title: "How", key: "how", openByDefault: true) {
            SheetField(label: "Detail") {
                SheetSegments(selection: $report.options.detail, options: ReportChoices.detail)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Detail")
            }
            SheetField(label: "Group under") {
                SheetSegments(selection: $report.options.groupBy, options: ReportChoices.groupBy)
                    .disabled(report.options.detail == .totals)
                    .opacity(report.options.detail == .totals ? 0.5 : 1)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Group under")
            }
            ReportSwitch(title: "Separate you and agents", isOn: $report.options.separateAgents)
            columnsField
            SheetField(label: "Hours format") {
                SheetSegments(selection: $report.options.hoursFormat, options: ReportChoices.hoursFormat)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Hours format")
            }
        }
    }

    private var columnsField: some View {
        SheetField(label: "Columns") {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(ReportOptionalColumn.allCases, id: \.self) { column in
                    columnChip(column)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Columns")
        }
    }

    private func columnChip(_ column: ReportOptionalColumn) -> some View {
        let available = column != .timeRange || report.options.detail == .entry
        return SheetChip(title: ReportChoices.title(column), selected: report.options.columns.contains(column),
                         outlined: true) {
            report.toggle(column: column)
        }
        .disabled(!available)
        .opacity(available ? 1 : 0.4)
        .help(available ? "" : "Time range needs the Entry detail")
    }
}

private struct ReportHeaderOptions: View {
    @ObservedObject var report: ReportModel

    private var strings: ReportStrings { ReportStrings(language: report.options.language) }

    var body: some View {
        ReportOptionGroup(title: "Header", key: "header", openByDefault: false) {
            SheetField(label: "Title") {
                SheetTextField(placeholder: strings.defaultTitle, text: $report.options.title)
                    .accessibilityLabel("Title")
            }
            SheetField(label: "Your name", note: "all clients") {
                SheetTextField(placeholder: strings.consultant, text: $report.options.personName)
                    .accessibilityLabel("Your name")
            }
            SheetField(label: "Your details", note: "all clients") {
                ReportTextArea(label: "Your details", placeholder: "Business name, address, VAT number",
                               text: $report.options.from)
            }
            SheetField(label: "Reference", note: "optional") {
                SheetTextField(placeholder: "Invoice or order number", text: $report.options.reference)
                    .accessibilityLabel("Reference")
            }
            SheetField(label: "Note", note: "optional") {
                ReportTextArea(label: "Note", placeholder: "Shown under the header", text: $report.options.note)
            }
        }
    }
}

private struct ReportPageOptions: View {
    @ObservedObject var report: ReportModel

    var body: some View {
        ReportOptionGroup(title: "Page", key: "page", openByDefault: false) {
            SheetField(label: "Language") {
                SheetMenu(selection: $report.options.language, groups: ReportChoices.languages)
                    .accessibilityLabel("Language")
            }
            SheetField(label: "Paper") {
                SheetSegments(selection: $report.options.paper, options: ReportChoices.paper)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Paper")
            }
            SheetField(label: "Orientation") {
                SheetSegments(selection: $report.options.orientation, options: ReportChoices.orientation)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("Orientation")
            }
            SheetField(label: "CSV separator") {
                SheetSegments(selection: $report.options.csvSeparator, options: ReportChoices.separator)
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("CSV separator")
            }
        }
    }
}

// MARK: - Preview

private struct ReportPreviewPane: View {
    @ObservedObject var report: ReportModel

    var body: some View {
        VStack(spacing: 0) {
            ReportStatusStrip(report: report)
            Rectangle().fill(Theme.hairline).frame(height: 1)
            previewBody
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .blockSurface(radius: 12)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var emptyTitle: String {
        report.options.billableOnly ? "No billable work in this period" : "No work in this period"
    }

    @ViewBuilder
    private var previewBody: some View {
        if let message = report.loadError {
            VStack(alignment: .leading, spacing: 10) {
                ReportNotice(title: "Daylanes couldn’t build this report", detail: message,
                             icon: "exclamationmark.triangle")
                Button("Try again") { report.fetch() }
                    .buttonStyle(PillButtonStyle())
            }
            .padding(.horizontal, 24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if report.rangeError != nil {
            ReportNotice(title: "Choose a valid period", detail: "The last day must be on or after the first day.",
                         icon: "calendar")
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let document = report.preview, report.hasContent {
            ReportPDFCanvas(document: document)
                .accessibilityLabel("Report preview")
        } else if report.rendering == nil {
            ProgressView("Building the report…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ReportNotice(title: emptyTitle,
                         detail: "Choose another period or other projects, or include non-billable work.",
                         icon: "doc.text")
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

/// Totals over the preview (hours, amount, pages) and the document's warnings.
private struct ReportStatusStrip: View {
    @ObservedObject var report: ReportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 18) {
                figures
                Spacer(minLength: 8)
                if report.loading || report.updating {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(report.loading ? "Loading report rows" : "Updating the preview")
                }
            }
            ForEach(report.warningTexts, id: \.self) { text in
                Label(text, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Theme.Tint.amber.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    @ViewBuilder
    private var figures: some View {
        if report.hasContent {
            if let hours = report.hoursText { figure("Hours", hours) }
            if let amount = report.amountText { figure("Amount", amount) }
            figure("Pages", report.pageCount.formatted())
        } else {
            Text(report.loading ? "Loading…" : "Nothing to export yet")
                .font(.callout)
                .foregroundStyle(Theme.secondary)
        }
    }

    private func figure(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(Theme.secondary)
            Text(value).font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(Theme.text)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The preview's backdrop with the page centred on it: the PDF view is exactly as wide as the page it shows
/// (fitted to the panel, at most 1.6 times its printed size), so the page never hugs one side.
private struct ReportPDFCanvas: View {
    let document: PDFDocument

    /// Room left and right of the page when the panel is narrow, and the page break margins PDFKit adds.
    private static let gutter: CGFloat = 16
    private static let pageMargins: CGFloat = 8

    private var pageWidth: CGFloat {
        guard let page = document.page(at: 0) else { return 595 }
        let width: CGFloat = page.bounds(for: .mediaBox).width
        return width > 1 ? width : 595
    }

    static func viewWidth(available: CGFloat, pageWidth: CGFloat) -> CGFloat {
        let fitted: CGFloat = available - 2 * gutter
        let largest: CGFloat = pageWidth * 1.6 + pageMargins
        return max(min(fitted, largest), 120)
    }

    static func scale(viewWidth: CGFloat, pageWidth: CGFloat) -> CGFloat {
        max((viewWidth - pageMargins) / (pageWidth + pageMargins), 0.1)
    }

    var body: some View {
        GeometryReader { proxy in
            canvas(available: proxy.size.width)
        }
        .background(Color(nsColor: ReportPDFPreview.background))
    }

    private func canvas(available: CGFloat) -> some View {
        let width: CGFloat = ReportPDFCanvas.viewWidth(available: available, pageWidth: pageWidth)
        let scale: CGFloat = ReportPDFCanvas.scale(viewWidth: width, pageWidth: pageWidth)
        return ReportPDFPreview(document: document, scale: scale)
            .frame(width: width)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The PDF itself, in PDFKit, so the preview is exactly the exported file.
private struct ReportPDFPreview: NSViewRepresentable {
    let document: PDFDocument
    /// Set by `ReportPDFCanvas` so the page fills the view's width.
    let scale: CGFloat

    static let background: NSColor = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return NSColor(hex: isDark ? 0x2A2A2E : 0xE6E4E0)
    }

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = false
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = ReportPDFPreview.background
        view.document = document
        view.scaleFactor = scale
        return view
    }

    func updateNSView(_ view: PDFView, context: Context) {
        if view.document === document {
            if abs(view.scaleFactor - scale) > 0.001 { view.scaleFactor = scale }
            return
        }
        // Keep the reader where they were: the same page, the same point on it.
        let previous: PDFDestination? = view.currentDestination
        var pageIndex = 0
        if let page = previous?.page, let old = view.document {
            pageIndex = old.index(for: page)
        }
        view.document = document
        view.scaleFactor = scale
        guard let previous, document.pageCount > 0 else { return }
        guard let page = document.page(at: min(max(pageIndex, 0), document.pageCount - 1)) else { return }
        view.layoutDocumentView()
        view.go(to: PDFDestination(page: page, at: previous.point))
    }
}
