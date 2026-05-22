import Foundation

/// Last-resort title matcher used when FTS5 — even after vocab
/// correction and the OR fallback — comes up empty. See
/// [phase-c.md §7](../../phase-c.md): exists to catch the badly
/// misspelled single-token "find the note called X" lookup, the cold
/// vocab-cache case, and titles that are genuinely outside the FTS5
/// vocabulary (short titles dropped by `QueryParser.minTokenLength`).
///
/// Why not fuzzy-match everything? Brute-force fuzzy over 5k notes ×
/// full body would be too slow for typing-speed search and ranks
/// poorly (no IDF, no field weighting, no BM25). FTS5 + vocab
/// correction does the heavy lifting; this is the safety net.
enum FuzzyTitleMatcher {
    struct Match: Equatable, Sendable {
        let path: String
        let title: String
        let score: Double
    }

    /// Minimum normalized similarity to keep a candidate. Tuned
    /// generously — anything below this is too noisy to surface as
    /// "did you mean".
    static let minimumScore: Double = 0.6

    /// Rank `titles` by edit-distance-based similarity against `query`.
    /// Returns the top `limit` matches with `score ≥ minimumScore`,
    /// sorted descending.
    static func match(
        query: String,
        titles: [(path: String, title: String)],
        limit: Int = 8
    ) -> [Match] {
        let needle = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return [] }

        var hits: [Match] = []
        hits.reserveCapacity(min(limit * 4, titles.count))

        for entry in titles {
            let haystack = entry.title.lowercased()
            guard !haystack.isEmpty else { continue }
            let denom = max(needle.count, haystack.count)
            // We only need the cheap upper bound on distance: once it
            // exceeds the threshold to clear minimumScore, the candidate
            // is dead. `bound = denom * (1 - minimumScore) + 1` is the
            // smallest distance that would still pass; anything higher
            // we discard.
            let maxAllowedDistance = max(1, Int(ceil(Double(denom) * (1 - minimumScore)))) + 1
            let distance = VocabCache.boundedLevenshtein(
                needle,
                haystack,
                bound: maxAllowedDistance
            )
            let score = 1.0 - Double(distance) / Double(denom)
            if score >= minimumScore {
                hits.append(Match(path: entry.path, title: entry.title, score: score))
            }
        }

        hits.sort { $0.score > $1.score }
        return Array(hits.prefix(limit))
    }
}
