import Foundation

/// One citable reference returned by a vault read tool. The Sources card
/// in the chat UI ([ui-spec.md §4.6](../../ui-spec.md)) renders an array
/// of these as tappable rows that deep-link into Obsidian.
///
/// Every read tool that surfaces note content includes a `citations`
/// array in its `ToolResult.output` (per phase-b.md §7.1). Construction
/// is centralized in `VaultIndex.citation(...)` so tools never have to
/// shape the JSON by hand.
struct Citation: Equatable, Sendable, Codable {
    /// Vault-relative POSIX path. Matches `notes.path` in the index.
    let path: String
    /// The note's display title (frontmatter title → first H1 → filename).
    let title: String
    /// Short body excerpt for the card. Best-effort — may be the first
    /// non-empty paragraph for read-style tools or a hit-centered snippet
    /// for search tools.
    let snippet: String
    /// Optional relevance score (0…1). Search tools populate this;
    /// `ReadNoteTool` and friends leave it nil.
    let score: Double?
}

extension Citation {
    /// JSON representation suitable for embedding inside a `ToolResult`'s
    /// `JSONValue` output. The UI walks the citations array via
    /// `output.objectValue?["citations"]`.
    var jsonValue: JSONValue {
        var dict: [String: JSONValue] = [
            "path": .string(path),
            "title": .string(title),
            "snippet": .string(snippet),
        ]
        if let score {
            dict["score"] = .number(score)
        }
        return .object(dict)
    }
}
