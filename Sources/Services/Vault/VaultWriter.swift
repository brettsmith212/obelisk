import Foundation

/// The single mediator for writing into a user's Obsidian vault.
///
/// Implements the "do no harm" rules from
/// [roadmap.md §"The 'do no harm' rules for vault writes"](../../../roadmap.md)
/// and phase-b.md §8 step 11:
///
/// - **Authorized folders.** Writes are refused unless the target path
///   sits under an allowed top-level folder. Default is `obelisk/`.
/// - **Identity marker.** Every file Obelisk writes carries
///   `source: obelisk` in its YAML frontmatter. The writer injects this
///   automatically so callers never have to.
/// - **No clobbering.** If a file already exists at the target path, the
///   writer reads its frontmatter; if `source: obelisk` is absent, the
///   write is refused. (User-authored notes are untouchable.)
/// - **Atomicity.** Bytes land via a sibling temp file + `replaceItemAt`,
///   so a mid-write crash never leaves a half-written file.
///
/// Stateless on purpose — tests / future tools can call it directly
/// without dragging the rest of the vault layer in.
enum VaultWriter {
    /// Folders inside the vault that Obelisk is allowed to write into.
    /// Conservative by design — the user can grant more in a future
    /// "authorized folders" UI (phase-b.md §2 stretch).
    static let defaultAuthorizedFolders: [String] = ["obelisk"]

    enum WriteError: Error, LocalizedError, Equatable {
        case unauthorizedFolder(path: String, allowed: [String])
        case wouldOverwriteForeignNote(path: String)
        case invalidPath(String)

        var errorDescription: String? {
            switch self {
            case .unauthorizedFolder(let path, let allowed):
                let list = allowed.map { "'\($0)/'" }.joined(separator: ", ")
                return "Refusing to write to '\(path)' — Obelisk can only write inside: \(list)."
            case .wouldOverwriteForeignNote(let path):
                return "Refusing to overwrite '\(path)' — that note wasn't created by Obelisk."
            case .invalidPath(let detail):
                return "Invalid path: \(detail)"
            }
        }
    }

    struct WriteResult: Equatable, Sendable {
        let relativePath: String
        let absoluteURL: URL
        /// `true` if the file did not previously exist; `false` if an
        /// Obelisk-created file was overwritten.
        let created: Bool
    }

    /// Frontmatter values the writer knows how to serialize. Kept
    /// deliberately small — anything more exotic should be staged in
    /// the body rather than the YAML preamble.
    enum FrontmatterValue: Sendable, Equatable {
        case scalar(String)
        case stringList([String])
    }

    /// Build a note from frontmatter + body, then atomically write it
    /// to `<vaultRoot>/<relativePath>`. The writer takes care of:
    ///
    /// - Validating the target path stays under an authorized folder.
    /// - Injecting `source: obelisk` (preserving any caller-supplied
    ///   frontmatter keys).
    /// - Refusing to overwrite a file Obelisk didn't create.
    /// - Creating any missing intermediate directories.
    @discardableResult
    static func write(
        relativePath: String,
        frontmatter: [String: FrontmatterValue],
        body: String,
        in vaultRoot: URL,
        authorizedFolders: [String] = defaultAuthorizedFolders
    ) throws -> WriteResult {
        let cleanedRelative = try normalize(relativePath: relativePath)
        try checkAuthorized(path: cleanedRelative, allowed: authorizedFolders)

        let absoluteURL = vaultRoot.appending(path: cleanedRelative, directoryHint: .notDirectory)
        let directoryURL = absoluteURL.deletingLastPathComponent()

        let fm = FileManager.default
        let existed = fm.fileExists(atPath: absoluteURL.path(percentEncoded: false))
        if existed {
            try requireObeliskOwned(absoluteURL: absoluteURL, relativePath: cleanedRelative)
        } else {
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        }

        let fullMarkdown = assemble(frontmatter: frontmatter, body: body)
        try atomicWrite(fullMarkdown, to: absoluteURL)
        return WriteResult(relativePath: cleanedRelative, absoluteURL: absoluteURL, created: !existed)
    }

    // MARK: - Path validation

    private static func normalize(relativePath raw: String) throws -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        cleaned = cleaned.replacingOccurrences(of: "\\", with: "/")
        while cleaned.hasPrefix("/") { cleaned.removeFirst() }
        guard !cleaned.isEmpty else {
            throw WriteError.invalidPath("path is empty")
        }
        if cleaned.contains("..") {
            throw WriteError.invalidPath("path may not contain '..' segments")
        }
        if !cleaned.lowercased().hasSuffix(".md") {
            cleaned += ".md"
        }
        return cleaned
    }

    /// Folder-level authorization. The first path segment ("" for files
    /// living at the vault root) must match one of the allowed entries
    /// (case-insensitive, trailing slashes ignored).
    ///
    /// Allowing `""` means "vault root only" — useful for daily notes
    /// when the user's Obsidian setup files them at the root.
    private static func checkAuthorized(path: String, allowed: [String]) throws {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        let topLevel: String = segments.count > 1 ? String(segments[0]) : ""
        let normalized = allowed.map {
            $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        }
        guard normalized.contains(topLevel.lowercased()) else {
            throw WriteError.unauthorizedFolder(path: path, allowed: allowed)
        }
    }

    // MARK: - Ownership check

    private static func requireObeliskOwned(absoluteURL: URL, relativePath: String) throws {
        guard let data = try? Data(contentsOf: absoluteURL),
              let text = String(data: data, encoding: .utf8) else {
            // Unreadable file at the target path is too suspicious — bail
            // rather than risk clobbering the user's bytes.
            throw WriteError.wouldOverwriteForeignNote(path: relativePath)
        }
        let parsed = FrontmatterParser.parse(text)
        guard case .string(let source)? = parsed.frontmatter["source"],
              source.lowercased() == "obelisk"
        else {
            throw WriteError.wouldOverwriteForeignNote(path: relativePath)
        }
    }

    // MARK: - Frontmatter assembly

    /// Compose the final markdown. `source: obelisk` is forced in even
    /// if the caller passed it explicitly (cheap guard against typos).
    /// Other keys are emitted in stable alphabetical order so diffs
    /// stay quiet across re-writes.
    private static func assemble(
        frontmatter caller: [String: FrontmatterValue],
        body: String
    ) -> String {
        var keys = caller
        keys["source"] = .scalar("obelisk")
        var lines: [String] = []
        for key in keys.keys.sorted() {
            switch keys[key]! {
            case .scalar(let raw):
                lines.append("\(key): \(yamlScalar(raw))")
            case .stringList(let items):
                if items.isEmpty {
                    lines.append("\(key): []")
                } else {
                    lines.append("\(key):")
                    for item in items {
                        lines.append("  - \(yamlScalar(item))")
                    }
                }
            }
        }
        let block = """
        ---
        \(lines.joined(separator: "\n"))
        ---

        """
        let bodyText = body.hasSuffix("\n") ? body : body + "\n"
        return block + bodyText
    }

    /// Conservative YAML scalar: quote when the value contains anything
    /// that would change YAML semantics (colon, bracket, leading dash,
    /// surrounding whitespace, etc.).
    private static func yamlScalar(_ raw: String) -> String {
        let needsQuoting = raw.isEmpty
            || raw != raw.trimmingCharacters(in: .whitespaces)
            || raw.contains(":")
            || raw.contains("#")
            || raw.contains("[")
            || raw.contains("]")
            || raw.contains("{")
            || raw.contains("}")
            || raw.hasPrefix("-")
        if needsQuoting {
            let escaped = raw.replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\""
        }
        return raw
    }

    // MARK: - Atomic write

    private static func atomicWrite(_ text: String, to destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        let tempURL = directory.appending(
            path: ".obelisk-write-" + UUID().uuidString,
            directoryHint: .notDirectory
        )
        let data = Data(text.utf8)
        try data.write(to: tempURL, options: .atomic)

        // `replaceItemAt` is the right primitive even on iOS — it handles
        // the create-or-replace fork atomically when both URLs live on
        // the same volume (which they do here).
        do {
            _ = try FileManager.default.replaceItemAt(destination, withItemAt: tempURL)
        } catch {
            // Best-effort cleanup; the user-facing error is the replace
            // failure, not the leftover temp.
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }
}
