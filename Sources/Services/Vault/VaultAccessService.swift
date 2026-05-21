import Foundation
import Observation

/// The single mediator between the rest of the vault layer (scanner,
/// parsers, tools) and the underlying file system. Owns the *active*
/// `VaultHandle` and is the only place that knows about security-scoped
/// bookmarks, `NSFileCoordinator`, or the difference between sample-vault
/// and picked-vault flows.
///
/// Phase B scope for this file:
/// - Active vault binding + persistence across launches.
/// - `withReadAccess` for the sample-vault (`appSandbox`) case.
/// - Document picker / security-scoped bookmark / file coordinator support
///   is reserved for the next sub-step (real vault picker) and currently
///   throws `notImplemented` for `securityScoped` handles.
@MainActor
@Observable
final class VaultAccessService {
    /// The vault Obelisk is currently bound to. `nil` means the chat is
    /// gated by `VaultGateView`.
    private(set) var activeVault: VaultHandle?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.activeVault = Self.restorePersistedBinding(defaults: defaults)
    }

    // MARK: - Binding

    /// Forget the active vault. Used by the Vault settings sheet
    /// ("Change vault…") and by `bindSampleVault` when re-binding.
    func forgetVault() {
        activeVault = nil
        defaults.removeObject(forKey: Keys.binding)
        defaults.removeObject(forKey: Keys.bookmark)
    }

    #if DEBUG
    /// DEBUG-only: bind the sample vault rsync'd into the app sandbox by
    /// `make seed-vault`. Returns `false` if no sample vault is present.
    @discardableResult
    func bindSampleVault() -> Bool {
        guard let handle = SampleVaultProvider.detect() else { return false }
        activeVault = handle
        defaults.set(Binding.sample.rawValue, forKey: Keys.binding)
        defaults.removeObject(forKey: Keys.bookmark)
        return true
    }
    #endif

    // MARK: - Read access

    /// Run `block` with a URL that points at the active vault's root.
    /// Each invocation handles whatever access ceremony the underlying
    /// `accessKind` requires; callers never wrap with `NSFileCoordinator`
    /// or `startAccessingSecurityScopedResource` themselves.
    func withReadAccess<T: Sendable>(
        _ block: @Sendable (_ rootURL: URL) async throws -> T
    ) async throws -> T {
        guard let handle = activeVault else {
            throw VaultAccessError.noActiveVault
        }
        switch handle.accessKind {
        case .appSandbox:
            // Sample vault: no scope, no coordinator. The folder lives in
            // our own Documents container.
            return try await block(handle.rootURL)
        case .securityScoped:
            // Real picker flow lands in the next sub-step.
            throw VaultAccessError.notImplemented(
                "Security-scoped vault access not yet wired (Phase B Step 3 follow-up)."
            )
        }
    }

    // MARK: - Persistence

    private enum Binding: String {
        case sample
        case picked
    }

    private enum Keys {
        static let binding  = "obelisk.activeVault.binding"
        static let bookmark = "obelisk.activeVault.bookmark"
    }

    private static func restorePersistedBinding(defaults: UserDefaults) -> VaultHandle? {
        guard let raw = defaults.string(forKey: Keys.binding),
              let binding = Binding(rawValue: raw)
        else { return nil }

        switch binding {
        case .sample:
            #if DEBUG
            return SampleVaultProvider.detect()
            #else
            // The sample binding can't exist in release builds — clear it
            // defensively so a debug-built install promoted to TestFlight
            // doesn't get stuck.
            defaults.removeObject(forKey: Keys.binding)
            return nil
            #endif
        case .picked:
            // Reserved for the document picker flow. Bookmark resolution
            // lands with the picker; until then, treat as no binding.
            return nil
        }
    }
}

// MARK: - Errors

enum VaultAccessError: Error, LocalizedError {
    case noActiveVault
    case notImplemented(String)

    var errorDescription: String? {
        switch self {
        case .noActiveVault:
            return "No vault is connected. Pick a vault to continue."
        case .notImplemented(let detail):
            return detail
        }
    }
}
