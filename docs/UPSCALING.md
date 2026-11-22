# Upscaling wallpapers

`walle upscale` sends wallpapers through a replaceable ML backend and writes HEIC copies.
The default backend is `walle-upscaler` with Real-ESRGAN **x4plus**; the picker, library,
apply and rotation code never learn which model or runtime is in use.

## Commands

```sh
walle upscale on                          # enable hidden cache; fill in background
walle upscale on --wait                   # enable; wait for the fill
walle upscale off                         # use originals again
walle upscale --refresh                   # fill missing cache entries
walle upscale --all                       # explicit export, whole library
walle upscale --dir ~/Pictures/MiniGT     # explicit export, one directory
walle upscale photo.jpeg                  # explicit export, one file
walle upscale --all --dry-run --json      # report only
```

Key options: `--model <name|.param>`, `--models <dir>`, `--scale 2|3|4`,
`--quality 0-1`, `--target display|WxH`, `--mode fill|fit|stretch`, `--upscaler <path>`,
`--tool <path>`, `--dry-run`, `--json`, `--force`.

## Automatic hidden cache

```sh
walle dir use ~/Pictures/Wallpapers
walle upscale on
```

`on` sets `upscale = on`, starts a detached cache fill and returns to the prompt
immediately. `--wait` blocks if you want to watch it. The source directory is untouched.

The cache lives under:

```text
~/Library/Application Support/walle/upscaled/cache/<model>/<WxH>/
```

- The picker shows and navigates the **source** paths; only the file handed to macOS is
  swapped for the cached HEIC. `walle current` reports the source path.
- While the fill runs, uncached images apply from source.
- When it finishes, the current source is quietly re-applied as its cached copy, unless
  the picker is open or the desktop was changed outside walle.
- New images and new directories are picked up by a detached refresh on picker open,
  `dir add`/`dir use`, or `walle upscale --refresh`. A change that arrives mid-fill leaves
  a pending marker; the running fill starts one more pass when it finishes.
- Deleted or changed sources are pruned on the next picker open or upscale run; their
  cached HEICs are deleted too.
- `off` applies originals again and does not cancel a fill already running. The cache stays
  on disk.
- Only one fill runs at a time (`upscale.lock`). The process exits when done; there is no
  daemon.
- The refresh log is `~/Library/Application Support/walle/upscaled/cache/refresh.log`.

Because there is no daemon, a new image is picked up on the next walle run (picker open or
`walle upscale --refresh`), not the instant it lands on disk.

## Backend setup

The default backend needs `upscayl-bin` and the x4plus model. It looks in this order:

1. `--tool` / `--models`
2. `upscale_tool` / `upscale_models`
3. `WALLE_UPSCAYL_BIN` / `WALLE_UPSCAYL_MODELS`
4. `~/Library/Application Support/walle/upscaler/upscayl-bin` and `.../upscaler/models`
5. `/Applications/Upscayl.app/Contents/Resources/...`
6. `upscayl-bin` on `PATH`

The easiest setup is:

```sh
brew install --cask upscayl
```

Or place the portable binary and `realesrgan-x4plus.{bin,param}` under
`~/Library/Application Support/walle/upscaler/` as shown above. Then:

```sh
walle upscale on
```

Config keys: `upscale` (`on`/`off`), `upscale_model` (default
`realesrgan-x4plus`), `upscale_command` (backend executable), `upscale_models`,
`upscale_tool`.

## Replacing the upscaler

The CLI writes a JSON job file and runs:

```text
walle-upscaler --job <job.json> --result <result.json>
```

The job lists `model`, optional `modelsDirectory`/`tool`, `quality`, `format: "heic"`,
the target size, and `jobs` with `{source, output, scale}`. The result lists each entry
with `status` (`ok`, `failed` or `skipped`), optional `width`/`height`, and an `error`.
The CLI verifies every `ok` output exists and is readable before recording it.

Any executable in any language can implement this contract. Point to it with `--upscaler`
or `upscale_command`, or replace the `walle-upscaler` binary. The default implementation
lives in `Sources/WalleUpscalerCore/` and `Sources/walle-upscaler/`; replacing it does not
touch the picker, library, history or Spaces code.

## Custom models

`--model <name>` uses `<models>/<name>.bin` and `.param`.
`--model path/to/model.param` uses the `.bin` beside it.
`--models <dir>` overrides the model directory. `walle config set upscale_model` and
`upscale_models` make the choice persistent.

## Model choice

`realesrgan-x4plus` was the best general compromise in a bake-off against NMKD
Superscale, NMKD Siax, 4xLSDIR and 4xNomos8kSC. Nomos8kSC looked slightly cleaner on
flat-shaded digital art but held less detail on architecture and product text, and had
more gradient noise. The earlier native/Lanczos/ML comparison is
[here](upscaling-ab-comparison.png).

## Runtime

Measured on an M1 Pro, one 1500×1000 source to 3000×2000:

- `walle-upscaler`: ~800 KB; `upscayl-bin`: ~27 MB; x4plus: ~32 MB
- Peak RSS: ~537 MB, plus GPU memory
- ~42 s per image; 22 images ~16 minutes
- HEIC output ~190 KB for the test product shot (PNG intermediate is temporary)
- `-t 256` was ~40 s; `-j` tuning and 2–3 concurrent processes did not help (the GPU is
  saturated). The default stays sequential.

The backend is inference-bound, so a wrapper rewrite does not help. The module boundary is
where a faster Core ML/Metal/remote backend can be dropped in later.

## Quality

ML upscaling can make a soft, clean 2× wallpaper meaningfully sharper. It can also invent
or distort fine text, faces, straight lines and texture, and it is not colour-managed for
wide-gamut/HDR sources. Inspect the result at 100%, especially logos, text and faces. A real
higher-resolution source is always better than any upscale.
