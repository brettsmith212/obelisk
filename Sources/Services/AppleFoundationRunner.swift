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
        let history = Array(messages.prefix(lastUserIndex))
        let userMessage = messages[lastUserIndex]

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
        let genOptions = GenerationOptions(temperature: options.temperature)
        do {
            let stream = session.streamResponse(to: userMessage.content, options: genOptions)
            var emitted = ""
            for try await snapshot in stream {
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

    var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return reason
        case .missingUserMessage:
            return "No user message to send to the model."
        }
    }
}
