import SwiftUI

/// Minimal Vault Settings sheet (phase-b.md §8 step 9). Surfaces the
/// vault path, current indexing status, a "Re-index now" button, the
/// user-editable write deny list, and a "Change vault…" action.
///
/// Lives behind the top-bar overflow `⋯` for now; the full Settings
/// screen is Phase F.
struct VaultSettingsView: View {
    let env: AppEnvironment
    let onDismiss: () -> Void

    @State private var newDenyEntry: String = ""
    @State private var confirmingChangeVault: Bool = false

    private var access: VaultAccessService { env.vaultAccess }
    private var indexing: VaultIndexingService { env.vaultIndexing }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.obBackground.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        vaultSection
                        indexingSection
                        denyListSection
                    }
                    .padding(.horizontal, ObSpacing.screenH)
                    .padding(.vertical, 20)
                }
            }
            .navigationTitle("Vault")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done", action: onDismiss)
                        .foregroundStyle(Color.obAccent)
                }
            }
            .alert(
                "Disconnect vault?",
                isPresented: $confirmingChangeVault
            ) {
                Button("Cancel", role: .cancel) {}
                Button("Disconnect", role: .destructive) {
                    access.forgetVault()
                    indexing.reset()
                    onDismiss()
                }
            } message: {
                Text("Obelisk will return to the connect-vault screen. Your notes are not deleted.")
            }
        }
    }

    // MARK: - Vault section

    @ViewBuilder
    private var vaultSection: some View {
        sectionHeader("Vault")
        VStack(alignment: .leading, spacing: 6) {
            if let handle = access.activeVault {
                Text(handle.displayName)
                    .font(.obBody.weight(.semibold))
                    .foregroundStyle(Color.obTextPrimary)
                Text(prettyPath(handle.rootURL))
                    .font(.obMeta)
                    .foregroundStyle(Color.obTextTertiary)
                    .textSelection(.enabled)
            } else {
                Text("No vault connected.")
                    .font(.obBody)
                    .foregroundStyle(Color.obTextSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ObSpacing.cardH)
        .background(cardBackground)

        Button(role: .destructive) {
            confirmingChangeVault = true
        } label: {
            Text("Change vault…")
                .font(.obBody.weight(.semibold))
                .foregroundStyle(Color.obStatusRed)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .overlay(
                    RoundedRectangle(cornerRadius: ObRadius.input, style: .continuous)
                        .stroke(Color.obStatusRed.opacity(0.5), lineWidth: ObStroke.hairline)
                )
        }
        .buttonStyle(.plain)
        .disabled(access.activeVault == nil)
        .opacity(access.activeVault == nil ? 0.4 : 1.0)
    }

    // MARK: - Indexing section

    @ViewBuilder
    private var indexingSection: some View {
        sectionHeader("Indexing")
        VStack(alignment: .leading, spacing: 10) {
            indexingStatusRow

            Button(action: triggerReindex) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise")
                    Text("Re-index now")
                        .font(.obBody.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .foregroundStyle(canReindex ? Color.obBackground : Color.obTextTertiary)
                .background(
                    RoundedRectangle(cornerRadius: ObRadius.input, style: .continuous)
                        .fill(canReindex ? Color.obAccent : Color.obSurface)
                )
            }
            .buttonStyle(.plain)
            .disabled(!canReindex)
        }
        .padding(ObSpacing.cardH)
        .background(cardBackground)
    }

    private var canReindex: Bool {
        guard access.activeVault != nil else { return false }
        if case .scanning = indexing.status { return false }
        return true
    }

    @ViewBuilder
    private var indexingStatusRow: some View {
        switch indexing.status {
        case .idle:
            statusLine(color: .obTextTertiary, text: "Idle")
        case .scanning(let processed, let total, let mode):
            VStack(alignment: .leading, spacing: 4) {
                statusLine(color: .obStatusAmber, text: scanningLabel(mode: mode))
                if total > 0 {
                    ProgressView(value: Double(processed), total: Double(total))
                        .tint(Color.obAccent)
                    Text("\(processed) / \(total)")
                        .font(.obMeta)
                        .foregroundStyle(Color.obTextTertiary)
                } else {
                    ProgressView()
                        .tint(Color.obAccent)
                }
            }
        case .ready(let noteCount, let lastScan, let summary):
            VStack(alignment: .leading, spacing: 4) {
                statusLine(color: .obStatusGreen, text: "Ready")
                Text("\(noteCount) notes · last scan \(relativeTime(lastScan))")
                    .font(.obMeta)
                    .foregroundStyle(Color.obTextTertiary)
                Text(summaryDetail(summary))
                    .font(.obMeta)
                    .foregroundStyle(Color.obTextTertiary)
            }
        case .failed(let message):
            VStack(alignment: .leading, spacing: 4) {
                statusLine(color: .obStatusRed, text: "Failed")
                Text(message)
                    .font(.obMeta)
                    .foregroundStyle(Color.obStatusRed)
            }
        }
    }

    // MARK: - Deny list section

    @ViewBuilder
    private var denyListSection: some View {
        sectionHeader("Write Deny List")
        VStack(alignment: .leading, spacing: 12) {
            Text("Obelisk can write anywhere in the vault except these folders. .obsidian and .trash are always protected.")
                .font(.obMeta)
                .foregroundStyle(Color.obTextSecondary)

            // Built-in defaults — read only.
            ForEach(VaultWriter.defaultDenyList, id: \.self) { entry in
                denyRow(name: entry, locked: true, onDelete: nil)
            }

            // User-managed entries.
            ForEach(access.userDenyList, id: \.self) { entry in
                denyRow(name: entry, locked: false) {
                    removeEntry(entry)
                }
            }

            HStack(spacing: 8) {
                TextField(
                    "",
                    text: $newDenyEntry,
                    prompt: Text("e.g. Archive").foregroundStyle(Color.obTextTertiary)
                )
                .font(.obBody)
                .foregroundStyle(Color.obTextPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(.horizontal, ObSpacing.cardH)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: ObRadius.input, style: .continuous)
                        .fill(Color.obSurface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ObRadius.input, style: .continuous)
                        .stroke(Color.obBorder, lineWidth: ObStroke.hairline)
                )

                Button(action: addEntry) {
                    Image(systemName: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(canAddEntry ? Color.obBackground : Color.obTextTertiary)
                        .frame(width: 38, height: 38)
                        .background(
                            Circle().fill(canAddEntry ? Color.obAccent : Color.obSurface)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canAddEntry)
            }
        }
        .padding(ObSpacing.cardH)
        .background(cardBackground)
    }

    private var canAddEntry: Bool {
        !newDenyEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private func denyRow(name: String, locked: Bool, onDelete: (() -> Void)?) -> some View {
        HStack {
            Image(systemName: locked ? "lock.fill" : "folder")
                .foregroundStyle(locked ? Color.obTextTertiary : Color.obTextSecondary)
            Text(name + "/")
                .font(.obBody)
                .foregroundStyle(Color.obTextPrimary)
            Spacer()
            if let onDelete {
                Button(action: onDelete) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundStyle(Color.obStatusRed)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Actions

    private func triggerReindex() {
        guard let handle = access.activeVault else { return }
        indexing.reindex(handle: handle)
    }

    private func addEntry() {
        let trimmed = newDenyEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let next = access.userDenyList + [trimmed]
        access.setUserDenyList(next)
        newDenyEntry = ""
    }

    private func removeEntry(_ entry: String) {
        let next = access.userDenyList.filter { $0 != entry }
        access.setUserDenyList(next)
    }

    // MARK: - Helpers

    @ViewBuilder
    private func sectionHeader(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.obSection)
            .foregroundStyle(Color.obTextSecondary)
    }

    @ViewBuilder
    private func statusLine(color: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text)
                .font(.obBody.weight(.semibold))
                .foregroundStyle(Color.obTextPrimary)
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: ObRadius.card, style: .continuous)
            .fill(Color.obSurface)
            .overlay(
                RoundedRectangle(cornerRadius: ObRadius.card, style: .continuous)
                    .stroke(Color.obBorder, lineWidth: ObStroke.hairline)
            )
    }

    private func prettyPath(_ url: URL) -> String {
        // The sample vault sits under the app sandbox — show a friendly
        // tail rather than the full container UUID path.
        let path = url.path(percentEncoded: false)
        if let range = path.range(of: "/Documents/") {
            return "…" + path[range.lowerBound...]
        }
        return path
    }

    private func scanningLabel(mode: VaultScanner.Mode) -> String {
        switch mode {
        case .full:        return "Scanning (full)"
        case .incremental: return "Scanning"
        }
    }

    private func summaryDetail(_ s: VaultScanner.Summary) -> String {
        "parsed=\(s.parsed), skipped=\(s.skipped), deleted=\(s.deleted) · \(String(format: "%.2fs", s.durationSeconds))"
    }

    private func relativeTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
