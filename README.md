# walle

A keyboard-driven wallpaper switcher for macOS. Press a hotkey, a row of slanted cards
appears over the desktop, pick one, and it becomes your wallpaper permanently.

There is no dock icon, no menu bar item, no preferences window and no background service.
When the picker is closed, walle uses zero processes and zero CPU. Everything is configured
from the command line.

---

## What it looks like

Two states, and it morphs between them.

**Resting (collapsed).** Five cards side by side, each a parallelogram leaning to the left.
They sit in a centred row, all fully opaque. The centred card is taller than the rest and
carries a thin orange border.

**Expanded (preview).** The centred card straightens into a plain rounded rectangle and
shows the wallpaper undistorted. It is deliberately *shorter* than its neighbours, which
slide outward and fade to 6% so the only thing you are looking at is the preview.

The morph animates width, skew and height together over 350 ms with an ease-out, which is
what makes it read as one shape changing rather than several properties changing at once.

---

## Requirements

- macOS 14 or later (developed and measured on macOS 27)
- Xcode or the Command Line Tools, for building
- **skhd** for the global hotkey, if you want one (see Install)

There are no runtime dependencies. No Homebrew packages, no Python, no SwiftPM
dependencies. The two binaries are self-contained.

---

## Install

### 1. Build and install

    git clone https://github.com/AdvayGujar/walle.git
    cd walle
    ./scripts/build.sh
    ./scripts/install.sh

`build.sh` compiles the release binaries, assembles `dist/Walle.app` and strips them.
`install.sh` copies everything to `~/.local/share/walle`, symlinks `walle` into
`~/.local/bin` and writes a default config if you do not have one.

If `~/.local/bin` is not on your `PATH`, the installer prints the exact line to add.

Useful flags:

    ./scripts/install.sh --prefix ~/somewhere --bin-dir /usr/local/bin
    ./scripts/install.sh --dry-run
    ./scripts/uninstall.sh

### 2. Point it at your wallpapers

    walle add ~/Pictures/Wallpapers

That creates the directory if it does not exist. Add as many as you like; `walle dirs` lists
them with image counts. To replace the list entirely:

    walle use ~/Pictures/Wallpapers

### 3. Build the thumbnail cache

    walle cache

Optional but recommended. It pre-renders one small and one large thumbnail per wallpaper
into `~/Library/Caches/walle`, so the picker never has to decode an image while it is
opening. Add `--prune` to drop cache entries whose source has been deleted.

### 4. Set up the hotkey

**Grant Accessibility first.** skhd aborts immediately without it; if it is already running
as a service, launchd silently restarts it, so it looks like it is running while doing
nothing and the hotkey never fires.

1. Install it:

        brew install koekeishiya/formulae/skhd

2. Add skhd to `System Settings → Privacy & Security → Accessibility`. Click **+**, press
   **⌘⇧G**, type `/opt/homebrew/bin/skhd`, add it and switch it on.

   skhd will not appear in that list by itself, because it exits before macOS can prompt. You
   have to add it by hand. If you later upgrade it with brew, the grant is lost and you must
   remove and re-add it.

3. Start it:

        skhd --start-service && skhd --reload

Then add the binding to `~/.config/skhd/skhdrc`:

    cmd + alt - w : ~/.local/bin/walle

Add it once. Two bindings mean the hotkey runs walle twice, and the second instance sees the
lock already held and closes the first, so the picker just flashes:

    grep -q walle ~/.config/skhd/skhdrc || echo 'cmd + alt - w : ~/.local/bin/walle' >> ~/.config/skhd/skhdrc
    skhd --reload

A bare `walle` with no argument opens the picker, which is exactly what a hotkey should run.

Finally, verify the whole chain:

    walle doctor

That checks the config file, the library, the picker binary, the thumbnail cache, the
history, whether skhd is installed, whether the binding exists **exactly once**, and whether
skhd is aborting for lack of Accessibility access. It exits non-zero if anything is wrong, so
it is usable from a script.

If you would rather not run skhd at all, a macOS Shortcut with a keyboard shortcut can run
`~/.local/bin/walle` instead. That adds no process whatsoever, at the cost of a slightly
slower launch.

---

## Using it

### Keyboard

| Key | Action |
| --- | --- |
| Left / Right (also Up / Down) | Move between wallpapers, wrapping forever in both directions |
| Space | Expand the centred card into the preview, or collapse it again |
| Enter | Apply the centred wallpaper and close |
| Escape | Close without changing anything |

The picker is keyboard only by design — there is no mouse interaction.

Applying writes the wallpaper through the public AppKit API, which persists across reboot
and Space changes. The change is recorded in the history only *after* it succeeds.

### Commands

Everything is `walle <verb>`.

    walle                       Open the picker
    walle pick                  Same thing, explicitly

    walle next                  Apply the next wallpaper
    walle prev                  Apply the previous one
    walle random                Apply a random one
    walle set <path>            Apply a specific file
    walle set --last            Re-apply the most recent one that still exists
    walle set --dry-run ...     Show what would be applied without applying it

    walle current               Print the current desktop wallpaper
    walle list                  List wallpapers in the configured directories
    walle history               Show recently applied wallpapers
    walle cache                 Build the thumbnail cache

    walle add <path>            Add a wallpaper directory
    walle remove <path>         Remove one
    walle use <path>            Replace the list with one directory
    walle dirs                  List the directories and their image counts

    walle config list           Print every setting
    walle config get <key>      Print one
    walle config set <key> <v>  Change one
    walle config unset <key>    Restore one to its default
    walle config path           Print the config file location
    walle config edit           Open it in $EDITOR

    walle doctor                Check the install, config, library and hotkey
    walle help                  Full help
    walle --version

Most commands accept `--json` for scripting, and `walle list` additionally accepts
`--limit N`, `--sort name|mtime|random` and `--dir PATH`.

Exit codes are stable: **0** success or applied, **1** error, **2** dismissed with no
selection, **3** already running.

---

## Configuration

`~/.config/walle/config`, a plain `key = value` file with `#` comments. No GUI.

### Geometry

All lengths are **design units for a 1920-wide screen** and are multiplied by
`scale = screenWidth / 1920` at layout time, so the whole composition scales with your
display instead of being pinned to one resolution.

| Key | Default | Meaning |
| --- | --- | --- |
| design_width | 1920 | The screen width the units below are authored against |
| slots | 5 | Cards in the row; must be odd so there is a true centre |
| card_width | 280 | Card width at the vertical centre |
| card_height | 420 | Neighbouring card height |
| card_gap | 10 | Gap between cards at rest |
| selected_card_height | 540 | Height of the centred card while resting |
| expanded_card_width | 880 | Width of the preview rectangle |
| expanded_card_height | 400 | Height of the preview rectangle |
| card_skew | -0.25 | Lean. Negative leans left. 0 is an upright rectangle |
| card_corner_radius | 12 | Corner radius, constant across the morph |
| card_border_width | 3 | Border on the selected card |
| card_border_color | FF9F0A | Border colour, hex |
| row_center_y_frac | 0.5 | Vertical position of the row, 0 = bottom |

### Appearance and motion

| Key | Default | Meaning |
| --- | --- | --- |
| dim_alpha | 0.35 | Backdrop darkness |
| dim_falloff | 0 | Per-step fading of the resting row. 0 means fully opaque |
| dim_floor | 0.35 | Lowest alpha the falloff will reach |
| expanded_neighbour_alpha | 0.06 | Opacity of everything but the preview while expanded |
| animation_ms | 350 | Duration of the morph and of a rotation step |
| expand_on_enter | true | Open in the resting state rather than already expanded |

### Behaviour

| Key | Default | Meaning |
| --- | --- | --- |
| wallpaper_dirs | ~/Downloads/wallpaper | Colon-separated roots |
| recursive | true | Descend into subdirectories |
| sort | name | name, mtime or random |
| apply_to | all | all screens, or only the one under the pointer |
| fill_mode | fill | fill, fit, stretch or center |
| thumb_max_px | 1600 | Thumbnail size, in pixels on the long side |
| preview_max_px | 1600 | Preview thumbnail size |
| type_to_filter | true | Reserved |
| log_level | warn | silent, error, warn |

Example:

    walle config set card_gap 40
    walle config set card_skew -0.15
    walle config set animation_ms 220

---

## Making it yours

Every visual and behavioural value is a config key, settable without rebuilding anything.
Changes take effect the next time the picker opens. Some starting points:

**Cards wider, narrower, more or less slanted**

    walle config set card_width 340     # wider
    walle config set card_width 120     # narrower
    walle config set card_skew -0.4     # more slanted
    walle config set card_skew -0.1     # almost upright
    walle config set card_skew 0        # perfectly upright rectangles
    walle config set card_gap 40        # more space between cards

`card_width` applies to both states: the resting row and the expanded card's neighbours.

**A different shape for the preview**

    walle config set expanded_card_width 1100
    walle config set expanded_card_height 620
    walle config set card_corner_radius 24
    walle config set card_border_width 6
    walle config set card_border_color 30D158    # green instead of orange

**Faster or slower motion**

    walle config set animation_ms 180    # snappier
    walle config set animation_ms 600    # more leisurely

`animation_ms` governs both the expand morph and the time taken by one arrow-key step.

**More or fewer cards on screen**

    walle config set slots 7     # must be odd, so there is a true centre

If your library is larger than `slots`, the cards always have somewhere to come from and the
rotation glides. If the library is smaller than or equal to `slots`, every wallpaper is on
screen at once, so the one that wraps has to jump from one end of the row to the other.

**Different placement and background**

    walle config set row_center_y_frac 0.35   # sit the row lower
    walle config set row_center_y_frac 0.7    # sit it higher
    walle config set dim_alpha 0              # no backdrop dimming at all
    walle config set dim_alpha 0.7            # very dark backdrop
    walle config set expanded_neighbour_alpha 0.3   # let neighbours show while expanded

**Bring back the fade across the resting row**

By default every card is fully opaque. If you prefer the outer ones dimmed:

    walle config set dim_falloff 0.2     # each step out fades by 20%
    walle config set dim_floor 0.4

**How the wallpaper is applied**

    walle config set apply_to active    # only the screen under the pointer
    walle config set apply_to all       # every screen (default)
    walle config set fill_mode fill     # fill the screen, cropping the overflow
    walle config set fill_mode fit      # show the whole image, with empty space
    walle config set fill_mode stretch  # distort to fit exactly
    walle config set fill_mode center   # no scaling, centred

**Library behaviour**

    walle config set sort mtime         # newest first
    walle config set sort random
    walle config set recursive false    # do not descend into subdirectories
    walle config set wallpaper_dirs ~/Pictures/Walls:/Volumes/Ext/Walls

**See what you have changed**

    walle config list                   # every key and its current value
    walle config path                   # where the file lives
    walle config edit                   # open it in $EDITOR

**Start over**

    walle config unset card_width       # restore one key to its default
    rm ~/.config/walle/config           # or throw the whole thing away

Every key and its default is listed under Configuration above, and the full list is always
available with `walle config list`.

### Previewing a change without opening the picker

`walle-picker` can render the row to a PNG offscreen, which is the fastest way to iterate on
the geometry:

    .build/scratch/release/walle-picker --snapshot /tmp/shot.png
    .build/scratch/release/walle-picker --snapshot /tmp/resting.png --collapsed
    .build/scratch/release/walle-picker --snapshot /tmp/mid.png --transition 0.5
    .build/scratch/release/walle-picker --dump-geometry

`--dump-geometry` prints every card's exact rectangle, width, height, skew and opacity as
text, which is often more useful than the picture.

---

## How it works

Two binaries, and the split is deliberate.

**`walle`** is the command line tool. It never links AppKit, so it starts in single-digit
milliseconds. Anything that needs the window server — changing the wallpaper, reading the
current one, showing the picker — it hands to the other binary.

**`walle-picker`** is the only part that links AppKit. It lives inside `Walle.app` with
`LSUIElement` set, which is what keeps it out of the dock and the application switcher.

The geometry lives in one place, `LayoutEngine`, which is pure and has no AppKit import at
all, so every rule about the card row is unit tested without a display. Crucially, the
geometry is a **continuous function of a single transition value**: 0 is the resting row, 1
is the expanded preview, and everything between is a valid frame of the morph. The animation
just moves that one number, which is why the shape cannot drift out of sync with itself and
why `--transition` can render any intermediate frame for inspection.

A rotating row is a carousel: each card keeps its own wallpaper and slides from the slot it
was in to the slot it is going to, rather than the pictures being swapped in place.

Cards are drawn as a `CAShapeLayer` path, not a shear transform. The same path is the clip
mask and the border, and the photo sits in an undistorted layer behind it — so the image is
never skewed, only cropped by the shape.

Thumbnails are generated with ImageIO at a bounded pixel size; a full-resolution image is
never decoded into memory.

### Repository layout

    Sources/WalleCore/     Foundation only, no AppKit, fully unit tested
    Sources/WalleKit/      AppKit: window, card layers, corridor view
    Sources/walle/         The CLI executable
    Sources/walle-picker/  The GUI executable
    Tests/WalleCoreTests/  Swift Testing suites
    scripts/               swift.sh (build wrapper), build.sh, install.sh, walle
    tools/                 Offscreen geometry diagnostics

---

## Performance

Measured on an Apple silicon Mac with a 1512×982 Retina display and a 5-image library.

| Metric | Value |
| --- | --- |
| `walle` binary, stripped | 392 KB |
| `walle-picker` binary, stripped | 523 KB |
| CLI start (`walle --version`) | < 10 ms |
| Picker: process start to window on screen | ~130 ms |
| Peak memory while the picker is open | ~47 MB |
| Processes alive when closed | 0 |
| Thumbnail cache | 2.3 MB for 38 MB of source images |

**Cold start, ~130 ms.** Roughly 65 ms of it is the operating system loading AppKit into the
process, before any walle code runs. The picker is the only binary that links AppKit and that
cost is not avoidable while it does. The rest is window creation at screen-saver level and
asking the window server to focus us, which we must do or the keyboard would not work.

**Memory, ~47 MB.** It breaks down as: 16 MB framework baseline, 22 MB for the full-screen
Retina backing store, and the remainder decoded thumbnails, window and layer overhead. The
backing store is simply the cost of dimming the whole screen.

The decoded-image cache is bounded rather than unbounded. At one point it was permitted to
grow to roughly 80 MB, and separately the picker preloaded oversized images for the centred
card and its two neighbours. Removing that preload and using one correctly sized thumbnail for
every card is what took this from 66 MB to 47 MB — while making the images *sharper*, because
the previous arrangement was serving the cards thumbnails that were far too small.

Both numbers are now inside the targets set at the start of the project (120 ms and 50 MB).

### Sizing thumbnails for your display

This is easy to get wrong, and the symptom is subtle: slightly soft images rather than anything
obviously broken. The cards are taller than they are wide, and a landscape wallpaper is
aspect-filled into them, so it is the image **width** that gets stretched. A card rendering at
654 x 850 points on a 2x display covers 1308 x 1700 device pixels, and to fill that a 16:9
image needs about 1700 x 16/9 — but since aspect-fill crops, what matters is the short side
covering the box height: about `850 * 16/9 = 1512` pixels on the long side.

For a 1512-wide screen at 2x:

| Card | Rendered box | Needs |
| --- | --- | --- |
| Collapsed centre | 654 x 850 px | ~1512 px |
| Collapsed neighbour | 606 x 662 px | ~1176 px |
| Expanded preview | 1386 x 630 px | ~1386 px |

So the default `thumb_max_px = 1600` covers a display up to roughly 1600 points wide. The
cards scale with the screen, so on a larger display raise it to match:

    walle config set thumb_max_px 2000
    walle cache --rebuild

**You do not have to get this right by hand.** The picker derives the minimum from the actual
card geometry, your display's backing scale and the widest aspect ratio in your library, and
uses that when it is larger than the configured value. It says so on stderr:

    walle-picker: thumb_max_px is 512 but these cards need 1837 on this display;
    using 1837. Run 'walle config set thumb_max_px 1837' and 'walle cache --rebuild' to match.

Do follow that advice. The picker will generate the larger thumbnails on demand and everything
will look right, but `walle cache` has been building the smaller ones, so the first open of
each wallpaper pays for a decode the cache was supposed to have paid already.

**A note on the config file.** `install.sh` writes one on first install, and from then on the
file is authoritative: changing a default in a new version does not reach a config that already
exists. That is deliberate, so customisations survive upgrades, but it does mean a value
written by an older build quietly persists after the geometry it was sized for has changed.
The automatic floor above exists precisely because that happened.

---

## Troubleshooting

**The picker opens but the keyboard does nothing.**

Different problem from the two above: skhd is working and walle is running, but the window is
not the key window. It must be key for the application to receive keystrokes, and walle asks
for focus on launch. If another app steals focus back, click once on the overlay and the keys
will start working. This is also what happens when walle is launched by something that does
not grant activation.

**The hotkey does nothing, and `skhd --reload` says "could not locate existing instance".**

That message means skhd is not running at all. The usual cause is that **skhd aborts
immediately without Accessibility permission** — it does not sit there waiting, it exits, and
if it was started as a service, launchd silently restarts it, so it looks like it is running
while doing nothing. Its one line of explanation goes to a log file:

    cat /tmp/skhd_$(whoami).err.log
    # skhd: must be run with accessibility access! abort..

`walle doctor` now reads that log for you and will report it.

To fix it:

1. Stop the crash-looping daemon first: `skhd --stop-service`
2. Open `System Settings → Privacy & Security → Accessibility`
3. Click **+**, press **⌘⇧G**, type `/opt/homebrew/bin/skhd`, add it, and switch it **on**
4. Start it again: `skhd --start-service && skhd --reload`
5. `walle doctor` to confirm

skhd does not appear in that list on its own, because it aborts before macOS can prompt. You
have to add it by hand. **If it still aborts after granting permission, remove it from the
list and add it again** — macOS caches the grant per binary and loses it when the binary is
replaced, which also happens after `brew upgrade skhd`.

**The picker flashes open and immediately closes when I press the hotkey.**

There is almost certainly more than one binding to walle in `~/.config/skhd/skhdrc`. Two
bindings mean the hotkey runs walle twice; the second instance sees the lock already held and
signals the first to close. Keep exactly one line:

    grep -v walle ~/.config/skhd/skhdrc > /tmp/skhdrc.new
    echo 'cmd + alt - w : ~/.local/bin/walle' >> /tmp/skhdrc.new
    mv /tmp/skhdrc.new ~/.config/skhd/skhdrc
    skhd --reload

`walle doctor` reports duplicate bindings rather than just checking that one exists.

**History is empty.**
walle writes history to `~/Library/Application Support/walle` only after the wallpaper has
actually changed, and it reports a failure rather than swallowing it. If you see a
permission warning on stderr, something is preventing that directory from being written.

**No wallpapers appear.**
Check `walle dirs` and `walle list`. Directories that do not exist produce a warning but do
not stop other directories being scanned.

**Thumbnails look stale after editing an image.**
Run `walle cache --prune`. Cache keys include the file's modification time, so edited
images are regenerated automatically; prune removes entries for deleted ones.

**Something looks wrong with the layout.**
`walle-picker --snapshot /tmp/shot.png` renders the row offscreen. `--transition 0.5` gives
you the middle of the morph, `--collapsed` the resting row, and
`walle-picker --dump-geometry` prints every card's exact rectangle, width, height, skew and
opacity as text.

---

## Development

    ./scripts/swift.sh test              # run the suite
    ./scripts/swift.sh build -c release  # release build
    ./scripts/clean.sh                   # reclaim disk

`scripts/swift.sh` must be used instead of bare `swift`. It redirects the SwiftPM and clang
caches into `.build` and disables SwiftPM's own sandbox, because those defaults are not
writable in every environment. It is harmless otherwise.

### Diagnostics

`tools/` contains the offscreen inspection tooling. See `tools/README.md`. The short version:

    .build/scratch/release/walle-picker --snapshot /tmp/shot.png --width 1512 --height 982
    .build/scratch/release/walle-picker --dump-geometry --transition 0.5
    .build/scratch/release/walle-picker --snapshot /tmp/dbg.png --debug-tiles

`--debug-tiles` fills each card with a distinct flat colour so the compositing order inside
an overlap can be read objectively rather than by eye. That is how a bug where the paint
order disagreed with `zPosition` was found and fixed.

---

## Non-goals

No video or live wallpapers, no online wallpaper search, no colour filtering, no dynamic
colour theming, no menu bar item and no automatic rotation daemon. All of those would mean
either a permanently running process or a much larger surface, and walle is deliberately
neither.

## License

MIT.
