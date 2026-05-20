import Foundation

/// Raw JSON I/O for `Conversation`s and the drawer index. Per phase-a.md §5:
///
///   Documents/
///     conversations.json                 ← summaries (drawer source)
///     conversations/<uuid>.json          ← one file per conversation
///
/// All writes are atomic (`Data.write(options: .atomic)` writes to a temp
/// file in the same directory and renames into place) so a crash mid-save
/// can't corrupt either the index or an individual conversation.
struct ConversationStore: Sendable {
    let documentsURL: URL

    init(documentsURL: URL? = nil) {
        // `.documentsDirectory` resolves to the app's sandboxed Documents
        // folder on iOS — same place we'll later mount vault bookmarks.
        self.documentsURL = documentsURL
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    }

    // MARK: - Paths

    private var conversationsDir: URL {
        documentsURL.appending(path: "conversations", directoryHint: .isDirectory)
    }

    private var indexURL: URL {
        documentsURL.appending(path: "conversations.json")
    }

    private func conversationURL(id: UUID) -> URL {
        conversationsDir.appending(path: "\(id.uuidString).json")
    }

    private func ensureConversationsDir() throws {
        try FileManager.default.createDirectory(
            at: conversationsDir,
            withIntermediateDirectories: true
        )
    }

    // MARK: - Coders

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .prettyPrinted]
        return e
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    // MARK: - Index

    /// Returns `[]` if the index file doesn't exist yet (fresh install).
    func loadIndex() throws -> [ConversationSummary] {
        guard FileManager.default.fileExists(atPath: indexURL.path()) else {
            return []
        }
        let data = try Data(contentsOf: indexURL)
        return try decoder.decode([ConversationSummary].self, from: data)
    }

    func saveIndex(_ summaries: [ConversationSummary]) throws {
        let data = try encoder.encode(summaries)
        try data.write(to: indexURL, options: .atomic)
    }

    // MARK: - Conversations

    func loadConversation(id: UUID) throws -> Conversation {
        let data = try Data(contentsOf: conversationURL(id: id))
        return try decoder.decode(Conversation.self, from: data)
    }

    func saveConversation(_ conversation: Conversation) throws {
        try ensureConversationsDir()
        let data = try encoder.encode(conversation)
        try data.write(to: conversationURL(id: conversation.id), options: .atomic)
    }

    func deleteConversation(id: UUID) throws {
        let url = conversationURL(id: id)
        if FileManager.default.fileExists(atPath: url.path()) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
