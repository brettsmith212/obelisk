import Foundation

/// Fetch one note by vault-relative path. For modest notes the full body
/// is returned inline. Above ~24K characters (~6K tokens) we switch to
/// a chunked response per phase-b.md §7 — the model can call again with
/// `chunkIndex` to page through.
struct ReadNoteTool: Tool {
    let name = "read_note"
    let description = """
    Read a single note from the user's Obsidian vault by its \
    vault-relative path (e.g. 'Projects/Obelisk.md'). Returns the note's \
    frontmatter and body. Long notes come back chunked — call again with \
    'chunkIndex' to read the next chunk.
    """
    let argumentsSchema: JSONSchema = .object(
        properties: [
            "path":       .string(description: "Vault-relative path to the note."),
            "chunkIndex": .integer(description: "0-based chunk to read when the body was returned chunked."),
        ],
        required: ["path"]
    )

    /// ~6K-token threshold per phase-b.md §7. A crude 4-char-per-token
    /// approximation is fine for triggering the chunk path; the model
    /// doesn't need byte-exact agreement.
    private static let chunkThresholdChars = 24_000

    private let index: VaultIndex

    init(index: VaultIndex) {
        self.index = index
    }

    func run(arguments: JSONValue) async throws -> JSONValue {
        guard case .object(let props) = arguments,
              case .string(let path)? = props["path"],
              !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw ToolError.invalidArguments("'path' is required.")
        }

        guard let note = try index.note(at: path) else {
            throw ToolError.executionFailed("Note '\(path)' is not in the vault index.")
        }

        let baseFields: [String: JSONValue] = [
            "path":        .string(note.path),
            "title":       .string(note.title),
            "frontmatter": .object(note.frontmatter),
        ]
        let citation = Citation(
            path: note.path,
            title: note.title,
            snippet: snippet(from: note.body),
            score: nil
        )

        if note.body.count <= Self.chunkThresholdChars {
            return .object(
                baseFields.merging([
                    "body":      .string(note.body),
                    "citations": .array([citation.jsonValue]),
                ]) { _, new in new }
            )
        }

        // Long-note chunked path.
        let chunks = MarkdownChunker.chunk(note.body)
        let chunkIndex = Int(props["chunkIndex"]?.numberValue ?? 0)
        guard chunkIndex >= 0, chunkIndex < chunks.count else {
            throw ToolError.invalidArguments(
                "chunkIndex \(chunkIndex) is out of range (0…\(chunks.count - 1))."
            )
        }
        let chunk = chunks[chunkIndex]
        var out = baseFields
        out["chunkIndex"] = .number(Double(chunkIndex))
        out["chunkCount"] = .number(Double(chunks.count))
        out["heading"] = chunk.heading.map(JSONValue.string) ?? .null
        out["body"] = .string(chunk.text)
        out["citations"] = .array([citation.jsonValue])
        if chunkIndex + 1 < chunks.count {
            out["hint"] = .string(
                "More content available — call again with chunkIndex=\(chunkIndex + 1)."
            )
        }
        return .object(out)
    }

    /// Sources-card preview: first non-empty prose line, capped at 200 chars.
    /// Matches the helper used by `VaultIndex.citation` for consistency.
    private func snippet(from body: String) -> String {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let stripped = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty { return String(stripped.prefix(200)) }
        }
        return ""
    }
}
