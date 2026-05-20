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
                let dispatch: @Sendable (UUID, String, JSONValue) async -> ToolResult = { id, name, args in
                    await dispatcher.dispatch(id: id, name: name, arguments: args)
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
