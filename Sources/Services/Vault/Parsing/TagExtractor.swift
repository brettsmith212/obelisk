import Foundation

/// Extracts Obsidian-style tags from a note's frontmatter and body.
///
/// Frontmatter tags: pulled from a top-level `tags` key, which Obsidian
/// accepts as either a list, a single string, or a whitespace/comma-
/// separated string. All are normalized to lowercase, leading `#`
/// stripped, hierarchy preserved (`project/obelisk/phase-b` is one tag,
/// not three).
///
/// Inline tags: `#name` not preceded by an alphanumeric (so `foo#bar`
/// is not a tag) and stopping at whitespace or punctuation that isn't
/// `/`, `_`, or `-`. Numbers-only (`#123`) are ignored — Obsidian
/// treats those as plain text.
///
/// De-duplication: same tag from both sources is kept twice with
/// different `source` values, because the index column `tags.source`
/// surfaces that distinction to tools.
enum TagExtractor {
    static func extract(
        frontmatter: [String: JSONValue],
        body: String
    ) -> [VaultNote.TagOccurrence] {
        let fm = frontmatterTags(frontmatter)
            .map { VaultNote.TagOccurrence(tag: $0, source: .frontmatter) }
        let inline = inlineTags(body)
            .map { VaultNote.TagOccurrence(tag: $0, source: .inline) }
        return fm + inline
    }

    // MARK: - Frontmatter

    private static func frontmatterTags(_ fm: [String: JSONValue]) -> [String] {
        guard let raw = fm["tags"] else { return [] }

        var out: [String] = []
        switch raw {
        case .string(let s):
            // Split on whitespace and commas, accept "#a #b" or "a, b".
            let pieces = s.split { $0.isWhitespace || $0 == "," }
            for p in pieces {
                if let tag = normalize(String(p)) {
                    out.append(tag)
                }
            }
        case .array(let arr):
            for v in arr {
                if case .string(let s) = v, let tag = normalize(s) {
                    out.append(tag)
                }
            }
        default:
            break
        }

        // Preserve insertion order; de-dupe within frontmatter only.
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    // MARK: - Inline

    /// Allowed characters in the body of a tag (after the leading `#`).
    /// Letters, digits, `/`, `_`, `-`. Hierarchy uses `/`.
    private static let tagBodyChars: Set<Character> = {
        var s = Set<Character>()
        for c in "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_-" {
            s.insert(c)
        }
        return s
    }()

    private static func inlineTags(_ body: String) -> [String] {
        guard !body.isEmpty else { return [] }
        var out: [String] = []
        var seen = Set<String>()

        let chars = Array(body)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "#" {
                // Reject if preceded by an alphanumeric (`word#anchor`).
                let prev: Character? = i > 0 ? chars[i - 1] : nil
                if let p = prev, p.isLetter || p.isNumber {
                    i += 1
                    continue
                }
                // Collect tag body.
                var j = i + 1
                while j < chars.count, tagBodyChars.contains(chars[j]) {
                    j += 1
                }
                let bodyLen = j - (i + 1)
                if bodyLen > 0 {
                    let tagSlice = String(chars[(i + 1)..<j])
                    if let normalized = normalize(tagSlice),
                       !isNumericOnly(normalized) {
                        if seen.insert(normalized).inserted {
                            out.append(normalized)
                        }
                    }
                }
                i = j
            } else {
                i += 1
            }
        }
        return out
    }

    // MARK: - Helpers

    /// Lowercase, strip a single leading `#`, trim slashes from both ends,
    /// reject empty results.
    private static func normalize(_ raw: String) -> String? {
        var s = raw
        if s.hasPrefix("#") { s.removeFirst() }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        s = s.lowercased()
        guard !s.isEmpty else { return nil }
        // Reject runs of slashes producing empty segments ("a//b").
        if s.contains("//") { return nil }
        return s
    }

    private static func isNumericOnly(_ s: String) -> Bool {
        return s.allSatisfy { $0.isNumber }
    }
}
