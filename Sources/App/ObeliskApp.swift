import SwiftUI

@main
struct ObeliskApp: App {
    @State private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootView(env: env)
                .preferredColorScheme(.dark)
        }
    }
}

/// Top-level gate: shows `VaultGateView` until a vault is bound, then
/// hands off to `ChatView`. Kept tiny on purpose so the gate logic is
/// readable at a glance — no business logic, no state of its own.
private struct RootView: View {
    let env: AppEnvironment

    var body: some View {
        Group {
            if let vault = env.vaultAccess.activeVault {
                ChatView(env: env)
                    .task(id: vault) {
                        // Kick off an incremental scan whenever a vault
                        // becomes (or remains) active. The service
                        // coalesces back-to-back calls.
                        env.vaultIndexing.ensureIndexed(handle: vault)
                    }
            } else {
                VaultGateView(vaultAccess: env.vaultAccess)
            }
        }
    }
}
