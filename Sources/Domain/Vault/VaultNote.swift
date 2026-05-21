import Foundation

/// In-memory projection of a single vault note, produced by `VaultScanner`
/// after parsing and consumed by `VaultIndex` for persistence and by the
/// read tools for query responses.
///
/// `path` is always vault-relative (e.g. `"Daily Notes/2026-05-19.md"`),
/// never absolute. The absolute URL is reconstructed by joining against
/// `VaultHandle.rootURL` at I/O time so the index stays portable across
/// app reinstalls / vault re-picks.
struct VaultNote: Equatable, Sendable {
    /// Vault-relative POSIX path. Forward slashes, case-sensitive.
    let path: String

    /// First H1, else frontmatter `title`, else filename without `.md`.
    let title: String

    /// Markdown body with frontmatter stripped.
    let body: String

    /// Parsed frontmatter as a JSON-shaped dictionary. Empty if the note
    /// has no frontmatter or the frontmatter failed to parse.
    let frontmatter: [String: JSONValue]

    /// Normalized tags (lowercased, no leading `#`), de-duplicated across
    /// frontmatter and inline sources. The original source for each tag
    /// is preserved separately so we can persist `tags.source` correctly.
    let tags: [TagOccurrence]

    /// Wikilink references in order of appearance.
    let outboundLinks: [Wikilink]

    /// SHA-256 of the raw file bytes, lowercase hex (64 chars). Used by
    /// the incremental scanner to decide whether the note needs re-parsing.
    let contentHash: String

    /// File modification timestamp from `URLResourceKey.contentModificationDate`.
    /// Cheap pre-filter only — `contentHash` is the source of truth.
    let modifiedAt: Date

    struct TagOccurrence: Equatable, Sendable {
        let tag: String
        let source: Source

        enum Source: String, Sendable {
            case frontmatter
            case inline
        }
    }
}
