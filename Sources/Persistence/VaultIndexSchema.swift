import Foundation
import GRDB

/// GRDB migration registry for the vault index.
///
/// Phase B ships migration `v1` (notes / links / tags + a reserved
/// `embeddings` table).
///
/// Phase C adds migration `v2`: an external-content FTS5 mirror over
/// `notes(title, body)` (with sync triggers + an `fts5vocab` aux table
/// for the typo-correction vocab cache), plus the append-only
/// `note_opens` table that backs frecency ranking. See [phase-c.md §4](../../phase-c.md).
///
/// Defining the migrator in its own file keeps the I/O surface (`VaultIndex`)
/// focused on queries and lets us unit-test the schema in isolation if /
/// when we add a test target.
enum VaultIndexSchema {
    static func makeMigrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE notes (
                    path           TEXT PRIMARY KEY,
                    title          TEXT NOT NULL,
                    body           TEXT NOT NULL,
                    frontmatter    TEXT NOT NULL,
                    content_hash   TEXT NOT NULL,
                    modified_at    DATETIME NOT NULL,
                    indexed_at     DATETIME NOT NULL
                );
                """)
            try db.execute(sql: "CREATE INDEX idx_notes_modified ON notes(modified_at);")

            try db.execute(sql: """
                CREATE TABLE links (
                    source_path    TEXT NOT NULL,
                    target_path    TEXT,
                    target_raw     TEXT NOT NULL,
                    target_heading TEXT,
                    target_block   TEXT,
                    display_label  TEXT,
                    FOREIGN KEY (source_path) REFERENCES notes(path) ON DELETE CASCADE
                );
                """)
            try db.execute(sql: "CREATE INDEX idx_links_source ON links(source_path);")
            try db.execute(sql: "CREATE INDEX idx_links_target ON links(target_path);")

            try db.execute(sql: """
                CREATE TABLE tags (
                    path           TEXT NOT NULL,
                    tag            TEXT NOT NULL,
                    source         TEXT NOT NULL,
                    FOREIGN KEY (path) REFERENCES notes(path) ON DELETE CASCADE
                );
                """)
            try db.execute(sql: "CREATE INDEX idx_tags_tag ON tags(tag);")
            try db.execute(sql: "CREATE INDEX idx_tags_path ON tags(path);")

            // Reserved for a future semantic-search pass (currently in
            // the deferred list — see roadmap.md). Defined now so
            // migrations stay linear.
            try db.execute(sql: """
                CREATE TABLE embeddings (
                    path           TEXT NOT NULL,
                    chunk_index    INTEGER NOT NULL,
                    chunk_start    INTEGER NOT NULL,
                    chunk_end      INTEGER NOT NULL,
                    content_hash   TEXT NOT NULL,
                    embedding      BLOB,
                    PRIMARY KEY (path, chunk_index),
                    FOREIGN KEY (path) REFERENCES notes(path) ON DELETE CASCADE
                );
                """)
        }

        migrator.registerMigration("v2") { db in
            // External-content FTS5 mirror. `content='notes'` +
            // `content_rowid='rowid'` means FTS5 doesn't duplicate the
            // body bytes — it reads from `notes` on demand. Triggers
            // below keep the index in sync.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE notes_fts USING fts5(
                    title,
                    body,
                    content='notes',
                    content_rowid='rowid',
                    tokenize='unicode61 remove_diacritics 2'
                );
                """)

            // Vocab table for the typo-correction cache. `'col'` type
            // gives one row per (term, column) so we can scope to either
            // title or body if we ever want to; today we union over all
            // cols. See phase-c.md §3.1.
            try db.execute(sql: """
                CREATE VIRTUAL TABLE notes_fts_v USING fts5vocab(notes_fts, 'col');
                """)

            // Sync triggers. Without these the FTS5 index goes stale
            // silently — every `notes` write must be mirrored.
            try db.execute(sql: """
                CREATE TRIGGER notes_fts_ai AFTER INSERT ON notes BEGIN
                    INSERT INTO notes_fts(rowid, title, body)
                    VALUES (new.rowid, new.title, new.body);
                END;
                """)
            try db.execute(sql: """
                CREATE TRIGGER notes_fts_ad AFTER DELETE ON notes BEGIN
                    INSERT INTO notes_fts(notes_fts, rowid, title, body)
                    VALUES('delete', old.rowid, old.title, old.body);
                END;
                """)
            try db.execute(sql: """
                CREATE TRIGGER notes_fts_au AFTER UPDATE ON notes BEGIN
                    INSERT INTO notes_fts(notes_fts, rowid, title, body)
                    VALUES('delete', old.rowid, old.title, old.body);
                    INSERT INTO notes_fts(rowid, title, body)
                    VALUES (new.rowid, new.title, new.body);
                END;
                """)

            // Backfill from existing rows once the table + triggers
            // exist. On a fresh install this is a no-op; on a Phase-B
            // upgrade it walks every previously-indexed note.
            try db.execute(sql: """
                INSERT INTO notes_fts(rowid, title, body)
                SELECT rowid, title, body FROM notes;
                """)

            // Frecency. Append-only — we keep history so the decay
            // window / λ can be re-tuned later without losing signal.
            try db.execute(sql: """
                CREATE TABLE note_opens (
                    path        TEXT NOT NULL,
                    opened_at   DATETIME NOT NULL,
                    source      TEXT NOT NULL,
                    FOREIGN KEY (path) REFERENCES notes(path) ON DELETE CASCADE
                );
                """)
            try db.execute(sql: "CREATE INDEX idx_note_opens_path ON note_opens(path);")
            try db.execute(sql: "CREATE INDEX idx_note_opens_at   ON note_opens(opened_at);")
        }

        return migrator
    }
}
