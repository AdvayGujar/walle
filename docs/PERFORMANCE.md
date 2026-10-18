# Performance

Measured on Apple silicon with a 1512×982 Retina display, a 13-image library and a warm thumbnail
cache:

| Metric | Value |
| --- | --- |
| `walle` binary, stripped | 524 KB |
| `walle-picker` binary, stripped | 640 KB |
| CLI start | ~9 ms (8.5 / 9.2 / 11.7 ms min/avg/max, 20 runs) |
| Picker: process start to window | ~120 ms (116–125 ms) |
| Peak memory | ~95 MB picker, ~8 MB CLI |
| Processes alive when closed | 0 |
| Thumbnail cache | 14 MB for 29 MB of source |

About 65 ms of the picker's cold start is the OS loading AppKit before any walle code runs, and about
22 MB of the memory is the full-screen Retina backing store needed to dim the screen. Both are
inherent to being a full-screen overlay. The rest of the memory is decoded thumbnails: this display's
card geometry needs roughly 2000-px thumbnails for the widest wallpaper, and several are resident at
once. The Spaces feature runs in the `walle` CLI process, not the picker, so it does not affect these
numbers.

## What is optimised

- **Scanning** reads directory metadata once per entry, skips the aspect-ratio read when the caller
  does not need it, and reads aspect ratios in parallel when it does. A synthetic 2 000-file
  `walle list` went from 0.53 s to 0.08 s.
- **The thumbnail cache** is built concurrently (one ImageIO pipeline per core), and its names use a
  table-driven hex encoder rather than 64 `String(format:)` calls.
- **The picker** decodes thumbnails off the main thread, coalesces duplicate in-flight requests,
  bounds the decoded-image cache to the visible row, and — on each animation tick — rebuilds only the
  cards whose silhouette changed. The animation clock is a display link, so it follows the display.
- **The CLI** loads only what a command needs: `set <path>` skips the library scan, `--last` reads
  the history tail, and `--random` draws one item instead of shuffling the library.
- **The Spaces sync** baselines the store's modification time before the picker starts and writes
  only after macOS's own write has landed; the fixed 0.4 s pause is skipped on that path. A no-op
  sync writes nothing and takes no backup.

## How these numbers were taken

Build the release tree with `./scripts/build.sh` and measure the binaries in `dist/`:

```sh
# CLI start (20 runs)
python3 - <<'PY'
import subprocess, time, statistics
times = []
for _ in range(20):
    start = time.perf_counter()
    subprocess.run(["dist/bin/walle", "--version"], stdout=subprocess.DEVNULL, check=True)
    times.append((time.perf_counter() - start) * 1000)
print(min(times), statistics.mean(times), max(times))
PY

# Window-up time
WALLE_TRACE=1 dist/bin/walle-picker --pick --run-for 400 2>&1 | grep 'window up'

# Peak RSS
/usr/bin/time -l dist/bin/walle-picker --pick --run-for 1200 2>&1 | grep 'maximum resident'
```

Treat the numbers as order-of-magnitude: they move with the display, the library and the cache.
Peak memory is dominated by the five visible thumbnails at the geometry's floor, so the widest
wallpaper in a library has a disproportionate effect on it.
