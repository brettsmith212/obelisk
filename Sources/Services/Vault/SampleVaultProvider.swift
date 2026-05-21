#if DEBUG
import Foundation

/// Dev-mode shortcut for binding a vault without the document picker.
///
/// The Makefile target `make seed-vault VAULT=/path/to/vault` rsyncs an
/// existing vault into the simulator's app container at
/// `Documents/SampleVault/`. This provider just detects that folder and
/// produces a `VaultHandle` the rest of the vault layer can consume —
/// it's intentionally a thin lookup, not a copy step.
///
/// Gated behind `#if DEBUG` so this entry point cannot ship in TestFlight
/// or App Store builds; production users always go through the document
/// picker (Phase B Step 3).
enum SampleVaultProvider {
    /// Returns a `VaultHandle` if `Documents/SampleVault/` exists and
    /// contains at least one file. Returns `nil` if the seed step hasn't
    /// run or the folder is empty.
    static func detect() -> VaultHandle? {
        let url = sampleVaultURL
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path(), isDirectory: &isDir), isDir.boolValue else {
            return nil
        }

        // Reject an empty directory — that's almost certainly an
        // accidentally-created folder, not a usable vault.
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: url.path())) ?? []
        guard !contents.isEmpty else { return nil }

        return VaultHandle(rootURL: url, accessKind: .appSandbox)
    }

    /// Diagnostic info shown in the dev gate so the developer can confirm
    /// the seed worked before binding the vault.
    static func summary() -> Summary? {
        let url = sampleVaultURL
        guard FileManager.default.fileExists(atPath: url.path()) else { return nil }

        let markdownCount = countMarkdown(under: url)
        let hasObsidianConfig = FileManager.default.fileExists(
            atPath: url.appending(path: ".obsidian", directoryHint: .isDirectory).path()
        )
        return Summary(
            path: url.path(),
            markdownCount: markdownCount,
            hasObsidianConfig: hasObsidianConfig
        )
    }

    struct Summary: Sendable {
        let path: String
        let markdownCount: Int
        let hasObsidianConfig: Bool
    }

    // MARK: - Internals

    private static var sampleVaultURL: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first!
            .appending(path: "SampleVault", directoryHint: .isDirectory)
    }

    /// Recursive `.md` count. Used only for the diagnostic summary so a
    /// naive walk is fine — full vault scanning is `VaultScanner`'s job.
    private static func countMarkdown(under root: URL) -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        var count = 0
        for case let url as URL in enumerator
        where url.pathExtension.lowercased() == "md" {
            count += 1
        }
        return count
    }
}
#endif
