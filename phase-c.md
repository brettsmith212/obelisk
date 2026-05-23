# Phase C — Implementation Overview

Make search in Obelisk feel like good lexical search, not bad lexical search. **No embeddings, no vector store, no model download, no MarkdownChunker invocation.** SQLite FTS5 + a tiny fuzzy fallback + a frecency layer + one new enumeration tool.

See [roadmap.md §"Phase C: Search that works"](./roadmap.md) for the strategic framing and scope-change rationale (TL;DR: every top agentic coder converged on lexical search, our QA failure modes were enumeration and weak keyword matching, embeddings move to deferred).

---

## 1. Goals

End-of-phase, on a physical iPhone 15 Pro / 16 Pro running iOS 26:

1. "What notes do I have" → `browse_vault` returns the first page sorted by recently modified.
2. "Search for productivity tips" → `search_vault` returns BM25-ranked hits; notes with the words in the *title* rank above body-only hits.
3. "Find my zetlekasten note" (typo) → vocab correction rewrites the token to `zettelkasten` and FTS5 returns the note; if vocab correction misses, fuzzy title fallback still finds "Zettelkasten."
   - And: "productiviy meeting notes" (typo in one of three tokens) returns the same hits as the correctly-spelled query, *not* zero — because the typo'd token is rewritten before the AND pass, not silently dropped.
4. A note the user has opened 5× in the past week ranks above an otherwise-equivalent never-opened note for the same query.
5. The agent picks `browse_vault` for enumeration prompts and `search_vault` for keyword prompts, reliably enough that we don't have to babysit it. No tool-name overlap.
6. Multi-word queries like "long term thinking" don't need every word in a single field — title hits on any word, body hits on all words, both surface.

---

## 2. Scope

### In scope

- New SQLite migration v2:
  - `notes_fts` — external-content FTS5 virtual table over `notes(title, body)` with sync triggers.
  - `note_opens` — append-only `(path, opened_at)` for frecency.
- Rewrite of [VaultIndex.search](./Sources/Services/Vault/VaultIndex.swift) to use FTS5 BM25 with `weight(title) = 10`, `weight(body) = 1`.
- A query-translation layer that converts the model's free-text `query` arg into safe FTS5 syntax (escaping, **per-token vocab correction**, AND→OR fallback, phrase support).
- A `VocabCache` over the FTS5 `notes_fts_v` auxiliary table so typo'd tokens get rewritten to the nearest in-vocabulary token before the FTS5 pass — keeps one bad token from sinking a multi-word query.
- Fuzzy title fallback when FTS5 (even after vocab correction) returns zero hits — Levenshtein over the title corpus, reserved for title-style lookups and last-resort typo recovery.
- New `BrowseVaultTool` for paginated enumeration.
- Frecency tracking — open events written from Sources card taps, wikilink taps, and `read_note` / `read_daily_note` invocations.
- Updated tool descriptions to claim the right prompt shapes.
- **Removal of `list_recent_notes` and `list_notes_by_tag`** — both fully absorbed by the upgraded `browse_vault` (folder + tag + sort + page args). Cuts two near-duplicate enumeration tools that the 3B model struggled to disambiguate during Phase B QA.

### Out of scope (deferred)

- **Semantic search via embeddings.** Original Phase C plan; moved to deferred. See roadmap.md.
- **Wikilink-graph ranking (PageRank-style).** Considered, deferred — not enough usage data yet.
- **Hybrid lexical + semantic re-rank.** Only meaningful once embeddings come back.
- **Cross-vault frecency sync.** Single-device frecency only.
- **Search UI surface.** No new dedicated search screen in Phase C — search is still agent-mediated.

### Stretch (only if Phase C finishes early)

- `WebSearchTool` + `URLFetchTool` (originally Phase B stretch, deferred again).
- Frecency boost configurable in Settings.

---

## 3. Architecture

```diagram
╭─────────────────────────────────────────────────────╮
│  ChatView (SwiftUI)                                 │
│   · existing chat shell + Sources card              │
│   · adds: open-tracking hooks                       │
╰─────────────┬───────────────────────────────────────╯
              │ (Sources tap, wikilink tap → note_opens)
              ▼
╭─────────────────────────────────────────────────────╮
│  ToolDispatcher  (AFM-realistic: 2 tools only)      │
│   · FindTool   — keyword / tag / folder / backlinks │
│   · ReadTool   — read one note (by path or daily)   │
│                                                     │
│   Removed during the Phase-C AFM-realistic refactor:│
│     SearchVaultTool, BrowseVaultTool, ReadNoteTool, │
│     ReadDailyNoteTool, GetBacklinksTool,            │
│     CreateNoteTool, DateTimeTool, CalculatorTool    │
╰─────────────┬───────────────────────────────────────╯
              │
              ▼
╭─────────────────────────────────────────────────────╮
│  VaultIndex (GRDB)                                  │
│   · existing notes / links / tags / embeddings      │
│   · adds:                                           │
│     notes_fts (FTS5 virtual table)                  │
│     note_opens (frecency)                           │
│   · adds query methods:                             │
│     search(query:)        — FTS5 + fuzzy + frecency │
│     browse(...)           — paginated enumeration   │
│     backlinks(to:)        — wikilink reverse index  │
│     recordOpen(path:)     — frecency writer         │
│     frecencyScore(path:)  — frecency reader         │
╰─────────────────────────────────────────────────────╯
```

`FindTool` and `ReadTool` are thin shells over `VaultIndex`. The
underlying search / browse / backlinks engines all still exist — only
the *tool surface* was collapsed. See §5 for the rationale.

### 3.1 New type seams

- **`SearchQuery`** — small value type wrapping `(raw: String, tokens: [String], phrases: [String], corrections: [String: String])`. Built once by `QueryParser.parse(raw:vocab:)`; consumed by both the FTS5 path and the fuzzy fallback. `corrections` carries `original → corrected` so the UI / logs can surface "did you mean" later if we ever want to.
- **`VocabCache`** — `Set<String>` of every token currently in `notes_fts`. Built once on first query (or scan complete), refreshed when the scanner upserts. Read source: SQLite's auto-generated `notes_fts_v` auxiliary table (FTS5 provides this for free with `vocab='full'` config). ~10k entries for a 5k-note vault ≈ 100KB resident.
- **`FrecencyScore`** — `Double` in `[0, 1]`, computed from `note_opens` rows via exponential decay. Cached per-path for the lifetime of a query.
- **`BrowseSort`** — `enum { case modified, title }`. Drives the `ORDER BY` in `VaultIndex.browse(...)`.

### 3.2 Discipline rules carried forward

- The `LLMRunner` seam **does not change** in Phase C. `BrowseVaultTool` conforms to the existing `Tool` protocol via `JSONArgsToolAdapter`. No new schema kinds.
- All vault file I/O still goes through `VaultAccessService.withReadAccess` — though Phase C is index-only, so this helper doesn't actually get called by new code. New invariant: search/browse never read the filesystem; everything answers from `VaultIndex`.
- The "do no harm" rules and `VaultWriter` are untouched.

### 3.3 File layout (additions / changes)

```
Obelisk/
  Domain/
    Vault/
      SearchQuery.swift              // new
  Persistence/
    VaultIndexSchema.swift           // adds migration v2
  Services/
    Vault/
      VaultIndex.swift               // adds search / browse / backlinks / frecency
      FrecencyTracker.swift          // new — write side + decay math
      QueryParser.swift              // new — raw text → FTS5 MATCH expression
      FuzzyTitleMatcher.swift        // new — edit-distance fallback
      VocabCache.swift               // new — notes_fts_v wrapper
    Tools/
      FindTool.swift                 // new — search / browse / backlinks in one
      ReadTool.swift                 // new — read by path or daily
      SearchVaultTool.swift          // REMOVED (absorbed by FindTool)
      BrowseVaultTool.swift          // REMOVED (absorbed by FindTool)
      GetBacklinksTool.swift         // REMOVED (absorbed by FindTool)
      ReadNoteTool.swift             // REMOVED (absorbed by ReadTool)
      ReadDailyNoteTool.swift        // REMOVED (absorbed by ReadTool)
      CreateNoteTool.swift           // REMOVED (write deferred to a `write` tool)
      ListRecentNotesTool.swift      // REMOVED (Phase B)
      ListNotesByTagTool.swift       // REMOVED (Phase B)
      DateTimeTool.swift             // REMOVED (Phase A demo, no product value)
      CalculatorTool.swift           // REMOVED (Phase A demo, no product value)
  UI/
    ChatView.swift                   // wire note-open events
    SourcesCard.swift                // tap → recordOpen
    WikilinkText.swift               // tap → recordOpen
```

---

## 4. Data model

### 4.1 Migration v2

```sql
-- External-content FTS5 mirror. `content='notes'` + `content_rowid='rowid'`
-- means FTS5 doesn't duplicate the body bytes — it reads from `notes` on
-- demand. Triggers below keep the index in sync.
CREATE VIRTUAL TABLE notes_fts USING fts5(
    title,
    body,
    content='notes',
    content_rowid='rowid',
    tokenize='unicode61 remove_diacritics 2'
);

-- Sync triggers. Without these the FTS5 index goes stale silently.
CREATE TRIGGER notes_fts_ai AFTER INSERT ON notes BEGIN
    INSERT INTO notes_fts(rowid, title, body) VALUES (new.rowid, new.title, new.body);
END;
CREATE TRIGGER notes_fts_ad AFTER DELETE ON notes BEGIN
    INSERT INTO notes_fts(notes_fts, rowid, title, body) VALUES('delete', old.rowid, old.title, old.body);
END;
CREATE TRIGGER notes_fts_au AFTER UPDATE ON notes BEGIN
    INSERT INTO notes_fts(notes_fts, rowid, title, body) VALUES('delete', old.rowid, old.title, old.body);
    INSERT INTO notes_fts(rowid, title, body) VALUES (new.rowid, new.title, new.body);
END;

-- Backfill from existing rows once the table + triggers exist.
INSERT INTO notes_fts(rowid, title, body) SELECT rowid, title, body FROM notes;

-- Frecency. Append-only — keep history so we can re-tune the decay later.
CREATE TABLE note_opens (
    path        TEXT NOT NULL,
    opened_at   DATETIME NOT NULL,
    source      TEXT NOT NULL,        -- "sources_tap" | "wikilink" | "read_note" | "daily_note"
    FOREIGN KEY (path) REFERENCES notes(path) ON DELETE CASCADE
);
CREATE INDEX idx_note_opens_path ON note_opens(path);
CREATE INDEX idx_note_opens_at   ON note_opens(opened_at);
```

The `notes` rowid is the join key — GRDB exposes it as `Int64`; we use the implicit rowid SQLite assigns. No schema change to `notes`.

### 4.2 Frecency math

Per-note score:

```
frecency(path) = Σ exp(-λ × days_since(opened_at))   for opens in last 90 days
```

`λ = ln(2) / 10` → 10-day half-life. Cap raw score at 10 (above that, take `10 + sqrt(score - 10)`) to prevent a single dominant note from drowning everything.

Combined with BM25:

```
final_score = bm25_score × (1 + frecency_boost)
where frecency_boost = min(frecency_score × 0.3, 1.5)
```

A note never opened: boost = 0, score = pure BM25. A long-favorite note: boost capped at +150%, so a truly strong BM25 match on an unfavored note still beats it.

---

## 5. Tools after the AFM-realistic refactor

Phase C was originally specified to ship 8 tools (`search_vault`,
`browse_vault`, `read_note`, `read_daily_note`, `get_backlinks`,
`create_note`, `datetime`, `calculator`). Simulator QA against a real
vault — combined with a deliberate read of Apple's
[TN3193](https://developer.apple.com/documentation/technotes/tn3193-managing-the-on-device-foundation-model-s-context-window) —
showed that count was wrong for AFM:

- TN3193 explicitly caps the recommended tool count at **3–5**.
- Every tool's `name + description + arg schema` is in the system
  prompt on *every* turn, paid for out of the 4096-token window.
- AFM's routing accuracy degrades sharply as the tool count grows or
  as descriptions overlap in vocabulary ("search vault" vs
  "browse vault" both say "vault notes").
- The Phase A demo tools (`datetime`, `calculator`) had no product
  value in a vault assistant and burned schema tokens for free.

So we collapsed the surface to two verbs — **`find`** (which notes?)
and **`read`** (what does this note say?) — and dropped the rest.
This matches the "verbs of a vault" model (find / read / write) and
puts AFM's routing decision on a binary that a ~3B model can actually
make reliably.

### 5.1 `find` (new — surfaces notes)

```swift
struct FindTool: Tool {
    let name = "find"
    let description = "Find vault notes by keyword, tag, folder, or backlinks."
    let argumentsSchema: JSONSchema = .object(
        properties: [
            "query":     .string(description: "Free-text keyword search."),
            "tag":       .string(description: "Tag filter, no '#'."),
            "folder":    .string(description: "Vault-relative folder prefix."),
            "linked_to": .string(description: "Vault-relative path; returns notes that wikilink to it."),
            "limit":     .integer(description: "Max notes. Default 10, cap 10."),
            "offset":    .integer(description: "Skip count for paging browse results."),
        ],
        required: []
    )
}
```

Dispatch is **implicit in argument presence** — no `mode` enum, fewer
schema tokens for AFM to digest:

| Args supplied | Underlying call |
|---|---|
| `linked_to` | `VaultIndex.backlinks(to:, limit:)` |
| `query` (with optional `tag` / `folder`) | `VaultIndex.search(query:, tag:, folder:, limit:)` |
| neither (with optional `tag` / `folder`) | `VaultIndex.browse(folder:, tag:, includeChildTags: true, sortBy: .modified, limit:, offset:)` |

Returns a flat envelope:

```json
{
  "notes":     [{ "path", "title" }, …],
  "citations": [ …Citation… ],          // same set, UI's Sources card binds here
  "totalCount": 530,                    // browse mode only
  "hasMore":   true,                    // browse mode only
  "nextOffset": 10                      // browse mode only, omitted when !hasMore
}
```

Snippets are **omitted** from the tool payload — every cited note row
costs tokens, and the model only needs `path + title` to either reply
or follow up with `read`. The Sources card builds its own snippet
preview from the index when rendering.

### 5.2 `read` (new — reads one note)

```swift
struct ReadTool: Tool {
    let name = "read"
    let description = "Read the contents of one vault note (by path, or today's daily)."
    let argumentsSchema: JSONSchema = .object(
        properties: [
            "path":  .string(description: "Vault-relative path of any note."),
            "daily": .string(description: "'today' or YYYY-MM-DD for the daily note."),
            "full":  .boolean(description: "Return the full body instead of a preview."),
        ],
        required: []
    )
}
```

Mutually-exclusive addressing: `daily` set → resolve via
`.obsidian/daily-notes.json` and look up the resulting path; else
`path` is consulted directly. If the daily note doesn't exist we
return a `{ exists: false }` envelope rather than throwing, so the
model can tell the user instead of erroring out.

`read` is **strictly read-only**. The original Phase B
`ReadDailyNoteTool` had a `createIfMissing` flag; we dropped it
because (a) it conflated reading with writing, and (b) creation
belongs to a future `write` tool (see §13).

Body defaults to a ~1500-char preview (`isPreview: true` in the
envelope when truncated); `full: true` returns the whole body. The
old `chunkIndex` arg was dropped — AFM almost never used it
correctly, and the preview-or-full binary is enough.

### 5.3 Tool registry after Phase C

`AppEnvironment.defaultTools(index:access:)` returns **2 tools**:

```
FindTool, ReadTool
```

Sits well under TN3193's 3–5 ceiling and leaves headroom for a
future `write` tool without crossing it. AFM's routing decision
collapses to a single binary — "which notes?" vs "what's in *this*
note?" — which the model handles with high reliability.

| Prompt shape | Tool | Args set |
|---|---|---|
| "find / search / look up notes about X" | `find` | `query` |
| "what notes do I have / recent notes / what have I been working on" | `find` | (none — defaults to recency) |
| "show me my #X notes" | `find` | `tag` |
| "what's in my <folder> folder" | `find` | `folder` |
| "what links to X / backlinks" | `find` | `linked_to` |
| "read note at path X" | `read` | `path` |
| "today's note / daily note / journal" | `read` | `daily: "today"` |

### 5.4 Companion guards in `AgentService`

The two-tool surface alone isn't enough — AFM still speculatively
chains tool calls. Three turn-scoped guards live in
[AgentService.swift](./Sources/Services/AgentService.swift) and
[AppleFoundationRunner.swift](./Sources/Services/AppleFoundationRunner.swift):

- **`maxTotalCalls: 1`** — one tool call per assistant turn. AFM's
  4096-token window cannot reliably fit two tool outputs plus their
  schemas plus a reply. Multi-step intent becomes two user turns.
- **Zero transcript replay** — each prompt is treated as a fresh
  request; no prior turns are replayed to the model. Trades pronoun
  follow-ups ("what does it say?") for predictable per-turn token
  budgets. Apple's TN3193 endorses this pattern explicitly under
  "split a large task into multiple language model sessions."
- **No-progress watchdog (45 s)** — surfaces a clean `inferenceStalled`
  error when the FM inference host dies silently mid-generation
  (which it does on context overflow), instead of leaving the UI on
  a stuck stop button.

---

## 6. Query translation

Free-text query → FTS5 MATCH string. **Assume users have typos** — the model will faithfully pass them through, and a single misspelled token in an AND-joined query is enough to return zero hits. We fix that at parse time, before FTS5 ever sees it.

The model will send things like:

- `productivity tips` → 2 tokens, AND
- `productiviy meeting notes` → 1 typo, 2 good tokens → vocab-correct `productiviy → productivity`, then AND
- `"long term thinking"` → phrase
- `mlx-swift` → 1 token with hyphen (FTS5 tokenizes on `-`, so this becomes `mlx swift`)
- `function(args)` → strip parens
- `tag:project` → keep colon stripped; we have a separate `tag` arg

Algorithm in `QueryParser.parse(raw:vocab:)`:

1. Pull out quoted phrases first: `/"([^"]+)"/` → `phrases`. **Phrases bypass vocab correction** — users mean them literally.
2. From the remainder, split on whitespace → `tokens`.
3. For each token, strip FTS5-significant chars: `:`, `*`, `(`, `)`, `"`, `^`, `~`, `+`, `-` at boundaries.
4. Drop empty tokens.
5. Drop tokens shorter than 2 chars (`'a'`, `'I'` — match too much, slow FTS5).
6. **Vocab correction.** For each remaining token (lowercased):
   - If the token is already in `VocabCache` → keep as-is.
   - Else if token length ≥ 4 → find the nearest in-vocab token by Levenshtein. Accept the correction if distance ≤ 2 AND distance ≤ `floor(token.count / 4)` (so `cat → bat` is rejected at length 3, but `productiviy → productivity` at distance 1 is accepted). Record `original → corrected` in `SearchQuery.corrections`.
   - Else (token length < 4, no in-vocab hit) → keep as-is; the OR fallback or fuzzy stage will handle it.
   - Implementation: linear scan over `VocabCache` with an early-exit edit-distance bound is fast enough at 10–20k vocab entries (sub-millisecond per token). If vocab grows past ~50k, add a BK-tree.
7. Build MATCH expression from the corrected tokens:
   - First pass (AND): `(token1 AND token2 AND …) AND ("phrase1" AND "phrase2" AND …)`
   - Fallback pass (OR): `(token1 OR token2 OR …) AND ("phrase1" AND …)`  (phrases stay AND because users mean them)
8. Wrap everything in parentheses defensively.

If after stripping we're left with an empty MATCH expression, return `[]` early — no search.

The vocab cache is rebuilt (cheap) any time the scanner reports a non-trivial upsert batch, and lazily on first query if it's never been built. A stale cache only hurts brand-new tokens; we accept that and rely on the OR / fuzzy fallback for the rare miss.

---

## 7. Fuzzy title fallback

Vocab correction (§6 step 6) handles the common typo case *inside* an FTS5 query. Fuzzy title matching is the **last-resort** stage — used only when FTS5 (both AND and OR passes, with vocab-corrected tokens) returns zero rows. It exists to catch:

- single-token "find the note called X" lookups where X is so badly misspelled that vocab correction's distance budget rejected it (e.g. distance 3 on an 8-char token),
- the cold-start case where the vocab cache hasn't been built yet,
- and queries against titles that are genuinely outside the FTS5 vocabulary (very short titles dropped at step 5).

Why not fuzzy-match *everything*? Brute-force fuzzy over 5k notes × full body is too slow for typing-speed search and ranks poorly (it has no IDF, no field weighting, no BM25). FTS5 + vocab correction does the heavy lifting; fuzzy titles are the safety net.

When triggered, scan note titles only.

```swift
struct FuzzyTitleMatcher {
    /// Returns titles ranked by edit-distance-based similarity.
    /// Brute force: 10k titles × O(query × title) = sub-millisecond.
    static func match(query: String, titles: [(path: String, title: String)], limit: Int = 8) -> [Match]
}
```

Algorithm: normalize (lowercase, trim), compute Levenshtein distance, score = `1.0 - (distance / max(query.count, title.count))`. Keep matches with score ≥ 0.6. Sort descending, take `limit`.

If even fuzzy returns nothing, surface zero results honestly — the model will then phrase a follow-up.

(Smith-Waterman per fff would be more sophisticated; not worth porting on phone-scale corpora. Levenshtein is fine.)

---

## 8. Frecency

### Write side — `FrecencyTracker.recordOpen(path:source:)`

Called from:
- `SourcesCard` row tap → source: `"sources_tap"`
- `WikilinkText` link tap → source: `"wikilink"`
- `ReadTool` path branch → source: `"read_note"`
- `ReadTool` daily branch (when note exists) → source: `"daily_note"`

(`FindTool` never records opens — it surfaces lists, it doesn't
imply a read. The frecency signal comes from the subsequent `read`
or Sources-card tap.)

Single INSERT. Cheap. Async via `Task.detached(priority: .utility)` so taps stay responsive.

### Read side — `FrecencyTracker.score(path:)`

Computed on demand inside `VaultIndex.search`. Per-query cache (built once, used N times). For a query that returns 10 BM25 candidates, we compute frecency 10 times — cheap (one indexed SELECT per path).

### Cleanup

Background trim: drop `note_opens` rows older than 90 days. Runs once per app launch in a low-priority task. Keeps the table from growing unboundedly while preserving the full window the decay math needs.

---

## 9. UI changes

Minimal — Phase C is mostly tools + index.

- `SourcesCard` tap handler: emit `FrecencyTracker.recordOpen(path:source: "sources_tap")` *before* opening the `obsidian://` URL.
- `WikilinkText` tap handler: same pattern, source `"wikilink"`.
- Vault Settings sheet (`⋯`): no new section in v1. If we have time, a tiny "Most opened notes" debug list under DEBUG would help validate frecency, but it's not required.

No new screens, no new chat affordances. Empty-state suggestion chips updated to exercise the 2-tool surface end-to-end ("What notes do I have?" → `find`; "Open today's daily note." → `read`).

---

## 10. Execution order

Sequential — earlier steps unblock later ones.

1. ✅ **Migration v2 + FTS5 backfill.** Added `notes_fts` external-content FTS5 table, sync triggers, `notes_fts_v` vocab table, and `note_opens` frecency table in [VaultIndexSchema.swift](./Sources/Persistence/VaultIndexSchema.swift).
2. ✅ **`VocabCache`.** Implemented in [VocabCache.swift](./Sources/Services/Vault/VocabCache.swift); reads from `notes_fts_v`, refreshed on scanner upserts via `VaultIndex.markVocabDirty()`.
3. ✅ **`QueryParser`.** Implemented in [QueryParser.swift](./Sources/Services/Vault/QueryParser.swift) with phrase extraction, FTS5 escaping, vocab-corrected AND, OR fallback. Unit-test coverage TBD.
4. ✅ **`VaultIndex.search` rewrite.** Rewritten in [VaultIndex.swift](./Sources/Services/Vault/VaultIndex.swift) to use FTS5 BM25 with title weight 10.
5. ✅ **`FuzzyTitleMatcher`.** Levenshtein-based fallback in [FuzzyTitleMatcher.swift](./Sources/Services/Vault/FuzzyTitleMatcher.swift); wired as the zero-hits fallback after AND and OR passes.
6. ✅ **`FrecencyTracker`.** Implemented in [FrecencyTracker.swift](./Sources/Services/Vault/FrecencyTracker.swift) with write side, exponential decay read side, 90-day prune.
7. ✅ **Wire frecency into `VaultIndex.search`.** BM25 × `(1 + boost)` combined ranking live. Visible-rank validation deferred to device QA.
8. ✅ **Wire open events into UI.** `ReadTool` (both branches) records opens; Sources card opens via `openURL` interceptor in [ChatView.swift](./Sources/UI/ChatView.swift); wikilink taps via the same interceptor.
9. ✅ **`BrowseVaultTool`.** Originally shipped with `folder`, `tag`, `includeChildTags`, `sortBy`, `limit`, `offset` args. *Later absorbed into `FindTool` — see step 14.*
10. ✅ **Remove `ListRecentNotesTool` and `ListNotesByTagTool`.** Both source files deleted, registry slimmed; `make build` clean.
11. ✅ **Sharpen tool descriptions.** Long claim-style descriptions shipped first. *Inverted in step 14 — one-line descriptions are demonstrably better on AFM.*
12. ✅ **Cleanup task.** Launch-time `FrecencyTracker.pruneOldOpens(...)` runs once per app launch from `AppEnvironment`.
13. ⬜ **Device QA.** Real iPhone, real vault. All Phase-C deliverable bullets pass using the post-refactor `find` / `read` surface. *Simulator QA done against a real vault; physical-device pass still pending.*
14. ✅ **AFM-realistic tool consolidation.** Collapsed `SearchVaultTool`, `BrowseVaultTool`, `GetBacklinksTool` into [FindTool.swift](./Sources/Services/Tools/FindTool.swift); collapsed `ReadNoteTool`, `ReadDailyNoteTool` into [ReadTool.swift](./Sources/Services/Tools/ReadTool.swift); deleted `CreateNoteTool`, `DateTimeTool`, `CalculatorTool`. Tool registry shrank from 8 to 2 — under TN3193's recommended 3–5 ceiling. All tool descriptions compressed to one sentence. Empty-state chips updated to match.
15. ✅ **Single tool call per turn.** [AgentService.swift](./Sources/Services/AgentService.swift) `TurnGuard` now hard-caps to `maxTotalCalls: 1` (single call). Multi-step intent ("find and read") becomes two user turns; the alternative was AFM speculatively chaining and overflowing context.
16. ✅ **Zero transcript replay.** [AppleFoundationRunner.swift](./Sources/Services/AppleFoundationRunner.swift) no longer replays prior turns into the FM transcript. Each user prompt is treated as a fresh session, in line with TN3193's "split a large task into multiple language model sessions." Trades pronoun follow-ups ("what does it say?") for predictable per-turn budgets.

#### Unplanned but completed during Phase C

The original Phase C plan assumed an 8-tool surface, browse pages of 25, transcript replay, and "claim every prompt shape" tool descriptions. Real-world simulator QA against an Obsidian vault made AFM's 4096-token ceiling the binding constraint and forced a series of corrections, culminating in the AFM-realistic refactor (steps 14–16 above). Companion fixes:

- **No-progress watchdog** in [AppleFoundationRunner.swift](./Sources/Services/AppleFoundationRunner.swift): if `streamResponse` produces no snapshot for 45s the runner emits an `inferenceStalled` error so the UI shows a red "Try again" row instead of staying on a stuck stop button. (Apple's FM inference host can die mid-generation on context overflow without throwing.)
- **`AgentError.humanize`** in [AgentService.swift](./Sources/Services/AgentService.swift): translates raw `LanguageModelSession.GenerationError` stringifications into user-actionable text (`"The model couldn't generate a response…"`, `"…too long for the on-device model…"`).
- **SwiftUI scroll-animation removal** in [ChatView.swift](./Sources/UI/ChatView.swift): per-token `withAnimation { scrollTo }` was triggering a `ViewLayoutEngine.sizeThatFits` layout cycle on long assistant messages, freezing the main thread. Bare `scrollTo` without animation is plenty for tail-following during streaming.
- **BM25 title weight bumped from 10 → 100** in [VaultIndex.swift](./Sources/Services/Vault/VaultIndex.swift): exact-title queries (e.g. searching for the literal title of a note) were being out-ranked by many short backlinking notes whose bodies mentioned the title. 100× restored title primacy.

---

## 11. Validation checklist

Before declaring Phase C done, every item below must be demonstrably true:

Updated post-AFM-realistic refactor — prompts now name `find` / `read` instead of the original 8 tools. Each test below should be run **in a fresh chat** (zero transcript replay means follow-ups inside the same chat don't help).

- [ ] On a fresh install: vault binds, scan completes, search returns BM25-ranked hits for any keyword present in the vault.
- [ ] On an upgrade from Phase B: existing DB migrates to v2, FTS5 table backfills, no data loss.
- [x] **Registry is exactly 2 tools.** `AppEnvironment.defaultTools(...)` returns `[FindTool, ReadTool]`. (`list_recent_notes`, `list_notes_by_tag`, `search_vault`, `browse_vault`, `read_note`, `read_daily_note`, `get_backlinks`, `create_note`, `datetime`, `calculator` all gone.)
- [x] **"What notes do I have"** routes to `find` (no args) → 10 recent notes. *(Verified in simulator QA against a real vault.)*
- [ ] **"List notes in my Projects folder"** routes to `find(folder: "Projects")` and returns only Projects/ notes.
- [ ] **"Show me my #project notes"** routes to `find(tag: "project")`; hierarchical children like `#project/work` are included by default.
- [ ] **"What have I been working on lately"** routes to `find` with no args (recency default).
- [ ] **"Find notes about productivity"** routes to `find(query: "productivity")`.
- [ ] **"What links to [[Master Branch]]"** routes to `find(linked_to: "Master Branch.md")` (model derives the path heuristically).
- [ ] **"Read Projects/Obelisk.md"** routes to `read(path: "Projects/Obelisk.md")` and returns the preview body.
- [ ] **"Open today's daily note"** routes to `read(daily: "today")` and returns the note (or `{ exists: false }` payload that the model paraphrases).
- [ ] **Single-tool-per-turn guard fires** when AFM speculatively chains: the second tool call comes back with the `TurnGuard.overBudget` amber row and the model proceeds to reply with the data it already has.
- [ ] Multi-word query like "productivity tips" returns notes where both words appear (AND first pass); if zero, returns notes where either word appears (OR fallback).
- [ ] Title hits rank above body-only hits for the same query.
- [ ] **Single-token typo**: "zetlekasten" (real note: "Zettelkasten") returns the right note. Vocab correction should rewrite it; if not, fuzzy fallback catches it. `SearchQuery.corrections` (logged in DEBUG) shows the rewrite when it happened.
- [ ] **Multi-token query with one typo**: "productiviy meeting notes" returns the same hits as "productivity meeting notes" — *not* zero.
- [ ] **Phrase typo bypass**: `"zetlekasten"` quoted returns zero (or only true substring matches) — phrases must not be vocab-corrected.
- [ ] **Short-token bypass**: a 3-char query like "cat" is not auto-corrected to "bat" or any other 3-char vocab word.
- [ ] **Cold start**: with an empty vocab cache (first query after launch), search still works — falls through to OR pass and fuzzy as needed without crashing.
- [ ] Opening a note via Sources card 5× and then searching for a term that returns that note + others ranks it visibly higher than before the opens.
- [ ] `obsidian://open?vault=…&file=…` deep links still work from the Sources card.
- [ ] FTS5 integrity check (`INSERT INTO notes_fts(notes_fts) VALUES('integrity-check')`) reports clean after a full scan.
- [ ] 20-minute mixed-usage soak: `find`, `read`, daily-note reads, change vault. No crashes, no slow queries (all under 200ms on a 5,000-note vault).

#### Superseded by the AFM-realistic refactor (do not re-test)

- ~~"What links to X" routes to `get_backlinks`~~ → now `find(linked_to: …)`.
- ~~"Save / create a note" routes to `create_note`~~ → write path deferred to a future `write` tool.
- ~~Phase B regression pass on 13 items~~ → Phase B's tool surface no longer exists; replaced by Phase C's 2-tool surface and Phase C's validation list above.

---

## 12. Pitfalls

- **FTS5 token-escaping.** The most likely first crash. The model sends raw prose; SQLite throws on unescaped `:` or unmatched `"`. `QueryParser` must produce strings that always parse as valid FTS5. Build a unit test corpus of pathological queries before shipping.
- **Vocab-correction over-eagerness.** A too-generous edit-distance budget will rewrite legitimate proper nouns ("Obelisk" → "obvious") and erode user trust. The `distance ≤ floor(token.count / 4)` rule keeps correction conservative; revisit only with concrete user complaints.
- **Stale vocab cache.** If the cache isn't invalidated after upserts, brand-new tokens are treated as out-of-vocab and may get "corrected" away. Invalidation strategy: scanner pushes a `vocabDirty` flag on any non-trivial batch; the next `QueryParser.parse` call rebuilds before using. Avoid rebuilding on every keystroke.
- **`notes_fts_v` cost.** SQLite's `vocab='full'` aux table is a virtual table — `SELECT term FROM notes_fts_v` walks the FTS5 index. ~20ms for a 5k-note vault, but call it at most once per dirty cycle, never per query.
- **External-content FTS5 drift.** If the upsert path bypasses the triggers (e.g. raw SQL via `db.execute`), the FTS5 index goes stale. Centralize all `notes` writes through `VaultIndex.upsert` and forbid direct INSERTs in code review.
- **Frecency feedback loops.** A note opened by reflex stays on top forever, drowning fresh notes. The cap on `frecency_boost` (max +150%) plus 10-day half-life is the safety net. Watch for it during QA.
- **`tokenize='unicode61 remove_diacritics 2'` and CJK.** `unicode61` doesn't tokenize Chinese / Japanese / Korean well. Document this; switch to `trigram` tokenizer later if a CJK user complains.
- **Sample-vault drift on simulator.** The sample vault's `notes_fts` will need re-seeding after migration. Document in `make seed-vault` notes that schema changes require dropping the DB.
- **`note_opens` table size.** 90-day trim keeps it bounded but a heavy user could hit thousands of rows. INSERT cost stays cheap (single row, indexed); SELECT for frecency-per-path stays fast via `idx_note_opens_path`. Re-measure if it ever crosses 100k rows.
- **Browse `limit` runaway.** A model that asks for `limit: 1000` shouldn't blow context. Cap server-side at 50. Document in the tool description.

---

## 13. Hand-off to Phase D

What Phase D will inherit and what it must not break:

- **Tool surface is exactly `find` + `read`.** Any new agent capability must either ride one of these (preferred) or stay under the 3–5 tool ceiling AFM can route reliably. The simplest extension on the horizon is a `write` tool (see "Open dependencies" below) — that becomes tool #3, no further additions without an explicit budget discussion.
- The `note_opens` table is the project's first "user behavior" datastore. Phase D (voice) doesn't touch it directly, but if voice ever surfaces a "most-talked-about notes" list, it reads from here.
- `QueryParser` is a pure function — voice input that becomes a chat message routes through it the same as typed input. No phase-c-specific assumptions.
- The FTS5 schema is additive over Phase B's migration v1 — no Phase D migration needed unless voice introduces its own tables.
- All Phase C UI hooks live in the existing chat shell. Phase D's mic affordance lands next to the existing input row without touching search/browse code.

### Standing AFM discipline rules

These were learned the hard way during the Phase C refactor and apply to **every future tool / prompt addition** until a second `LLMRunner` (with a wider context window) ships:

1. **Tool budget: 3 max, 5 hard ceiling** (TN3193). Adding a tool requires deleting / merging another, not just appending.
2. **One-line tool descriptions.** No claim-stacking, no "use this when…" overlap.
3. **One tool call per assistant turn.** Enforced in `AgentService.TurnGuard`. Multi-step intent becomes multi-turn dialog.
4. **Zero transcript replay.** Each user prompt is a fresh session to FM. If a feature *requires* memory of prior turns, build it on top of router/worker session splitting (TN3193), not by re-enabling replay.
5. **Prefer pre-routing over agentic routing for unambiguous intents.** If a user prompt has exactly one reasonable tool call (e.g. "open today's daily"), detect in Swift, run the tool, inject the result into the prompt, and call FM with *no tools registered* for that turn.
6. **Keep tool payloads small.** No snippets, no duplicated rows, no debugging metadata. The model only needs enough to either reply or call a follow-up tool.

### Open dependencies into later phases

- **`write` tool.** Phase B originally shipped `CreateNoteTool`; it was removed during the AFM-realistic refactor. Phase E (capture / Share Sheet / `obelisk/inbox/`) implicitly needs a write path. Bring it back as the third tool (`write(path?, title?, body, mode: create|append|replace, folder?)`), still well inside the 3–5 ceiling. The "do no harm" rules in [roadmap.md §"The 'do no harm' rules for vault writes"](./roadmap.md) all carry forward verbatim.
- **Conversation history.** Voice (Phase D) makes follow-ups ("read it", "more") natural again. Zero transcript replay doesn't fit that. The clean solution per TN3193 is router/worker session splitting (session A picks tool + args, Swift runs it, session B narrates with the tool result inlined). Worth piloting before voice ships.
- **Second `LLMRunner`.** Phase F's Settings model picker is "deferred until a second `LLMRunner` exists." If AFM remains the only backend, several of these discipline rules become permanent rather than temporary.
