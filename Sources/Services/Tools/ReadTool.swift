import Foundation

/// The second of the two AFM-realistic vault tools. Returns the
/// content of one note — addressed either by `path` (any vault note)
/// or by `daily` (the user's date-based daily note). Strictly
/// read-only; creation is deferred to a future `write` tool.
///
/// Dispatch rules:
///   - `daily` set → resolve via `.obsidian/daily-notes.json`, look
///     up in the index, and return either the contents or a
///     `{ exists: false }` payload so the model can tell the user.
///   - `path` set  → straight read from the index.
///   - neither    → invalid arguments.
///
/// Body is returned as a `~1500`-char preview unless `full: true`, to
/// keep the tool output within AFM's 4096-token window.
struct ReadTool: Tool {
    let name = "read"
    let description = "Read the contents of one vault note (by path, or today's daily)."
    let argumentsSchema: JSONSchema = .object(
        properties: [
            "path":  .string(description: "Vault-relative path of any note."),
            "daily": .string(description: "'today' or YYYY-MM-DD for the daily note."),
            "full":  .boolean(description: "Return the full body instead of a preview."),
        ],
        required: []
    )

    /// Preview length when `full` is not set. ~1500 chars ≈ 375
    /// tokens — fits comfortably inside AFM's window.
    private static let previewChars = 1_500

    private let index: VaultIndex
    private let rootURLProvider: @Sendable () async -> URL?

    init(
        index: VaultIndex,
        rootURLProvider: @escaping @Sendable () async -> URL?
    ) {
        self.index = index
        self.rootURLProvider = rootURLProvider
    }

    func run(arguments: JSONValue) async throws -> JSONValue {
        let props = arguments.objectValue ?? [:]
        let full = props["full"]?.boolValue ?? false

        // Daily branch is mutually exclusive with `path`; if both are
        // supplied (model uncertainty), `daily` wins because that's
        // the most specific intent.
        if let daily = props["daily"]?.stringValue?.trimmedNonEmpty {
            return try await readDaily(dailyArg: daily, full: full)
        }

        if let path = props["path"]?.stringValue?.trimmedNonEmpty {
            return try readByPath(path: path, full: full)
        }

        throw ToolError.invalidArguments(
            "Provide either 'path' (any vault note) or 'daily' (date-based daily note)."
        )
    }

    // MARK: - Path branch

    private func readByPath(path: String, full: Bool) throws -> JSONValue {
        guard let note = try index.note(at: path) else {
            throw ToolError.executionFailed("Note '\(path)' is not in the vault index.")
        }
        recordOpen(path: note.path, source: .readNote)
        return Self.payload(
            path: note.path,
            title: note.title,
            frontmatter: note.frontmatter,
            body: note.body,
            full: full
        )
    }

    // MARK: - Daily branch

    private func readDaily(dailyArg: String, full: Bool) async throws -> JSONValue {
        let date = try resolveDate(from: dailyArg)
        guard let rootURL = await rootURLProvider() else {
            throw ToolError.executionFailed("No vault is connected.")
        }
        let config = ObsidianConfig.load(rootURL: rootURL).dailyNotes
        let filename = format(date: date, with: config.format) + ".md"
        let relativePath: String = {
            let folder = config.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            return folder.isEmpty ? filename : folder + "/" + filename
        }()

        if let note = try index.note(at: relativePath) {
            recordOpen(path: note.path, source: .dailyNote)
            return Self.payload(
                path: note.path,
                title: note.title,
                frontmatter: note.frontmatter,
                body: note.body,
                full: full
            )
        }

        // Doesn't exist. Return a structured "missing" payload rather
        // than throwing so the model can tell the user it hasn't been
        // created yet instead of erroring out.
        return .object([
            "path":   .string(relativePath),
            "title":  .string(filename.replacingOccurrences(of: ".md", with: "")),
            "body":   .string(""),
            "exists": .bool(false),
        ])
    }

    // MARK: - Date / format helpers

    /// Accept either `"today"` (case-insensitive) or a YYYY-MM-DD
    /// ISO-8601 calendar day.
    private func resolveDate(from raw: String) throws -> Date {
        if raw.caseInsensitiveCompare("today") == .orderedSame {
            return Date()
        }
        if let parsed = ISO8601Day.parse(raw) {
            return parsed
        }
        throw ToolError.invalidArguments(
            "Invalid 'daily' value — expected 'today' or YYYY-MM-DD, got '\(raw)'."
        )
    }

    private func format(date: Date, with momentFormat: String) -> String {
        let translated = translateMomentFormat(momentFormat)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = translated
        return f.string(from: date)
    }

    private func translateMomentFormat(_ raw: String) -> String {
        var out = raw
        let pairs: [(String, String)] = [
            ("YYYY", "yyyy"),
            ("YY",   "yy"),
            ("MMMM", "MMMM"),
            ("MMM",  "MMM"),
            ("MM",   "MM"),
            ("DDDD", "DDD"),
            ("DD",   "dd"),
            ("dddd", "EEEE"),
            ("ddd",  "EEE"),
            ("dd",   "EE"),
        ]
        for (from, to) in pairs {
            out = out.replacingOccurrences(of: from, with: to)
        }
        return out.isEmpty ? "yyyy-MM-dd" : out
    }

    // MARK: - Frecency

    private func recordOpen(path: String, source: FrecencyTracker.Source) {
        let frecency = index.frecency
        Task.detached(priority: .utility) {
            frecency.recordOpen(path: path, source: source)
        }
    }

    // MARK: - Payload shaping

    /// Shared output envelope. Truncates the body to a preview unless
    /// the caller asked for the full text.
    private static func payload(
        path: String,
        title: String,
        frontmatter: [String: JSONValue],
        body: String,
        full: Bool
    ) -> JSONValue {
        let isTruncated = !full && body.count > previewChars
        let effective = isTruncated
            ? String(body.prefix(previewChars)) + "…"
            : body
        var out: [String: JSONValue] = [
            "path":        .string(path),
            "title":       .string(title),
            "frontmatter": .object(frontmatter),
            "body":        .string(effective),
        ]
        if isTruncated {
            out["isPreview"] = .bool(true)
        }
        out["citations"] = .array([
            Citation(path: path, title: title, snippet: "", score: nil).jsonValue
        ])
        return .object(out)
    }
}

// MARK: - ISO-8601 day formatter

private enum ISO8601Day {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()
    static func parse(_ raw: String) -> Date? { formatter.date(from: raw) }
}

private extension String {
    var trimmedNonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
