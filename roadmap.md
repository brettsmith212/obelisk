# Obelisk: A Local AI Companion for Obsidian on iPhone — Roadmap

## What Obelisk is

An iPhone companion app for Obsidian users. It connects to your existing vault and uses an on-device AI model to answer questions about your notes, search across them, summarize, capture new thoughts, do web research, and produce daily/weekly digests — all without per-request fees and without sending your notes to any cloud service.

The wedge is Obsidian-native. Existing Obsidian AI plugins on iPhone either depend on paid cloud APIs (OpenAI, Anthropic) or don't work at all (Ollama can't run on iOS, the plugin sandbox can't run native ML inference). Obelisk is built around Obsidian's specific structure — vault layout, wikilinks, frontmatter, tags, daily notes — on top of the best on-device model available on the phone.

**Working name:** Obelisk.
**Product positioning:** A private, Obsidian-native AI companion for your vault. On iPhone. Free per request.
**Target audience:** Existing Obsidian users who care about local-first / privacy and don't want to pay for an API subscription. Skews toward power users, researchers, students, knowledge workers.
**Target platform:** iPhone 15 Pro and up (need Apple Intelligence support + memory headroom).
**Target OS:** iOS 26+ (required for the Foundation Models framework).
**Shipping target:** TestFlight, for personal use and a small group of friends.
**Time commitment:** Nights and weekends, ~year-long arc (used as a relative difficulty estimate, not a deadline).

## UI / UX direction

The full UI specification — design principles, visual language (Obsidian-native, dark-mode primary, purple accent, Inter + SF Mono), screen sketches, interaction patterns, status pill system, capture and Action Button flows, app icon direction — lives in [ui-spec.md](./ui-spec.md). The roadmap describes *what* gets built and in what order; the spec describes *how it looks and feels*.

The governing rule for anything unspecified: **default to ChatGPT's iOS behavior.** Originality belongs in vault-awareness, citations, wikilinks, tool transparency, and Obsidian deep-linking — not in chat-shell mechanics.

## Model strategy: Foundation Models for v1, MLX as a power-user path

Apple's Foundation Models framework (iOS 26+) gives third-party apps free, on-device access to Apple's ~3B-parameter foundation model — the same model that powers Apple Intelligence. It supports constrained tool calling, guided generation (`@Generable`), and LoRA adapters out of the box. Per Apple's [2025 tech report](https://machinelearning.apple.com/research/apple-foundation-models-tech-report-2025), the model is competitive with Qwen 2.5/3 3–4B and Gemma 3 4B at its size class.

**v1 default:** Foundation Models. No 2GB model download, no chat template debugging, no manual KV cache management, system-managed memory, constrained tool calling that won't emit malformed JSON.

**v1 fallback / power-user option:** MLX-Swift with a model from `mlx-community` (Gemma 3 2B Q4 or Qwen 2.5 3B Q4) for users who want a larger or different model, fewer content guardrails, or who are on devices that don't support Apple Intelligence.

**Implication for architecture:** the agent code is written against an `LLMRunner` protocol. Day-one implementations are `AppleFoundationRunner` and `MLXRunner`. The user picks in Settings; Foundation Models is the default when available.

## Memory budget (iPhone 15 Pro / 16 Pro, ~3.5 GB app budget before jetsam)

| Component                           | Foundation Models v1 | MLX (Qwen 2.5 3B Q4) |
|-------------------------------------|----------------------|----------------------|
| SwiftUI + chat UI                   | ~150 MB              | ~150 MB              |
| Vault index (SQLite)                | ~50–300 MB           | ~50–300 MB           |
| Embedding cache (hot subset)        | ~50–200 MB           | ~50–200 MB           |
| LLM weights resident                | 0 (system-managed)   | ~1.8 GB              |
| KV cache (4K context)               | system-managed       | ~200–400 MB, grows   |
| WhisperKit (base, when loaded)      | ~150 MB              | ~150 MB              |
| Headroom required                   | ≥500 MB              | ≥500 MB              |

Decision rules:
- Only one of {MLX LLM, Whisper-large} is resident at a time. Voice mode quiesces the LLM, transcribes, then reloads.
- When using Foundation Models, the OS handles weight residency across apps; do not assume the model is hot.
- Re-measure on real devices each phase; this table is the starting estimate.

## Non-goals

- **Not an Obsidian replacement.** Obelisk does not edit notes in its own UI, render markdown nicely, support graphs/canvas, etc. Obsidian handles editing; Obelisk handles reasoning.
- **Not an Obsidian plugin.** Obsidian's iOS plugin sandbox can't run native ML inference, and the available AI plugins on mobile route to paid cloud APIs. Obelisk is a sibling app that operates on the same vault folder and uses an on-device model.
- **Not a Templater-compatible templating engine.** Templater templates contain JavaScript that runs in Obsidian's environment. Out of scope.
- **Not a Dataview / Bases query engine.** Those are Obsidian-specific query languages. Out of scope.
- **Not Siri at the system level.** Apple owns the wake word, lock screen, CarPlay, etc.
- **Not a frontier-quality reasoner.** Local 2-4B models are noticeably weaker than Opus or GPT-4. The product hypothesis is privacy + vault context, not raw capability.
- **Not fine-tuning custom models.** Out of v1; could add later.
- **Not a Mac app.** Out of v1; code largely ports, but iPhone-first is the differentiator. The Mac side is well-served by Ollama + Smart Connections / Copilot.
- **Not a multimodal vision app.** Out of v1.

## Working approach with Claude Code

You're using AI to write the implementation and reviewing the output. The split that works:

**You own:** architecture decisions, library and model choices, prompt engineering for the agent (taste-driven, matters a lot), tool design (what tools exist, what their schemas look like), UX flows, scope decisions.

**You delegate:** Swift syntax, SwiftUI plumbing, MLX-Swift wiring, networking code, file I/O, build system, most boilerplate.

The pattern: write a short design doc for each phase or feature *before* asking Claude Code to implement. This forces the learning to happen at the architecture layer, which is where it matters most.

## Tech stack

- **Swift + SwiftUI** for the app
- **Foundation Models framework** (iOS 26+) for the default on-device LLM, tool calling, and guided generation
- **MLX-Swift** for the optional power-user LLM backend (`ml-explore/mlx-swift`, `ml-explore/mlx-swift-examples`)
- **swift-transformers** (`huggingface/swift-transformers`) for tokenizers when using the MLX backend
- **WhisperKit** for on-device speech-to-text (Phase D)
- **NaturalLanguage framework** (built into iOS) for initial embeddings, possibly swap for an MLX embedding model later
- **Yams** (`jpsim/Yams`) for YAML frontmatter parsing
- **GRDB.swift** for SQLite storage of the embedding index and metadata
- **swift-markdown** (`apple/swift-markdown`) for AST-aware markdown parsing
- **AppIntents framework** for Shortcuts / Action Button integration (Phase E)
- **Files framework** for vault access via document picker + security-scoped bookmarks

**Default model (v1):** Apple Foundation Models on-device (~3B params, 2-bit QAT, system-managed).
**Optional MLX models:** `mlx-community/gemma-3-2b-it-4bit` (smaller/faster) or `mlx-community/Qwen2.5-3B-Instruct-4bit` (stronger reasoner). Exposed in Settings; user opts in.

## The "do no harm" rules for vault writes

The user trusts you with years of notes. Violating that trust loses them permanently. These rules are non-negotiable from Phase B onward:

1. **Every Obelisk-created file has `source: obelisk` in YAML frontmatter.** Your single most important safety marker.
2. **Obelisk only writes to folders the user has explicitly authorized.** Default: an `obelisk/` subfolder Obelisk creates inside the vault. User can authorize others (daily notes folder, inbox folder, etc.) explicitly.
3. **Obelisk never deletes files it didn't create.** Even if asked. Suggest deletion to the user; let them confirm in Obsidian.
4. **Best-effort frontmatter preservation.** Obelisk only writes to frontmatter keys it added itself or the user explicitly asked be changed. Untouched keys are preserved verbatim by splicing changes into the original text by line offset rather than round-tripping through Yams. Comments and exact formatting on untouched keys survive; comments embedded *inside* a key Obelisk is editing may not. In v1, Obelisk does not perform structural edits to existing frontmatter — only adds new keys or updates specific values.
5. **All writes are atomic.** Write to a temp file, then rename. No partial writes that could corrupt a note mid-save.
6. **Conflict handling.** If a file changed since Obelisk last read it, surface the conflict and ask. Don't silently overwrite.

---

## Phase 0: Swift onboarding (1–2 weekends)

You've never written Swift. You don't need fluency — you need to *read* Swift confidently and know enough to debug what Claude Code produces.

### Mental model coming from Python/TS/Go/C++

Swift feels closest to TypeScript with a Rust-flavored memory model and a stronger type system.

- `struct` is a value type (copied), `class` is a reference type (ARC-counted). Default to struct unless you need identity or inheritance.
- `protocol` is like a Go interface but more powerful — supports associated types and default implementations via `extension`.
- Generics work like you'd expect from C++ / TS.
- `async/await` is essentially identical to TypeScript's.
- Optionals (`Type?`) are like Rust's `Option<T>`. Unwrap with `if let`, `guard let`, or `?.` chains.
- `@State`, `@Observable`, `@MainActor` are property wrappers / macros, not annotations. They generate code behind the scenes.
- Result builders are the DSL syntax that powers SwiftUI. Looks magical, isn't — just function composition with a specific shape.

### Goals

- Read Swift code without it feeling foreign.
- Know what `@State`, `@Observable`, `@Binding`, `@Environment` do.
- Understand SwiftUI's declarative model and how view updates work.
- Be able to navigate Xcode (build, run, debug, look at the simulator).

### Resources

- Apple's "A Swift Tour" (single-page overview at swift.org/documentation)
- Apple's SwiftUI tutorial (the Landmarks one — go through it end to end)
- Paul Hudson's *100 Days of SwiftUI* — skim the first 20 days; don't grind through it all

### Deliverable

A throwaway todo app: add items, mark complete, persist with `@AppStorage` or `SwiftData`. The point isn't the app, it's confirming you can read and reason about SwiftUI views, state, and lifecycle.

### What to skip

- Combine (mostly superseded by async/await for new code)
- UIKit (you'll only need SwiftUI for v1)
- Storyboards (dead, ignore)
- Deep dive into Swift concurrency models — surface understanding is enough

---

## Phase A: Text-only chat agent (4–6 weeks)

> **Status: ✅ Complete** — see [phase-a.md](./phase-a.md) for the execution log. Three on-device tools (`datetime`, `calculator`, `scratchpad`) wire end-to-end through Foundation Models with multi-turn `Transcript` history; chat shell ships drawer, edit, regenerate, stop, and inline error tiers per [ui-spec.md](./ui-spec.md). Physical-device QA on iPhone 15 Pro / 16 Pro is the only open thread.

This is the foundation. Everything else sits on it. Don't rush.

### Goal

A working chat interface where you type a message, the local model streams a reply, the model can call tools to extend itself, and conversations persist across app launches.

### Key concepts to understand

**Chat templates.** Every instruct-tuned model has a specific format for system/user/assistant turns. Get this wrong and the model degenerates into nonsense. `swift-transformers` handles most of it via the tokenizer's chat template metadata.

**Tokenization.** Models think in tokens, not characters. You'll need a tokenizer that matches your model. `swift-transformers` provides this.

**KV cache.** The model's working memory during generation. Lives in RAM, grows with conversation length. You decide when to truncate (you will need to — phones don't have unbounded memory).

**Sampling parameters.** Temperature, top-p, top-k, repetition penalty. Defaults are fine to start (temp 0.7, top-p 0.95). Tune later if outputs feel off.

**Tool-calling loop.** Modern instruct models emit tool calls as structured text — usually JSON inside special tokens like `<tool_call>...</tool_call>` (format varies by model). The loop:
1. Send conversation + tool definitions to model
2. Stream output, watching for tool-call markers
3. If tool call detected: parse → dispatch the tool → append result as a tool message → resume generation
4. If no tool call: deliver the final response to the user
5. Continue until model emits a stop token without a pending tool call

### Architecture sketch

```
ChatView (SwiftUI)
    │
    ▼
ConversationManager
    - conversation history
    - persistence (start with JSON files in Documents)
    │
    ▼
AgentService
    - takes conversation + tool list
    - returns AsyncStream<AgentEvent>
    - events: .token, .toolCallStart, .toolCallResult, .finalAnswer, .error
    │
    ├──► LLMRunner (protocol)
    │    - generate(messages:tools:options:) -> AsyncThrowingStream<LLMEvent>
    │    - isAvailable, cancel()
    │    │
    │    └── AppleFoundationRunner   ← only v1 implementation
    │        - wraps LanguageModelSession
    │        - uses @Generable tool descriptors
    │        - guided generation for structured outputs
    │
    └──► ToolDispatcher
         - registry of available tools
         - receives structured calls from the runner
         - executes and returns results
         - tools: DateTimeTool, CalculatorTool, ScratchpadTool
```

The `LLMRunner` protocol is the extensibility seam. v1 ships exactly one implementation (`AppleFoundationRunner`), but the protocol is designed so a second backend (MLX, in a later version) can be added without touching `AgentService` or the tool layer.

Discipline rules for keeping the seam intact:

- The protocol surface stays neutral: `Message`, `ToolDescriptor`, `LLMEvent` are Obelisk types, not Foundation Models types. `LanguageModelSession`, `Transcript`, and `@Generable` live *inside* `AppleFoundationRunner` and never leak to callers.
- Tools are defined once against a shared `Tool` protocol with a JSON-schema arg type. `AppleFoundationRunner` adapts them to Foundation Models' native `Tool` conformance. A future MLX runner would render them into a text-based tool-call format.
- Features unique to one backend (e.g., guided generation) can be used freely *inside* the runner that supports them, but must not appear in the protocol — otherwise the second backend can't satisfy it.
- Before merging any change to `LLMRunner`, mentally check: "could MLX satisfy this?" If no, push the specialness back into the concrete runner.

### Starter tools (build all three)

- **DateTimeTool** — returns current date/time. Trivial, but tests the loop end-to-end.
- **CalculatorTool** — basic arithmetic. Tests parameter parsing.
- **ScratchpadTool** — read and write markdown files in the app's own Documents folder (not yet a vault). Tests stateful tools. This is throwaway code that Phase C replaces with proper vault access.

### Approach

1. Define the `LLMRunner` protocol and `Tool` protocol with neutral types (`Message`, `ToolDescriptor`, `LLMEvent`). Sketch the minimal surface needed by `AgentService`. Mentally pressure-test: could a hypothetical MLX backend satisfy this? If no, narrow the protocol.
2. Build `AppleFoundationRunner` as the only implementation. Spin up a `LanguageModelSession`, register a single tool (DateTime) via the `Tool` protocol, stream a response. This should be ~an afternoon, not a week — Foundation Models removes most of the boilerplate.
3. Build the SwiftUI chat shell with streaming display (use `AsyncStream` for event delivery).
4. Add the other two starter tools.
5. Add conversation persistence and "new conversation" reset.
6. Test on a real device — Foundation Models requires Apple Intelligence to be enabled, and the simulator behavior differs from the device.

Do **not** stub `MLXRunner` in v1. The protocol is the extensibility seam; an empty stub is dead code with no value. A second runner is a deferred-version concern.

### Resources

- Foundation Models docs: `https://developer.apple.com/documentation/FoundationModels`
- "Generating content and performing tasks with Foundation Models": `https://developer.apple.com/documentation/FoundationModels/generating-content-and-performing-tasks-with-foundation-models`
- Tool calling: `https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling`
- WWDC 2025 session 286 "Meet the Foundation Models framework"
- WWDC 2025 session 301 "Deep dive into the Foundation Models framework"
- WWDC 2025 session 259 "Code-along: Bring on-device AI to your app using the Foundation Models framework"
- For the MLX path (deferred): `https://github.com/ml-explore/mlx-swift-examples`, `https://rudrank.com/exploring-mlx-swift-getting-started-with-tool-use`, `https://huggingface.co/mlx-community`

### Pitfalls

- **Foundation Models availability.** The model is only available when the user is on a supported device *and* has Apple Intelligence enabled. Always check `SystemLanguageModel.default.availability` and have a fallback UI explaining how to enable it.
- **Content guardrails.** Apple applies safety filters. Personal notes touching sensitive topics may be refused. Surface refusals clearly; do not pretend they're errors.
- **Guided generation schema drift.** When you update a `@Generable` type, old conversation transcripts may not deserialize. Version your generable types.
- **For MLX backend (when built): chat template formatting.** If outputs are gibberish or the model refuses to use tools, this is almost always the culprit. Print the exact prompt being sent to the model and compare against the model card.
- **For MLX backend: tool-call parsing.** Small models occasionally emit malformed JSON. Build a forgiving parser. If parsing fails, append an error message to the conversation and let the model retry.
- **Memory growth.** Conversation history will balloon. Plan for context truncation (drop oldest turns, or summarize them) before you ship.
- **Background eviction.** iOS will kill your app under memory pressure. On foreground, re-create the `LanguageModelSession` rather than assuming it's still valid.
- **Bundling vs downloading the MLX model.** Don't bundle — the app would be 2GB. Download on first launch with a progress UI. (Not relevant for the Foundation Models default; the model is system-provided.)

### Deliverable

You can have a multi-turn conversation, the model uses all three tools when appropriate, conversations save and reload, and it runs on your physical iPhone without crashing.

---

## Phase B: Vault connection and Obsidian primitives (4–6 weeks)

Before Obelisk can be useful, it needs to be able to safely read and reason about an Obsidian vault. This phase is the parsing and access layer.

### Goal

User picks their vault, Obelisk scans it, builds an index of notes, links, and tags, and can answer basic questions about it via the chat agent.

### Step 1: Vault picker and access

Use `UIDocumentPickerViewController` to let the user pick a folder. Persist access with a security-scoped bookmark stored in `UserDefaults`. On every launch, resolve the bookmark and start access (`startAccessingSecurityScopedResource`). Always wrap reads/writes in `NSFileCoordinator` for files outside the app container.

The vault location can be On My iPhone, iCloud Drive, Obsidian Sync's folder, or another cloud provider. v1 explicitly supports On My iPhone (lowest friction) and iCloud Drive (with the constraints in Step 1.5). Other providers (Dropbox, Google Drive via Files) are unsupported in v1 — they may work, but no guarantees.

Detect that it's an Obsidian vault by looking for a `.obsidian/` folder inside. If present, read the relevant config files (more below). If absent, offer to treat it as a plain markdown folder.

### Step 1.5: iCloud Drive handling

iCloud Drive vaults are common but full of sharp edges. v1 supports them, but with explicit constraints:

- **Placeholder detection.** Walk the vault on connect; if any file is an `.icloud` placeholder (not downloaded), refuse to index and prompt the user to mark the vault folder as "Keep on this iPhone" in the Files app. Re-check on each app foreground.
- **Force-download flow.** For users who have Optimize iPhone Storage enabled, offer to trigger `startDownloadingUbiquitousItem(at:)` for each placeholder, with progress. Warn that this may consume significant data and storage.
- **Content-hash change detection, not modification dates.** iCloud often reports stale `modificationDate` values. Use a SHA-256 of file contents to decide whether a re-index is needed.
- **`NSFileCoordinator` everywhere.** Required for safe interleaving with iCloud syncs. Reads use `coordinate(readingItemAt:options:error:byAccessor:)`; writes use the writing variant. Failure to coordinate causes silent data loss when another device writes concurrently.
- **Bookmark staleness recovery.** iCloud metadata rebuilds can stale bookmarks. On stale, do not crash — re-prompt the user via the document picker and replace the bookmark.
- **Change-monitoring caveat.** `NSFilePresenter` does not reliably fire for changes made on other devices via iCloud. Treat foregrounding as a "rescan trigger" rather than relying on live notifications.
- **Conflict handling.** Don't try to resolve iCloud conflicts; defer to iCloud's own conflict files and tell the user.
- **No multi-device write coordination promise.** v1 assumes a single primary writer at any moment. If the user is editing the same note in Obsidian on Mac while Obelisk is writing on iPhone, behavior is undefined.

Onboarding should recommend "On My iPhone" or Obsidian Sync's local folder as the default; iCloud Drive is supported but flagged as advanced.

### Step 2: Obsidian config awareness

Read these files from `.obsidian/`:

- `daily-notes.json` — folder, date format, template path for daily notes. Fall back to sensible defaults if absent.
- `templates.json` — template folder location.
- `app.json` — general settings.
- `core-plugins.json` — which core plugins are enabled.

Detect community plugins by listing `.obsidian/plugins/*`. Specifically check for Templater (warn the user that Obelisk can't run Templater templates).

### Step 3: Markdown parsing primitives

Build a small library of vault-specific parsing utilities. These are used everywhere downstream:

- **FrontmatterParser** — uses Yams. Reads YAML frontmatter, returns `(frontmatter, body)`. Round-trip safe so edits preserve original structure.
- **WikilinkParser** — finds `[[Link]]`, `[[Link|Display]]`, `[[Link#Heading]]`, `[[Link^block]]`. Returns structured references. Resolves to file paths using Obsidian's name-matching rules.
- **TagExtractor** — finds inline `#tag` (skipping code blocks and URLs) and frontmatter `tags:`. Supports hierarchical tags like `#project/obelisk`.
- **MarkdownChunker** — splits a note into chunks for embedding. Use `swift-markdown` AST to split at heading boundaries when possible, falling back to paragraph splits. Target 200-400 tokens per chunk with light overlap.

### Step 4: Vault index

A SQLite database (via GRDB) at `<app data>/vault-index.sqlite` storing:

- `notes` — one row per markdown file: path, title, content hash, frontmatter as JSON, last-modified date
- `links` — one row per wikilink: source path, target path, target heading/block (optional)
- `tags` — one row per tag occurrence: path, tag, count
- `embeddings` (added in Phase C) — one row per chunk

On first vault connection, full scan. After that, watch for changes via `NSFilePresenter` or polling on app foreground, and incrementally update only changed files (compare content hash).

### Step 5: Vault tools for the agent

Replace the ScratchpadTool with these:

- **SearchVaultTool** — full-text and metadata search. Args: query string, optional tag filter, optional folder filter. Returns: list of `(path, title, snippet, score)`. Phase C will add semantic search alongside this.
- **ReadNoteTool** — reads a single note by path. Returns the full body (or a chunked view if the note is huge).
- **ListNotesByTagTool** — returns notes matching a tag (or tag hierarchy).
- **GetBacklinksTool** — given a note path, returns notes that wikilink to it.
- **ListRecentNotesTool** — notes created or modified in the last N days. Useful for "what have I been working on."
- **ReadDailyNoteTool** — reads (or creates, with proper template) the daily note for a given date.

The web/URL tools are also useful, since the agent will often answer questions that benefit from external context:

- **WebSearchTool** — query Brave Search API or Exa. User provides API key in settings.
- **URLFetchTool** — fetch a URL, extract main content, return as markdown.

### Step 6: Note creation tool (with do-no-harm rules)

- **CreateNoteTool** — args: title, body, folder (must be authorized), tags. Writes a new `.md` file with `source: obelisk` in frontmatter. Atomic write (temp file + rename). Returns the new path.

### Tool design principles

A 3B model is a worse function-caller than a frontier model. The tools have to compensate:

- **Clear, single-purpose tools.** "search_vault" is good; "search_or_navigate_or_summarize" is bad.
- **6–10 tools maximum at any time.** More than that and selection accuracy drops sharply.
- **Descriptive names and concise descriptions.** The model picks tools based on the description.
- **Tight parameter schemas.** Required params obviously named. Use enums where possible.
- **Forgiving execution.** If a parameter is slightly wrong, try to recover rather than fail.

### Resources

- `swift-markdown`: `https://github.com/apple/swift-markdown`
- Yams: `https://github.com/jpsim/Yams`
- GRDB.swift: `https://github.com/groue/GRDB.swift`
- Document picker / security-scoped bookmarks: `https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller`
- Smart Connections README (study how they handle the same problems): `https://github.com/brianpetro/obsidian-smart-connections`

### Pitfalls

- **Security-scoped bookmarks expiring.** They can become stale (especially after iCloud changes). Detect and re-prompt the user gracefully.
- **Frontmatter round-tripping.** YAML parse + serialize is not lossless by default. Test with frontmatter that includes comments, nested structures, and unusual fields.
- **Wikilink resolution edge cases.** Notes with the same name in different folders, links to nonexistent files, links with relative paths. Don't crash; resolve heuristically and log unresolvable links.
- **Templater detection.** If the user has Templater installed and uses it for daily notes, your "create daily note" tool will produce notes that don't match their template. Warn clearly.
- **File modification timing.** iOS may report stale modification dates over iCloud. Use content hashes for change detection, not just `modificationDate`.

### Deliverable

User picks their vault. Obelisk scans it, indexes notes/links/tags. The agent can answer "what notes do I have about X," "show me notes tagged #project," "what links to this note," "what's in my daily note from yesterday." Web search works. New notes can be created safely in an `obelisk/` subfolder.

---

## Phase C: Semantic search via embeddings (3–4 weeks)

Phase B gave the agent vault access and text-based search. This phase adds the magic: ask a question, get back relevant notes that don't share keywords with the query.

### Goal

Obelisk can semantically search the vault. "What have I written about long-term thinking" returns notes that talk about patience, planning, deferred gratification — without those exact words appearing in the query.

### Embedding model

Start with `NLContextualEmbedding` from Apple's NaturalLanguage framework:

- Built into iOS, no model download, no MLX plumbing
- Reasonable quality for English
- Fast on Apple Silicon

If quality feels insufficient later, swap to an MLX embedding model (`bge-small-en`, `nomic-embed-text` — both available in mlx-community). The interface stays the same; just the embedding function changes.

### Indexing flow

Extend the vault index schema with an `embeddings` table: `(note_path, chunk_index, chunk_start, chunk_end, embedding_blob, content_hash)`.

On vault connection (Phase B already detected it):
1. List all notes; for each, check if content hash differs from indexed hash
2. For changed/new notes, chunk via MarkdownChunker (from Phase B)
3. Embed each chunk, store the result
4. Show progress to the user — embedding a 5,000-note vault takes minutes, not seconds, on iPhone

Incremental updates happen on app foreground: re-check hashes, re-embed only what changed.

### Retrieval

At query time:
1. Embed the query
2. Compute cosine similarity against all chunks in SQLite (use sqlite-vec if you want; for v1 a plain `SELECT` + computation in Swift is fine until it isn't)
3. Return top K (start with K=10)
4. Optionally: re-rank top K by passing them through the LLM with a "which of these are actually relevant" prompt, take top 3-5

### New tools

Replace the basic `SearchVaultTool` with a smarter one:

- **SemanticSearchVaultTool** — args: query, optional filters (tag, folder, date range). Returns top-K chunks with their parent note paths and snippets.

Keep the existing text-based search as a separate tool. The agent can use whichever is appropriate (or both).

### What this enables, product-wise

This is the phase where Obelisk starts to feel intelligent. New flows that now work well:
- "What ideas have I had related to this one" → semantic search finds adjacent thinking
- "Summarize what I know about X" → retrieval pulls relevant notes, model synthesizes
- "Find duplicate or near-duplicate notes" → cluster embeddings, surface clusters

### Resources

- `https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding`
- Smart Connections embedding strategy (study how they chunk and what models they use)
- sqlite-vec extension: `https://github.com/asg017/sqlite-vec` — useful when the index grows large

### Pitfalls

- **Initial scan blocking the UI.** Run embedding work off the main thread, show progress, allow the user to keep using the chat interface (degraded — only text search until embeddings finish).
- **Chunk boundaries cutting key information.** AST-aware chunking from `swift-markdown` helps — split at heading boundaries when possible.
- **Embedding quality for niche domains.** Generic embedding models underperform on specialized vocabulary. If a user has a vault full of legal terms or biotech jargon, semantic search will feel mediocre. Defer until you see it as a real problem.
- **Background eviction during long embedding runs.** iOS may kill the app. Track progress and resume from where you left off on next launch.

### Deliverable

User connects vault. Obelisk shows embedding progress. Once complete, the agent can answer questions that require semantic retrieval. "What have I written about X" works even when X never appears verbatim in the notes.

---

## Phase D: Voice input — live dictation (2–3 weeks)

The model and tool layer don't change. You're just adding another way to populate the input field. Voice is a **dictation convenience**, not a separate "voice mode" — it's a faster keyboard, not a walkie-talkie. See [ui-spec.md §4.4](./ui-spec.md) for the exact interaction.

### Goal

A mic button in the chat input. Tap to start dictation: WhisperKit streams partial transcripts live into the input text field. Tap again to stop. The user reviews/edits the transcribed text and taps send manually. **No auto-send, no spoken response, no TTS.**

### Components

- **AVAudioEngine** for capture. Sample rate matched to the Whisper model (16kHz).
- **WhisperKit** for streaming transcription. Use its partial-result / streaming API so the text field updates as the user speaks, not after they stop. Pick the right CoreML-optimized Whisper variant for the device — start with `openai_whisper-base.en` for low latency; upgrade to `small` or `large-v3-turbo` if accuracy on multi-sentence dictation becomes the bottleneck.
- **No VAD-driven endpointing.** Stopping dictation is a user gesture (tap the mic again or the stop square). Energy-based silence cutoff is explicitly not used — we don't want the field to "close" mid-thought.
- **No TTS / AVSpeechSynthesizer.** Replies are always text. Voice output is a non-goal for v1.

### Resources

- WhisperKit: `https://github.com/argmaxinc/WhisperKit` — has an iOS sample app and a streaming transcription example
- AVAudioEngine docs: `https://developer.apple.com/documentation/avfaudio/avaudioengine`

### Pitfalls

- **Streaming vs. one-shot transcription.** Make sure you're using the streaming API and updating the input field incrementally. A one-shot transcribe-on-stop flow is the wrong UX even if it's simpler to wire up — the live-updating field is the entire point.
- **Audio session conflicts.** Background music, other apps, AirPods. Configure `AVAudioSession.Category.playAndRecord` (or `.record` since we're not playing audio) carefully.
- **Permission prompts.** Microphone permission needs Info.plist string and runtime request.
- **Re-entrancy and editing.** The user can tap into the text field and edit while dictation is paused. Make sure stopping dictation leaves cleanly committed text, not a partial hypothesis that the next dictation session overwrites.

### Deliverable

Tap mic → speak → words appear in the input field as you talk → tap again to stop → edit if needed → tap send. Latency between speech and first visible token is short enough to feel responsive (~500ms on iPhone 16 Pro).

---

## Phase E: Action Button, capture, and Shortcuts integration (3–4 weeks)

Now Obelisk can be activated without opening the app, content can be captured into the vault from anywhere in iOS, and Obelisk itself can drive other apps via user-configured Shortcuts. See [ui-spec.md §6 and §7](./ui-spec.md) for the exact flows.

### Goal

Three integrations: (1) the Action Button opens Obelisk in a new chat with dictation already active, (2) Share Sheet + an `AppIntent` let the user capture content directly into `obelisk/inbox/` without opening the app, and (3) Obelisk can run user-defined Shortcuts as tools.

### Direction 1: Obelisk as a Shortcut target — Action Button flow

Define an `AppIntent` like `AskObeliskIntent` with a `query: String` parameter and a `perform` method that runs the agent and returns the result. Register it via an `AppShortcutsProvider`.

This automatically gets you:
- The intent shows up in the Shortcuts app
- Siri can invoke it ("Hey Siri, ask Obelisk what's on my calendar")
- The Action Button can be bound to it (user does this in Settings → Action Button → Shortcut)
- Spotlight search surfaces it

Add an Action Button intent variant whose `perform` method:

1. **Opens the app directly into a brand-new conversation** (not the most recent one — never edit an existing thread by accident).
2. **Starts dictation immediately** — the mic is already in the pulsing-red recording state when the chat appears, and WhisperKit streams partial transcripts straight into the input field per Phase D.
3. **Does not auto-send.** The user reviews the transcription and taps send. Action Button presses are easy to fat-finger; we never want a half-thought silently fired at the model.

So the full Action Button flow is: press Action Button → Obelisk opens in a new chat with mic live → speak → tap to stop dictation → review → tap send.

### Direction 2: Capture flows (Share Sheet + App Intent)

Capture is the path for getting content *into* the vault from outside Obelisk. **There is no in-chat capture button** — capture is a system-level entry point, not a chat affordance.

Two complementary surfaces, both writing to `obelisk/inbox/` with `source: obelisk` frontmatter and a timestamp, both with **no model invocation and no chat history** (pure write operations):

1. **Share Sheet extension.** The user taps Share in any app, picks Obelisk, and the shared payload (URL, selected text, image) becomes a new markdown note in the inbox. A small confirmation toast appears in the source app.
2. **`CaptureToObeliskIntent` App Intent.** Takes a `text: String` parameter and writes the same way. Available to Shortcuts, Siri ("Capture to Obelisk: ..."), Spotlight, and as an alternate Action Button binding for users who prefer capture over chat.

The user later opens Obelisk and asks "what's in my inbox?" to triage. Triage UX itself is just a normal chat interaction — no special inbox screen.

### Direction 3: Obelisk triggers user Shortcuts

Add a `RunShortcutTool` that takes a shortcut name and optional input. This is the workaround for the "Obelisk can't directly call other apps' intents" limitation. The user pre-builds Shortcuts for the things they want Obelisk to be able to do; Obelisk picks the right one and runs it.

**Use `x-callback-url`, not the bare `shortcuts://` scheme.** The bare scheme leaves Obelisk and never returns a result; the agent loop is dead. `x-callback-url` gives a structured way to round-trip the result back into the agent.

```
shortcuts://x-callback-url/run-shortcut?
    name=<name>
    &input=<input>
    &x-success=obelisk://shortcut-callback?token=<one-time-token>
    &x-error=obelisk://shortcut-callback?token=<token>&error=1
    &x-cancel=obelisk://shortcut-callback?token=<token>&cancelled=1
```

Flow:
1. Obelisk registers an `obelisk://` URL scheme.
2. `RunShortcutTool` generates a one-time correlation token, suspends the agent in an awaitable continuation keyed on that token, and opens the `x-callback-url` URL.
3. Shortcuts executes the user's shortcut, then opens the `x-success` / `x-error` / `x-cancel` callback URL.
4. Obelisk's URL handler looks up the continuation by token, resumes the agent with the result (or "user cancelled" / "shortcut errored"), and the agent continues generating.
5. If no callback arrives within a timeout (e.g., 60s), resume with "the shortcut did not return a result in time."

Bonus tool: `ListShortcutsTool` that returns the user's installed shortcut names so the model knows what's available. (Note: there's no public API to enumerate installed shortcuts; the user maintains an opt-in list in Settings of shortcuts Obelisk is allowed to invoke.)

**If this is too much work for v1, defer the entire `RunShortcutTool`.** Directions 1 and 2 (Action Button + capture flows via App Intents and the Share Sheet) are the higher-value half — they cover the headline interactions of this phase.

### App Intent assistant schemas (worth doing)

Since Obelisk creates and queries notes, the `.journal` assistant schema is a strong fit. Conforming an `ObeliskNoteEntity` to `@AssistantEntity(schema: .journal.entry)` and the create/search intents to the corresponding `.journal.create` / `.journal.search` schemas means Siri's natural-language understanding routes requests like "show me my Obelisk note about X" or "create an Obelisk note that says ..." correctly. This is genuine integration polish that pays off because users get to use natural language without remembering exact App Shortcut phrases.

### Resources

- AppIntents framework: `https://developer.apple.com/documentation/appintents`
- WWDC 2025 session 244 "Get to know App Intents"
- WWDC 2024 session 10210 "Bring your app's core features to users with App Intents"
- Assistant schemas: `https://developer.apple.com/documentation/appintents/app-intent-domains`

### Pitfalls

- **Intent must be in same target as `AppShortcutsProvider`.** Common gotcha when refactoring code into packages.
- **The intent code can't easily share runtime state with the app.** Plan for the intent to launch the app or pass data via shared storage (App Group).
- **Action Button binding is user-driven.** You can't bind it programmatically; you can only document how the user does it.
- **Share Sheet extension runs in its own process.** It cannot reach into the main app's runtime; route writes through the same vault-access layer via an App Group container and security-scoped bookmarks shared from the main app.
- **Action Button must land in a new conversation with dictation already live.** Resist the urge to "resume last chat" — that's how Action Button presses end up appending to existing threads.

### Deliverable

User binds Action Button to Obelisk. Presses Action Button → Obelisk opens in a new chat with the mic already recording. Speaks → reviews transcription → taps send → answer. Separately: the Share Sheet and a `CaptureToObeliskIntent` can drop content into `obelisk/inbox/` without opening the app. Separately again: Obelisk can run a Shortcut the user has built ("post to Mastodon," "control HomeKit scene," etc.).

---

## Phase F: Polish and TestFlight (4–6 weeks)

### Goal

Something good enough to give to friends without embarrassment.

### Work items

- **Settings screen, per [ui-spec.md §3.4](./ui-spec.md).** Single scrollable list grouped into:
  - **Vault** — path, change vault, indexing status, re-index now.
  - **Model** — read-only "Apple Foundation Models (on-device)" with availability state. No picker, no download, no switching (a real picker is deferred until a second `LLMRunner` exists).
  - **Tools** — web search toggle + search API key, authorized Shortcuts list.
  - **Authorized folders** — folders Obelisk is allowed to write to (default: `obelisk/`); add via document picker.
  - **Voice** — dictation on/off, Whisper model picker (`base.en` default).
  - **About** — version, privacy, licenses.
- **Memory pressure handling.** Respond to `didReceiveMemoryWarning` by tearing down the active `LanguageModelSession`. Re-create on next use.
- **Onboarding flow, per [ui-spec.md §3.5](./ui-spec.md).** Three swipeable screens: Welcome (with the "what it does NOT do" list), Vault picker (with iCloud download warning), Apple Intelligence availability check (deep-link to Settings if disabled, hard-block if device unsupported).
- **Error states.** Network failures, tool errors, model load failures — all need user-visible handling via the status pill system and inline error rows from [ui-spec.md §4.8 / §5](./ui-spec.md).
- **Conversation management.** Rename, delete, export to markdown, search across conversations (drawer per [ui-spec.md §3.2](./ui-spec.md)).
- **Status pill component.** Implement the green/amber/red top-of-screen pill from [ui-spec.md §5](./ui-spec.md).
- **App icon and launch screen.** Direction per [ui-spec.md §8](./ui-spec.md): a stylized geometric mark, *not* a literal obelisk illustration. Complementary to Obsidian's `◇` shape language — single recognizable geometric primitive, flat, monochrome with purple accent on a dark background, instantly readable at 60×60px. Explicit non-goals: realism, gradients, drop shadows, photographic textures, AI clichés (no robot / sparkles / chat bubble).
- **TestFlight setup.** Apple Developer account, App Store Connect, internal testers group, build upload via Xcode.

### Pitfalls

- **Privacy manifest.** iOS 17+ requires `PrivacyInfo.xcprivacy` declaring data usage. Local-only is the easy case but you still need the file.
- **TestFlight review.** Internal builds are basically instant; external testing requires a brief review. Don't claim "no data collection" if your search tool sends queries to Brave.
- **Crash reports.** Set up Xcode Organizer to receive them. You will get crashes you didn't see in development.

### Deliverable

A TestFlight build with onboarding, settings, error handling, and at least one friend successfully using it for a week.

---

## Deferred (out of v1)

- **MLX backend (`MLXRunner`).** A second `LLMRunner` implementation using MLX-Swift for users who want a different/larger model, fewer content guardrails, or who are on devices without Apple Intelligence. The v1 protocol is designed so this can be added without touching `AgentService` or the tools — but the implementation itself is deferred. When built: clone `mlx-swift-examples`, study LLMEval/LLMChat, strip to the smallest model load + generate + tool-call loop.
- **Model picker UI.** Settings screen to switch between `LLMRunner` backends, download/manage MLX models, etc. Only meaningful once a second runner exists.
- **Fine-tuning.** LoRA via `mlx-lm` in Python, ship the adapter in Swift. Plausible v2 work, no need now.
- **Mac version.** The same code mostly ports. Defer until iPhone version is solid.
- **Multimodal vision.** `mlx-vlm` exists for vision-language models on Apple Silicon, but it's earlier-stage. Defer.
- **Long-running background research.** "Go research this for an hour" — interesting but adds complexity around background execution that iOS makes hard.
- **Sharing or syncing across users.** Single-user, single-device for v1.

---

## Glossary

### AI / MLX

- **Foundation Models framework** — Apple's iOS 26+ framework that gives third-party apps direct access to the ~3B-parameter on-device model at the core of Apple Intelligence. Provides streaming generation, constrained tool calling, guided generation (`@Generable`), and LoRA adapter loading. Free to use, no per-request cost.
- **Apple Foundation Model (AFM)** — the ~3B-parameter, 2-bit QAT on-device model exposed via the Foundation Models framework. Competitive with Qwen 2.5/3 3–4B and Gemma 3 4B at this size class. Not designed as a general-knowledge chatbot.
- **`LanguageModelSession`** — the primary Foundation Models entry point. Wraps a conversation with the on-device model; handles streaming, tools, and guided generation.
- **`@Generable`** — Swift macro that turns a struct into a schema the on-device model can fill in. The framework constrains decoding so the output is always valid against the schema — no malformed-JSON parsing.
- **Guided generation** — the broader pattern of constraining the model's decoder to emit only outputs that match a schema. Foundation Models does this natively; eliminates a whole class of small-model tool-calling failure.
- **MLX** — Apple's array/ML framework, optimized for unified memory on Apple Silicon. Think PyTorch for M-series.
- **MLX-Swift** — Swift bindings for MLX. First-class peer of the Python version for inference. Obelisk uses it as an opt-in alternate backend.
- **Quantization** — compressing model weights from 16-bit floats to 4-bit integers (Q4) or 2-bit (Apple's QAT) or similar. Trades a small quality hit for ~4–8x size reduction.
- **QAT (quantization-aware training)** — training the model with the quantization noise present in the forward pass, so the final quantized weights perform better than naive post-training quantization. Apple's on-device model is QAT-trained at 2-bit.
- **Chat template** — the specific string format a model expects for system/user/assistant turns. Lives in the model's tokenizer config. Relevant when running MLX models; Foundation Models hides this.
- **KV cache** — key/value attention cache built during generation. Speeds up subsequent tokens by avoiding recomputation. Memory-resident, grows with sequence length.
- **Tool calling** — the pattern where a model emits a structured request for the host program to run a function, then resumes generation with the result.
- **Embedding** — a fixed-length vector representation of text. Semantically similar text has geometrically close vectors.
- **RAG (retrieval-augmented generation)** — the pattern of retrieving relevant context (via embeddings or other search) and feeding it to the model before it generates an answer.

### iOS

- **App Intents** — Apple's framework for exposing your app's actions to Siri, Spotlight, Shortcuts, the Action Button, and widgets.
- **Assistant Schemas** — predefined intent shapes (journal, photos, mail, etc.) that Apple Intelligence models are trained to recognize. Conform to them for better Siri integration.
- **WhisperKit** — Swift framework for running Whisper speech-to-text on iOS with CoreML acceleration.
- **VAD** — voice activity detection. Knowing when speech starts and stops in an audio stream.
- **Security-scoped bookmark** — a persisted reference to a file or folder the user picked, allowing your app to re-access it across launches without re-prompting.

### Obsidian

- **Vault** — a folder of markdown files that Obsidian treats as a unit. Has a `.obsidian/` subfolder for config.
- **Frontmatter** — YAML metadata block at the top of a markdown file. Used for tags, aliases, custom properties, dates.
- **Wikilink** — Obsidian's internal link syntax: `[[Note Name]]`, `[[Note Name|Display]]`, `[[Note#Heading]]`, `[[Note^block-id]]`.
- **Daily Note** — a markdown file per day, created by the core Daily Notes plugin. Folder, naming, and template configurable.
- **Templater** — popular community plugin for JavaScript-based templates. Templates run inside Obsidian's environment; Obelisk can't execute them.
- **Dataview** — community plugin that adds a query language for treating notes as a database. Out of scope for Obelisk.
- **Bases** — Obsidian's newer built-in database-like feature using frontmatter. Out of scope for v1.
- **Obsidian Sync** — Obsidian's paid sync service. To Obelisk it's just another sync mechanism for the vault folder.

---

## Reference materials

### Apple WWDC sessions (transcripts on developer.apple.com)

- WWDC 2025: sessions 259, 286, 298, 301, 315 — local model / MLX / Foundation Models coverage
- WWDC 2025 session 244 — "Get to know App Intents"
- WWDC 2024 session 10133 — "Bring your app to Siri"
- WWDC 2024 session 10210 — "Bring your app's core features to users with App Intents"

### Documentation

- MLX framework: `https://mlx-framework.org/`
- MLX-Swift API: `https://swiftpackageindex.com/ml-explore/mlx-swift/main/documentation/mlx`
- Foundation Models: `https://developer.apple.com/documentation/FoundationModels/generating-content-and-performing-tasks-with-foundation-models`
- App Intents: `https://developer.apple.com/documentation/appintents`
- App Intent domains: `https://developer.apple.com/documentation/appintents/app-intent-domains`
- Document picker: `https://developer.apple.com/documentation/uikit/uidocumentpickerviewcontroller`
- NaturalLanguage embeddings: `https://developer.apple.com/documentation/naturallanguage/nlcontextualembedding`
- Obsidian help (file format, vault structure): `https://help.obsidian.md/`

### Code repositories

- `https://github.com/ml-explore/mlx-swift`
- `https://github.com/ml-explore/mlx-swift-examples`
- `https://github.com/huggingface/swift-transformers`
- `https://github.com/argmaxinc/WhisperKit`
- `https://github.com/apple/swift-markdown`
- `https://github.com/jpsim/Yams`
- `https://github.com/groue/GRDB.swift`

### Obsidian plugin code worth studying

The big plugins doing similar things on Mac. Read their READMEs and source for design ideas; you cannot reuse the code (JS/TS in a different environment), but the UX patterns are valuable.

- Smart Connections: `https://github.com/brianpetro/obsidian-smart-connections` — the dominant local-AI Obsidian plugin. Study their embedding flow, settings, "related notes" UX.
- Copilot for Obsidian: `https://github.com/logancyang/obsidian-copilot` — chat-focused. Study their conversation UX, "relevant notes" context injection.
- Obsidian Local GPT: similar Ollama-based plugin, simpler scope.

### Models (Hugging Face mlx-community)

- `mlx-community/gemma-3-2b-it-4bit` — default starter, smaller and faster
- `mlx-community/Qwen2.5-3B-Instruct-4bit` — slightly stronger reasoner
- Browse `https://huggingface.co/mlx-community` for more

### Other reading

- Rudrank's MLX-Swift tool-use post: `https://rudrank.com/exploring-mlx-swift-getting-started-with-tool-use`
- Adrien Grondin's *Locally AI* — reference iOS app showing what's achievable, worth installing and studying

---

## How to use this document

Each phase is independent enough that you can pick it up cold. When starting a phase:

1. Re-read its section here.
2. Open the linked resources.
3. Write a short design doc (one page) for the specific slice you're tackling.
4. Hand the design doc to Claude Code along with relevant code context.
5. Review what it produces, run it on a real device, iterate.

When something doesn't work, the failure is almost always in one of: chat template formatting, tool-call parsing, permissions/authorization, or memory pressure. Start there before going deeper.

Update this document as you learn things. The deferred list will shrink and the glossary will grow.
