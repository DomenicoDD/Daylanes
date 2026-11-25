import AppKit
import Foundation

struct InstalledMacApp: Identifiable, Sendable {
    let id: String
    let name: String
    let url: URL

    init?(url: URL, runningName: String? = nil) {
        guard url.pathExtension.lowercased() == "app" else { return nil }
        let url = url.resolvingSymlinksInPath()
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.isEmpty,
              id != "com.domenicodidonna.tracker", id != Bundle.main.bundleIdentifier,
              bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool != true else { return nil }
        self.id = id
        self.url = url
        let names = [runningName, bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
                     bundle.object(forInfoDictionaryKey: "CFBundleName") as? String]
        self.name = names.compactMap { $0?.pythonStripped }.first { !$0.isEmpty }
            ?? url.deletingPathExtension().lastPathComponent
    }

    func matches(_ query: String) -> Bool {
        query.isEmpty || name.localizedStandardContains(query) || id.localizedStandardContains(query)
    }

    static func catalog() -> [Self] {
        let running = NSWorkspace.shared.runningApplications.compactMap { app -> Self? in
            guard app.activationPolicy != .prohibited, let url = app.bundleURL else { return nil }
            return Self(url: url, runningName: app.localizedName)
        }
        let files = FileManager.default
        let roots = files.urls(for: .applicationDirectory, in: [.userDomainMask, .localDomainMask, .systemDomainMask])
        let installed = roots.flatMap { root -> [Self] in
            guard let contents = files.enumerator(at: root, includingPropertiesForKeys: nil,
                                                  options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
            return contents.compactMap { ($0 as? URL).flatMap { Self(url: $0) } }
        }
        let unique = Dictionary((running + installed).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return unique.values.sorted {
            let comparison = $0.name.localizedStandardCompare($1.name)
            return comparison == .orderedSame ? $0.id < $1.id : comparison == .orderedAscending
        }
    }
}
