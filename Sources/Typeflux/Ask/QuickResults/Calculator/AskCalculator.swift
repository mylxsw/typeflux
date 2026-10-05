import Foundation

/// A calculated expression as the launcher shows it.
struct AskCalculation: Equatable {
    /// The expression as typed, tidied: `×` and `÷`, spaces around operators.
    var expression: String
    var outcome: Result<AskCalculatorNumber, AskCalculatorError>
    /// The expression used `0x` or `0b`, so hexadecimal and binary are worth showing.
    var radix = false

    var number: AskCalculatorNumber? {
        if case let .success(number) = outcome { return number }
        return nil
    }
}

/// Decides whether the launcher's text is arithmetic, and computes it. Everything
/// runs locally and synchronously: a keystroke's worth of work is microseconds.
enum AskCalculator {
    enum Reading: Equatable {
        /// Leave the text to the AI.
        case notExpression
        /// Arithmetic that is still being typed, such as "12*3+"; carries the tidy expression so far.
        case incomplete(expression: String)
        case calculation(AskCalculation)
    }

    /// Shapes that parse as arithmetic but are something else: dates and phone numbers.
    private static let lookalikes: [NSRegularExpression] = [
        #"^\d{4}[-/.]\d{1,2}([-/.]\d{1,2})?$"#, // 2024-10-05, 2024/10
        #"^\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4}$"#, // 10/5/2024
        #"^\d{3,4}-\d{7,8}$"#, // 010-12345678
        #"^\d{3}-\d{4}-\d{4}$"# // 138-1234-5678
    ].map { try! NSRegularExpression(pattern: $0) }

    static func read(_ text: String) -> Reading {
        guard text.count <= AskCalculatorLexer.maximumLength, !text.contains(where: \.isNewline) else { return .notExpression }
        let normalized = AskCalculatorLexer.normalize(text)
        guard !normalized.isEmpty, !looksLikeSomethingElse(normalized),
              let tokens = try? AskCalculatorLexer.tokenize(normalized) else { return .notExpression }
        let expression = display(tokens)
        let parsed: (node: AskCalculatorNode, hasOperation: Bool)
        do {
            parsed = try AskCalculatorParser.parse(tokens)
        } catch AskCalculatorParser.Failure.incomplete {
            return .incomplete(expression: expression)
        } catch {
            return .notExpression
        }
        guard parsed.hasOperation else { return .notExpression }
        let radix = tokens.contains { if case .number(_, _, true) = $0 { true } else { false } }
        let outcome: Result<AskCalculatorNumber, AskCalculatorError>
        do {
            outcome = .success(AskCalculatorNumber(try AskCalculatorEvaluator.evaluate(parsed.node)))
        } catch let error as AskCalculatorError {
            outcome = .failure(error)
        } catch {
            outcome = .failure(.domain)
        }
        return .calculation(AskCalculation(expression: expression, outcome: outcome, radix: radix))
    }

    static func looksLikeSomethingElse(_ normalized: String) -> Bool {
        let compact = normalized.filter { !$0.isWhitespace }
        let range = NSRange(compact.startIndex..., in: compact)
        return lookalikes.contains { $0.firstMatch(in: compact, range: range) != nil }
    }

    /// "1234567.89*2" reads as "1234567.89 × 2".
    static func display(_ tokens: [AskCalculatorToken]) -> String {
        var text = ""
        var previous: AskCalculatorToken?
        for token in tokens {
            switch token {
            case let .number(_, written, _): text += written
            case let .identifier(name): text += name
            case let .symbol(symbol):
                switch symbol {
                case "*": text += " × "
                case "/": text += " ÷ "
                case "m": text += " mod "
                case ",": text += ", "
                case "+", "-":
                    text += isUnary(after: previous) ? String(symbol) : " \(symbol) "
                default: text.append(symbol)
                }
            }
            previous = token
        }
        return text.trimmingCharacters(in: .whitespaces)
    }

    private static func isUnary(after previous: AskCalculatorToken?) -> Bool {
        guard let previous else { return true }
        guard case let .symbol(symbol) = previous else { return false }
        return !")%!°".contains(symbol)
    }
}
