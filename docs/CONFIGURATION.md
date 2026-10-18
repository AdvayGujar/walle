# Configuration

`~/.config/walle/config` — plain `key = value`, one per line, `#` comments, no GUI. Geometry is in
design units for a 1920-wide screen and is scaled to your display automatically.

The file is written once by the installer and is authoritative from then on: changing a default in a
new version does not reach an existing config. That is deliberate — your settings survive upgrades.
Editing commands (`config set/unset`, `dir add/remove/use`) change only the line involved, so
comments, blank lines and your own key order survive too. A key that a newer version has retired is
ignored quietly; a misspelled key is still reported as a warning. `walle doctor` shows those as
advisories, not failures.

**`walle config list` prints the values in effect.** The table below is the same set, with what each
one does.

## Keys

| Key | Default | |
| --- | --- | --- |
| `wallpaper_dirs` | `~/Downloads/wallpaper` | colon-separated roots; a literal `:` is written `\:` |
| `recursive` | `true` | descend into subdirectories |
| `sort` | `name` | `name`, `mtime` or `random` |
| `design_width` | `1920` | screen width the design units are authored against |
| `slots` | `5` | cards in the row; must be odd |
| `card_width` | `280` | card width at the vertical centre |
| `card_height` | `420` | neighbouring card height |
| `card_gap` | `10` | gap between cards at rest |
| `selected_card_height` | `540` | height of the centred card while resting |
| `expanded_card_width` | `880` | preview rectangle width |
| `expanded_card_height` | `400` | preview rectangle height |
| `card_skew` | `-0.25` | lean; negative leans left, `0` is upright |
| `card_corner_radius` | `12` | constant across the morph |
| `card_border_width` | `3` | border on the selected card |
| `card_border_color` | `FF9F0A` | hex, `RRGGBB` |
| `row_center_y_frac` | `0.5` | row position, `0` = bottom, `1` = top |
| `dim_falloff` | `0` | per-step fade of the resting row; `0` = fully opaque |
| `dim_floor` | `0.35` | lowest alpha that fade reaches |
| `dim_alpha` | `0.35` | backdrop darkness |
| `expanded_neighbour_alpha` | `0.06` | opacity of everything but the preview |
| `animation_ms` | `350` | morph duration; a rotation step is capped at 260 ms |
| `expand_on_enter` | `true` | open resting rather than already expanded |
| `apply_to` | `all` | `all` screens, or the one under the pointer (`active`) |
| `fill_mode` | `fill` | `fill`, `fit`, `stretch` or `center` |
| `spaces` | `current` | `current`, or `all`: copy every apply onto every Space |
| `thumb_max_px` | `1600` | manual floor for thumbnail size; see below |
| `log_level` | `warn` | `silent`, `error`, `warn` or `info` |

Out-of-range values are clamped and reported as warnings rather than crashing the picker. `slots`
is forced odd (a true centre slot); an even library gets one extra slot, deliberately duplicating a
wallpaper on both sides of the centre.

## Some useful settings

```sh
walle config set card_skew -0.4            # more slanted
walle config set card_skew 0               # upright rectangles
walle config set animation_ms 180          # snappier
walle config set slots 7                   # more cards (must be odd)
walle config set apply_to active           # only the screen under the pointer
walle config set fill_mode fit             # show the whole image
walle config set dim_falloff 0.2           # fade the resting row
walle config set dim_alpha 0               # no backdrop dimming
walle config set log_level info            # report scan and cache detail
```

`walle config unset <key>` restores the current default; `walle config edit` opens the file in
`$EDITOR`; `walle config path` prints its location.

## Thumbnail size

You never need to set it. The picker derives what the cards need from their geometry, your display
and your widest wallpaper, and `walle cache` asks the picker for that value before building, so the
two always agree. There is one thumbnail size for every card: the cards are taller than they are
wide, so a landscape wallpaper is stretched in width, and using a smaller size for the resting row
was what made cards look soft.

`thumb_max_px` is only a manual floor if you want more resolution than the geometry requires. If it
is lower than the floor, the picker uses the floor and prints a warning. Raising it with
`walle config set thumb_max_px <value>` stops the warning but does not change the size used.

## Log levels

- `silent` — nothing but errors.
- `error` — errors only.
- `warn` (default) — warnings plus errors.
- `info` — adds scan/cache detail and status lines.

Errors always print, regardless of the level. The picker honours the same level for its warnings.
