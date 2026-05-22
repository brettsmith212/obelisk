import Foundation

/// Paginated enumeration over the indexed vault. Absorbs the
/// responsibilities of the removed `list_recent_notes` and
/// `list_notes_by_tag` tools (phase-c.md §5.2 / §5.3):
///
/// - "What notes do I have?" → defaults (sortBy=modified, limit=25).
/// - "What's in my Projects folder?" → folder='Projects'.
/// - "Show me my #project notes" → tag='project'.
/// - "What have I been working on lately?" → sortBy='modified'.
///
/// Returns one page plus the total candidate count so the model can
/// reason about whether to ask for more via `offset`.
struct BrowseVaultTool: Tool {
    let name = "browse_vault"
    let description = """
    Enumerate notes in the vault. Use for: 'what notes do I have', \
    'list my notes', 'recent notes', 'what have I been working on', \
    'what's in my <folder> folder', 'show me my #X notes', 'what's \
    tagged X', 'browse my vault'. Default sort: newest-modified.

    Only set `folder` or `tag` when the user explicitly names one \
    ('Projects folder', '#project', 'tagged X'). 'Working on' is \
    NOT a tag — it means sort by modified.

    Returns ≤10 notes plus totalCount, nextOffset, hasMore. Call at \
    most ONCE per turn (the dispatcher will reject a second call). \
    For 'show me 30' or 'all my notes': return 10 + say there are \
    <totalCount> total + invite 'more'. For 'more' / 'next page': \
    call once with offset=<previous nextOffset>. Reply concisely — \
    a short line per note keeps responses inside the context window.

    For keyword search use search_vault.
    """
    let argumentsSchema: JSONSchema = .object(
        properties: [
            "folder": .string(
                description: "Optional vault-relative folder prefix (e.g. 'Projects', 'Daily Notes')."
            ),
            "tag": .string(
                description: "Optional tag to filter by (no leading '#' required; e.g. 'project' or 'project/work')."
            ),
            "includeChildTags": .boolean(
                description: "When 'tag' is set, also include hierarchical children (e.g. tag='project' matches 'project/work'). Default true."
            ),
            "sortBy": .string(
                description: "How to sort: 'modified' (newest first) or 'title' (A→Z). Default 'modified'.",
                enumValues: ["modified", "title"]
            ),
            "limit": .integer(
                description: "Max notes to return per page. Default 10, hard cap 10 (values above 10 are clamped). The cap exists because larger payloads overflow the on-device model's context window."
            ),
            "offset": .integer(
                description: "Number of notes to skip. Default 0. To fetch the next page, set offset = nextOffset from the previous response."
            ),
        ],
        required: []
    )

    private let index: VaultIndex

    init(index: VaultIndex) {
        self.index = index
    }

    func run(arguments: JSONValue) async throws -> JSONValue {
        let props = arguments.objectValue ?? [:]

        let folder = props["folder"]?.stringValue
        let tag = props["tag"]?.stringValue
        let includeChildTags = props["includeChildTags"]?.boolValue ?? true

        let sortBy: VaultIndex.BrowseSort = {
            let raw = props["sortBy"]?.stringValue?.lowercased() ?? ""
            return VaultIndex.BrowseSort(rawValue: raw) ?? .modified
        }()

        // Hard-cap at 10 (default 10). AFM's 4096-token window can't
        // hold a larger response plus tool schemas plus the model's
        // own paraphrased reply, especially across multiple turns
        // where the previous reply is replayed in the transcript.
        // Phase C accepts the constraint: pagination is "next page",
        // not "collect everything in one turn".
        let limit = max(1, min(Int(props["limit"]?.numberValue ?? 10), 10))
        let offset = max(0, Int(props["offset"]?.numberValue ?? 0))

        let page = try index.browse(
            folder: folder,
            tag: tag,
            includeChildTags: includeChildTags,
            sortBy: sortBy,
            limit: limit,
            offset: offset
        )

        // Compact rows: omit modifiedAt for `title` sorts (the sort
        // order already conveys it) — keeps the JSON payload small
        // enough to survive the AFM 4096-token context.
        let rows: [JSONValue] = page.notes.map { n in
            var row: [String: JSONValue] = [
                "path":  .string(n.path),
                "title": .string(n.title),
            ]
            if sortBy == .modified {
                row["modifiedAt"] = .string(VaultToolFormatting.iso(n.modifiedAt))
            }
            return .object(row)
        }
        // Citations carry the Sources-card metadata. For enumeration
        // we drop the snippet — there's no query context to anchor it
        // to, and the per-row token cost adds up fast across 10–25
        // notes. The Sources card already handles empty snippets
        // gracefully (renders just the title).
        let citations: [JSONValue] = page.notes.map { n in
            Citation(path: n.path, title: n.title, snippet: "", score: nil).jsonValue
        }
        let nextOffset = offset + page.notes.count
        let hasMore = nextOffset < page.totalCount
        return .object([
            "notes":      .array(rows),
            "totalCount": .number(Double(page.totalCount)),
            "offset":     .number(Double(offset)),
            "limit":      .number(Double(limit)),
            "hasMore":    .bool(hasMore),
            "nextOffset": .number(Double(nextOffset)),
            "citations":  .array(citations),
        ])
    }
}
