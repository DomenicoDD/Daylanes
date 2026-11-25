import Foundation

/// A nonnegative arbitrary-precision integer, enough for decimal coefficients (base 10^9 limbs).
struct BigUInt: Equatable, Comparable, CustomStringConvertible {
    static let base: UInt64 = 1_000_000_000
    /// Little-endian limbs below `base`, with no trailing zero limbs; zero is empty.
    private(set) var limbs: [UInt32]

    init() { limbs = [] }

    init(_ value: UInt64) {
        var rest = value
        var limbs: [UInt32] = []
        while rest > 0 {
            limbs.append(UInt32(rest % BigUInt.base))
            rest /= BigUInt.base
        }
        self.limbs = limbs
    }

    /// Decimal digits only ("0012" reads as 12).
    init?<S: StringProtocol>(digits: S) {
        let scalars = Array(digits.utf8)
        guard !scalars.isEmpty, scalars.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        var limbs: [UInt32] = []
        var end = scalars.count
        while end > 0 {
            let start = max(0, end - 9)
            var value: UInt32 = 0
            for byte in scalars[start..<end] { value = value * 10 + UInt32(byte - 48) }
            limbs.append(value)
            end = start
        }
        self.limbs = limbs
        trim()
    }

    private mutating func trim() {
        while let last = limbs.last, last == 0 { limbs.removeLast() }
    }

    var isZero: Bool { limbs.isEmpty }

    /// The value when it fits in 64 bits.
    var uint64: UInt64? {
        guard limbs.count <= 3 else { return nil }
        var value: UInt64 = 0
        for limb in limbs.reversed() {
            let (scaled, overflow) = value.multipliedReportingOverflow(by: BigUInt.base)
            guard !overflow else { return nil }
            let (sum, carry) = scaled.addingReportingOverflow(UInt64(limb))
            guard !carry else { return nil }
            value = sum
        }
        return value
    }

    var description: String {
        guard let last = limbs.last else { return "0" }
        var text = String(last)
        for limb in limbs.dropLast().reversed() {
            let part = String(limb)
            text += String(repeating: "0", count: 9 - part.count) + part
        }
        return text
    }

    /// Number of decimal digits (1 for zero, like Python's `len(str(n))`).
    var digitCount: Int {
        guard let last = limbs.last else { return 1 }
        var count = (limbs.count - 1) * 9
        var top = last
        while top > 0 { count += 1; top /= 10 }
        return count
    }

    static func < (lhs: BigUInt, rhs: BigUInt) -> Bool {
        if lhs.limbs.count != rhs.limbs.count { return lhs.limbs.count < rhs.limbs.count }
        for index in stride(from: lhs.limbs.count - 1, through: 0, by: -1) where lhs.limbs[index] != rhs.limbs[index] {
            return lhs.limbs[index] < rhs.limbs[index]
        }
        return false
    }

    static func + (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var result = BigUInt()
        result.limbs.reserveCapacity(max(lhs.limbs.count, rhs.limbs.count) + 1)
        var carry: UInt64 = 0
        for index in 0..<max(lhs.limbs.count, rhs.limbs.count) {
            let sum = UInt64(index < lhs.limbs.count ? lhs.limbs[index] : 0)
                + UInt64(index < rhs.limbs.count ? rhs.limbs[index] : 0) + carry
            result.limbs.append(UInt32(sum % base))
            carry = sum / base
        }
        if carry > 0 { result.limbs.append(UInt32(carry)) }
        return result
    }

    /// `lhs - rhs`, where `lhs >= rhs`.
    static func - (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        var result = lhs
        var borrow: Int64 = 0
        for index in 0..<lhs.limbs.count {
            var value = Int64(lhs.limbs[index]) - borrow - Int64(index < rhs.limbs.count ? rhs.limbs[index] : 0)
            borrow = 0
            if value < 0 { value += Int64(base); borrow = 1 }
            result.limbs[index] = UInt32(value)
        }
        precondition(borrow == 0, "BigUInt subtraction underflow")
        result.trim()
        return result
    }

    static func * (lhs: BigUInt, rhs: BigUInt) -> BigUInt {
        if lhs.isZero || rhs.isZero { return BigUInt() }
        if let a = lhs.uint64, let b = rhs.uint64 {
            let (product, overflow) = a.multipliedReportingOverflow(by: b)
            if !overflow { return BigUInt(product) }
        }
        var cells = [UInt64](repeating: 0, count: lhs.limbs.count + rhs.limbs.count + 1)
        for (i, a) in lhs.limbs.enumerated() {
            var carry: UInt64 = 0
            for (j, b) in rhs.limbs.enumerated() {
                let value = cells[i + j] + UInt64(a) * UInt64(b) + carry
                cells[i + j] = value % base
                carry = value / base
            }
            var k = i + rhs.limbs.count
            while carry > 0 {
                let value = cells[k] + carry
                cells[k] = value % base
                carry = value / base
                k += 1
            }
        }
        var result = BigUInt()
        result.limbs = cells.map { UInt32($0) }
        result.trim()
        return result
    }

    private static var powers: [BigUInt] = [BigUInt(1)]

    static func pow10(_ exponent: Int) -> BigUInt {
        precondition(exponent >= 0)
        if exponent < 19 { return BigUInt((0..<exponent).reduce(UInt64(1)) { value, _ in value * 10 }) }
        var result = BigUInt(1)
        var remaining = exponent
        let chunk = BigUInt(UInt64(1_000_000_000_000_000_000))  // 10^18
        while remaining >= 18 { result = result * chunk; remaining -= 18 }
        return result * pow10(remaining)
    }

    /// Quotient and remainder.
    func divided(by divisor: BigUInt) -> (quotient: BigUInt, remainder: BigUInt) {
        precondition(!divisor.isZero, "division by zero")
        if self < divisor { return (BigUInt(), self) }
        if let a = uint64, let b = divisor.uint64 { return (BigUInt(a / b), BigUInt(a % b)) }
        if divisor.limbs.count == 1 {
            let d = UInt64(divisor.limbs[0])
            var quotient = [UInt32](repeating: 0, count: limbs.count)
            var remainder: UInt64 = 0
            for index in stride(from: limbs.count - 1, through: 0, by: -1) {
                let value = remainder * BigUInt.base + UInt64(limbs[index])
                quotient[index] = UInt32(value / d)
                remainder = value % d
            }
            var q = BigUInt()
            q.limbs = quotient
            q.trim()
            return (q, BigUInt(remainder))
        }
        // Long division over decimal digits: at most nine subtractions per digit.
        var quotientDigits = ""
        var remainder = BigUInt()
        let ten = BigUInt(10)
        for character in description.utf8 {
            remainder = remainder * ten + BigUInt(UInt64(character - 48))
            var digit = 0
            while !(remainder < divisor) {
                remainder = remainder - divisor
                digit += 1
            }
            quotientDigits.append(Character(String(digit)))
        }
        return (BigUInt(digits: quotientDigits) ?? BigUInt(), remainder)
    }

    /// The last decimal digit.
    var lastDigit: Int { limbs.isEmpty ? 0 : Int(limbs[0] % 10) }
}

/// A decimal with Python's `decimal.Decimal` semantics under the default context
/// (28 significant digits, ROUND_HALF_EVEN): the same exponents, rounding and text.
struct PyDecimal: CustomStringConvertible, Equatable, Comparable {
    static let precision = 28

    enum Rounding { case halfEven, halfUp, down }

    var negative: Bool
    var coefficient: BigUInt
    var exponent: Int

    init(negative: Bool = false, coefficient: BigUInt, exponent: Int) {
        self.negative = negative
        self.coefficient = coefficient
        self.exponent = exponent
    }

    init(_ value: Int) {
        negative = value < 0
        coefficient = BigUInt(value.magnitude.toUInt64)
        exponent = 0
    }

    static let zero = PyDecimal(0)
    static let one = PyDecimal(1)

    /// `Decimal(text)` for finite values; nil where Python raises or gives NaN/Infinity.
    init?(_ text: String) {
        var body = Substring(text.pythonStripped)
        var negative = false
        if let first = body.first, first == "+" || first == "-" {
            negative = first == "-"
            body = body.dropFirst()
        }
        var exponent = 0
        if let marker = body.firstIndex(where: { $0 == "e" || $0 == "E" }) {
            var digits = body[body.index(after: marker)...]
            var expNegative = false
            if let sign = digits.first, sign == "+" || sign == "-" {
                expNegative = sign == "-"
                digits = digits.dropFirst()
            }
            guard let value = PyDecimal.underscoredDigits(digits), value.count <= 18, let parsed = Int(value) else { return nil }
            exponent = expNegative ? -parsed : parsed
            body = body[..<marker]
        }
        let parts = body.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let whole = parts[0]
        let fraction = parts.count > 1 ? parts[1] : ""
        guard parts.count == 1 || parts.count == 2 else { return nil }
        guard !(whole.isEmpty && fraction.isEmpty) else { return nil }
        guard let wholeDigits = whole.isEmpty ? "" : PyDecimal.underscoredDigits(whole),
              let fractionDigits = fraction.isEmpty ? "" : PyDecimal.underscoredDigits(fraction) else { return nil }
        guard let coefficient = BigUInt(digits: wholeDigits + fractionDigits) else { return nil }
        self.negative = negative
        self.coefficient = coefficient
        self.exponent = exponent - fractionDigits.count
    }

    /// Digits with Python's optional single underscores between them.
    private static func underscoredDigits<S: StringProtocol>(_ text: S) -> String? {
        guard !text.isEmpty, text.first != "_", text.last != "_", !text.contains("__") else { return nil }
        let digits = text.replacingOccurrences(of: "_", with: "")
        guard !digits.isEmpty, digits.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }) else { return nil }
        return digits
    }

    var isZero: Bool { coefficient.isZero }

    // MARK: Rounding

    /// Drops `count` trailing digits of the coefficient with the given rounding.
    private static func dropDigits(_ coefficient: BigUInt, _ count: Int, _ rounding: Rounding, negative: Bool) -> BigUInt {
        guard count > 0 else { return coefficient }
        let divisor = BigUInt.pow10(count)
        let (quotient, remainder) = coefficient.divided(by: divisor)
        guard !remainder.isZero else { return quotient }
        switch rounding {
        case .down:
            return quotient
        case .halfUp, .halfEven:
            let doubled = remainder + remainder
            if doubled < divisor { return quotient }
            if divisor < doubled { return quotient + BigUInt(1) }
            if rounding == .halfUp || quotient.lastDigit % 2 == 1 { return quotient + BigUInt(1) }
            return quotient
        }
    }

    /// Rounds to the context precision (Python's `_fix`, without exponent limits).
    func fixed() -> PyDecimal {
        let digits = coefficient.digitCount
        guard digits > PyDecimal.precision else { return self }
        var drop = digits - PyDecimal.precision
        var rounded = PyDecimal.dropDigits(coefficient, drop, .halfEven, negative: negative)
        if rounded.digitCount > PyDecimal.precision {
            rounded = rounded.divided(by: BigUInt(10)).quotient
            drop += 1
        }
        return PyDecimal(negative: negative, coefficient: rounded, exponent: exponent + drop)
    }

    /// `quantize` / `_rescale`: the same value with exactly this exponent.
    func rescaled(_ target: Int, _ rounding: Rounding = .halfEven) -> PyDecimal {
        if coefficient.isZero { return PyDecimal(negative: negative, coefficient: BigUInt(), exponent: target) }
        if target <= exponent {
            return PyDecimal(negative: negative, coefficient: coefficient * BigUInt.pow10(exponent - target), exponent: target)
        }
        let rounded = PyDecimal.dropDigits(coefficient, target - exponent, rounding, negative: negative)
        return PyDecimal(negative: negative, coefficient: rounded, exponent: target)
    }

    func quantized(_ exponent: Int, _ rounding: Rounding = .halfEven) -> PyDecimal { rescaled(exponent, rounding) }

    /// `normalize()`: rounded to the precision, trailing zeros removed.
    func normalized() -> PyDecimal {
        var value = fixed()
        if value.coefficient.isZero { return PyDecimal(negative: value.negative, coefficient: BigUInt(), exponent: 0) }
        let ten = BigUInt(10)
        while value.coefficient.lastDigit == 0 {
            value.coefficient = value.coefficient.divided(by: ten).quotient
            value.exponent += 1
        }
        return value
    }

    /// `int(value)`: truncated toward zero.
    var truncated: Int {
        let magnitude: BigUInt
        if exponent >= 0 {
            magnitude = coefficient * BigUInt.pow10(exponent)
        } else {
            magnitude = coefficient.divided(by: BigUInt.pow10(-exponent)).quotient
        }
        let value = Int(min(magnitude.uint64 ?? UInt64(Int.max), UInt64(Int.max)))
        return negative ? -value : value
    }

    /// `int(value.quantize(Decimal("1"), ROUND_HALF_UP))` (Python's `store.round_units`).
    var roundedHalfUp: Int { rescaled(0, .halfUp).truncated }

    // MARK: Arithmetic

    static prefix func - (value: PyDecimal) -> PyDecimal {
        PyDecimal(negative: !value.negative, coefficient: value.coefficient, exponent: value.exponent)
    }

    static func + (lhs: PyDecimal, rhs: PyDecimal) -> PyDecimal {
        var exponent = min(lhs.exponent, rhs.exponent)
        if lhs.isZero && rhs.isZero {
            return PyDecimal(negative: lhs.negative && rhs.negative, coefficient: BigUInt(), exponent: exponent).fixed()
        }
        if lhs.isZero || rhs.isZero {
            // Python keeps the other operand, rescaled to the smaller exponent (bounded by the precision).
            let other = lhs.isZero ? rhs : lhs
            exponent = max(exponent, other.exponent - precision - 1)
            return other.rescaled(exponent).fixed()
        }
        let a = lhs.coefficient * BigUInt.pow10(lhs.exponent - exponent)
        let b = rhs.coefficient * BigUInt.pow10(rhs.exponent - exponent)
        if lhs.negative == rhs.negative {
            return PyDecimal(negative: lhs.negative, coefficient: a + b, exponent: exponent).fixed()
        }
        if a == b {
            // x + (-x) is +0 under ROUND_HALF_EVEN.
            return PyDecimal(negative: false, coefficient: BigUInt(), exponent: exponent).fixed()
        }
        if b < a {
            return PyDecimal(negative: lhs.negative, coefficient: a - b, exponent: exponent).fixed()
        }
        return PyDecimal(negative: rhs.negative, coefficient: b - a, exponent: exponent).fixed()
    }

    static func - (lhs: PyDecimal, rhs: PyDecimal) -> PyDecimal { lhs + (-rhs) }

    static func * (lhs: PyDecimal, rhs: PyDecimal) -> PyDecimal {
        PyDecimal(negative: lhs.negative != rhs.negative, coefficient: lhs.coefficient * rhs.coefficient,
                  exponent: lhs.exponent + rhs.exponent).fixed()
    }

    /// Division as in CPython's `Decimal.__truediv__` (exact when possible, else 28 digits).
    static func / (lhs: PyDecimal, rhs: PyDecimal) -> PyDecimal {
        precondition(!rhs.isZero, "division by zero")
        let negative = lhs.negative != rhs.negative
        if lhs.isZero {
            return PyDecimal(negative: negative, coefficient: BigUInt(), exponent: lhs.exponent - rhs.exponent).fixed()
        }
        let shift = rhs.coefficient.digitCount - lhs.coefficient.digitCount + precision + 1
        var exponent = lhs.exponent - rhs.exponent - shift
        var (quotient, remainder) = shift >= 0
            ? (lhs.coefficient * BigUInt.pow10(shift)).divided(by: rhs.coefficient)
            : lhs.coefficient.divided(by: rhs.coefficient * BigUInt.pow10(-shift))
        if !remainder.isZero {
            if quotient.lastDigit % 5 == 0 { quotient = quotient + BigUInt(1) }
        } else {
            let ideal = lhs.exponent - rhs.exponent
            let ten = BigUInt(10)
            while exponent < ideal, quotient.lastDigit == 0, !quotient.isZero {
                quotient = quotient.divided(by: ten).quotient
                exponent += 1
            }
        }
        return PyDecimal(negative: negative, coefficient: quotient, exponent: exponent).fixed()
    }

    static func += (lhs: inout PyDecimal, rhs: PyDecimal) { lhs = lhs + rhs }

    // MARK: Comparing

    static func == (lhs: PyDecimal, rhs: PyDecimal) -> Bool { compare(lhs, rhs) == 0 }
    static func < (lhs: PyDecimal, rhs: PyDecimal) -> Bool { compare(lhs, rhs) < 0 }

    private static func compare(_ lhs: PyDecimal, _ rhs: PyDecimal) -> Int {
        if lhs.isZero && rhs.isZero { return 0 }
        let lsign = lhs.isZero ? 0 : (lhs.negative ? -1 : 1)
        let rsign = rhs.isZero ? 0 : (rhs.negative ? -1 : 1)
        if lsign != rsign { return lsign < rsign ? -1 : 1 }
        let exponent = min(lhs.exponent, rhs.exponent)
        let a = lhs.coefficient * BigUInt.pow10(lhs.exponent - exponent)
        let b = rhs.coefficient * BigUInt.pow10(rhs.exponent - exponent)
        if a == b { return 0 }
        let magnitude = a < b ? -1 : 1
        return lsign < 0 ? -magnitude : magnitude
    }

    // MARK: Text

    /// `str(value)`: Python's scientific or plain notation.
    var description: String {
        let digits = coefficient.description
        let left = exponent + digits.count
        let dot: Int = (exponent <= 0 && left > -6) ? left : 1
        var intPart: String, fracPart: String
        if dot <= 0 {
            intPart = "0"
            fracPart = "." + String(repeating: "0", count: -dot) + digits
        } else if dot >= digits.count {
            intPart = digits + String(repeating: "0", count: dot - digits.count)
            fracPart = ""
        } else {
            intPart = String(digits.prefix(dot))
            fracPart = "." + digits.dropFirst(dot)
        }
        let exp = left == dot ? "" : "E" + (left - dot >= 0 ? "+" : "-") + String(abs(left - dot))
        return (negative ? "-" : "") + intPart + fracPart + exp
    }

    /// `format(value, "f")` without a precision: plain notation keeping the exponent's digits.
    var plain: String { formatted(places: nil) }

    /// `format(value, ".Nf")`: rounded half to even to N places.
    func fixedText(_ places: Int) -> String { formatted(places: places) }

    private func formatted(places: Int?) -> String {
        var value = self
        if let places { value = value.rescaled(-places, .halfEven) }
        if value.isZero && value.exponent > 0 { value = value.rescaled(0, .halfEven) }
        let digits = value.coefficient.description
        let dot = value.exponent + digits.count
        var intPart: String, fracPart: String
        if dot < 0 {
            intPart = "0"
            fracPart = String(repeating: "0", count: -dot) + digits
        } else if dot > digits.count {
            intPart = digits + String(repeating: "0", count: dot - digits.count)
            fracPart = ""
        } else {
            intPart = dot == 0 ? "0" : String(digits.prefix(dot))
            fracPart = String(digits.dropFirst(dot))
        }
        return (value.negative ? "-" : "") + intPart + (fracPart.isEmpty ? "" : "." + fracPart)
    }
}

private extension UInt {
    var toUInt64: UInt64 { UInt64(self) }
}

extension PyDecimal {
    /// Python's `store.money(cents)`: `format(Decimal(cents) / 100, ".2f")`.
    static func money(_ cents: Int) -> String { (PyDecimal(cents) / PyDecimal(100)).fixedText(2) }

    /// Python's `store.hours(millis)`: `format(Decimal(millis) / 3600000, ".4f")`.
    static func hours(_ millis: Int) -> String { (PyDecimal(millis) / PyDecimal(3_600_000)).fixedText(4) }

    /// Python's `store.round_units` then `store.money`: an amount in cents as "12.34".
    static func centsText(_ amount: PyDecimal) -> String { money(amount.roundedHalfUp) }
}
