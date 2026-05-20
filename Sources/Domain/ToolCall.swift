import Foundation

/// A single tool invocation emitted by the model and (eventually) resolved
/// by `ToolDispatcher`. Persisted as part of a `Message`.
///
/// See phase-a.md §5 (data model) and §4.5 (inline rendering).
struct ToolCall: Codable, Identifiable, Equatable, Sendable {
    /// Matches the call id minted by the runner so the UI can correlate
    /// streaming updates with the right inline tool-call row.
    let id: UUID

    /// Tool family name — "datetime", "calculator", "scratchpad".
    var name: String

    /// Schema-typed arguments as decoded from the model.
    var arguments: JSONValue

    /// `nil` while the tool call is in flight; populated when complete or errored.
    var result: ToolResult?
}

/// The outcome of running a tool. Either has an `output` (success) or an
/// `error` (failure surfaced inline per ui-spec §4.8 tier 1).
struct ToolResult: Codable, Equatable, Sendable {
    var output: JSONValue
    var error: String?

    static func success(_ output: JSONValue) -> ToolResult {
        ToolResult(output: output, error: nil)
    }

    static func failure(_ message: String) -> ToolResult {
        ToolResult(output: .null, error: message)
    }
}
