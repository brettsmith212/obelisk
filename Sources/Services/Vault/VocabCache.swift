import Foundation

/// In-memory snapshot of every term currently in the FTS5 index. Backs
/// the typo-correction step in [QueryParser](./QueryParser.swift) per
/// phase-c.md §3.1 / §6.
///
/// Build cost is dominated by walking the FTS5 vocab aux table
/// (`notes_fts_v`) — ~20ms for a 5k-note vault. We pay it once per
/// "dirty" cycle (scanner reports an upsert batch) and on first query
/// if it was never built, then read it many times across subsequent
/// queries.
///
/// Concurrency: the cache is a value snapshot (immutable after
/// construction). `VaultIndex` rebuilds it under its own
/// `DatabaseQueue.read` so there's no shared mutable state to guard.
struct VocabCache: Sendable {
    /// Lowercased terms. Lookup uses a `Set` for O(1) contains, plus
    /// a flat array for the nearest-neighbor scan.
    private let termSet: Set<String>
    private let termsByLength: [Int: [String]]

    init(terms: [String]) {
        // Normalize once; downstream callers always lowercase before
        // probing.
        let normalized = terms.map { $0.lowercased() }
        self.termSet = Set(normalized)
        var bucketed: [Int: [String]] = [:]
        for term in self.termSet {
            bucketed[term.count, default: []].append(term)
        }
        self.termsByLength = bucketed
    }

    /// Total unique terms in the cache. Reported in DEBUG logs for the
    /// validation step.
    var count: Int { termSet.count }

    /// O(1) membership check. Tokens already in vocab skip correction.
    func contains(_ term: String) -> Bool {
        termSet.contains(term)
    }

    /// Nearest in-vocabulary term within `maxDistance` Levenshtein
    /// distance. Returns `nil` if no candidate qualifies. Walks only
    /// the buckets whose length is within `maxDistance` of the target
    /// (the metric's own lower bound) so we don't scan the whole
    /// vocab for short tokens.
    func nearest(to token: String, maxDistance: Int) -> String? {
        guard maxDistance >= 1 else { return nil }
        let lengthRange = (token.count - maxDistance)...(token.count + maxDistance)

        var best: String?
        var bestDistance = maxDistance + 1

        for len in lengthRange {
            guard let bucket = termsByLength[len] else { continue }
            for candidate in bucket {
                if candidate == token { return candidate }
                let d = Self.boundedLevenshtein(token, candidate, bound: bestDistance)
                if d < bestDistance {
                    bestDistance = d
                    best = candidate
                    if d == 1 { return best } // can't beat distance 1
                }
            }
        }
        return best
    }

    // MARK: - Levenshtein with early-exit bound

    /// Wagner–Fischer Levenshtein with an optimistic bound. Returns
    /// `bound` (the input cap) when the partial-row minimum already
    /// exceeds it — avoids finishing rows we'd discard anyway. Plenty
    /// fast for vocabularies ≤ ~50k terms; if growth pushes us past
    /// that we'd swap to a BK-tree per phase-c.md §6 step 6.
    static func boundedLevenshtein(_ a: String, _ b: String, bound: Int) -> Int {
        let aChars = Array(a)
        let bChars = Array(b)
        let aCount = aChars.count
        let bCount = bChars.count

        if abs(aCount - bCount) >= bound { return bound }
        if aCount == 0 { return min(bCount, bound) }
        if bCount == 0 { return min(aCount, bound) }

        var previous = Array(0...bCount)
        var current = Array(repeating: 0, count: bCount + 1)

        for i in 1...aCount {
            current[0] = i
            var rowMin = current[0]
            for j in 1...bCount {
                let cost = aChars[i - 1] == bChars[j - 1] ? 0 : 1
                let value = min(
                    previous[j] + 1,        // deletion
                    current[j - 1] + 1,     // insertion
                    previous[j - 1] + cost  // substitution
                )
                current[j] = value
                if value < rowMin { rowMin = value }
            }
            if rowMin >= bound { return bound }
            swap(&previous, &current)
        }
        return min(previous[bCount], bound)
    }
}
