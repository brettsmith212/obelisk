import Foundation

/// A parsed, validated, and (where applicable) vocab-corrected query
/// destined for `VaultIndex.search`. Built once by `QueryParser.parse`
/// and consumed by both the FTS5 path and the fuzzy-title fallback.
///
/// Why a value type instead of just passing the raw string around:
/// - Vocab correction happens up front, *before* we hit FTS5. Carrying
///   the parsed result keeps the search method honest about what it's
///   actually matching against.
/// - `corrections` lets the UI / DEBUG logs surface "did you mean…"
///   without re-running the parser.
/// - Phrases (`"long term thinking"`) and tokens have different
///   semantics — phrases bypass vocab correction entirely (users mean
///   them literally per phase-c.md §6 step 1).
struct SearchQuery: Equatable, Sendable {
    /// Verbatim string the caller passed in. Useful for snippet
    /// generation and for logging.
    let raw: String

    /// Whitespace-split tokens after stripping FTS5-significant chars
    /// and applying vocab correction. Always lowercased.
    let tokens: [String]

    /// Quoted phrases pulled out before tokenization. Stored without
    /// the surrounding quotes; rendered back into FTS5 as `"…"` at
    /// expression-build time.
    let phrases: [String]

    /// `original → corrected` map for the tokens that vocab correction
    /// rewrote. The UI doesn't surface these yet; logging them in
    /// DEBUG is what the typo validation step in phase-c.md §11 relies
    /// on.
    let corrections: [String: String]

    /// True when the parser couldn't produce a single usable token or
    /// phrase. `VaultIndex.search` short-circuits to an empty result
    /// in this case.
    var isEmpty: Bool {
        tokens.isEmpty && phrases.isEmpty
    }
}
