import SwiftUI

/// "Sources" card per [ui-spec.md §4.6](../../ui-spec.md). Appears at the
/// end of an assistant turn whose tool calls returned citations.
///
/// - Header: "Sources" in secondary text.
/// - Up to 3 rows expanded by default; `+ N more` reveals the rest.
/// - Each row: file glyph + note title + 1–2-line snippet, tappable.
/// - Tap a row → `obsidian://open?vault=…&file=…` via `openURL`.
/// - No in-app preview sheet (principle 1 in ui-spec.md §1).
struct SourcesCard: View {
    let citations: [Citation]
    let vaultName: String

    @State private var expanded: Bool = false
    @Environment(\.openURL) private var openURL

    private static let collapsedRowLimit = 3

    private var visibleCount: Int {
        expanded ? citations.count : min(Self.collapsedRowLimit, citations.count)
    }

    private var hiddenCount: Int {
        max(0, citations.count - Self.collapsedRowLimit)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sources")
                .font(.obMeta)
                .foregroundStyle(Color.obTextSecondary)

            VStack(alignment: .leading, spacing: 0) {
                ForEach(0..<visibleCount, id: \.self) { idx in
                    if idx > 0 {
                        Divider().background(Color.obBorder)
                    }
                    CitationRow(citation: citations[idx]) {
                        if let url = Self.deepLink(for: citations[idx], vault: vaultName) {
                            openURL(url)
                        }
                    }
                }

                if !expanded && hiddenCount > 0 {
                    Divider().background(Color.obBorder)
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { expanded = true }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.down")
                            Text("+ \(hiddenCount) more")
                        }
                        .font(.obMeta)
                        .foregroundStyle(Color.obTextTertiary)
                        .padding(.horizontal, ObSpacing.cardH)
                        .padding(.vertical, 10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.plain)
                }
            }
            .background(
                RoundedRectangle(cornerRadius: ObRadius.card, style: .continuous)
                    .fill(Color.obBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ObRadius.card, style: .continuous)
                    .stroke(Color.obBorder, lineWidth: ObStroke.hairline)
            )
        }
    }

    // MARK: - Deep link

    /// `obsidian://open?vault=<vault>&file=<path-without-md>`. Both
    /// components must be percent-encoded individually because Obsidian
    /// treats the `vault` and `file` query values as raw filesystem-ish
    /// strings (spaces, slashes, unicode all allowed).
    static func deepLink(for citation: Citation, vault: String) -> URL? {
        var fileToken = citation.path
        if fileToken.lowercased().hasSuffix(".md") {
            fileToken = String(fileToken.dropLast(3))
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
}

// MARK: - Row

private struct CitationRow: View {
    let citation: Citation
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "doc.text")
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Color.obTextSecondary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(citation.title)
                        .font(.obBody)
                        .foregroundStyle(Color.obTextPrimary)
                        .lineLimit(1)
                    if !citation.snippet.isEmpty {
                        Text(citation.snippet)
                            .font(.obMeta)
                            .foregroundStyle(Color.obTextSecondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, ObSpacing.cardH)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Extraction

extension SourcesCard {
    /// Walk every successful tool call on the message and collect the
    /// citations it returned. Dedup by `path` (first occurrence wins so
    /// search-tool ordering and scores are preserved); preserves first-
    /// seen order across the conversation turn.
    ///
    /// Failed tool calls (those with `result.error != nil`) contribute
    /// nothing. Tools that don't emit a `citations` array (e.g. the
    /// calculator) are silently skipped.
    static func citations(in message: Message) -> [Citation] {
        var seen = Set<String>()
        var result: [Citation] = []
        for call in message.toolCalls {
            guard let toolResult = call.result, toolResult.error == nil,
                  let items = toolResult.output.objectValue?["citations"]?.arrayValue
            else { continue }
            for item in items {
                guard let citation = decode(item) else { continue }
                if seen.insert(citation.path).inserted {
                    result.append(citation)
                }
            }
        }
        return result
    }

    private static func decode(_ value: JSONValue) -> Citation? {
        guard let obj = value.objectValue,
              let path = obj["path"]?.stringValue,
              let title = obj["title"]?.stringValue
        else { return nil }
        return Citation(
            path: path,
            title: title,
            snippet: obj["snippet"]?.stringValue ?? "",
            score: obj["score"]?.numberValue
        )
    }
}
