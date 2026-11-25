import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum IntegrationKeychain: String {
    case openRouter = "openrouter"
    case toggl = "toggl"
    #if TRACKER_GOOGLE_CALENDAR
    case googleCalendar = "google-calendar"
    case googleCalendarClient = "google-calendar-client"
    #endif
    case fal, higgsfield, replicate, ollama
    #if TRACKER_PAYMENTS
    /// Trial start, install ID and licence key (JSON). Kept in Keychain so reinstalling does not reset the trial.
    case license = "license"
    #endif

    init(provider: AIProvider) {
        switch provider {
        case .openrouter: self = .openRouter
        case .fal: self = .fal
        case .higgsfield: self = .higgsfield
        case .replicate: self = .replicate
        case .ollama: self = .ollama
        }
    }

    private var account: String {
        switch self {
        case .openRouter: "OpenRouter management key"
        case .toggl: "Toggl Track API token"
        #if TRACKER_GOOGLE_CALENDAR
        case .googleCalendar: "Google Calendar authorization"
        case .googleCalendarClient: "Google Calendar Desktop OAuth client"
        #endif
        case .fal: "fal billing key"
        case .higgsfield: "Higgsfield API credential"
        case .replicate: "Replicate API token"
        case .ollama: "Ollama Cloud API key"
        #if TRACKER_PAYMENTS
        case .license: "Tracker licence"  // Keychain lookup key, keep stable across renames
        #endif
        }
    }

    private func item(ledger: String?) -> [String: Any] {
        let scope = ledger.map { SHA256.hash(data: Data($0.utf8)).map { String(format: "%02x", $0) }.joined() }
        return [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.domenicodidonna.tracker." + rawValue,
         kSecAttrAccount as String: scope.map { account + " " + $0 } ?? account,
         kSecAttrSynchronizable as String: false]
    }

    func load(ledger: String? = nil) throws -> String? {
        var query = item(ledger: ledger)
        query[kSecReturnData as String] = true
        var value: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &value)
        if status == errSecItemNotFound { return nil }
        try check(status)
        return (value as? Data).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Finds a legacy token by its metadata without requesting its secret or showing a prompt.
    func hasSavedItem() -> Bool {
        var query = item(ledger: nil)
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        query[kSecReturnAttributes as String] = true
        var attributes: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &attributes) == errSecSuccess
    }

    /// A Keychain access prompt can block until someone answers it, and must not freeze the window.
    func loadInBackground() async throws -> String? {
        let item = self
        return try await Task.detached(priority: .userInitiated) { try item.load() }.value
    }

    func save(_ key: String, ledger: String? = nil) throws {
        let item = item(ledger: ledger)
        let secret = Data(key.utf8)
        let attributes = [kSecValueData as String: secret]
        let status = SecItemUpdate(item as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var entry = item
            entry[kSecValueData as String] = secret
            try check(SecItemAdd(entry as CFDictionary, nil))
        } else {
            try check(status)
        }
    }

    func remove(ledger: String? = nil) throws {
        let status = SecItemDelete(item(ledger: ledger) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }

    private func check(_ status: OSStatus) throws {
        if status != errSecSuccess {
            let reason = SecCopyErrorMessageString(status, nil) as String? ?? "Error \(status)"
            throw Ledger.CommandError(message: "Could not access the \(account) in macOS Keychain. \(reason)")
        }
    }
}
