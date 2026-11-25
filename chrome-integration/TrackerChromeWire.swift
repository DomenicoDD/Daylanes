import Darwin
import Foundation

enum TrackerChromeWire {
    static let hostName = "com.domenicodidonna.tracker.chrome"
    /// Fixed by the public key in the extension manifest, so it is the same in every profile and folder.
    static let extensionID = "lkckmlojgpfflmkhkaapcijpjehdmobo"
    /// The Chrome Web Store assigns its own ID on first upload. Add it here, and put the store's
    /// public key in the manifest so unpacked builds share it.
    static let storeExtensionIDs: [String] = []
    static var allowedOrigins: [String] {
        ([extensionID] + storeExtensionIDs).map { "chrome-extension://\($0)/" }
    }

    struct Browser: Sendable {
        let name: String
        let bundleIDs: [String]
        /// The browser's data folder under ~/Library/Application Support.
        let folder: String
    }

    /// Chromium browsers that install Chrome Web Store extensions and support native messaging.
    static let browsers = [
        Browser(name: "Google Chrome", bundleIDs: ["com.google.Chrome"], folder: "Google/Chrome"),
        Browser(name: "Chrome Beta", bundleIDs: ["com.google.Chrome.beta"], folder: "Google/Chrome Beta"),
        Browser(name: "Chrome Dev", bundleIDs: ["com.google.Chrome.dev"], folder: "Google/Chrome Dev"),
        Browser(name: "Chrome Canary", bundleIDs: ["com.google.Chrome.canary"], folder: "Google/Chrome Canary"),
        Browser(name: "Microsoft Edge", bundleIDs: ["com.microsoft.edgemac"], folder: "Microsoft Edge"),
        Browser(name: "Edge Beta", bundleIDs: ["com.microsoft.edgemac.Beta"], folder: "Microsoft Edge Beta"),
        Browser(name: "Brave", bundleIDs: ["com.brave.Browser"], folder: "BraveSoftware/Brave-Browser"),
        Browser(name: "Brave Beta", bundleIDs: ["com.brave.Browser.beta"], folder: "BraveSoftware/Brave-Browser-Beta"),
        Browser(name: "Arc", bundleIDs: ["company.thebrowser.Browser"], folder: "Arc/User Data"),
        Browser(name: "Vivaldi", bundleIDs: ["com.vivaldi.Vivaldi"], folder: "Vivaldi"),
        Browser(name: "Chromium", bundleIDs: ["org.chromium.Chromium"], folder: "Chromium"),
    ]

    static func isBrowser(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return browsers.contains { $0.bundleIDs.contains(bundleID) }
    }

    static func manifest(for browser: Browser, home: URL) -> URL {
        home.appendingPathComponent("Library/Application Support/\(browser.folder)/NativeMessagingHosts/\(hostName).json")
    }
    static let maxFrame = 4096

    struct Request: Codable {
        let version: Int
        let type: String
        let id: UUID

        init() {
            version = 1
            type = "snapshot"
            id = UUID()
        }

        var valid: Bool { version == 1 && type == "snapshot" }
    }

    struct Reply: Codable, Sendable {
        enum Status: String, Codable, Sendable { case tab, noTab = "no_tab" }

        let version: Int
        let id: UUID
        let status: Status
        let url: String?
        let profile: String?

        func valid(for request: Request) -> Bool {
            guard version == 1, id == request.id else { return false }
            if status == .noTab { return url == nil && profile == nil }
            guard let url, url.utf8.count <= 2048,
                  url.rangeOfCharacter(from: .controlCharacters) == nil,
                  let address = URLComponents(string: url), address.string == url,
                  address.scheme == "http" || address.scheme == "https",
                  let host = address.host, !host.isEmpty, address.path.hasPrefix("/"),
                  !address.path.contains("@"),
                  address.user == nil, address.password == nil,
                  address.query == nil, address.fragment == nil else { return false }
            guard let profile else { return true }
            return profile.range(of: "\\A[a-zA-Z0-9 _-]{1,40}\\z", options: .regularExpression) != nil
        }
    }

    static func directory(create: Bool) -> URL? {
        let size = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, size) == size else { return nil }
        let path = buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        let url = URL(fileURLWithPath: path).appendingPathComponent("tracker-chrome", isDirectory: true)
        if create && mkdir(url.path, 0o700) != 0 && errno != EEXIST { return nil }
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_uid == geteuid(),
              info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700 else { return nil }
        return url
    }

    static func socketPath(_ url: URL) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        guard url.path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.copyBytes(from: url.path.utf8)
        }
        return address
    }

    static func withAddress<T>(_ address: inout sockaddr_un, _ operation: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                operation($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    static func localPeer(_ descriptor: Int32) -> Bool {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(descriptor, &uid, &gid) == 0 && uid == geteuid()
    }

    static func suppressBrokenPipe(_ descriptor: Int32) {
        var enabled: Int32 = 1
        _ = setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
    }

    static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    static func read<T: Decodable>(_ type: T.Type, from descriptor: Int32, by deadline: TimeInterval) -> T? {
        guard let sizeData = read(4, from: descriptor, by: deadline) else { return nil }
        let size = Int(sizeData.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) })
        guard (1...maxFrame).contains(size), let body = read(size, from: descriptor, by: deadline) else { return nil }
        return try? JSONDecoder().decode(type, from: body)
    }

    static func write<T: Encodable>(_ item: T, to descriptor: Int32, by deadline: TimeInterval) -> Bool {
        guard let body = try? JSONEncoder().encode(item), body.count <= maxFrame else { return false }
        var size = UInt32(body.count)
        var frame = withUnsafeBytes(of: &size) { Data($0) }
        frame.append(body)
        return frame.withUnsafeBytes { bytes in
            guard let start = bytes.baseAddress else { return false }
            var offset = 0
            while offset < bytes.count {
                guard ready(descriptor, for: Int16(POLLOUT), by: deadline) else { return false }
                let count = Darwin.write(descriptor, start.advanced(by: offset), bytes.count - offset)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    static func ready(_ descriptor: Int32, for event: Int16, by deadline: TimeInterval) -> Bool {
        var watched = pollfd(fd: descriptor, events: event, revents: 0)
        while now() < deadline {
            let result = poll(&watched, 1, Int32(ceil((deadline - now()) * 1000).clamped(to: 0...1000)))
            if result < 0 && errno == EINTR { continue }
            return result > 0 && watched.revents & event != 0
        }
        return false
    }

    private static func read(_ size: Int, from descriptor: Int32, by deadline: TimeInterval) -> Data? {
        var data = Data(count: size)
        let complete = data.withUnsafeMutableBytes { bytes in
            guard let start = bytes.baseAddress else { return false }
            var offset = 0
            while offset < size {
                guard ready(descriptor, for: Int16(POLLIN), by: deadline) else { return false }
                let count = Darwin.read(descriptor, start.advanced(by: offset), size - offset)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
        return complete ? data : nil
    }
}

private extension Double {
    func clamped(to limits: ClosedRange<Double>) -> Double {
        max(limits.lowerBound, min(limits.upperBound, self))
    }
}
