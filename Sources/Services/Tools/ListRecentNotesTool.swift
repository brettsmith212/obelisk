import Foundation

/// Notes modified within a trailing time window, newest first. Used by
/// prompts like "what was I working on this week".
struct ListRecentNotesTool: Tool {
    let name = "list_recent_notes"
    let description = """
    List notes in the user's Obsidian vault that were modified within \
    the last N days, newest first. Use this for 'what did I touch \
    recently' or 'what was I working on'.
    """
    let argumentsSchema: JSONSchema = .object(
        properties: [
            "days":  .integer(description: "Trailing window in days. Default 7."),
            "limit": .integer(description: "Max notes to return. Default 20."),
        ],
        required: []
    )

    private let index: VaultIndex

    init(index: VaultIndex) {
        self.index = index
    }

    func run(arguments: JSONValue) async throws -> JSONValue {
        var days = 7
        var limit = 20
        if case .object(let props) = arguments {
            if let raw = props["days"]?.numberValue {
                days = max(1, min(Int(raw), 365))
            }
            if let raw = props["limit"]?.numberValue {
                limit = max(1, min(Int(raw), 100))
            }
        }

        let notes = try index.recentNotes(within: days, limit: limit)
        let rows: [JSONValue] = notes.map { n in
            .object([
                "path":       .string(n.path),
                "title":      .string(n.title),
                "modifiedAt": .string(VaultToolFormatting.iso(n.modifiedAt)),
            ])
        }
        let citations: [JSONValue] = try notes.compactMap { n in
            try index.citation(forPath: n.path)?.jsonValue
        }
        return .object([
            "days":      .number(Double(days)),
            "notes":     .array(rows),
            "citations": .array(citations),
        ])
    }
}
