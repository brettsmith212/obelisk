# Obelisk: UI / UX Specification

This document is the single source of truth for Obelisk's UI and interaction design. The roadmap describes *what* gets built and in what order; this document describes *how it looks and feels*.

If something is not specified here, the default is **whatever ChatGPT's iOS app does**. That's the fallback for any unsettled interaction question — scroll behavior, keyboard avoidance, text selection, long-press menus, share sheet defaults, "regenerate" placement, edit-message flow, error toast vs. inline error, etc. We are not trying to invent novel chat interactions.

---

## 1. Design principles

1. **Obsidian-native, not Obsidian-replacing.** Obelisk reasons; Obsidian shows and edits. The app never tries to be a markdown editor or note browser. Citations and wikilinks open the corresponding note in Obsidian, not in an in-app preview sheet.
2. **Chat-first, single screen.** The product is a conversation. No dashboards, no card-based homepages, no tabs across the bottom. The drawer (left swipe) is the only secondary surface.
3. **Silent unless something needs attention.** No spurious notifications, no banners celebrating that indexing finished, no "tip of the day". Errors and warnings live in the status pill; everything else is invisible.
4. **Show, don't hide.** Tool calls, citations, and model actions are visible by default. Trust is earned by transparency — a small local model that quietly does the wrong thing is much worse than one that visibly shows its work.
5. **Don't compete with Obsidian's renderer.** No in-app markdown preview of cited notes, no graph view, no embedded canvas. We render assistant *replies* nicely; we do not render *notes*.
6. **No voice output.** Voice is an *input* convenience only (Phase D). Replies are always text. No TTS, no spoken responses, no AVSpeechSynthesizer.
7. **Default to ChatGPT behavior.** Mirror ChatGPT's iOS chat patterns for anything not explicitly specified here. If you find yourself inventing a novel interaction, stop and check whether ChatGPT already solved it.

---

## 2. Aesthetic / visual language

### 2.1 Theme

Dark mode is primary. Light mode is a faithful adaptation, not a separate design.

| Token | Dark | Light |
|-------|------|-------|
| Background | `#1E1E1E` | `#FAFAFA` |
| Surface (cards, input row) | `#262626` | `#FFFFFF` |
| Surface elevated (drawer, modals) | `#2A2A2A` | `#FFFFFF` |
| Border / hairline | `#333333` | `#E5E5E5` |
| Text primary | `#ECECEC` | `#1A1A1A` |
| Text secondary | `#A0A0A0` | `#6B6B6B` |
| Text tertiary (tool calls, timestamps) | `#6E6E6E` | `#9A9A9A` |
| Accent (purple) | `#A78BFA` | `#7C3AED` |
| Status amber | `#F59E0B` | `#D97706` |
| Status red | `#F87171` | `#DC2626` |
| Status green | `#34D399` | `#059669` |

### 2.2 Typography

- **UI text:** Inter (or San Francisco system font if Inter is not bundled). Regular for body, Semibold for emphasis and bubble author labels.
- **Code / inline `code` / code blocks:** SF Mono.
- **Wikilinks (`[[Note name]]`):** rendered with the surrounding `[[` `]]` brackets visible at ~40% opacity; the note name inside is accent purple, semibold, with an underline that appears on press.
- **Tags (`#tag`):** small pill at body-text size, accent-purple fill at ~15% opacity, accent-purple text.
- **Timestamps and meta:** text tertiary, 12pt.
- **Body text:** 16pt, line-height 1.45.
- **Code blocks:** 14pt SF Mono, 12px padding, surface color background, 1px border.

### 2.3 Spacing and shape

- Corner radii: **8–10px** for cards and citation rows, **12px** for the input row, **16px** for the mic / send circular buttons, **20px** for modal sheets.
- 1px hairline borders. No drop shadows. Flat surfaces only.
- Horizontal padding: 16px from screen edge for chat content, 12px inside cards.
- Vertical rhythm between messages: 16px.

---

## 3. Screen sketches

### 3.1 Primary chat screen

```diagram
╭─────────────────────────────────────╮
│  ☰      Obelisk             ⋯       │  ← top bar
├─────────────────────────────────────┤
│                                     │
│  9:42                               │
│  what have I written about          │
│  long-term thinking lately?         │
│  ✎ edit                             │  ← below user msg
│                                     │
│  ───────────────────────────────    │
│  🔍 searching vault for "long-term  │  ← tool call inline
│     thinking"  ✓ 4 notes            │
│                                     │
│  I found 4 recent notes that touch  │  ← assistant text
│  on this. The most central is       │
│  [[Patient capital]], where you     │  ← wikilink in purple
│  draw a line between *waiting*      │
│  and *holding*…                     │
│                                     │
│  ╭─ Sources ───────────────────╮    │
│  │ 📄 Patient capital          │    │  ← citation card
│  │   "...the discipline of     │    │
│  │    holding, not waiting..." │    │
│  │                             │    │
│  │ 📄 5-year horizons          │    │
│  │   "...compounding units..." │    │
│  │                             │    │
│  │ + 2 more                    │    │  ← tap to expand
│  ╰─────────────────────────────╯    │
│  ↻ regenerate                       │  ← below assistant msg
│                                     │
├─────────────────────────────────────┤
│  ╭─────────────────────╮  ╭─╮  ╭─╮  │
│  │ Ask your vault…     │  │🎙│  │⤴│  │  ← input row
│  ╰─────────────────────╯  ╰─╯  ╰─╯  │
╰─────────────────────────────────────╯
```

Top bar: hamburger (drawer), title "Obelisk", overflow `⋯` (rename, delete, export current conversation).

Message order: user messages right-aligned in a subtle accented bubble; assistant messages left-aligned without a bubble (just text on background), to keep long replies readable. Tool calls and citation cards are visually part of the assistant turn that produced them.

Input row: rounded multi-line text field; mic button to its right; send arrow on the far right. Mic and send are 32pt circular buttons. The send arrow becomes a stop square (■) while a response is generating.

### 3.2 Drawer (left swipe / hamburger)

```diagram
╭──────────────────────────╮
│  + New conversation      │
├──────────────────────────┤
│  Today                   │
│  · long-term thinking    │
│  · grocery list ideas    │
│                          │
│  Yesterday               │
│  · daily standup notes   │
│                          │
│  Previous 7 days         │
│  · …                     │
│                          │
├──────────────────────────┤
│  ⚙  Settings             │
╰──────────────────────────╯
```

Conversations are grouped by recency (Today / Yesterday / Previous 7 days / Previous 30 days / older). Long-press a row: rename, delete, export to markdown. Search bar at top appears once there are more than ~20 conversations.

### 3.3 Empty state (new conversation)

```diagram
╭─────────────────────────────────────╮
│  ☰      Obelisk             ⋯       │
├─────────────────────────────────────┤
│                                     │
│                                     │
│            Obelisk                  │  ← centered, large
│                                     │
│   1,247 notes · 89 tags             │  ← stats line, muted
│   indexed 4 min ago                 │
│                                     │
│                                     │
│   Try:                              │  ← suggested prompts
│   ╭─────────────────────────────╮   │
│   │ What was I working on this  │   │
│   │ week?                       │   │
│   ╰─────────────────────────────╯   │
│   ╭─────────────────────────────╮   │
│   │ Summarize my notes on …     │   │
│   ╰─────────────────────────────╯   │
│   ╭─────────────────────────────╮   │
│   │ What's in my inbox folder?  │   │
│   ╰─────────────────────────────╯   │
│                                     │
├─────────────────────────────────────┤
│  ╭─────────────────────╮  ╭─╮  ╭─╮  │
│  │ Ask your vault…     │  │🎙│  │⤴│  │
│  ╰─────────────────────╯  ╰─╯  ╰─╯  │
╰─────────────────────────────────────╯
```

Tapping a suggested prompt populates the input field (does not auto-send). The suggested prompts are a small static curated list; we are not dynamically generating them from the vault in v1.

### 3.4 Settings

Single scrollable list grouped into sections; no nested tabs.

```diagram
╭─────────────────────────────────────╮
│  ‹ Back        Settings             │
├─────────────────────────────────────┤
│  VAULT                              │
│   Path           /…/MyVault         │
│   Change vault…                  ›  │
│   Indexing       up to date         │
│   Re-index now                   ›  │
│                                     │
│  MODEL                              │
│   Apple Foundation Models           │
│   On-device · available             │
│                                     │
│  TOOLS                              │
│   Web search             [ on ]     │
│   Search API key         ••••••     │
│   Authorized Shortcuts        ›     │
│                                     │
│  AUTHORIZED FOLDERS                 │
│   obelisk/                       ✓  │
│   Daily Notes                    ✓  │
│   + Add folder…                  ›  │
│                                     │
│  VOICE                              │
│   Dictation             [ on ]      │
│   Whisper model        base.en   ›  │
│                                     │
│  ABOUT                              │
│   Version, privacy, licenses        │
╰─────────────────────────────────────╯
```

Notes:
- **Model** section is informational only in v1 (no picker, no download). It exists so users can see at a glance which backend is active and whether Apple Intelligence is available.
- **Authorized folders** is the user-facing surface of the "do no harm" write rules. Each folder is added explicitly via the document picker.
- **Voice** section appears only after Phase D ships. Dictation toggle disables the mic button entirely if off.

### 3.5 Onboarding

Three short screens, swipeable, with a single primary button per screen.

1. **Welcome.** "Obelisk is an AI companion for your Obsidian vault. Everything runs on this iPhone — your notes don't leave the device." Plus a small "What it does *not* do" list: not a note editor, not a cloud service, not a replacement for Obsidian. Primary button: **Continue**.
2. **Pick your vault.** Document-picker button. iCloud Drive placeholder check (warn if the vault is iCloud-stored and may not be fully downloaded). Primary button: **Choose vault folder** → on success, **Continue**.
3. **Check Apple Intelligence.** If available and enabled: green check, **Get started**. If the device is supported but Apple Intelligence is off: deep-link to Settings → Apple Intelligence. If the device is unsupported: hard block with explanation, no path forward (Obelisk requires iPhone 15 Pro / 16 Pro+ on iOS 26+).

---

## 4. Interaction patterns

### 4.1 Editing user messages

Tap the `✎ edit` affordance below any user message → that bubble becomes an inline editable text field with the original content pre-filled → the send arrow appears next to it → Return or send confirms. On confirm, the edited message replaces the original *and all subsequent messages in the conversation are deleted*, then the agent re-runs from that point. This is ChatGPT's behavior.

### 4.2 Regenerate

Tap the `↻ regenerate` affordance below the most recent assistant message → the response is replaced in-place with a new streamed response. Only available on the last assistant turn (not historical ones). ChatGPT-style.

### 4.3 Stop generation

While the model is generating, the send arrow on the input row becomes a stop square (■). Tap it → cancels the current generation. Any partial stream that arrived is kept and marked as `… stopped` in tertiary text below it. The user can then edit their previous message, regenerate, or just send a new one.

### 4.4 Voice input — live dictation (Phase D)

Voice is a dictation convenience, not a separate "voice mode". The pattern is the iOS keyboard dictation pattern, not a walkie-talkie:

1. Tap the 🎙 mic button in the input row.
2. Button becomes a pulsing red square. Audio capture starts. WhisperKit streams partial transcripts directly into the input text field, updating in place as more words are recognized.
3. Tap again (or tap the stop square) to stop dictation. The transcribed text remains in the input field as if the user had typed it.
4. The user reviews and edits the transcription, then taps send manually.

No auto-send on silence. No VAD-driven endpointing that fires the message. No spoken response. The mic is just a faster keyboard.

### 4.5 Tool calls

Rendered inline in tertiary text, indented slightly, with a small leading glyph indicating the tool family:

- `🔍 searching vault for "<query>"  ✓ 4 notes`
- `🌐 web search "<query>"  ✓ 6 results`
- `📄 reading [[Patient capital]]`
- `⏱  date/time`
- `🧮 calculator: 14 * 23`

While the tool is running, the row shows `…` instead of a result count. On error, the row turns amber and shows the error message. Tool call rows are not interactive in v1 (no expand-to-see-arguments). They sit visually inside the assistant turn that triggered them, above the assistant's prose reply.

### 4.6 Citations

When the assistant cites vault notes, a "Sources" card appears at the end of that assistant turn (see sketch in §3.1):

- Header text "Sources" in secondary text.
- Each row: file icon, note title in primary text, snippet in secondary text (1–2 lines, truncated).
- Up to 3 rows expanded by default, then `+ N more` to expand the rest.
- Tap a row → opens the note in Obsidian via deep link (`obsidian://open?vault=…&file=…`). No in-app preview sheet.

### 4.7 Wikilinks in assistant replies

When the model emits `[[Note name]]`, `[[Note|Display]]`, `[[Note#Heading]]`, or `[[Note^block]]` in its prose, it's rendered as a tappable link styled per §2.2 (purple, with low-opacity brackets around it). Tap → Obsidian deep link, including heading or block reference if present. No in-app preview.

### 4.8 Errors

Three tiers, in order of severity:

1. **Inline error in a tool-call row** — the tool failed but the conversation continues. Amber.
2. **Inline error replacing the assistant turn** — the model itself failed (load error, content guardrail refusal, etc.). Red. Includes a "Try again" button.
3. **Status pill at the top of the screen** — see §5. Used for app-level state that affects everything (vault disconnected, Apple Intelligence unavailable, low memory).

Never use modal alerts for errors that the user can't act on right now.

---

## 5. Status pill system

A single full-width pill below the top bar, color-coded. Only one pill is visible at a time; severity wins.

| Color | Use | Example copy |
|-------|-----|--------------|
| Green | Transient confirmation (~2s, then auto-dismiss) | "Indexed 12 new notes" |
| Amber | Warning, app still functional | "Vault not fully downloaded from iCloud" |
| Red | Hard error, action required | "Vault disconnected — tap to reconnect" |

The pill is tappable when there's an action to take (reconnect vault, open Settings → Apple Intelligence, retry index). Otherwise it's purely informational. Green pills auto-dismiss; amber and red pills persist until the underlying condition is resolved.

---

## 6. Capture flows (Phase E)

Capture is how content gets *into* the vault from outside Obelisk. There is **no in-chat capture button** — capture is a system-level entry point, not a chat affordance.

Two flows:

1. **Share Sheet extension.** When the user taps Share in any app and picks Obelisk, the shared content (URL, selected text, image) is written to `obelisk/inbox/` as a new markdown note with `source: obelisk` frontmatter and a timestamp. A small confirmation toast ("Saved to Obelisk inbox") appears in the source app. No chat is opened.
2. **App Intent: "Capture to Obelisk".** A `CaptureToObeliskIntent` that takes a `text: String` parameter and writes it to `obelisk/inbox/` the same way. Available to Shortcuts, Siri, Spotlight, and (if the user binds it) the Action Button as an alternate to the chat flow.

Both flows write to the inbox folder only. No model invocation, no agent loop, no chat history — capture is a pure write operation. The user can later open Obelisk and ask "what's in my inbox?" to triage.

---

## 7. Action Button flow (Phase E)

The Action Button binds (via the user, in iOS Settings) to an `AskObeliskIntent` variant whose behavior is:

1. **Launch the app directly into a new conversation.** Not the most recent conversation — a fresh one. This avoids the awkwardness of "Action Button accidentally edits an existing thread."
2. **Start dictation immediately.** The mic is already in the pulsing-red recording state when the app appears. WhisperKit streams partial transcripts into the input field exactly as described in §4.4.
3. **No auto-send.** The user reviews the transcription and taps send. This is critical — Action Button presses are easy to fat-finger, and we never want a half-thought to be silently sent to the model.
4. **Tap the stop square or the mic again to end dictation.** Standard dictation rules apply.

So the full flow is: hold Action Button → Obelisk opens in a new chat with mic live → speak → tap to stop → review → tap send. This is deliberately one extra tap compared to a hands-free "speak and it answers" flow; the tradeoff is that the user always sees what's about to be sent.

---

## 8. App icon direction (Phase F)

- **A stylized geometric mark.** Not a literal obelisk illustration. Not a 3D-rendered Egyptian monument. The product is called Obelisk because it's tall, dark, and stores knowledge — the icon should *evoke* that, not depict it.
- Complementary to Obsidian's `◇` diamond mark. Same family of shape language: a single recognizable geometric primitive, flat, monochrome with a small accent, instantly readable at 60×60px.
- Purple accent dominant (per §2.1). Dark background.
- Should look at home next to Obsidian on a home screen and on the lock screen / Action Button bind sheet.

Explicit non-goals for the icon: realism, gradients, drop shadows, photographic textures, anything that reads as "AI assistant" cliché (no robot, no sparkles, no chat bubble).

---

## 9. "Default to ChatGPT behavior" rule

This is the tiebreaker for any unsettled UI question. If we haven't specified a behavior here and there is no Obsidian-specific reason to invent one, mirror ChatGPT's iOS app. Specifically:

- Scroll position and auto-scroll-to-bottom behavior during streaming.
- Keyboard avoidance and input-row sticky positioning.
- Long-press menu on messages (copy, share, select text).
- Text selection inside assistant replies.
- "Stop generating" placement, label, and behavior.
- Edit-message / regenerate placement and behavior.
- Loading states (typing indicator dots while waiting for first token).
- Error retry affordance.
- Pull-down to dismiss keyboard.
- Markdown rendering of assistant prose (lists, headings, bold/italic, code).

We are not trying to be more original than ChatGPT in chat-shell mechanics. Our originality is in: vault-awareness, citations, wikilinks, tool transparency, Obsidian deep-linking, local-first model, capture and Action Button flows. Everything else should feel reassuringly familiar.
