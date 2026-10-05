import Foundation

/// A parsed calculator expression.
indirect enum AskCalculatorNode: Equatable {
    case number(Decimal)
    case constant(String)
    case negate(AskCalculatorNode)
    case binary(Character, AskCalculatorNode, AskCalculatorNode)
    case percent(AskCalculatorNode)
    case factorial(AskCalculatorNode)
    case degrees(AskCalculatorNode)
    case call(String, [AskCalculatorNode])
}

/// Recursive-descent parser for the calculator grammar:
///
///     expr    := term (('+' | '-') term)*
///     term    := unary (('*' | '/' | 'mod') unary)*
///     unary   := ('-' | '+') unary | power
///     power   := postfix ('^' unary)?            // right-associative; -2^2 = -4
///     postfix := primary ('%' | '!' | '°')*
///     primary := number | constant | function '(' args ')' | '(' expr ')'
struct AskCalculatorParser {
    enum Failure: Error, Equatable {
        /// The text ends where more is expected, as in "12*3+" or "(1+2".
        case incomplete
        /// The text cannot be an expression.
        case invalid
    }

    static let constants: Set<String> = ["pi", "π", "e"]
    /// Accepted argument counts per function.
    static let functions: [String: ClosedRange<Int>] = [
        "sqrt": 1 ... 1, "abs": 1 ... 1, "round": 1 ... 2, "floor": 1 ... 1, "ceil": 1 ... 1,
        "ln": 1 ... 1, "log": 1 ... 1, "log2": 1 ... 1,
        "sin": 1 ... 1, "cos": 1 ... 1, "tan": 1 ... 1, "asin": 1 ... 1, "acos": 1 ... 1, "atan": 1 ... 1,
        "min": 1 ... 32, "max": 1 ... 32
    ]
    static let maximumDepth = 64

    private let tokens: [AskCalculatorToken]
    private var position = 0
    private var depth = 0
    /// Something beyond a bare value was written: an operator or a function.
    private(set) var hasOperation = false

    init(tokens: [AskCalculatorToken]) { self.tokens = tokens }

    /// Parses every token, or fails.
    static func parse(_ tokens: [AskCalculatorToken]) throws -> (node: AskCalculatorNode, hasOperation: Bool) {
        var parser = AskCalculatorParser(tokens: tokens)
        guard !tokens.isEmpty else { throw Failure.invalid }
        let node = try parser.expression()
        guard parser.position == tokens.count else {
            // A closing parenthesis too many, or two values side by side.
            throw Failure.invalid
        }
        return (node, parser.hasOperation)
    }

    private var current: AskCalculatorToken? { position < tokens.count ? tokens[position] : nil }

    private mutating func take(_ symbol: Character) -> Bool {
        guard current == .symbol(symbol) else { return false }
        position += 1
        return true
    }

    private mutating func nested<T>(_ body: (inout AskCalculatorParser) throws -> T) throws -> T {
        depth += 1
        defer { depth -= 1 }
        guard depth <= Self.maximumDepth else { throw Failure.invalid }
        return try body(&self)
    }

    private mutating func expression() throws -> AskCalculatorNode {
        var node = try term()
        while let symbol = current.flatMap(Self.symbol), symbol == "+" || symbol == "-" {
            position += 1
            hasOperation = true
            node = .binary(symbol, node, try term())
        }
        return node
    }

    private mutating func term() throws -> AskCalculatorNode {
        var node = try unary()
        while let symbol = current.flatMap(Self.symbol), symbol == "*" || symbol == "/" || symbol == "m" {
            position += 1
            hasOperation = true
            node = .binary(symbol, node, try unary())
        }
        return node
    }

    private mutating func unary() throws -> AskCalculatorNode {
        if take("-") { return try nested { .negate(try $0.unary()) } }
        if take("+") { return try nested { try $0.unary() } }
        return try power()
    }

    private mutating func power() throws -> AskCalculatorNode {
        let base = try postfix()
        guard take("^") else { return base }
        hasOperation = true
        return try nested { .binary("^", base, try $0.unary()) }
    }

    private mutating func postfix() throws -> AskCalculatorNode {
        var node = try primary()
        while let symbol = current.flatMap(Self.symbol) {
            switch symbol {
            case "%": node = .percent(node)
            case "!": node = .factorial(node)
            case "°": node = .degrees(node)
            default: return node
            }
            position += 1
            hasOperation = true
        }
        return node
    }

    private mutating func primary() throws -> AskCalculatorNode {
        guard let token = current else { throw Failure.incomplete }
        position += 1
        switch token {
        case let .number(value, _, _):
            return .number(value)
        case let .identifier(name):
            // A lone constant is not enough: "e" is also how a sentence starts.
            if Self.constants.contains(name) {
                return .constant(name == "π" ? "pi" : name)
            }
            guard let arity = Self.functions[name] else { throw Failure.invalid }
            guard current != nil else { throw Failure.incomplete }
            guard take("(") else { throw Failure.invalid }
            hasOperation = true
            let arguments = try nested { try $0.arguments() }
            guard arity.contains(arguments.count) else { throw Failure.invalid }
            return .call(name, arguments)
        case .symbol("("):
            let node = try nested { try $0.expression() }
            guard current != nil else { throw Failure.incomplete }
            guard take(")") else { throw Failure.invalid }
            return node
        case .symbol:
            throw Failure.invalid
        }
    }

    private mutating func arguments() throws -> [AskCalculatorNode] {
        var list = [try expression()]
        while take(",") { list.append(try expression()) }
        guard current != nil else { throw Failure.incomplete }
        guard take(")") else { throw Failure.invalid }
        return list
    }

    private static func symbol(_ token: AskCalculatorToken) -> Character? {
        if case let .symbol(symbol) = token { return symbol }
        return nil
    }
}
