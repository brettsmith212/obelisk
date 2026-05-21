import SwiftUI

/// Pre-chat onboarding gate (ui-spec.md §3.5 step 2, narrowed for Phase B).
/// Shown whenever `VaultAccessService.activeVault == nil` — until a vault
/// is bound, the chat shell is hidden and the model can't be invoked
/// (vault tools have nothing to query).
///
/// In release builds, the only path forward is the document picker. In
/// `#if DEBUG`, an additional "Use sample vault" button lets us bind
/// `Documents/SampleVault/` directly without the picker — see
/// `make seed-vault` and `SampleVaultProvider`.
struct VaultGateView: View {
    let vaultAccess: VaultAccessService

    @State private var pickerErrorMessage: String?

    var body: some View {
        ZStack {
            Color.obBackground.ignoresSafeArea()

            VStack(spacing: 28) {
                Spacer()

                VStack(spacing: 12) {
                    Text("Obelisk")
                        .font(.obWordmark)
                        .foregroundStyle(Color.obTextPrimary)
                    Text("Connect your Obsidian vault to get started.")
                        .font(.obBody)
                        .foregroundStyle(Color.obTextSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }

                VStack(spacing: 12) {
                    PrimaryButton(
                        title: "Choose vault folder…",
                        systemImage: "folder.badge.plus",
                        isPrimary: true,
                        action: openPicker
                    )
                    .disabled(true) // wired in the next sub-step
                    .opacity(0.5)

                    #if DEBUG
                    sampleVaultButton
                    #endif

                    if let message = pickerErrorMessage {
                        Text(message)
                            .font(.obMeta)
                            .foregroundStyle(Color.obStatusAmber)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                }

                VStack(spacing: 6) {
                    Text("Everything stays on this iPhone.")
                        .font(.obMeta)
                        .foregroundStyle(Color.obTextTertiary)
                    Text("Your notes never leave the device.")
                        .font(.obMeta)
                        .foregroundStyle(Color.obTextTertiary)
                }
                .padding(.top, 12)

                Spacer()
            }
            .padding(.horizontal, ObSpacing.screenH)
        }
    }

    // MARK: - Real picker (placeholder)

    private func openPicker() {
        // Lands in the next Phase B sub-step (UIDocumentPickerViewController
        // + security-scoped bookmark persistence + iCloud placeholder check).
        pickerErrorMessage = "Vault picker not wired yet — use the sample vault button below."
    }

    // MARK: - Sample vault (DEBUG)

    #if DEBUG
    @ViewBuilder
    private var sampleVaultButton: some View {
        if let summary = SampleVaultProvider.summary() {
            VStack(spacing: 8) {
                PrimaryButton(
                    title: "Use sample vault",
                    systemImage: "ladybug.fill",
                    isPrimary: false,
                    action: bindSample
                )
                Text(
                    "Detected \(summary.markdownCount) markdown notes" +
                    (summary.hasObsidianConfig ? " · .obsidian/ present" : "")
                )
                .font(.obMeta)
                .foregroundStyle(Color.obTextTertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
            }
        } else {
            VStack(spacing: 4) {
                Text("No sample vault detected.")
                    .font(.obMeta)
                    .foregroundStyle(Color.obTextTertiary)
                Text("Run: make seed-vault VAULT=/path/to/vault")
                    .font(.obCode)
                    .foregroundStyle(Color.obTextTertiary)
            }
            .padding(.top, 8)
        }
    }

    private func bindSample() {
        if !vaultAccess.bindSampleVault() {
            pickerErrorMessage = "Sample vault folder is empty or missing."
        }
    }
    #endif
}

// MARK: - Button

private struct PrimaryButton: View {
    let title: String
    let systemImage: String
    let isPrimary: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                Text(title)
                    .font(.obBody.weight(.semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .padding(.horizontal, ObSpacing.cardH)
            .foregroundStyle(isPrimary ? Color.obBackground : Color.obTextPrimary)
            .background(
                RoundedRectangle(cornerRadius: ObRadius.input, style: .continuous)
                    .fill(isPrimary ? Color.obAccent : Color.obSurface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: ObRadius.input, style: .continuous)
                    .stroke(Color.obBorder, lineWidth: isPrimary ? 0 : ObStroke.hairline)
            )
        }
        .buttonStyle(.plain)
    }
}
