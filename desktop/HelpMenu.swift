import AppKit
import SwiftUI

/// Public pages on the Daylanes website. The app links to the website only, never straight to a
/// store: daylanes.app/chrome decides where to send people (the Chrome Web Store once the listing
/// is live, an install note until then), so the app never needs an update when that changes.
enum SiteLinks {
    static let website = URL(string: "https://daylanes.app")!
    static let chromeExtension = URL(string: "https://daylanes.app/chrome")!
}

/// Replaces the default Help menu, which only says help isn't available.
struct HelpMenuCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .help) {
            Button("Daylanes Website") { NSWorkspace.shared.open(SiteLinks.website) }
            Button("Get the Chrome Extension") { NSWorkspace.shared.open(SiteLinks.chromeExtension) }
        }
    }
}
