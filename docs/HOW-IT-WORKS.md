# How it works

## Two binaries

`walle` is the CLI. It never links AppKit, so it starts in single-digit milliseconds. Anything that
needs the window server — the picker, applying a wallpaper, reading the current one — it hands to
`walle-picker`, the only binary that links AppKit and lives inside `Walle.app` with `LSUIElement`
set to stay out of the Dock.

The cost is one `exec` when a wallpaper is applied; the alternative would be loading AppKit into
every CLI invocation, which is tens of milliseconds and a much larger binary. Do not add an AppKit
import to `WalleCore` or `walle`.

## Geometry is one number

`LayoutEngine` (in `WalleCore`, no AppKit) maps a single `transition` value to every card's position,
size, skew and opacity. `0` is the resting row, `1` is the expanded preview, and every value between
is a valid frame. The animation moves that one number, which is why the shape cannot drift out of
sync with itself and why `--transition 0.5` renders a truthful midpoint.

The design units are authored for a 1920-wide screen and scaled by `screenWidth / design_width`, so
the composition scales with the display.

## Cards are paths, not transforms

A card is a parallelogram built as a `CGPath` (`CardPath`). The same path is the clip mask and the
border, and the wallpaper sits in an undistorted layer behind it. The shear is symmetric about the
vertical centre, and `LayoutEngine.contains` inverts exactly that, so hit-testing and drawing agree
even mid-morph.

Paint order is explicit: the on-screen compositor sorts by `zPosition`, but `CALayer.render(in:)`
paints in sublayer order. The cards are re-inserted back-to-front, so `--snapshot` matches the
screen.

## A rotating row is a carousel

Each card keeps its own wallpaper and slides into its neighbour's slot. During a rotation the cards
interpolate between the slot they came from and the slot they are going to; the card that enters from
off the end is pushed in from one pitch away. Getting the direction sign wrong is what makes the row
slide the wrong way and snap at the end.

## Thumbnails

The picker never decodes a full-resolution image. `ThumbnailCache` asks ImageIO for a thumbnail at a
bounded size, writes a JPEG into a content-addressed cache (SHA-256 of path, modification time and
size), and hands the decoded image back. There is one size for every card — the cards are taller than
they are wide, so landscape wallpapers are stretched in width — derived from the card geometry, the
display's backing scale and the widest aspect in the library. `walle cache` asks the picker for that
size so the cache it builds matches.

Decoding happens off the main thread; cache hits paint synchronously, misses are coalesced and
delivered on the main queue. The decoded-image cache is bounded to the visible row plus a couple of
sliding candidates.

## The picker session

A borderless window at screen-saver level overrides `canBecomeKey` (a borderless `NSWindow` refuses
key status by default, which is the classic reason a tool like this ignores the keyboard). Keys are
handled by one application-level monitor, so they work regardless of which view is first responder.
A display link drives the animation at the display's cadence; each tick rebuilds only the cards whose
silhouette actually changed.

## The Spaces store

Per-Space wallpapers live in a private plist. walle reads it, rewrites the entries, backs it up and
restarts `WallpaperAgent`. That is documented separately in
[Wallpapers and Spaces](SPACES.md), because the details and the failure modes are their own subject.

## Source layout

```text
Sources/WalleCore/     Foundation only, no AppKit, fully unit tested
  Config.swift         every tunable, key table, validation
  Layout.swift         SlotGeometry and LayoutEngine
  CardPath.swift       the card silhouette
  Carousel.swift       rotation slot arithmetic
  Library.swift        directory scan, sorting, aspect ratios
  Queue.swift          circular index arithmetic
  Thumbnails.swift     ImageIO thumbnails and the on-disk cache
  ThumbnailProvider.swift  decoded images, in-flight coalescing, async loading
  History.swift        apply history and picker state
  WallpaperStore.swift per-Space store (M7)
  CLI.swift            the command line surface
Sources/WalleKit/      AppKit: window, cards, corridor, the real setDesktopImageURL
Sources/walle/         CLI executable
Sources/walle-picker/  GUI executable (also has headless modes)
Tests/WalleCoreTests/  152 tests in 14 suites
scripts/               swift.sh, build.sh, install.sh, uninstall.sh, clean.sh
tools/                 offscreen geometry diagnostics
```

## Verifying without a display

`walle-picker --snapshot` renders the layer tree to a PNG, `--dump-geometry` prints the exact
rectangles, and `--debug-tiles` fills each card with a flat colour. Those plus the helpers in
[tools/](../tools/README.md) are how compositing and geometry are checked objectively.
