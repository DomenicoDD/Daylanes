import Foundation

/// An error the engine reports to the caller, worded like the Python engine's messages.
enum EngineError: Error, LocalizedError, CustomStringConvertible {
    /// A bad argument or a rule the ledger enforces (Python's ValueError).
    case invalid(String)
    /// A name or id that doesn't exist.
    case notFound(String)
    /// The data changed since the caller read it.
    case conflict(String)
    /// The operation isn't available in the Swift engine yet.
    case unsupported(String)

    var message: String {
        switch self {
        case let .invalid(text), let .notFound(text), let .conflict(text), let .unsupported(text): text
        }
    }
    var description: String { message }
    var errorDescription: String? { message }

    /// The error code from the API plan (docs/MCP_API_PLAN.md section 7).
    var code: String {
        switch self {
        case .invalid: "invalid_argument"
        case .notFound: "not_found"
        case .conflict: "conflict"
        case .unsupported: "internal"
        }
    }
}

enum Values {
    /// A trimmed, nonempty string, or an error naming the field (Python's `store.required`).
    static func required(_ value: String?, _ label: String) throws -> String {
        let trimmed = value?.pythonStripped ?? ""
        guard !trimmed.isEmpty else { throw EngineError.invalid("\(label) must be a nonempty string") }
        return trimmed
    }

    // MARK: Decimals

    private static let decimalPattern = try! NSRegularExpression(pattern: #"^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$"#)

    /// Parses a decimal string the way Python's `Decimal(str(value))` does (finite values only).
    static func decimal(_ text: String) -> Decimal? {
        let trimmed = text.pythonStripped.replacingOccurrences(of: "_", with: "")
        let range = NSRange(trimmed.startIndex..., in: trimmed)
        guard decimalPattern.firstMatch(in: trimmed, range: range) != nil else { return nil }
        guard let value = Decimal(string: trimmed, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN else { return nil }
        return value
    }

    /// Nonnegative money with at most two decimals, in cents (Python's `store.cents`).
    static func cents(_ text: String) throws -> Int {
        let failure = EngineError.invalid("Enter a nonnegative amount with at most two decimal places")
        guard let amount = decimal(text) else { throw failure }
        let scaled = amount * 100
        guard scaled == scaled.roundedTo(0), scaled >= 0, scaled <= 1_000_000_000_000 else { throw failure }
        return NSDecimalNumber(decimal: scaled).intValue
    }

    /// Minutes as milliseconds, rounded half up, between one millisecond and a day.
    static func durationMillis(_ text: String) throws -> Int {
        let failure = EngineError.invalid("Time must be between one millisecond and 24 hours")
        guard let amount = decimal(text), amount > 0, amount <= 1440 else { throw failure }
        let millis = (amount * 60000).roundedTo(0, .plain)
        let value = NSDecimalNumber(decimal: millis).intValue
        guard value > 0 else { throw failure }
        return value
    }

    /// Cents as a decimal string with two places ("12.50", "-0.75").
    static func money(_ cents: Int) -> String {
        let sign = cents < 0 ? "-" : ""
        let magnitude = cents.magnitude
        return "\(sign)\(magnitude / 100).\(String(format: "%02d", Int(magnitude % 100)))"
    }

    /// Milliseconds as hours with four places, rounded half to even (Python's `store.hours`).
    static func hours(_ millis: Int) -> String {
        fixed(Decimal(millis) / 3_600_000, places: 4)
    }

    /// A decimal with a fixed number of places, rounded half to even like Python's `format(d, ".Nf")`.
    static func fixed(_ value: Decimal, places: Int) -> String {
        let rounded = value.roundedTo(places, .bankers)
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.minimumFractionDigits = places
        formatter.maximumFractionDigits = places
        formatter.minimumIntegerDigits = 1
        return formatter.string(from: NSDecimalNumber(decimal: rounded)) ?? "\(rounded)"
    }

    // MARK: Paths

    /// The ledger path: `TRACKER_DB`, or ~/.local/share/tracker/ledger.sqlite3.
    static func databasePath(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        let fallback = NSHomeDirectory() + "/.local/share/tracker/ledger.sqlite3"
        let value = environment["TRACKER_DB"].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
        return resolvedPath(value)
    }

    /// `Path(value).expanduser().resolve()` (Python 3.9, not strict): absolute, with symlinks resolved
    /// component by component, so a ".." after a symlink leaves the link's target; missing parts are kept.
    static func resolvedPath(_ value: String, base: String = FileManager.default.currentDirectoryPath) -> String {
        var path = value
        if path == "~" || path.hasPrefix("~/") {
            let home = ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? NSHomeDirectory()
            path = home + path.dropFirst()
        }
        if !path.hasPrefix("/") { path = base + "/" + path }
        var seen: [String: String?] = [:]
        // `current` is the resolved path so far, "" for the root.
        func walk(_ start: String, _ rest: String) -> String {
            var current = start
            for part in rest.split(separator: "/", omittingEmptySubsequences: true) {
                if part == "." { continue }
                if part == ".." {
                    current = current.lastIndex(of: "/").map { String(current[..<$0]) } ?? ""
                    continue
                }
                let next = current + "/" + part
                if let known = seen[next] {
                    current = known ?? next  // nil: a symlink loop, kept as written
                    continue
                }
                var info = stat()
                guard lstat(next, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK else {
                    current = next
                    continue
                }
                var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
                let length = readlink(next, &buffer, Int(PATH_MAX))
                guard length >= 0 else { current = next; continue }
                let target = String(decoding: buffer[..<length].map { UInt8(bitPattern: $0) }, as: UTF8.self)
                seen[next] = .some(nil)
                current = walk(target.hasPrefix("/") ? "" : current, target)
                seen[next] = .some(current)
            }
            return current
        }
        let resolved = walk("", path)
        return resolved.isEmpty ? "/" : resolved
    }

    static func folderPath(_ value: String?) throws -> String {
        resolvedPath(try required(value, "Folder"))
    }

    // MARK: Time

    static func zone(_ name: String) throws -> TimeZone {
        guard !name.isEmpty, let zone = TimeZone(identifier: name) else {
            throw EngineError.invalid("Unknown time zone: \(name)")
        }
        return zone
    }

    /// A log's timestamp: Unix seconds (int or float) or an ISO string, naive ones in UTC (Python's `store.parse_at`).
    static func parseAt(_ value: JSON, zone: TimeZone = TimeZone(secondsFromGMT: 0)!) -> Int? {
        switch value {
        case let .int(seconds):
            let (stamp, overflow) = seconds.multipliedReportingOverflow(by: 1000)
            guard !overflow, (-62_135_596_800_000...253_402_300_799_999).contains(stamp) else { return nil }
            return Int(stamp)
        case let .double(seconds):
            let stamp = seconds * 1000
            guard stamp.isFinite, (-62_135_596_800_000...253_402_300_799_999).contains(stamp) else { return nil }
            return Int(stamp)
        case let .string(text):
            return parseAt(text, zone: zone)
        default:
            return nil
        }
    }

    static func nowMillis() -> Int { Int((Date().timeIntervalSince1970 * 1000).rounded(.down)) }

    private static let isoPattern = try! NSRegularExpression(pattern:
        #"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2})(?::(\d{2})(?::(\d{2})(?:\.(\d{3}|\d{6}))?)?)?)?(Z|[+-]\d{2}:\d{2}(?::\d{2})?)?$"#)

    /// An ISO date or timestamp as epoch milliseconds; a value without an offset is in `zone`.
    /// Matches Python 3.9's `datetime.fromisoformat` (plus a trailing Z), which the engine targets.
    static func parseAt(_ text: String, zone: TimeZone) -> Int? {
        let range = NSRange(text.startIndex..., in: text)
        guard let match = isoPattern.firstMatch(in: text, range: range) else { return nil }
        func group(_ index: Int) -> String? {
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
        if group(8) != nil, group(4) == nil { return nil }
        var parts = DateComponents()
        parts.year = Int(group(1)!)
        parts.month = Int(group(2)!)
        parts.day = Int(group(3)!)
        parts.hour = Int(group(4) ?? "0")
        parts.minute = Int(group(5) ?? "0")
        parts.second = Int(group(6) ?? "0")
        guard let month = parts.month, (1...12).contains(month), let day = parts.day, day >= 1,
              let hour = parts.hour, hour < 24, let minute = parts.minute, minute < 60,
              let second = parts.second, second < 60 else { return nil }
        // Fixed offsets are applied by hand: TimeZone(secondsFromGMT:) only covers ±18 hours, Python ±24.
        var calendar = Calendar(identifier: .gregorian)
        var offsetSeconds = 0
        if let offset = group(8) {
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            if offset != "Z" {
                let sign = offset.hasPrefix("-") ? -1 : 1
                let fields = offset.dropFirst().split(separator: ":").compactMap { Int($0) }
                guard fields[0] < 24, fields[1] < 60 else { return nil }
                offsetSeconds = sign * (fields[0] * 3600 + fields[1] * 60 + (fields.count > 2 ? fields[2] : 0))
            }
        } else {
            calendar.timeZone = zone
        }
        guard parts.isValidDate(in: calendar), let local = calendar.date(from: parts) else { return nil }
        let date = local.addingTimeInterval(TimeInterval(-offsetSeconds))
        var micros = 0
        if let fraction = group(7) {
            micros = Int(fraction.padding(toLength: 6, withPad: "0", startingAt: 0)) ?? 0
        }
        let seconds = Int(date.timeIntervalSince1970.rounded())
        // Python: int(dt.timestamp() * 1000), where timestamp() divides whole microseconds by 10**6.
        guard (-62_135_596_800...253_402_300_799).contains(seconds) else { return nil }
        let timestamp = Double(seconds * 1_000_000 + micros) / 1_000_000
        return Int(timestamp * 1000)
    }
}

extension String {
    /// Python's `str.strip()` with no arguments: removes Unicode whitespace at both ends.
    var pythonStripped: String {
        var scalars = Substring(self).unicodeScalars
        while let first = scalars.first, first.properties.isWhitespace || (0x1C...0x1F).contains(first.value) {
            scalars.removeFirst()
        }
        while let last = scalars.last, last.properties.isWhitespace || (0x1C...0x1F).contains(last.value) {
            scalars.removeLast()
        }
        return String(scalars)
    }
}

extension Decimal {
    func roundedTo(_ places: Int, _ mode: NSDecimalNumber.RoundingMode = .plain) -> Decimal {
        var source = self
        var result = Decimal()
        NSDecimalRound(&result, &source, places, mode)
        return result
    }
}
