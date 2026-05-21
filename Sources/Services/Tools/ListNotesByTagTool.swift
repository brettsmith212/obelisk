import Foundation

/// List notes carrying a tag. With `includeChildren = true` (the
/// default), hierarchical tags match — asking for `project` returns
/// notes tagged `#project`, `#project/obelisk`, and so on.
struct ListNotesByTagTool: Tool {
    let name = "list_notes_by_tag"
    let description = """
    List notes in the user's Obsidian vault tagged with the given tag. \
    Use this for prompts like 'show me notes tagged #project'. By \
    default, hierarchical children also match (so 'project' includes \
    'project/obelisk'); pass includeChildren=false for an exact match.
    """
    let argumentsSchema: JSONSchema = .object(
        properties: [
            "tag":             .string(description: "Tag to look up (no leading '#' required)."),
            "includeChildren": .boolean(description: "Include hierarchical child tags. Default true."),
            "limit":           .integer(description: "Max notes to return. Default 10."),
        ],
        required: ["tag"]
    )

    private let index: VaultIndex

    init(index: VaultIndex) {
        self.index = index
    }

    func run(arguments: JSONValue) async throws -> JSONValue {
        guard case .object(let props) = arguments,
              case .string(let tag)? = props["tag"],
              !tag.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ToolError.invalidArguments("'tag' is required.")
        }
        let includeChildren = props["includeChildren"]?.boolValue ?? true
        // Capped at 25 to keep the JSON payload small enough for the
        // local 3B model to summarize back to the user.
        let limit = max(1, min(Int(props["limit"]?.numberValue ?? 10), 25))

        let notes = try index.notes(withTag: tag, includeChildren: includeChildren, limit: limit)
        let rows: [JSONValue] = notes.map { n in
            .object([
                "path":       .string(n.path),
                "title":      .string(n.title),
                "modifiedAt": .string(VaultToolFormatting.iso(n.modifiedAt)),
            ])
        }
        let citations: [JSONValue] = try notes.compactMap { n in
            try index.citation(forPath: n.path)?.jsonValue
        }
        return .object([
            "tag":       .string(tag),
            "notes":     .array(rows),
            "citations": .array(citations),
        ])
    }
}
