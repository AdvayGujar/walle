# Development

## Commands

```sh
./scripts/swift.sh test              # 152 tests in 14 suites
./scripts/swift.sh build -c release
./scripts/build.sh                   # release + dist/Walle.app + strip
./scripts/install.sh                 # build, install, link
./scripts/clean.sh                   # reclaim .build (100+ MB of intermediates)
./scripts/walle <args>               # run the repo-local build
```

Use `./scripts/swift.sh` rather than bare `swift`. It redirects the SwiftPM and clang caches into
`.build` and passes `--disable-sandbox`, because SwiftPM's own sandbox cannot nest inside a sandboxed
environment and the default cache locations may not be writable. Bare `swift` can fail with
`sandbox_apply: Operation not permitted`. Set `WALLE_SWIFT_TAG` to isolate `.build` scratch/cache
directories when running several builds at once.

## Tests and layout

`WalleCore` is Foundation-only and fully covered — config, geometry, scanning, thumbnails, history,
the CLI contract and the Spaces store. `WalleKit` is AppKit and has no test target; the offscreen
diagnostics below are the substitute. The source layout is in
[How it works](HOW-IT-WORKS.md#source-layout).

## Offscreen diagnostics

```sh
P=.build/scratch/release/walle-picker
"$P" --snapshot /tmp/shot.png --width 1512 --height 982
"$P" --snapshot /tmp/mid.png --transition 0.5
"$P" --snapshot /tmp/dbg.png --debug-tiles
"$P" --dump-geometry --transition 0.5
```

`--debug-tiles` plus the helpers in [tools/](../tools/README.md) is how compositing order inside an
overlap is read objectively rather than by eye. When changing rendering, compare warm-cache snapshots
against a baseline binary; a cold cache renders the freshly generated image, so a cold run and a warm
run legitimately differ.

## Release process

The version lives in exactly one place, `Sources/WalleCore/WalleVersion.swift`. `scripts/build.sh`
reads it, stamps `Walle.app/Contents/Info.plist`, and fails if the built binary does not report the
same version.

1. Update `WalleVersion.string` and add a section to [`CHANGELOG.md`](../CHANGELOG.md).
2. Run the tests and `./scripts/swift.sh build -c release`.
3. Run `./scripts/build.sh` and check `dist/bin/walle --version`.
4. Smoke the release: `walle doctor`, `walle spaces all --dry-run` against a store copy, and a warm
   `--snapshot`.
5. Stage an install into a throwaway prefix:
   `./scripts/build.sh --prefix /tmp/walle-<version>` and
   `./scripts/install.sh --packager --prefix /tmp/walle-<version>`; run the staged binary.
6. Merge to `master` with a merge commit (the history is kept linear-with-merges by convention) and
   create an annotated tag, e.g. `git tag -a v1.1.0 -m "walle 1.1.0"`.
7. Push the branch and tag, then publish the GitHub release from the tag. Attach a zipped
   `Walle.app` if you are offering a prebuilt download.
8. Update the Homebrew tap: in
   [AdvayGujar/homebrew-tap](https://github.com/AdvayGujar/homebrew-tap) `Formula/walle.rb`, set
   `url` to the new tag archive and `sha256` to `shasum -a 256` of it. Verify with
   `brew install --build-from-source AdvayGujar/tap/walle` and `brew test walle`.

### Repository topics

GitHub topics are what make the project findable; they are repository settings, not files. With the
GitHub CLI authenticated as the owner:

```sh
gh repo edit AdvayGujar/walle \
  --description "A Linux-style wallpaper picker for macOS" \
  --add-topic macos --add-topic wallpaper --add-topic wallpaper-picker \
  --add-topic wallpaper-switcher --add-topic wallpaper-manager \
  --add-topic desktop-wallpaper --add-topic swift --add-topic appkit \
  --add-topic cli --add-topic skhd --add-topic keyboard-driven \
  --add-topic ricing --add-topic dotfiles --add-topic macos-app
```

The same is available in the repository's **About** panel on github.com. Keep the description short
and keyword-rich; it is indexed alongside the README and the topics.

## Conventions worth keeping

- The CLI never links AppKit; only `walle-picker` does.
- Geometry is a pure function of `transition`; add visual properties as functions of it, not as
  separately animated state.
- Cards are paths, not transforms; the mask, border and hit-test all use the same path.
- One thumbnail size class, with a floor derived from the geometry.
- Paint order is explicit so `--snapshot` matches the screen.
- Keep user-facing facts in one place: the README is a landing page, the `docs/` pages hold the
  detail, and `walle config list` / `walle help` are authoritative for their own surfaces.
