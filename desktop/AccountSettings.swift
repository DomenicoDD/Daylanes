import SwiftUI

/// Settings > Account: trial or licence status, Buy, Enter licence key, Deactivate this Mac.
struct AccountSettings: View {
    @ObservedObject private var licensing = Licensing.shared
    @State private var key = ""
    @State private var confirmDeactivate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 19) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Licence").font(.headline).accessibilityAddTraits(.isHeader)
                statusText
            }
            if licensing.state?.key == nil {
                buy
                Divider()
                enterKey
            } else {
                licensed
            }
            if let message = licensing.message {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Text("When the trial ends, Daylanes locks until you activate a licence, and keeps tracking in the background. A licence works forever on up to two Macs and includes every future update.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .disabled(licensing.busy)
        .task { await licensing.start() }
    }

    @ViewBuilder
    private var statusText: some View {
        switch licensing.status {
        case .loading:
            ProgressView().controlSize(.small)
        case let .trial(days):
            Text("Free trial: \(days == 1 ? "1 day" : "\(days) days") left. Buy before it ends for \(Licensing.trialPrice) USD instead of \(Licensing.fullPrice) USD.")
        case .trialEnded:
            Text("Your trial has ended. Daylanes costs \(Licensing.fullPrice) USD, once.")
        case .licensed:
            VStack(alignment: .leading, spacing: 4) {
                Text("Licensed to \(owner)")
                Text("Every future update is included.")
                    .foregroundStyle(.secondary)
            }
        case .checkOverdue:
            VStack(alignment: .leading, spacing: 6) {
                Text("Daylanes couldn't reach Polar for \(Licensing.offlineGraceDays) days to check your licence. Your key is kept; connect to the internet and check again.")
                Button("Check Again") { Task { await licensing.validate() } }
            }
        }
    }

    private var owner: String {
        let state = licensing.state
        return [state?.name, state?.email].compactMap { $0 }.filter { !$0.isEmpty }.first ?? "you"
    }

    private var buy: some View {
        HStack {
            Button("Buy for \(licensing.price) USD…") {
                Task { await licensing.buy() }
            }
            .buttonStyle(.borderedProminent)
            if licensing.busy { ProgressView().controlSize(.small) }
        }
    }

    private var enterKey: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Already bought it? Copy the licence key from your Polar purchases page (the receipt email links to it) and paste it here.")
                .foregroundStyle(.secondary)
            HStack {
                TextField("Licence key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 360)
                    .onSubmit(activate)
                Button("Activate", action: activate)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var licensed: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let display = licensing.state?.key {
                LabeledContent("Key", value: masked(display))
            }
            LabeledContent("Macs", value: "This Mac is one of \(Licensing.activationLimitText(licensing.state?.activationLimit))")
            Button("Deactivate this Mac…") { confirmDeactivate = true }
                .confirmationDialog("Deactivate Daylanes on this Mac?", isPresented: $confirmDeactivate) {
                    Button("Deactivate") { Task { await licensing.deactivate() } }
                } message: {
                    Text("This frees one of your activations so you can use the key on another Mac. If the trial here is over, Daylanes locks until you activate a key again. Tracking keeps running.")
                }
        }
    }

    private func activate() {
        let typed = key
        Task {
            await licensing.activate(typed)
            if licensing.state?.key != nil { key = "" }
        }
    }

    private func masked(_ key: String) -> String {
        guard key.count > 8 else { return key }
        return String(key.prefix(9)) + "…" + String(key.suffix(4))
    }
}
