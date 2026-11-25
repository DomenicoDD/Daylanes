import SwiftUI

extension View {
    func licenceGate(compact: Bool = false) -> some View {
        #if TRACKER_PAYMENTS
        LicenceGate(compact: compact) { self }
        #else
        self
        #endif
    }
}

#if TRACKER_PAYMENTS
/// Wraps each scene. After the trial, an unlicensed copy shows only the purchase and licence prompt.
/// Tracking keeps running behind the prompt (TrackerLifecycle), so no time is missing after buying.
struct LicenceGate<Content: View>: View {
    @ObservedObject private var licensing = Licensing.shared
    var compact = false
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            switch licensing.status {
            case .loading:
                ProgressView()
                    .frame(maxWidth: compact ? 340 : .infinity, maxHeight: compact ? nil : .infinity)
                    .padding(compact ? 24 : 0)
            case .trialEnded:
                TrialEndedPrompt(compact: compact)
            default:
                content()
            }
        }
        .task { await licensing.start() }
    }
}

struct TrialEndedPrompt: View {
    @ObservedObject private var licensing = Licensing.shared
    let compact: Bool
    @State private var key = ""

    var body: some View {
        VStack(spacing: 16) {
            if !compact {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().aspectRatio(contentMode: .fit).frame(width: 72, height: 72)
                    .accessibilityHidden(true)
            }
            Text("Your free trial has ended").font(compact ? .headline : .title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Buy a licence to use Daylanes again. It keeps tracking on this Mac, so your time is here when you unlock it. Quit Daylanes to stop tracking.")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Buy for \(Licensing.fullPrice) USD…") { Task { await licensing.buy() } }
                .buttonStyle(.borderedProminent)
            HStack {
                TextField("Licence key", text: $key).textFieldStyle(.roundedBorder).onSubmit(activate)
                Button("Activate", action: activate)
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("Already bought it? The receipt email links to your licence key.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if licensing.busy { ProgressView().controlSize(.small) }
            if let message = licensing.message {
                Text(message).font(.callout).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Button("Quit Daylanes") { NSApplication.shared.terminate(nil) }.buttonStyle(.borderless)
        }
        .disabled(licensing.busy)
        .tint(Theme.accent)
        .padding(compact ? 18 : 32)
        .frame(width: compact ? 340 : 460)
        .frame(maxWidth: compact ? nil : .infinity, maxHeight: compact ? nil : .infinity)
        .background(compact ? Color.clear : Theme.card)
    }

    private func activate() {
        let typed = key
        Task { await licensing.activate(typed) }
    }
}
#endif
