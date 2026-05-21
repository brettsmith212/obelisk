import Foundation

/// Evaluates a basic arithmetic expression. Per phase-a.md §6 this tool
/// exists to exercise parameter parsing across the runner / adapter seam.
///
/// Safety: the expression is whitelisted to digits, decimal points,
/// whitespace, parentheses, and `+ - * /` before being handed to
/// `NSExpression`. That keeps random model-supplied input from triggering
/// NSPredicate-style format-string interpolation (`%K`, `%@`, …) or other
/// non-arithmetic operators.
struct CalculatorTool: Tool {
    let name = "calculator"
    let description = "Evaluates a basic arithmetic expression like '14 * 23' or '(3+4)/2'. Only digits, decimal points, parentheses, whitespace, and + - * / are allowed."
    let argumentsSchema: JSONSchema = .object(
        properties: [
            "expression": .string(description: "Arithmetic expression to evaluate.")
        ],
        required: ["expression"]
    )

    private static let allowed: CharacterSet = {
        var set = CharacterSet(charactersIn: "0123456789.+-*/() ")
        set.insert(charactersIn: "\t\n")
        return set
    }()

    func run(arguments: JSONValue) async throws -> JSONValue {
        guard case .object(let props) = arguments,
              case .string(let raw)? = props["expression"]
        else {
            throw ToolError.invalidArguments("Missing 'expression' string.")
        }

        let expr = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !expr.isEmpty else {
            throw ToolError.invalidArguments("Empty expression.")
        }
        guard expr.unicodeScalars.allSatisfy({ Self.allowed.contains($0) }) else {
            throw ToolError.invalidArguments("Expression contains disallowed characters; use digits and + - * / ( ) only.")
        }

        // NSExpression's parser raises an Obj-C exception on malformed
        // input (not catchable from Swift). The whitelist above guards the
        // common cases; anything that slips through and returns non-numeric
        // is caught below.
        let value = NSExpression(format: expr).expressionValue(with: nil, context: nil)

        guard let number = value as? NSNumber else {
            throw ToolError.executionFailed("Expression did not evaluate to a number.")
        }

        return .object([
            "expression": .string(expr),
            "result":     .number(number.doubleValue)
        ])
    }
}
