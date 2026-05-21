import Foundation
import Yams

/// Splits an Obsidian markdown file into `(frontmatter, body)`.
///
/// Obsidian frontmatter rules we care about:
/// - Must start at byte 0 with a line of exactly `---`.
/// - Closed by a subsequent line of exactly `---` (or `...`, per YAML).
/// - Everything between is parsed as YAML; whatever follows the closer
///   is the markdown body.
/// - If the opener exists but no closer is found, the whole file is body
///   (Obsidian's behavior — silently dropping content would be worse).
///
/// We intentionally do **not** round-trip the YAML on write — the writer
/// in Phase B's later step splices new keys in by line offset so comments
/// and formatting survive untouched. This parser is read-only.
enum FrontmatterParser {
    struct Result: Equatable, Sendable {
        let frontmatter: [String: JSONValue]
        let body: String
    }

    static func parse(_ text: String) -> Result {
        guard text.hasPrefix("---") else {
            return Result(frontmatter: [:], body: text)
        }

        // Walk lines until we find a closing fence. Using `components` keeps
        // line endings normal; we rejoin with `\n` for the body which is
        // fine because the index doesn't need byte-exact preservation.
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---" else {
            return Result(frontmatter: [:], body: text)
        }

        var closingIndex: Int?
        for i in 1..<lines.count {
            let line = lines[i]
            if line == "---" || line == "..." {
                closingIndex = i
                break
            }
        }

        guard let close = closingIndex else {
            // Unterminated — treat the whole file as body, like Obsidian.
            return Result(frontmatter: [:], body: text)
        }

        let yamlSlice = lines[1..<close].joined(separator: "\n")
        let bodyLines = lines[(close + 1)...]
        let body = bodyLines.joined(separator: "\n")

        let parsed = parseYAMLDict(yamlSlice)
        return Result(frontmatter: parsed, body: body)
    }

    // MARK: - YAML → JSONValue

    private static func parseYAMLDict(_ yaml: String) -> [String: JSONValue] {
        guard !yaml.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [:]
        }
        do {
            let any = try Yams.load(yaml: yaml)
            guard let dict = any as? [String: Any] else { return [:] }
            return dict.compactMapValues(convert)
        } catch {
            // Malformed frontmatter is common in the wild. Don't fail the
            // whole scan — just drop the metadata for this note.
            return [:]
        }
    }

    private static func convert(_ any: Any) -> JSONValue? {
        if any is NSNull { return .null }
        if let b = any as? Bool { return .bool(b) }
        if let i = any as? Int { return .number(Double(i)) }
        if let d = any as? Double { return .number(d) }
        if let s = any as? String { return .string(s) }
        if let date = any as? Date {
            // ISO-8601 string keeps things JSON-clean and human-readable
            // in the index. We never need original Date semantics back.
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime]
            return .string(f.string(from: date))
        }
        if let arr = any as? [Any] {
            return .array(arr.compactMap(convert))
        }
        if let dict = any as? [String: Any] {
            return .object(dict.compactMapValues(convert))
        }
        if let dict = any as? [AnyHashable: Any] {
            // Yams sometimes returns non-String keys; coerce.
            var out: [String: JSONValue] = [:]
            for (k, v) in dict {
                if let key = k as? String, let value = convert(v) {
                    out[key] = value
                }
            }
            return .object(out)
        }
        return nil
    }
}
