import Foundation

/// Read / write / list plain-text notes in the app's own `Documents/scratchpad/`.
/// Per phase-a.md §6 this is throwaway state used to exercise stateful tools
/// end-to-end; **not** the vault. Phase B replaces it with real vault tools
/// that respect the "do no harm" rules.
struct ScratchpadTool: Tool {
    let name = "scratchpad"
    let description = """
    Read, write, or list notes in a private scratchpad folder. \
    Use action="list" to see all notes (omit name/content), \
    action="read" with a name to retrieve a note, \
    action="write" with name and content to create or overwrite a note. \
    Notes are plain text. This is the agent's own scratchpad — not the user's Obsidian vault.
    """
    let argumentsSchema: JSONSchema = .object(
        properties: [
            "action":  .string(
                description: "One of 'read', 'write', or 'list'.",
                enumValues: ["read", "write", "list"]
            ),
            "name":    .string(description: "Note name (omit for 'list')."),
            "content": .string(description: "Note body (required for 'write').")
        ],
        required: ["action"]
    )

    private let directoryURL: URL

    init(documentsURL: URL? = nil) {
        let docs = documentsURL
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.directoryURL = docs.appending(path: "scratchpad", directoryHint: .isDirectory)
    }

    func run(arguments: JSONValue) async throws -> JSONValue {
        guard case .object(let props) = arguments,
              case .string(let action)? = props["action"]
        else {
            throw ToolError.invalidArguments("Missing 'action'.")
        }
        try ensureDirectory()

        switch action {
        case "list":
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directoryURL.path()))
                ?? []
            return .object([
                "notes": .array(names.sorted().map { .string($0) })
            ])

        case "read":
            let name = try requireName(props, for: "read")
            let url = noteURL(name: name)
            guard FileManager.default.fileExists(atPath: url.path()) else {
                throw ToolError.executionFailed("Note '\(name)' not found.")
            }
            let content = try String(contentsOf: url, encoding: .utf8)
            return .object([
                "name":    .string(url.lastPathComponent),
                "content": .string(content)
            ])

        case "write":
            let name = try requireName(props, for: "write")
            guard case .string(let content)? = props["content"] else {
                throw ToolError.invalidArguments("'write' requires 'content'.")
            }
            let url = noteURL(name: name)
            try Data(content.utf8).write(to: url, options: .atomic)
            return .object([
                "name":  .string(url.lastPathComponent),
                "saved": .bool(true)
            ])

        default:
            throw ToolError.invalidArguments("Unknown action '\(action)'. Use 'read', 'write', or 'list'.")
        }
    }

    private func requireName(_ props: [String: JSONValue], for action: String) throws -> String {
        guard case .string(let name)? = props["name"],
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ToolError.invalidArguments("'\(action)' requires a non-empty 'name'.")
        }
        return name
    }

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
    }

    /// Sanitize the model-supplied name so it stays inside the scratchpad
    /// folder (no traversal, no separators) and gets a `.md` suffix.
    private func noteURL(name: String) -> URL {
        var safe = name
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .replacingOccurrences(of: "..", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !safe.lowercased().hasSuffix(".md") { safe += ".md" }
        return directoryURL.appending(path: safe)
    }
}
