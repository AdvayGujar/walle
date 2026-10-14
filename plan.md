# walle — implementation plan

Lightweight macOS wallpaper switcher. Press a hotkey, an overlay shows an endless
horizontal queue of wallpaper tiles as parallelograms; the centred one is prominent
while neighbours dim and recede; the centred tile becomes a flat rectangle preview;
click applies it to the desktop permanently. No Dock icon, no window chrome, no GUI
for configuration — everything is CLI.

## Stack (decided)

| Choice | Value | Why |
| --- | --- | --- |
| Language | Swift 6 + AppKit, no SwiftUI | ~40-80 ms cold start, ~25 MB peak, no runtime dependency |
| Picker trigger | skhd (Homebrew tap) | Chosen by you; walle itself is 0 processes when closed |
| Config | plain `key = value` at ~/.config/walle/config | No TOML/JSON parser needed, hand-editable |
| Dependencies | none | No SwiftPM deps, no pip, no runtime installs |

## Build harness (already working)

`scripts/swift.sh` wraps `swift` and must be used for every build/test:

- redirects SwiftPM + clang caches into `.build/`, because the DSH workspace-write
  sandbox forbids writes to ~/Library and the shared module cache;
- passes `--disable-sandbox`, because SwiftPM's own `sandbox-exec` cannot nest
  inside the DSH sandbox (`sandbox_apply: Operation not permitted`).

Usage: `./scripts/swift.sh build` / `./scripts/swift.sh test`.

## Modules

Each module ends with a verification step and a stop for your approval.

| # | Module | Verification | Status |
| --- | --- | --- | --- |
| M1 | Scaffold, Paths, Config, Queue, Layout | `swift test` on config/queue/layout units | code green, tests pending |
| M2 | Library scan + thumbnail cache | `walle list`, `walle cache` against a real wallpaper dir | not started |
| M3 | History/state + setter + CLI | `walle dir add/list`, `walle set` changes the desktop | not started |
| M4 | Picker window + static tile corridor | `walle pick` shows parallelograms, no input yet | not started |
| M5 | Hover fly-to-centre, rectangle preview, input | interactive: hover, click, arrows, Esc | not started |
| M6 | Perf pass + install scripts + doctor + docs | cold start < 120 ms, RSS < 50 MB, `walle doctor` | not started |

## M1 in detail (current)

Files:

- `Package.swift` — targets WalleCore (Foundation only), WalleKit (AppKit),
  executables `walle` and `walle-picker`, test target WalleCoreTests. No dependencies.
- `Sources/WalleCore/Paths.swift` — resolves config/data/cache/log paths, tilde and
  XDG aware, every one overridable by `WALLE_*` env vars so tests never touch real
  user state.
- `Sources/WalleCore/Config.swift` — the full tunable set (geometry, depth, shear,
  preview budget, apply target, fill mode, thumbnails), parse/serialize/validate.
- `Sources/WalleCore/Queue.swift` — infinite circular indexing: wrap, effective slot
  count (clamps to library size), slot-to-index mapping.
- `Sources/WalleCore/Layout.swift` — pure geometry, the whole visual design:
  per-slot rect, z, zPosition, alpha, shear, plus point-in-parallelogram hit-testing.

Key geometry decisions encoded in `Layout.swift`:

- pitch `= tile_width * (1 - overlap)`;
- neighbours recede by `depth_step` in z with perspective `m34 = -1/perspective`,
  so convergence comes from real projection, not hand-faked x spacing;
- side alpha `= max(dim_floor, 1 - dim_falloff * |d|)`, scale `= scale_falloff^|d|`;
- centre slot: shear 0, rect from the aspect-fitted preview budget, zPosition on top;
- shear is a 2D factor: x displaced by `shear * (y - rect.minY)`, which is exactly
  what hit-testing inverts.

## Conventions

- WalleCore stays UI-free and fully unit-testable; AppKit lives only in WalleKit.
- Thumbnails never decode a full-size image: ImageIO thumbnails at 512 px (tiles) and
  1600 px (centre preview).
- All disk I/O via URL/FileManager; dedupe by canonical path and visited inode.
- Swift 6 language mode, @MainActor on AppKit types, Sendable actors for background work.

## Running log

- 2026-10-14 M1 scaffolded. Package builds green; 1 placeholder test passes.
  Sandbox workarounds established in `scripts/swift.sh`.
