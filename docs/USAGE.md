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
walle rotate [interval]     Apply the next one now, then every interval.
walle rotate --once         Apply one and exit.
walle upscale on|off        Cache ML copies in the background, or use originals.
walle upscale on --wait     Cache in the foreground and wait for it to finish.
walle upscale --refresh     Fill missing cache entries (also runs on picker open).
walle upscale <file>...     ML-upscale to HEIC; originals untouched.
walle upscale --all         Do that for every wallpaper in the library.
walle upscale --dir <path>  Do that for one directory.
walle upscale --model M     Use a different model; --models points at its directory.
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

## Rotation

`walle rotate [interval]` applies the next wallpaper immediately, then applies the next one every
interval until you stop it with Ctrl-C. It runs in the foreground: there is no daemon and no process
left behind after it exits.

```sh
walle rotate 10m                 # every ten minutes
walle rotate --interval 2h       # same thing, spelled out
walle rotate                     # uses rotation_interval (default 30m)
walle rotate --dry-run --once    # show the next choice without applying it
```

Intervals are `30s`, `10m` or `2h`; a bare number means seconds. `--once` applies one wallpaper and
exits, which is the daemon-free way to rotate on a schedule you already have (for example a launchd
`StartInterval` job).

Each step re-reads the wallpaper walle last applied rather than keeping its own position. Open the
picker while a rotation is running, choose a card, and the next step continues from that choice. A
step that comes due while the picker is open is skipped, so the rotation never changes the desktop
while you are choosing. Only one rotation can run at a time.

## Upscaling

`walle upscale` sends wallpapers through a replaceable ML backend and writes HEIC copies.
The default backend is `walle-upscaler` with Real-ESRGAN **x4plus**; the picker, library and
apply code do not depend on the model or runtime.

```sh
walle upscale --all                       # every wallpaper in the library
walle upscale --dir ~/Pictures/MiniGT     # one directory
walle upscale photo.jpeg                  # one file
walle upscale --all --dry-run --json      # report only
walle upscale --all --scale 2             # force a 2x pass
```

For transparent caching, use `walle upscale on`. It returns immediately after starting a
detached fill of a hidden cache under the app's data directory; the picker applies the
cached HEIC while still showing your source paths. While the fill runs, uncached images
apply from source. New images and newly added directories are picked up by a detached
refresh on the next picker open, `dir add`/`dir use`, or `--refresh`; deleting a source
directory prunes its cached copies. When the fill finishes, the current source is quietly
swapped to its cached copy. `walle upscale --wait` keeps the old blocking behaviour.
`walle upscale off` uses originals again.

Explicit exports go to `~/Library/Application Support/walle/upscaled/ml/<model>/<WxH>/`
by default, with a `manifest.json` that makes reruns skip unchanged files. Point walle at
it with `walle add` or `walle use`. The backend needs `upscayl-bin` and the x4plus model;
the recommended setup, custom models, the module contract, runtime measurements and
quality caveats are in [Upscaling](UPSCALING.md).

## JSON, options and exit codes

Most commands accept `--json` for machine-readable output. `list` also takes `--limit N`,
`--sort name|mtime|random` and `--dir PATH`.

```text
0   applied / ok
1   error
2   picker dismissed with Escape
3   another picker, rotation or upscale is already running
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
