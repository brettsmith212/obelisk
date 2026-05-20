import SwiftUI

@main
struct ObeliskApp: App {
    @State private var env = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            ChatView(env: env)
                .preferredColorScheme(.dark)
        }
    }
}
