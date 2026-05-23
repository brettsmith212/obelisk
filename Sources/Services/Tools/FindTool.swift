import Foundation

/// One of the two AFM-realistic vault tools. Surfaces notes — by
/// keyword (search), by recency / folder / tag (browse), or by
/// backlinks. Replaces the old `search_vault`, `browse_vault`, and
/// `get_backlinks` tools so the model has one verb to pick from when
/// the user wants a *list* of notes.
///
/// Dispatch is implicit in argument presence (no `mode` enum — fewer
/// schema tokens, easier for a 3B model to populate):
///   - `linked_to`  → backlinks of that note
///   - `query`      → keyword search (optionally narrowed by tag / folder)
///   - otherwise    → browse newest-modified (optionally narrowed by
///                    tag / folder)
///
/// Output is a flat `notes` array of `{path, title}` plus a parallel
/// `citations` array consumed by the chat UI's Sources card.
struct FindTool: Tool {
    let name = "find"
    let description = "Find vault notes by keyword, tag, folder, or backlinks."
    let argumentsSchema: JSONSchema = .object(
        properties: [
            "query":     .string(description: "Free-text keyword search."),
            "tag":       .string(description: "Tag filter, no '#'."),
            "folder":    .string(description: "Vault-relative folder prefix."),
            "linked_to": .string(description: "Vault-relative path; returns notes that wikilink to it."),
            "limit":     .integer(description: "Max notes. Default 10, cap 10."),
            "offset":    .integer(description: "Skip count for paging browse results."),
        ],
        required: []
    )

    private let index: VaultIndex

    init(index: VaultIndex) {
        self.index = index
    }

    func run(arguments: JSONValue) async throws -> JSONValue {
        let props = arguments.objectValue ?? [:]

        let linkedTo = props["linked_to"]?.stringValue?.trimmedNonEmpty
        let query    = props["query"]?.stringValue?.trimmedNonEmpty
        let tag      = props["tag"]?.stringValue?.trimmedNonEmpty
        let folder   = props["folder"]?.stringValue?.trimmedNonEmpty

        // Hard cap at 10. AFM's 4096-token window can't hold a larger
        // result list plus tool schemas plus the reply.
        let limit  = max(1, min(Int(props["limit"]?.numberValue ?? 10), 10))
        let offset = max(0, Int(props["offset"]?.numberValue ?? 0))

        // 1) Backlinks mode wins if `linked_to` is set.
        if let linkedTo {
            let rows = try index.backlinks(to: linkedTo, limit: limit)
            return Self.envelope(
                notes: rows.map { ($0.path, $0.title) },
                citations: rows.compactMap { (try? index.citation(forPath: $0.path))?.jsonValue }
            )
        }

        // 2) Keyword search if a query is provided.
        if let query {
            let hits = try index.search(query: query, tag: tag, folder: folder, limit: limit)
            return Self.envelope(
                notes: hits.map { ($0.summary.path, $0.summary.title) },
                citations: hits.map {
                    Citation(
                        path: $0.summary.path,
                        title: $0.summary.title,
                        snippet: "",
                        score: $0.score
                    ).jsonValue
                }
            )
        }

        // 3) Browse mode (recency-first) for plain enumeration.
        let page = try index.browse(
            folder: folder,
            tag: tag,
            includeChildTags: true,
            sortBy: .modified,
            limit: limit,
            offset: offset
        )
        let nextOffset = offset + page.notes.count
        let hasMore = nextOffset < page.totalCount
        var out: [String: JSONValue] = [
            "notes": .array(page.notes.map {
                .object([
                    "path":  .string($0.path),
                    "title": .string($0.title),
                ])
            }),
            "citations": .array(page.notes.map {
                Citation(path: $0.path, title: $0.title, snippet: "", score: nil).jsonValue
            }),
            "totalCount": .number(Double(page.totalCount)),
            "hasMore":    .bool(hasMore),
        ]
        if hasMore {
            out["nextOffset"] = .number(Double(nextOffset))
        }
        return .object(out)
    }

    /// Compact two-key envelope (`notes` + `citations`) shared by the
    /// backlinks and search branches. Browse adds pagination keys on
    /// top of it.
    private static func envelope(
        notes: [(path: String, title: String)],
        citations: [JSONValue]
    ) -> JSONValue {
        .object([
            "notes": .array(notes.map {
                .object([
                    "path":  .string($0.path),
                    "title": .string($0.title),
                ])
            }),
            "citations": .array(citations),
        ])
    }
}

private extension String {
    /// Treat empty/whitespace as absent. Lets the tool driver branch
    /// on "did the model actually supply this arg?" without nullable
    /// gymnastics.
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
