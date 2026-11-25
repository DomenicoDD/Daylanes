import Foundation

/// A JSON value that keeps object keys in order, so output matches the Python engine byte for byte.
enum JSON: Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([(String, JSON)])

    static func == (lhs: JSON, rhs: JSON) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): true
        case let (.bool(a), .bool(b)): a == b
        case let (.int(a), .int(b)): a == b
        case let (.double(a), .double(b)): a == b
        case let (.int(a), .double(b)), let (.double(b), .int(a)): Double(a) == b
        case let (.string(a), .string(b)): a == b
        case let (.array(a), .array(b)): a == b
        case let (.object(a), .object(b)):
            a.count == b.count && a.allSatisfy { key, value in b.first { $0.0 == key }?.1 == value }
        default: false
        }
    }

    // MARK: Building

    static func optional(_ value: String?) -> JSON { value.map { JSON.string($0) } ?? .null }
    static func optional(_ value: Int?) -> JSON { value.map { .int(Int64($0)) } ?? .null }
    static func strings(_ values: [String]) -> JSON { .array(values.map { JSON.string($0) }) }

    // MARK: Reading

    subscript(_ key: String) -> JSON {
        if case let .object(pairs) = self { return pairs.first { $0.0 == key }?.1 ?? .null }
        return .null
    }
    var isNull: Bool { self == .null }
    var stringValue: String? { if case let .string(value) = self { return value }; return nil }
    var boolValue: Bool? { if case let .bool(value) = self { return value }; return nil }
    var intValue: Int? {
        switch self {
        case let .int(value): Int(value)
        case let .double(value) where value == value.rounded() && abs(value) < 9e15: Int(value)
        default: nil
        }
    }
    var doubleValue: Double? {
        switch self {
        case let .int(value): Double(value)
        case let .double(value): value
        default: nil
        }
    }
    var arrayValue: [JSON]? { if case let .array(value) = self { return value }; return nil }
    var pairs: [(String, JSON)]? { if case let .object(value) = self { return value }; return nil }

    /// Adds or replaces a key, keeping the position of an existing one.
    mutating func set(_ key: String, _ value: JSON) {
        guard case var .object(pairs) = self else { return }
        if let index = pairs.firstIndex(where: { $0.0 == key }) {
            pairs[index].1 = value
        } else {
            pairs.append((key, value))
        }
        self = .object(pairs)
    }

    // MARK: Parsing

    /// Parses JSON text. Object keys keep the order they appear in.
    static func parse(_ data: Data) throws -> JSON { try parse(bytes: [UInt8](data)) }

    /// With `decimalFloats`, a number with a fraction or exponent comes back as `JSON.decimal(text)`
    /// holding the text as written (Python's `json.loads(..., parse_float=Decimal)`).
    static func parse(bytes: [UInt8], decimalFloats: Bool = false) throws -> JSON {
        var parser = JSONParser(bytes: bytes)
        parser.decimalFloats = decimalFloats
        let value = try parser.value()
        parser.skipSpace()
        guard parser.index == parser.bytes.count else { throw parser.failure("Extra data") }
        return value
    }

    static func parse(_ text: String) throws -> JSON { try parse(Data(text.utf8)) }

    /// The key of the one-entry object that stands for a decimal number read with `decimalFloats`.
    static let decimalKey = "\u{0}decimal"

    static func decimal(_ text: String) -> JSON { .object([(decimalKey, .string(text))]) }

    /// The text of a number read with `decimalFloats`, or nil for any other value.
    var decimalText: String? {
        guard case let .object(pairs) = self, pairs.count == 1, pairs[0].0 == JSON.decimalKey else { return nil }
        return pairs[0].1.stringValue
    }

    // MARK: Writing

    /// The same text as Python's `json.dumps(value, ensure_ascii=False, indent=2)`.
    /// With `indent: nil` and `ensureASCII: true` it is plain `json.dumps(value)`.
    func pythonText(indent: Int? = 2, ensureASCII: Bool = false) -> String {
        var out = ""
        write(into: &out, indent: indent, level: 0, ascii: ensureASCII)
        return out
    }

    private func write(into out: inout String, indent: Int?, level: Int, ascii: Bool) {
        switch self {
        case .null: out += "null"
        case let .bool(value): out += value ? "true" : "false"
        case let .int(value): out += String(value)
        case let .double(value): out += JSON.pythonFloat(value)
        case let .string(value): JSON.writeString(value, into: &out, ascii: ascii)
        case let .array(values):
            guard !values.isEmpty else { out += "[]"; return }
            out += "["
            for (offset, value) in values.enumerated() {
                if offset > 0 { out += indent == nil ? ", " : "," }
                JSON.newline(&out, indent, level + 1)
                value.write(into: &out, indent: indent, level: level + 1, ascii: ascii)
            }
            JSON.newline(&out, indent, level)
            out += "]"
        case let .object(pairs):
            guard !pairs.isEmpty else { out += "{}"; return }
            out += "{"
            for (offset, pair) in pairs.enumerated() {
                if offset > 0 { out += indent == nil ? ", " : "," }
                JSON.newline(&out, indent, level + 1)
                JSON.writeString(pair.0, into: &out, ascii: ascii)
                out += ": "
                pair.1.write(into: &out, indent: indent, level: level + 1, ascii: ascii)
            }
            JSON.newline(&out, indent, level)
            out += "}"
        }
    }

    private static func newline(_ out: inout String, _ indent: Int?, _ level: Int) {
        guard let indent else { return }
        out += "\n" + String(repeating: " ", count: indent * level)
    }

    private static func writeString(_ value: String, into out: inout String, ascii: Bool) {
        out += "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 || (ascii && scalar.value == 0x7F) {
                    out += String(format: "\\u%04x", scalar.value)
                } else if ascii && scalar.value > 0x7F {
                    for unit in String(scalar).utf16 { out += String(format: "\\u%04x", unit) }
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }

    /// Python's `repr(float)`: shortest round-trip digits, with ".0" on whole numbers.
    static func pythonFloat(_ value: Double) -> String {
        if value.isNaN { return "NaN" }
        if value.isInfinite { return value < 0 ? "-Infinity" : "Infinity" }
        var text = "\(value)"
        if let e = text.firstIndex(of: "e") {
            // Swift writes 1e-05 and 1e+16 like Python, but 1.5e-07 too; only the exponent sign needs care.
            let exponent = text[text.index(after: e)...]
            if !exponent.hasPrefix("-") && !exponent.hasPrefix("+") {
                text = String(text[..<e]) + "e+" + exponent
            }
        }
        return text
    }
}

private struct JSONParser {
    let bytes: [UInt8]
    var index = 0
    var decimalFloats = false

    init(bytes: [UInt8]) { self.bytes = bytes }

    func failure(_ message: String) -> Error {
        EngineError.invalid("Invalid JSON: \(message) at offset \(index)")
    }

    mutating func skipSpace() {
        while index < bytes.count, [0x20, 0x0A, 0x0D, 0x09].contains(bytes[index]) { index += 1 }
    }

    mutating func value() throws -> JSON {
        skipSpace()
        guard index < bytes.count else { throw failure("Expecting value") }
        switch bytes[index] {
        case UInt8(ascii: "{"): return try object()
        case UInt8(ascii: "["): return try array()
        case UInt8(ascii: "\""): return .string(try string())
        case UInt8(ascii: "t"): try literal("true"); return .bool(true)
        case UInt8(ascii: "f"): try literal("false"); return .bool(false)
        case UInt8(ascii: "n"): try literal("null"); return .null
        default: return try number()
        }
    }

    mutating func literal(_ word: String) throws {
        let expected = Array(word.utf8)
        guard index + expected.count <= bytes.count, Array(bytes[index..<index + expected.count]) == expected else {
            throw failure("Expecting value")
        }
        index += expected.count
    }

    mutating func object() throws -> JSON {
        index += 1
        var pairs: [(String, JSON)] = []
        skipSpace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
        while true {
            skipSpace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: "\"") else { throw failure("Expecting property name") }
            let key = try string()
            skipSpace()
            guard index < bytes.count, bytes[index] == UInt8(ascii: ":") else { throw failure("Expecting ':'") }
            index += 1
            let item = try value()
            if let existing = pairs.firstIndex(where: { $0.0 == key }) {
                pairs[existing].1 = item   // Python keeps the last value for a repeated key.
            } else {
                pairs.append((key, item))
            }
            skipSpace()
            guard index < bytes.count else { throw failure("Expecting ',' delimiter") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "}") { index += 1; return .object(pairs) }
            throw failure("Expecting ',' delimiter")
        }
    }

    mutating func array() throws -> JSON {
        index += 1
        var values: [JSON] = []
        skipSpace()
        if index < bytes.count, bytes[index] == UInt8(ascii: "]") { index += 1; return .array(values) }
        while true {
            values.append(try value())
            skipSpace()
            guard index < bytes.count else { throw failure("Expecting ',' delimiter") }
            if bytes[index] == UInt8(ascii: ",") { index += 1; continue }
            if bytes[index] == UInt8(ascii: "]") { index += 1; return .array(values) }
            throw failure("Expecting ',' delimiter")
        }
    }

    mutating func hex4() throws -> UInt32 {
        guard index + 4 <= bytes.count, let text = String(bytes: bytes[index..<index + 4], encoding: .ascii),
              let value = UInt32(text, radix: 16) else { throw failure("Invalid \\uXXXX escape") }
        index += 4
        return value
    }

    mutating func string() throws -> String {
        index += 1
        // One UTF-8 buffer for the whole string, decoded once at the end: appending to a String piece
        // by piece copied it each time, which made long transcript lines quadratic.
        var out: [UInt8] = []
        func append(_ scalar: Unicode.Scalar) { out.append(contentsOf: UTF8.encode(scalar)!) }
        while index < bytes.count {
            let byte = bytes[index]
            if byte == UInt8(ascii: "\"") {
                index += 1
                guard let text = String(bytes: out, encoding: .utf8) else { throw EngineError.invalid("Invalid JSON: Invalid UTF-8") }
                return text
            }
            if byte == UInt8(ascii: "\\") {
                index += 1
                guard index < bytes.count else { break }
                let escape = bytes[index]
                index += 1
                switch escape {
                case UInt8(ascii: "\""): out.append(UInt8(ascii: "\""))
                case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
                case UInt8(ascii: "/"): out.append(UInt8(ascii: "/"))
                case UInt8(ascii: "b"): out.append(0x08)
                case UInt8(ascii: "f"): out.append(0x0C)
                case UInt8(ascii: "n"): out.append(0x0A)
                case UInt8(ascii: "r"): out.append(0x0D)
                case UInt8(ascii: "t"): out.append(0x09)
                case UInt8(ascii: "u"):
                    var code = try hex4()
                    if (0xD800..<0xDC00).contains(code), index + 6 <= bytes.count,
                       bytes[index] == UInt8(ascii: "\\"), bytes[index + 1] == UInt8(ascii: "u") {
                        let saved = index
                        index += 2
                        let low = try hex4()
                        if (0xDC00..<0xE000).contains(low) {
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        } else {
                            index = saved
                        }
                    }
                    append(Unicode.Scalar(code) ?? "\u{FFFD}")
                default: throw failure("Invalid \\escape")
                }
                continue
            }
            if byte < 0x20 { throw failure("Invalid control character") }
            out.append(byte)
            index += 1
        }
        throw failure("Unterminated string")
    }

    mutating func number() throws -> JSON {
        let start = index
        if index < bytes.count, bytes[index] == UInt8(ascii: "-") { index += 1 }
        var isFloat = false
        while index < bytes.count {
            let byte = bytes[index]
            if (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) {
                index += 1
            } else if [UInt8(ascii: "."), UInt8(ascii: "e"), UInt8(ascii: "E"), UInt8(ascii: "+"), UInt8(ascii: "-")].contains(byte) {
                isFloat = true
                index += 1
            } else {
                break
            }
        }
        guard index > start, let text = String(bytes: bytes[start..<index], encoding: .ascii) else {
            throw failure("Expecting value")
        }
        if !isFloat, let value = Int64(text) { return .int(value) }
        guard let value = Double(text) else { throw failure("Expecting value") }
        if isFloat && decimalFloats { return .decimal(text) }
        return .double(value)
    }
}
