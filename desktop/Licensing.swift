import AppKit
import Foundation

/// Trial, purchase and licence key.
///
/// Terms (docs/RELEASE_PLAN.md section 8): 14-day trial, then locked until licensed. A licence is
/// perpetual: it works forever, includes every future update, and covers 2 Macs. The Polar key never expires.
///
/// Settings come from Info.plist so the sandbox and live builds differ only there:
/// `TrackerPolarAPI`, `TrackerPolarOrganizationID`, `TrackerCheckoutServer`.
@MainActor
final class Licensing: ObservableObject {
    static let shared = Licensing()

    static let trialDays = 14
    private static let legacyTrialDays = 7
    private static let secondsPerDay: TimeInterval = 86_400
    /// How long a licensed Mac keeps working without reaching Polar.
    static let offlineGraceDays = 14
    static let fullPrice = 39
    static let trialPrice = 29
    private static let inactiveKeyMessage = "Your licence key is no longer valid. If you think this is a mistake, contact support."

    struct State: Codable, Equatable {
        var installID: String
        var trialStartedAt: Date
        /// Set by the checkout server the first time it sees this install ID; wins over the local clock.
        var trialEndsAt: Date?
        /// Older Keychain records and checkout servers have a seven-day end date with no duration field.
        var serverTrialDays: Int?
        var key: String?
        var activationID: String?
        var purchasedAt: Date?
        var email: String?
        var name: String?
        var activationLimit: Int?
        var lastValidatedAt: Date?
    }

    enum Status: Equatable {
        case loading
        case trial(daysLeft: Int)
        case trialEnded
        case licensed
        /// Licensed, but Polar couldn't be reached for `offlineGraceDays`. The key and activation are
        /// kept, so the next successful check restores the licence without using another Mac slot.
        case checkOverdue
    }

    @Published private(set) var state: State?
    @Published private(set) var busy = false
    @Published var message: String?

    private let config = Config()
    private var started = false

    var status: Status {
        guard let state else { return .loading }
        if state.key != nil, Date.now.timeIntervalSince(state.lastValidatedAt ?? .distantPast)
            > Double(Self.offlineGraceDays) * 86_400 {
            return .checkOverdue
        }
        if state.key != nil { return .licensed }
        let remaining = Self.trialEnd(state).timeIntervalSinceNow
        return remaining > 0 ? .trial(daysLeft: Int(ceil(remaining / Self.secondsPerDay))) : .trialEnded
    }

    var isLicensed: Bool {
        if case .licensed = status { return true }
        return false
    }

    /// After the trial an unlicensed copy is unusable until a key is activated. A copy with a key is
    /// never locked here: offline owners keep working, and a revoked key is cleared by `validate`.
    var isLocked: Bool { status == .trialEnded }

    var price: Int {
        if case .trial = status { return Self.trialPrice }
        return Self.fullPrice
    }

    /// Loads or creates the Keychain record, asks the server for the trial end, then checks the key
    /// with Polar when the last check is a day old, and again every hour while the app runs (so a
    /// refund is noticed and a failed check is retried). Safe to call from several views.
    func start() async {
        guard !started else { return }
        started = true
        do {
            if let saved = try await IntegrationKeychain.license.loadInBackground(),
               let decoded = try? Self.decoder.decode(State.self, from: Data(saved.utf8)) {
                state = decoded
            } else {
                let fresh = State(installID: UUID().uuidString.lowercased(), trialStartedAt: .now)
                state = fresh
                save()
            }
        } catch {
            message = error.localizedDescription
            state = State(installID: UUID().uuidString.lowercased(), trialStartedAt: .now)
        }
        writeStamp()
        await syncTrialIfNeeded()
        await validateIfDue()
        // `status` depends on the clock, so republish it for a trial that ends while the app runs.
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                self.objectWillChange.send()
            }
        }
        Task { [weak self] in
            while true {
                try? await Task.sleep(for: .seconds(3600))
                guard let self else { return }
                await self.syncTrialIfNeeded()
                await self.validateIfDue()
            }
        }
    }

    private func validateIfDue() async {
        guard state?.key != nil else { return }
        if let last = state?.lastValidatedAt, Date.now.timeIntervalSince(last) < 86_400 { return }
        await validate()
    }

    // MARK: Buying

    /// Opens a Polar checkout at the right price: the server attaches the trial discount while the
    /// trial lasts. Without a checkout server it falls back to the plain checkout link.
    func buy() async {
        guard let state else { return }
        busy = true
        defer { busy = false }
        do {
            guard let server = config.checkoutServer else {
                if let link = config.checkoutLink { NSWorkspace.shared.open(link) }
                else { message = "This build has no checkout address." }
                return
            }
            let reply = try await post(server.appending(path: "checkout"), ["install_id": state.installID])
            guard let address = reply["url"] as? String, let url = URL(string: address) else {
                throw LicenseError("The checkout server sent no checkout address.")
            }
            NSWorkspace.shared.open(url)
        } catch {
            message = error.localizedDescription
        }
    }

    private func syncTrialIfNeeded() async {
        guard state?.trialEndsAt == nil || state?.serverTrialDays != Self.trialDays else { return }
        guard let server = config.checkoutServer, let id = state?.installID else { return }
        guard let reply = try? await post(server.appending(path: "trial"), ["install_id": id]),
              let end = (reply["trial_ends_at"] as? String).flatMap(Self.date) else { return }
        state?.trialEndsAt = end
        state?.serverTrialDays = reply["trial_days"] as? Int ?? Self.legacyTrialDays
        save()
    }

    static func trialEnd(_ state: State) -> Date {
        if let serverEnd = state.trialEndsAt {
            let days = Self.trialDays - (state.serverTrialDays ?? Self.legacyTrialDays)
            return serverEnd.addingTimeInterval(Double(days) * Self.secondsPerDay)
        }
        return state.trialStartedAt.addingTimeInterval(Double(Self.trialDays) * Self.secondsPerDay)
    }

    // MARK: Licence key

    func activate(_ typed: String) async {
        let key = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, let organization = config.organizationID, state != nil else {
            message = config.organizationID == nil ? "This build has no Polar organization set." : nil
            return
        }
        busy = true
        defer { busy = false }
        do {
            let reply = try await post(config.polarAPI.appending(path: "v1/customer-portal/license-keys/activate"), [
                "key": key,
                "organization_id": organization,
                "label": Host.current().localizedName ?? "Mac",
                "meta": ["install_id": state?.installID ?? ""],
            ])
            guard let activation = reply["id"] as? String,
                  let license = reply["license_key"] as? [String: Any] else {
                throw LicenseError("Polar's reply had no activation.")
            }
            // A different key replaces the old one: free the old key's slot for this Mac first.
            if let old = state?.key, old != key { await releaseActivation() }
            state?.key = key
            state?.activationID = activation
            apply(license)
            message = nil
        } catch let error as LicenseError where error.status == 403
            && error.errorDescription?.localizedCaseInsensitiveContains("activation limit already reached") == true {
            message = "This key is already active on \(Self.activationLimitText(nil)). Deactivate it on the other Mac first, or contact support."
        } catch let error as LicenseError where error.status == 403
            && error.errorDescription?.localizedCaseInsensitiveContains("license key is no longer active") == true {
            message = Self.inactiveKeyMessage
        } catch let error as LicenseError where error.status == 404 {
            message = "Polar doesn't know this key. Check that you pasted all of it."
        } catch {
            message = error.localizedDescription
        }
    }

    /// Checks the key with Polar. A revoked or refunded key comes back as 404 and is removed. Without
    /// a connection nothing is removed; after `offlineGraceDays` the status becomes `.checkOverdue`.
    func validate() async {
        guard let state, let key = state.key, let organization = config.organizationID else { return }
        var body: [String: Any] = ["key": key, "organization_id": organization]
        if let activation = state.activationID { body["activation_id"] = activation }
        do {
            let reply = try await post(config.polarAPI.appending(path: "v1/customer-portal/license-keys/validate"), body)
            apply(reply)
        } catch let error as LicenseError where error.status == 404 {
            clearKey()
            message = Self.inactiveKeyMessage
        } catch {
            if status == .checkOverdue {
                message = "Daylanes couldn't check your licence for \(Self.offlineGraceDays) days. Connect to the internet and choose Check Again."
            }
        }
    }

    /// Frees this Mac's activation so the key can be used on another one.
    func deactivate() async {
        busy = true
        defer { busy = false }
        if await releaseActivation() {
            message = nil
            clearKey()
        }
    }

    /// Asks Polar to release this Mac's activation of the stored key. Returns false (with a message)
    /// if the release couldn't be confirmed, so the caller keeps the credentials.
    @discardableResult
    private func releaseActivation() async -> Bool {
        guard let state, let key = state.key, let organization = config.organizationID,
              let activation = state.activationID else { return true }
        do {
            _ = try await post(config.polarAPI.appending(path: "v1/customer-portal/license-keys/deactivate"), [
                "key": key, "organization_id": organization, "activation_id": activation,
            ])
        } catch let error as LicenseError where error.status == 404 {
            // Already gone on Polar's side.
        } catch let error as LicenseError where error.status == 429 {
            let retry = error.retryAfter.map { "Try again in \($0) seconds." } ?? "Try again shortly."
            message = "Polar is temporarily limiting licence requests. \(retry)"
            return false
        } catch {
            message = error.localizedDescription
            return false
        }
        return true
    }

    private func apply(_ license: [String: Any]) {
        if let created = (license["created_at"] as? String).flatMap(Self.date) { state?.purchasedAt = created }
        if let customer = license["customer"] as? [String: Any] {
            state?.email = customer["email"] as? String
            state?.name = customer["name"] as? String
        }
        state?.activationLimit = license["limit_activations"] as? Int
        state?.lastValidatedAt = .now
        save()
    }

    private func clearKey() {
        state?.key = nil
        state?.activationID = nil
        state?.purchasedAt = nil
        state?.email = nil
        state?.name = nil
        state?.activationLimit = nil
        state?.lastValidatedAt = nil
        save()
    }

    private func save() {
        guard let state, let data = try? Self.encoder.encode(state) else { return }
        do { try IntegrationKeychain.license.save(String(decoding: data, as: UTF8.self)) }
        catch { message = error.localizedDescription }
        writeStamp()
    }

    /// Tells the MCP server, `tracker call` and `tracker diary` whether they may run (core/LicenceStamp.swift).
    /// Any key counts as licensed, like the app's own lock: an offline copy is not locked.
    private func writeStamp() {
        guard let state else { return }
        try? LicenceStamp.write(.init(licensed: state.key != nil, trialEndsAt: Self.trialEnd(state)))
    }

    static func activationLimitText(_ limit: Int?) -> String {
        let count = limit ?? 2
        return count == 1 ? "1 Mac" : "\(count) Macs"
    }

    // MARK: Network

    struct LicenseError: LocalizedError {
        let errorDescription: String?
        let status: Int?
        let retryAfter: Int?

        init(_ message: String, status: Int? = nil, retryAfter: Int? = nil) {
            errorDescription = message
            self.status = status
            self.retryAfter = retryAfter
        }
    }

    private func post(_ url: URL, _ body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (200..<300).contains(status) else {
            let detail = (object["detail"] as? String) ?? (object["error"] as? String) ?? "HTTP \(status)"
            let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw LicenseError(detail, status: status, retryAfter: retryAfter)
        }
        return object
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    /// Polar sends dates like 2026-11-21T10:00:00.123456Z or with +00:00; drop the fraction before parsing.
    nonisolated static func date(_ text: String) -> Date? {
        let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }

    private struct Config {
        let polarAPI: URL
        let organizationID: String?
        let checkoutServer: URL?
        let checkoutLink: URL?

        init(bundle: Bundle = .main) {
            func value(_ key: String) -> String? {
                (bundle.object(forInfoDictionaryKey: key) as? String)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .flatMap { $0.isEmpty ? nil : $0 }
            }
            polarAPI = value("TrackerPolarAPI").flatMap(URL.init(string:)) ?? URL(string: "https://api.polar.sh")!
            organizationID = value("TrackerPolarOrganizationID")
            checkoutServer = value("TrackerCheckoutServer").flatMap(URL.init(string:))
            checkoutLink = value("TrackerCheckoutLink").flatMap(URL.init(string:))
        }
    }
}
