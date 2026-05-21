import Foundation

/// Extracts `[[Wikilinks]]` from markdown body text.
///
/// Grammar handled (matches the Obsidian subset documented in
/// `Wikilink.swift`):
///
///     [[Target]]
///     [[Target|Display]]
///     [[Target#Heading]]
///     [[Target#Heading|Display]]
///     [[Target^block]]
///     [[Target^block|Display]]
///
/// We deliberately don't try to skip wikilinks inside fenced code blocks
/// in this pass; the cost of being slightly over-inclusive is one or two
/// noise rows in `links`, which is acceptable for v1. A future pass can
/// gate on `MarkdownChunker` AST positions if it matters.
enum WikilinkParser {
    static func parse(_ body: String) -> [Wikilink] {
        guard !body.isEmpty else { return [] }

        // Anything between `[[` and `]]` that doesn't contain another `[`
        // or `]`. Greedy `.` would over-match across nested or adjacent
        // links; the `[^\[\]]` character class keeps each link tight.
        let pattern = #"\[\[([^\[\]]+?)\]\]"#

        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let nsBody = body as NSString
        let range = NSRange(location: 0, length: nsBody.length)
        let matches = regex.matches(in: body, range: range)

        var links: [Wikilink] = []
        links.reserveCapacity(matches.count)
        for match in matches where match.numberOfRanges >= 2 {
            let inner = nsBody.substring(with: match.range(at: 1))
            if let link = parseInner(inner) {
                links.append(link)
            }
        }
        return links
    }

    // MARK: - Inner parse

    /// Split the inner text of a `[[...]]` into (target, heading, block,
    /// displayLabel). All four are optional except `target`.
    private static func parseInner(_ inner: String) -> Wikilink? {
        // Split off display label first (`|Display` is always the last
        // component when present).
        var rest = inner
        var displayLabel: String?
        if let pipeRange = rest.firstRange(of: "|") {
            displayLabel = String(rest[pipeRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            rest = String(rest[..<pipeRange.lowerBound])
        }

        // Then split off block ref (`^block`) — block always wins over
        // heading because Obsidian doesn't allow `#Heading^block` in
        // the link grammar.
        var block: String?
        if let caretRange = rest.firstRange(of: "^") {
            block = String(rest[caretRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            rest = String(rest[..<caretRange.lowerBound])
        }

        // Then heading.
        var heading: String?
        if block == nil, let hashRange = rest.firstRange(of: "#") {
            heading = String(rest[hashRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            rest = String(rest[..<hashRange.lowerBound])
        }

        let target = rest.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }

        return Wikilink(
            target: target,
            heading: heading?.isEmpty == true ? nil : heading,
            block: block?.isEmpty == true ? nil : block,
            displayLabel: displayLabel?.isEmpty == true ? nil : displayLabel,
            raw: inner
        )
    }
}
