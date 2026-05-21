import Foundation

/// Return notes that wikilink into a target note. Resolution uses the
/// `links.target_path` column populated by `VaultScanner` — unresolved
/// links (those whose target name didn't match any note) are
/// intentionally omitted.
struct GetBacklinksTool: Tool {
    let name = "get_backlinks"
    let description = """
    List notes that link to the given note via [[Wikilinks]]. Useful for \
    'what mentions [[Foo]]?' or 'which notes reference [[Bar]]'.
    """
    let argumentsSchema: JSONSchema = .object(
        properties: [
            "path":  .string(description: "Vault-relative path of the target note."),
            "limit": .integer(description: "Max backlinks to return. Default 10."),
        ],
        required: ["path"]
    )

    private let index: VaultIndex

    init(index: VaultIndex) {
        self.index = index
    }

    func run(arguments: JSONValue) async throws -> JSONValue {
        guard case .object(let props) = arguments,
              case .string(let path)? = props["path"],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ToolError.invalidArguments("'path' is required.")
        }
        // Capped at 25 so a popular note's 100+ backlinks don't blow the
        // local 3B model's context window when the result is fed back in.
        let limit = max(1, min(Int(props["limit"]?.numberValue ?? 10), 25))

        let backlinks = try index.backlinks(to: path, limit: limit)
        let rows: [JSONValue] = backlinks.map { n in
            .object([
                "path":       .string(n.path),
                "title":      .string(n.title),
                "modifiedAt": .string(VaultToolFormatting.iso(n.modifiedAt)),
            ])
        }
        let citations: [JSONValue] = try backlinks.compactMap { n in
            try index.citation(forPath: n.path)?.jsonValue
        }
        return .object([
            "path":      .string(path),
            "backlinks": .array(rows),
            "citations": .array(citations),
        ])
    }
}
