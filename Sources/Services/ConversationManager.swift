import Foundation
import Observation

/// Observable state for the chat shell. Owns the currently visible
/// conversation, the drawer's summary list, and a debounced save loop
/// (~500 ms after the last mutation, per phase-a.md §7).
///
/// All mutations are funneled through `updateActive(_:)` so the dirty
/// signal — and the resulting save + index update — can never be skipped
/// by an ad-hoc property write.
@MainActor
@Observable
final class ConversationManager {
    /// The conversation currently visible in `ChatView`. `nil` means show
    /// the empty state (ui-spec §3.3).
    private(set) var activeConversation: Conversation?

    /// Drawer source, sorted newest-first.
    private(set) var summaries: [ConversationSummary]

    private let store: ConversationStore
    private let saveDelay: Duration
    private var saveTask: Task<Void, Never>?

    init(store: ConversationStore = ConversationStore(), saveDelay: Duration = .milliseconds(500)) {
        self.store = store
        self.saveDelay = saveDelay
        self.summaries = (try? store.loadIndex())?.sorted(by: Self.byRecency) ?? []
    }

    // MARK: - Selection / lifecycle

    /// Create a blank conversation and make it active. Not persisted until
    /// the first content mutation — empty conversations would otherwise
    /// clutter the drawer.
    func newConversation() {
        activeConversation = Conversation()
    }

    /// Load a conversation from disk and make it active. No-op if it's
    /// already active or can't be loaded.
    func selectConversation(id: UUID) {
        if activeConversation?.id == id { return }
        guard let loaded = try? store.loadConversation(id: id) else { return }
        activeConversation = loaded
    }

    /// Mutate the active conversation in place. Bumps `updatedAt` and
    /// schedules a debounced save. All UI writes (user message append,
    /// streaming token accumulation, tool call updates, edits, etc.) go
    /// through here.
    func updateActive(_ mutation: (inout Conversation) -> Void) {
        guard var conversation = activeConversation else { return }
        mutation(&conversation)
        conversation.updatedAt = .now
        activeConversation = conversation
        scheduleSave()
    }

    /// Cancel any pending debounced save and write synchronously. Call
    /// before backgrounding so a quick app-switch doesn't drop the last
    /// few tokens.
    func flush() async {
        saveTask?.cancel()
        await persistNow()
    }

    // MARK: - Save loop

    private func scheduleSave() {
        saveTask?.cancel()
        let delay = saveDelay
        saveTask = Task { [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return // cancelled — a newer mutation took over
            }
            await self?.persistNow()
        }
    }

    private func persistNow() async {
        guard let conversation = activeConversation else { return }
        do {
            try store.saveConversation(conversation)
            updateIndex(with: conversation)
            try store.saveIndex(summaries)
        } catch {
            // Phase A: log only. A later step wires this to the status pill
            // (ui-spec §5) so the user can see persistence failures.
            print("ConversationManager: save failed — \(error)")
        }
    }

    private func updateIndex(with conversation: Conversation) {
        let summary = ConversationSummary(
            id: conversation.id,
            title: conversation.title,
            updatedAt: conversation.updatedAt
        )
        if let idx = summaries.firstIndex(where: { $0.id == conversation.id }) {
            summaries[idx] = summary
        } else {
            summaries.append(summary)
        }
        summaries.sort(by: Self.byRecency)
    }

    private static func byRecency(_ a: ConversationSummary, _ b: ConversationSummary) -> Bool {
        a.updatedAt > b.updatedAt
    }
}
