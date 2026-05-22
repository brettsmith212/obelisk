import Foundation
import CryptoKit

/// Walks the vault filesystem and populates `VaultIndex`.
///
/// Two modes, sharing the same code path:
/// - **Full scan**: first connect, or after the user re-picks a vault.
///   Wipes the index, parses every `.md`, writes everything back.
/// - **Incremental scan**: foregrounding / "Re-index now". Diffs live
///   file hashes against `VaultIndex.existingHashes()` and re-parses
///   only changed files; still updates the unresolved-link table to
///   pick up newly-resolvable wikilinks.
///
/// Heavy work runs on the actor's executor (off the main thread). The
/// scanner reports progress via an `AsyncStream<Progress>` consumed by
/// `VaultAccessService` so the Settings sheet can render a status line.
actor VaultScanner {
    enum Mode: Equatable, Sendable {
        case full
        case incremental
    }

    /// One progress event per phase transition + per processed file
    /// (coalesced — the scanner emits ~1 progress event per 25 files
    /// to keep UI updates cheap).
    enum Progress: Equatable, Sendable {
        case started(totalFiles: Int, mode: Mode)
        case parsing(processed: Int, totalFiles: Int)
        case resolvingLinks
        case finished(Summary)
        case failed(String)
    }

    struct Summary: Equatable, Sendable {
        let mode: Mode
        let totalFiles: Int
        let parsed: Int        // notes actually re-parsed this run
        let skipped: Int       // hash-matched, body untouched
        let deleted: Int       // stale paths removed from the index
        let iCloudPlaceholders: Int
        let durationSeconds: Double
    }

    /// Structured failures the scanner can surface. The only one users
    /// see today is `.iCloudNotDownloaded` — the spec wants a specific
    /// red banner ("Mark the folder as 'Keep on this iPhone'…") rather
    /// than a generic "scan failed" pill.
    enum ScanError: LocalizedError, Equatable {
        case iCloudNotDownloaded

        var errorDescription: String? {
            switch self {
            case .iCloudNotDownloaded:
                return "Vault not fully downloaded from iCloud. Mark the folder as 'Keep on this iPhone' and try again."
            }
        }
    }

    private let index: VaultIndex

    init(index: VaultIndex) {
        self.index = index
    }

    // MARK: - Public API

    /// Run a scan against the given vault. `mode == .full` wipes the
    /// index first; `.incremental` diffs against
    /// `VaultIndex.existingHashes()`.
    ///
    /// The caller is responsible for ensuring `handle.rootURL` is
    /// readable (i.e. any security-scoped access started before this
    /// call and stopped after the stream completes). For app-sandbox
    /// vaults — currently the only kind — there's no ceremony.
    nonisolated func scan(handle: VaultHandle, mode: Mode) -> AsyncStream<Progress> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    let summary = try await self.runScan(
                        handle: handle,
                        mode: mode,
                        report: { event in continuation.yield(event) }
                    )
                    continuation.yield(.finished(summary))
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Implementation

    private func runScan(
        handle: VaultHandle,
        mode: Mode,
        report: @Sendable (Progress) -> Void
    ) async throws -> Summary {
        let start = Date()
        if mode == .full {
            try index.wipe()
        }
        let existingHashes = try index.existingHashes()
        let rootURL = handle.rootURL

        // Phase 1: enumerate live files (cheap, no parsing).
        let inventory = try VaultScanner.enumerateMarkdown(rootURL: rootURL)

        // Refuse to index a partly-downloaded iCloud vault — half the
        // notes would silently go missing and the model would hallucinate
        // confidently about an incomplete corpus (phase-b.md §8 step 15).
        // The UI turns this into a red status pill with a "tap to retry"
        // affordance once the user marks the folder "Keep on this iPhone".
        if inventory.iCloudPlaceholders > 0 {
            throw ScanError.iCloudNotDownloaded
        }

        report(.started(totalFiles: inventory.files.count, mode: mode))

        // Phase 2: hash + parse only changed files. Untouched files still
        // contribute to the name-map so newly-added notes can resolve
        // wikilinks pointing at them.
        var parsed = 0
        var skipped = 0
        var nameMap = NameResolver()
        var parsedNotes: [VaultNote] = []
        parsedNotes.reserveCapacity(inventory.files.count)

        let reportEvery = 25

        for (i, file) in inventory.files.enumerated() {
            try Task.checkCancellation()
            let relativePath = file.relativePath
            let fileURL = rootURL.appending(path: relativePath, directoryHint: .notDirectory)

            let data: Data
            do {
                data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            } catch {
                // Skip unreadable files; they're rare and we'd rather
                // index 99% than fail the whole scan. They retry next
                // foreground.
                continue
            }
            let hash = VaultScanner.sha256Hex(data)

            nameMap.add(path: relativePath)

            if let prior = existingHashes[relativePath], prior == hash {
                skipped += 1
            } else {
                let text = String(data: data, encoding: .utf8) ?? ""
                let note = VaultScanner.parseNote(
                    relativePath: relativePath,
                    text: text,
                    contentHash: hash,
                    modifiedAt: file.modifiedAt
                )
                parsedNotes.append(note)
                parsed += 1
            }

            if (i + 1) % reportEvery == 0 || (i + 1) == inventory.files.count {
                report(.parsing(processed: i + 1, totalFiles: inventory.files.count))
            }
        }

        // Phase 3: resolve wikilinks against the full name map and write.
        report(.resolvingLinks)
        let indexedAt = Date()
        let resolverSnapshot = nameMap // value type — safe to capture
        for note in parsedNotes {
            let resolved = note.outboundLinks.map { link in
                ResolvedLink(
                    wikilink: link,
                    targetPath: resolverSnapshot.resolve(link.target)
                )
            }
            try index.upsert(note: note, resolvedLinks: resolved, indexedAt: indexedAt)
        }

        // Phase 4: prune paths that disappeared between scans.
        let livePaths = Set(inventory.files.map { $0.relativePath })
        var deleted = 0
        if mode == .incremental {
            for stalePath in existingHashes.keys where !livePaths.contains(stalePath) {
                try index.deleteNote(path: stalePath)
                deleted += 1
            }
            // Also rewire any links that previously couldn't resolve but
            // now can (a referenced note was just added). Cheap: one
            // UPDATE per name in the map.
            try index.resolveOutboundLinks(using: resolverSnapshot.uniqueByBasename)
        }

        // Phase C: a non-trivial upsert batch may have added or
        // removed FTS5 vocab terms — invalidate the cache so the next
        // query rebuilds it. Full scans always invalidate; incrementals
        // only when something actually changed.
        if mode == .full || parsed > 0 || deleted > 0 {
            index.markVocabDirty()
        }

        let duration = Date().timeIntervalSince(start)
        return Summary(
            mode: mode,
            totalFiles: inventory.files.count,
            parsed: parsed,
            skipped: skipped,
            deleted: deleted,
            iCloudPlaceholders: inventory.iCloudPlaceholders,
            durationSeconds: duration
        )
    }

    // MARK: - Enumeration

    private struct Inventory: Sendable {
        let files: [File]
        let iCloudPlaceholders: Int

        struct File: Sendable {
            let relativePath: String
            let modifiedAt: Date
        }
    }

    private static func enumerateMarkdown(rootURL: URL) throws -> Inventory {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .contentModificationDateKey, .nameKey,
        ]
        // We can't use `.skipsHiddenFiles` here because iCloud placeholder
        // files are dot-prefixed (`.Foo.md.icloud`) — skipping hidden
        // files would also skip the very signal we need to detect a
        // half-downloaded vault. We apply the hidden-folder policy
        // manually below instead.
        guard let enumerator = fm.enumerator(
            at: rootURL,
            includingPropertiesForKeys: keys
        ) else {
            return Inventory(files: [], iCloudPlaceholders: 0)
        }

        // Folder names we never index. Includes Obsidian's own metadata
        // (`.obsidian/` would brick the vault if we touched its config)
        // and the trash. `obelisk/` is *not* excluded — that's our
        // authorized write target and must be indexed.
        let excludedDirNames: Set<String> = [".obsidian", ".trash", ".git"]

        var files: [Inventory.File] = []
        var placeholders = 0

        for case let url as URL in enumerator {
            let name = url.lastPathComponent
            let rel = relativePath(of: url, root: rootURL)

            // Skip excluded directories outright (and don't descend),
            // and skip anything already underneath one of them.
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDirectory, excludedDirNames.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            if excludedDirNames.contains(where: { rel.hasPrefix($0 + "/") }) {
                continue
            }

            // iCloud placeholder files look like `.Foo.md.icloud` — when
            // the file has been evicted, the real bytes live in the
            // cloud. We can't read them, so count + skip and let the
            // scanner refuse to index per phase-b.md §8 step 15.
            if name.hasSuffix(".icloud") {
                placeholders += 1
                continue
            }

            // Past the placeholder check, anything still starting with
            // a dot is a user/system hidden file we don't care about
            // (e.g. `.DS_Store`, or a personal sidecar). Skip silently.
            if name.hasPrefix(".") { continue }

            guard url.pathExtension.lowercased() == "md" else { continue }

            let resourceValues = try? url.resourceValues(forKeys: Set(keys))
            let modified = resourceValues?.contentModificationDate ?? .distantPast
            files.append(Inventory.File(relativePath: rel, modifiedAt: modified))
        }

        // Stable ordering simplifies progress UI.
        files.sort { $0.relativePath < $1.relativePath }
        return Inventory(files: files, iCloudPlaceholders: placeholders)
    }

    /// Decoded (non-percent-encoded) vault-relative POSIX path. Using
    /// `URL.path()` here would percent-encode spaces, which would then
    /// double-encode when we reconstruct the file URL with
    /// `rootURL.appending(path:)`.
    private static func relativePath(of url: URL, root: URL) -> String {
        let rootPath = root.path(percentEncoded: false)
        let full = url.path(percentEncoded: false)
        if full.hasPrefix(rootPath) {
            var rel = String(full.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            return rel
        }
        return url.lastPathComponent
    }

    // MARK: - Parsing

    private static func parseNote(
        relativePath: String,
        text: String,
        contentHash: String,
        modifiedAt: Date
    ) -> VaultNote {
        let split = FrontmatterParser.parse(text)
        let tags = TagExtractor.extract(frontmatter: split.frontmatter, body: split.body)
        let links = WikilinkParser.parse(split.body)
        let title = deriveTitle(
            relativePath: relativePath,
            frontmatter: split.frontmatter,
            body: split.body
        )
        return VaultNote(
            path: relativePath,
            title: title,
            body: split.body,
            frontmatter: split.frontmatter,
            tags: tags,
            outboundLinks: links,
            contentHash: contentHash,
            modifiedAt: modifiedAt
        )
    }

    /// Title precedence:
    /// 1. Frontmatter `title` (if string).
    /// 2. First H1 in the body.
    /// 3. Filename without `.md`.
    private static func deriveTitle(
        relativePath: String,
        frontmatter: [String: JSONValue],
        body: String
    ) -> String {
        if case .string(let s) = frontmatter["title"], !s.isEmpty {
            return s
        }
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        let last = (relativePath as NSString).lastPathComponent
        if last.lowercased().hasSuffix(".md") {
            return String(last.dropLast(3))
        }
        return last
    }

    // MARK: - SHA-256

    private static func sha256Hex(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Name resolver

/// Obsidian-style wikilink resolution: try exact relative path first,
/// then unique basename match. Ambiguous basenames (same `Foo.md` in
/// two folders) resolve to `nil` unless the wikilink target explicitly
/// includes a folder segment.
private struct NameResolver: Sendable {
    /// Exact relative paths, indexed lowercased for case-insensitive
    /// matching.
    private var byRelativePath: [String: String] = [:]
    /// Basename without `.md`, lowercased → all matching relative paths.
    private var byBasename: [String: [String]] = [:]

    mutating func add(path: String) {
        byRelativePath[path.lowercased()] = path
        let base = basename(of: path).lowercased()
        byBasename[base, default: []].append(path)
    }

    /// Map of unambiguous basenames → canonical path. Used by
    /// `VaultIndex.resolveOutboundLinks` to fix orphan links after
    /// adding new notes.
    var uniqueByBasename: [String: String] {
        var out: [String: String] = [:]
        for (base, paths) in byBasename where paths.count == 1 {
            out[base] = paths[0]
        }
        return out
    }

    /// Best-effort resolution of a wikilink target. Tries the most
    /// specific match first; returns `nil` if ambiguous or missing.
    func resolve(_ target: String) -> String? {
        let trimmed = target.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }

        // 1. Exact path match including or excluding the `.md` suffix.
        let withMd = trimmed.lowercased().hasSuffix(".md") ? trimmed : trimmed + ".md"
        if let hit = byRelativePath[withMd.lowercased()] {
            return hit
        }

        // 2. If the target contains a slash, it was a folder-qualified
        //    link and we don't fall back to basename matching — Obsidian
        //    treats those as unresolved when the path doesn't exist.
        if trimmed.contains("/") {
            return nil
        }

        // 3. Basename match — only if unambiguous.
        let base = (trimmed.hasSuffix(".md") ? String(trimmed.dropLast(3)) : trimmed).lowercased()
        if let candidates = byBasename[base], candidates.count == 1 {
            return candidates[0]
        }
        return nil
    }

    private func basename(of relativePath: String) -> String {
        let last = (relativePath as NSString).lastPathComponent
        if last.lowercased().hasSuffix(".md") {
            return String(last.dropLast(3))
        }
        return last
    }
}
