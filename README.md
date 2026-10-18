# walle

**A Linux-style wallpaper picker for macOS.**

If you have used hyprpaper, swww, swaybg, or one of the Quickshell wallpaper pickers on Hyprland,
Sway or Niri, this is the macOS equivalent. Press a hotkey and a row of slanted wallpaper cards
appears over your desktop; move with the arrow keys; press Enter and it becomes your wallpaper,
permanently.

- **Two small binaries** — 524 KB and 640 KB, no dependencies, nothing installed at runtime
- **No UI besides the picker** — no dock icon, no menu bar item, no preferences window
- **No background process** — zero processes and zero CPU when the picker is closed
- **Keyboard first** — configured from the command line, driven from the keyboard
- **Quick** — ~130 ms from hotkey to window, ~95 MB while open

![The resting row: five slanted wallpaper cards, the centred one taller and outlined in orange](docs/resting.gif)

Pressing Space straightens the centred card into an undistorted preview; the second recording is
[here](docs/preview.gif).

### Coming from a Linux setup

| On Hyprland / Sway / Niri you would use | Here |
| --- | --- |
| `swww img <file>`, `hyprctl hyprpaper wallpaper …` | `walle set <file>` |
| a rofi / walker / Quickshell picker | `walle`, or a hotkey bound to it |
| a keybind that steps to the next wallpaper | `walle next` / `walle prev` / `walle random` |
| `~/.config/hypr/hyprpaper.conf` | `~/.config/walle/config` |
| `swww-daemon` and friends | nothing — no daemon runs at all |

## Install

macOS 14 or later, Xcode or the Command Line Tools, and
[skhd](https://github.com/koekeishiya/skhd) if you want a global hotkey.

```sh
git clone https://github.com/AdvayGujar/walle.git
cd walle
./scripts/install.sh                 # builds, installs, and links ~/.local/bin/walle
walle add ~/Pictures/Wallpapers      # or any directory of images
walle cache                          # optional, but makes the picker open instantly
```

A bare `walle` opens the picker — that is what a hotkey should run. `walle doctor` checks the
install end to end. Packaging (`--prefix`, `--packager`), the skhd Accessibility setup, and every
installer flag are in **[docs/INSTALL.md](docs/INSTALL.md)**.

## Using it

| Key | Action |
| --- | --- |
| Left / Right (or Up / Down) | Move between wallpapers, wrapping forever |
| Space | Expand the centred card into the preview, or collapse it |
| Enter | Apply the centred wallpaper and close |
| Escape | Close without changing anything |

```sh
walle                      # open the picker
walle next | prev | random # apply the next, previous or a random wallpaper
walle set <path>           # apply one file; --last re-applies the newest that still exists
walle current              # print the current desktop wallpaper
walle list | dirs          # what was found, and where
walle add | remove | use   # change the directory list
walle cache [--prune|--rebuild]
walle spaces [on|off|all] [--dry-run] [--prune]
walle config list|get|set|unset|edit|path
walle history [--limit N] [--clear]
walle doctor
```

Every command, `--json`, and the exit codes are in **[docs/USAGE.md](docs/USAGE.md)**.

## Two pieces of macOS worth knowing

**Wallpapers are per Space.** The public API only writes the Space you are on, so that is what an
apply changes. `walle spaces on` makes every apply cover every Space; `walle spaces all --dry-run`
shows what that would do without writing anything. Details: [docs/SPACES.md](docs/SPACES.md).

**The config is a file.** `~/.config/walle/config`, plain `key = value`, created once and then
authoritative. `walle config list` prints every current value. Details:
[docs/CONFIGURATION.md](docs/CONFIGURATION.md).

## Documentation

| | |
| --- | --- |
| [Install and packaging](docs/INSTALL.md) | build, prefixes, packager mode, hotkey |
| [Usage](docs/USAGE.md) | commands, JSON, exit codes |
| [Configuration](docs/CONFIGURATION.md) | every key, defaults, examples |
| [Wallpapers and Spaces](docs/SPACES.md) | per-Space behaviour, dry run, prune |
| [Troubleshooting](docs/TROUBLESHOOTING.md) | hotkey, focus, empty library, stale Spaces |
| [How it works](docs/HOW-IT-WORKS.md) | the two binaries, geometry, thumbnails |
| [Performance](docs/PERFORMANCE.md) | measurements and method |
| [Development](docs/DEVELOPMENT.md) | tests, tools, release process |

## Non-goals

No video or live wallpapers, no online search, no colour filtering, no menu bar item, no
auto-rotation daemon. Each would mean a permanently running process or a much larger surface.

## License

MIT — see [LICENSE](LICENSE).
