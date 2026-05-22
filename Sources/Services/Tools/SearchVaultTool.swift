import Foundation

/// Phase C flagship retrieval tool. Returns notes whose title or body
/// matches `query`, optionally narrowed by tag or folder. Output shape
/// follows phase-b.md §7.1 — every hit also surfaces a `Citation` row
/// consumed by the Sources card.
///
/// Implementation lives in `VaultIndex.search`: FTS5 BM25 (title × 10,
/// body × 1) with vocab-corrected typo tolerance, two-pass AND→OR
/// fallback, fuzzy-title last-resort, and a frecency multiplier on top.
struct SearchVaultTool: Tool {
    let name = "search_vault"
    let description = """
    Free-text keyword search across the vault. Use for: 'find / \
    search / look up notes about X', 'what's the note that says…', \
    'what have I written about X'. Title + body BM25 with typo \
    tolerance. Optional `tag` and `folder` NARROW a keyword query.

    Do NOT use for tag-only or list-only prompts ('show me notes \
    tagged X', 'what's tagged X', 'list my #X notes', 'what notes \
    do I have') — those go to browse_vault. Only call when there's \
    an actual keyword to match against text.

    After this returns, REPLY to the user directly using the \
    snippets — do NOT chain into read_note unless the user \
    explicitly asks to read the body of a specific note.
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
        // Single payload: `citations` is both the model-visible result
        // list and the UI Sources-card source of truth. Previously we
        // duplicated the same per-hit data as a `results` array; on
        // the AFM 4096-token window that duplication was overflowing
        // the second-pass generation on title-heavy queries.
        let citations: [JSONValue] = hits.map { hit in
            Citation(
                path: hit.summary.path,
                title: hit.summary.title,
                snippet: Self.trimmedSnippet(hit.snippet),
                score: hit.score
            ).jsonValue
        }
        return .object([
            "query":     .string(query),
            "citations": .array(citations),
        ])
    }
}

private extension Int {
    /// Clamp to 1…50 to keep a runaway model from asking for 1000 hits.
    var clampedToSearchLimit: Int { Swift.max(1, Swift.min(self, 50)) }
}

private extension SearchVaultTool {
    /// Cap each per-hit snippet at ~80 chars (≈20 tokens). The Sources
    /// card only needs a one-line preview, and the model wastes tokens
    /// re-reading long body excerpts when the title already conveys
    /// what the note is.
    static func trimmedSnippet(_ raw: String) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if collapsed.count <= 80 { return collapsed }
        return String(collapsed.prefix(80)) + "…"
    }
}
