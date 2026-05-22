import Foundation
import CryptoKit

/// Read (and optionally create) the daily note for a given date. The
/// path and filename format come from `.obsidian/daily-notes.json` —
/// `format` (moment.js-style) decides the filename stem and `folder`
/// decides where to look. Missing settings fall back to
/// `YYYY-MM-DD` in the vault root.
///
/// With `createIfMissing = true` the tool writes an empty note via
/// `VaultWriter`, carrying `source: obelisk` frontmatter, and inserts
/// it into the index so a follow-up `read_note` sees it.
struct ReadDailyNoteTool: Tool {
    let name = "read_daily_note"
    let description = """
    Read OR create the user's daily note for a given date (defaults to \
    today). This is THE tool for any prompt mentioning 'daily note', \
    'today's note', 'journal entry', 'my note for today', or asking \
    about a specific date like '2026-05-22'. Uses the vault's \
    daily-notes settings for the correct filename and folder. \
    Pass createIfMissing=true when the user wants to create the daily \
    note (e.g. 'create today's daily note', 'start my journal for \
    today'). DO NOT use create_note for daily notes — this tool puts \
    them in the right folder; create_note would put them in obelisk/.
    """
    let argumentsSchema: JSONSchema = .object(
        properties: [
            "date":            .string(description: "ISO-8601 date (YYYY-MM-DD). Defaults to today."),
            "createIfMissing": .boolean(description: "Create the note if it doesn't exist. Default false."),
        ],
        required: []
    )

    private let index: VaultIndex
    private let rootURLProvider: @Sendable () async -> URL?
    private let userDenyListProvider: @Sendable () async -> [String]

    init(
        index: VaultIndex,
        rootURLProvider: @escaping @Sendable () async -> URL?,
        userDenyListProvider: @escaping @Sendable () async -> [String] = { [] }
    ) {
        self.index = index
        self.rootURLProvider = rootURLProvider
        self.userDenyListProvider = userDenyListProvider
    }

    func run(arguments: JSONValue) async throws -> JSONValue {
        let props = arguments.objectValue ?? [:]
        let dateInput = props["date"]?.stringValue
        let createIfMissing = props["createIfMissing"]?.boolValue ?? false

        let date = try resolveDate(from: dateInput)

        guard let rootURL = await rootURLProvider() else {
            throw ToolError.executionFailed("No vault is connected.")
        }
        let config = ObsidianConfig.load(rootURL: rootURL).dailyNotes
        let filename = format(date: date, with: config.format) + ".md"
        let relativePath: String = {
            let folder = config.folder.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
            return folder.isEmpty ? filename : folder + "/" + filename
        }()

        // Index first — that's the source of truth for "currently exists".
        if let note = try index.note(at: relativePath) {
            let citation = Citation(
                path: note.path,
                title: note.title,
                snippet: firstNonEmptyLine(of: note.body),
                score: nil
            )
            return .object([
                "path":      .string(note.path),
                "title":     .string(note.title),
                "body":      .string(note.body),
                "created":   .bool(false),
                "exists":    .bool(true),
                "date":      .string(ISO8601Day.string(from: date)),
                "citations": .array([citation.jsonValue]),
            ])
        }

        if createIfMissing {
            return try await createDailyNote(
                relativePath: relativePath,
                filename: filename,
                date: date,
                rootURL: rootURL
            )
        }

        return .object([
            "path":      .string(relativePath),
            "title":     .string(filename.replacingOccurrences(of: ".md", with: "")),
            "body":      .string(""),
            "created":   .bool(false),
            "exists":    .bool(false),
            "date":      .string(ISO8601Day.string(from: date)),
            "citations": .array([]),
        ])
    }

    // MARK: - createIfMissing

    private func createDailyNote(
        relativePath: String,
        filename: String,
        date: Date,
        rootURL: URL
    ) async throws -> JSONValue {
        let title = filename.replacingOccurrences(of: ".md", with: "")
        // No folder special-case: under the denylist model the daily
        // notes folder is implicitly writable unless the user added it
        // to their deny list (in which case refusal is the right call).
        let userDenyList = await userDenyListProvider()

        let result: VaultWriter.WriteResult
        do {
            result = try VaultWriter.write(
                relativePath: relativePath,
                frontmatter: [
                    "title":     .scalar(title),
                    "createdAt": .scalar(ISO8601DateFormatter().string(from: Date())),
                    "tags":      .stringList(["daily"]),
                ],
                body: "",
                in: rootURL,
                userDenyList: userDenyList
            )
        } catch let error as VaultWriter.WriteError {
            throw ToolError.executionFailed(error.localizedDescription)
        }

        try upsertIntoIndex(result: result, title: title)

        let citation = Citation(
            path: result.relativePath,
            title: title,
            snippet: "",
            score: nil
        )
        return .object([
            "path":      .string(result.relativePath),
            "title":     .string(title),
            "body":      .string(""),
            "created":   .bool(result.created),
            "exists":    .bool(true),
            "date":      .string(ISO8601Day.string(from: date)),
            "citations": .array([citation.jsonValue]),
        ])
    }

    /// Synchronously reflect the newly-written daily note in the index
    /// so a follow-up `read_note` doesn't 404 between scans.
    private func upsertIntoIndex(
        result: VaultWriter.WriteResult,
        title: String
    ) throws {
        let data = (try? Data(contentsOf: result.absoluteURL)) ?? Data()
        let hash = SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }.joined()
        let text = String(data: data, encoding: .utf8) ?? ""
        let parsed = FrontmatterParser.parse(text)
        let tags = TagExtractor.extract(frontmatter: parsed.frontmatter, body: parsed.body)
        let links = WikilinkParser.parse(parsed.body)
        let modifiedAt = (try? result.absoluteURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()
        let note = VaultNote(
            path: result.relativePath,
            title: title,
            body: parsed.body,
            frontmatter: parsed.frontmatter,
            tags: tags,
            outboundLinks: links,
            contentHash: hash,
            modifiedAt: modifiedAt
        )
        let resolved = links.map { ResolvedLink(wikilink: $0, targetPath: nil) }
        try index.upsert(note: note, resolvedLinks: resolved, indexedAt: Date())
    }

    // MARK: - Helpers

    /// Parse the caller's `date` argument as an ISO-8601 calendar day.
    /// Missing → today (UTC start-of-day to match how daily notes are
    /// usually filed).
    private func resolveDate(from raw: String?) throws -> Date {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else {
            return Date()
        }
        if let parsed = ISO8601Day.parse(raw) {
            return parsed
        }
        throw ToolError.invalidArguments(
            "Invalid 'date' — expected YYYY-MM-DD, got '\(raw)'."
        )
    }

    /// Translate a moment.js-style format string into a `DateFormatter`
    /// pattern, then format the date. v1 supports the tokens that
    /// matter for the default Obsidian daily-notes format: `YYYY`,
    /// `YY`, `MM`, `DD`, `dd`, `ddd`, `dddd`. Unknown tokens fall back
    /// to `yyyy-MM-dd`.
    private func format(date: Date, with momentFormat: String) -> String {
        let translated = translateMomentFormat(momentFormat)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = translated
        return f.string(from: date)
    }

    private func translateMomentFormat(_ raw: String) -> String {
        // Map most-specific tokens first so e.g. `dddd` is replaced
        // before `dd`.
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
        // If translation left no recognized tokens, fall back to default.
        return out.isEmpty ? "yyyy-MM-dd" : out
    }

    private func firstNonEmptyLine(of body: String) -> String {
        for line in body.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let stripped = trimmed.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
            if !stripped.isEmpty { return String(stripped.prefix(200)) }
        }
        return ""
    }
}

// MARK: - ISO-8601 day formatter

private enum ISO8601Day {
    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate]
        return f
    }()

    static func string(from date: Date) -> String { formatter.string(from: date) }
    static func parse(_ raw: String) -> Date? { formatter.date(from: raw) }
}
