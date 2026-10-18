# Usage

## Keyboard

| Key | Action |
| --- | --- |
| Left / Right (or Up / Down) | Move between wallpapers, wrapping forever |
| Space | Expand the centred card into the preview, or collapse it |
| Enter | Apply the centred wallpaper and close |
| Escape | Close without changing anything |

Keyboard only, by design. Applying goes through the public AppKit API, so it persists across
reboots. History is recorded only *after* the desktop actually changed.

**Note:** macOS keeps the desktop picture **per Space**, so an apply changes the Space you are
looking at. See [Wallpapers and Spaces](SPACES.md).

## Commands

```text
walle                       Open the picker. A bare "walle" does the same.
walle pick                  The picker, spelled out.
walle set <path>            Apply one specific file.
walle set --last            Re-apply the most recent one that still exists.
walle set --dry-run ...     Show what would be applied, change nothing.
walle next                  Apply the next wallpaper in the library.
walle prev                  Apply the previous one.
walle random                Apply a random one.
walle current               Print the current desktop wallpaper.

walle list                  List the wallpapers that were found.
walle dirs                  Show the configured directories and their counts.
walle add <path>            Add a directory (created if it does not exist).
walle remove <path>         Remove a directory from the list.
walle use <path>            Replace the whole list with one directory.
walle dir list|add|remove|use   The same four commands, spelled out.
walle cache [--prune|--rebuild]

walle history [--limit N] [--clear]

walle spaces                Show the mode, the live Spaces and the stale entries.
walle spaces on             Every wallpaper you pick goes to every Space from now on.
walle spaces off            Only change the Space you are on (the default).
walle spaces all            Copy the current wallpaper onto every Space now.
walle spaces all --prune    Also drop entries for Spaces you deleted.
walle spaces all --dry-run  Show what a sync would change, write nothing.

walle config list|get|set|unset|edit|path
walle doctor                Check the install end to end.
walle version               Print the version (also --version).
walle help
```

## Choosing a wallpaper

- `walle set <path>` applies exactly that file, whether or not it is in the library.
- `walle next` / `prev` walk the scanned library in its sort order and wrap forever. They start
  from the last wallpaper walle applied (recorded in its state file), so they line up with what you
  last picked here rather than with a change made elsewhere.
- `walle random` picks one with a fresh seed each run.
- `walle set --last` re-applies the newest history entry whose file still exists.
- `--dry-run` prints the chosen path and exits; it never launches the picker.
- `apply_to` and `fill_mode` (see [Configuration](CONFIGURATION.md)) control which screens are
  changed and how the image is fitted.

## JSON, options and exit codes

Most commands accept `--json` for machine-readable output. `list` also takes `--limit N`,
`--sort name|mtime|random` and `--dir PATH`.

```text
0   applied / ok
1   error
2   picker dismissed with Escape
3   another picker is already running
```

`walle` writes its own output to stdout and warnings to stderr. `--help` works on every
subcommand (`walle list --help`).

## History

History is append-only newline-delimited JSON in `~/Library/Application Support/walle/history.jsonl`
(or under `XDG_DATA_HOME`). `walle history` shows newest first; `--limit N` reads only the tail;
`--clear` empties it.

## Environment

| Variable | Effect |
| --- | --- |
| `WALLE_CONFIG` | config file (default `~/.config/walle/config`) |
| `WALLE_DATA_DIR` | state, history and the picker lock |
| `WALLE_CACHE_DIR` | thumbnail cache |
| `WALLE_PICKER` | explicit path to `walle-picker` |
| `WALLE_WALLPAPER_STORE` | test only: use a copy of the Space store and never touch the live one |
| `XDG_CONFIG_HOME` / `XDG_DATA_HOME` / `XDG_CACHE_HOME` | standard overrides when the `WALLE_*` ones are unset |

See [Wallpapers and Spaces](SPACES.md) for the store override and [Development](DEVELOPMENT.md) for
the build environment.
