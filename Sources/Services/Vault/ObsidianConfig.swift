import Foundation

/// Read-only view of the `.obsidian/` settings that affect Obelisk's
/// behavior. Everything is optional — Obsidian itself treats these files
/// as soft configuration and we mirror that with sensible defaults.
///
/// We currently consume:
/// - `app.json`        → attachment folder, new-link format (not yet used)
/// - `daily-notes.json` → daily note format + folder + template path
/// - `core-plugins.json` → presence detection only (for warnings)
struct ObsidianConfig: Equatable, Sendable {
    let dailyNotes: DailyNotesConfig
    /// `true` if the Templater community plugin is installed — used only
    /// to warn the user that Obelisk-created daily notes won't run their
    /// template (per phase-b.md §10).
    let hasTemplaterPlugin: Bool

    struct DailyNotesConfig: Equatable, Sendable {
        /// moment.js-style format string. Default `YYYY-MM-DD`, matching
        /// Obsidian's default when the daily-notes plugin is disabled.
        let format: String
        /// Vault-relative folder for new daily notes. Default `""`
        /// (vault root), matching Obsidian.
        let folder: String
        /// Vault-relative path to the template file, if configured.
        let templatePath: String?
    }

    static let `default` = ObsidianConfig(
        dailyNotes: DailyNotesConfig(format: "YYYY-MM-DD", folder: "", templatePath: nil),
        hasTemplaterPlugin: false
    )

    // MARK: - Loading

    /// Load all settings from `<root>/.obsidian/`. Missing files quietly
    /// fall back to defaults. Caller is responsible for whatever access
    /// scope `rootURL` needs.
    static func load(rootURL: URL) -> ObsidianConfig {
        let obsidianDir = rootURL.appending(path: ".obsidian", directoryHint: .isDirectory)
        let daily = loadDailyNotes(in: obsidianDir)
        let templater = FileManager.default.fileExists(
            atPath: obsidianDir
                .appending(path: "plugins/templater-obsidian", directoryHint: .isDirectory)
                .path()
        )
        return ObsidianConfig(dailyNotes: daily, hasTemplaterPlugin: templater)
    }

    private static func loadDailyNotes(in obsidianDir: URL) -> DailyNotesConfig {
        let url = obsidianDir.appending(path: "daily-notes.json", directoryHint: .notDirectory)
        guard
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return DailyNotesConfig(format: "YYYY-MM-DD", folder: "", templatePath: nil)
        }
        let format = (json["format"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "YYYY-MM-DD"
        let folder = (json["folder"] as? String) ?? ""
        let template = (json["template"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return DailyNotesConfig(format: format, folder: folder, templatePath: template)
    }
}
