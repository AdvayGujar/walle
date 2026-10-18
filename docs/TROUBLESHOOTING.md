# Troubleshooting

Start with:

```sh
walle doctor
```

It checks the config, wallpaper directories, library, picker binary, thumbnail cache at the size the
picker will actually request, history, the Spaces store and the skhd setup. `ok` means it works,
`warn` is an advisory (a retired or misspelled config key, a partially built cache), and `fail` is
something actionable.

## The hotkey does nothing, or `skhd --reload` says "could not locate existing instance"

skhd is not running. It exits immediately without Accessibility permission, and launchd quietly
restarts it, so it looks alive while doing nothing. Its explanation is one line in a log:

```sh
cat /tmp/skhd_$(whoami).err.log      # "must be run with accessibility access! abort.."
```

Fix: `skhd --stop-service`, grant Accessibility as described in [Install](INSTALL.md), then
`skhd --start-service && skhd --reload`. A `brew upgrade skhd` loses the grant, so it has to be
removed and re-added in System Settings. `walle doctor` detects this.

## The picker flashes open and closes immediately

Two bindings in `~/.config/skhd/skhdrc`. Keep exactly one, then `skhd --reload`. The second instance
sees the single-instance lock held and asks the first to close, which looks like a flash.
`walle doctor` reports duplicate bindings.

## The picker opens but the keyboard does nothing

skhd is fine but the window is not key. walle asks for focus on launch; if another app steals it,
click once on the overlay. This is also why the picker is keyboard-only: there is no mouse fallback.

## No wallpapers appear

```sh
walle dirs     # the configured roots and how many images each holds
walle list     # every image found
```

A missing directory warns but does not stop the others being scanned. Check `wallpaper_dirs` in the
config and that the directories are readable. Hidden files, Finder-hidden files and the supported
image extensions (jpg, jpeg, png, heic, heif, avif, webp, tiff, tif, bmp, gif) are the filter.

## The cards look soft

The cache is probably built at a size this display no longer uses. `walle doctor` reports how many
thumbnails exist at the size the picker will request; if it is not all of them, run `walle cache`. If
the picker warns that `thumb_max_px` is below what the geometry needs, raise it and run
`walle cache --rebuild` — or restore the default with `walle config unset thumb_max_px`; the picker's
geometric floor always wins.

## History is empty

History is written only after the wallpaper actually changed, and a failure to write is reported
rather than swallowed. Check `walle current` and that the data directory is writable.

## Something looks wrong with the layout

These render offscreen and need no display:

```sh
walle-picker --snapshot /tmp/shot.png --collapsed
walle-picker --snapshot /tmp/mid.png --transition 0.5
walle-picker --snapshot /tmp/dbg.png --debug-tiles
walle-picker --dump-geometry --transition 0.5
```

`--debug-tiles` fills each slot with a flat colour so compositing order can be read objectively; see
[`tools/README.md`](../tools/README.md) for the text-based helpers. The geometry is a pure function
of `--transition`, so any frame can be reproduced exactly.

## Spaces

**Applying only changes the Space I am on.** That is macOS: the public API writes the current Space.
Run `walle spaces on` to make future applies cover every Space, or `walle spaces all` to sync now.
See [Wallpapers and Spaces](SPACES.md).

**Other desktops did not change.** Run `walle spaces` and look at the missing/stale entries.
`walle spaces all --dry-run` shows exactly what a sync would do. A missing entry for a live Space
means it has never been synced; `walle spaces all` creates it.

**Stale entries keep accumulating.** macOS never removes the entry for a deleted Space.
`walle spaces all --prune` drops them; without `--prune` they are only reported.

**The store is private state.** walle backs it up to `Index.plist.walle-backup` before writing and
restarts `WallpaperAgent` so the change is picked up. If a sync reports a warning, the wallpaper
apply itself still succeeded — the warning is only about the other Spaces.

## A config warning

`walle doctor` shows config warnings as advisories. A misspelled key is reported; a key that a newer
version has retired (`preview_max_px`, `type_to_filter`) is ignored quietly. Fix a typo with
`walle config edit` or `walle config set`; the edit rewrites only that line, so comments survive.

## Build problems

Use `./scripts/swift.sh` rather than bare `swift` — the wrapper redirects the SwiftPM and clang caches
into `.build` and disables SwiftPM's own sandbox. See [Development](DEVELOPMENT.md).
