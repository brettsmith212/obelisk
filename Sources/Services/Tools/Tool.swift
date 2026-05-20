import Foundation

/// A capability the model can invoke. Per phase-a.md §6 and the discipline
/// rules in roadmap.md §"Phase A":
///
/// - Defined **once** against this neutral protocol.
/// - `AppleFoundationRunner` adapts each conformance to Foundation Models'
///   native `Tool` conformance and `@Generable` arg type **internally**;
///   none of that leaks across the `LLMRunner` seam.
/// - A future MLX runner would render the same `argumentsSchema` into a
///   text-based tool-call format. Keep this protocol satisfiable by both.
protocol Tool: Sendable {
    /// Stable identifier the model uses in its tool call. Lowercase, no
    /// spaces: e.g. `"datetime"`, `"calculator"`, `"scratchpad"`.
    var name: String { get }

    /// One-line, model-facing description. Helps the model decide when to
    /// invoke this tool.
    var description: String { get }

    /// JSON-schema-shaped description of `run`'s expected arguments.
    var argumentsSchema: JSONSchema { get }

    /// Execute the tool. Throw `ToolError` (or any `Error`) to surface a
    /// user-visible failure in the inline tool-call row (ui-spec §4.5 / §4.8).
    func run(arguments: JSONValue) async throws -> JSONValue
}

/// Common failure cases tools can throw. The dispatcher renders these into
/// the `error` field of `ToolResult`.
enum ToolError: Error, LocalizedError {
    case invalidArguments(String)
    case executionFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let m): "Invalid arguments: \(m)"
        case .executionFailed(let m):  m
        }
    }
}
