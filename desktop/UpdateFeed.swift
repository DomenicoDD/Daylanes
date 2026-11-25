import Foundation

/// The small JSON file that says which Daylanes version is newest (docs/UPDATES.md).
///
/// ```json
/// {"version": "0.5.0", "released": "2026-12-01", "notes": "What changed, in a sentence or two.",
///  "page": "https://daylanes.app/download",
///  "downloads": {"arm64": "https://downloads.daylanes.app/Daylanes-0.5.0-arm64.dmg",
///                "x86_64": "https://downloads.daylanes.app/Daylanes-0.5.0-x86_64.dmg"}}
/// ```
struct UpdateFeed: Decodable, Equatable {
    var version: String
    var released: String?
    var notes: String?
    var page: URL?
    var downloads: [String: URL]?

    static let address = URL(string: "https://daylanes.app/updates/latest.json")!

    /// The installer for this Mac's architecture, or the download page when there isn't one.
    func download(for architecture: String) -> URL? {
        downloads?[architecture] ?? page
    }

    /// True when `version` is newer than `installed`. Versions compare number by number, so 0.10.0 is
    /// newer than 0.9.9 and 1.0 equals 1.0.0. Anything after a hyphen (0.5.0-beta) is ignored.
    static func isNewer(_ version: String, than installed: String) -> Bool {
        let new = numbers(version), old = numbers(installed)
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0
            let b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    private static func numbers(_ version: String) -> [Int] {
        let core = version.trimmingCharacters(in: .whitespaces)
            .drop(while: { $0 == "v" || $0 == "V" })
            .split(separator: "-", maxSplits: 1).first ?? ""
        return core.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    static var currentArchitecture: String {
        #if arch(arm64)
        "arm64"
        #else
        "x86_64"
        #endif
    }
}
