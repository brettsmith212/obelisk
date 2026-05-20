import Foundation

/// Returns the current ISO-8601 timestamp and the user's local IANA time
/// zone identifier. Per phase-a.md §6, this tool exists primarily to
/// exercise the tool-calling loop end-to-end — it has no arguments and
/// can't fail under normal conditions.
struct DateTimeTool: Tool {
    let name = "datetime"
    let description = "Returns the current date and time in ISO-8601 format along with the user's local time zone."
    let argumentsSchema: JSONSchema = .empty

    func run(arguments: JSONValue) async throws -> JSONValue {
        let now = Date.now
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        return .object([
            "iso8601":  .string(iso.string(from: now)),
            "timeZone": .string(TimeZone.current.identifier)
        ])
    }
}
