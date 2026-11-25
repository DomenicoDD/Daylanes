import Foundation

/// Profile names come from Chrome's local profile picker catalog. The directory ID survives a rename.
struct ChromeProfile: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let name: String
    private let windowNames: Set<String>

    private static let storagePrefix = "chrome:"
    private static let browserSuffix = " - Google Chrome"
    private static let profileSeparators = [" – ", " - ", " — "]
    private static let maximumSize = 32 * 1024 * 1024

    struct Catalog: Equatable, Sendable {
        let profiles: [ChromeProfile]
        let requiresImport: Bool

        func profile(forVerifiedWindowTitle title: String) -> ChromeProfile? {
            // Chrome omits the profile suffix when there is only one profile. An imported list can be stale.
            if !requiresImport, profiles.count == 1, title.hasSuffix(ChromeProfile.browserSuffix) {
                return profiles.first
            }
            return ChromeProfile.identify(windowTitle: title, in: profiles)
        }
    }

    static func validID(_ id: String) -> Bool {
        id == "Default" || id.range(of: #"\AProfile (?:0|[1-9][0-9]{0,9})\z"#, options: .regularExpression) != nil
    }

    // The legacy field stored only letters, numbers, spaces, hyphens and underscores.
    static func storedID(_ id: String) -> String { storagePrefix + id }

    static func id(fromStored value: String?) -> String? {
        guard let value, value.hasPrefix(storagePrefix) else { return nil }
        let id = String(value.dropFirst(storagePrefix.count))
        return validID(id) ? id : nil
    }

    static func catalog(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [Self] {
        discover(home: home).profiles
    }

    static func localState(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
    }

    static func discover(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Catalog {
        if let profiles = try? readLocalState(localState(home: home)) {
            return Catalog(profiles: profiles, requiresImport: false)
        }
        let saved = try? JSONDecoder().decode([Self].self, from: read(savedCatalog(home)))
        return Catalog(profiles: saved ?? [], requiresImport: true)
    }

    /// Retain the profiles needed for rule matching when macOS restricts direct access to Chrome's data.
    @discardableResult
    static func importCatalog(from url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> [Self] {
        guard url.lastPathComponent == "Local State" else {
            throw EngineError.invalid("Choose the Local State file in the Google Chrome folder.")
        }
        let profiles = try readLocalState(url)
        let destination = savedCatalog(home)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(profiles).write(to: destination, options: .atomic)
        return profiles
    }

    private static func savedCatalog(_ home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/Tracker/ChromeProfiles/catalog.json")
    }

    private static func read(_ url: URL) throws -> Data {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard let data = try file.read(upToCount: maximumSize + 1), data.count <= maximumSize else {
            throw EngineError.invalid("Couldn’t read the Chrome profile catalog.")
        }
        return data
    }

    private static func readLocalState(_ url: URL) throws -> [Self] {
        guard let profiles = try parseLocalState(read(url)) else {
            throw EngineError.invalid("Choose Chrome’s Local State file. It contains the profile list.")
        }
        return profiles
    }

    static func decodeCatalog(_ data: Data) -> [Self] { parseLocalState(data) ?? [] }

    private static func parseLocalState(_ data: Data) -> [Self]? {
        struct LocalState: Decodable {
            struct Entry: Decodable {
                let name: String?
                let enterprise_label: String?
                let gaia_given_name: String?
                let gaia_name: String?
                let is_ephemeral: Bool?
            }
            struct Profiles: Decodable { let info_cache: [String: Entry] }
            let profile: Profiles
        }
        guard let state = try? JSONDecoder().decode(LocalState.self, from: data) else { return nil }
        return state.profile.info_cache.compactMap { id, item -> Self? in
            guard validID(id), item.is_ephemeral != true else { return nil }
            let local = (item.enterprise_label?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
                ?? item.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let local, !local.isEmpty else { return nil }
            let account = [item.gaia_given_name, item.gaia_name].compactMap { $0 }
                .first { !$0.isEmpty }
            var names: Set<String> = [local]
            if let account {
                // Chrome's avatar name may be the local name, the account display name, or both.
                names.insert(account)
                names.insert("\(account) (\(local))")
            }
            return Self(id: id, name: local, windowNames: names)
        }.sorted { lhs, rhs in
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending : order == .orderedAscending
        }
    }

    /// Match the browser-added profile suffix of an accessibility window title only when it is unique.
    /// A title without a recognised Chrome suffix or a unique profile leaves the profile unresolved.
    static func identify(windowTitle: String, in catalog: [Self]) -> Self? {
        guard let browser = windowTitle.range(of: browserSuffix, options: .backwards) else { return nil }
        let suffix = windowTitle[browser.upperBound...]
        guard let separator = profileSeparators.first(where: { suffix.hasPrefix($0) }) else { return nil }
        let name = String(suffix.dropFirst(separator.count))
        let matches = catalog.filter { $0.windowNames.contains(name) }
        return matches.count == 1 ? matches.first : nil
    }

    var object: JSON { .object([("id", .string(id)), ("name", .string(name))]) }
}
