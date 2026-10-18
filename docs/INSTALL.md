# Install and packaging

## Requirements

- macOS 14 or later (developed on macOS 27)
- Xcode or the Command Line Tools
- [skhd](https://github.com/koekeishiya/skhd) if you want a global hotkey
- No runtime dependencies: both binaries are self-contained.

## Install

```sh
git clone https://github.com/AdvayGujar/walle.git
cd walle
./scripts/install.sh
```

`install.sh` builds the release binaries, assembles `Walle.app`, and stages it. By default:

- app: `~/.local/share/walle/Walle.app` (the picker, with `LSUIElement`)
- CLI: `~/.local/share/walle/bin/walle`
- link: `~/.local/bin/walle` → the CLI
- config: `~/.config/walle/config`, written once and never overwritten

If `~/.local/bin` is not on `PATH`, the installer prints the line to add.

Options: `--prefix DIR`, `--bin-dir DIR`, `--version VER`, `--no-config`, `--clean`, `--dry-run`,
`--packager`. Running the installer twice is safe.

## Point it at your wallpapers

```sh
walle add ~/Pictures/Wallpapers   # creates the directory if needed
walle dirs                        # what is configured, and how many images each holds
walle list                        # every image found
```

`wallpaper_dirs` is colon-separated; a literal colon is written `\:`. `recursive` defaults to
true. A missing directory warns but does not stop the others being scanned.

## Build the thumbnail cache

```sh
walle cache
```

Optional but recommended, so the picker never generates a thumbnail while opening. It asks the
picker for the size the current display needs, so there is nothing to tune. `walle cache --prune`
drops thumbnails whose source changed or vanished; `--rebuild` throws the cache away and starts over.

## Global hotkey (skhd)

1. `brew install koekeishiya/formulae/skhd`
2. Grant Accessibility: **System Settings → Privacy & Security → Accessibility**, click **+**,
   press **⌘⇧G**, type `/opt/homebrew/bin/skhd`, add it and switch it on. skhd exits before macOS
   can prompt, so it never appears on its own; a `brew upgrade skhd` loses the grant.
3. `skhd --start-service`
4. Add the binding **once** — two bindings make the hotkey run walle twice, and the second instance
   immediately closes the first:

   ```sh
   grep -q walle ~/.config/skhd/skhdrc || echo 'cmd + alt - w : ~/.local/bin/walle' >> ~/.config/skhd/skhdrc
   skhd --reload
   ```

5. `walle doctor` checks all of the above, plus config, library, cache and the Spaces store.

A bare `walle` opens the picker, which is what a hotkey should run. A macOS Shortcut can run
`~/.local/bin/walle` instead: no extra process, slightly slower launch.

## Packaging

`build.sh` and `install.sh` both take `--prefix DIR`. `install.sh --packager` keeps every write
inside that prefix — no `~/.local`, no `~/.config`, no `PATH` changes, no prompts, and never
`sudo`:

```sh
./scripts/build.sh --prefix "$(brew --prefix)/Cellar/walle/1.1.0"
./scripts/install.sh --packager --prefix /opt/homebrew/Cellar/walle/1.1.0
```

Build `--version VER` (or `WALLE_VERSION=VER`) stamps the app. It exists because a packager
building from a release tarball has no `.git`, so the tag cannot be read there. The version lives in
one place, `Sources/WalleCore/WalleVersion.swift`, and `build.sh` fails if the built binary does not
report the version it just stamped.

## Uninstall

```sh
./scripts/uninstall.sh
```

Use `--prefix` / `--bin-dir` to match a custom install; `--dry-run` prints what it would remove.
The config file is left alone.
