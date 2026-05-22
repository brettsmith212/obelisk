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

    /// Phase C toolset (phase-c.md §5.4): Phase A's `DateTimeTool` +
    /// `CalculatorTool` and the Phase B vault tools, with two
    /// enumeration tools (`list_recent_notes`, `list_notes_by_tag`)
    /// collapsed into the new `BrowseVaultTool` and `SearchVaultTool`
    /// upgraded to FTS5 + frecency. Total: 8 tools — comfortably under
    /// the 10-tool ceiling.
    @MainActor
    static func defaultTools(index: VaultIndex, access: VaultAccessService) -> [any Tool] {
        // Snapshot the active vault's root URL on demand for tools that
        // need filesystem access. The closure jumps to MainActor since
        // `VaultAccessService` is main-actor-isolated; this is cheap
        // (one property read).
        let rootURLProvider: @Sendable () async -> URL? = { [weak access] in
            await MainActor.run { access?.activeVault?.rootURL }
        }
        // Same shape for the user's deny list — sourced from
        // `VaultAccessService` so edits in the Vault Settings sheet
        // take effect on the next tool call without re-registering.
        let denyListProvider: @Sendable () async -> [String] = { [weak access] in
            await MainActor.run { access?.userDenyList ?? [] }
        }
        return [
            DateTimeTool(),
            CalculatorTool(),
            SearchVaultTool(index: index),
            BrowseVaultTool(index: index),
            ReadNoteTool(index: index),
            GetBacklinksTool(index: index),
            ReadDailyNoteTool(
                index: index,
                rootURLProvider: rootURLProvider,
                userDenyListProvider: denyListProvider
            ),
            CreateNoteTool(
                index: index,
                rootURLProvider: rootURLProvider,
                userDenyListProvider: denyListProvider
            ),
        ]
    }
}
