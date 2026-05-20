import Foundation
import FoundationModels

/// Phase A's only `LLMRunner` implementation. Wraps Apple's Foundation
/// Models framework (iOS 26+).
///
/// Discipline (per phase-a.md §3.2):
///   - `LanguageModelSession`, `Transcript`, `@Generable`, `GenerationOptions`
///     are referenced **only** inside this file. They never appear in the
///     `LLMRunner` protocol or in callers.
///   - Tool adapters live here too. Obelisk's neutral `Tool` /
///     `ToolDescriptor` is translated to Foundation Models' native `Tool`
///     conformance via private adapter types.
///
/// Phase A step 6 scope: only the empty-args tool shape (DateTime) is
/// wired. `makeAdapter` throws `unsupportedToolSchema` for anything else —
/// Calculator and Scratchpad will add their own adapters (or move to a
/// dynamic `GenerationSchema` + `GeneratedContent` adapter) in step 11.
actor AppleFoundationRunner: LLMRunner {
    /// Tracks the most recent in-flight generation so `cancel()` can tear
    /// it down. A single `LanguageModelSession` per call keeps the
    /// implementation simple for Phase A; multi-turn context will be
    /// re-introduced when we wire `Transcript`.
    private var currentTask: Task<Void, Never>?

    init() {}

    // MARK: - LLMRunner

    nonisolated var availability: LLMAvailability {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            return .unavailable(reason: Self.describe(reason))
        @unknown default:
            return .unavailable(reason: "Apple Intelligence is unavailable for an unknown reason.")
        }
    }

    nonisolated func generate(
        messages: [Message],
        tools: [ToolDescriptor],
        dispatch: @escaping @Sendable (_ id: UUID, _ name: String, _ arguments: JSONValue) async -> ToolResult,
        options: LLMGenerateOptions
    ) -> AsyncThrowingStream<LLMEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                await self.run(
                    messages: messages,
                    tools: tools,
                    dispatch: dispatch,
                    options: options,
                    continuation: continuation
                )
            }
            Task { await self.setCurrentTask(task) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated func cancel() {
        Task { await self.cancelCurrent() }
    }

    // MARK: - Actor-isolated state

    private func setCurrentTask(_ task: Task<Void, Never>) {
        currentTask?.cancel()
        currentTask = task
    }

    private func cancelCurrent() {
        currentTask?.cancel()
        currentTask = nil
    }

    private func clearCurrentTask(_ task: Task<Void, Never>) {
        // Only clear if it's still the one we set — avoids racing with a
        // newer generate() call that already swapped in its task.
        if currentTask == task { currentTask = nil }
    }

    // MARK: - Core run loop

    private func run(
        messages: [Message],
        tools: [ToolDescriptor],
        dispatch: @escaping @Sendable (UUID, String, JSONValue) async -> ToolResult,
        options: LLMGenerateOptions,
        continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) async {
        defer { continuation.finish() }

        // 1. Gate on availability.
        if case .unavailable(let reason) = availability {
            continuation.finish(throwing: AppleFoundationRunnerError.unavailable(reason: reason))
            return
        }

        // 2. Pull the prompt out of the transcript. Phase A only sends the
        //    most recent user turn; multi-turn history wiring is a later
        //    step (`Transcript`-based rehydration).
        guard let userMessage = messages.last(where: { $0.role == .user }) else {
            continuation.finish(throwing: AppleFoundationRunnerError.missingUserMessage)
            return
        }

        // 3. Build native Tool adapters for whatever descriptors we got.
        let adapters: [any FoundationModels.Tool]
        do {
            adapters = try tools.map { descriptor in
                try Self.makeAdapter(
                    for: descriptor,
                    dispatch: dispatch,
                    continuation: continuation
                )
            }
        } catch {
            continuation.finish(throwing: error)
            return
        }

        // 4. Spin up a fresh session per call.
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            tools: adapters,
            instructions: Instructions(
                "You are Obelisk, a private on-device assistant. Be concise. " +
                "When a tool can answer a factual question (current time, " +
                "arithmetic, etc.), prefer calling the tool over guessing."
            )
        )

        // 5. Stream snapshots → emit deltas as .token events.
        let genOptions = GenerationOptions(temperature: options.temperature)
        do {
            let stream = session.streamResponse(to: userMessage.content, options: genOptions)
            var emitted = ""
            for try await snapshot in stream {
                // `streamResponse(to: String, ...)` yields snapshots whose
                // `content` is the cumulative text-so-far. Diff against
                // what we've already emitted to honor the `.token`
                // contract on `LLMEvent` (callers append, not replace).
                let full = snapshot.content
                guard full.count > emitted.count else { continue }
                let delta = String(full[full.index(full.startIndex, offsetBy: emitted.count)...])
                continuation.yield(.token(delta))
                emitted = full
            }
            continuation.yield(.done)
        } catch is CancellationError {
            // Stream cancelled by `cancel()` or task termination — finish
            // silently so callers can mark the turn `.stopped`.
        } catch {
            continuation.finish(throwing: error)
        }
    }

    // MARK: - Adapter factory

    private static func makeAdapter(
        for descriptor: ToolDescriptor,
        dispatch: @escaping @Sendable (UUID, String, JSONValue) async -> ToolResult,
        continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) throws -> any FoundationModels.Tool {
        // Phase A step 6: only empty-args is wired. Validate the schema
        // shape and reject anything richer with a clear error rather than
        // silently mis-dispatching.
        guard case .object(let properties, _, _) = descriptor.argumentsSchema, properties.isEmpty else {
            throw AppleFoundationRunnerError.unsupportedToolSchema(name: descriptor.name)
        }
        return EmptyArgsToolAdapter(
            name: descriptor.name,
            description: descriptor.description,
            dispatch: dispatch,
            continuation: continuation
        )
    }

    // MARK: - Availability message mapping

    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is off. Enable it in Settings → Apple Intelligence."
        case .deviceNotEligible:
            return "This device doesn't support Apple Intelligence."
        case .modelNotReady:
            return "Apple Intelligence is still downloading. Try again in a moment."
        @unknown default:
            return "Apple Intelligence isn't available right now."
        }
    }
}

// MARK: - Tool adapter (empty args)

/// Bridges a no-argument Obelisk `Tool` to Foundation Models' native `Tool`
/// conformance. The adapter emits `.toolCallStart` / `.toolCallResult` on
/// the outer event stream so the UI can render the inline tool-call row
/// per ui-spec §4.5.
private struct EmptyArgsToolAdapter: FoundationModels.Tool {
    let name: String
    let description: String
    let dispatch: @Sendable (UUID, String, JSONValue) async -> ToolResult
    let continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation

    @Generable
    struct Arguments {}

    func call(arguments: Arguments) async throws -> String {
        let id = UUID()
        let args = JSONValue.object([:])

        continuation.yield(.toolCallStart(id: id, name: name, arguments: args))
        let result = await dispatch(id, name, args)
        continuation.yield(.toolCallResult(id: id, result: result))

        if let err = result.error {
            // Surface the failure to FM so the model can react in its
            // continuation — but the user-visible row is already amber
            // via the .toolCallResult event above.
            throw ToolError.executionFailed(err)
        }
        return Self.stringify(result.output)
    }

    /// Serialize a `JSONValue` into a compact string for the model to read
    /// back. FM's Tool API accepts any `PromptRepresentable`; a stable
    /// JSON string is the simplest neutral encoding.
    private static func stringify(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(value),
           let string = String(data: data, encoding: .utf8) {
            return string
        }
        return String(describing: value)
    }
}

// MARK: - Errors

enum AppleFoundationRunnerError: Error, LocalizedError {
    case unavailable(reason: String)
    case missingUserMessage
    case unsupportedToolSchema(name: String)

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason
        case .missingUserMessage:
            return "No user message to send to the model."
        case .unsupportedToolSchema(let name):
            return "Tool '\(name)' has a non-empty argument schema; only empty-args tools are wired in Phase A step 6."
        }
    }
}
