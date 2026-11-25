import SwiftUI

extension AIProvider {
    var usageDescription: String {
        switch self {
        case .openrouter: "Reported usage for assigned keys"
        case .fal: "Model API usage after discounts"
        case .higgsfield: "Estimated API cost for completed generations"
        case .replicate: "Prediction history and processing time"
        case .ollama: "Cloud usage value, including usage covered by your plan"
        }
    }

    var connectionInstructions: String {
        switch self {
        case .openrouter: "Use a management key with activity and API-key listing access."
        case .fal: "Create a key with the BILLING preset in the fal workspace you want to track."
        case .higgsfield: "Use a dedicated key from Higgsfield Console. The usage API is documented under Enterprise. Keys appear here once they have completed generations in the synced period."
        case .replicate: "Use a token for the Replicate user or organization you want to track. Prediction history is account-wide."
        case .ollama: "Create a cloud API key. Tracker reads your own cloud usage and available credits."
        }
    }

    var keysURL: URL {
        let address: String
        switch self {
        case .openrouter: address = "https://openrouter.ai/settings/management-keys"
        case .fal: address = "https://fal.ai/dashboard/keys"
        case .higgsfield: address = "https://console.higgsfield.ai"
        case .replicate: address = "https://replicate.com/account/api-tokens"
        case .ollama: address = "https://ollama.com/settings/keys"
        }
        return URL(string: address)!
    }
}

private extension ProviderUsage.Metrics {
    var hasValues: Bool { !spend.isEmpty || quantities.values.contains { $0 > 0 } }

    var costs: String {
        spend.sorted { $0.key < $1.key }.map { currency, amount in
            let precision = (amount > 0 && amount < 0.01) ? 2...6 : 2...2
            return "\(currency) \(amount.formatted(.number.precision(.fractionLength(precision))))"
        }.joined(separator: " · ")
    }

    var usage: String {
        quantities.filter { $0.value > 0 }.sorted { $0.key < $1.key }.map { unit, count in
            "\(count.formatted(.number.precision(.fractionLength(0...3)))) \(unit.lowercased())"
        }.joined(separator: " · ")
    }

    var headline: String {
        if !costs.isEmpty { return costs }
        return usage.isEmpty ? "No recorded usage" : usage
    }

    var detail: String {
        let parts = [costs.isEmpty ? "" : usage, hasUnpricedUsage ? "Some usage has no reported cost" : ""]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

struct ProviderUsageSection: View {
    let snapshot: Snapshot
    var projects: Set<String>? = nil

    var body: some View {
        let accounts = (snapshot.providerUsage ?? []).filter { account in
            projects == nil || account.keys.contains { includes($0) }
        }
        if !accounts.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                SectionTitle(title: "AI provider usage")
                ForEach(accounts) { account in
                    ProviderUsageCard(account: account, start: snapshot.start, end: snapshot.endExclusive,
                                      keys: account.keys.filter(includes), scoped: projects != nil)
                }
            }
        }
    }

    private func includes(_ key: ProviderUsage.Line) -> Bool {
        guard let projects else { return true }
        return key.project.map { projects.contains($0) } ?? false
    }
}

private struct ProviderUsageCard: View {
    let account: ProviderUsage.Account
    let start: String
    let end: String
    let keys: [ProviderUsage.Line]
    let scoped: Bool

    var body: some View {
        let totals = scoped ? keys.reduce(into: ProviderUsage.Metrics()) { $0.add($1.metrics) } : account.totals
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 9) {
                if let first = account.from, let until = account.until {
                    Text("Synced \(first) through \(lastDay(until)) UTC").font(.caption).foregroundStyle(.secondary)
                }
                Text("Last synced \(Date(timeIntervalSince1970: account.fetchedAt).formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                if let balance = account.balance {
                    ForEach(balance.keys.sorted(), id: \.self) { key in
                        if let amount = balance[key] {
                            usageRow(key, details: nil, value: "USD \(amount.formatted(.number.precision(.fractionLength(2))))")
                        }
                    }
                }
                if !keys.isEmpty {
                    Text("API keys").font(.subheadline.weight(.semibold))
                    ForEach(keys) { key in
                        usageRow(key.name, details: [key.client, key.project].compactMap { $0 }.joined(separator: " / "),
                                 value: key.metrics.hasValues ? key.metrics.headline : "—")
                    }
                }
                if !scoped && account.provider.supportsProjects && account.unassigned.hasValues {
                    usageRow("Unassigned usage", details: nil, value: account.unassigned.headline)
                }
                if !scoped && !account.models.isEmpty {
                    Text("Models").font(.subheadline.weight(.semibold))
                    ForEach(account.models) { line in
                        usageRow(line.name, details: line.metrics.detail, value: line.metrics.headline)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(account.provider.name).fontWeight(.semibold)
                    Text(account.provider.usageDescription).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 3) {
                    Text(account.from == nil ? "No synced days" : totals.headline)
                        .font(.callout.weight(.semibold)).monospacedDigit()
                    if account.from != nil {
                        let detail = [totals.detail, coverageNote].filter { !$0.isEmpty }.joined(separator: " · ")
                        if !detail.isEmpty {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    private var coverageNote: String {
        guard let first = account.from, let until = account.until, start < first || until < end else { return "" }
        return "\(first) through \(lastDay(until)) UTC"
    }

    private func lastDay(_ until: String) -> String {
        (try? Day.parse(until).adding(days: -1).iso) ?? until
    }

    private func usageRow(_ name: String, details: String?, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name).textSelection(.enabled)
                if let details, !details.isEmpty {
                    Text(details).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

struct ProviderKeyRoutes: View {
    let account: ProviderUsage.Account
    let edit: (ProviderUsage.Line) -> Void

    var body: some View {
        DisclosureGroup("Assign API keys to projects (\(account.keys.count))") {
            if account.keys.isEmpty {
                Text("No keys found in the synced account.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(account.keys) { key in
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(key.name).textSelection(.enabled)
                        if let project = key.project {
                            Text([key.client, project].compactMap { $0 }.joined(separator: " / "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button(key.project == nil ? "Assign…" : "Edit…") { edit(key) }
                        .accessibilityLabel("Assign \(key.name)")
                }
                .padding(.vertical, 3)
            }
        }
    }
}

struct ProviderCredentialEditor: View {
    let provider: AIProvider
    let connected: Bool
    let save: (String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var keyID = ""
    @State private var secret = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text(connected ? "Manage \(provider.name)" : "Connect \(provider.name)").font(.title2.bold())
            Text(provider.connectionInstructions).foregroundStyle(.secondary)
            Link("Open \(provider.name) keys", destination: provider.keysURL)
            if provider == .higgsfield {
                TextField("Key ID", text: $keyID)
                SecureField("Key secret", text: $secret)
            } else {
                SecureField(connected ? "New API credential" : "API credential", text: $secret)
            }
            HStack {
                if connected { Button("Disconnect", role: .destructive) { save(nil) } }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(connected ? "Update key" : "Connect") {
                    save(provider == .higgsfield ? "\(keyID.trimmed):\(secret.trimmed)" : secret.trimmed)
                }
                .disabled(secret.trimmed.isEmpty || (provider == .higgsfield && keyID.trimmed.isEmpty))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

struct ProviderKeyEditor: View {
    let provider: AIProvider
    let key: ProviderUsage.Line
    let projects: [Project]
    let save: (String?, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var destination: String?
    @State private var alias: String

    init(provider: AIProvider, key: ProviderUsage.Line, projects: [Project], save: @escaping (String?, String?) -> Void) {
        self.provider = provider
        self.key = key
        self.projects = projects
        self.save = save
        _destination = State(initialValue: key.project)
        _alias = State(initialValue: key.name == key.id ? "" : key.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            Text("Assign \(provider.name) API key").font(.title2.bold())
            Text(key.name).foregroundStyle(.secondary).textSelection(.enabled)
            if provider == .higgsfield && key.name != key.id {
                Text(key.id).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            if provider == .higgsfield { TextField("Key name in Tracker", text: $alias) }
            Picker("Project", selection: $destination) {
                Text("Unassigned").tag(nil as String?)
                ForEach(projects) { project in
                    Text([project.client, project.name].compactMap { $0 }.joined(separator: " / ")).tag(Optional(project.name))
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save assignment") { save(destination, provider == .higgsfield ? alias.trimmed : nil) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}
