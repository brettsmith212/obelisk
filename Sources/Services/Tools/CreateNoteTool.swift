import Foundation
import CryptoKit

/// Create a note in the user's Obsidian vault. All "do no harm"
/// enforcement lives in `VaultWriter` — this tool's job is to shape
/// the request (filename, frontmatter, body) and to keep `VaultIndex`
/// consistent so a follow-up read tool sees the new note immediately.
///
/// Args (phase-b.md §7):
/// - `title` (required): becomes the note's filename stem and a
///   `title:` frontmatter key.
/// - `body` (required): markdown body.
/// - `folder` (optional, default `""` — vault root): vault subfolder to
///   drop the file into, matching where a manually-created Obsidian
///   note would land. Refused if any segment of the resulting path is
///   on the deny list (`.obsidian`, `.trash`, plus user-configured
///   entries).
/// - `tags` (optional): array of tag names (no leading '#').
struct CreateNoteTool: Tool {
    let name = "create_note"
    let description = """
    Create a new note in the user's Obsidian vault. Use this for prompts \
    like 'save a note about X' or 'write a note titled Y'. \
    DO NOT use this for daily notes or today's note — use read_daily_note \
    with createIfMissing=true instead. \
    IMPORTANT: If the user names a folder (e.g. 'in Archive', 'under \
    Projects/', 'inside my Inbox folder'), you MUST pass that exact \
    folder name in the 'folder' argument. Otherwise omit 'folder' — the \
    note lands in the vault root, matching where a manually-created \
    Obsidian note would go. \
    The note is stamped with 'source: obelisk' frontmatter automatically.
    """
    let argumentsSchema: JSONSchema = .object(
        properties: [
            "title":  .string(description: "Note title — becomes both the filename and the 'title' frontmatter key."),
            "body":   .string(description: "Markdown body."),
            "folder": .string(description: "Vault subfolder to write into. Pass the exact folder name the user mentioned (e.g. 'Archive', 'Projects/Active'). Omit when the user did not specify a folder — the note lands in the vault root."),
            "tags":   .array(items: .string(description: "Tag name without '#'."),
                             description: "Optional tags to write into frontmatter."),
        ],
        required: ["title", "body"]
    )

    private let index: VaultIndex
    private let rootURLProvider: @Sendable () async -> URL?
    private let userDenyListProvider: @Sendable () async -> [String]

    init(
        index: VaultIndex,
        rootURLProvider: @escaping @Sendable () async -> URL?,
        userDenyListProvider: @escaping @Sendable () async -> [String] = { [] }
    ) {
        self.index = index
        self.rootURLProvider = rootURLProvider
        self.userDenyListProvider = userDenyListProvider
    }

    func run(arguments: JSONValue) async throws -> JSONValue {
        guard case .object(let props) = arguments,
              case .string(let rawTitle)? = props["title"],
              !rawTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ToolError.invalidArguments("'title' is required.")
        }
        guard case .string(let body)? = props["body"] else {
            throw ToolError.invalidArguments("'body' is required.")
        }
        let folder = (props["folder"]?.stringValue ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let tags: [String] = {
            guard case .array(let arr)? = props["tags"] else { return [] }
            return arr.compactMap { $0.stringValue }
                .map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "# /")) }
                .filter { !$0.isEmpty }
        }()

        guard let rootURL = await rootURLProvider() else {
            throw ToolError.executionFailed("No vault is connected.")
        }

        let filename = sanitizeFilename(rawTitle) + ".md"
        let relativePath = folder.isEmpty ? filename : "\(folder)/\(filename)"

        // Compose frontmatter. `source: obelisk` is forced in by the
        // writer; we only need to add caller-supplied keys.
        var frontmatter: [String: VaultWriter.FrontmatterValue] = [
            "title":     .scalar(rawTitle),
            "createdAt": .scalar(ISO8601DateFormatter().string(from: Date())),
        ]
        if !tags.isEmpty {
            frontmatter["tags"] = .stringList(tags)
        }

        let userDenyList = await userDenyListProvider()
        let result: VaultWriter.WriteResult
        do {
            result = try VaultWriter.write(
                relativePath: relativePath,
                frontmatter: frontmatter,
                body: body,
                in: rootURL,
                userDenyList: userDenyList
            )
        } catch let error as VaultWriter.WriteError {
            // Surface the writer's structured errors as tool errors so
            // the chat shows the amber inline tool-error row.
            throw ToolError.executionFailed(error.localizedDescription)
        }

        // Reflect the new note in the index so the very next read tool
        // call sees it. Wikilink resolution is left to the next
        // incremental scan — single-note resolution would need the
        // global name map.
        try upsertIntoIndex(result: result, body: body)

        let citation = Citation(
            path: result.relativePath,
            title: rawTitle,
            snippet: firstNonEmptyLine(of: body),
            score: nil
        )
        return .object([
            "path":      .string(result.relativePath),
            "created":   .bool(result.created),
            "citations": .array([citation.jsonValue]),
        ])
    }

    // MARK: - Index sync

    private func upsertIntoIndex(
        result: VaultWriter.WriteResult,
        body: String
    ) throws {
        let writtenData = (try? Data(contentsOf: result.absoluteURL)) ?? Data()
        let hash = SHA256.hash(data: writtenData)
            .map { String(format: "%02x", $0) }
            .joined()
        let text = String(data: writtenData, encoding: .utf8) ?? ""
        let parsed = FrontmatterParser.parse(text)
        let tags = TagExtractor.extract(frontmatter: parsed.frontmatter, body: parsed.body)
        let links = WikilinkParser.parse(parsed.body)
        let modifiedAt = (try? result.absoluteURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        let note = VaultNote(
            path: result.relativePath,
            title: deriveTitle(relativePath: result.relativePath, frontmatter: parsed.frontmatter, body: parsed.body),
            body: parsed.body,
            frontmatter: parsed.frontmatter,
            tags: tags,
            outboundLinks: links,
            contentHash: hash,
            modifiedAt: modifiedAt
        )
        // Leave outbound links unresolved — the next incremental scan
        // will fix them via the global name map.
        let resolved = links.map { ResolvedLink(wikilink: $0, targetPath: nil) }
        try index.upsert(note: note, resolvedLinks: resolved, indexedAt: Date())
    }

    private func deriveTitle(
        relativePath: String,
        frontmatter: [String: JSONValue],
        body: String
    ) -> String {
        if case .string(let s) = frontmatter["title"], !s.isEmpty { return s }
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        let last = (relativePath as NSString).lastPathComponent
        return last.lowercased().hasSuffix(".md") ? String(last.dropLast(3)) : last
    }

    // MARK: - Helpers

    /// Strip filesystem-hostile characters and collapse whitespace. We
    /// keep this lenient — the model picks readable titles, we just
    /// guarantee the result is filesystem-safe.
    private func sanitizeFilename(_ raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let forbidden: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|"]
        cleaned = String(cleaned.map { forbidden.contains($0) ? "-" : $0 })
        // Collapse runs of spaces to a single space.
        while cleaned.contains("  ") {
            cleaned = cleaned.replacingOccurrences(of: "  ", with: " ")
        }
        // Reject leading dots so we don't create hidden files.
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.isEmpty { cleaned = "Untitled" }
        if cleaned.lowercased().hasSuffix(".md") {
            cleaned = String(cleaned.dropLast(3))
        }
        // Keep filenames reasonable — long titles wrap awkwardly in
        // Files.app and the document picker.
        if cleaned.count > 80 { cleaned = String(cleaned.prefix(80)) }
        return cleaned
    }

    private func firstNonEmptyLine(of body: String) -> String {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let stripped = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty { return String(stripped.prefix(120)) }
        }
        return ""
    }
}
