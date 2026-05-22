# Phase B — Implementation Overview

Connect Obelisk to an Obsidian vault, parse its structure, and give the agent a working set of vault-aware tools. **No embeddings, no semantic search, no voice, no Action Button.** Those are later phases.

See [roadmap.md §"Phase B: Vault connection and Obsidian primitives"](./roadmap.md) for the strategic framing and [ui-spec.md](./ui-spec.md) for the visual / interaction spec.

---

## 1. Goals

End-of-phase, on a physical iPhone 15 Pro / 16 Pro running iOS 26 (and in the iOS Simulator via the sample-vault scaffolding from §3):

1. User picks a folder via the document picker → Obelisk persists access via a security-scoped bookmark and treats it as the active vault.
2. The vault is scanned on first connect. A SQLite index (notes / links / tags) is built in the app sandbox. Subsequent foregrounding triggers an incremental re-scan via content hashes.
3. The agent can answer:
   - "Search my vault for `<query>`."
   - "Read `<note name>`."
   - "List notes tagged `#project/obelisk`."
   - "What links to `<note>`?"
   - "What did I touch in the last 3 days?"
   - "What's in my daily note?" (creates one if absent, in the configured daily-notes folder)
4. The agent can **create** notes safely inside the authorized `obelisk/` subfolder, with `source: obelisk` in YAML frontmatter and an atomic write.
5. Assistant replies that cite notes render a Sources card; `[[Wikilinks]]` in prose render as tappable accent-purple links that open Obsidian via `obsidian://open?vault=…&file=…`.
6. The `ScratchpadTool` from Phase A is removed.

---

## 2. Scope

### In scope

- `VaultAccessService` (document picker, security-scoped bookmark persistence, `NSFileCoordinator`-wrapped reads).
- Parsing primitives: `FrontmatterParser` (Yams), `WikilinkParser`, `TagExtractor`, `MarkdownChunker` (swift-markdown — the chunker is built now but only used by Phase C).
- `VaultIndex` built on GRDB: `notes`, `links`, `tags` tables. `embeddings` table reserved for Phase C.
- `VaultScanner` — walks the vault, populates the index, supports full and incremental scans.
- Six read tools: `SearchVaultTool`, `ReadNoteTool`, `ListNotesByTagTool`, `GetBacklinksTool`, `ListRecentNotesTool`, `ReadDailyNoteTool`.
- One write tool: `CreateNoteTool` with the "do no harm" rules from [roadmap.md §"The 'do no harm' rules for vault writes"](./roadmap.md).
- UI: Sources card under cited assistant turns, wikilink rendering in prose (both per [ui-spec.md §4.6 / §4.7](./ui-spec.md)), and a minimal Vault section in Settings (path, re-pick, indexing status, last-indexed timestamp).
- Onboarding gate: app refuses to leave the empty state until a vault is picked (or "Use sample vault" is tapped in dev builds).
- Sample-vault scaffolding (§3) so simulator dev is unblocked without Obsidian.

### Out of scope (deferred to later phases)

- **Semantic search / embeddings.** Phase C.
- **Status pill component** ([ui-spec.md §5](./ui-spec.md)). Inline errors continue to carry app-level state through Phase B. Status pill lands in Phase F.
- **Web search / URL fetch tools.** Useful and listed in the roadmap, but they need API-key UI; defer until the Settings screen lands in Phase F. If we want them earlier, they're cheap to add as a stretch step.
- **iCloud Drive sharp edges** beyond placeholder detection and `NSFileCoordinator` wrapping. Force-download flows, conflict UI, and advanced bookmark-staleness recovery (per [roadmap.md §"Step 1.5"](./roadmap.md)) are partial: we detect and refuse rather than fix in v1.
- **Voice, Action Button, capture, Share Sheet.** Phases D / E.
- **Settings screen** beyond the Vault section. Phase F.
- **Templater compatibility.** We only *warn* if Templater is installed (no template execution).

### Stretch (only if Phase B finishes early)

- `WebSearchTool` (Brave / Exa) + `URLFetchTool`.
- iCloud Drive force-download flow with progress.
- "Authorized folders" UI so users can grant write access beyond `obelisk/`.

---

## 3. Dev environment: getting a vault into the simulator

This is the single biggest blocker for Phase B iteration, so it gets its own section.

### Why we can't use Obsidian directly in the Simulator

Obsidian ships only via the App Store. The iOS Simulator can't install App Store apps — `simctl install` only accepts locally-built `.app` bundles. So our dev-loop strategy is:

1. **Default dev path: bundle a sample vault into the app.** A `Resources/SampleVault/` directory ships in the app bundle. On first dev launch with no vault selected, Obelisk copies it into `Documents/SampleVault/` and registers that as the active vault. This works identically in Simulator and on device, requires no Obsidian, and gives us a stable corpus to write tests against. Gated behind `#if DEBUG` so it never reaches TestFlight builds.
2. **"Real-ish" dev path: drag a folder into the Simulator.** Make a vault folder on macOS (`.obsidian/` + a few `.md` files with frontmatter / wikilinks / tags), drag it onto the Simulator window — it lands in Files → On My iPhone. The document picker can pick it. Useful for testing the picker + bookmark flow against arbitrary content.
3. **Real device path: Obsidian + iCloud sync.** Install Obsidian on a physical iPhone, create or sync a vault, then in Obelisk pick that vault folder via the document picker. This is the actual user flow.

The bundled `SampleVault/` should contain ~15–25 notes covering the cases the parsers and tools have to handle:

- A note with rich YAML frontmatter (tags array, custom keys, dates).
- A note with no frontmatter.
- Notes that wikilink to each other (`[[A]] → [[B]] → [[A]]`).
- Notes with display labels (`[[Long Note Name|Display]]`), heading refs (`[[A#Heading]]`), and block refs (`[[A^block]]`).
- Notes with hierarchical inline tags (`#project/obelisk/phase-b`) and frontmatter tags.
- A note inside a `Daily Notes/` subfolder named `2026-05-19.md` so daily-notes tooling has something to read.
- An `obelisk/` subfolder (authorized write target).
- A minimal `.obsidian/` with `app.json`, `daily-notes.json`, `core-plugins.json`.

A small `make seed-vault` Makefile target can rebuild `Documents/SampleVault/` from the bundled copy when the sample changes, so we can iterate on the corpus without reinstalling the app.

### Wire-up

- New SwiftUI gate in `ChatView`: if `VaultAccessService.activeVault == nil`, show a "Pick your vault" screen with two buttons — "Choose vault folder" (real flow) and, in `#if DEBUG` builds, "Use sample vault" (dev flow).
- `SampleVaultProvider` (DEBUG only) handles copy-into-Documents + bookmark synthesis. It produces the same `VaultHandle` shape as the picker flow so the rest of the code can't tell the difference.

---

## 4. Architecture

### 4.1 Module diagram

```diagram
╭─────────────────────────────────────────────────────╮
│  ChatView (SwiftUI)                                 │
│   · existing chat shell                             │
│   · adds: VaultGateView, SourcesCard, WikilinkText  │
╰─────────────┬───────────────────────────────────────╯
              │
              ▼
╭─────────────────────────────────────────────────────╮
│  ConversationManager / AgentService  (unchanged)    │
│   Phase B only changes the *tools* exposed.         │
╰─────────────┬───────────────────────────────────────╯
              │
              ▼  (descriptors)
╭─────────────────────────────────────────────────────╮
│  ToolDispatcher                                     │
│   · existing: datetime, calculator                  │
│   · new:                                            │
│     SearchVaultTool, ReadNoteTool,                  │
│     ListNotesByTagTool, GetBacklinksTool,           │
│     ListRecentNotesTool, ReadDailyNoteTool,         │
│     CreateNoteTool                                  │
│   · removed: ScratchpadTool                         │
╰─────────────┬───────────────────────────────────────╯
              │
              ▼
╭─────────────────────────────────────────────────────╮
│  Vault layer (new)                                  │
│                                                     │
│   VaultAccessService     ◀── document picker /      │
│    · activeVault: VaultHandle?                      │
│    · pick / forget / withReadAccess { … }           │
│    · bookmark in UserDefaults                       │
│                                                     │
│   VaultScanner                                      │
│    · scan(handle) → writes into VaultIndex          │
│    · incremental(handle) → diff by SHA-256          │
│                                                     │
│   VaultIndex (GRDB)                                 │
│    · notes / links / tags tables                    │
│    · queries used by the read tools                 │
│                                                     │
│   ObsidianConfig                                    │
│    · parses .obsidian/{app,daily-notes}.json        │
│                                                     │
│   Parsers: FrontmatterParser, WikilinkParser,       │
│            TagExtractor, MarkdownChunker            │
│                                                     │
│   VaultWriter                                       │
│    · enforces "do no harm" (deny list,              │
│      source: obelisk frontmatter, atomic write)     │
╰─────────────────────────────────────────────────────╯
```

### 4.2 New type seams

- **`VaultHandle`** — opaque value type wrapping a security-scoped URL + a stable vault identifier (used as a foreign key in the index). All file I/O goes through `VaultAccessService.withReadAccess(handle:) { url in … }` so the start/stop scope and `NSFileCoordinator` wrapping happen in exactly one place.
- **`VaultNote`** — domain projection used by the index and tools: `path`, `title`, `body`, `frontmatter: [String: JSONValue]`, `tags: [String]`, `outboundLinks: [WikilinkRef]`, `contentHash`, `modifiedAt`.
- **`Citation`** — `(notePath, snippet, score?)` returned by read tools and bubbled to the UI as `ToolResult.output`, which the SourcesCard consumes.

### 4.3 Discipline rules carried forward from Phase A

- The `LLMRunner` seam **does not change** in Phase B. New tools conform to the same `Tool` protocol from Phase A and flow through `JSONArgsToolAdapter` unchanged.
- New tool arg schemas must stay inside the existing `JSONSchema` subset (string, number, integer, boolean, array, object, plus string enums). Add nothing to the seam.
- Vault file I/O **never** appears in `AppleFoundationRunner` or `AgentService`. It lives entirely behind `VaultAccessService` / `VaultScanner` / tools.

### 4.4 Suggested file layout

```
Obelisk/
  Domain/
    Vault/
      VaultHandle.swift
      VaultNote.swift
      Wikilink.swift
      Citation.swift
  Services/
    Vault/
      VaultAccessService.swift
      VaultScanner.swift
      VaultIndex.swift              // GRDB store + queries
      VaultWriter.swift             // do-no-harm enforcement
      ObsidianConfig.swift
      SampleVaultProvider.swift     // #if DEBUG
      Parsing/
        FrontmatterParser.swift
        WikilinkParser.swift
        TagExtractor.swift
        MarkdownChunker.swift
    Tools/
      SearchVaultTool.swift
      ReadNoteTool.swift
      ListNotesByTagTool.swift
      GetBacklinksTool.swift
      ListRecentNotesTool.swift
      ReadDailyNoteTool.swift
      CreateNoteTool.swift
      (ScratchpadTool.swift — deleted)
  Persistence/
    VaultIndexSchema.swift          // GRDB migrations
  UI/
    VaultGateView.swift             // pre-vault onboarding screen
    Components/
      SourcesCard.swift
      WikilinkText.swift
  Resources/
    SampleVault/                    // bundled dev corpus
      .obsidian/{app,daily-notes,core-plugins}.json
      obelisk/.gitkeep              // authorized write target
      Daily Notes/2026-05-19.md
      *.md                           // 15–25 sample notes
```

---

## 5. UI subset implemented in Phase B

Pull from [ui-spec.md](./ui-spec.md), but only these new surfaces (everything Phase A added stays):

- **§3.5 Onboarding step 2 — Pick your vault.** Implemented as a pre-chat gate: when no vault is bound, render `VaultGateView` instead of the empty state. Includes a placeholder iCloud-download warning (real force-download flow deferred).
- **§3.4 Settings → Vault section.** A minimal sheet (not the full Settings screen). Lists vault path, "Change vault…", indexing status (`up to date` / `scanning… N of M` / `error: …`), and "Re-index now".
- **§3.1 Primary chat screen — citation cards.** Sources card renders at the end of any assistant turn whose tool calls returned citations. Up to 3 rows expanded by default; "+ N more" expands the rest. Tap a row → `obsidian://open?vault=…&file=…` deep link.
- **§4.7 Wikilinks in assistant replies.** When the model emits `[[Note]]`, `[[Note|Display]]`, `[[Note#Heading]]`, or `[[Note^block]]` in prose, render per the typography rules — accent purple, semibold, low-opacity brackets, deep-link on tap.
- **§4.5 Tool calls — vault glyphs.** Extend the inline tool-call row's glyph map: `🔍 search vault`, `📄 reading [[Note]]`, `🏷 tag list`, `🔗 backlinks`, `📅 daily note`, `✍ created [[Note]]`.

Still **not** in Phase B: settings screen beyond the vault section, voice mic interaction, capture, Action Button, status pill component (we keep the inline error tiers from Phase A).

---

## 6. Data model

### 6.1 GRDB schema (migration v1)

```sql
CREATE TABLE notes (
    path           TEXT PRIMARY KEY,        -- vault-relative
    title          TEXT NOT NULL,
    body           TEXT NOT NULL,
    frontmatter    TEXT NOT NULL,           -- JSON
    content_hash   TEXT NOT NULL,           -- SHA-256, 64 hex chars
    modified_at    DATETIME NOT NULL,
    indexed_at     DATETIME NOT NULL
);
CREATE INDEX idx_notes_modified ON notes(modified_at);

CREATE TABLE links (
    source_path    TEXT NOT NULL,
    target_path    TEXT,                    -- resolved; NULL if unresolved
    target_raw     TEXT NOT NULL,           -- as written: "Foo#Bar"
    target_heading TEXT,
    target_block   TEXT,
    display_label  TEXT,
    FOREIGN KEY (source_path) REFERENCES notes(path) ON DELETE CASCADE
);
CREATE INDEX idx_links_source ON links(source_path);
CREATE INDEX idx_links_target ON links(target_path);

CREATE TABLE tags (
    path           TEXT NOT NULL,
    tag            TEXT NOT NULL,           -- normalized, lowercase, no '#'
    source         TEXT NOT NULL,           -- "frontmatter" | "inline"
    FOREIGN KEY (path) REFERENCES notes(path) ON DELETE CASCADE
);
CREATE INDEX idx_tags_tag ON tags(tag);
CREATE INDEX idx_tags_path ON tags(path);

-- Reserved for Phase C; defined now to keep migrations linear.
CREATE TABLE embeddings (
    path           TEXT NOT NULL,
    chunk_index    INTEGER NOT NULL,
    chunk_start    INTEGER NOT NULL,
    chunk_end      INTEGER NOT NULL,
    content_hash   TEXT NOT NULL,
    embedding      BLOB,
    PRIMARY KEY (path, chunk_index),
    FOREIGN KEY (path) REFERENCES notes(path) ON DELETE CASCADE
);
```

Storage: `Documents/vault-index.sqlite`. One DB per app install (vault identity is the security-scoped bookmark — if the user picks a different vault, we drop and rebuild).

### 6.2 Vault identity

A vault is identified by the `(vaultName, rootURL)` pair persisted alongside the bookmark in `UserDefaults` under key `obelisk.activeVault`. Switching vaults nukes the index (the alternative — keeping multiple — adds storage cost we can't justify for v1).

### 6.3 Content hashing

`SHA256(file bytes)` decides whether a note needs re-parsing. `modificationDate` is consulted as a cheap pre-filter but never trusted as ground truth (iCloud unreliability per [roadmap.md §"Pitfalls"](./roadmap.md)).

---

## 7. New tools

All seven conform to the existing `Tool` protocol from Phase A; nothing about `AppleFoundationRunner` or `JSONArgsToolAdapter` changes.

| Tool | Args | Returns | Notes |
|------|------|---------|-------|
| `SearchVaultTool` | `query: String`, `tag?: String`, `folder?: String`, `limit?: Int (default 8)` | `{ results: [{ path, title, snippet, score }] }` | Phase B is plain FTS over `notes.body` (LIKE / GRDB FTS5). Phase C upgrades to semantic. |
| `ReadNoteTool` | `path: String` | `{ path, title, frontmatter, body }` | If body exceeds ~6K tokens, returns a chunked view with `chunks: [{ index, heading, body }]` and a hint to call again with `chunkIndex`. |
| `ListNotesByTagTool` | `tag: String`, `includeChildren?: Bool (default true)` | `{ notes: [{ path, title, modifiedAt }] }` | `#project` includes `#project/obelisk` when `includeChildren`. |
| `GetBacklinksTool` | `path: String` | `{ backlinks: [{ sourcePath, sourceTitle, snippet }] }` | Resolves via `links.target_path = path`. |
| `ListRecentNotesTool` | `days: Int (default 7)`, `limit?: Int (default 20)` | `{ notes: [{ path, title, modifiedAt }] }` | Sorted newest-first. Used by "what was I working on" prompts. |
| `ReadDailyNoteTool` | `date?: String (ISO, default today)`, `createIfMissing?: Bool (default false)` | `{ path, title, body, created: Bool }` | Uses `.obsidian/daily-notes.json` if present, else `Daily Notes/YYYY-MM-DD.md`. `createIfMissing=true` triggers `CreateNoteTool` internally with `source: obelisk` frontmatter. |
| `CreateNoteTool` | `title: String`, `body: String`, `folder?: String (default "obelisk/")`, `tags?: [String]` | `{ path, created: Bool }` | Enforces all "do no harm" rules (see §8.5). |

### 7.1 Returning citations

Every read tool that surfaces note content includes a `citations` array in its output alongside the human-readable payload. The Sources card UI consumes that array. Shape:

```
{ "citations": [
    { "path": "Patient capital.md",
      "title": "Patient capital",
      "snippet": "…the discipline of holding, not waiting…",
      "score": 0.81 }
] }
```

Citations are populated automatically by a helper in `VaultIndex`; tools never have to construct them by hand.

---

## 8. Execution order

Sequential — earlier steps unblock later ones.

1. ✅ **Package dependencies.** Added Yams 6.2.1, GRDB.swift 7.10.0, swift-markdown (main) to `project.yml`. Verified clean build under `make gen build`.
2. ✅ **Sample vault scaffolding via `make seed-vault` + `SampleVaultProvider` (DEBUG).** Instead of bundling a fixed corpus in `Resources/`, `make seed-vault VAULT=/path/to/vault` rsyncs an existing vault into `Documents/SampleVault/`. `SampleVaultProvider.detect()` exposes it via the same `VaultHandle` shape the real picker will use. Seeded with the developer's real 529-note vault for end-to-end testing.
3. 🟡 **`VaultAccessService` (sample-vault path only).** App-sandbox vault binding, `UserDefaults`-persisted binding kind, debug-only `bindSampleVault()`. Document picker + security-scoped bookmark + `NSFileCoordinator` wrapping are stubbed (`VaultAccessError.notImplemented`) and land with the picker flow.
4. ✅ **`VaultGateView`.** Pre-chat gate replaces the empty state when no vault is bound; `RootView` switches between it and `ChatView`. (DEBUG) "Use sample vault" button binds the seeded vault and shows a detected-notes summary. iCloud-placeholder copy is deferred to step 15.
5. ✅ **Parsing primitives.** `FrontmatterParser` (Yams), `WikilinkParser`, `TagExtractor`, `MarkdownChunker` (swift-markdown). Chunker is built now but unused until Phase C.
6. ✅ **`ObsidianConfig`.** Reads `.obsidian/daily-notes.json` and detects the Templater plugin; returns sensible defaults when missing.
7. ✅ **`VaultIndex` (GRDB).** Schema migration v1 in [VaultIndexSchema.swift](./Sources/Persistence/VaultIndexSchema.swift) — `notes` / `links` / `tags` + reserved `embeddings`. Backed by `DatabaseQueue` at `Documents/vault-index.sqlite`. `upsert`, `existingHashes`, `noteCount`, `wipe`, `resolveOutboundLinks` exposed for the scanner; richer query helpers land with the read tools.
8. ✅ **`VaultScanner` + `VaultIndexingService`.** Walks the vault off-main on a detached task, computes SHA-256 per file, parses only changed notes, resolves wikilinks via Obsidian's "shortest unique name" rule, then prunes stale paths. `VaultIndexingService` is the `@MainActor @Observable` glue that exposes scan status to the UI and kicks off an incremental scan from `RootView.task` whenever a vault becomes active. Validated on the seeded vault: full scan → 529 notes / 2930 links / 127 tags in ~0.9s; incremental relaunch → parsed=0, skipped=529 in ~0.15s.
9. ✅ **Vault Settings sheet + allowlist→denylist inversion.** [VaultSettingsView](./Sources/UI/VaultSettingsView.swift) is presented from the chat top-bar `⋯` button as a `.sheet`. Three sections: **Vault** (display name + `…/Documents/SampleVault/` path + a destructive "Change vault…" with a confirm-disconnect alert that calls `forgetVault()` + `indexing.reset()`); **Indexing** (color-coded status line — idle / scanning + progress bar / ready with `530 notes · last scan N sec. ago` + parsed/skipped/deleted/duration / failed in red — plus a "Re-index now" CTA that calls `reindex(handle:)` and is disabled while a scan is in flight); **Write Deny List** (explanatory copy, the two locked default rows `.obsidian/` + `.trash/` with lock glyphs, the user's editable entries each with a red `minus.circle.fill` remove button, and an add-row TextField + `+` button). The deny-list inversion that ships with this sheet:
    - [VaultWriter.defaultAuthorizedFolders](./Sources/Services/Vault/VaultWriter.swift) (`["obelisk"]`) replaced with `defaultDenyList = [".obsidian", ".trash"]` (hard-coded, non-overridable — editing Obsidian's own config bricks the vault).
    - `userDenyList: [String]` lives on [VaultAccessService](./Sources/Services/Vault/VaultAccessService.swift), persisted to `UserDefaults` under `obelisk.vault.userDenyList`, and edited from this sheet via `setUserDenyList(_:)` (dedup + trim, defaults filtered out so the user can't accidentally duplicate them).
    - `checkAuthorized` → `checkNotDenied`: any path segment that case-insensitively matches a deny entry refuses the write, so both `archive/foo.md` and `notes/Archive/foo.md` fail when `Archive` is denied.
    - [ReadDailyNoteTool](./Sources/Services/Tools/ReadDailyNoteTool.swift) folder-authorization special case dropped — it's now a plain `VaultWriter.write(...)` call. Daily notes land wherever Obsidian configured them as long as the user hasn't denied that folder.
    - `source: obelisk` overwrite refusal stays load-bearing: under the denylist model it's the only safety net keeping user-authored notes anywhere in the vault safe from the model. Atomic temp + `replaceItemAt` stays.
    - [AppEnvironment](./Sources/App/AppEnvironment.swift) wires a `denyListProvider: @Sendable () async -> [String]` into `CreateNoteTool` and `ReadDailyNoteTool` (same pattern as `rootURLProvider`), so deny-list edits in the sheet take effect on the next tool call without re-registering anything.
    - Validation checklist line about "unauthorized folder" updated to "deny-listed folder" below.
    - Validated on simulator: opened the sheet from `⋯`, confirmed `SampleVault` display name + `…/Documents/SampleVault/` path render correctly, Ready state shows `530 notes · last scan 11 sec. ago / parsed=0, skipped=530, deleted=0 · 0.56s`, "Re-index now" sits under it, the two locked defaults plus an add/remove cycle of `Archive/` on the deny list both work.
10. ✅ **Read tools (6 of them).** [SearchVaultTool](./Sources/Services/Tools/SearchVaultTool.swift), [ReadNoteTool](./Sources/Services/Tools/ReadNoteTool.swift), [ListNotesByTagTool](./Sources/Services/Tools/ListNotesByTagTool.swift), [GetBacklinksTool](./Sources/Services/Tools/GetBacklinksTool.swift), [ListRecentNotesTool](./Sources/Services/Tools/ListRecentNotesTool.swift), [ReadDailyNoteTool](./Sources/Services/Tools/ReadDailyNoteTool.swift). Each returns `citations` shaped via [Citation.swift](./Sources/Domain/Vault/Citation.swift) so the future Sources card can consume them uniformly. Query helpers live in [VaultIndex](./Sources/Services/Vault/VaultIndex.swift); `ReadNoteTool` chunks long notes via `MarkdownChunker`. List-style tools default to 10 results (cap 25) and snippets cap at 120 chars to stay within the 3B model's context budget. Validated on simulator: "What notes did I touch in the last 3 days?" → model called `list_recent_notes`, got `Master Branch.md` with the right snippet, and produced a clean text reply.
11. ✅ **`VaultWriter` + `CreateNoteTool`.** [VaultWriter](./Sources/Services/Vault/VaultWriter.swift) enforces (a) authorized folder allowlist (default `obelisk/`, with `""` opt-in for root-level daily notes); (b) `source: obelisk` injected on every write; (c) atomic temp + `replaceItemAt`; (d) refusal to overwrite a note lacking `source: obelisk`. [CreateNoteTool](./Sources/Services/Tools/CreateNoteTool.swift) shapes the request, then upserts the new note into `VaultIndex` so a follow-up read sees it immediately. [ReadDailyNoteTool](./Sources/Services/Tools/ReadDailyNoteTool.swift) now honors `createIfMissing=true` via `VaultWriter`. Tool failures are returned to FM as `{"error": …}` JSON (see [AppleFoundationRunner.JSONArgsToolAdapter](./Sources/Services/AppleFoundationRunner.swift)) instead of being thrown, so refusals surface only as the clean amber inline row and the model can self-correct in its next turn. Validated on simulator: (a) "Phase B Smoke Test" created at `obelisk/Phase B Smoke Test.md` with `source: obelisk` + tag list; (b) prompt to write into `04 People/` triggered the refusal, kept the filesystem untouched, and the model retried with the default `obelisk/` folder.
12. ✅ **Tool registry swap.** `ScratchpadTool` deleted from `Sources/Services/Tools/`; `AppEnvironment.defaultTools(index:access:)` now registers the six vault read tools alongside the surviving `DateTimeTool` and `CalculatorTool` (8 tools total — under the 6–10 phase-b.md pitfall threshold). [EmptyStateView](./Sources/UI/ChatView.swift) suggestions rotated to vault prompts. Verified on simulator: vault questions invoke `search_vault`/`list_recent_notes` rather than `calculator`.
13. ✅ **Citations UI.** [SourcesCard](./Sources/UI/SourcesCard.swift) lives at the bottom of any assistant turn whose tool calls returned `citations` (extracted via `SourcesCard.citations(in:)` — dedup'd by path, fail-safe over tools that don't emit them). Renders a "Sources" header above a bordered card; up to 3 rows visible by default, "+ N more" reveals the rest. Each row is a file glyph + title + 1–2-line snippet. Tap → `obsidian://open?vault=<displayName>&file=<path-without-md>` via SwiftUI's `@Environment(\.openURL)`. Card only renders after `message.status == .complete` so it doesn't flicker mid-stream; `MessageListView` now scrolls on `status` / `toolCalls.count` changes so a late-arriving card stays in view above the input row's fold. Validated on simulator: "Search my vault for productivity." → 8 citations, 3 visible + "+ 5 more", header + glyphs + truncated snippets all per [ui-spec.md §4.6](./ui-spec.md).
14. ✅ **Wikilink rendering.** [WikilinkText](./Sources/UI/WikilinkText.swift) replaces the raw `Text(message.content)` in `AssistantTurn` for non-errored turns. Scans the prose with the same regex as `WikilinkParser`, builds an `AttributedString` where `[[` and `]]` render at ~40% accent opacity and the inner display name renders in accent purple semibold. All three segments carry the same `.link` attribute so the whole `[[…]]` is one tap target; SwiftUI's `@Environment(\.openURL)` dispatches the deep link. URL: `obsidian://open?vault=<displayName>&file=<Target[#Heading][#^block]>` — heading and block refs are appended per Obsidian's URL scheme; display labels (`[[Target|Label]]`) show `Label` while resolving to `Target`. Errored turns stay as plain red text so the failure reads as one semantic unit. Validated on simulator: "What links to [[Master Branch]]?" → model's response rendered `[[` `Master Branch` `]]` in spec'd accent-purple styling per [ui-spec.md §2.2 / §4.7](./ui-spec.md).
15. ✅ **iCloud placeholder gate.** [VaultScanner](./Sources/Services/Vault/VaultScanner.swift) throws `ScanError.iCloudNotDownloaded` immediately after enumeration if `inventory.iCloudPlaceholders > 0` — copy: "Vault not fully downloaded from iCloud. Mark the folder as 'Keep on this iPhone' and try again." Enumerator no longer passes `.skipsHiddenFiles` (placeholder files are dot-prefixed like `.Foo.md.icloud`) and manually skips `.obsidian` / `.trash` / `.git` instead. `VaultIndexingService` surfaces the throw as `.failed(message)`, which [ChatView.activeStatusPill()](./Sources/UI/ChatView.swift) renders as a full-width red [StatusPill](./Sources/UI/StatusPill.swift) under the top bar; tap → `reindex(handle:)`. Validated on simulator: `touch .SomeNote.md.icloud` in the seeded vault → red pill on relaunch; `rm` the placeholder + tap the pill → pill clears, indexing returns to `.ready`. Force-download remains stretch.
16. ✅ **Device QA.** Validated on real iPhone with a real iCloud-stored Obsidian vault. Document picker → security-scoped bookmark → cold-launch restore all behave. All six read tools invoked end-to-end (`search_vault`, `read_note`, `list_notes_by_tag`, `get_backlinks`, `list_recent_notes`, `read_daily_note`); both write paths (`create_note`, `read_daily_note(createIfMissing: true)`) round-trip through Obsidian cleanly. Deny-list refusal confirmed end-to-end. Tool-routing pass surfaced two real issues that landed mid-QA: (a) the model was picking `create_note` for "create today's daily note" prompts → sharpened both tool descriptions so `read_daily_note` claims daily-note / today / journal / date-shaped requests and `create_note` explicitly disclaims them; (b) the `obelisk/` allowlist-vestige default folder was inconsistent with the denylist model → `CreateNoteTool.folder` now defaults to `""` (vault root), matching where a manually-created Obsidian note lands. Two gaps surfaced but intentionally not addressed in Phase B: no body-edit / append tool (the model improvises a duplicate note when asked to add content to an existing one — out of scope per the do-no-harm rules' "no structural body edits" stance), and Periodic Notes plugin config (`.obsidian/plugins/periodic-notes/data.json`) isn't read so vaults using it for daily notes fall back to core `daily-notes.json` defaults.

---

## 9. Validation checklist

Before declaring Phase B done, every item below must be demonstrably true:

- [x] On a fresh install with no vault, the app shows `VaultGateView` instead of the chat empty state.
- [x] Picking a vault via the document picker persists access across cold launches; re-launching does not re-prompt.
- [x] In Simulator with the sample vault, "Use sample vault" produces a working chat in under 5 seconds.
- [x] `SearchVaultTool` returns reasonable results for both exact and partial queries against the sample vault. (Vague queries like "what notes do I have" under-perform — the LIKE search is the known weakness Phase C semantic supersedes.)
- [x] Asking "show me notes tagged X" lists the right notes from the sample corpus, including hierarchical matches.
- [x] "What links to [[A]]?" returns the expected backlinks; unresolved wikilinks don't crash the parser.
- [x] Asking "what's in my daily note today?" with no daily note present prompts the model to call `ReadDailyNoteTool(createIfMissing: true)`; the resulting note has `source: obelisk` frontmatter.
- [x] Asking the model to create a note inside a deny-listed folder (e.g. `.obsidian/`, `.trash/`, or any user-added entry from the Vault Settings sheet) fails the tool call with an amber inline error; no file is written under the denied path.
- [x] A note created by Obelisk is visible in the Files app inside the vault and opens cleanly in Obsidian (on device QA).
- [x] Wikilinks in assistant replies render in accent purple with low-opacity brackets and open Obsidian on tap.
- [x] Sources card renders under any cited assistant turn; tap → opens the note in Obsidian.
- [x] An iCloud-stored vault with at least one `.icloud` placeholder triggers the red "not fully downloaded" inline error and refuses to index until resolved.
- [x] Foregrounding the app after editing a vault note in Obsidian on Mac causes the next search to pick up the changes (incremental scan via SHA-256 diff).
- [x] No crashes after a 20-minute session that includes vault switching and at least one full re-index.

---

## 10. Pitfalls (from roadmap §"Phase B")

- **Security-scoped bookmarks expiring.** Detect stale bookmarks (resolve throws or returns no-access). On stale, surface a one-tap "Reconnect vault" affordance — never crash, never auto-prompt the picker on launch.
- **Frontmatter round-tripping.** Yams parse → serialize is not lossless. Per the "do no harm" rule from [roadmap.md](./roadmap.md), the writer splices new keys into the original text by line offset rather than round-tripping the whole frontmatter through Yams. Comments and exact formatting on untouched keys must survive.
- **Wikilink resolution edge cases.** Same name in multiple folders, links to nonexistent notes, relative paths. Resolve heuristically (Obsidian's "shortest unique name" rule), persist `target_path = NULL` for unresolved, log + carry on.
- **Templater detection.** If `.obsidian/plugins/templater-obsidian/` exists, warn the user in the Vault settings sheet that Obelisk-created daily notes won't run their template.
- **File modification timing.** iCloud reports stale `modificationDate`. SHA-256 is the source of truth for change detection.
- **Tool count creeping past 10.** A 3B model's tool-selection accuracy drops sharply past 6–10 tools. Phase B already adds 7. Resist the urge to bolt on `WebSearchTool` + `URLFetchTool` in this phase unless we're willing to remove or merge something else.
- **`NSFileCoordinator` everywhere.** Forgetting to wrap reads/writes against an iCloud-stored vault causes silent data loss under sync. Centralize in `VaultAccessService.withReadAccess` so it can't be skipped at a call site.
- **Background eviction during scan.** Full scans of large vaults can run minutes. Track progress in the index (or a sidecar file) so we can resume on next launch rather than restarting from scratch.

---

## 11. Hand-off to Phase C

> **Phase C scope changed after Phase B device QA** — see [roadmap.md §"Phase C: Search that works"](./roadmap.md). The original "semantic search via embeddings" plan moved to deferred; the new Phase C is FTS5 + fuzzy fallback + frecency + `browse_vault`. Hand-off notes updated to reflect that.

What Phase C will inherit and what it must *not* break:

- The `notes` / `links` / `tags` schema from migration v1 is the source of truth Phase C extends. The FTS5 virtual table is an *external-content* mirror of `notes(title, body)` kept in sync via triggers, so the existing scanner upsert path stays unchanged.
- The `embeddings` table reserved in migration v1 stays reserved and unused — Phase C v2 (this version) doesn't populate it. Kept on the schema so a future `semantic_search_vault` add-on doesn't need a migration.
- `MarkdownChunker` is built in Phase B but unused — and stays unused through Phase C v2. Kept on the shelf for the same future embeddings work.
- `SearchVaultTool` is the seam Phase C *upgrades in place*. Its `citations`-shaped output stays identical so the Sources card UI doesn't change. The new `BrowseVaultTool` reuses the same `Citation` shape via `VaultIndex.citation(forPath:)`.
- `VaultAccessService.withReadAccess` is the single mediator for file I/O. Phase C is index-only — no new vault reads — so the helper stays untouched.
- The "do no harm" rules and `VaultWriter` are untouched by Phase C; search and browse are read-only over the index.
- Frecency tracking introduces a new `note_opens` table (Phase C migration v2). Writes happen from the UI layer (Sources card tap, wikilink tap) and from `read_note` / `read_daily_note` invocations. Independent of vault file I/O.
