import SwiftUI

struct CustomPeriodEditor: View {
    @State private var first: String
    @State private var last: String
    let apply: (Period) -> Void

    init(range: LedgerRange, apply: @escaping (Period) -> Void) {
        _first = State(initialValue: range.start)
        _last = State(initialValue: ReportCalendar.adding(days: -1, to: range.endExclusive))
        self.apply = apply
    }

    private var period: Period? {
        guard let firstDay = try? Day.parse(first), let lastDay = try? Day.parse(last), firstDay <= lastDay else { return nil }
        return .custom(first: firstDay, last: lastDay)
    }

    var body: some View {
        SheetFrame(title: "Custom date range", primary: "Apply", canSubmit: period != nil, width: 400,
                   submit: { if let period { apply(period) } }) {
            HStack(spacing: 16) {
                ReportDayPicker(label: "From", day: $first)
                ReportDayPicker(label: "Through", day: $last)
            }
            if period == nil {
                Text("Choose an end date on or after the start date.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
import UniformTypeIdentifiers

func normalizedAmount(_ value: String) -> String? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
    guard trimmed.range(of: #"^[0-9]+(?:\.[0-9]{1,2})?$"#, options: .regularExpression) != nil else {
        return nil
    }
    return trimmed
}

struct ProjectEditor: View {
    let folder: String?
    let existing: Project?
    let clients: [String]
    let initialClient: String?
    /// The client standing for your own internal and personal work.
    let selfClient: String
    /// Name, client, classification, folder, and the colour change: nil keeps it, "" automatic, else #RRGGBB.
    let save: (String, String, String, String?, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var client = ""
    @State private var color: Color = .blue
    @State private var customColor = false
    @State private var colorChanged = false
    @State private var kind = "billable"
    @State private var mappedFolder = ""
    @State private var newClientName = ""

    static let newClient = "\u{1}new-client"

    private var clientOptions: [String] {
        Set(clients + [selfClient]).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    private var chosenClient: String {
        client == ProjectEditor.newClient ? newClientName.trimmed : client.trimmed
    }

    static let swatches = ["#3B82F6", "#14B8A6", "#22C55E", "#F59E0B", "#EF4444", "#EC4899", "#8B5CF6"]

    private var previewColor: Color {
        customColor ? color : ProjectColor.automatic(name.trimmed.isEmpty ? (existing?.name ?? "") : name.trimmed)
    }

    private var canSave: Bool { !name.trimmed.isEmpty && !(kind == "billable" && chosenClient.isEmpty) }

    /// Created from a client's page: the client is given, so there is no client picker.
    private var fixedClient: Bool { existing == nil && initialClient != nil && client == initialClient }

    private func submit() {
        save(name.trimmed, chosenClient, kind,
             mappedFolder.trimmed.isEmpty ? nil : mappedFolder.trimmed,
             colorChanged ? (customColor ? color.hexString ?? "" : "") : nil)
    }

    var body: some View {
        SheetFrame(title: existing?.name ?? (name.trimmed.isEmpty ? "New project" : name.trimmed), dot: previewColor,
                   subtitle: existing != nil ? "Edit project" : fixedClient ? "In \(client)" : nil,
                   primary: existing == nil ? "Create project" : "Save project", canSubmit: canSave, width: 560,
                   submit: submit) {
            if existing == nil {
                SheetField(label: "Name") {
                    SheetTextField(placeholder: "e.g. Lumen Dashboard", text: $name, autofocus: true)
                }
            }
            if !fixedClient {
                SheetGroup {
                    SheetField(label: "Client") {
                        SheetMenu(selection: $client, groups: [
                            clientOptions.map { ($0, $0 == selfClient ? "\($0) (your own work)" : $0) },
                            [(ProjectEditor.newClient, "New client…")],
                        ])
                    }
                    if client == ProjectEditor.newClient {
                        SheetField(label: "New client name") {
                            SheetTextField(placeholder: "e.g. Lumen Labs", text: $newClientName)
                        }
                    }
                }
            }
            // Whose work it is follows from the client: a real client means client work,
            // your own client means internal or personal. How it's billed lives in Billing.
            if client == selfClient {
                SheetField(label: "Type") {
                    SheetSegments(selection: $kind, options: [("internal", "Internal"), ("personal", "Personal")])
                }
            }
            SheetField(label: "Colour") {
                HStack(spacing: 8) {
                    Button { pickAutomatic() } label: {
                        Text("Auto")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(customColor ? Theme.text : SheetTheme.accent)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .background(customColor ? SheetTheme.soft : SheetTheme.accent.opacity(0.1), in: Capsule())
                            .overlay(Capsule().strokeBorder(customColor ? .clear : SheetTheme.accent, lineWidth: 1.5))
                    }
                    .buttonStyle(.plain)
                    ForEach(Self.swatches, id: \.self) { hex in
                        let selected = customColor && color.hexString?.uppercased() == hex
                        Button { pick(hex) } label: {
                            Circle().fill(Color(hex: hex) ?? .gray)
                                .frame(width: 20, height: 20)
                                .padding(2)
                                .overlay(Circle().strokeBorder(selected ? Theme.text : .clear, lineWidth: 2))
                        }
                        .buttonStyle(.plain)
                        .help(hex)
                    }
                    // A colour chosen earlier that isn't one of the swatches stays visible and selected.
                    if customColor, let hex = color.hexString?.uppercased(), !Self.swatches.contains(hex) {
                        Circle().fill(color)
                            .frame(width: 20, height: 20)
                            .padding(2)
                            .overlay(Circle().strokeBorder(Theme.text, lineWidth: 2))
                            .help("Current colour")
                    }
                }
            }
            if let folder {
                SheetOption(title: "Always use this project for this folder",
                            detail: folder, isOn: Binding(
                                get: { !mappedFolder.isEmpty },
                                set: { mappedFolder = $0 ? folder : "" }))
            } else {
                SheetField(label: "Folder", note: existing == nil ? "optional, routes agent runs here" : "add one, optional") {
                    HStack(spacing: 8) {
                        SheetTextField(placeholder: "No folder", text: $mappedFolder, mono: !mappedFolder.isEmpty)
                        Button("Choose…", action: chooseFolder)
                            .buttonStyle(SheetButtonStyle(kind: .secondary))
                    }
                }
            }
        }
        .onAppear {
            if let existing {
                name = existing.name
                client = existing.client ?? ""
                kind = existing.kind
                customColor = ProjectColor.choices.hex(existing.name) != nil
                color = ProjectColor.color(for: existing.name)
            } else {
                client = initialClient ?? clients.first { $0 != selfClient } ?? ProjectEditor.newClient
                // Your own work is internal by default, not client work.
                kind = client == selfClient ? "internal" : "billable"
            }
            if client.isEmpty { client = selfClient }
        }
        .onChange(of: client) { _, next in
            if next == selfClient {
                if kind == "billable" { kind = "internal" }
            } else {
                kind = "billable"
            }
        }
    }

    private func pick(_ hex: String) {
        color = Color(hex: hex) ?? color
        customColor = true
        colorChanged = true
    }

    private func pickAutomatic() {
        guard customColor else { return }
        customColor = false
        colorChanged = true
        color = ProjectColor.automatic(name.trimmed.isEmpty ? (existing?.name ?? "") : name.trimmed)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let folder = panel.url { mappedFolder = folder.path }
    }
}

struct AssignmentEditor: View {
    let activity: Activity
    let projects: [Project]
    let save: (String, Bool) -> Void
    let new: () -> Void
    @State private var target = ""
    @State private var remember = false

    var body: some View {
        SheetFrame(title: activity.folderName,
                   chips: [providerName(activity.provider), activity.branch,
                           "\(activity.entryCount.formatted()) entries"].compactMap { $0 },
                   subtitle: activity.folder, monoSubtitle: true,
                   primary: "Assign",
                   canSubmit: !target.isEmpty && !(target == activity.project && !remember),
                   submit: { save(target, remember) }) {
            if projects.isEmpty {
                Text("Create a project to assign this activity.").foregroundStyle(SheetTheme.muted)
            } else {
                SheetField(label: "Project") {
                    SheetMenu(selection: $target, groups: [projects.map { ($0.name, $0.name) }],
                              placeholder: "Choose a project",
                              dot: { $0.isEmpty ? nil : ProjectColor.color(for: $0) })
                }
                if activity.folder != nil {
                    SheetOption(title: "Always use this project for this folder",
                                detail: "Applies to the other unassigned activity in this folder and to future imports.",
                                isOn: $remember)
                }
            }
        } leading: {
            Button("+ New project", action: new).buttonStyle(SheetButtonStyle(kind: .link))
        }
        .onAppear { target = activity.project ?? "" }
    }
}

struct RepoEditor: View {
    let project: Project
    let save: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var repo = ""
    @State private var confirmUnlink = false

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("GitHub repository").font(.title2.bold())
            Text(project.name).fontWeight(.medium)
            TextField("Repository", text: $repo, prompt: Text("owner/repo"))
                .textFieldStyle(.roundedBorder)
            Text("Daylanes sends this repository name to GitHub and reads its pull requests using your GitHub CLI sign-in.")
                .foregroundStyle(.secondary)
            HStack {
                if project.githubRepo != nil {
                    Button("Unlink…", role: .destructive) { confirmUnlink = true }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(repo.trimmed == project.githubRepo ? "Refresh pull requests" : "Link and refresh") {
                    save(repo.trimmed)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(repo.trimmed.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 445)
        .onAppear { repo = project.githubRepo ?? "" }
        .alert("Unlink GitHub repository?", isPresented: $confirmUnlink) {
            Button("Cancel", role: .cancel) {}
            Button("Unlink", role: .destructive) { save(nil) }
        } message: {
            Text("This clears cached pull requests and routing rules for \(project.name).")
        }
    }
}

struct EntryEditor: View {
    let project: Project
    let isExpense: Bool
    let currency: String
    let save: (String, String, String, Bool) -> Void
    @State private var amount = ""
    @State private var description = ""
    @State private var activity = "other"
    @State private var task = ""
    @State private var reimbursable = false

    private static let durations: [(String, Int)] = [("15 min", 15), ("30 min", 30), ("1 h", 60), ("2 h", 120)]
    private static let activities: [(String, String)] = [("prompting", "Prompting"), ("reviewing", "Reviewing"), ("other", "Other")]

    private var currencySymbol: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.currencySymbol ?? currency
    }

    private var subtitle: String {
        [isExpense ? "Log expense" : "Log human time", project.client,
         Date().formatted(.dateTime.weekday(.wide).day().month(.wide))].compactMap { $0 }.joined(separator: " · ")
    }

    private var canSave: Bool {
        guard let value = normalizedAmount(amount) else { return false }
        return isExpense ? !description.trimmed.isEmpty : (Double(value) ?? 0) > 0
    }

    var body: some View {
        SheetFrame(title: project.name, dot: ProjectColor.color(for: project.name), subtitle: subtitle,
                   primary: isExpense ? "Log expense" : "Log time", canSubmit: canSave, submit: {
            if let value = normalizedAmount(amount) {
                save(value, isExpense ? description.trimmed : activity, task.trimmed, reimbursable)
            }
        }) {
            if isExpense {
                HStack(alignment: .top, spacing: 12) {
                    SheetField(label: "Description") {
                        SheetTextField(placeholder: "e.g. fal asset generation", text: $description, autofocus: true)
                    }
                    SheetField(label: "Amount") {
                        SheetTextField(placeholder: "0.00", text: $amount, prefix: currencySymbol, numeric: true)
                    }
                    .frame(width: 150)
                }
            } else {
                SheetField(label: "Duration") {
                    HStack(spacing: 8) {
                        SheetTextField(placeholder: "0", text: $amount, numeric: true, autofocus: true)
                            .frame(width: 96)
                        Text("min").font(.system(size: 13)).foregroundStyle(SheetTheme.muted).padding(.trailing, 6)
                        ForEach(Self.durations, id: \.1) { item in
                            SheetChip(title: item.0, selected: amount == String(item.1), outlined: true) {
                                amount = String(item.1)
                            }
                        }
                    }
                }
                SheetField(label: "Activity") {
                    HStack(spacing: 6) {
                        ForEach(Self.activities, id: \.0) { item in
                            SheetChip(title: item.1, selected: activity == item.0) { activity = item.0 }
                        }
                    }
                }
            }
            SheetField(label: "Task", note: "optional") {
                SheetTextField(placeholder: "e.g. WEB-42", text: $task)
            }
            if isExpense {
                SheetOption(title: "Reimbursable", detail: "Marked as reimbursable in CSV exports and invoices.",
                            isOn: $reimbursable)
            }
        }
    }
}

struct PriceEditor: View {
    let price: ModelPrice
    let currency: String
    let save: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var values = ["", "", "", ""]

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(price.model).font(.title2.bold())
            Text("Manual price per million tokens (\(currency))").foregroundStyle(.secondary)
            Form {
                TextField("Uncached input", text: $values[0])
                TextField("Cache reads", text: $values[1])
                TextField("Cache writes", text: $values[2])
                TextField("Output", text: $values[3])
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save prices") { save(values.compactMap(normalizedAmount)) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(values.compactMap(normalizedAmount).count != values.count)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear {
            if let prices = price.prices {
                values = [prices.input, prices.cached, prices.cacheWrite, prices.output]
                    .map { String(format: "%.2f", Double($0) / 100) }
            }
        }
    }
}

struct SubscriptionEditor: View {
    let plan: Subscription?
    let currency: String
    let save: (String, String?, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var provider = ""
    @State private var monthly = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(plan == nil ? "Add subscription" : "Edit subscription").font(.title2.bold())
            Text("Enter what you pay each month. For an annual plan, enter its monthly equivalent.")
                .foregroundStyle(.secondary)
            Form {
                TextField("Provider", text: $provider, prompt: Text("OpenAI, Anthropic, or another provider"))
                TextField("Plan name", text: $name, prompt: Text("ChatGPT Pro or Claude Pro"))
                    .disabled(plan != nil)
                TextField("Monthly fee (\(currency))", text: $monthly)
            }
            HStack {
                if let plan {
                    Button("Remove", role: .destructive) { save(plan.name, nil, provider.trimmed) }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save subscription") {
                    if let amount = normalizedAmount(monthly) { save(name.trimmed, amount, provider.trimmed) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmed.isEmpty || normalizedAmount(monthly) == nil)
            }
        }
        .padding(22)
        .frame(width: 420)
        .onAppear {
            name = plan?.name ?? ""
            provider = plan?.provider ?? ""
            monthly = plan?.monthly ?? ""
        }
    }
}

struct ClientEditor: View {
    let previous: String?
    /// The new name, and the icon change: nil keeps it, "" removes it, otherwise a prepared PNG file.
    let save: (String, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var icon: String?
    @State private var preview: NSImage?
    @State private var removed = false
    @State private var problem: String?

    /// Icons are drawn at up to 32 pt, so a 64 px square is sharp on Retina screens.
    static let iconPixels = 64

    private var hasIcon: Bool { preview != nil || (!removed && previous.flatMap { ProjectColor.choices.icon($0) } != nil) }

    var body: some View {
        SheetFrame(title: previous ?? "New client",
                   subtitle: previous == nil ? "Projects for this client share its billing rates and icon."
                       : "Projects and reports will use the new name.",
                   primary: previous == nil ? "Create client" : "Save",
                   canSubmit: !name.trimmed.isEmpty && !(name.trimmed == previous && icon == nil && !removed),
                   submit: { save(name.trimmed, icon ?? (removed ? "" : nil)) }) {
            HStack(alignment: .center, spacing: 16) {
                Button(action: chooseIcon) {
                    Group {
                        if let preview {
                            Image(nsImage: preview).resizable().interpolation(.high)
                                .frame(width: 64, height: 64)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        } else if hasIcon, !removed {
                            ClientIcon(client: previous, size: 64)
                        } else {
                            Image(systemName: "photo")
                                .font(.system(size: 20))
                                .foregroundStyle(SheetTheme.muted)
                                .frame(width: 64, height: 64)
                                .background(SheetTheme.field, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                                    .strokeBorder(SheetTheme.border, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])))
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(hasIcon ? "Change icon" : "Choose icon")
                VStack(alignment: .leading, spacing: 4) {
                    (Text("Icon").font(.system(size: 13, weight: .semibold))
                     + Text(" · optional").font(.system(size: 13)).foregroundColor(SheetTheme.muted))
                    Text("PNG or JPEG, cropped to a square. Without one, Daylanes uses the client’s initial.")
                        .font(.system(size: 12)).foregroundStyle(SheetTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 4) {
                        Button(hasIcon ? "Change…" : "Choose…", action: chooseIcon)
                            .buttonStyle(SheetButtonStyle(kind: .link))
                        if hasIcon {
                            Button("Remove") { preview = nil; icon = nil; removed = true }
                                .buttonStyle(SheetButtonStyle(kind: .destructive))
                        }
                    }
                    .padding(.leading, -6)
                }
            }
            if let problem { Text(problem).font(.callout).foregroundStyle(.red) }
            SheetField(label: "Client name") {
                SheetTextField(placeholder: "e.g. Lumen Labs", text: $name, autofocus: true)
            }
        }
        .onAppear { name = previous ?? "" }
    }

    private func chooseIcon() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .image]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let source = NSImage(contentsOf: url), let square = Self.squarePNG(source) else {
            problem = "Daylanes could not read that image."
            return
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("tracker-icon-\(UUID().uuidString).png")
        do {
            try square.data.write(to: file, options: .atomic)
            icon = file.path
            preview = square.image
            removed = false
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    /// Centre-crops the image to a square and scales it to `iconPixels`, as PNG.
    static func squarePNG(_ source: NSImage) -> (data: Data, image: NSImage)? {
        guard let cg = source.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = min(cg.width, cg.height)
        let crop = CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)
        guard let cropped = cg.cropping(to: crop),
              let context = CGContext(data: nil, width: iconPixels, height: iconPixels, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: iconPixels, height: iconPixels))
        guard let scaled = context.makeImage() else { return nil }
        let bitmap = NSBitmapImageRep(cgImage: scaled)
        guard let data = bitmap.representation(using: .png, properties: [:]) else { return nil }
        return (data, NSImage(cgImage: scaled, size: NSSize(width: iconPixels, height: iconPixels)))
    }
}

struct TogglTokenEditor: View {
    let connected: Bool
    let save: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(connected ? "Manage Toggl Track" : "Connect Toggl Track").font(.title2.bold())
            Text("Daylanes sends your token to Toggl Track to read project names and time entries. The token is stored in macOS Keychain.")
                .foregroundStyle(.secondary)
            Link("Find your API token in Toggl Track", destination: URL(string: "https://track.toggl.com/profile")!)
            SecureField(connected ? "New API token" : "API token", text: $key)
            HStack {
                if connected {
                    Button("Disconnect", role: .destructive) { save(nil) }
                        .help("Remove the saved token and keep previously imported time")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(connected ? "Update token" : "Connect") { save(key.trimmed) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmed.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 445)
    }
}

struct TogglImportEditor: View {
    let sources: [TogglProject]
    let snapshot: Snapshot
    let runImport: (TogglProject, String, String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var source: Int?
    @State private var target: String?
    @State private var start = Date()
    @State private var last = Date()

    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(identifier: snapshot.timezone) ?? .current
        return result
    }

    private var format: DateFormatter {
        let result = DateFormatter()
        result.locale = Locale(identifier: "en_US_POSIX")
        result.calendar = calendar
        result.timeZone = calendar.timeZone
        result.dateFormat = "yyyy-MM-dd"
        return result
    }

    private var days: Int {
        calendar.dateComponents([.day], from: calendar.startOfDay(for: start),
                                to: calendar.startOfDay(for: last)).day ?? -1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Import Toggl Track time").font(.title2.bold())
            Form {
                Picker("Toggl project", selection: $source) {
                    Text("Choose project").tag(nil as Int?)
                    ForEach(sources) { item in Text(item.label).tag(Optional(item.id)) }
                }
                Picker("Daylanes project", selection: $target) {
                    Text("Choose project").tag(nil as String?)
                    ForEach(snapshot.projects) { item in
                        Text([item.client, item.name].compactMap { $0 }.joined(separator: " / ")).tag(Optional(item.name))
                    }
                }
                DatePicker("First day", selection: $start, displayedComponents: .date)
                DatePicker("Last day", selection: $last, displayedComponents: .date)
            }
            .environment(\.calendar, calendar)
            .environment(\.timeZone, calendar.timeZone)
            Text("Imports completed entries that started in this range (\(snapshot.timezone)). Reimporting updates the local copy for that Toggl project and date range.")
                .foregroundStyle(.secondary)
            Text("Imported time is added to manually logged and automatic time. Overlaps count toward both sources.")
                .foregroundStyle(.secondary)
            if !(0..<31).contains(days) {
                Text("Choose a date range of 1 to 31 days.").foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import completed time") {
                    if let item = sources.first(where: { $0.id == source }), let target,
                       let end = calendar.date(byAdding: .day, value: 1, to: last) {
                        runImport(item, target, format.string(from: start), format.string(from: end))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(source == nil || target == nil || !(0..<31).contains(days))
            }
        }
        .padding(22)
        .frame(width: 480)
        .onAppear {
            if let first = format.date(from: snapshot.start) { start = first }
            if let end = format.date(from: snapshot.endExclusive),
               let final = calendar.date(byAdding: .day, value: -1, to: end) { last = final }
            if sources.count == 1 { source = sources.first?.id }
            if snapshot.projects.count == 1 { target = snapshot.projects.first?.name }
        }
    }
}

struct OpenRouterEditor: View {
    let connected: Bool
    let save: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(connected ? "Manage OpenRouter connection" : "Connect OpenRouter").font(.title2.bold())
            Text("Daylanes syncs the last 30 completed UTC days. Your management key is stored in macOS Keychain.")
                .foregroundStyle(.secondary)
            Link("Manage keys on OpenRouter", destination: URL(string: "https://openrouter.ai/settings/management-keys")!)
            SecureField(connected ? "New management key" : "Management key", text: $key)
            HStack {
                if connected {
                    Button("Disconnect", role: .destructive) { save(nil) }
                        .help("Remove the saved key and clear cached OpenRouter activity")
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(connected ? "Update key" : "Connect") { save(key.trimmed) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(key.trimmed.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

struct QuickProjectEditor: View {
    @Environment(\.dismiss) private var dismiss
    let created: (Project) -> Void
    @State private var name = ""
    @State private var client = ""
    @State private var kind = "billable"
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        SheetFrame(title: "New project", subtitle: "Every project belongs to a client. Your own work can leave it blank.",
                   primary: saving ? "Saving…" : "Create project",
                   canSubmit: !name.trimmed.isEmpty && !(kind == "billable" && client.trimmed.isEmpty),
                   busy: saving, submit: save) {
            SheetField(label: "Name") {
                SheetTextField(placeholder: "e.g. Lumen Dashboard", text: $name, autofocus: true)
            }
            SheetField(label: "Type") {
                SheetSegments(selection: $kind, options: [
                    ("billable", "Client work"), ("internal", "Internal"), ("personal", "Personal"),
                ])
            }
            SheetField(label: "Client", note: kind == "billable" ? nil : "blank for your own work") {
                SheetTextField(placeholder: "e.g. Lumen Labs", text: $client)
            }
            if let error { Label(error, systemImage: "exclamationmark.circle").foregroundStyle(.red) }
        }
        .disabled(saving)
        .interactiveDismissDisabled(saving)
    }

    private func save() {
        saving = true
        error = nil
        let projectName = name.trimmed
        let clientName = client.trimmed.isEmpty ? nil : client.trimmed
        let classification = kind
        Task {
            defer { saving = false }
            do {
                var args = ["project", "add", "--kind", classification, "--new-only"]
                if let clientName { args.append("--client=\(clientName)") }
                args += ["--", projectName]
                _ = try await Ledger.run(args)
                created(Project(name: projectName, client: clientName, kind: classification, folders: [],
                                githubRepo: nil, githubRefreshedAt: nil, githubRoutedPrs: nil, githubPullRequests: nil,
                                folderSources: []))
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

/// Rates for a client, or overrides for one project. Blank project fields use the client's terms.
struct BillingEditor: View {
    enum Scope { case client, project }

    let scope: Scope
    let name: String
    /// For a project: the client it belongs to and that client's terms, shown as the defaults.
    let client: String?
    let existing: BillingTerms
    let inherited: BillingTerms
    let currency: String
    let save: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var humanRate = ""
    @State private var agentMode = ""
    @State private var agentRate = ""
    @State private var markup = ""
    @State private var cap = ""

    private static let modes: [(String, String)] = [
        ("none", "Not billed"), ("time", "Time"), ("usage", "Usage"), ("hybrid", "Time + usage"),
    ]

    private var effectiveMode: String {
        agentMode.isEmpty ? (scope == .project ? inherited.agentMode ?? "none" : "none") : agentMode
    }

    private func modeName(_ mode: String?) -> String {
        Self.modes.first { $0.0 == (mode ?? "none") }?.1 ?? "Not billed"
    }

    private func placeholder(_ value: String?, unit: String = "") -> String {
        guard scope == .project else { return "Not set" }
        guard let value else { return "Not set on \(client ?? "the client")" }
        return "\(client ?? "Client"): \(value)\(unit)"
    }

    private func valid(_ value: String) -> Bool { value.trimmed.isEmpty || normalizedAmount(value) != nil }

    private var validMarkup: Bool {
        let value = markup.trimmed.replacingOccurrences(of: ",", with: ".")
        return value.isEmpty || (Double(value).map { $0 > 0 && $0 <= 100 } ?? false)
    }

    private var canSave: Bool { valid(humanRate) && valid(agentRate) && valid(cap) && validMarkup }

    private func submit() {
        let target = scope == .client ? "--client=\(name)" : "--project=\(name)"
        var arguments = ["billing", "set", target,
                         "--human-rate=\(normalizedAmount(humanRate) ?? "")",
                         "--agent-mode=\(agentMode)",
                         "--agent-rate=\(normalizedAmount(agentRate) ?? "")",
                         "--markup=\(markup.trimmed.replacingOccurrences(of: ",", with: "."))"]
        if scope == .client { arguments.append("--cap=\(normalizedAmount(cap) ?? "")") }
        save(arguments)
    }

    private var modeOptions: [(String, String)] {
        [("", scope == .project ? "Same as client (\(modeName(inherited.agentMode)))" : "Not billed")]
            + Self.modes.filter { scope == .project || $0.0 != "none" }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder _ content: @escaping () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold))
            SheetGroup(content: content)
        }
    }

    private func help(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(SheetTheme.muted).fixedSize(horizontal: false, vertical: true)
    }

    var body: some View {
        SheetFrame(title: "Billing", dot: scope == .project ? ProjectColor.color(for: name) : nil,
                   chips: [name],
                   subtitle: scope == .client ? "Applies to every project of this client unless a project overrides it."
                       : "Leave a field blank to use \(client ?? "the client")’s terms.",
                   primary: "Save", canSubmit: canSave, width: 540, submit: submit) {
            section("Your time") {
                SheetField(label: "Hourly rate", note: currency) {
                    SheetTextField(placeholder: placeholder(inherited.humanRate), text: $humanRate, numeric: true)
                }
                help("Overlapping time on different projects bills each project, so an hour switching between two projects bills two hours.")
            }
            section("Agents") {
                SheetField(label: "Bill agents by") {
                    SheetMenu(selection: $agentMode, groups: [modeOptions])
                }
                if effectiveMode == "time" || effectiveMode == "hybrid" {
                    SheetField(label: "Agent hourly rate", note: currency) {
                        SheetTextField(placeholder: placeholder(inherited.agentRate), text: $agentRate, numeric: true)
                    }
                }
                if effectiveMode == "usage" || effectiveMode == "hybrid" {
                    SheetField(label: "Markup on API value", note: "×") {
                        SheetTextField(placeholder: scope == .project && inherited.usageMarkup != nil
                                       ? placeholder(inherited.usageMarkup, unit: "×") : "1 (at cost)",
                                       text: $markup, numeric: true)
                    }
                }
                help(modeHelp)
            }
            if scope == .client {
                section("Limit") {
                    SheetField(label: "Monthly cap on agents", note: currency) {
                        SheetTextField(placeholder: "No cap", text: $cap, numeric: true)
                    }
                    help("Agent lines for this client never add up to more than this in a calendar month.")
                }
            }
        }
        .onAppear {
            humanRate = existing.humanRate ?? ""
            agentMode = existing.agentMode ?? ""
            agentRate = existing.agentRate ?? ""
            markup = existing.usageMarkup ?? ""
            cap = existing.monthlyCap ?? ""
        }
    }

    private var modeHelp: String {
        switch effectiveMode {
        case "time": "Agent hours × the agent rate. Each thread bills its running time, so parallel threads add up."
        case "usage": "The API-credit value of the tokens (OpenRouter rates, in USD) × the markup, converted with the exchange rate in Settings → AI costs."
        case "hybrid": "Two invoice lines: agent hours × the agent rate, plus the API-credit value × the markup."
        default: "Agents stay off the invoice. Their time and tokens are still tracked."
        }
    }
}
