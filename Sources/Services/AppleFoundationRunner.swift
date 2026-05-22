import Foundation
import FoundationModels

/// Phase A's only `LLMRunner` implementation. Wraps Apple's Foundation
/// Models framework (iOS 26+).
///
/// Discipline (per phase-a.md §3.2):
///   - `LanguageModelSession`, `Transcript`, `@Generable`, `GenerationOptions`,
///     `GeneratedContent`, `GenerationSchema`, `DynamicGenerationSchema` are
///     referenced **only** inside this file. They never appear on the
///     `LLMRunner` seam.
///   - Tools are adapted to Foundation Models' native `Tool` conformance
///     via a single private `JSONArgsToolAdapter` whose arguments type is
///     `GeneratedContent` — so any Obelisk `Tool` whose schema fits the
///     `JSONSchema` subset works without per-tool typed structs.
///   - Multi-turn history is replayed as a `Transcript` rebuilt per call.
actor AppleFoundationRunner: LLMRunner {
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

    // MARK: - Core run loop

    private static let systemInstructions = """
    You are Obelisk, a private on-device assistant grounded in the \
    user's Obsidian vault. Be concise. Prefer calling a tool over \
    guessing — search, read, and cite notes from the vault when the \
    user asks about their own knowledge. After a tool returns, reply \
    in plain prose; never echo raw JSON.
    """

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

        // 2. Identify the most recent user turn — that's the prompt for
        //    this generation. Everything before it is replayed as transcript
        //    history. A trailing streaming-assistant placeholder (if any)
        //    is implicitly ignored.
        guard let lastUserIndex = messages.lastIndex(where: { $0.role == .user }) else {
            continuation.finish(throwing: AppleFoundationRunnerError.missingUserMessage)
            return
        }
        let fullHistory = Array(messages.prefix(lastUserIndex))
        let userMessage = messages[lastUserIndex]

        // Trim history to fit the AFM 4096-token window. Tool-heavy
        // turns (e.g. browse_vault returning a long bulleted list) blow
        // the budget within two exchanges. Walk backward and keep the
        // newest turns whose combined character count stays under a
        // conservative budget; the model loses long-ago context but
        // keeps near-term coherence — much better than silently failing
        // to generate.
        let history = Self.trimHistory(fullHistory, maxChars: 6000)

        // 3. Build FoundationModels Tool adapters from descriptors.
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

        // 4. Spin up a session preloaded with prior turns. Per Apple's
        //    docs, instructions live inside the transcript when one is
        //    supplied at init time.
        let transcript = Self.buildTranscript(
            history: history,
            instructions: Self.systemInstructions,
            toolAdapters: adapters
        )
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            tools: adapters,
            transcript: transcript
        )

        // 5. Stream the response. Snapshots carry cumulative text; emit
        //    deltas so callers can keep appending per the `.token` contract.
        //
        //    A no-progress watchdog rides alongside the consumer: Apple's
        //    on-device inference host can die mid-generation (most often
        //    on context-window overflow during tool follow-up) without the
        //    Swift surface ever throwing. Without the watchdog the UI sits
        //    on the "stop" button forever. We treat ≥45s of stream silence
        //    as a stall and surface it as `inferenceStalled` so the chat
        //    can drop into the standard red error row.
        let genOptions = GenerationOptions(temperature: options.temperature)
        let stream = session.streamResponse(to: userMessage.content, options: genOptions)
        let activity = ActivityClock()
        await activity.tick()

        // Race the consumer against a no-progress watchdog. We do NOT
        // await consumer.value, because `session.streamResponse`'s
        // for-await may not honor `Task.cancel()` when the inference
        // host has already died — that would leave us awaiting a Task
        // that never finishes. Instead, both tasks race to write the
        // terminal event into a tiny actor; whoever loses is silently
        // dropped (its work is harmless or background-leaked).
        let result = StreamOutcome()

        let consumer = Task<Void, Never> {
            do {
                var emitted = ""
                for try await snapshot in stream {
                    await activity.tick()
                    let full = snapshot.content
                    guard full.count > emitted.count else { continue }
                    let delta = String(full[full.index(full.startIndex, offsetBy: emitted.count)...])
                    continuation.yield(.token(delta))
                    emitted = full
                }
                await result.finish(.done)
            } catch is CancellationError {
                await result.finish(.cancelled)
            } catch {
                await result.finish(.failed(error))
            }
        }

        let watchdog = Task<Void, Never> {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                if await activity.idleSeconds() > 45 {
                    await result.finish(.stalled)
                    return
                }
            }
        }

        switch await result.value() {
        case .done:
            watchdog.cancel()
            continuation.yield(.done)
        case .cancelled:
            watchdog.cancel()
            // Real user stop — finish silently so the UI marks the
            // turn `.stopped` per its own policy.
        case .failed(let error):
            watchdog.cancel()
            continuation.finish(throwing: error)
        case .stalled:
            // Watchdog won. The consumer task is likely still parked
            // inside `for try await snapshot in stream`; cancel it
            // best-effort and leave it to die in the background while
            // we surface a clean error to the UI.
            consumer.cancel()
            continuation.finish(throwing: AppleFoundationRunnerError.inferenceStalled)
        }
    }

    // MARK: - History trimming

    /// Keep the newest tail of `history` whose total `content` character
    /// count fits in `maxChars`. Always returns a contiguous suffix so
    /// the model sees a coherent recent window. Empty assistant
    /// placeholders are skipped from the budget since `buildTranscript`
    /// drops them anyway.
    private static func trimHistory(_ history: [Message], maxChars: Int) -> [Message] {
        var kept: [Message] = []
        var total = 0
        for msg in history.reversed() {
            let cost = msg.content.count
            if total + cost > maxChars && !kept.isEmpty {
                break
            }
            kept.append(msg)
            total += cost
        }
        return kept.reversed()
    }

    // MARK: - Transcript builder

    /// Replay history as alternating `.prompt` / `.response` entries with a
    /// leading `.instructions` entry that advertises the tools.
    ///
    /// Tool-call provenance from prior turns is intentionally flattened
    /// into the assistant text — FM's `.toolCalls` / `.toolOutput` entries
    /// are reserved for the *current* loop. The model still gets full
    /// conversational continuity, just not the structured trace of every
    /// past tool invocation. Acceptable for Phase A; Phase B can revisit
    /// once vault tools start carrying citation-grade data.
    private static func buildTranscript(
        history: [Message],
        instructions: String,
        toolAdapters: [any FoundationModels.Tool]
    ) -> Transcript {
        var entries: [Transcript.Entry] = []

        // `Transcript.ToolDefinition.init(tool:)` is generic over `some Tool`,
        // so we can't pass the existential `any Tool` adapters through it.
        // Build the definitions explicitly from their public surface.
        let toolDefinitions = toolAdapters.map { adapter in
            Transcript.ToolDefinition(
                name: adapter.name,
                description: adapter.description,
                parameters: adapter.parameters
            )
        }
        let instructionsEntry = Transcript.Instructions(
            segments: [.text(Transcript.TextSegment(content: instructions))],
            toolDefinitions: toolDefinitions
        )
        entries.append(.instructions(instructionsEntry))

        for msg in history {
            switch msg.role {
            case .user:
                let prompt = Transcript.Prompt(
                    segments: [.text(Transcript.TextSegment(content: msg.content))]
                )
                entries.append(.prompt(prompt))
            case .assistant:
                // Skip empty placeholders (e.g. a regenerated turn whose
                // content was reset to "").
                if msg.content.isEmpty { continue }
                let response = Transcript.Response(
                    assetIDs: [],
                    segments: [.text(Transcript.TextSegment(content: msg.content))]
                )
                entries.append(.response(response))
            case .system, .tool:
                continue
            }
        }
        return Transcript(entries: entries)
    }

    // MARK: - Adapter factory

    private static func makeAdapter(
        for descriptor: ToolDescriptor,
        dispatch: @escaping @Sendable (UUID, String, JSONValue) async -> ToolResult,
        continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation
    ) throws -> any FoundationModels.Tool {
        let schema = try Self.buildGenerationSchema(
            rootName: descriptor.name.capitalized + "Arguments",
            from: descriptor.argumentsSchema
        )
        return JSONArgsToolAdapter(
            name: descriptor.name,
            description: descriptor.description,
            parameters: schema,
            dispatch: dispatch,
            continuation: continuation
        )
    }

    // MARK: - JSONSchema → GenerationSchema

    private static func buildGenerationSchema(
        rootName: String,
        from schema: JSONSchema
    ) throws -> GenerationSchema {
        let root = makeDynamic(name: rootName, schema: schema)
        return try GenerationSchema(root: root, dependencies: [])
    }

    private static func makeDynamic(name: String, schema: JSONSchema) -> DynamicGenerationSchema {
        switch schema {
        case .string(_, let enumValues):
            if let vals = enumValues, !vals.isEmpty {
                return DynamicGenerationSchema(name: name, anyOf: vals)
            }
            return DynamicGenerationSchema(type: String.self)
        case .number:
            return DynamicGenerationSchema(type: Double.self)
        case .integer:
            return DynamicGenerationSchema(type: Int.self)
        case .boolean:
            return DynamicGenerationSchema(type: Bool.self)
        case .array(let items, _):
            let item = makeDynamic(name: "\(name)Item", schema: items)
            return DynamicGenerationSchema(arrayOf: item)
        case .object(let properties, let required, let description):
            let props: [DynamicGenerationSchema.Property] = properties
                .sorted(by: { $0.key < $1.key }) // stable schema text
                .map { (key, value) in
                    DynamicGenerationSchema.Property(
                        name: key,
                        description: Self.propertyDescription(of: value),
                        schema: makeDynamic(name: "\(name)_\(key)", schema: value),
                        isOptional: !required.contains(key)
                    )
                }
            return DynamicGenerationSchema(name: name, description: description, properties: props)
        }
    }

    private static func propertyDescription(of schema: JSONSchema) -> String? {
        switch schema {
        case .string(let d, _),
             .number(let d),
             .integer(let d),
             .boolean(let d),
             .array(_, let d),
             .object(_, _, let d):
            return d
        }
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

// MARK: - Tool adapter

/// Bridges any Obelisk `Tool` (regardless of arg shape) to Foundation
/// Models' `Tool` protocol by using `GeneratedContent` as the arg type and
/// carrying a precomputed `GenerationSchema`. The adapter emits
/// `.toolCallStart` / `.toolCallResult` on the outer event stream so the UI
/// can render the inline tool-call row per ui-spec §4.5.
private struct JSONArgsToolAdapter: FoundationModels.Tool {
    typealias Arguments = GeneratedContent
    typealias Output = String

    let name: String
    let description: String
    let parameters: GenerationSchema
    let dispatch: @Sendable (UUID, String, JSONValue) async -> ToolResult
    let continuation: AsyncThrowingStream<LLMEvent, Error>.Continuation

    func call(arguments: GeneratedContent) async throws -> String {
        let id = UUID()
        let args = Self.toJSON(arguments)

        continuation.yield(.toolCallStart(id: id, name: name, arguments: args))
        let result = await dispatch(id, name, args)
        continuation.yield(.toolCallResult(id: id, result: result))

        if let err = result.error {
            // Hand the failure to FM as a normal tool output so the model
            // can apologize / suggest an alternative instead of crashing
            // the whole generation. The user-visible amber row was already
            // emitted via `.toolCallResult` above, so this stays the single
            // source of error truth in the UI.
            return Self.stringify(.object(["error": .string(err)]))
        }
        return Self.stringify(result.output)
    }

    private static func toJSON(_ content: GeneratedContent) -> JSONValue {
        switch content.kind {
        case .null:                       return .null
        case .bool(let b):                return .bool(b)
        case .number(let n):              return .number(n)
        case .string(let s):              return .string(s)
        case .array(let arr):             return .array(arr.map(toJSON))
        case .structure(let props, _):    return .object(props.mapValues(toJSON))
        }
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
    case inferenceStalled

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason
        case .missingUserMessage:
            return "No user message to send to the model."
        case .inferenceStalled:
            return "The on-device model stopped responding (this usually means the conversation exceeded its context window). Start a new chat or ask a shorter question."
        }
    }
}

/// Tracks the last moment we observed forward progress from
/// `streamResponse`. Used by the no-progress watchdog above; kept as a
/// tiny actor so the consumer and watchdog can share state safely.
private actor ActivityClock {
    private var last: Date = .distantPast

    func tick() {
        last = Date()
    }

    func idleSeconds() -> TimeInterval {
        Date().timeIntervalSince(last)
    }
}

/// First-finisher box for the consumer/watchdog race. Only the first
/// `finish(_:)` wins; later writes are dropped. `value()` suspends until
/// the first finisher lands. Used to translate "stream completed", "real
/// cancellation", "thrown error", and "watchdog stall" into a single
/// terminal event the run loop can switch on without awaiting the
/// (potentially hung) consumer task.
private actor StreamOutcome {
    enum Outcome: Sendable {
        case done
        case cancelled
        case failed(Error)
        case stalled
    }

    private var outcome: Outcome?
    private var waiters: [CheckedContinuation<Outcome, Never>] = []

    func finish(_ outcome: Outcome) {
        guard self.outcome == nil else { return }
        self.outcome = outcome
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume(returning: outcome)
        }
    }

    func value() async -> Outcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { cont in
            waiters.append(cont)
        }
    }
}
