import Foundation

/// Why a well-formed expression has no value.
enum AskCalculatorError: Error, Equatable {
    case divisionByZero
    /// Outside where the operation is defined, such as `sqrt(-1)` or `ln(0)`.
    case domain
    /// Too large to compute or to represent.
    case outOfRange

    var message: String {
        switch self {
        case .divisionByZero: L("ask.quick.error.divisionByZero")
        case .domain: L("ask.quick.error.domain")
        case .outOfRange: L("ask.quick.error.outOfRange")
        }
    }
}

/// Evaluates a parsed expression. Arithmetic, integer powers, percentages and
/// factorials stay in `Decimal`, so `0.1 + 0.2` is 0.3 and money adds up;
/// roots, logarithms and trigonometry go through `Double`.
enum AskCalculatorEvaluator {
    static let maximumDecimalExponent = 1000
    static let maximumFactorial = 170
    static let pi = Decimal(string: "3.14159265358979323846264338327950288", locale: Locale(identifier: "en_US_POSIX"))!
    static let e = Decimal(string: "2.71828182845904523536028747135266250", locale: Locale(identifier: "en_US_POSIX"))!

    static func evaluate(_ node: AskCalculatorNode) throws -> Decimal {
        let value = try value(of: node)
        guard !value.isNaN else { throw AskCalculatorError.outOfRange }
        return value
    }

    private static func value(of node: AskCalculatorNode) throws -> Decimal {
        switch node {
        case let .number(value):
            return value
        case let .constant(name):
            return name == "e" ? e : pi
        case let .negate(operand):
            return -(try value(of: operand))
        case let .percent(operand):
            return try checked(value(of: operand) / 100)
        case let .degrees(operand):
            return try checked(value(of: operand) * pi / 180)
        case let .factorial(operand):
            return try factorial(value(of: operand))
        case let .call(name, arguments):
            return try call(name, arguments.map(value(of:)))
        case let .binary(symbol, lhs, rhs):
            let left = try value(of: lhs)
            // "200 + 10%" adds ten percent of 200, as on a pocket calculator.
            if symbol == "+" || symbol == "-", case let .percent(inner) = rhs {
                let rate = try value(of: inner) / 100
                return try checked(left * (symbol == "+" ? 1 + rate : 1 - rate))
            }
            return try binary(symbol, left, value(of: rhs))
        }
    }

    private static func binary(_ symbol: Character, _ left: Decimal, _ right: Decimal) throws -> Decimal {
        switch symbol {
        case "+": return try checked(left + right)
        case "-": return try checked(left - right)
        case "*": return try checked(left * right)
        case "/":
            guard !right.isZero else { throw AskCalculatorError.divisionByZero }
            return try checked(left / right)
        case "m":
            guard !right.isZero else { throw AskCalculatorError.divisionByZero }
            return try checked(left - right * truncate(left / right))
        case "^":
            return try power(left, right)
        default:
            throw AskCalculatorError.domain
        }
    }

    private static func power(_ base: Decimal, _ exponent: Decimal) throws -> Decimal {
        if isInteger(exponent), exponent.magnitude <= Decimal(maximumDecimalExponent) {
            let count = NSDecimalNumber(decimal: exponent).intValue
            if count >= 0 { return try checked(pow(base, count)) }
            guard !base.isZero else { throw AskCalculatorError.divisionByZero }
            return try checked(1 / pow(base, -count))
        }
        return try fromDouble(Foundation.pow(double(base), double(exponent)))
    }

    private static func factorial(_ value: Decimal) throws -> Decimal {
        guard isInteger(value), value >= 0 else { throw AskCalculatorError.domain }
        guard value <= Decimal(maximumFactorial) else { throw AskCalculatorError.outOfRange }
        var result = Decimal(1)
        var factor = Decimal(2)
        while factor <= value {
            result = try checked(result * factor)
            factor += 1
        }
        return result
    }

    private static func call(_ name: String, _ arguments: [Decimal]) throws -> Decimal {
        let first = arguments[0]
        switch name {
        case "abs": return first.magnitude
        case "floor": return floor(first)
        case "ceil": return -floor(-first)
        case "round":
            let places = arguments.count > 1 ? arguments[1] : 0
            guard isInteger(places), places.magnitude <= 30 else { throw AskCalculatorError.domain }
            return round(first, places: NSDecimalNumber(decimal: places).intValue)
        case "min": return arguments.min()!
        case "max": return arguments.max()!
        case "sqrt":
            guard first >= 0 else { throw AskCalculatorError.domain }
            return try fromDouble(Foundation.sqrt(double(first)))
        case "ln", "log", "log2":
            guard first > 0 else { throw AskCalculatorError.domain }
            let value = double(first)
            return try fromDouble(name == "ln" ? Foundation.log(value) : name == "log" ? Foundation.log10(value) : Foundation.log2(value))
        case "asin", "acos":
            guard first.magnitude <= 1 else { throw AskCalculatorError.domain }
            return try fromDouble(name == "asin" ? Foundation.asin(double(first)) : Foundation.acos(double(first)))
        case "atan": return try fromDouble(Foundation.atan(double(first)))
        case "sin", "cos", "tan":
            let angle = double(first)
            let value = name == "sin" ? Foundation.sin(angle) : name == "cos" ? Foundation.cos(angle) : Foundation.tan(angle)
            // sin(pi) is 1.2e-16 in binary floating point; a person expects 0.
            return try fromDouble(Swift.abs(value) < 1e-15 ? 0 : value)
        default:
            throw AskCalculatorError.domain
        }
    }

    // MARK: - Helpers

    private static func checked(_ value: Decimal) throws -> Decimal {
        guard !value.isNaN else { throw AskCalculatorError.outOfRange }
        return value
    }

    private static func double(_ value: Decimal) -> Double { NSDecimalNumber(decimal: value).doubleValue }

    private static func fromDouble(_ value: Double) throws -> Decimal {
        guard !value.isNaN else { throw AskCalculatorError.domain }
        // Decimal tops out near 10^165; beyond it there is nothing to show exactly.
        guard value.isFinite, Swift.abs(value) < 1e160 else { throw AskCalculatorError.outOfRange }
        // Drop binary noise (2.9999999999999996) but keep one digit beyond what is
        // shown, so a value used again, as in asin(1)*2, still rounds correctly.
        return AskCalculatorNumber(Decimal(value), significantDigits: 16).decimal
    }

    static func isInteger(_ value: Decimal) -> Bool { truncate(value) == value }

    /// Rounds toward zero.
    private static func truncate(_ value: Decimal) -> Decimal {
        value < 0 ? -rounded(-value, scale: 0, mode: .down) : rounded(value, scale: 0, mode: .down)
    }

    private static func floor(_ value: Decimal) -> Decimal {
        value < 0 ? -rounded(-value, scale: 0, mode: .up) : rounded(value, scale: 0, mode: .down)
    }

    /// Half away from zero, as people round by hand.
    private static func round(_ value: Decimal, places: Int) -> Decimal {
        value < 0 ? -rounded(-value, scale: places, mode: .plain) : rounded(value, scale: places, mode: .plain)
    }

    private static func rounded(_ value: Decimal, scale: Int, mode: NSDecimalNumber.RoundingMode) -> Decimal {
        var input = value
        var result = Decimal()
        NSDecimalRound(&result, &input, scale, mode)
        return result
    }
}
