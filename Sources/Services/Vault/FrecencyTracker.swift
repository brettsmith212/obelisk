import Foundation
import GRDB

/// Write + read side of the `note_opens` frecency table introduced in
/// phase-c.md §8. Owned by the same `DatabaseQueue` as `VaultIndex`,
/// kept as a thin wrapper so the search method can ask for a per-path
/// score without re-encoding the SQL.
///
/// Concurrency: `recordOpen` is fire-and-forget — callers dispatch it
/// from UI tap handlers on a detached utility-priority task to keep
/// taps responsive. The read side runs synchronously inside
/// `VaultIndex.search`'s read transaction.
struct FrecencyTracker: Sendable {
    /// Where the open happened. Used for diagnostics; doesn't affect
    /// ranking today. See phase-c.md §8.
    enum Source: String, Sendable {
        case sourcesTap   = "sources_tap"
        case wikilink
        case readNote     = "read_note"
        case dailyNote    = "daily_note"
    }

    /// 10-day half-life: λ = ln(2) / 10 ≈ 0.0693 per day. A score
    /// captured this way decays to 0.25 after ~20 days, 0.125 after
    /// ~30, etc.
    static let halfLifeDays: Double = 10
    static let lambda: Double = 0.6931471805599453 / halfLifeDays

    /// We only ever look at opens in the trailing 90-day window. Anything
    /// older contributes ≈ 0.002 weight at λ above and is pruned by the
    /// cleanup task on launch.
    static let lookbackDays: Double = 90

    /// Above 10 raw opens, returns diminishing. Prevents one reflexive
    /// favorite from dominating every result list.
    static let rawScoreCap: Double = 10

    /// Final BM25 multiplier ceiling: +150%.
    static let frecencyBoostCap: Double = 1.5

    /// Frecency boost coefficient — `boost = min(score * coef, cap)`.
    static let frecencyBoostCoefficient: Double = 0.3

    private let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Writes

    /// One synchronous INSERT. Cheap (single row, indexed); callers
    /// still dispatch from a detached task to keep UI taps off the
    /// GRDB queue. Errors are swallowed — frecency is best-effort.
    func recordOpen(path: String, source: Source, at date: Date = Date()) {
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: "INSERT INTO note_opens (path, opened_at, source) VALUES (?, ?, ?)",
                    arguments: [path, date, source.rawValue]
                )
            }
        } catch {
            #if DEBUG
            print("[FrecencyTracker] recordOpen failed for \(path): \(error)")
            #endif
        }
    }

    // MARK: - Reads

    /// Raw frecency score for `path` — the sum of exponentially-decayed
    /// open events in the lookback window, capped above `rawScoreCap`.
    /// Pure function of the database; safe to call from any GRDB read
    /// transaction.
    func rawScore(db: Database, path: String, now: Date = Date()) throws -> Double {
        let cutoff = now.addingTimeInterval(-Self.lookbackDays * 86_400)
        let rows = try Row.fetchAll(
            db,
            sql: "SELECT opened_at FROM note_opens WHERE path = ? AND opened_at >= ?",
            arguments: [path, cutoff]
        )
        var raw: Double = 0
        for row in rows {
            guard let openedAt: Date = row["opened_at"] else { continue }
            let days = max(0, now.timeIntervalSince(openedAt) / 86_400)
            raw += exp(-Self.lambda * days)
        }
        if raw > Self.rawScoreCap {
            return Self.rawScoreCap + sqrt(raw - Self.rawScoreCap)
        }
        return raw
    }

    /// BM25 multiplier derived from the raw score: `1 + boost`, with
    /// `boost = min(rawScore * coef, cap)`. A note never opened
    /// returns 1.0 (no boost).
    static func bm25Multiplier(rawScore: Double) -> Double {
        let boost = min(rawScore * frecencyBoostCoefficient, frecencyBoostCap)
        return 1 + boost
    }

    // MARK: - Maintenance

    /// Drop `note_opens` rows older than the lookback window. Cheap and
    /// idempotent; called once per app launch from a low-priority task.
    func pruneOldOpens(now: Date = Date()) {
        let cutoff = now.addingTimeInterval(-Self.lookbackDays * 86_400)
        do {
            try dbQueue.write { db in
                try db.execute(
                    sql: "DELETE FROM note_opens WHERE opened_at < ?",
                    arguments: [cutoff]
                )
            }
        } catch {
            #if DEBUG
            print("[FrecencyTracker] pruneOldOpens failed: \(error)")
            #endif
        }
    }
}
