import Foundation

/// Free-text query → `SearchQuery` ready for FTS5 (or fuzzy fallback).
///
/// Phase C §6 spells out the algorithm:
/// 1. Pull out quoted phrases (`"long term thinking"`) — they bypass
///    vocab correction.
/// 2. Split the remainder on whitespace.
/// 3. Strip FTS5-significant chars (`:`, `*`, `(`, `)`, `"`, `^`,
///    `~`, `+`, `-`) at boundaries.
/// 4. Drop empty / single-char tokens (`a`, `I` — match too much,
///    slow FTS5).
/// 5. Vocab-correct each token against the live FTS5 vocab.
/// 6. Build a two-pass MATCH expression (AND, then OR fallback).
///
/// `QueryParser` is a pure value type: it owns no state and is safe
/// to recreate per call.
enum QueryParser {
    /// Edit-distance cap for vocab correction. A token of length ≥ 4
    /// is rewritten when (a) some in-vocab token is within
    /// `min(absoluteCap, length/4)` of it and (b) the cap floor of
    /// 1 still admits the small typo. Cap-of-2 keeps proper-noun
    /// false positives ("Obelisk" → "obvious") rare. See
    /// phase-c.md §6 step 6.
    private static let maxCorrectionDistance = 2

    /// Tokens shorter than this aren't put through vocab correction.
    /// They're also dropped from the AND-MATCH expression entirely —
    /// FTS5 hates 1-char tokens (they match almost everything and
    /// thrash the postings list).
    private static let minTokenLength = 2

    /// Bypass vocab correction altogether for tokens shorter than this
    /// (even after we already kept them past `minTokenLength`).
    /// `cat → bat` would be technically allowed at `length/4 = 0` but
    /// we'd rather not call it out as a "did you mean".
    private static let minCorrectionLength = 4

    /// Characters FTS5 will choke on if they appear unescaped inside a
    /// bare-token MATCH expression. We strip them at token boundaries
    /// rather than escaping mid-token because the model rarely uses
    /// them meaningfully — `function(args)` becomes `function args`.
    private static let ftsBoundaryStrip = CharacterSet(charactersIn: ":*()\"^~+-")

    /// Parse `raw` against the supplied vocab. `vocab` may be empty
    /// (cold start) — in that case correction is skipped and we rely
    /// on the OR / fuzzy fallback inside `VaultIndex.search`.
    static func parse(raw: String, vocab: VocabCache?) -> SearchQuery {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SearchQuery(raw: raw, tokens: [], phrases: [], corrections: [:])
        }

        let (phrases, residual) = extractPhrases(from: trimmed)
        let rawTokens = residual
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        var tokens: [String] = []
        var corrections: [String: String] = [:]

        for original in rawTokens {
            let stripped = original
                .trimmingCharacters(in: Self.ftsBoundaryStrip)
                .lowercased()
            guard stripped.count >= minTokenLength else { continue }

            if let vocab, stripped.count >= minCorrectionLength,
               !vocab.contains(stripped) {
                if let corrected = vocab.nearest(
                    to: stripped,
                    maxDistance: distanceBudget(for: stripped)
                ), corrected != stripped {
                    corrections[stripped] = corrected
                    tokens.append(corrected)
                    continue
                }
            }
            tokens.append(stripped)
        }

        return SearchQuery(
            raw: raw,
            tokens: tokens,
            phrases: phrases,
            corrections: corrections
        )
    }

    /// Build an FTS5 MATCH expression from the parsed query.
    /// `mode == .and` produces `(tok1 AND tok2 AND "phrase1")` —
    /// the typical first pass. `mode == .or` produces
    /// `(tok1 OR tok2) AND "phrase1"` — phrases stay required because
    /// users mean them. Returns `nil` when there's nothing to match.
    static func matchExpression(for query: SearchQuery, mode: MatchMode) -> String? {
        var clauses: [String] = []

        if !query.tokens.isEmpty {
            let connector = mode == .and ? " AND " : " OR "
            // Wrap tokens individually so FTS5 treats them as bare
            // terms (no prefix-search confusion with `*` etc.).
            let inner = query.tokens.map(escapeToken).joined(separator: connector)
            clauses.append("(" + inner + ")")
        }

        if !query.phrases.isEmpty {
            let inner = query.phrases.map { "\"" + escapePhrase($0) + "\"" }.joined(separator: " AND ")
            clauses.append("(" + inner + ")")
        }

        guard !clauses.isEmpty else { return nil }
        return clauses.joined(separator: " AND ")
    }

    enum MatchMode {
        case and, or
    }

    // MARK: - Helpers

    /// Pull every `"..."`-quoted span out of the input. Returns the
    /// extracted phrases plus the remainder with the phrases removed
    /// (and replaced with whitespace so downstream tokenization
    /// doesn't fuse adjacent words).
    private static func extractPhrases(from input: String) -> (phrases: [String], residual: String) {
        guard input.contains("\"") else { return ([], input) }

        var phrases: [String] = []
        var residual = ""
        var inQuote = false
        var buffer = ""

        for ch in input {
            if ch == "\"" {
                if inQuote {
                    let trimmed = buffer.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { phrases.append(trimmed) }
                    buffer = ""
                    residual.append(" ")
                } else {
                    residual.append(" ")
                }
                inQuote.toggle()
            } else if inQuote {
                buffer.append(ch)
            } else {
                residual.append(ch)
            }
        }
        // Unterminated quote — fall back to treating the buffer as
        // loose text rather than dropping it.
        if inQuote, !buffer.isEmpty {
            residual.append(" ")
            residual.append(buffer)
        }
        return (phrases, residual)
    }

    /// Per-token Levenshtein budget. Honors the global cap *and*
    /// scales with length so short tokens can't accidentally rewrite
    /// to unrelated short words.
    private static func distanceBudget(for token: String) -> Int {
        max(1, min(maxCorrectionDistance, token.count / 4))
    }

    /// FTS5 wants bare terms to be alphanumeric; anything weirder we
    /// wrap as a quoted phrase to avoid syntax errors. Unicode tokens
    /// without operators are safe as-is.
    private static func escapeToken(_ token: String) -> String {
        if token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            return token
        }
        return "\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// FTS5 phrase strings double up embedded quotes.
    private static func escapePhrase(_ phrase: String) -> String {
        phrase.replacingOccurrences(of: "\"", with: "\"\"")
    }
}
