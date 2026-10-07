import Foundation

public nonisolated struct AppleCalculatorResult: Equatable, Sendable {
    public let expression: String
    public let value: String
    public let isApproximate: Bool
}

public nonisolated enum AppleCalculator {
    public static func evaluate(_ expression: String) throws -> AppleCalculatorResult {
        guard expression.utf8.count <= 512 else { throw AppleToolError.invalidInput("Use an expression of at most 512 bytes.") }
        var parser = try Parser(expression)
        let value = try parser.sum(0)
        guard parser.position == parser.tokens.count else { throw AppleToolError.invalidInput("The expression contains unexpected input.") }
        var number = value
        let text = value == 0 ? "0" : NSDecimalString(&number, Locale(identifier: "en_US_POSIX"))
        return AppleCalculatorResult(expression: expression.trimmingCharacters(in: .whitespacesAndNewlines), value: text, isApproximate: parser.approximate)
    }

    private enum Token { case number(Decimal), symbol(UInt8) }
    private struct Parser {
        var tokens: [Token] = []
        var position = 0
        var approximate = false
        static func invalid(_ message: String = "The expression isn't valid.") -> AppleToolError { .invalidInput(message) }
        init(_ expression: String) throws {
            let bytes = Array(expression.utf8)
            var index = 0
            func digit(_ b: UInt8) -> Bool { (48...57).contains(b) }
            while index < bytes.count {
                let b = bytes[index]
                if [9,10,13,32].contains(b) { index += 1; continue }
                guard tokens.count < 128 else { throw Self.invalid("Use at most 128 expression tokens.") }
                if digit(b) || b == 46 {
                    let start = index
                    var digits = 0
                    var fractionDigits = 0
                    var mantissaDigits: [UInt8] = []
                    while index < bytes.count && digit(bytes[index]) { mantissaDigits.append(bytes[index]); digits += 1; index += 1 }
                    if index < bytes.count && bytes[index] == 46 {
                        index += 1
                        while index < bytes.count && digit(bytes[index]) { mantissaDigits.append(bytes[index]); digits += 1; fractionDigits += 1; index += 1 }
                    }
                    guard digits > 0 else { throw Self.invalid() }
                    var exponent = 0
                    if index < bytes.count && [69,101].contains(bytes[index]) {
                        index += 1
                        var sign = 1
                        if index < bytes.count && [43,45].contains(bytes[index]) { if bytes[index] == 45 { sign = -1 }; index += 1 }
                        let exponentStart = index
                        while index < bytes.count && digit(bytes[index]) {
                            guard exponent <= 1000 else { throw Self.invalid("The number is outside the decimal range.") }
                            exponent = exponent * 10 + Int(bytes[index] - 48); index += 1
                        }
                        guard index > exponentStart else { throw Self.invalid() }
                        exponent *= sign
                    }
                    let significant = mantissaDigits.drop(while: { $0 == 48 })
                    guard significant.count <= 38 else { throw Self.invalid("Use numbers with at most 38 significant digits.") }
                    let decimalExponent = exponent - fractionDigits
                    guard (-128...127).contains(decimalExponent) else { throw Self.invalid("The number is outside the decimal range.") }
                    let literal = String(decoding: bytes[start..<index], as: UTF8.self)
                    guard let value = Decimal(string: literal, locale: Locale(identifier: "en_US_POSIX")), !value.isNaN, (value != 0 || significant.isEmpty) else { throw Self.invalid("The number is outside the decimal range.") }
                    tokens.append(.number(value))
                } else {
                    guard [43,45,42,47,40,41,37,94].contains(b) else { throw Self.invalid("Use numbers and arithmetic operators only.") }
                    tokens.append(.symbol(b)); index += 1
                }
            }
            guard !tokens.isEmpty else { throw Self.invalid("What expression should I calculate?") }
        }
        func check(_ depth: Int) throws { guard depth <= 32 else { throw Self.invalid("The expression is nested too deeply.") } }
        mutating func take(_ symbol: UInt8) -> Bool {
            guard position < tokens.count, case .symbol(symbol) = tokens[position] else { return false }
            position += 1; return true
        }
        mutating func sum(_ depth: Int) throws -> Decimal {
            try check(depth)
            var value = try product(depth)
            while true {
                if take(43) { value = try compute(value, product(depth), 43) }
                else if take(45) { value = try compute(value, product(depth), 45) }
                else { return value }
            }
        }
        mutating func product(_ depth: Int) throws -> Decimal {
            var value = try unary(depth)
            while true {
                if take(42) { value = try compute(value, unary(depth), 42) }
                else if take(47) { value = try compute(value, unary(depth), 47) }
                else { return value }
            }
        }
        mutating func unary(_ depth: Int) throws -> Decimal {
            try check(depth)
            if take(43) { return try unary(depth + 1) }
            if take(45) { return try compute(0, unary(depth + 1), 45) }
            return try power(depth)
        }
        mutating func power(_ depth: Int) throws -> Decimal {
            var value = try primary(depth)
            if take(37) { value = try compute(value, 100, 47) }
            if take(94) {
                let exponent = try unary(depth + 1)
                var raw = exponent
                var rounded = Decimal()
                NSDecimalRound(&rounded, &raw, 0, .plain)
                guard rounded == exponent, exponent >= -1000, exponent <= 1000 else { throw Self.invalid("Powers require an integer exponent from -1000 through 1000.") }
                let n = NSDecimalNumber(decimal: exponent).intValue
                guard !(value == 0 && n <= 0) else { throw Self.invalid("Zero cannot have a zero or negative exponent.") }
                var remaining = abs(n)
                var base = value
                var result = Decimal(1)
                while remaining > 0 {
                    if remaining % 2 == 1 { result = try compute(result, base, 42) }
                    remaining /= 2
                    if remaining > 0 { base = try compute(base, base, 42) }
                }
                value = n < 0 ? try compute(1, result, 47) : result
            }
            return value
        }
        mutating func primary(_ depth: Int) throws -> Decimal {
            try check(depth)
            if take(40) {
                let value = try sum(depth + 1)
                guard take(41) else { throw Self.invalid("The expression needs a closing parenthesis.") }
                return value
            }
            guard position < tokens.count, case .number(let number) = tokens[position] else { throw Self.invalid() }
            position += 1; return number
        }
        mutating func compute(_ lhs: Decimal, _ rhs: Decimal, _ operation: UInt8) throws -> Decimal {
            var a = lhs, b = rhs, result = Decimal()
            NSDecimalCompact(&a)
            NSDecimalCompact(&b)
            if a != 0 && b != 0 && (operation == 42 || operation == 47) {
                let exponent = operation == 42 ? a.exponent + b.exponent : a.exponent - b.exponent
                guard (-128...127).contains(exponent) else {
                    throw Self.invalid("The calculation is outside the calculator's decimal range.")
                }
            }
            let error: Decimal.CalculationError
            switch operation {
            case 43: error = NSDecimalAdd(&result, &a, &b, .plain)
            case 45: error = NSDecimalSubtract(&result, &a, &b, .plain)
            case 42: error = NSDecimalMultiply(&result, &a, &b, .plain)
            default:
                guard rhs != 0 else { throw Self.invalid("Division by zero isn't defined.") }
                error = NSDecimalDivide(&result, &a, &b, .plain)
            }
            switch error {
            case .noError: break
            case .lossOfPrecision: approximate = true
            case .divideByZero: throw Self.invalid("Division by zero isn't defined.")
            default: throw Self.invalid("The calculation is outside the decimal range.")
            }
            guard !result.isNaN else { throw Self.invalid("The calculation has no decimal result.") }
            if operation == 47 {
                var restored = Decimal()
                var quotient = result
                let reverseError = NSDecimalMultiply(&restored, &quotient, &b, .plain)
                if reverseError != .noError || restored.isNaN || restored != a { approximate = true }
            } else if operation == 43 || operation == 45 {
                var restored = Decimal(), other = Decimal(), copy = result
                let first: Decimal.CalculationError
                let second: Decimal.CalculationError
                if operation == 43 {
                    first = NSDecimalSubtract(&restored, &copy, &a, .plain)
                    second = NSDecimalSubtract(&other, &copy, &b, .plain)
                } else {
                    first = NSDecimalSubtract(&restored, &a, &copy, .plain)
                    second = NSDecimalAdd(&other, &copy, &b, .plain)
                }
                if first != .noError || second != .noError || restored.isNaN || other.isNaN || restored != b || other != a { approximate = true }
            } else if operation == 42 && significantDigits(a) + significantDigits(b) > 38 {
                approximate = true
            }
            return result
        }

        private func significantDigits(_ value: Decimal) -> Int {
            var storage = value
            let digits = Array(NSDecimalString(&storage, Locale(identifier: "en_US_POSIX")).utf8.filter { (48...57).contains($0) })
            let trimmed = digits.drop(while: { $0 == 48 }).reversed().drop(while: { $0 == 48 })
            return max(1, trimmed.count)
        }
    }
}
