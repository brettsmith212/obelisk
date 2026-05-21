import Foundation

/// Phase B's flagship retrieval tool. Returns notes whose title or body
/// matches `query`, optionally narrowed by tag or folder. Output shape
/// follows phase-b.md §7 + §7.1 — every hit also surfaces a `Citation`
/// row consumed by the Sources card.
///
/// Implementation is a naive `LIKE` scan against the GRDB index (see
/// `VaultIndex.search`). Phase C replaces the body with semantic
/// retrieval but keeps the JSON shape identical so the UI is unaffected.
struct SearchVaultTool: Tool {
    let name = "search_vault"
    let description = """
    Search the user's Obsidian vault for notes whose title or body \
    matches a free-text query. Optional 'tag' narrows to notes carrying \
    that tag (hierarchical, so 'project' includes 'project/obelisk'). \
    Optional 'folder' narrows to a vault subfolder. Use this whenever \
    the user asks about something in their notes.
    """
    let argumentsSchema: JSONSchema = .object(
        properties: [
            "query":  .string(description: "Free-text query."),
            "tag":    .string(description: "Optional tag to narrow by (no '#' needed)."),
            "folder": .string(description: "Optional vault-relative folder prefix."),
            "limit":  .integer(description: "Max results to return. Default 8."),
        ],
        required: ["query"]
    )

    private let index: VaultIndex

    init(index: VaultIndex) {
        self.index = index
    }

    func run(arguments: JSONValue) async throws -> JSONValue {
        guard case .object(let props) = arguments,
              case .string(let query)? = props["query"],
              !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ToolError.invalidArguments("'query' is required.")
        }
        let tag: String? = props["tag"]?.stringValue
        let folder: String? = props["folder"]?.stringValue
        let limit = Int(props["limit"]?.numberValue ?? 8).clampedToSearchLimit

        let hits = try index.search(query: query, tag: tag, folder: folder, limit: limit)
        let results: [JSONValue] = hits.map { hit in
            .object([
                "path":    .string(hit.summary.path),
                "title":   .string(hit.summary.title),
                "snippet": .string(hit.snippet),
                "score":   .number(hit.score),
            ])
        }
        let citations: [JSONValue] = hits.map { hit in
            Citation(
                path: hit.summary.path,
                title: hit.summary.title,
                snippet: hit.snippet,
                score: hit.score
            ).jsonValue
        }
        return .object([
            "query":     .string(query),
            "results":   .array(results),
            "citations": .array(citations),
        ])
    }
}

private extension Int {
    /// Clamp to 1…50 to keep a runaway model from asking for 1000 hits.
    var clampedToSearchLimit: Int { Swift.max(1, Swift.min(self, 50)) }
}
