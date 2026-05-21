# Obelisk — Agent guidance

Obelisk is an iPhone app (Swift + SwiftUI, iOS 26+). The project uses **XcodeGen** (`project.yml` → `Obelisk.xcodeproj`) and **xcode-build-server** to keep sourcekit-lsp working from Neovim. Xcode is never used for editing.

## Always use the Makefile

The [Makefile](./Makefile) is the canonical driver. Do **not** invoke `xcodebuild`, `xcrun simctl`, or `xcodegen` directly — those calls bypass the `xcode-build-server parse -av` pipe and will silently break LSP.

| You want to… | Run |
|---|---|
| Build + install + launch on the sim (default workflow) | `make run` |
| Just regenerate the Xcode project (after editing `project.yml` or adding/renaming files in `Sources/`) | `make gen` |
| Regenerate project, then build/install/launch | `make gen run` |
| Build without launching | `make build` |
| Boot the sim + install the app without launching | `make install` |
| (Re)launch the already-installed app | `make launch` |
| Run tests | `make test` |
| Copy an Obsidian vault into the booted sim for Phase B dev | `make seed-vault VAULT=/path/to/your/vault` |
| Fix "LSP not resolving symbols" / empty `.compile` | `make refresh-lsp` (then restart nvim) |
| (Re)write `buildServer.json` for sourcekit-lsp | `make lsp-config` |
| Nuke `build/`, `.compile`, `.bsp` | `make clean` |

Override the simulator per-invocation: `make run SIM_NAME="iPhone 16"`. Default is `iPhone 17 Pro`.

## After making changes

1. Edited Swift source only → `make run`.
2. Added/renamed a file under `Sources/`, or edited `project.yml` → `make gen run`.
3. UI-affecting change → `make run`, then verify with the ios-simulator MCP (`mcp__ios_simulator__screenshot` or `ui_describe_all`). Do not ask the user to check the screen yourself.

## Project layout

```
obelisk/
├── project.yml              # XcodeGen spec — edit this, not the .xcodeproj
├── Makefile                 # Canonical build/run/test driver
├── Sources/                 # All Swift source
│   ├── ObeliskApp.swift     # @main App
│   └── ContentView.swift
├── roadmap.md               # Phase plan (Phase 0 → F)
├── ui-spec.md               # Design language + screen-by-screen UX spec
├── phase-a.md               # Active phase design doc
├── Obelisk.xcodeproj/       # Generated, gitignored
├── build/                   # DerivedData for sim builds, gitignored
├── .compile / .bsp/         # xcode-build-server state, gitignored
└── buildServer.json         # sourcekit-lsp bridge config, gitignored
```

`Obelisk.xcodeproj` is **generated** — never edit it by hand and never commit it.

## Reference docs

- [roadmap.md](./roadmap.md) — what gets built, in what order, with what tech.
- [ui-spec.md](./ui-spec.md) — visual language and per-screen UX. Defer to ChatGPT iOS behavior for anything unspecified.
