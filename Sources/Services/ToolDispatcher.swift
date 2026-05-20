import Foundation

/// Tiny registry that maps tool names → `Tool` conformances and executes
/// a call. Lives one layer above `LLMRunner`: the runner asks "please
/// resolve this tool call," the dispatcher looks up the tool, runs it,
/// and converts thrown errors into `ToolResult.failure`.
///
/// Why a dispatcher exists (and the runner doesn't just receive `[Tool]`):
///   - Keeps the runner narrow — runner advertises schemas, caller owns
///     execution. Future cross-cutting concerns (timeouts, telemetry,
///     authorization) attach here, not in the runner.
///   - Matches the architecture diagram in phase-a.md §3.1.
struct ToolDispatcher: Sendable {
    /// Keyed by `Tool.name`. Constructor validates uniqueness so a name
    /// collision is caught at startup, not at dispatch time.
    private let tools: [String: any Tool]

    init(tools: [any Tool]) {
        var byName: [String: any Tool] = [:]
        for tool in tools {
            precondition(byName[tool.name] == nil, "Duplicate tool name: \(tool.name)")
            byName[tool.name] = tool
        }
        self.tools = byName
    }

    /// Schema-only projections suitable for handing to `LLMRunner.generate(tools:)`.
    var descriptors: [ToolDescriptor] {
        tools.values.map(ToolDescriptor.init(tool:))
    }

    /// Resolve a single tool call. Never throws — failures become
    /// `ToolResult.failure(...)` so the runner can surface them to the
    /// model and the UI can render the amber inline error row (ui-spec §4.8).
    func dispatch(id: UUID, name: String, arguments: JSONValue) async -> ToolResult {
        guard let tool = tools[name] else {
            return .failure("Unknown tool: \(name)")
        }
        do {
            let output = try await tool.run(arguments: arguments)
            return .success(output)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failure(message)
        }
    }
}
