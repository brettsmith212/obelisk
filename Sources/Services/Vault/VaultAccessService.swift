import Foundation
import Observation

/// The single mediator between the rest of the vault layer (scanner,
/// parsers, tools) and the underlying file system. Owns the *active*
/// `VaultHandle` and is the only place that knows about security-scoped
/// bookmarks, `NSFileCoordinator`, or the difference between sample-vault
/// and picked-vault flows.
///
/// Phase B scope:
/// - Active vault binding + persistence across launches.
/// - Document picker → security-scoped bookmark → restore on launch.
/// - For picked vaults, `startAccessingSecurityScopedResource()` is held
///   for the entire lifetime of the binding (released by `forgetVault`).
///   This is the simplest model that keeps `VaultScanner` and
///   `VaultWriter` ignorant of access ceremony — they just see a working
///   `rootURL`. `NSFileCoordinator` wrapping for iCloud coexistence is
///   listed as partial in phase-b.md §2 and stays deferred.
@MainActor
@Observable
final class VaultAccessService {
    /// The vault Obelisk is currently bound to. `nil` means the chat is
    /// gated by `VaultGateView`.
    private(set) var activeVault: VaultHandle?

    /// User-managed deny list, layered onto `VaultWriter.defaultDenyList`.
    /// Edited from the Vault Settings sheet; persisted in
    /// `UserDefaults`. Folder names match against any path segment
    /// (case-insensitive) — see [VaultWriter](./VaultWriter.swift).
    private(set) var userDenyList: [String]

    private let defaults: UserDefaults

    /// URL we currently hold security-scoped access on. Released on
    /// `forgetVault` / when a new picked vault replaces it.
    private var scopedURL: URL?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.userDenyList = (defaults.array(forKey: Keys.userDenyList) as? [String]) ?? []
        // Run restore as an instance method so we can hold scope state.
        self.activeVault = nil
        restorePersistedBinding()
    }

    // No deinit: `VaultAccessService` lives for the whole app process,
    // so the OS reclaims any held security scope when the process exits.

    // MARK: - User deny list

    /// Replace the user's deny list with `entries`, deduped and trimmed.
    /// Empty strings and the hard-coded defaults (`.obsidian`, `.trash`)
    /// are filtered out — they're enforced unconditionally by the writer.
    func setUserDenyList(_ entries: [String]) {
        let cleaned: [String] = entries
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) }
            .filter { !$0.isEmpty }
            .filter { entry in
                !VaultWriter.defaultDenyList.contains { $0.caseInsensitiveCompare(entry) == .orderedSame }
            }
        // Preserve order while deduping case-insensitively.
        var seen = Set<String>()
        var deduped: [String] = []
        for entry in cleaned {
            let key = entry.lowercased()
            if !seen.contains(key) {
                seen.insert(key)
                deduped.append(entry)
            }
        }
        userDenyList = deduped
        defaults.set(deduped, forKey: Keys.userDenyList)
    }

    // MARK: - Binding

    /// Forget the active vault. Used by the Vault Settings sheet
    /// ("Change vault…") and by `bindSampleVault` / `pickVault` when
    /// re-binding to a different vault.
    func forgetVault() {
        releaseScope()
        activeVault = nil
        defaults.removeObject(forKey: Keys.binding)
        defaults.removeObject(forKey: Keys.bookmark)
    }

    /// Bind the vault at `url` (returned by the document picker). The
    /// URL is security-scoped — we create a bookmark, persist it, and
    /// hold `startAccessingSecurityScopedResource()` for the lifetime
    /// of the binding so callers can treat the URL as plain Foundation.
    func pickVault(url: URL) throws {
        // The picker hands us a URL with a fresh scope already active;
        // we still need our own `start` call so the scope outlives the
        // picker's callback.
        let started = url.startAccessingSecurityScopedResource()
        guard started else {
            throw VaultAccessError.scopeUnavailable
        }

        let bookmark: Data
        do {
            // iOS doesn't support `.withSecurityScope`; the picker URL
            // already carries the scope and the bookmark restores it.
            bookmark = try url.bookmarkData(
                options: [],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
        } catch {
            url.stopAccessingSecurityScopedResource()
            throw VaultAccessError.bookmarkCreationFailed(error.localizedDescription)
        }

        // Release any prior binding before we overwrite the persisted state.
        releaseScope()

        defaults.set(bookmark, forKey: Keys.bookmark)
        defaults.set(Binding.picked.rawValue, forKey: Keys.binding)

        scopedURL = url
        activeVault = VaultHandle(rootURL: url, accessKind: .securityScoped)
    }

    #if DEBUG
    /// DEBUG-only: bind the sample vault rsync'd into the app sandbox by
    /// `make seed-vault`. Returns `false` if no sample vault is present.
    @discardableResult
    func bindSampleVault() -> Bool {
        guard let handle = SampleVaultProvider.detect() else { return false }
        releaseScope()
        activeVault = handle
        defaults.set(Binding.sample.rawValue, forKey: Keys.binding)
        defaults.removeObject(forKey: Keys.bookmark)
        return true
    }
    #endif

    // MARK: - Read access

    /// Run `block` with a URL that points at the active vault's root.
    /// Picked vaults rely on scope held for the binding's lifetime
    /// (started in `pickVault` / `restorePersistedBinding`), so callers
    /// see a working URL with no extra ceremony.
    func withReadAccess<T: Sendable>(
        _ block: @Sendable (_ rootURL: URL) async throws -> T
    ) async throws -> T {
        guard let handle = activeVault else {
            throw VaultAccessError.noActiveVault
        }
        return try await block(handle.rootURL)
    }

    // MARK: - Persistence

    private enum Binding: String {
        case sample
        case picked
    }

    private enum Keys {
        static let binding      = "obelisk.activeVault.binding"
        static let bookmark     = "obelisk.activeVault.bookmark"
        static let userDenyList = "obelisk.vault.userDenyList"
    }

    private func restorePersistedBinding() {
        guard let raw = defaults.string(forKey: Keys.binding),
              let binding = Binding(rawValue: raw)
        else { return }

        switch binding {
        case .sample:
            #if DEBUG
            activeVault = SampleVaultProvider.detect()
            #else
            // The sample binding can't exist in release builds — clear it
            // defensively so a debug-built install promoted to TestFlight
            // doesn't get stuck.
            defaults.removeObject(forKey: Keys.binding)
            #endif

        case .picked:
            guard let data = defaults.data(forKey: Keys.bookmark) else {
                defaults.removeObject(forKey: Keys.binding)
                return
            }
            do {
                var isStale = false
                let url = try URL(
                    resolvingBookmarkData: data,
                    options: [],
                    relativeTo: nil,
                    bookmarkDataIsStale: &isStale
                )
                guard url.startAccessingSecurityScopedResource() else {
                    // Bookmark resolved but the OS denied scope (e.g. the
                    // user revoked Files access). Drop the binding so the
                    // gate re-prompts; nothing crashes.
                    defaults.removeObject(forKey: Keys.binding)
                    defaults.removeObject(forKey: Keys.bookmark)
                    return
                }
                scopedURL = url
                activeVault = VaultHandle(rootURL: url, accessKind: .securityScoped)

                if isStale {
                    // Best-effort refresh; failure isn't fatal — the
                    // current resolution still works for this session.
                    if let refreshed = try? url.bookmarkData(
                        options: [],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    ) {
                        defaults.set(refreshed, forKey: Keys.bookmark)
                    }
                }
            } catch {
                // Bookmark unresolvable (folder deleted, iCloud account
                // signed out, …). Clear the binding so the gate re-prompts.
                defaults.removeObject(forKey: Keys.binding)
                defaults.removeObject(forKey: Keys.bookmark)
            }
        }
    }

    private func releaseScope() {
        if let url = scopedURL {
            url.stopAccessingSecurityScopedResource()
            scopedURL = nil
        }
    }
}

// MARK: - Errors

enum VaultAccessError: Error, LocalizedError {
    case noActiveVault
    case scopeUnavailable
    case bookmarkCreationFailed(String)

    var errorDescription: String? {
        switch self {
        case .noActiveVault:
            return "No vault is connected. Pick a vault to continue."
        case .scopeUnavailable:
            return "Couldn't get access to that folder. Try picking it again."
        case .bookmarkCreationFailed(let detail):
            return "Couldn't remember that folder: \(detail)"
        }
    }
}
