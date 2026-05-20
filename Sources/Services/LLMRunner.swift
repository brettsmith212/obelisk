import Foundation

// MARK: - Public seam types
//
// These are the Obelisk-native types that flow across the LLMRunner boundary.
// Foundation-Models-specific types (`LanguageModelSession`, `Transcript`,
// `@Generable`, …) and any other backend's internals must stay behind
// concrete runner implementations and never appear here.
//
// Discipline rules — see phase-a.md §3.2:
//   1. The seam is neutral. `Message`, `Role`, `ToolCall`, `ToolResult` are
//      reused from Domain/ as-is.
//   2. Backend-specific features (e.g. guided generation) may be used
//      *inside* a concrete runner but must not appear in this file.
//   3. Before changing this file, ask: "Could MLX satisfy this?" If no,
//      push the specialness back into the concrete runner.

/// Schema-only description of a tool the model may invoke. Carries no
/// execution capability — tool execution is mediated by the caller via the
/// `dispatch` closure passed to `generate`, so a runner can advertise tools
/// to a model without needing to run them itself.
///
/// Built from a `Tool` via `ToolDescriptor(tool:)`.
struct ToolDescriptor: Sendable, Equatable {
    let name: String
    let description: String
    let argumentsSchema: JSONSchema

    init(name: String, description: String, argumentsSchema: JSONSchema) {
        self.name = name
        self.description = description
        self.argumentsSchema = argumentsSchema
    }

    init(tool: Tool) {
        self.init(
            name: tool.name,
            description: tool.description,
            argumentsSchema: tool.argumentsSchema
        )
    }
}

/// Streamed atoms a runner emits during a single assistant turn.
///
/// Ordering guarantees:
///   - Tokens for a given turn arrive in order.
///   - For each tool call, `.toolCallStart(id)` is followed (after the
///     caller's `dispatch` returns) by exactly one `.toolCallResult(id)`.
///   - `.done` is the terminal event for a successful turn.
///   - On failure, the stream finishes with the thrown error and no `.done`.
enum LLMEvent: Sendable, Equatable {
    /// A chunk of assistant text. May be a single token or several;
    /// callers should append, not replace.
    case token(String)

    /// The model has requested a tool be run. The caller's `dispatch`
    /// closure is invoked to resolve it; this event is for UI rendering.
    case toolCallStart(id: UUID, name: String, arguments: JSONValue)

    /// The result of the matching `.toolCallStart`. Either success
    /// (`result.error == nil`) or a user-visible failure.
    case toolCallResult(id: UUID, result: ToolResult)

    /// The assistant turn is complete. No further events will be emitted.
    case done
}

/// Reasons a runner may be unable to service a request. Mapped by callers
/// to inline error UI per ui-spec.md §4.8.
enum LLMAvailability: Sendable, Equatable {
    /// Ready to generate.
    case available

    /// Backend exists but isn't ready right now. `reason` is user-facing
    /// copy explaining how to recover (e.g. "Apple Intelligence is off in
    /// Settings.").
    case unavailable(reason: String)
}

/// Sampling / decode knobs. Kept small on purpose — anything we add here
/// must be expressible by every backend we ever ship.
struct LLMGenerateOptions: Sendable {
    /// `nil` means "use the runner's default."
    var temperature: Double?
    var maxTokens: Int?

    init(temperature: Double? = nil, maxTokens: Int? = nil) {
        self.temperature = temperature
        self.maxTokens = maxTokens
    }

    static let `default` = LLMGenerateOptions()
}

// MARK: - Protocol

/// The single extensibility seam for swapping LLM backends. Day-one
/// implementations: `AppleFoundationRunner`. Future: `MLXRunner`.
///
/// The runner's job is narrow:
///   1. Take a conversation transcript and a set of tool descriptors.
///   2. Stream assistant tokens.
///   3. When the model wants a tool, invoke the caller-provided `dispatch`
///      closure, wait for the `ToolResult`, surface it to the model so it
///      can continue, and emit `.toolCallStart` / `.toolCallResult` events
///      for the UI.
///   4. End with `.done`, or throw.
///
/// The runner does **not** own tool registration, conversation persistence,
/// or UI state. Those live in `AgentService`, `ToolDispatcher`, and
/// `ConversationManager` respectively.
protocol LLMRunner: Sendable {
    /// Whether the runner is usable right now. Cheap to call — safe to
    /// query before every generation.
    var availability: LLMAvailability { get }

    /// Stream a single assistant turn.
    ///
    /// - Parameters:
    ///   - messages: Full transcript so far. The runner is free to ignore
    ///     `Message` fields it doesn't care about (`id`, `status`,
    ///     `createdAt`).
    ///   - tools: Tools the model may invoke this turn. Schema-only.
    ///   - dispatch: Caller-owned tool executor. The runner awaits this
    ///     synchronously per tool call; whatever `ToolResult` it returns is
    ///     fed back to the model and re-emitted as `.toolCallResult`.
    ///   - options: Sampling knobs.
    /// - Returns: A throwing stream of `LLMEvent`s. Cancelling the stream
    ///   (task cancellation or `cancel()`) must cleanly tear down the
    ///   underlying session.
    func generate(
        messages: [Message],
        tools: [ToolDescriptor],
        dispatch: @escaping @Sendable (_ id: UUID, _ name: String, _ arguments: JSONValue) async -> ToolResult,
        options: LLMGenerateOptions
    ) -> AsyncThrowingStream<LLMEvent, Error>

    /// Cancel any in-flight generation. Safe to call when idle. After
    /// cancellation the runner must remain reusable for subsequent
    /// `generate` calls.
    func cancel()
}
