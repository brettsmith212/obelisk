import Foundation
import Markdown

/// Splits a markdown body into sized, heading-aware chunks suitable for
/// embedding in Phase C. Built now per the phase-b plan; no caller in
/// Phase B uses it yet.
///
/// Strategy:
/// - Walk the markdown AST (swift-markdown).
/// - Cut at H1/H2/H3 boundaries.
/// - If any heading section is larger than `maxChars`, split it on
///   paragraph boundaries to stay under the limit.
/// - Carry the most recent heading text on each chunk so the embedding
///   record can be retrieved with context (`heading` column in the
///   reserved `embeddings` table).
enum MarkdownChunker {
    struct Chunk: Equatable, Sendable {
        /// Zero-based index within the note.
        let index: Int
        /// Nearest heading covering this chunk, or `nil` for preamble
        /// before the first heading.
        let heading: String?
        /// Byte offsets into the original body (start inclusive, end
        /// exclusive). Used by the index for slicing snippets.
        let start: Int
        let end: Int
        let text: String
    }

    /// Default target is ~800 characters (~200 tokens), comfortably
    /// below typical embedding context windows.
    static func chunk(_ body: String, maxChars: Int = 800) -> [Chunk] {
        guard !body.isEmpty else { return [] }

        let doc = Document(parsing: body)
        var sections: [(heading: String?, start: Int, end: Int)] = []
        var currentHeading: String?
        var currentStart = 0

        // First pass: find heading boundaries by source range.
        for child in doc.children {
            if let heading = child as? Heading, heading.level <= 3 {
                if let range = heading.range {
                    let offset = offset(in: body, line: range.lowerBound.line, column: range.lowerBound.column)
                    if offset > currentStart {
                        sections.append((currentHeading, currentStart, offset))
                    }
                    currentStart = offset
                    currentHeading = heading.plainText
                }
            }
        }
        if currentStart < body.utf8.count {
            sections.append((currentHeading, currentStart, body.utf8.count))
        }
        if sections.isEmpty {
            sections = [(nil, 0, body.utf8.count)]
        }

        // Second pass: split oversized sections on blank-line boundaries.
        var chunks: [Chunk] = []
        var idx = 0
        for section in sections {
            let slice = utf8Slice(body, start: section.start, end: section.end)
            if slice.count <= maxChars {
                chunks.append(
                    Chunk(
                        index: idx,
                        heading: section.heading,
                        start: section.start,
                        end: section.end,
                        text: slice
                    )
                )
                idx += 1
                continue
            }

            // Split on double-newline paragraphs, packing greedily.
            let paragraphs = slice.components(separatedBy: "\n\n")
            var buffer = ""
            var bufferStart = section.start
            var cursor = section.start
            for (i, p) in paragraphs.enumerated() {
                let trailing = (i == paragraphs.count - 1) ? "" : "\n\n"
                let piece = p + trailing
                if buffer.count + piece.count > maxChars, !buffer.isEmpty {
                    chunks.append(
                        Chunk(
                            index: idx,
                            heading: section.heading,
                            start: bufferStart,
                            end: cursor,
                            text: buffer
                        )
                    )
                    idx += 1
                    buffer = ""
                    bufferStart = cursor
                }
                buffer += piece
                cursor += piece.utf8.count
            }
            if !buffer.isEmpty {
                chunks.append(
                    Chunk(
                        index: idx,
                        heading: section.heading,
                        start: bufferStart,
                        end: cursor,
                        text: buffer
                    )
                )
                idx += 1
            }
        }

        return chunks
    }

    // MARK: - Offset helpers

    /// Convert a 1-based `(line, column)` from swift-markdown into a
    /// byte offset into `body`. Column is treated as a UTF-8 column.
    private static func offset(in body: String, line: Int, column: Int) -> Int {
        var current = 0
        var lineNo = 1
        let utf8 = Array(body.utf8)
        while current < utf8.count, lineNo < line {
            if utf8[current] == 0x0A { lineNo += 1 }
            current += 1
        }
        return min(current + max(column - 1, 0), utf8.count)
    }

    /// Extract the substring covering the half-open UTF-8 byte range
    /// `[start, end)`. Used because swift-markdown ranges are in
    /// `SourceLocation` line/column form which we convert above.
    private static func utf8Slice(_ body: String, start: Int, end: Int) -> String {
        let bytes = Array(body.utf8)
        let clampedEnd = min(end, bytes.count)
        let clampedStart = max(0, min(start, clampedEnd))
        let sub = Array(bytes[clampedStart..<clampedEnd])
        return String(decoding: sub, as: UTF8.self)
    }
}
