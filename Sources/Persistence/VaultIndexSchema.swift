import Foundation
import GRDB

/// GRDB migration registry for the vault index.
///
/// Phase B ships migration `v1` (notes / links / tags + a reserved
/// `embeddings` table). Phase C will only add rows to `embeddings`,
/// not change the schema, so v1 should be the only migration for a
/// while.
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

            // Reserved for Phase C; defined now so migrations stay linear.
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

        return migrator
    }
}
