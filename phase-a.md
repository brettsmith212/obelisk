# Phase A — Implementation Overview

A working chat interface where you type a message, the local model streams a reply, the model can call tools, and conversations persist across app launches. **No vault yet, no embeddings, no voice, no Action Button.** Those are later phases.

See [roadmap.md §"Phase A: Text-only chat agent"](./roadmap.md) for the strategic framing and [ui-spec.md](./ui-spec.md) for the visual / interaction spec this phase implements a subset of.

---

## 1. Goals

End-of-phase, on a physical iPhone 15 Pro / 16 Pro running iOS 26:

1. Launch the app and see a chat screen styled per the spec.
2. Type a message, watch tokens stream in.
3. The model can call any of three tools (`DateTime`, `Calculator`, `Scratchpad`) and resume generation with the result.
4. Tap stop mid-stream → generation cancels, partial reply preserved.
5. Tap `✎ edit` on a user message → re-runs from that point, deleting subsequent messages.
6. Tap `↻ regenerate` on the last assistant message → replaces it in place.
7. Open the drawer → see prior conversations grouped by recency → tap one → it loads.
8. Tap "+ New conversation" → fresh empty chat.
9. Kill and relaunch the app → all conversations and history persist.

---

## 2. Scope

### In scope

- `LLMRunner` protocol with one implementation: `AppleFoundationRunner`.
- `Tool` protocol with three concrete tools: `DateTimeTool`, `CalculatorTool`, `ScratchpadTool`.
- `AgentService` that turns a conversation + tool list into an `AsyncStream<AgentEvent>`.
- `ConversationManager` with JSON-file persistence in the app's Documents directory.
- SwiftUI chat shell: top bar, message list, input row, drawer, empty state.
- Visual design system (colors, typography, spacing) per [ui-spec.md §2](./ui-spec.md). Dark mode primary, light mode adaptation.
- Inline tool-call rendering per [ui-spec.md §4.5](./ui-spec.md) — used by all three starter tools.
- Edit / regenerate / stop per [ui-spec.md §4.1–§4.3](./ui-spec.md).
- "Default to ChatGPT behavior" for everything unspecified.

### Out of scope (deferred to later phases)

- **Vault access, frontmatter parsing, embeddings, RAG.** Phase B/C.
- **Citation cards, wikilink rendering.** Phase B/C — there are no vault notes to cite yet.
- **Voice input / dictation / WhisperKit.** Phase D.
- **Action Button, Share Sheet, App Intents, capture flows.** Phase E.
- **Settings screen, onboarding, status pill, app icon, TestFlight.** Phase F.
- **Stub `MLXRunner`.** Explicitly *not* built. Protocol-only seam (see §3.1).
- **Conversation search, export.** Phase F.

### Stretch (only if Phase A finishes early)

- iCloud-backed conversation persistence.
- Keyboard shortcuts on iPad/external keyboard.

---

## 3. Architecture

### 3.1 Module / protocol layout

```diagram
╭─────────────────────────────────────────────╮
│  ChatView (SwiftUI)                         │
│   · DrawerView · MessageListView            │
│   · InputRowView · EmptyStateView           │
╰─────────────┬───────────────────────────────╯
              │
              ▼
╭─────────────────────────────────────────────╮
│  ConversationManager        @Observable     │
│   · activeConversation: Conversation?       │
│   · all: [ConversationSummary]              │
│   · load / save / new / delete / rename     │
│   · persistence: JSON files in Documents    │
╰─────────────┬───────────────────────────────╯
              │
              ▼
╭─────────────────────────────────────────────╮
│  AgentService                               │
│   · run(conversation, tools)                │
│     -> AsyncStream<AgentEvent>              │
│   · events: .token, .toolCallStart,         │
│     .toolCallResult, .toolCallError,        │
│     .finalDone, .error                      │
╰─────┬──────────────────────────────┬────────╯
      │                              │
      ▼                              ▼
╭─────────────────────────╮  ╭───────────────────────────╮
│  LLMRunner (protocol)   │  │  ToolDispatcher           │
│   · generate(messages,  │  │   · register(Tool)        │
│     tools, options)     │  │   · dispatch(call)        │
│     -> AsyncThrowingS…  │  │     -> ToolResult         │
│   · cancel()            │  │                           │
│   · isAvailable         │  │  Tools:                   │
│                         │  │   · DateTimeTool          │
│  AppleFoundationRunner  │  │   · CalculatorTool        │
│   wraps LanguageModel-  │  │   · ScratchpadTool        │
│   Session, @Generable   │  │                           │
│   tool descriptors      │  ╰───────────────────────────╯
╰─────────────────────────╯
```

### 3.2 Discipline rules for the `LLMRunner` seam

Per [roadmap.md Phase A](./roadmap.md):

- Public types on the seam (`Message`, `ToolDescriptor`, `LLMEvent`, `Role`, `ToolCall`, `ToolResult`) are Obelisk types — *not* Foundation Models types.
- `LanguageModelSession`, `Transcript`, `@Generable` live **inside** `AppleFoundationRunner` and never leak through the protocol.
- Tools are defined once against the Obelisk `Tool` protocol with a JSON-schema arg type. `AppleFoundationRunner` adapts each tool to Foundation Models' native `Tool` conformance internally.
- Foundation-Models-only features (guided generation) can be used freely inside the runner but must not appear in the protocol.
- Before merging any change to `LLMRunner`, ask: "Could MLX satisfy this?" If no, push the specialness back into the concrete runner.

### 3.3 Suggested file layout

```
Obelisk/
  App/
    ObeliskApp.swift
    AppEnvironment.swift            // dependency wiring
  UI/
    ChatView.swift
    DrawerView.swift
    EmptyStateView.swift
    MessageListView.swift
    InputRowView.swift
    Components/
      MessageBubble.swift
      ToolCallRow.swift
      EditableUserMessage.swift
    DesignSystem/
      Colors.swift                  // tokens from ui-spec §2.1
      Typography.swift              // Inter + SF Mono per §2.2
      Spacing.swift                 // radii / padding per §2.3
  Domain/
    Conversation.swift              // model + Codable
    Message.swift
    ToolCall.swift
  Services/
    ConversationManager.swift
    AgentService.swift
    LLMRunner.swift                 // protocol + neutral types
    AppleFoundationRunner.swift     // only implementation
    ToolDispatcher.swift
    Tools/
      Tool.swift                    // protocol + JSONSchema arg
      DateTimeTool.swift
      CalculatorTool.swift
      ScratchpadTool.swift
  Persistence/
    ConversationStore.swift         // JSON files in Documents
  Resources/
    Assets.xcassets                 // placeholder icon for now
```

Wire dependencies through `AppEnvironment` (a simple holder of singletons) injected via `@Environment` or constructor.

---

## 4. UI subset implemented in Phase A

Pull from [ui-spec.md](./ui-spec.md), but only these surfaces:

- **§2 Visual language** — implement the full token set now. Cheaper to do once and reuse than to retrofit later.
- **§3.1 Primary chat screen** — top bar, message list, input row, mic *placeholder* (disabled or hidden), send arrow / stop square. Citation cards and wikilink rendering are no-ops (no vault yet).
- **§3.2 Drawer** — conversation list grouped by recency. No search bar yet (low conversation count in Phase A).
- **§3.3 Empty state** — simplified: app name + a single line "Start a conversation." Stats line ("N notes · M tags") is omitted because there's no vault. Suggested prompts can be a small static list that populates the input field on tap.
- **§4.1 edit, §4.2 regenerate, §4.3 stop** — required.
- **§4.5 tool calls** — required for all three starter tools. Use the glyph + tertiary-text inline style.
- **§4.8 errors** — inline error row in the tool-call slot (amber) for tool failures; inline error replacing the assistant turn (red, with "Try again") for model failures. Status pill is deferred — Phase A surfaces app-level state via a transient toast instead, or just relies on inline errors.
- **§9 "Default to ChatGPT behavior"** — applies throughout.

Explicitly **not** in Phase A: settings screen, onboarding, status pill, citation card, wikilink rendering, voice mic interaction, capture, Action Button.

---

## 5. Data model

```swift
struct Conversation: Codable, Identifiable {
    let id: UUID
    var title: String              // first user message, truncated; user-editable later
    var createdAt: Date
    var updatedAt: Date
    var messages: [Message]
}

struct Message: Codable, Identifiable {
    let id: UUID
    var role: Role                 // .system, .user, .assistant, .tool
    var content: String
    var toolCalls: [ToolCall]      // empty for non-assistant or non-tool-using turns
    var status: Status             // .complete, .streaming, .stopped, .errored
    var createdAt: Date
}

enum Role: String, Codable { case system, user, assistant, tool }
enum Status: String, Codable { case complete, streaming, stopped, errored }

struct ToolCall: Codable, Identifiable {
    let id: UUID                   // matches the call id from the runner
    var name: String               // "datetime", "calculator", "scratchpad"
    var arguments: JSONValue       // schema-typed args
    var result: ToolResult?        // nil while in flight
}

struct ToolResult: Codable {
    var output: JSONValue
    var error: String?
}
```

Persistence: one JSON file per conversation in `Documents/conversations/<uuid>.json`, plus an index file `conversations.json` listing summaries (id, title, updatedAt) for fast drawer rendering. Atomic writes (temp file + rename).

---

## 6. Tools

All three exist primarily to exercise the tool-calling loop end-to-end.

| Tool | Args | Returns | Notes |
|------|------|---------|-------|
| `DateTimeTool` | none | current ISO-8601 timestamp + user's local time zone | Trivial; proves the loop. |
| `CalculatorTool` | `expression: String` | numeric result or error | Use `NSExpression` for arithmetic. Reject anything non-arithmetic. |
| `ScratchpadTool` | `action: "read" \| "write" \| "list"`, `name?: String`, `content?: String` | file contents / write confirmation / list of names | Writes to `Documents/scratchpad/`. **Not** the vault. Phase B replaces this with real vault tools. |

Each conforms to the Obelisk `Tool` protocol:

```swift
protocol Tool {
    var name: String { get }
    var description: String { get }
    var argumentsSchema: JSONSchema { get }
    func run(arguments: JSONValue) async throws -> JSONValue
}
```

`AppleFoundationRunner` adapts each `Tool` to Foundation Models' native `Tool` conformance (and to a `@Generable` arg type generated from the JSON schema) inside the runner — never exposed to callers.

---

## 7. Streaming and event flow

`AgentService.run` returns an `AsyncStream<AgentEvent>`:

```swift
enum AgentEvent {
    case token(String)                          // append to current assistant message
    case toolCallStart(ToolCall)                // render tool-call row in "running" state
    case toolCallResult(id: UUID, ToolResult)   // update row with result / error
    case finalDone                              // assistant turn complete
    case error(AgentError)                      // surface inline error
}
```

The UI consumes the stream on the main actor and mutates the active `Conversation` in place. `ConversationManager` debounces saves (e.g., 500ms after last mutation) to avoid hammering disk during streaming.

Cancellation: tapping stop calls `runner.cancel()`, which propagates to `LanguageModelSession`. The current assistant message is marked `.stopped`; any in-flight tool call is marked errored with `"cancelled"`.

---

## 8. Execution order

Sequential — earlier steps unblock later ones.

1. ✅ **Project skeleton.** Xcode project, iOS 26 deployment target, Foundation Models capability enabled, run on simulator and device.
2. ✅ **Design system.** Implement [ui-spec.md §2](./ui-spec.md) tokens — colors, typography, spacing — as `Color` / `Font` extensions. Build a tiny preview gallery to verify dark/light.
3. ✅ **Domain types.** `Conversation`, `Message`, `ToolCall`, etc., with Codable round-trip tests. *(Types in place; explicit round-trip tests deferred until a test target exists.)*
4. ✅ **`Tool` protocol + `DateTimeTool`.** Simplest possible — no I/O.
5. ✅ **`LLMRunner` protocol + neutral event types.** Define and document the seam.
6. ✅ **`AppleFoundationRunner` (DateTime only).** Spin up a `LanguageModelSession`, register the date/time tool, return an `AsyncThrowingStream<LLMEvent>`. Validate that you can pressure-test the model into calling the tool ("what time is it?"). *(Validated on iOS 26.5 simulator — model invoked the tool and streamed a correct answer.)*
7. ✅ **`AgentService`.** Bridges `LLMRunner` stream to `AgentEvent`s, dispatches tool calls through `ToolDispatcher`, feeds results back into the runner.
8. ✅ **`ConversationManager` + `ConversationStore`.** JSON persistence, atomic writes, index file. *(500 ms debounced saves; empty conversations not persisted.)*
9. ✅ **Chat shell — minimum viable.** `ChatView` with hardcoded test conversation rendering. Verify colors / typography / spacing match the spec.
10. ✅ **Streaming wiring.** Send → stream tokens → render. Tool calls render inline. Final state persists. *(Verified on simulator with a real multi-turn FM conversation including tool calls.)*
11. ✅ **Add `CalculatorTool` and `ScratchpadTool`.** *(Runner now uses a `GeneratedContent`-based `JSONArgsToolAdapter` that translates Obelisk's `JSONSchema` into a `DynamicGenerationSchema`; all three Phase A tools share the same adapter. Validated in the iOS 26.5 simulator: `🧮 calculator ✓ → "The result of 14 * 23 is 322."` and `📄 scratchpad ✓ → ideas.md` written to `Documents/scratchpad/`.)*
12. ✅ **Edit / regenerate / stop** ([ui-spec.md §4.1–§4.3](./ui-spec.md)). *(All three wired — edit inline-replaces a user message and truncates everything after, regenerate replaces the last assistant turn in place, stop cancels the streaming task and marks the turn `… stopped`.)*
13. ✅ **Drawer + multiple conversations + "+ New conversation"** ([ui-spec.md §3.2](./ui-spec.md)). *(Slide-over drawer with scrim, conversations grouped Today / Yesterday / Previous 7 days / Previous 30 days / Older, active row highlighted in accent purple, "+ New conversation" creates an empty thread and closes the drawer.)*
14. ✅ **Empty state** ([ui-spec.md §3.3](./ui-spec.md), simplified). *(Wordmark + "Start a conversation." + three static suggestions that populate — not auto-send — the input field; no stats line, per the simplified Phase A scope.)*
15. ✅ **Error handling.** Tool errors → amber inline row. Model errors / unavailability → red replacement with retry. *(Tool-call row now renders the amber error message below the header glyph; failed assistant turns get a red "Try again" button that re-runs through the same regenerate path. `AgentError.humanize` continues to translate common FM raw errors into actionable copy.)*
16. ⬜ **Device QA.** Run on a real iPhone 15 Pro / 16 Pro. Verify Apple Intelligence is on. Test multi-turn, tool use, persistence, cold launch, backgrounding. *(Pending — requires hardware. Simulator validation covers everything else.)*

Multi-turn history note: `AppleFoundationRunner` now rebuilds a `Transcript` per call from the prior `[user, assistant]` pairs, so follow-up questions like "now multiply that by 5" correctly carry forward the previous numeric answer.

---

## 9. Validation checklist

Before declaring Phase A done, every item below must be demonstrably true on a physical device:

- [ ] App builds and launches on iPhone 15 Pro / 16 Pro running iOS 26.
- [ ] Apple Intelligence availability is checked; a clean error UI appears if it's off.
- [ ] Typing a message streams a response token-by-token (visible incremental updates).
- [ ] The model uses each tool at least once across the test session, and the inline tool-call row reflects start → result correctly.
- [ ] Stop button cancels mid-stream; partial reply is preserved and labeled `… stopped`.
- [ ] Editing a user message replays from that point and deletes subsequent messages.
- [ ] Regenerate replaces the most-recent assistant message in place.
- [ ] Quitting the app (swipe up from app switcher) and relaunching: all conversations and messages reload.
- [ ] Drawer correctly groups conversations by recency; tapping switches active conversation; "+ New" creates an empty chat.
- [ ] Dark mode renders with the exact tokens from [ui-spec.md §2.1](./ui-spec.md); light mode is a faithful adaptation.
- [ ] No crash after 20 minutes of mixed use including backgrounding and returning.
- [ ] Tool errors show as amber inline rows; model errors show as red inline rows with retry.

---

## 10. Pitfalls (from roadmap §"Phase A")

- **Foundation Models availability.** Always check `SystemLanguageModel.default.availability` before creating a `LanguageModelSession`. Don't crash if Apple Intelligence is off — surface a clear message.
- **Content guardrails.** Apple applies safety filters; surface refusals as model output, not as errors.
- **Guided generation schema drift.** Version any `@Generable` types you introduce inside `AppleFoundationRunner` so older serialized transcripts don't blow up after a schema change.
- **Memory growth.** Long conversations balloon context. Don't ship Phase A without at least a naive truncation strategy (drop oldest turns above a token threshold).
- **Background eviction.** iOS may kill the app under memory pressure. On foreground, re-create the `LanguageModelSession` rather than assuming it's still valid.
- **Simulator ≠ device.** Foundation Models behavior on the simulator differs meaningfully from on-device. Final validation must be on hardware.

---

## 11. Hand-off to Phase B

What Phase B will inherit and what it must *not* break:

- The `LLMRunner` / `Tool` seam. Phase B adds vault tools (`SearchVaultTool`, `ReadNoteTool`, etc.) by adding more `Tool` conformances; no changes to `LLMRunner`.
- `ScratchpadTool` is the canary — Phase B replaces it with real vault-write tooling that respects the "do no harm" rules ([roadmap.md §"The 'do no harm' rules for vault writes"](./roadmap.md)).
- The UI's citation card and wikilink rendering slots already exist as no-ops; Phase B/C fills them in.
