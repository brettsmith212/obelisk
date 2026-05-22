import Foundation

/// The single mediator for writing into a user's Obsidian vault.
///
/// Implements the "do no harm" rules from
/// [roadmap.md §"The 'do no harm' rules for vault writes"](../../../roadmap.md)
/// and phase-b.md §8 step 9:
///
/// - **Denylist gating.** Writes are refused if any segment of the
///   target path falls inside a denied folder. A hard-coded
///   `defaultDenyList` blocks `.obsidian/` and `.trash/` (editing
///   Obsidian's own config bricks the vault); an additional
///   `userDenyList` can be provided per call from `VaultAccessService`,
///   which the Vault Settings sheet edits.
/// - **Identity marker.** Every file Obelisk writes carries
///   `source: obelisk` in its YAML frontmatter. The writer injects this
///   automatically so callers never have to.
/// - **No clobbering.** If a file already exists at the target path, the
///   writer reads its frontmatter; if `source: obelisk` is absent, the
///   write is refused. This is the load-bearing safety net under the
///   denylist model — user-authored notes anywhere in the vault stay
///   untouchable even though their parent folder is implicitly writable.
/// - **Atomicity.** Bytes land via a sibling temp file + `replaceItemAt`,
///   so a mid-write crash never leaves a half-written file.
///
/// Stateless on purpose — tests / future tools can call it directly
/// without dragging the rest of the vault layer in.
enum VaultWriter {
    /// Folders the writer will never touch, no matter what the user
    /// configures. Editing `.obsidian/` corrupts the vault config;
    /// `.trash/` is reserved for Obsidian's own delete flow.
    static let defaultDenyList: [String] = [".obsidian", ".trash"]

    enum WriteError: Error, LocalizedError, Equatable {
        case deniedFolder(path: String, deniedSegment: String)
        case wouldOverwriteForeignNote(path: String)
        case invalidPath(String)

        var errorDescription: String? {
            switch self {
            case .deniedFolder(let path, let segment):
                return "Refusing to write to '\(path)' — '\(segment)/' is in the deny list."
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
    /// - Validating the target path against the deny list.
    /// - Injecting `source: obelisk` (preserving any caller-supplied
    ///   frontmatter keys).
    /// - Refusing to overwrite a file Obelisk didn't create.
    /// - Creating any missing intermediate directories.
    ///
    /// `userDenyList` is layered onto `defaultDenyList`; pass `[]` when
    /// no user customization applies.
    @discardableResult
    static func write(
        relativePath: String,
        frontmatter: [String: FrontmatterValue],
        body: String,
        in vaultRoot: URL,
        userDenyList: [String] = []
    ) throws -> WriteResult {
        let cleanedRelative = try normalize(relativePath: relativePath)
        let effectiveDenyList = defaultDenyList + userDenyList
        try checkNotDenied(path: cleanedRelative, denied: effectiveDenyList)

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

    /// Denylist gate. The check matches *any* segment of the relative
    /// path (folder or filename stem) against the configured deny
    /// entries — so `.obsidian/foo.md` and `archive/.obsidian/foo.md`
    /// both fail. Comparison is case-insensitive; user-supplied entries
    /// are trimmed of surrounding `/` and whitespace.
    private static func checkNotDenied(path: String, denied: [String]) throws {
        let segments = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).lowercased() }
        let normalizedDenied: [String] = denied
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")).lowercased() }
            .filter { !$0.isEmpty }
        for entry in normalizedDenied {
            if segments.contains(entry) {
                throw WriteError.deniedFolder(path: path, deniedSegment: entry)
            }
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
