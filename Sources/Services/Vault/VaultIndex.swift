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

    /// Persists at `Documents/vault-index.sqlite`. One DB per app install;
    /// switching vaults wipes and rebuilds (vault identity = the active
    /// security-scoped bookmark, not anything in this DB).
    init(databaseURL: URL) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        self.dbQueue = try DatabaseQueue(path: databaseURL.path(), configuration: config)
        try VaultIndexSchema.makeMigrator().migrate(dbQueue)
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
    /// (`ListNotesByTagTool`, `ListRecentNotesTool`, `GetBacklinksTool`).
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

    /// Notes carrying a given tag. With `includeChildren = true`,
    /// `project` also matches `project/obelisk`, `project/obelisk/phase-b`,
    /// etc. (Obsidian's hierarchical-tag semantics.)
    func notes(withTag tag: String, includeChildren: Bool, limit: Int) throws -> [NoteSummary] {
        let normalized = tag.lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "# /"))
        guard !normalized.isEmpty else { return [] }

        return try dbQueue.read { db in
            let sql: String
            let args: StatementArguments
            if includeChildren {
                sql = """
                    SELECT DISTINCT n.path, n.title, n.modified_at
                    FROM notes n
                    JOIN tags t ON t.path = n.path
                    WHERE t.tag = ? OR t.tag LIKE ?
                    ORDER BY n.modified_at DESC
                    LIMIT ?
                    """
                args = [normalized, normalized + "/%", limit]
            } else {
                sql = """
                    SELECT DISTINCT n.path, n.title, n.modified_at
                    FROM notes n
                    JOIN tags t ON t.path = n.path
                    WHERE t.tag = ?
                    ORDER BY n.modified_at DESC
                    LIMIT ?
                    """
                args = [normalized, limit]
            }
            let rows = try Row.fetchAll(db, sql: sql, arguments: args)
            return rows.map(Self.noteSummary(from:))
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

    /// Notes modified within the trailing `days` window, newest first.
    func recentNotes(within days: Int, limit: Int) throws -> [NoteSummary] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        return try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT path, title, modified_at
                    FROM notes
                    WHERE modified_at >= ?
                    ORDER BY modified_at DESC
                    LIMIT ?
                    """,
                arguments: [cutoff, limit]
            )
            return rows.map(Self.noteSummary(from:))
        }
    }

    /// Naive case-insensitive LIKE search across title + body. Returns
    /// hits with a snippet centered on the first body match (or the
    /// first non-empty line when only the title matched). Phase C will
    /// replace this with semantic search but keep the result shape.
    ///
    /// Score is a coarse 0…1 heuristic: title hits weigh heaviest,
    /// followed by raw match count in the body.
    func search(
        query: String,
        tag: String?,
        folder: String?,
        limit: Int
    ) throws -> [SearchHit] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let needle = "%" + trimmed.replacingOccurrences(of: "%", with: "\\%") + "%"

        return try dbQueue.read { db in
            var sql = """
                SELECT DISTINCT n.path, n.title, n.body, n.modified_at
                FROM notes n
                """
            var args: [DatabaseValueConvertible] = []
            var clauses: [String] = ["(LOWER(n.title) LIKE LOWER(?) OR LOWER(n.body) LIKE LOWER(?))"]
            args.append(needle)
            args.append(needle)

            if let tag = tag?.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: "# /")),
               !tag.isEmpty {
                sql += " JOIN tags t ON t.path = n.path "
                clauses.append("(t.tag = ? OR t.tag LIKE ?)")
                args.append(tag)
                args.append(tag + "/%")
            }
            if let folder = folder?
                .trimmingCharacters(in: CharacterSet(charactersIn: "/ ")),
               !folder.isEmpty {
                clauses.append("n.path LIKE ?")
                args.append(folder + "/%")
            }

            sql += " WHERE " + clauses.joined(separator: " AND ")
            sql += " ORDER BY n.modified_at DESC LIMIT ?"
            args.append(limit * 4) // overfetch; we trim after scoring

            let rows = try Row.fetchAll(
                db,
                sql: sql,
                arguments: StatementArguments(args)
            )

            let hits = rows.map { row -> SearchHit in
                let path: String = row["path"] ?? ""
                let title: String = row["title"] ?? ""
                let body: String = row["body"] ?? ""
                let modifiedAt: Date = row["modified_at"] ?? .distantPast
                let snippet = Self.snippet(in: body, around: trimmed) ?? Self.firstNonEmptyLine(of: body)
                let score = Self.score(query: trimmed, title: title, body: body)
                return SearchHit(
                    summary: NoteSummary(path: path, title: title, modifiedAt: modifiedAt),
                    snippet: snippet,
                    score: score
                )
            }
            return hits.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
        }
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

    // MARK: - Snippet + scoring

    /// Best-effort hit-centered snippet (about 160 chars) trimmed to
    /// the nearest word boundary on each side.
    private static func snippet(in body: String, around query: String) -> String? {
        guard !body.isEmpty, !query.isEmpty else { return nil }
        let lower = body.lowercased()
        guard let range = lower.range(of: query.lowercased()) else { return nil }
        let radius = 80
        let startIdx = body.index(range.lowerBound, offsetBy: -radius, limitedBy: body.startIndex) ?? body.startIndex
        let endIdx = body.index(range.upperBound, offsetBy: radius, limitedBy: body.endIndex) ?? body.endIndex
        var snippet = String(body[startIdx..<endIdx])
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if startIdx != body.startIndex { snippet = "…" + snippet }
        if endIdx != body.endIndex { snippet += "…" }
        return snippet
    }

    /// First non-empty prose line, capped at 120 chars. Kept short on
    /// purpose: long snippets multiplied by 10+ citations blow past the
    /// on-device model's context budget when results are fed back in.
    private static func firstNonEmptyLine(of body: String) -> String {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // Skip markdown headings' hash marks so the snippet reads as prose.
            let stripped = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty { return String(stripped.prefix(120)) }
        }
        return ""
    }

    private static func score(query: String, title: String, body: String) -> Double {
        let q = query.lowercased()
        let titleLower = title.lowercased()
        let bodyLower = body.lowercased()
        let titleHits = titleLower.contains(q) ? 1 : 0
        let bodyHits = bodyLower.components(separatedBy: q).count - 1
        // Title match = 0.7, +0.05 per body hit, capped.
        let raw = Double(titleHits) * 0.7 + min(Double(bodyHits) * 0.05, 0.3)
        return min(raw, 1.0)
    }

    /// Wipe every table. Used when the user picks a new vault — vault
    /// identity is the bookmark, not anything in this DB.
    func wipe() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM links")
            try db.execute(sql: "DELETE FROM tags")
            try db.execute(sql: "DELETE FROM embeddings")
            try db.execute(sql: "DELETE FROM notes")
        }
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
