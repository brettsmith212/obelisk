import Foundation
import GRDB

/// SQLite-backed projection of the parsed vault. Owned by the app for
/// the lifetime of the active vault binding; queried by the read tools
/// in Phase B and the embedding pipeline in Phase C.
///
/// Concurrency: all access goes through GRDB's `DatabaseQueue`, which
/// serializes reads and writes on its own thread. `VaultIndex` itself
/// is reference-typed and safe to share across actors — but each call
/// blocks until GRDB drains its queue.
///
/// The schema lives in `VaultIndexSchema.swift`; this file is queries
/// plus the small DTOs they exchange with the scanner.
final class VaultIndex {
    private let dbQueue: DatabaseQueue

    /// Cached lazy vocab snapshot. Invalidated by `markVocabDirty()`
    /// (called by the scanner after a non-trivial upsert batch) and
    /// rebuilt on first query that needs it. Guarded by `vocabLock` —
    /// we never mutate the snapshot itself, only swap the optional.
    private var cachedVocab: VocabCache?
    private let vocabLock = NSLock()

    /// Frecency reader/writer over the same `DatabaseQueue`. Owned
    /// here so tools and the scanner can share one instance and the
    /// search path can call `rawScore` inside its own read txn.
    let frecency: FrecencyTracker

    /// Persists at `Documents/vault-index.sqlite`. One DB per app install;
    /// switching vaults wipes and rebuilds (vault identity = the active
    /// security-scoped bookmark, not anything in this DB).
    init(databaseURL: URL) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        self.dbQueue = try DatabaseQueue(path: databaseURL.path(), configuration: config)
        try VaultIndexSchema.makeMigrator().migrate(dbQueue)
        self.frecency = FrecencyTracker(dbQueue: dbQueue)
    }

    // MARK: - Writes (used by VaultScanner)

    /// Upsert a parsed note plus its links and tags atomically. Existing
    /// rows for the same `path` are replaced, including all link/tag
    /// fanout.
    func upsert(
        note: VaultNote,
        resolvedLinks: [ResolvedLink],
        indexedAt: Date
    ) throws {
        try dbQueue.write { db in
            try Self.upsertNote(db, note: note, indexedAt: indexedAt)
            try Self.replaceLinks(db, sourcePath: note.path, resolved: resolvedLinks)
            try Self.replaceTags(db, path: note.path, tags: note.tags)
        }
    }

    /// Delete a note and (via cascade) all its links and tags.
    func deleteNote(path: String) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM notes WHERE path = ?", arguments: [path])
        }
    }

    /// Bulk-resolve previously-unresolved outbound links once every note
    /// has been indexed. Used at the tail of a full scan when we have
    /// the complete name → path map.
    func resolveOutboundLinks(using nameMap: [String: String]) throws {
        // Cheap path: rebuild target_path by joining on target_raw's
        // base portion. The scanner handles ambiguous names — by the
        // time we're here, `nameMap` already encodes the resolution.
        try dbQueue.write { db in
            for (rawName, resolvedPath) in nameMap {
                try db.execute(
                    sql: """
                        UPDATE links
                        SET target_path = ?
                        WHERE target_path IS NULL AND target_raw = ?
                        """,
                    arguments: [resolvedPath, rawName]
                )
            }
        }
    }

    // MARK: - Reads (used by VaultScanner and, later, the read tools)

    /// Snapshot of every indexed note's `(path, content_hash)`. The
    /// incremental scanner diffs the live filesystem against this map.
    func existingHashes() throws -> [String: String] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT path, content_hash FROM notes")
            var out: [String: String] = [:]
            out.reserveCapacity(rows.count)
            for row in rows {
                if let path: String = row["path"], let hash: String = row["content_hash"] {
                    out[path] = hash
                }
            }
            return out
        }
    }

    /// Total note count. Used by the Vault settings sheet and by
    /// debug diagnostics during Phase B bring-up.
    func noteCount() throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM notes") ?? 0
        }
    }

    // MARK: - Tool queries

    /// One full note, hydrated for `ReadNoteTool`.
    struct NoteRecord: Equatable, Sendable {
        let path: String
        let title: String
        let body: String
        let frontmatter: [String: JSONValue]
        let modifiedAt: Date
    }

    /// Lightweight projection for list-style tool results
    /// (`BrowseVaultTool`, `GetBacklinksTool`).
    struct NoteSummary: Equatable, Sendable {
        let path: String
        let title: String
        let modifiedAt: Date
    }

    /// A search hit with a pre-cut snippet.
    struct SearchHit: Equatable, Sendable {
        let summary: NoteSummary
        let snippet: String
        let score: Double
    }

    /// Read a single note by path. Returns `nil` if no such note is
    /// indexed (caller surfaces a friendly tool error).
    func note(at path: String) throws -> NoteRecord? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT path, title, body, frontmatter, modified_at FROM notes WHERE path = ?",
                arguments: [path]
            ) else { return nil }
            return Self.noteRecord(from: row)
        }
    }

    /// Resolve a user-supplied "what is this note?" string to a
    /// vault-relative path. Accepts:
    ///   - a real vault path (returned as-is if it matches `notes.path`)
    ///   - a `[[Wikilink]]` (brackets stripped, then title-resolved)
    ///   - a bare title (case-insensitive match against `notes.title`,
    ///     `.md` suffix stripped)
    ///
    /// Used by `FindTool` so the model can pass "Master Branch" without
    /// having to know whether the note lives in the vault root or in a
    /// subfolder — AFM cannot make that distinction without a lookup
    /// tool of its own, and we cap at one tool call per turn.
    ///
    /// Title collisions: returns the first matching path; if the user
    /// has two notes with the same title in different folders we
    /// arbitrarily pick the older one (path ASC) for now. Acceptable
    /// until dogfooding surfaces a real conflict.
    func resolveNotePath(forTitleOrPath raw: String) throws -> String? {
        let cleaned = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "[[", with: "")
            .replacingOccurrences(of: "]]", with: "")
            .trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }

        return try dbQueue.read { db in
            // Exact-path hit (with or without `.md` suffix).
            if let path: String = try String.fetchOne(
                db,
                sql: "SELECT path FROM notes WHERE path = ? LIMIT 1",
                arguments: [cleaned]
            ) {
                return path
            }
            let withMD = cleaned.hasSuffix(".md") ? cleaned : cleaned + ".md"
            if withMD != cleaned,
               let path: String = try String.fetchOne(
                db,
                sql: "SELECT path FROM notes WHERE path = ? LIMIT 1",
                arguments: [withMD]
               ) {
                return path
            }
            // Title fallback. Strip `.md` so users can pass either
            // shape and a case-insensitive compare so "master branch"
            // matches "Master Branch".
            let titleGuess = cleaned.hasSuffix(".md")
                ? String(cleaned.dropLast(3))
                : cleaned
            return try String.fetchOne(
                db,
                sql: """
                    SELECT path FROM notes
                    WHERE LOWER(title) = LOWER(?)
                    ORDER BY path ASC
                    LIMIT 1
                    """,
                arguments: [titleGuess]
            )
        }
    }

    /// Backlinks to a given note (any other note whose `links.target_path`
    /// resolved to this path). Unresolved links are intentionally
    /// excluded — we don't know the user meant *this* note.
    func backlinks(to path: String, limit: Int) throws -> [NoteSummary] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT n.path, n.title, n.modified_at
                    FROM links l
                    JOIN notes n ON n.path = l.source_path
                    WHERE l.target_path = ?
                    ORDER BY n.modified_at DESC
                    LIMIT ?
                    """,
                arguments: [path, limit]
            )
            return rows.map(Self.noteSummary(from:))
        }
    }

    /// FTS5-backed search across title + body with BM25 ranking, a
    /// title-weight multiplier of 10, vocab-corrected typo handling,
    /// a two-pass AND→OR strategy, and a fuzzy-title last-resort. All
    /// surviving hits get a frecency boost layered on top.
    ///
    /// Behavior contract — phase-c.md §5.1:
    /// 1. Build `SearchQuery` via `QueryParser` (vocab correction first).
    /// 2. Try `(t1 AND t2 …)` MATCH expression.
    /// 3. If zero rows, retry with `(t1 OR t2 …)`.
    /// 4. If still zero, fall through to `FuzzyTitleMatcher` over
    ///    titles only.
    /// 5. For every hit, multiply BM25 score by `(1 + frecencyBoost)`
    ///    where boost is capped at +150%.
    ///
    /// The `tag` and `folder` filters narrow the FTS5 candidate set
    /// via SQL joins; they don't apply to the fuzzy stage (titles are
    /// path-keyed but tag filtering would defeat the safety-net
    /// purpose).
    func search(
        query: String,
        tag: String?,
        folder: String?,
        limit: Int
    ) throws -> [SearchHit] {
        let vocab = ensureVocab()
        let parsed = QueryParser.parse(raw: query, vocab: vocab)
        guard !parsed.isEmpty else { return [] }

        #if DEBUG
        if !parsed.corrections.isEmpty {
            print("[VaultIndex.search] corrections: \(parsed.corrections)")
        }
        #endif

        return try dbQueue.read { db in
            // First pass — AND. Models faithfully echo the user's
            // tokens; vocab correction already normalized typos, so
            // an AND with title-weighted BM25 is the right default.
            var hits = try runFTS(
                db,
                query: parsed,
                tag: tag,
                folder: folder,
                mode: .and,
                limit: limit
            )
            if hits.isEmpty {
                hits = try runFTS(
                    db,
                    query: parsed,
                    tag: tag,
                    folder: folder,
                    mode: .or,
                    limit: limit
                )
            }
            if hits.isEmpty {
                hits = try runFuzzyTitleFallback(
                    db,
                    parsed: parsed,
                    tag: tag,
                    folder: folder,
                    limit: limit
                )
            }
            return hits
        }
    }

    // MARK: - Browse

    /// How `browse(...)` orders the returned notes.
    enum BrowseSort: String, Sendable {
        case modified
        case title
    }

    /// One page of `browse_vault` plus the total count needed to drive
    /// pagination UX. See `BrowseVaultTool`.
    struct BrowsePage: Equatable, Sendable {
        let notes: [NoteSummary]
        let totalCount: Int
    }

    /// Paginated enumeration over the notes table, optionally filtered
    /// by folder prefix and/or tag. Powers `browse_vault` (phase-c.md
    /// §5.2) and replaces the two removed Phase-B enumeration tools.
    func browse(
        folder: String?,
        tag: String?,
        includeChildTags: Bool,
        sortBy: BrowseSort,
        limit: Int,
        offset: Int
    ) throws -> BrowsePage {
        let normalizedFolder = folder?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let normalizedTag = tag?.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "# /"))

        return try dbQueue.read { db in
            var args: [DatabaseValueConvertible] = []
            var joins = ""
            var clauses: [String] = []

            if let normalizedTag, !normalizedTag.isEmpty {
                joins += " JOIN tags t ON t.path = n.path "
                if includeChildTags {
                    clauses.append("(t.tag = ? OR t.tag LIKE ?)")
                    args.append(normalizedTag)
                    args.append(normalizedTag + "/%")
                } else {
                    clauses.append("t.tag = ?")
                    args.append(normalizedTag)
                }
            }
            if let normalizedFolder, !normalizedFolder.isEmpty {
                clauses.append("n.path LIKE ?")
                args.append(normalizedFolder + "/%")
            }

            let whereClause = clauses.isEmpty
                ? ""
                : " WHERE " + clauses.joined(separator: " AND ")

            let orderClause: String = {
                switch sortBy {
                case .modified: return " ORDER BY n.modified_at DESC "
                case .title:    return " ORDER BY LOWER(n.title) ASC "
                }
            }()

            // SELECT DISTINCT covers the tag-join multiplicity for the
            // page; COUNT(DISTINCT) does the same for totals.
            let pageSQL = """
                SELECT DISTINCT n.path, n.title, n.modified_at
                FROM notes n
                \(joins)
                \(whereClause)
                \(orderClause)
                LIMIT ? OFFSET ?
                """
            var pageArgs = args
            pageArgs.append(limit)
            pageArgs.append(offset)
            let rows = try Row.fetchAll(
                db,
                sql: pageSQL,
                arguments: StatementArguments(pageArgs)
            )
            let notes = rows.map(Self.noteSummary(from:))

            let countSQL = """
                SELECT COUNT(*) FROM (
                    SELECT DISTINCT n.path FROM notes n \(joins) \(whereClause)
                )
                """
            let total = try Int.fetchOne(
                db,
                sql: countSQL,
                arguments: StatementArguments(args)
            ) ?? notes.count

            return BrowsePage(notes: notes, totalCount: total)
        }
    }

    // MARK: - Vocab cache

    /// Snapshot of every term currently in `notes_fts`. Built on
    /// demand; rebuilt only when `markVocabDirty()` is called.
    func ensureVocab() -> VocabCache {
        vocabLock.lock()
        if let cached = cachedVocab {
            vocabLock.unlock()
            return cached
        }
        vocabLock.unlock()

        let snapshot = (try? buildVocabSnapshot()) ?? VocabCache(terms: [])
        vocabLock.lock()
        cachedVocab = snapshot
        vocabLock.unlock()
        #if DEBUG
        print("[VaultIndex] vocab cache built — \(snapshot.count) terms")
        #endif
        return snapshot
    }

    /// Drop the cached vocab snapshot. The scanner calls this after a
    /// non-trivial upsert batch (`parsed + deleted > 0`); next query
    /// rebuilds.
    func markVocabDirty() {
        vocabLock.lock()
        cachedVocab = nil
        vocabLock.unlock()
    }

    private func buildVocabSnapshot() throws -> VocabCache {
        try dbQueue.read { db in
            // `notes_fts_v` is the `fts5vocab` aux table declared in
            // migration v2 (type 'col'). Distinct terms over all
            // columns is exactly what the typo-correction step wants.
            let terms = try String.fetchAll(
                db,
                sql: "SELECT DISTINCT term FROM notes_fts_v"
            )
            return VocabCache(terms: terms)
        }
    }

    // MARK: - Search internals

    private struct FTSRow {
        let path: String
        let title: String
        let body: String
        let modifiedAt: Date
        let bm25: Double
        let snippet: String
    }

    /// Run one FTS5 pass with the given AND/OR mode. Bails (returns
    /// `[]`) when the parsed query can't produce a MATCH expression
    /// — that's not a search miss, that's "nothing to search."
    private func runFTS(
        _ db: Database,
        query: SearchQuery,
        tag: String?,
        folder: String?,
        mode: QueryParser.MatchMode,
        limit: Int
    ) throws -> [SearchHit] {
        guard let matchExpr = QueryParser.matchExpression(for: query, mode: mode) else {
            return []
        }

        // BM25 weights: title × 10, body × 1. FTS5 returns *negative*
        // BM25 (smaller is better); we flip it so callers can sort
        // descending without thinking about it.
        let normalizedTag = tag?.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "# /"))
        let normalizedFolder = folder?
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))

        var args: [DatabaseValueConvertible] = [matchExpr]
        var joins = ""
        var extraClauses: [String] = []

        if let normalizedTag, !normalizedTag.isEmpty {
            joins += " JOIN tags t ON t.path = n.path "
            extraClauses.append("(t.tag = ? OR t.tag LIKE ?)")
            args.append(normalizedTag)
            args.append(normalizedTag + "/%")
        }
        if let normalizedFolder, !normalizedFolder.isEmpty {
            extraClauses.append("n.path LIKE ?")
            args.append(normalizedFolder + "/%")
        }
        // Overfetch so the frecency multiplier has room to reshuffle
        // borderline-ranked candidates before we trim.
        args.append(limit * 4)

        let extraWhere = extraClauses.isEmpty
            ? ""
            : " AND " + extraClauses.joined(separator: " AND ")

        let sql = """
            SELECT DISTINCT
                n.path, n.title, n.body, n.modified_at,
                bm25(notes_fts, 100.0, 1.0) AS bm25_score,
                snippet(notes_fts, 1, '', '', '…', 16) AS body_snippet
            FROM notes_fts
            JOIN notes n ON n.rowid = notes_fts.rowid
            \(joins)
            WHERE notes_fts MATCH ?
            \(extraWhere)
            ORDER BY bm25_score ASC
            LIMIT ?
            """

        let rows: [FTSRow]
        do {
            rows = try Row.fetchAll(
                db,
                sql: sql,
                arguments: StatementArguments(args)
            ).map { row in
                FTSRow(
                    path: row["path"] ?? "",
                    title: row["title"] ?? "",
                    body: row["body"] ?? "",
                    modifiedAt: row["modified_at"] ?? .distantPast,
                    bm25: row["bm25_score"] ?? 0,
                    snippet: row["body_snippet"] ?? ""
                )
            }
        } catch {
            // FTS5 will throw on a malformed MATCH expression. Treat
            // that as zero rows rather than crashing the whole tool
            // call; the OR / fuzzy fallback may still recover.
            #if DEBUG
            print("[VaultIndex.runFTS] MATCH failed for '\(matchExpr)': \(error)")
            #endif
            return []
        }

        var hits: [SearchHit] = []
        hits.reserveCapacity(rows.count)
        for row in rows {
            let raw = try frecency.rawScore(db: db, path: row.path)
            let multiplier = FrecencyTracker.bm25Multiplier(rawScore: raw)
            // FTS5 returns negative BM25 (more negative = better
            // match). Flip and add a small offset so multiplication
            // by the frecency boost behaves intuitively (boosting a
            // tied candidate moves it ahead instead of arithmetically
            // backwards from negative numbers).
            let baseScore = max(0.0001, -row.bm25)
            let combined = baseScore * multiplier
            let snippet = row.snippet.isEmpty
                ? Self.firstNonEmptyLine(of: row.body)
                : row.snippet
            hits.append(
                SearchHit(
                    summary: NoteSummary(
                        path: row.path,
                        title: row.title,
                        modifiedAt: row.modifiedAt
                    ),
                    snippet: snippet,
                    score: combined
                )
            )
        }
        hits.sort { $0.score > $1.score }
        return Array(hits.prefix(limit))
    }

    /// Title-only fuzzy fallback. Only runs after both AND and OR FTS
    /// passes returned zero. Filters tag/folder client-side to keep
    /// the safety-net behavior honest about which notes the caller
    /// asked for.
    private func runFuzzyTitleFallback(
        _ db: Database,
        parsed: SearchQuery,
        tag: String?,
        folder: String?,
        limit: Int
    ) throws -> [SearchHit] {
        // Use the original raw query for fuzzy — vocab correction
        // already failed, and the raw spelling is the best signal we
        // have for the title-match metric.
        let rawNeedle = parsed.raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawNeedle.isEmpty else { return [] }

        let candidates = try Row.fetchAll(
            db,
            sql: "SELECT path, title, body, modified_at FROM notes"
        )
        let titles = candidates.map { row -> (path: String, title: String) in
            (row["path"] ?? "", row["title"] ?? "")
        }
        let matches = FuzzyTitleMatcher.match(
            query: rawNeedle,
            titles: titles,
            limit: limit
        )
        guard !matches.isEmpty else { return [] }

        // Build the row lookup once so we can hydrate snippets without
        // a per-match query.
        var rowByPath: [String: Row] = [:]
        for row in candidates {
            if let p: String = row["path"] { rowByPath[p] = row }
        }

        var hits: [SearchHit] = []
        hits.reserveCapacity(matches.count)
        for match in matches {
            guard let row = rowByPath[match.path] else { continue }
            let body: String = row["body"] ?? ""
            let modifiedAt: Date = row["modified_at"] ?? .distantPast

            // Apply tag/folder filters client-side so the safety-net
            // path doesn't bypass scope the user explicitly asked for.
            if !matchesTag(row: row, db: db, tag: tag) { continue }
            if let normalizedFolder = folder?
                .trimmingCharacters(in: CharacterSet(charactersIn: "/ ")),
               !normalizedFolder.isEmpty,
               !match.path.hasPrefix(normalizedFolder + "/") {
                continue
            }

            let raw = try frecency.rawScore(db: db, path: match.path)
            let multiplier = FrecencyTracker.bm25Multiplier(rawScore: raw)
            hits.append(
                SearchHit(
                    summary: NoteSummary(
                        path: match.path,
                        title: match.title,
                        modifiedAt: modifiedAt
                    ),
                    snippet: Self.firstNonEmptyLine(of: body),
                    score: match.score * multiplier
                )
            )
        }
        hits.sort { $0.score > $1.score }
        return Array(hits.prefix(limit))
    }

    /// Tag filter for the fuzzy path. Returns true when no tag is
    /// requested or the row carries the tag (with optional
    /// hierarchical children, matching the search arg's semantics).
    private func matchesTag(row: Row, db: Database, tag: String?) -> Bool {
        guard let normalized = tag?.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "# /")),
              !normalized.isEmpty,
              let path: String = row["path"]
        else { return true }
        let hit = (try? Int.fetchOne(
            db,
            sql: """
                SELECT 1 FROM tags
                WHERE path = ? AND (tag = ? OR tag LIKE ?)
                LIMIT 1
                """,
            arguments: [path, normalized, normalized + "/%"]
        )) ?? nil
        return hit != nil
    }

    /// Build a `Citation` from any indexed note path. Used by tools that
    /// surface multi-note results; keeps citation construction in one
    /// place so the Sources card never sees ad-hoc shapes.
    func citation(forPath path: String, snippetOverride: String? = nil, score: Double? = nil) throws -> Citation? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT title, body FROM notes WHERE path = ?",
                arguments: [path]
            ) else { return nil }
            let title: String = row["title"] ?? path
            let body: String = row["body"] ?? ""
            let snippet = snippetOverride ?? Self.firstNonEmptyLine(of: body)
            return Citation(path: path, title: title, snippet: snippet, score: score)
        }
    }

    // MARK: - Row mappers

    private static func noteRecord(from row: Row) -> NoteRecord {
        let frontmatterJSON: String = row["frontmatter"] ?? "{}"
        let frontmatter = decodeFrontmatter(frontmatterJSON)
        return NoteRecord(
            path: row["path"] ?? "",
            title: row["title"] ?? "",
            body: row["body"] ?? "",
            frontmatter: frontmatter,
            modifiedAt: row["modified_at"] ?? .distantPast
        )
    }

    private static func noteSummary(from row: Row) -> NoteSummary {
        NoteSummary(
            path: row["path"] ?? "",
            title: row["title"] ?? "",
            modifiedAt: row["modified_at"] ?? .distantPast
        )
    }

    private static func decodeFrontmatter(_ raw: String) -> [String: JSONValue] {
        guard let data = raw.data(using: .utf8) else { return [:] }
        return (try? JSONDecoder().decode([String: JSONValue].self, from: data)) ?? [:]
    }

    // MARK: - Snippet

    /// First non-empty prose line, capped at 120 chars. Kept short on
    /// purpose: long snippets multiplied by 10+ citations blow past the
    /// on-device model's context budget when results are fed back in.
    /// FTS5's `snippet()` does the heavy lifting for body matches; this
    /// is the fallback when there's no in-body hit to center on.
    private static func firstNonEmptyLine(of body: String) -> String {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip markdown headings' hash marks so the snippet reads as prose.
            let stripped = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty { return String(stripped.prefix(120)) }
        }
        return ""
    }

    /// Wipe every table. Used when the user picks a new vault — vault
    /// identity is the bookmark, not anything in this DB.
    func wipe() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM links")
            try db.execute(sql: "DELETE FROM tags")
            try db.execute(sql: "DELETE FROM embeddings")
            try db.execute(sql: "DELETE FROM note_opens")
            try db.execute(sql: "DELETE FROM notes")
            // FTS5 triggers cascade title/body deletes via the
            // `notes` rows above, so notes_fts is empty by now.
        }
        markVocabDirty()
    }

    // MARK: - Private query helpers

    private static func upsertNote(_ db: Database, note: VaultNote, indexedAt: Date) throws {
        let frontmatterJSON = encodeJSON(note.frontmatter)
        try db.execute(
            sql: """
                INSERT INTO notes (path, title, body, frontmatter, content_hash, modified_at, indexed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(path) DO UPDATE SET
                    title        = excluded.title,
                    body         = excluded.body,
                    frontmatter  = excluded.frontmatter,
                    content_hash = excluded.content_hash,
                    modified_at  = excluded.modified_at,
                    indexed_at   = excluded.indexed_at
                """,
            arguments: [
                note.path,
                note.title,
                note.body,
                frontmatterJSON,
                note.contentHash,
                note.modifiedAt,
                indexedAt,
            ]
        )
    }

    private static func replaceLinks(
        _ db: Database,
        sourcePath: String,
        resolved: [ResolvedLink]
    ) throws {
        try db.execute(sql: "DELETE FROM links WHERE source_path = ?", arguments: [sourcePath])
        guard !resolved.isEmpty else { return }
        let stmt = try db.makeStatement(sql: """
            INSERT INTO links
                (source_path, target_path, target_raw, target_heading, target_block, display_label)
            VALUES (?, ?, ?, ?, ?, ?)
            """)
        for link in resolved {
            try stmt.execute(arguments: [
                sourcePath,
                link.targetPath,
                link.wikilink.target,
                link.wikilink.heading,
                link.wikilink.block,
                link.wikilink.displayLabel,
            ])
        }
    }

    private static func replaceTags(
        _ db: Database,
        path: String,
        tags: [VaultNote.TagOccurrence]
    ) throws {
        try db.execute(sql: "DELETE FROM tags WHERE path = ?", arguments: [path])
        guard !tags.isEmpty else { return }
        let stmt = try db.makeStatement(sql: """
            INSERT INTO tags (path, tag, source) VALUES (?, ?, ?)
            """)
        for t in tags {
            try stmt.execute(arguments: [path, t.tag, t.source.rawValue])
        }
    }

    private static func encodeJSON(_ dict: [String: JSONValue]) -> String {
        guard !dict.isEmpty else { return "{}" }
        let encoder = JSONEncoder()
        // Stable ordering helps when eyeballing the DB in a SQLite browser.
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(dict),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return "{}"
    }
}

// MARK: - DTOs

/// One outbound wikilink resolved against the rest of the vault.
/// `targetPath` is `nil` when the wikilink couldn't be matched to a
/// note (unresolved link — kept for backlinks queries, surfaced to the
/// UI as a dimmed style later).
struct ResolvedLink: Equatable, Sendable {
    let wikilink: Wikilink
    let targetPath: String?
}
