import SwiftUI

/// Renders assistant prose that may contain `[[Wikilinks]]` per
/// [ui-spec.md §4.7](../../ui-spec.md) (and the styling rules in §2.2):
///
/// - `[[` and `]]` brackets render at ~40% accent opacity.
/// - The note name inside renders in accent purple, semibold.
/// - The whole wikilink span is tappable; tap → `obsidian://open?vault=…
///   &file=Target#Heading` (or `…#^block`) via SwiftUI's `openURL`.
/// - Display labels (`[[Target|Label]]`) are rendered in place of the
///   target; the deep link still resolves to `Target`.
///
/// Recognized grammar matches `WikilinkParser` (Phase B parsing layer):
/// `[[Target]]`, `[[Target|Display]]`, `[[Target#Heading]]`,
/// `[[Target#Heading|Display]]`, `[[Target^block]]`,
/// `[[Target^block|Display]]`.
///
/// If `vaultName` is nil/empty, wikilinks still render with the right
/// styling but carry no `.link` attribute (taps are no-ops). That
/// matches the "vault disconnected" graceful-degradation behavior.
struct WikilinkText: View {
    let content: String
    let vaultName: String?

    var body: some View {
        Text(Self.attributed(content, vaultName: vaultName))
            .tint(Color.obAccent)
            .textSelection(.enabled)
    }

    // MARK: - Attributed string assembly

    /// Walks `content`, replacing every `[[…]]` span with three styled
    /// segments (open bracket, inner name, close bracket). All other
    /// text is appended verbatim.
    static func attributed(_ content: String, vaultName: String?) -> AttributedString {
        var result = AttributedString()
        let nsContent = content as NSString
        let fullRange = NSRange(location: 0, length: nsContent.length)
        let matches = Self.regex?.matches(in: content, range: fullRange) ?? []

        var cursor = 0
        for match in matches where match.numberOfRanges >= 2 {
            let outer = match.range(at: 0)
            if outer.location > cursor {
                let plain = nsContent.substring(
                    with: NSRange(location: cursor, length: outer.location - cursor)
                )
                result.append(AttributedString(plain))
            }
            let inner = nsContent.substring(with: match.range(at: 1))
            if let parsed = parseInner(inner) {
                result.append(stylized(parsed: parsed, raw: inner, vaultName: vaultName))
            } else {
                // Malformed inner — fall back to the literal text.
                result.append(AttributedString("[[\(inner)]]"))
            }
            cursor = outer.location + outer.length
        }

        if cursor < nsContent.length {
            let tail = nsContent.substring(
                with: NSRange(location: cursor, length: nsContent.length - cursor)
            )
            result.append(AttributedString(tail))
        }
        return result
    }

    /// Three-segment rendering: dim `[[`, accent semibold display, dim `]]`.
    /// All three segments carry the same `.link` attribute so the entire
    /// wikilink (including brackets) is one tap target.
    private static func stylized(
        parsed: Parsed,
        raw: String,
        vaultName: String?
    ) -> AttributedString {
        let display = parsed.displayLabel ?? parsed.target
        let url = deepLink(parsed: parsed, vaultName: vaultName)

        var open = AttributedString("[[")
        open.foregroundColor = Color.obAccent.opacity(0.4)
        if let url { open.link = url }

        var name = AttributedString(display)
        name.foregroundColor = Color.obAccent
        name.font = .obBody.weight(.semibold)
        if let url { name.link = url }

        var close = AttributedString("]]")
        close.foregroundColor = Color.obAccent.opacity(0.4)
        if let url { close.link = url }

        var combined = open
        combined.append(name)
        combined.append(close)
        return combined
    }

    // MARK: - Deep link

    /// `obsidian://open?vault=<vault>&file=<Target[#Heading|#^block]>`.
    /// Heading and block refs are appended to `file` per Obsidian's
    /// URL scheme. Returns `nil` if there's no vault bound.
    static func deepLink(parsed: Parsed, vaultName: String?) -> URL? {
        guard let vault = vaultName, !vault.isEmpty else { return nil }
        var fileToken = parsed.target
        if let block = parsed.block, !block.isEmpty {
            fileToken += "#^" + block
        } else if let heading = parsed.heading, !heading.isEmpty {
            fileToken += "#" + heading
        }
        var components = URLComponents()
        components.scheme = "obsidian"
        components.host = "open"
        components.queryItems = [
            URLQueryItem(name: "vault", value: vault),
            URLQueryItem(name: "file", value: fileToken),
        ]
        return components.url
    }

    // MARK: - Parsing primitives

    struct Parsed: Equatable {
        let target: String
        let heading: String?
        let block: String?
        let displayLabel: String?
    }

    /// Mirrors `WikilinkParser.parseInner` but kept inline here so the UI
    /// layer doesn't depend on the indexing layer. Inner format:
    /// `Target[#Heading|^block][|Display]`.
    static func parseInner(_ inner: String) -> Parsed? {
        var rest = inner
        var displayLabel: String?
        if let pipe = rest.firstRange(of: "|") {
            displayLabel = String(rest[pipe.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            rest = String(rest[..<pipe.lowerBound])
        }
        var block: String?
        if let caret = rest.firstRange(of: "^") {
            block = String(rest[caret.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            rest = String(rest[..<caret.lowerBound])
        }
        var heading: String?
        if block == nil, let hash = rest.firstRange(of: "#") {
            heading = String(rest[hash.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            rest = String(rest[..<hash.lowerBound])
        }
        let target = rest.trimmingCharacters(in: .whitespaces)
        guard !target.isEmpty else { return nil }
        return Parsed(target: target, heading: heading, block: block, displayLabel: displayLabel)
    }

    /// Same regex as `WikilinkParser` — anything between `[[` and `]]`
    /// that doesn't itself contain `[` or `]`.
    private static let regex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\[\[([^\[\]]+?)\]\]"#)
    }()
}
