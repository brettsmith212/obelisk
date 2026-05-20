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

    init(
        runner: (any LLMRunner)? = nil,
        tools: [any Tool] = AppEnvironment.defaultTools,
        manager: ConversationManager? = nil
    ) {
        let runner = runner ?? AppleFoundationRunner()
        let dispatcher = ToolDispatcher(tools: tools)

        self.runner = runner
        self.dispatcher = dispatcher
        self.agent = AgentService(runner: runner, dispatcher: dispatcher)
        self.manager = manager ?? ConversationManager()
    }

    /// Phase A toolset: DateTime only (step 6). Calculator and Scratchpad
    /// land in step 11 once the runner gains a non-empty-args adapter.
    nonisolated static var defaultTools: [any Tool] {
        [DateTimeTool()]
    }
}
