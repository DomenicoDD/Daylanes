import Foundation

@main
struct UpdateChecks {
    static func main() throws {
        precondition(UpdateFeed.isNewer("0.5.0", than: "0.4.1"))
        precondition(UpdateFeed.isNewer("0.10.0", than: "0.9.9"))
        precondition(UpdateFeed.isNewer("1.0.1", than: "1.0"))
        precondition(!UpdateFeed.isNewer("1.0", than: "1.0.0"))
        precondition(!UpdateFeed.isNewer("0.4.1", than: "0.4.1"))
        precondition(!UpdateFeed.isNewer("0.4.0", than: "0.4.1"))
        precondition(!UpdateFeed.isNewer("0.4.1-beta", than: "0.4.1"))
        precondition(UpdateFeed.isNewer("v0.5", than: "0.4.9"))

        let json = #"""
        {"version": "0.5.0", "released": "2026-12-01", "notes": "Faster timeline.",
         "page": "https://daylanes.app/download",
         "downloads": {"arm64": "https://downloads.daylanes.app/Daylanes-0.5.0-arm64.dmg"}}
        """#
        let feed = try JSONDecoder().decode(UpdateFeed.self, from: Data(json.utf8))
        precondition(feed.version == "0.5.0" && feed.notes == "Faster timeline.")
        precondition(feed.download(for: "arm64")?.lastPathComponent == "Daylanes-0.5.0-arm64.dmg")
        precondition(feed.download(for: "x86_64")?.absoluteString == "https://daylanes.app/download")

        let minimal = try JSONDecoder().decode(UpdateFeed.self, from: Data(#"{"version": "0.4.1"}"#.utf8))
        precondition(minimal.download(for: "arm64") == nil)
        print("UpdateChecks passed")
    }
}
