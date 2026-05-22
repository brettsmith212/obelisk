import Foundation

/// UI-facing event stream produced by `AgentService`. Maps 1:1 to the data
/// the chat view needs to render an assistant turn (phase-a.md §7).
///
/// Differences from `LLMEvent`:
///   - `.toolCallStart` carries a fully-formed `ToolCall` so the UI can
///     append it to the message's `toolCalls` array directly.
///   - Failures arrive as `.error` events on this non-throwing stream
///     instead of escaping through `try`. One stream, one consumer loop.
enum AgentEvent: Sendable {
    case token(String)
    case toolCallStart(ToolCall)
    case toolCallResult(id: UUID, ToolResult)
    case finalDone
    case error(AgentError)
}

/// User-presentable failure surfaced via `AgentEvent.error`. The string is
/// already shaped for direct rendering in the inline error row (ui-spec §4.8
/// tier 2 — red, "Try again").
struct AgentError: Error, Sendable {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    init(from error: Error) {
        // Apple's FoundationModels errors stringify as raw debug text
        // (e.g. "FoundationModels.LanguageModelSession.GenerationError
        // error -1"). Translate the ones we see into something a user
        // can act on; fall back to the underlying description otherwise.
        let raw = (error as? LocalizedError)?.errorDescription
            ?? String(describing: error)
        self.message = Self.humanize(raw)
    }

    private static func humanize(_ raw: String) -> String {
        if raw.contains("GenerationError") || raw.contains("LanguageModelSession") {
            return "The model couldn't generate a response. Try rephrasing the question or starting a new conversation."
        }
        if raw.contains("guardrail") || raw.contains("safety") {
            return "Apple Intelligence declined to respond to that prompt."
        }
        if raw.contains("contextWindow") || raw.contains("context window") {
            return "The conversation is too long for the on-device model. Start a new chat to continue."
        }
        return raw
    }
}

/// Bridges `LLMRunner` (schema-only, throwing, backend-specific shape) to
/// the chat UI's single non-throwing `AsyncStream<AgentEvent>`.
///
/// Responsibilities:
///   1. Project the dispatcher's tools into `[ToolDescriptor]` for the runner.
///   2. Provide the runner's `dispatch` closure (routes tool calls through
///      `ToolDispatcher`).
///   3. Translate `LLMEvent` → `AgentEvent`.
///   4. Catch any thrown error and re-emit it as `.error`.
///
/// Not responsible for: conversation persistence (that's `ConversationManager`),
/// tool registration (that's `ToolDispatcher`), or session lifecycle (that's
/// inside the runner).
struct AgentService: Sendable {
    let runner: any LLMRunner
    let dispatcher: ToolDispatcher

    init(runner: any LLMRunner, dispatcher: ToolDispatcher) {
        self.runner = runner
        self.dispatcher = dispatcher
    }

    /// Stream a single assistant turn for the given conversation. The
    /// caller is responsible for having appended the user message before
    /// calling, and for creating a streaming assistant placeholder to
    /// receive the events.
    ///
    /// Cancellation: dropping the consumer (or breaking out of the loop)
    /// cancels the underlying runner task via the stream's
    /// `onTermination` hook.
    func run(
        conversation: Conversation,
        options: LLMGenerateOptions = .default
    ) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            let runner = self.runner
            let dispatcher = self.dispatcher

            let task = Task {
                // Per-turn guard. Two protections against context
                // overflow on the AFM 4096-token window:
                //   1. `singleCall`: some tools (notably
                //      `browse_vault`) must not be called more than
                //      once in the same turn — two pages of results
                //      blow the window.
                //   2. `maxTotalCalls`: cap total tool invocations
                //      per turn at 2. One was too restrictive — the
                //      model frequently re-runs search_vault in a
                //      follow-up turn ("what does it say?") and then
                //      needs read_note. Two calls accommodates that.
                //      Tool outputs are kept compact (browse: 10
                //      rows w/o snippets; search: trimmed snippets;
                //      read_note: small preview by default) so the
                //      two outputs still fit the 4096-token window.
                let turnGuard = TurnGuard(singleCall: ["browse_vault"], maxTotalCalls: 2)
                let dispatch: @Sendable (UUID, String, JSONValue) async -> ToolResult = { id, name, args in
                    switch await turnGuard.shouldBlock(name) {
                    case .allow:
                        return await dispatcher.dispatch(id: id, name: name, arguments: args)
                    case .duplicate:
                        return .failure(
                            "\(name) was already called this turn. Do NOT call it again. Reply to the user with the data you already have. If the user wants the next page, they will ask in their next message and you can call \(name) again then with offset=nextOffset."
                        )
                    case .overBudget:
                        return .failure(
                            "You may only call ONE tool per user turn. Reply to the user NOW with the data you already have from the previous tool call; do not call any more tools this turn. If the user wants you to do something with the result (e.g. read a found note), they will ask in their next message."
                        )
                    }
                }

                let stream = runner.generate(
                    messages: conversation.messages,
                    tools: dispatcher.descriptors,
                    dispatch: dispatch,
                    options: options
                )

                do {
                    for try await event in stream {
                        switch event {
                        case .token(let text):
                            continuation.yield(.token(text))

                        case .toolCallStart(let id, let name, let arguments):
                            continuation.yield(.toolCallStart(
                                ToolCall(id: id, name: name, arguments: arguments, result: nil)
                            ))

                        case .toolCallResult(let id, let result):
                            continuation.yield(.toolCallResult(id: id, result))

                        case .done:
                            continuation.yield(.finalDone)
                        }
                    }
                } catch is CancellationError {
                    // Caller-initiated cancellation; finish silently so
                    // the UI can mark the turn `.stopped` per its own
                    // policy (ui-spec §4.3).
                } catch {
                    continuation.yield(.error(AgentError(from: error)))
                }

                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
                runner.cancel()
            }
        }
    }

    /// Convenience: forwards to the runner. Equivalent to dropping the
    /// stream consumer, but explicit when the UI's stop button is tapped.
    func cancel() {
        runner.cancel()
    }
}

/// Per-turn dispatch guard. Tracks which tools have already been
/// invoked within a single assistant turn. Lives only for the
/// duration of one `AgentService.run(...)` call.
private actor TurnGuard {
    enum Decision {
        case allow
        case duplicate      // tool in `singleCall` invoked a second time
        case overBudget     // would exceed `maxTotalCalls`
    }

    private var called: Set<String> = []
    private var totalCalls: Int = 0
    private let singleCall: Set<String>
    private let maxTotalCalls: Int

    init(singleCall: Set<String>, maxTotalCalls: Int) {
        self.singleCall = singleCall
        self.maxTotalCalls = maxTotalCalls
    }

    /// Returns the dispatcher's decision for this call. On `.allow`
    /// the call is recorded so subsequent calls see the updated state.
    func shouldBlock(_ name: String) -> Decision {
        if singleCall.contains(name), called.contains(name) {
            return .duplicate
        }
        if totalCalls >= maxTotalCalls {
            return .overBudget
        }
        called.insert(name)
        totalCalls += 1
        return .allow
    }
}
