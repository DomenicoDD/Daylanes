import Foundation

/// Installs the browser helper and registers it with every Chromium browser on this Mac, from this app bundle, so the extension
/// works after a build without running register.py.
enum ChromeBridge {
    enum Setup: Equatable, Sendable {
        /// The browsers the helper is registered with.
        case installed([String])
        case noBrowser
        case notBundled
        case failed(String)
    }

    private static var support: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    }

    static var helper: URL { support.appendingPathComponent("Tracker/ChromeBridge/TrackerChromeHost") }
    /// A copy of the unpacked extension at a path that survives moving or deleting the checkout.
    static var extensionFolder: URL { support.appendingPathComponent("Tracker/Chrome Extension", isDirectory: true) }

    static func install() async -> Setup {
        await Task.detached(priority: .utility) { installNow() }.value
    }

    static func installNow(bundle: Bundle = .main) -> Setup {
        let files = FileManager.default
        let home = files.homeDirectoryForCurrentUser
        let browsers = TrackerChromeWire.browsers.filter {
            files.fileExists(atPath: support.appendingPathComponent($0.folder).path)
        }
        guard !browsers.isEmpty else { return .noBrowser }
        guard let source = bundle.url(forAuxiliaryExecutable: "TrackerChromeHost") else { return .notBundled }
        do {
            // Chrome cannot launch a helper inside protected folders such as Documents, so keep a private copy.
            try files.createDirectory(at: helper.deletingLastPathComponent(), withIntermediateDirectories: true,
                                      attributes: [.posixPermissions: 0o700])
            if files.contentsEqual(atPath: source.path, andPath: helper.path) == false {
                let staged = helper.appendingPathExtension("new")
                try? files.removeItem(at: staged)
                try files.copyItem(at: source, to: staged)
                try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: staged.path)
                if files.fileExists(atPath: helper.path) {
                    // A running helper keeps its old file open, and the next Chrome launch uses the new one.
                    _ = try files.replaceItemAt(helper, withItemAt: staged)
                } else {
                    try files.moveItem(at: staged, to: helper)
                }
            }
            if let bundled = bundle.resourceURL?.appendingPathComponent("chrome-extension", isDirectory: true),
               files.fileExists(atPath: bundled.appendingPathComponent("manifest.json").path) {
                try sync(bundled, to: extensionFolder)
            }
            let registration: [String: Any] = [
                "name": TrackerChromeWire.hostName,
                "description": "Tracker local Chrome tab bridge",
                "path": helper.path,
                "type": "stdio",
                "allowed_origins": TrackerChromeWire.allowedOrigins,
            ]
            let data = try JSONSerialization.data(withJSONObject: registration, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
            for browser in browsers {
                let manifest = TrackerChromeWire.manifest(for: browser, home: home)
                guard (try? Data(contentsOf: manifest)) != data else { continue }
                try files.createDirectory(at: manifest.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: manifest, options: .atomic)
            }
            return .installed(browsers.map(\.name))
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    /// Replaces changed files only, so Chrome keeps the folder it loaded and picks up edits on reload.
    private static func sync(_ source: URL, to target: URL) throws {
        let files = FileManager.default
        try files.createDirectory(at: target, withIntermediateDirectories: true)
        let wanted = try files.contentsOfDirectory(atPath: source.path)
        for name in try files.contentsOfDirectory(atPath: target.path) where !wanted.contains(name) {
            try files.removeItem(at: target.appendingPathComponent(name))
        }
        for name in wanted {
            let from = source.appendingPathComponent(name), to = target.appendingPathComponent(name)
            guard !files.contentsEqual(atPath: from.path, andPath: to.path) else { continue }
            try? files.removeItem(at: to)
            try files.copyItem(at: from, to: to)
        }
    }
}
