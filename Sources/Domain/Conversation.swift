import Foundation

/// A persisted chat thread. Stored as `Documents/conversations/<uuid>.json`
/// (see phase-a.md §5); a separate index file holds summaries for fast
/// drawer rendering.
struct Conversation: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    /// First user message, truncated. User-editable in a later phase.
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var messages: [Message]

    init(
        id: UUID = UUID(),
        title: String = "New conversation",
        createdAt: Date = .now,
        updatedAt: Date = .now,
        messages: [Message] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }
}

/// Lightweight projection used by the drawer's recency-grouped list
/// (ui-spec §3.2). Avoids loading every full conversation JSON file at
/// drawer-open time.
struct ConversationSummary: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var updatedAt: Date
}
