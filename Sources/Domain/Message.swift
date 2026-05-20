import Foundation

/// One turn in a `Conversation`. See phase-a.md §5.
struct Message: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var role: Role
    var content: String

    /// Empty for non-assistant or non-tool-using turns.
    var toolCalls: [ToolCall]

    var status: Status
    var createdAt: Date

    init(
        id: UUID = UUID(),
        role: Role,
        content: String,
        toolCalls: [ToolCall] = [],
        status: Status = .complete,
        createdAt: Date = .now
    ) {
        self.id = id
        self.role = role
        self.content = content
        self.toolCalls = toolCalls
        self.status = status
        self.createdAt = createdAt
    }
}

enum Role: String, Codable, Sendable {
    case system, user, assistant, tool
}

enum Status: String, Codable, Sendable {
    /// Final / settled.
    case complete
    /// Still receiving tokens from the runner.
    case streaming
    /// Cancelled by the user mid-stream (ui-spec §4.3 — labeled `… stopped`).
    case stopped
    /// Failed (model error, guardrail refusal, etc. — ui-spec §4.8 tier 2).
    case errored
}
