import SwiftUI

struct ContentView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 16) {
                Text("Obelisk")
                    .font(.system(size: 44, weight: .semibold, design: .default))
                    .foregroundStyle(.white)

                Text("A local AI companion for Obsidian")
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }
}

#Preview {
    ContentView()
}
