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

        // Tools default to Phase B's vault toolset — `tools` is only
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

    /// Phase B toolset (phase-b.md §4 + §7): the original `DateTimeTool`
    /// and `CalculatorTool` survive from Phase A; `ScratchpadTool` is
    /// removed per phase-b.md §1.6; the six vault read tools and the
    /// single write tool (`CreateNoteTool`) take its place. Total: 9
    /// tools — within the 6–10 ceiling phase-b.md §10 warns about for
    /// the on-device 3B model.
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
            DateTimeTool(),
            CalculatorTool(),
            SearchVaultTool(index: index),
            ReadNoteTool(index: index),
            ListNotesByTagTool(index: index),
            GetBacklinksTool(index: index),
            ListRecentNotesTool(index: index),
            ReadDailyNoteTool(index: index, rootURLProvider: rootURLProvider),
            CreateNoteTool(index: index, rootURLProvider: rootURLProvider),
        ]
    }
}
