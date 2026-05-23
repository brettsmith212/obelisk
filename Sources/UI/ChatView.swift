import SwiftUI

/// The Phase A chat shell. Implements (per phase-a.md §4):
///   - top bar with hamburger → drawer (ui-spec §3.2)
///   - empty state (ui-spec §3.3, simplified — no vault stats)
///   - message list with inline tool-call rows (§4.5)
///   - user-message edit (§4.1) and last-assistant regenerate (§4.2)
///   - stop while streaming (§4.3)
///   - inline error tiers (§4.8): amber on failed tool-call rows,
///     red replacing the assistant turn with a "Try again" button.
struct ChatView: View {
    let env: AppEnvironment

    // Local UI state — not persisted.
    @State private var inputText: String = ""
    @State private var streamingTask: Task<Void, Never>?
    @State private var drawerOpen: Bool = false
    @State private var editingMessageID: UUID? = nil
    @State private var editingText: String = ""
    @State private var settingsOpen: Bool = false

    private var manager: ConversationManager { env.manager }
    private var agent: AgentService { env.agent }
    private var isStreaming: Bool { streamingTask != nil }

    var body: some View {
        ZStack(alignment: .leading) {
            mainContent

            // Drawer scrim + panel slide-over (ui-spec §3.2).
            if drawerOpen {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { closeDrawer() }
            }

            DrawerView(
                summaries: manager.summaries,
                activeID: manager.activeConversation?.id,
                onNew: { newConversation() },
                onSelect: { id in selectConversation(id: id) }
            )
            .frame(width: 280)
            .offset(x: drawerOpen ? 0 : -320)
            .animation(.easeInOut(duration: 0.22), value: drawerOpen)
        }
        .sheet(isPresented: $settingsOpen) {
            VaultSettingsView(env: env, onDismiss: { settingsOpen = false })
        }
    }

    // MARK: - Main column

    private var mainContent: some View {
        ZStack {
            Color.obBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Divider().background(Color.obBorder)

                activeStatusPill()

                if let conversation = manager.activeConversation, !conversation.messages.isEmpty {
                    MessageListView(
                        conversation: conversation,
                        isStreaming: isStreaming,
                        editingMessageID: editingMessageID,
                        editingText: $editingText,
                        vaultName: env.vaultAccess.activeVault?.displayName,
                        onBeginEdit: beginEdit,
                        onConfirmEdit: confirmEdit,
                        onCancelEdit: cancelEdit,
                        onRegenerate: regenerate,
                        onRetry: regenerate
                    )
                } else {
                    EmptyStateView(onPickSuggestion: { inputText = $0 })
                }

                Divider().background(Color.obBorder)
                InputRowView(
                    text: $inputText,
                    isStreaming: isStreaming,
                    onSend: send,
                    onStop: stop
                )
            }
        }
        // Phase C: every `obsidian://open?…&file=…` URL the user taps
        // — from the Sources card or from a wikilink in assistant
        // prose — flows through SwiftUI's openURL environment. We
        // intercept once here to record a frecency event before
        // letting the system open Obsidian. Source defaults to
        // `.sourcesTap` (we can't distinguish from this layer, and
        // the source field is diagnostic-only today).
        .environment(\.openURL, OpenURLAction { url in
            if let path = Self.notePath(from: url) {
                let frecency = env.frecency
                Task.detached(priority: .utility) {
                    frecency.recordOpen(path: path, source: .sourcesTap)
                }
            }
            return .systemAction(url)
        })
    }

    /// Vault-relative path encoded in an `obsidian://open?vault=…&file=…`
    /// URL, with `.md` re-appended (`SourcesCard.deepLink` strips it
    /// when building the link). Returns nil for any other scheme.
    private static func notePath(from url: URL) -> String? {
        guard url.scheme == "obsidian",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.host == "open"
        else { return nil }
        guard var file = components.queryItems?
            .first(where: { $0.name == "file" })?.value,
              !file.isEmpty
        else { return nil }
        // Strip wikilink heading/block fragments so the frecency event
        // keys on the note, not its anchor.
        if let hashRange = file.range(of: "#") {
            file = String(file[..<hashRange.lowerBound])
        }
        return file.lowercased().hasSuffix(".md") ? file : file + ".md"
    }

    // MARK: - Status pill

    /// Maps the indexing service's status onto a `StatusPill`. Only the
    /// `.failed` case surfaces UI today (phase-b.md §8 step 15 — iCloud
    /// not fully downloaded). `.scanning` / `.ready` stay silent in the
    /// chat shell; the Settings sheet (step 9) renders them once it
    /// exists.
    @ViewBuilder
    private func activeStatusPill() -> some View {
        switch env.vaultIndexing.status {
        case .failed(let message):
            StatusPill(
                kind: .red,
                message: message,
                onTap: env.vaultAccess.activeVault.map { handle in
                    { env.vaultIndexing.reindex(handle: handle) }
                }
            )
        default:
            EmptyView()
        }
    }

    private var topBar: some View {
        HStack {
            Button(action: { drawerOpen.toggle() }) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(Color.obTextPrimary)
            }
            Spacer()
            Text("Obelisk")
                .font(.obTitle)
                .foregroundStyle(Color.obTextPrimary)
            Spacer()
            // Overflow menu — Vault Settings lives here in Phase B
            // (phase-b.md §8 step 9); rename/delete/export land in Phase F.
            Button(action: { settingsOpen = true }) {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Color.obTextPrimary)
            }
            .accessibilityLabel("Vault settings")
        }
        .padding(.horizontal, ObSpacing.screenH)
        .padding(.vertical, 12)
    }

    // MARK: - Send / stop

    private func send() {
        let prompt = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isStreaming else { return }
        inputText = ""

        if manager.activeConversation == nil {
            manager.newConversation()
        }

        manager.updateActive { conversation in
            conversation.messages.append(Message(role: .user, content: prompt))
            if conversation.messages.filter({ $0.role == .user }).count == 1 {
                conversation.title = String(prompt.prefix(60))
            }
            conversation.messages.append(Message(role: .assistant, content: "", status: .streaming))
        }
        runAgent()
    }

    private func stop() {
        streamingTask?.cancel()
        agent.cancel()
    }

    // MARK: - Drawer actions

    private func newConversation() {
        if isStreaming { stop() }
        editingMessageID = nil
        manager.newConversation()
        closeDrawer()
    }

    private func selectConversation(id: UUID) {
        if isStreaming { stop() }
        editingMessageID = nil
        manager.selectConversation(id: id)
        closeDrawer()
    }

    private func closeDrawer() {
        withAnimation(.easeInOut(duration: 0.22)) { drawerOpen = false }
    }

    // MARK: - Edit / regenerate / retry

    private func beginEdit(message: Message) {
        guard !isStreaming, message.role == .user else { return }
        editingMessageID = message.id
        editingText = message.content
    }

    private func cancelEdit() {
        editingMessageID = nil
        editingText = ""
    }

    /// Per ui-spec §4.1 — replace the user message, drop every subsequent
    /// turn, then re-run from that point.
    private func confirmEdit() {
        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = editingMessageID, !trimmed.isEmpty, !isStreaming else { return }

        manager.updateActive { conversation in
            guard let idx = conversation.messages.firstIndex(where: { $0.id == id }),
                  conversation.messages[idx].role == .user
            else { return }
            conversation.messages[idx].content = trimmed
            conversation.messages.removeSubrange((idx + 1)..<conversation.messages.count)
            conversation.messages.append(Message(role: .assistant, content: "", status: .streaming))
        }
        editingMessageID = nil
        editingText = ""
        runAgent()
    }

    /// Per ui-spec §4.2 — replace the most recent assistant turn in place.
    /// Doubles as the "Try again" handler from §4.8 tier 2.
    private func regenerate() {
        guard !isStreaming else { return }
        manager.updateActive { conversation in
            guard let lastIdx = conversation.messages.lastIndex(where: { $0.role == .assistant })
            else { return }
            // If the previous run errored before any tokens, just reset.
            conversation.messages[lastIdx] = Message(
                id: conversation.messages[lastIdx].id,
                role: .assistant,
                content: "",
                toolCalls: [],
                status: .streaming
            )
        }
        runAgent()
    }

    // MARK: - Streaming wiring

    private func runAgent() {
        guard let snapshot = manager.activeConversation else { return }

        streamingTask = Task { @MainActor in
            let stream = agent.run(conversation: snapshot)
            for await event in stream {
                handle(event)
            }
            if Task.isCancelled {
                manager.updateActive { conversation in
                    guard var last = conversation.messages.last, last.role == .assistant else { return }
                    if last.status == .streaming {
                        last.status = .stopped
                        conversation.messages[conversation.messages.count - 1] = last
                    }
                }
            }
            streamingTask = nil
        }
    }

    private func handle(_ event: AgentEvent) {
        switch event {
        case .token(let text):
            mutateLastAssistant { $0.content += text }

        case .toolCallStart(let call):
            mutateLastAssistant { $0.toolCalls.append(call) }

        case .toolCallResult(let id, let result):
            mutateLastAssistant { msg in
                if let idx = msg.toolCalls.firstIndex(where: { $0.id == id }) {
                    msg.toolCalls[idx].result = result
                }
            }

        case .finalDone:
            mutateLastAssistant { $0.status = .complete }

        case .error(let error):
            mutateLastAssistant { msg in
                msg.status = .errored
                if msg.content.isEmpty {
                    msg.content = error.message
                } else {
                    msg.content += "\n\n" + error.message
                }
            }
        }
    }

    private func mutateLastAssistant(_ mutation: (inout Message) -> Void) {
        manager.updateActive { conversation in
            guard var last = conversation.messages.last, last.role == .assistant else { return }
            mutation(&last)
            conversation.messages[conversation.messages.count - 1] = last
        }
    }
}

// MARK: - Drawer (ui-spec §3.2)

private struct DrawerView: View {
    let summaries: [ConversationSummary]
    let activeID: UUID?
    let onNew: () -> Void
    let onSelect: (UUID) -> Void

    var body: some View {
        VStack(spacing: 0) {
            Button(action: onNew) {
                HStack(spacing: 10) {
                    Image(systemName: "plus")
                    Text("New conversation")
                    Spacer()
                }
                .font(.obBody)
                .foregroundStyle(Color.obTextPrimary)
                .padding(.horizontal, ObSpacing.cardH)
                .padding(.vertical, 12)
            }
            .buttonStyle(.plain)
            Divider().background(Color.obBorder)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Self.group(summaries), id: \.0) { (heading, rows) in
                        Text(heading)
                            .font(.obSection)
                            .foregroundStyle(Color.obTextSecondary)
                            .padding(.horizontal, ObSpacing.cardH)
                            .padding(.top, 16)
                            .padding(.bottom, 4)
                        ForEach(rows) { summary in
                            Button(action: { onSelect(summary.id) }) {
                                HStack(spacing: 8) {
                                    Text(summary.title.isEmpty ? "New conversation" : summary.title)
                                        .font(.obBody)
                                        .foregroundStyle(Color.obTextPrimary)
                                        .lineLimit(1)
                                    Spacer()
                                }
                                .padding(.horizontal, ObSpacing.cardH)
                                .padding(.vertical, 10)
                                .background(
                                    activeID == summary.id
                                        ? Color.obAccent.opacity(0.15)
                                        : Color.clear
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if summaries.isEmpty {
                        Text("No conversations yet.")
                            .font(.obMeta)
                            .foregroundStyle(Color.obTextTertiary)
                            .padding(.horizontal, ObSpacing.cardH)
                            .padding(.vertical, 16)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .background(Color.obSurfaceElevated)
        .overlay(
            Rectangle()
                .fill(Color.obBorder)
                .frame(width: ObStroke.hairline),
            alignment: .trailing
        )
    }

    /// Today / Yesterday / Previous 7 days / Previous 30 days / Older.
    private static func group(_ summaries: [ConversationSummary])
        -> [(String, [ConversationSummary])] {
        let cal = Calendar.current
        let now = Date.now
        var today: [ConversationSummary] = []
        var yesterday: [ConversationSummary] = []
        var prev7: [ConversationSummary] = []
        var prev30: [ConversationSummary] = []
        var older: [ConversationSummary] = []

        for s in summaries {
            if cal.isDateInToday(s.updatedAt) {
                today.append(s)
            } else if cal.isDateInYesterday(s.updatedAt) {
                yesterday.append(s)
            } else if let diff = cal.dateComponents([.day], from: s.updatedAt, to: now).day {
                if diff <= 7 { prev7.append(s) }
                else if diff <= 30 { prev30.append(s) }
                else { older.append(s) }
            } else {
                older.append(s)
            }
        }

        var groups: [(String, [ConversationSummary])] = []
        if !today.isEmpty     { groups.append(("Today", today)) }
        if !yesterday.isEmpty { groups.append(("Yesterday", yesterday)) }
        if !prev7.isEmpty     { groups.append(("Previous 7 days", prev7)) }
        if !prev30.isEmpty    { groups.append(("Previous 30 days", prev30)) }
        if !older.isEmpty     { groups.append(("Older", older)) }
        return groups
    }
}

// MARK: - Message list

private struct MessageListView: View {
    let conversation: Conversation
    let isStreaming: Bool
    let editingMessageID: UUID?
    @Binding var editingText: String
    let vaultName: String?
    let onBeginEdit: (Message) -> Void
    let onConfirmEdit: () -> Void
    let onCancelEdit: () -> Void
    let onRegenerate: () -> Void
    let onRetry: () -> Void

    private var lastAssistantID: UUID? {
        conversation.messages.last(where: { $0.role == .assistant })?.id
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: ObSpacing.messageGap) {
                    ForEach(conversation.messages) { message in
                        MessageRow(
                            message: message,
                            isLastAssistant: message.id == lastAssistantID,
                            isStreaming: isStreaming,
                            isEditing: message.id == editingMessageID,
                            editingText: $editingText,
                            vaultName: vaultName,
                            onBeginEdit: { onBeginEdit(message) },
                            onConfirmEdit: onConfirmEdit,
                            onCancelEdit: onCancelEdit,
                            onRegenerate: onRegenerate,
                            onRetry: onRetry
                        )
                        .id(message.id)
                    }
                }
                .padding(.horizontal, ObSpacing.screenH)
                .padding(.vertical, ObSpacing.messageGap)
            }
            .onChange(of: conversation.messages.last?.id) { _, newID in
                if let newID { withAnimation { proxy.scrollTo(newID, anchor: .bottom) } }
            }
            .onChange(of: conversation.messages.last?.content) { _, _ in
                // No animation, no withAnimation: during streaming this
                // fires once per token. Wrapping each call in an
                // animation forces SwiftUI to interpolate every layout
                // pass against the in-flight animation; with long
                // assistant messages the layout engine can fail to
                // converge between updates and the main thread spins
                // inside `ViewLayoutEngine.sizeThatFits` (UI freeze).
                // A bare `scrollTo` is plenty for tail-following.
                if let id = conversation.messages.last?.id {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
            // The Sources card appears only after a turn settles to
            // `.complete` (see `AssistantTurn.showSourcesCard`). Since
            // neither id nor content changes at that moment, scroll on
            // status transitions so the card doesn't render below the
            // input row's fold.
            .onChange(of: conversation.messages.last?.status) { _, _ in
                if let id = conversation.messages.last?.id {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
            // Same idea for the streamed tool-call rows: a late-arriving
            // tool result can grow the assistant turn after the last
            // content delta. Re-anchor whenever the toolCalls array on
            // the trailing message changes shape — but again without an
            // animation wrapper, for the same convergence reason.
            .onChange(of: conversation.messages.last?.toolCalls.count) { _, _ in
                if let id = conversation.messages.last?.id {
                    proxy.scrollTo(id, anchor: .bottom)
                }
            }
        }
    }
}

private struct MessageRow: View {
    let message: Message
    let isLastAssistant: Bool
    let isStreaming: Bool
    let isEditing: Bool
    @Binding var editingText: String
    let vaultName: String?
    let onBeginEdit: () -> Void
    let onConfirmEdit: () -> Void
    let onCancelEdit: () -> Void
    let onRegenerate: () -> Void
    let onRetry: () -> Void

    var body: some View {
        switch message.role {
        case .user:
            UserBubble(
                message: message,
                isStreaming: isStreaming,
                isEditing: isEditing,
                editingText: $editingText,
                onBeginEdit: onBeginEdit,
                onConfirmEdit: onConfirmEdit,
                onCancelEdit: onCancelEdit
            )
        case .assistant:
            AssistantTurn(
                message: message,
                isLastAssistant: isLastAssistant,
                isStreaming: isStreaming,
                vaultName: vaultName,
                onRegenerate: onRegenerate,
                onRetry: onRetry
            )
        case .tool, .system:
            EmptyView()
        }
    }
}

private struct UserBubble: View {
    let message: Message
    let isStreaming: Bool
    let isEditing: Bool
    @Binding var editingText: String
    let onBeginEdit: () -> Void
    let onConfirmEdit: () -> Void
    let onCancelEdit: () -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack {
                Spacer(minLength: 40)
                if isEditing {
                    editor
                } else {
                    Text(message.content)
                        .font(.obBody)
                        .foregroundStyle(Color.obTextPrimary)
                        .padding(.horizontal, ObSpacing.cardH)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: ObRadius.card, style: .continuous)
                                .fill(Color.obAccent.opacity(0.15))
                        )
                        .textSelection(.enabled)
                }
            }

            if !isEditing && !isStreaming {
                Button(action: onBeginEdit) {
                    HStack(spacing: 4) {
                        Image(systemName: "pencil")
                        Text("edit")
                    }
                    .font(.obMeta)
                    .foregroundStyle(Color.obTextTertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .trailing, spacing: 8) {
            TextField("", text: $editingText, axis: .vertical)
                .font(.obBody)
                .foregroundStyle(Color.obTextPrimary)
                .lineLimit(1...10)
                .padding(.horizontal, ObSpacing.cardH)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: ObRadius.card, style: .continuous)
                        .fill(Color.obAccent.opacity(0.15))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: ObRadius.card, style: .continuous)
                        .stroke(Color.obAccent.opacity(0.4), lineWidth: ObStroke.hairline)
                )

            HStack(spacing: 12) {
                Button("Cancel", action: onCancelEdit)
                    .font(.obMeta)
                    .foregroundStyle(Color.obTextSecondary)
                Button(action: onConfirmEdit) {
                    Text("Save & send")
                        .font(.obMeta.weight(.semibold))
                        .foregroundStyle(Color.obAccent)
                }
                .disabled(editingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
}

private struct AssistantTurn: View {
    let message: Message
    let isLastAssistant: Bool
    let isStreaming: Bool
    let vaultName: String?
    let onRegenerate: () -> Void
    let onRetry: () -> Void

    /// Citations harvested from this turn's tool calls. Computed once
    /// per body render; cheap because tool-call counts are tiny.
    private var citations: [Citation] { SourcesCard.citations(in: message) }

    /// Render the Sources card only after the turn settles. Streaming
    /// the card in mid-flight makes it flicker as new tool calls land
    /// and the model continues typing; we also don't want a Sources
    /// card under a red `.errored` turn (the user's eye should go to
    /// "Try again," not to mid-flight tool output).
    private var showSourcesCard: Bool {
        guard !citations.isEmpty,
              let vaultName, !vaultName.isEmpty
        else { return false }
        switch message.status {
        case .complete, .stopped: return true
        case .streaming, .errored: return false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(message.toolCalls) { call in
                ToolCallRow(call: call)
            }

            if message.content.isEmpty && message.status == .streaming {
                TypingIndicator()
            } else if !message.content.isEmpty {
                // While streaming OR after a clean settle: render
                // wikilinks per ui-spec §4.7. The errored case stays as
                // plain red text so the failure message reads as a
                // single semantic unit rather than mixed-color tokens.
                if message.status == .errored {
                    Text(message.content)
                        .font(.obBody)
                        .foregroundStyle(Color.obStatusRed)
                        .obBodyLineSpacing()
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } else {
                    WikilinkText(content: message.content, vaultName: vaultName)
                        .font(.obBody)
                        .foregroundStyle(Color.obTextPrimary)
                        .obBodyLineSpacing()
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if showSourcesCard, let vaultName {
                SourcesCard(citations: citations, vaultName: vaultName)
                    .padding(.top, 4)
            }

            if message.status == .stopped {
                Text("… stopped")
                    .font(.obMeta)
                    .foregroundStyle(Color.obTextTertiary)
            }

            // Affordances under the last assistant turn (ui-spec §4.2, §4.8).
            if isLastAssistant && !isStreaming {
                if message.status == .errored {
                    Button(action: onRetry) {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.clockwise")
                            Text("Try again")
                        }
                        .font(.obMeta.weight(.semibold))
                        .foregroundStyle(Color.obStatusRed)
                        .padding(.horizontal, ObSpacing.cardH)
                        .padding(.vertical, 6)
                        .overlay(
                            RoundedRectangle(cornerRadius: ObRadius.card, style: .continuous)
                                .stroke(Color.obStatusRed.opacity(0.6), lineWidth: ObStroke.hairline)
                        )
                    }
                    .buttonStyle(.plain)
                } else if message.status == .complete || message.status == .stopped {
                    Button(action: onRegenerate) {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("regenerate")
                        }
                        .font(.obMeta)
                        .foregroundStyle(Color.obTextTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

private struct ToolCallRow: View {
    let call: ToolCall

    /// Inline glyph for the tool family per ui-spec §4.5.
    private var glyph: String {
        switch call.name {
        case "find": "🔎"
        case "read": "📄"
        default:     "🔧"
        }
    }

    private var trailing: String {
        if let result = call.result {
            return result.error == nil ? "✓" : "✗"
        } else {
            return "…"
        }
    }

    private var headerColor: Color {
        if let result = call.result, result.error != nil {
            return Color.obStatusAmber
        }
        return Color.obTextTertiary
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text("\(glyph)  \(call.name)  \(trailing)")
                    .font(.obMeta)
                    .foregroundStyle(headerColor)
                Spacer()
            }
            // Amber inline error message (ui-spec §4.8 tier 1).
            if let result = call.result, let err = result.error {
                Text(err)
                    .font(.obMeta)
                    .foregroundStyle(Color.obStatusAmber)
                    .padding(.leading, 22)
            }
        }
    }
}

private struct TypingIndicator: View {
    @State private var phase: Int = 0

    var body: some View {
        Text(String(repeating: "•", count: phase + 1).padding(toLength: 3, withPad: " ", startingAt: 0))
            .font(.obBody)
            .foregroundStyle(Color.obTextTertiary)
            .onAppear {
                Task { @MainActor in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(350))
                        phase = (phase + 1) % 3
                    }
                }
            }
    }
}

// MARK: - Empty state

private struct EmptyStateView: View {
    let onPickSuggestion: (String) -> Void

    // Suggestions exercise the 2-tool AFM-realistic surface:
    // `find` (recency / keyword / backlinks) and `read` (daily).
    // Tappable to populate the input, not auto-sent.
    private let suggestions = [
        "What notes do I have?",
        "Search my vault for productivity.",
        "Open today's daily note.",
        "What links to [[Master Branch]]?"
    ]

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 10) {
                Text("Obelisk")
                    .font(.obWordmark)
                    .foregroundStyle(Color.obTextPrimary)
                Text("Start a conversation.")
                    .font(.obBody)
                    .foregroundStyle(Color.obTextSecondary)
            }

            VStack(spacing: 8) {
                Text("Try")
                    .font(.obSection)
                    .foregroundStyle(Color.obTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)

                ForEach(suggestions, id: \.self) { suggestion in
                    Button(action: { onPickSuggestion(suggestion) }) {
                        Text(suggestion)
                            .font(.obBody)
                            .foregroundStyle(Color.obTextPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, ObSpacing.cardH)
                            .padding(.vertical, 12)
                            .background(
                                RoundedRectangle(cornerRadius: ObRadius.card, style: .continuous)
                                    .fill(Color.obSurface)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: ObRadius.card, style: .continuous)
                                    .stroke(Color.obBorder, lineWidth: ObStroke.hairline)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, ObSpacing.screenH)

            Spacer()
            Spacer()
        }
    }
}

// MARK: - Input row

private struct InputRowView: View {
    @Binding var text: String
    let isStreaming: Bool
    let onSend: () -> Void
    let onStop: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            HStack {
                TextField(
                    "",
                    text: $text,
                    prompt: Text("Ask Obelisk…").foregroundStyle(Color.obTextTertiary),
                    axis: .vertical
                )
                .font(.obBody)
                .foregroundStyle(Color.obTextPrimary)
                .focused($focused)
                .lineLimit(1...5)
                .submitLabel(.send)
                .onSubmit(onSend)
            }
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

            CircleButton(systemName: "mic", filled: false, action: { /* Phase D */ })
                .disabled(true)
                .opacity(0.4)

            if isStreaming {
                CircleButton(systemName: "stop.fill", filled: true, action: onStop)
            } else {
                CircleButton(
                    systemName: "arrow.up",
                    filled: !text.trimmingCharacters(in: .whitespaces).isEmpty,
                    action: onSend
                )
                .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(.horizontal, ObSpacing.screenH)
        .padding(.vertical, 10)
        .background(Color.obBackground)
    }
}

private struct CircleButton: View {
    let systemName: String
    let filled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(filled ? Color.obBackground : Color.obTextPrimary)
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(filled ? Color.obAccent : Color.obSurface)
                )
                .overlay(
                    Circle().stroke(Color.obBorder, lineWidth: filled ? 0 : ObStroke.hairline)
                )
        }
        .buttonStyle(.plain)
    }
}
