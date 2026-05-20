import Foundation

/// A deliberately slim subset of JSON Schema, just rich enough to describe
/// the three Phase A tools (`DateTime`, `Calculator`, `Scratchpad`).
///
/// The `LLMRunner` seam carries this neutral type; `AppleFoundationRunner`
/// translates it into a `@Generable` arg struct internally. Keep the cases
/// minimal — anything we add here, both backends must be able to render.
indirect enum JSONSchema: Sendable, Equatable {
    case string(description: String? = nil, enumValues: [String]? = nil)
    case number(description: String? = nil)
    case integer(description: String? = nil)
    case boolean(description: String? = nil)
    case array(items: JSONSchema, description: String? = nil)
    case object(
        properties: [String: JSONSchema],
        required: [String] = [],
        description: String? = nil
    )

    /// Convenience: a schema for a tool that takes no arguments.
    static let empty: JSONSchema = .object(properties: [:], required: [])
}
