import Foundation

/// A single `[[Wikilink]]` reference extracted from a note's body.
///
/// Obsidian's wikilink grammar (the subset we care about):
///
///     [[Target]]                  // simple
///     [[Target|Display]]          // with display label
///     [[Target#Heading]]          // heading reference
///     [[Target#Heading|Display]]
///     [[Target^block]]            // block reference
///     [[Target^block|Display]]
///
/// `target` is the raw text before `#` / `^` / `|`. Resolution to a
/// concrete note path happens later in `VaultScanner` once every note
/// has been indexed (so we can apply Obsidian's "shortest unique name"
/// rule).
struct Wikilink: Equatable, Sendable {
    /// The note name as written, before `#`, `^`, or `|`.
    /// e.g. `[[Foo/Bar#Heading|Label]]` → `"Foo/Bar"`.
    let target: String

    /// Heading anchor (`#…`), if present, without the leading `#`.
    let heading: String?

    /// Block anchor (`^…`), if present, without the leading `^`.
    let block: String?

    /// Display label (`|…`), if present.
    let displayLabel: String?

    /// The exact text between `[[` and `]]`, preserved for re-rendering.
    let raw: String
}
