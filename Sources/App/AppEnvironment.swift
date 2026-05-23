import Foundation

/// Top-level composition root. Holds the live `LLMRunner`, the
/// `ToolDispatcher` with all registered tools, the `AgentService` that
/// bridges them, and the `ConversationManager` that owns chat state.
///
/// Constructed once in `ObeliskApp` and passed down to views as a `let`.
/// Not `@Observable` itself — the only piece that publishes changes is
/// `manager`, which views read directly.
@MainActor
final class AppEnvironment {
    let runner: any LLMRunner
    let dispatcher: ToolDispatcher
    let agent: AgentService
    let manager: ConversationManager
    let vaultAccess: VaultAccessService
    let vaultIndexing: VaultIndexingService
    /// Exposed at app scope so chat UI taps (Sources card, wikilinks)
    /// can record frecency open events without reaching through the
    /// indexing service for the underlying `VaultIndex`. See
    /// phase-c.md §8.
    let frecency: FrecencyTracker

    init(
        runner: (any LLMRunner)? = nil,
        tools: [any Tool]? = nil,
        manager: ConversationManager? = nil,
        vaultAccess: VaultAccessService? = nil
    ) {
        let runner = runner ?? AppleFoundationRunner()
        let access = vaultAccess ?? VaultAccessService()
        let index = AppEnvironment.makeVaultIndex()
        let scanner = VaultScanner(index: index)
        let indexing = VaultIndexingService(index: index, scanner: scanner)

        // Tools default to the Phase C vault toolset — `tools` is only
        // overridden by tests / previews.
        let resolvedTools: [any Tool] = tools ?? AppEnvironment.defaultTools(
            index: index,
            access: access
        )

        let dispatcher = ToolDispatcher(tools: resolvedTools)
        self.runner = runner
        self.dispatcher = dispatcher
        self.agent = AgentService(runner: runner, dispatcher: dispatcher)
        self.manager = manager ?? ConversationManager()
        self.vaultAccess = access
        self.vaultIndexing = indexing
        self.frecency = index.frecency

        // One-shot launch maintenance: drop `note_opens` rows older
        // than the lookback window so the table can't grow unbounded.
        let frecency = index.frecency
        Task.detached(priority: .background) {
            frecency.pruneOldOpens()
        }
    }

    /// Open (or create) the SQLite vault index in `Documents/vault-index.sqlite`.
    /// On failure we fall back to an in-memory store so the app still launches —
    /// the user will see "indexing failed" in the Vault settings sheet instead
    /// of a crash.
    private static func makeVaultIndex() -> VaultIndex {
        let url = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first!
            .appending(path: "vault-index.sqlite", directoryHint: .notDirectory)
        do {
            return try VaultIndex(databaseURL: url)
        } catch {
            #if DEBUG
            print("[AppEnvironment] vault-index.sqlite open failed: \(error). Using in-memory fallback.")
            #endif
            // ":memory:" is a SQLite-recognized path that lives only for
            // the process lifetime. Good enough as a safety net.
            // swiftlint:disable:next force_try
            return try! VaultIndex(databaseURL: URL(fileURLWithPath: ":memory:"))
        }
    }

    /// AFM-realistic toolset: just `find` (surface notes by keyword,
    /// tag, folder, or backlinks) and `read` (read one note by path
    /// or as today's daily). Two tools collapse the previous six so
    /// AFM's routing decision shrinks to a single binary choice —
    /// list vs. content — which a ~3B model can actually make
    /// reliably. Apple's TN3193 caps the recommended tool count at
    /// 3–5; we sit comfortably under that.
    @MainActor
    static func defaultTools(index: VaultIndex, access: VaultAccessService) -> [any Tool] {
        // Snapshot the active vault's root URL on demand for tools that
        // need filesystem access. The closure jumps to MainActor since
        // `VaultAccessService` is main-actor-isolated; this is cheap
        // (one property read).
        let rootURLProvider: @Sendable () async -> URL? = { [weak access] in
            await MainActor.run { access?.activeVault?.rootURL }
        }
        return [
            FindTool(index: index),
            ReadTool(index: index, rootURLProvider: rootURLProvider),
        ]
    }
}
