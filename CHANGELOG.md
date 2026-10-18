# Changelog

Notable changes to walle. Versions follow semantic versioning.

## [1.1.0] — 2026-10-18

### Added

- `walle spaces on|all --dry-run` reports what a sync would change — including `--prune` — without
  backing up, writing or restarting anything.
- `walle doctor` now checks the thumbnail cache at the size the picker will actually request, and
  reports the `spaces` mode, the store (or a `WALLE_WALLPAPER_STORE` override) and stale Space
  entries.
- `walle list --json` reports every scanned root, including `--dir` roots.
- A CLI test suite covering option parsing, exit codes, `--json`, config and directory round-trips,
  dry-run selection, history and `doctor`. The suite is 152 tests in 14 suites.
- In-repo documentation under `docs/`; the README is now a landing page that links to it.

### Changed

- The library scan reads metadata once per entry, skips aspect ratios when the caller does not need
  them, and reads them in parallel when it does. `walle list` on a synthetic 2 000-file library went
  from 0.53 s to 0.08 s.
- `walle cache` scans the library once, builds thumbnails concurrently, and names cache files with a
  table-driven hex encoder.
- `walle set <path>` no longer scans the library; `--last` reads only the history tail;
  `--random` draws one item instead of shuffling.
- The picker decodes thumbnails off the main thread, coalesces duplicate requests, and bounds the
  decoded-image cache to the visible row.
- The animation clock is a display link and each tick rebuilds only the cards whose silhouette
  changed.
- The Spaces apply path baselines the store's modification time before the picker starts, skips the
  0.4 s pause before restarting `WallpaperAgent`, and takes a backup only when it writes. A no-op
  sync no longer copies the store.
- `config set/unset` and `dir add/remove/use` preserve comments, blank lines and key order.
- `log_level` has real levels (`silent`, `error`, `warn`, `info`), and `wallpaper_dirs` accepts
  `\:` for a literal colon and `\\` for a literal backslash.
- Retired config keys are ignored quietly instead of being reported as unknown.

### Fixed

- A deadlock when a chatty picker filled its stderr pipe before closing stdout.
- Space in the picker applied a wallpaper instead of toggling the preview (the view's duplicate key
  handler is gone; the application-level monitor is the single binding).
- A Space created during a sync kept the previous wallpaper when the applied path had not reached the
  store yet.
- `walle set --last` now stops at the first existing history entry.
- `walle doctor` no longer counts config warnings as failures.
- `walle list --json` omitted `--dir` roots from its `roots` field.

### Removed

- `preview_max_px` and `type_to_filter`. Both are retired: an old config keeps loading, and both are
  ignored quietly.
- Dead internal helpers, including the unused per-Space live-list duplicate (`legacyLiveSpaceUUIDs`),
  `syncIfEnabled` and the unused hit-testing API.

### Upgrade notes

- An existing config may keep retired keys; they do nothing and do not warn. A misspelled key still
  warns, and `walle doctor` shows it as an advisory.
- The thumbnail cache filename changed, so thumbnails regenerate once. Running `walle cache` or
  `walle cache --rebuild` is optional.
- The config file remains authoritative: new defaults do not reach an existing config. Use
  `walle config unset KEY` to restore one default.
- Existing thumbnail caches are safe to remove; the picker rebuilds what it needs.

## [1.0.0]

Initial release.
