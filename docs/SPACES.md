# Wallpapers and Spaces

**macOS stores the desktop picture per Space.** The only public API for setting it writes the Space
you are currently on, so applying a wallpaper changes the desktop you are looking at and leaves your
other Spaces alone. System Settings behaves in exactly the same way — this is not something walle
gets wrong.

If you would rather one wallpaper covered every Space, turn that on once:

```sh
walle spaces on     # every wallpaper you pick from now on goes to every Space
walle spaces off    # back to only changing the Space you are on (the default)
```

`spaces on` brings the Spaces you already have into line immediately and remembers the setting in the
config file as `spaces = all`. It covers every apply path: the picker (including the hotkey),
`walle set`, and `next` / `prev` / `random`.

## Reporting

```sh
walle spaces               # the mode, the live Spaces, and any stale entries
walle spaces all           # sync now, without changing the mode
walle spaces all --prune   # also drop entries for Spaces you have deleted
walle spaces all --dry-run # show what the sync would change, write nothing
```

`walle spaces` compares three things: the store's entries, the Spaces macOS actually has (from
`com.apple.spaces.plist`), and the default picture. It reports Spaces with no entry, entries for
Spaces that no longer exist, and whether every live Space shows the same picture.

## How the sync works

- It copies the wallpaper that was just applied, not the store's "default". Once each Space has its
  own entry, `setDesktopImageURL` updates only the current Space and leaves the default stale, so
  copying the default silently reverts what you picked.
- It rewrites each entry's `Default` node **and** its per-display `Displays` nodes. macOS renders a
  Space from the per-display entry when one exists; syncing only `Default` leaves the other desktops
  on their old picture.
- It watches the store's modification time, baselined before the picker starts, and writes only after
  macOS's own asynchronous write has landed. Writing first loses the race and the result is reverted.
- It backs the store up first (`Index.plist.walle-backup`) and restarts `WallpaperAgent` with
  SIGKILL so it cannot flush stale in-memory state over the file. The 0.4 s pause before the restart
  is kept for the manual `walle spaces on|all` commands; the apply path has already waited for the
  system write and skips it.
- A Space with no entry is created from the applied wallpaper. Nothing is ever removed unless you
  pass `--prune`.

`--dry-run` runs the same planning code and reports the same result without backing up, writing or
restarting anything. It is the safe way to check `--prune` before using it.

## The store

The file is private macOS state:
`~/Library/Application Support/com.apple.wallpaper/Store/Index.plist`. Its `Spaces` dictionary is
keyed by Space UUID; the empty-string key is a real Space (the first Space on the primary display),
not a fallback. Creating a Space makes macOS add an entry; deleting one leaves its entry behind
forever, which is why stale entries accumulate and why the sync compares the store with the live
Space list instead of trusting the store's keys.

Because this is private state, walle is defensive: it backs the file up before writing, reports a
missing or differently-shaped store rather than guessing, and never restarts `WallpaperAgent` when
`WALLE_WALLPAPER_STORE` is set (see below).

## Testing against a copy

Set `WALLE_WALLPAPER_STORE` to point every Spaces command at a copy of the store. In that mode the
live store is not touched and `WallpaperAgent` is not restarted, so it is safe to experiment:

```sh
cp ~/Library/Application\ Support/com.apple.wallpaper/Store/Index.plist /tmp/Index.plist
WALLE_WALLPAPER_STORE=/tmp/Index.plist walle spaces all --dry-run
```
