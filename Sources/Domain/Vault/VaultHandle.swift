import Foundation

/// Opaque value type identifying the active vault. Wraps a directory URL
/// plus the access strategy needed to read from it.
///
/// Why a wrapper instead of a bare URL: real vaults picked via the document
/// picker require `startAccessingSecurityScopedResource` brackets and
/// `NSFileCoordinator` wrapping. The sample-vault flow (and any future
/// app-sandbox storage) does not. `VaultAccessService.withReadAccess` is
/// the single mediator that knows which kind of access this handle needs;
/// callers never branch on the access strategy themselves.
struct VaultHandle: Equatable, Sendable {
    /// The vault's root directory. Always absolute.
    let rootURL: URL

    /// How callers obtain read access for this vault.
    ///
    /// - `appSandbox`: the URL points into the app's own Documents/Library
    ///   container. No security scope, no file coordination needed.
    /// - `securityScoped`: the URL came from the document picker. Each
    ///   read/write must be wrapped in `start/stopAccessingSecurityScopedResource`
    ///   plus `NSFileCoordinator`.
    let accessKind: AccessKind

    /// Human-readable vault name (the directory's last path component).
    /// Used in Settings, the status pill, and the Obsidian deep link.
    var displayName: String { rootURL.lastPathComponent }

    enum AccessKind: Equatable, Sendable {
        case appSandbox
        case securityScoped
    }
}
