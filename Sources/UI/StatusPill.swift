import SwiftUI

/// Full-width status pill per [ui-spec.md §5](../../ui-spec.md). Only one
/// is visible at a time and lives right under the top bar.
///
/// Today this drives a single piece of UI: a red "Vault not fully
/// downloaded from iCloud" banner when the scanner refuses to index
/// (phase-b.md §8 step 15). Future Phase B/C/F work plugs in more
/// statuses (Apple Intelligence unavailable, vault disconnected,
/// "Indexed N new notes" green transient) without changing the call
/// site in `ChatView`.
struct StatusPill: View {
    let kind: Kind
    let message: String
    let onTap: (() -> Void)?

    enum Kind {
        case green
        case amber
        case red
    }

    var body: some View {
        Button {
            onTap?()
        } label: {
            HStack(spacing: 8) {
                Text(message)
                    .font(.obMeta.weight(.semibold))
                    .foregroundStyle(foreground)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 8)
                if onTap != nil {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(foreground)
                }
            }
            .padding(.horizontal, ObSpacing.cardH)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
        }
        .buttonStyle(.plain)
        .disabled(onTap == nil)
    }

    private var foreground: Color {
        switch kind {
        case .green: Color.obStatusGreen
        case .amber: Color.obStatusAmber
        case .red:   Color.obStatusRed
        }
    }

    private var background: Color {
        switch kind {
        case .green: Color.obStatusGreen.opacity(0.12)
        case .amber: Color.obStatusAmber.opacity(0.12)
        case .red:   Color.obStatusRed.opacity(0.12)
        }
    }
}
