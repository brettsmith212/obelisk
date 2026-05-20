# Obelisk

**A private, on-device AI companion for Obsidian on iPhone.**

Obelisk connects to your existing Obsidian vault and uses Apple's on-device Foundation Models to answer questions about your notes, search across them, summarize, capture new thoughts, and produce daily/weekly digests — without per-request fees and without sending your notes to any cloud service.

## Why

Existing Obsidian AI plugins on iPhone either route to paid cloud APIs (OpenAI, Anthropic) or don't work at all (Ollama can't run on iOS; the plugin sandbox can't host native ML inference). Obelisk is a sibling app — not a plugin — built around Obsidian's structure (vault layout, wikilinks, frontmatter, tags, daily notes) on top of the best on-device model the phone has.

## Status

Early. Currently scaffolding **Phase A** (text-only chat agent with tool calling). See [roadmap.md](./roadmap.md) for the full phase plan and [ui-spec.md](./ui-spec.md) for the design language.

## Requirements

- iPhone 15 Pro or newer (Apple Intelligence + memory headroom)
- iOS 26+ (Foundation Models framework)
- An Obsidian vault

## What it is not

- **Not an Obsidian replacement.** Obsidian edits notes; Obelisk reasons about them.
- **Not an Obsidian plugin.** Sibling app operating on the same vault folder.
- **Not a cloud service.** All inference runs on-device.
- **Not a frontier-quality reasoner.** A local ~3B model is weaker than GPT-4 / Opus. The bet is privacy + vault context, not raw capability.

## Development

Built from Neovim + shell using XcodeGen, xcode-build-server, and sourcekit-lsp. The [Makefile](./Makefile) is the single entry point — see [AGENTS.md](./AGENTS.md) for the command reference.

```bash
make gen   # generate Obelisk.xcodeproj from project.yml
make run   # build + install + launch on the iOS Simulator
make test  # run tests
```
