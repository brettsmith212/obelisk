import SwiftUI

/// The Phase A chat shell. Top bar, message list (or empty state), input
/// row with send/stop toggle. Drawer, edit/regenerate, and full error
/// surfacing land in later steps; this view is the minimum needed for an
/// end-to-end send → stream → persist loop.
struct ChatView: View {
    let env: AppEnvironment

    // Local UI state — not persisted.
    @State private var inputText: String = ""
    @State private var streamingTask: Task<Void, Never>?

    private var manager: ConversationManager { env.manager }
    private var agent: AgentService { env.agent }
    private var isStreaming: Bool { streamingTask != nil }

    var body: some View {
        ZStack {
            Color.obBackground.ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                Divider().background(Color.obBorder)

                if let conversation = manager.activeConversation, !conversation.messages.isEmpty {
                    MessageListView(conversation: conversation)
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
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack {
            Button(action: { /* drawer — step 13 */ }) {
                Image(systemName: "line.3.horizontal")
                    .foregroundStyle(Color.obTextPrimary)
            }
            Spacer()
            Text("Obelisk")
                .font(.obTitle)
                .foregroundStyle(Color.obTextPrimary)
            Spacer()
            Button(action: { /* overflow — later */ }) {
                Image(systemName: "ellipsis")
                    .foregroundStyle(Color.obTextPrimary)
            }
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

        // Append the user turn + a streaming assistant placeholder so the
        // UI updates instantly and the placeholder is in place for token
        // events to mutate.
        manager.updateActive { conversation in
            conversation.messages.append(Message(role: .user, content: prompt))
            if conversation.messages.filter({ $0.role == .user }).count == 1 {
                conversation.title = String(prompt.prefix(60))
            }
            conversation.messages.append(Message(role: .assistant, content: "", status: .streaming))
        }

        guard let snapshot = manager.activeConversation else { return }

        streamingTask = Task { @MainActor in
            let stream = agent.run(conversation: snapshot)
            for await event in stream {
                handle(event)
            }
            // Loop exit reasons: .finalDone, .error, or task cancellation.
            // For cancellation we mark `.stopped`; otherwise leave the
            // status set by `.finalDone` / `.error`.
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

    private func stop() {
        streamingTask?.cancel()
        agent.cancel()
    }

    // MARK: - Stream event reducer

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

    /// Apply a mutation to the most recent assistant message. Used by the
    /// event reducer above so each case stays one line.
    private func mutateLastAssistant(_ mutation: (inout Message) -> Void) {
        manager.updateActive { conversation in
            guard var last = conversation.messages.last, last.role == .assistant else { return }
            mutation(&last)
            conversation.messages[conversation.messages.count - 1] = last
        }
    }
}

// MARK: - Message list

private struct MessageListView: View {
    let conversation: Conversation

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: ObSpacing.messageGap) {
                    ForEach(conversation.messages) { message in
                        MessageRow(message: message)
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
                if let id = conversation.messages.last?.id {
                    withAnimation(.linear(duration: 0.1)) {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

private struct MessageRow: View {
    let message: Message

    var body: some View {
        switch message.role {
        case .user:    UserBubble(message: message)
        case .assistant: AssistantTurn(message: message)
        case .tool, .system: EmptyView()
        }
    }
}

private struct UserBubble: View {
    let message: Message

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            Text(message.content)
                .font(.obBody)
                .foregroundStyle(Color.obTextPrimary)
                .padding(.horizontal, ObSpacing.cardH)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: ObRadius.card, style: .continuous)
                        .fill(Color.obAccent.opacity(0.15))
                )
        }
    }
}

private struct AssistantTurn: View {
    let message: Message

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(message.toolCalls) { call in
                ToolCallRow(call: call)
            }

            if message.content.isEmpty && message.status == .streaming {
                TypingIndicator()
            } else {
                Text(message.content)
                    .font(.obBody)
                    .foregroundStyle(message.status == .errored ? Color.obStatusRed : Color.obTextPrimary)
                    .obBodyLineSpacing()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            if message.status == .stopped {
                Text("… stopped")
                    .font(.obMeta)
                    .foregroundStyle(Color.obTextTertiary)
            }
        }
    }
}

private struct ToolCallRow: View {
    let call: ToolCall

    /// Inline glyph for the tool family per ui-spec §4.5.
    private var glyph: String {
        switch call.name {
        case "datetime":   "⏱"
        case "calculator": "🧮"
        case "scratchpad": "📄"
        default:           "🔧"
        }
    }

    private var trailing: String {
        if let result = call.result {
            return result.error == nil ? "✓" : "✗"
        } else {
            return "…"
        }
    }

    private var color: Color {
        if let result = call.result, result.error != nil {
            return Color.obStatusAmber
        }
        return Color.obTextTertiary
    }

    var body: some View {
        HStack(spacing: 6) {
            Text("\(glyph)  \(call.name)  \(trailing)")
                .font(.obMeta)
                .foregroundStyle(color)
            Spacer()
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

    private let suggestions = [
        "What time is it?",
        "Tell me a haiku about Obsidian.",
        "What can you do?"
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
