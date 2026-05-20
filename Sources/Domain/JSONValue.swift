import Foundation

/// A schema-agnostic JSON value used for tool arguments and tool results
/// flowing across the `LLMRunner` seam.
///
/// Why an explicit enum and not `Any`/`[String: Any]`:
/// - Codable round-trips through `Conversation` persistence (Phase A §5).
/// - The seam stays neutral — Foundation-Models-specific encoding (e.g.
///   `@Generable`) is built *inside* `AppleFoundationRunner` from this value,
///   never leaked through the protocol.
///
/// Construction shortcuts: literal conformances let callers write
/// `JSONValue.object(["x": 1, "y": "hi"])` without wrapping every leaf.
enum JSONValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: - Codable

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let b = try? c.decode(Bool.self) {
            self = .bool(b)
        } else if let n = try? c.decode(Double.self) {
            self = .number(n)
        } else if let s = try? c.decode(String.self) {
            self = .string(s)
        } else if let a = try? c.decode([JSONValue].self) {
            self = .array(a)
        } else if let o = try? c.decode([String: JSONValue].self) {
            self = .object(o)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c,
                debugDescription: "JSONValue: unsupported value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:           try c.encodeNil()
        case .bool(let b):    try c.encode(b)
        case .number(let n):  try c.encode(n)
        case .string(let s):  try c.encode(s)
        case .array(let a):   try c.encode(a)
        case .object(let o):  try c.encode(o)
        }
    }
}

// MARK: - Convenience accessors

extension JSONValue {
    var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    var numberValue: Double? { if case .number(let n) = self { return n } else { return nil } }
    var boolValue:   Bool?   { if case .bool(let b)   = self { return b } else { return nil } }
    var objectValue: [String: JSONValue]? { if case .object(let o) = self { return o } else { return nil } }
    var arrayValue:  [JSONValue]? { if case .array(let a) = self { return a } else { return nil } }
}
