# Upscaling low-resolution wallpapers on macOS

**Research for `walle` · 22 November 2026**

**Test machine:** Apple M1 Pro (14-core GPU), macOS 27.0.1 (build 26A434), Xcode 27 SDK. No source changes were made. Third-party tools were downloaded to `/tmp` and run from there; nothing was installed.

**Question:** when a wallpaper is smaller than the display, does macOS upscale it well, can a pre-upscaled copy look better, which tools are actually available on Apple Silicon, and what should `walle` do about it?

> **Implementation note (later):** option (b) below (vImage Lanczos) was removed after the
> A/B showed that ML gives the result users actually want. `walle upscale` now calls a
> replaceable `walle-upscaler` backend, defaults to Real-ESRGAN x4plus, and writes HEIC.
> See [`docs/UPSCALING.md`](../docs/UPSCALING.md). The rest of this document is the
> research trail that led there.

**Labels used below:** **Verified** = Apple/project documentation, source code, or a measurement I ran; **Unverified** = could not confirm from a primary source; **Judgement** = my assessment, not a fact.

---

## Executive summary

- **macOS does scale a small wallpaper up.** `fill` and `fit` ask for proportional scaling, `stretch` scales each axis independently, and only `center` is 1:1. Apple does **not** document the resampling filter, the colour-management path, or whether scaling happens at backing-pixel resolution. Treat native quality as **unverified** rather than assuming it is bad. ([`NSImageScaling`](https://developer.apple.com/documentation/appkit/nsimagescaling), [`setDesktopImageURL`](<https://developer.apple.com/documentation/appkit/nsworkspace/setdesktopimageurl(_:for:options:)>))
- **Non-ML pre-upscaling cannot add detail.** `sips`, Preview, Core Image and vImage are resamplers. vImage is the best documented option: Lanczos-3 by default, Lanczos-5 with `kvImageHighQualityResampling`. ([vImage docs](https://developer.apple.com/documentation/accelerate/kvimagehighqualityresampling)) The only way a pre-upscale improves perceived sharpness is if it beats the native filter and avoids a second resample; if macOS already uses a good filter, expect little or no gain.
- **Apple ships no super-resolution API or first-party model.** Core ML is a runtime; Apple's model gallery has classification, depth, segmentation and similar models, not image super-resolution. Vision is analysis, not synthesis. MetalFX is a real-time spatial upscaler for render frames, not a photo upscaler. ([Core ML models](https://developer.apple.com/machine-learning/models/), [Vision](https://developer.apple.com/documentation/vision), [MetalFX](https://developer.apple.com/documentation/metalfx))
- **Pixelmator Pro has ML Super Resolution and is now an Apple app**, but it is a paid GUI editor. It supports AppleScript/Shortcuts generally; Apple's current guide does not document a Super Resolution CLI or a stable batch action. ($49.99 one-time, or via Apple Creator Studio at $12.99/month or $129/year.) ([guide](https://support.apple.com/guide/pixelmator-pro/automatically-increase-image-resolution-pix1d6f0eac3/mac), [product page](https://www.pixelmator.com/pro/))
- **The practical open-source CLI route on Apple Silicon is Upscayl's newer `upscayl-bin`, not the old Real-ESRGAN portable build.** Both ship universal (`x86_64` + `arm64`) binaries and use Vulkan through MoltenVK; the `upscayl-ncnn` macOS build links MoltenVK statically (`USE_STATIC_MOLTENVK=ON`). ([upscayl-ncnn build docs](https://github.com/upscayl/upscayl-ncnn#macos), [MoltenVK](https://github.com/KhronosGroup/MoltenVK)) In my measurement the official Real-ESRGAN build took **36.6 s** to turn a 1512×982 photo into 3024×1964 on the M1 Pro, and **stripped the ICC profile** from the output. A later full-size 2× A/B showed that the 2022 Real-ESRGAN macOS build can produce **corrupted tiled output** (missing blocks, tile seams, `VK_ERROR_DEVICE_LOST` at large tiles); the 20251207 `upscayl-bin` with the same `realesrgan-x4plus` model was clean. See §4.5. ([Real-ESRGAN release](https://github.com/xinntao/Real-ESRGAN/releases/tag/v0.2.5.0), [Upscayl CLI release](https://github.com/upscayl/upscayl-ncnn/releases/tag/20251207-174704))
- **ML super-resolution is real but not magic.** It can make a soft, clean 1.5–2× photo look sharper and more detailed. It can also twist straight lines, invent foliage and texture, mangle small faces and text, amplify JPEG artifacts, and produce tile seams. Real-ESRGAN's own paper lists twisted lines, unpleasant GAN artifacts and out-of-distribution degradation as limitations. ([Real-ESRGAN paper §4.4](https://arxiv.org/abs/2107.10833))
- **Recommendation: do (a) + (b), not (c) or (d).** Document external ML tools, and add a small, opt-in `walle upscale` that uses vImage Lanczos-5 to write durable, display-sized copies under `~/Library/Application Support/walle/upscaled/`, leaving originals untouched. Do not bundle a Core ML model, and do not auto-shell out to Upscayl/Real-ESRGAN. Estimate: **1.5 days for a generate-only MVP, 2.5–3 days for generate + opt-in apply + prune.**

**Contents:** [1. Native macOS](#1-what-macos-does-natively-when-the-wallpaper-is-too-small) · [2. Apple-only options](#2-apple-only--built-in-options-on-current-macos) · [3. Third-party tools](#3-third-party-open-source-and-commercial-options-for-batchcli-on-apple-silicon) · [4. Quality reality check](#4-quality-reality-check-what-ml-super-resolution-actually-buys-you) · [5. Recommendation](#5-recommendation-for-walle) · [6. What to do today](#6-what-to-do-today) · [7. Open questions](#7-open-questions)

---

## 1. What macOS does natively when the wallpaper is too small

### 1.1 The API contract: it does scale

`NSWorkspace.setDesktopImageURL(_:for:options:)` takes a file URL and an options dictionary that "control how the image is scaled on the screen." ([Apple docs](<https://developer.apple.com/documentation/appkit/nsworkspace/setdesktopimageurl(_:for:options:)>))

The relevant options are:

| Option | Meaning | Source |
| --- | --- | --- |
| `imageScaling` | An `NSImageScaling` value. Defaults to `.scaleProportionallyUpOrDown`. | [Apple docs](https://developer.apple.com/documentation/appkit/nsworkspace/desktopimageoptionkey/imagescaling) |
| `allowClipping` | With proportional scaling, `true` fills the screen and may crop; `false` shows the whole image and may leave empty space. | [Apple docs](https://developer.apple.com/documentation/appkit/nsworkspace/desktopimageoptionkey/allowclipping) |

`NSImageScaling.scaleProportionallyUpOrDown` is documented as "Scale the image to its maximum possible dimensions while both staying within the destination area and preserving its aspect ratio." ([Apple docs](https://developer.apple.com/documentation/appkit/nsimagescaling)) That is exactly what `walle` uses for `fill` and `fit`; `stretch` uses `.scaleAxesIndependently`, and `center` uses `.scaleNone`. See [`NSWorkspaceSetter.swift`](../Sources/WalleKit/NSWorkspaceSetter.swift).

**Verified:** a small image is not left at 1:1 in fill/fit/stretch. It is scaled up by the wallpaper pipeline. In `center` mode it is not scaled at all.

**Unverified:** the actual filter. Apple's documentation says nothing about bilinear, bicubic or Lanczos; there is no public API to choose a filter; `WallpaperAgent` is private. I could not find an Apple statement or sample code that documents the resampling quality.

**Unverified:** whether the wallpaper is rasterised at the display's backing-pixel size (3024×1964 on this Mac) or at point size (1512×982) and then upscaled by the compositor. A Retina display needs the former for a 1:1 wallpaper, but Apple does not document it.

**Unverified:** colour management. The desktop pipeline accepts Display P3 and HDR images, but Apple does not document how it converts them, whether it preserves the ICC profile, or how it handles HEIC gain maps.

**Judgement:** modern macOS almost certainly uses a GPU compositor and at least bilinear filtering. It may use a better filter. Without an A/B test at native resolution, any claim that macOS "upscales badly" is speculation.

### 1.2 Is there any way to observe the native filter?

Not cleanly through public APIs. The desktop picture is drawn by private system processes, and `screencapture` gives you the composited result including windows, menu bar and colour management. You could set a test pattern, screenshot it, and compare it to candidate resamplers, but that changes the user's wallpaper and still cannot separate the wallpaper scaler from the compositor's colour conversion. I did not do that. Treat native filter quality as an open question.

### 1.3 Will pre-upscaling improve perceived sharpness?

**Judgement**, with the caveats above:

| Condition | Likely result |
| --- | --- |
| Source is ≥ display pixel size | Pre-upscaling is pointless; macOS will downsample. |
| Source is 1.2–2× below display size, clean, low-noise | A good Lanczos-5 pre-upscale may slightly improve edge definition if the native filter is weaker; if native is already good, little or no visible change. |
| Source is 2–4× below display size | Lanczos makes it smoother but cannot add detail. ML can add plausible detail, with artifact risk. |
| Source is blurry, heavily JPEG-compressed, or upscaled before | Both Lanczos and ML mostly enlarge the blur/artifacts. The Upscayl issue tracker has a real example of a user seeing "just bigger, no improvement" on a compressed image. ([issue #699](https://github.com/upscayl/upscayl/issues/699)) |
| Text, faces, fine line art | Generic photo SR models are risky; dedicated face/text models or leaving it alone may be better. |
| HDR/wide-gamut source | Pre-upscaling may flatten it to SDR or lose the profile. Verify before adopting. |

The key point: **resampling estimates missing samples; it does not recover frequencies that were never captured.** That is the Nyquist–Shannon sampling theorem, not a property of a particular filter. ([Shannon 1949](https://doi.org/10.1109/JRPROC.1949.232969)) A pre-upscale can change *which* interpolation kernel is used and avoid a second resample, but it cannot create true detail.

---

## 2. Apple-only / built-in options on current macOS

| Option | What it actually does | Quality ceiling | Scripting / CLI | Speed | Colour / format | Suitable for walle? |
| --- | --- | --- | --- | --- | --- | --- |
| `sips` | ImageIO resample (`-z`, `-Z`), format conversion, profile embedding | Resampling only; filter undocumented | Yes, `/usr/bin/sips`, batch over multiple files | Very fast (~0.09 s for 1.5→5.9 MP in my test) | Preserved sRGB and Display P3 in my tests; can write HEIC/JPEG/PNG | Good for docs and "today"; not a quality upgrade over native |
| Preview | GUI "Adjust Size" with "Resample image" | Resampling only; filter undocumented | No CLI; multi-select batch in one window | Interactive | Preserves profile in normal use (not formally documented) | Fine for a few images; not automatable |
| Photos | Crop, straighten, definition, sharpen, noise reduction; export size presets | No super-resolution; definition/sharpen are local contrast | GUI-first; no CLI for arbitrary resize | Interactive | Photos-managed | Not an upscaling route |
| Core Image `CILanczosScaleTransform` | Lanczos scale filter; "high-quality, scaled version" | Resampling only | Swift/Obj-C; no CLI | ~0.10 s for 1.5→5.9 MP in my test | Can preserve P3 **if** the `CIContext` is configured with the source colour space; a naive context lost P3 in my test | Usable, but vImage is simpler and documented |
| Accelerate / vImage | `vImageScale_ARGB8888`; Lanczos-3 by default, Lanczos-5 with `kvImageHighQualityResampling` | Best documented non-ML resampler | Swift/C; no CLI | ~0.049 s for 1.5→5.9 MP in my test | Preserved Display P3 when attached end-to-end; 8-bit ARGB path | **Best fit for a non-ML walle command** |
| MetalFX spatial scaler | Real-time spatial upscale of a Metal texture | No new detail; designed for antialiased, tone-mapped render frames | Metal only; no image-file API | GPU-fast, but setup/readback overhead | Perceptual/linear/HDR modes; output texture must be private storage | Not worth it for one-shot stills |
| Core ML / Vision | Runtime and analysis APIs; no Apple SR model | Depends entirely on a model you supply | Core ML APIs; no CLI | Model-dependent | Model-dependent | No turnkey Apple solution |
| Pixelmator Pro | ML Super Resolution; GUI; AppleScript/Shortcuts | ML detail synthesis; Apple claims "preserving sharpness and detail" | AppleScript/Shortcuts generally; no documented SR CLI | Interactive; not benchmarked | Colour-managed app; exports HEIC/PNG/JPEG | Paid external option; document it |
| macOS 26/27 new features | Photos Extend/Clean Up, Image Playground, Spatial Reframing | Generative editing, not resolution upscaling | GUI / app intents | Interactive | App-managed | Do not mistake these for SR |

### 2.1 `sips`

`sips` is the built-in "scriptable image processing system." Its man page documents `-z/--resampleHeightWidth`, `-Z/--resampleHeightWidthMax`, `-o`, format conversion and ICC profile embedding/matching. It does **not** document which resampling filter is used. ([`man sips`](x-man-page://sips) on macOS 27.0.1; Apple does not publish this man page at a stable public URL.)

What I verified locally:

- `sips -Z 1000` **does upscale** a 220×220 image to 1000×1000; it is not downsample-only.
- `sips -z 1964 3024` produced a 3024×1964 PNG from a 1512×982 sRGB JPEG in 0.09 s.
- The output kept `sRGB IEC61966-2.1`; a Display P3 source kept `Display P3`.
- It can write HEIC (`sips -s format heic`), which is useful for wallpapers.

**Judgement:** `sips` is excellent for "make a copy at the display size now" and for format/profile housekeeping. Because the filter is undocumented, do not describe its output as "Lanczos" in walle's documentation.

### 2.2 Preview and Photos

Preview has a proper batch resize UI: open multiple images in one window, select them, `Tools > Adjust Size`, choose dimensions or a percentage, optionally "Scale proportionally", and leave "Resample image" on. ([Apple Support](https://support.apple.com/guide/preview/crop-resize-or-rotate-an-image-prvw2015/mac)) The guide describes resampling but not the algorithm. It is a fine manual route for a handful of wallpapers, not a CLI.

Photos' documented editing tools are crop/extend, light/colour, definition, noise reduction, sharpen and vignette. ([Photos editing basics](https://support.apple.com/guide/photos/editing-basics-pht304c2ace6/mac), [definition](https://support.apple.com/guide/photos/adjust-definition-phtb151c05a0/mac), [sharpen](https://support.apple.com/guide/photos/sharpen-a-photo-phtba5e3cf7d/mac), [noise](https://support.apple.com/guide/photos/reduce-noise-phta85f0d224/mac)) None of these is super-resolution, and Photos is not a documented route for producing a larger-than-source wallpaper. I found no Apple documentation for an "Enhance" feature that increases pixel dimensions; the documented Enhance-style controls are tonal/colour adjustments.

### 2.3 Core Image: `CILanczosScaleTransform`

Core Image's Lanczos filter is documented as creating "a high-quality, scaled version of a source image"; `scale > 1.0` scales up, and `aspectRatio` adds horizontal scaling. ([Apple docs](<https://developer.apple.com/documentation/coreimage/cifilter-swift.class/lanczosscaletransform()>), [protocol](https://developer.apple.com/documentation/coreimage/cilanczosscaletransform))

It is a real Lanczos resampler, but **colour management is easy to get wrong**. In my test, the straightforward `CIContext()` + `createCGImage` path turned a Display P3 source into a `DeviceRGB` image and the PNG was written as sRGB. Configuring the context with the source colour space as both working and output space preserved Display P3. That is a code-quality trap, not a reason to reject Core Image, but it is a reason to prefer vImage for a small CLI.

Speed was ~0.10 s for 1512×982 → 3024×1964 on this machine.

### 2.4 Accelerate / vImage: the best documented non-ML option

Apple's vImage documentation is unusually explicit:

> "vImage uses Lanczos interpolation for resampling." ... "By default, vImage uses the Lanczos-3 algorithm for resampling. Set this flag to switch to the higher-quality Lanczos-5 algorithm."

([`kvImageHighQualityResampling`](https://developer.apple.com/documentation/accelerate/kvimagehighqualityresampling))

`vImageScale_ARGB8888` supports non-uniform scaling and takes a flags argument; `kvImageHighQualityResampling` selects the better filter. ([`vImageScale_ARGB8888`](<https://developer.apple.com/documentation/accelerate/vimagescale_argb8888(_:_:_:_:)>)) In my test it produced a 3024×1964 image from 1512×982 in **0.049 s**, and attaching the source `CGColorSpace` preserved Display P3.

Caveats:

- The 8-bit interleaved path is ARGB8888; alpha should be premultiplied or constant. For opaque wallpapers this is a non-issue.
- 16-bit, CMYK and HDR/EDR need different vImage formats or a conversion step. Treat those as out of scope for v1.
- vImage does **not** colour-manage; it scales the encoded values. That is actually desirable here: keep the source profile attached and let the display pipeline interpret it.
- It is a system framework (Accelerate), not a bundled dependency.

### 2.5 MetalFX spatial scaling

MetalFX is a real-time upscaler: "upscale every frame of your app's scene or rendering in real time" and "intentionally rendering to a lower resolution to save time before upscaling." ([`MTLFXSpatialScaler`](https://developer.apple.com/documentation/metalfx/mtlfxspatialscaler)) The WWDC22 session says spatial upscaling "only requires anti-aliased input colour" and works best after tone mapping in a perceptual colour space. ([WWDC22-10103](https://developer.apple.com/videos/play/wwdc2022/10103/))

Why it is a poor fit for still wallpapers:

- It is built for a render pass, not an image file. You must create a `MTLTexture`, encode a command buffer, and read the result back.
- The output texture must use `MTLStorageMode.private`, so saving it requires a blit/copy to a shared texture. ([`outputTexture`](https://developer.apple.com/documentation/metalfx/mtlfxspatialscalerbase/outputtexture))
- Scaler objects are expensive to create; Apple recommends creating them at launch or on display changes, not per image. ([WWDC22-10103](https://developer.apple.com/videos/play/wwdc2022/10103/))
- It is a spatial filter, not a learned super-resolution model. It cannot add detail that is not in the input.

**Judgement:** technically possible, but it adds a Metal pipeline and readback for no quality benefit over vImage on a still image. Skip it.

### 2.6 Core ML, Vision and Apple models

Core ML is a framework for running models; it does not include an image super-resolution model. ([Core ML](https://developer.apple.com/documentation/coreml)) Apple's public Core ML model gallery (checked November 2026) lists image classification, depth estimation, segmentation, object detection, text and similar models; it has no "super resolution" or "image upscaling" entry. ([Apple model gallery](https://developer.apple.com/machine-learning/models/))

Vision is described as "analyze image and video content ... object detection, text recognition, and image segmentation." ([Vision](https://developer.apple.com/documentation/vision)) There is no public `VN` request that synthesises a higher-resolution image.

So a Core ML route means bringing your own model:

1. Pick a model (Real-ESRGAN, SwinIR, etc.).
2. Convert it with coremltools. Conversion is a real project: tracing, op support, image input/output types, flexible shapes, and validation. ([coremltools guide](https://apple.github.io/coremltools/docs-guides/))
3. Decide the compute unit. Core ML can allow the OS to pick CPU, GPU or the Neural Engine (`MLComputeUnits.all`), but Apple does not guarantee that a given SR network maps well to the ANE. This needs measurement, not assumption. ([`MLComputeUnits`](https://developer.apple.com/documentation/coreml/mlcomputeunits))
4. Ship the weights. Real-ESRGAN's x4plus ncnn weights are ~32 MB; a Core ML conversion is in the same order of magnitude before compression. That is 16–32 MB of weights alone, 25–50× the size of `walle-picker`.

**Judgement:** the engineering cost and app-size cost are large, and the quality is the same model you could shell out to. Not a good trade for walle.

### 2.7 Pixelmator Pro "ML Super Resolution"

Pixelmator Pro is now an Apple app (App Store developer: Apple) and includes Super Resolution. ([App Store](https://apps.apple.com/us/app/pixelmator-pro/id1289583905))

- **How to use it:** open an image, choose `Image > Super Resolution` for automatic enlargement, or `Image > Image Size` and choose "Super Resolution" as the scaling algorithm to hit a specific size. ([Apple guide: automatic](https://support.apple.com/guide/pixelmator-pro/automatically-increase-image-resolution-pix1d6f0eac3/mac), [Apple guide: resize](https://support.apple.com/guide/pixelmator-pro/resize-an-image-pix1db05dd71/mac))
- **Quality:** Apple's wording is "preserving sharpness and detail" and "preserves sharpness and details intelligently." That is marketing copy; I did not run an independent quality comparison. The app does not document a maximum scale factor in the current guide.
- **Automation:** Pixelmator Pro has extensive AppleScript support and Shortcuts actions; Automator can drive the same AppleScript dictionary. ([AppleScript guide](https://support.pixelmator.com/faq-pixelmator-pro/advanced-workflows/advanced-automation-and-scripting-with-applescript), [Shortcuts/HDR guide](https://support.pixelmator.com/faq-pixelmator-pro/advanced-workflows/working-with-hdr-images-using-shortcuts)) However, Apple's current Super Resolution guide documents only the GUI command, not a CLI or a "Super Resolution" Shortcuts action. A scripted batch is therefore possible in principle but **not a documented contract**; test it against your installed version before relying on it.
- **Cost:** $49.99 one-time on the Mac App Store, or included in Apple Creator Studio at $12.99/month or $129/year. ([product page](https://www.pixelmator.com/pro/), [App Store](https://apps.apple.com/us/app/pixelmator-pro/id1289583905))
- **Colour:** Pixelmator is a colour-managed editor with documented colour-profile controls; it is a safer GUI route for P3/HDR than an ML CLI that strips profiles. ([colour management guide](https://support.apple.com/guide/pixelmator-pro/about-color-management-pix91010c515/mac))

**Judgement:** the best "Apple-owned, no-terminal" option for a handful of important wallpapers. It is not a walle dependency.

### 2.8 Anything new in macOS 26/27?

I found no public OS-level super-resolution feature in macOS 26 or 27. The macOS 27 feature page highlights Siri AI, Visual Intelligence, Liquid Glass refinements, Photos' Spatial Reframing/Extend/Clean Up, and Image Playground. ([macOS 27](https://www.apple.com/os/macos/)) Those are generative editing or image creation, not upscaling an existing photo to a higher resolution.

`Image Playground` creates new images from descriptions; it is not an upscaler. ([macOS 27](https://www.apple.com/os/macos/)) Photos' "Extend" expands the canvas with generated content; it does not increase the resolution of the existing pixels. ([Photos editing basics](https://support.apple.com/guide/photos/editing-basics-pht304c2ace6/mac))

**Verified negative (as of November 2026):** Apple's public documentation does not describe a built-in photo super-resolution command in Preview, Photos, `sips`, Core Image, Vision or Core ML. If a new feature ships later, this section will need revisiting.

---

## 3. Third-party open-source and commercial options for batch/CLI on Apple Silicon

| Tool | Install | CLI | Apple Silicon / GPU | Model size | Licence | Cost | Rough speed | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **Upscayl** (GUI) | `brew install --cask upscayl`, App Store, or DMG | No supported CLI in the GUI app; use `upscayl-bin` | Yes; Real-ESRGAN ncnn + Vulkan via MoltenVK | Models vary; bundled in app | AGPL-3.0 | Free | Interactive | Best GUI batch experience; macOS 12+; Vulkan GPU required |
| **upscayl-bin / upscayl-ncnn** | Portable zip | Yes (`-i`, `-o`, `-n`, `-s`, `-r`, `-f`) | Universal `arm64`; MoltenVK | No models in the CLI zip; supply `-m` | AGPL-3.0 | Free | Same engine as Real-ESRGAN | Output strips ICC in my test; app's model folder is the easy source |
| **Real-ESRGAN ncnn-Vulkan** | Portable macOS zip | Yes (`-i`, `-o`, `-n`, `-s`, `-f`) | Universal `arm64`; Vulkan/MoltenVK | 32 MB x4plus; 8.5 MB anime; 1.2 MB anime-video | BSD-3-Clause | Free | 36.6 s for 1.5→5.9 MP on M1 Pro | Default model is anime; specify `-n realesrgan-x4plus` for photos |
| **Real-ESRGAN (PyTorch)** | `pip install` + weights | Python script | CUDA-oriented; MPS is DIY | 64 MB+ checkpoints | BSD-3-Clause | Free | Slower; not packaged | `--outscale` does a final Lanczos resize; more flexible, more setup |
| **waifu2x-ncnn-Vulkan** | Portable zip | Yes | Universal; Apple Silicon listed | Small | MIT | Free | Fast | Anime/line art, not photographs |
| **Real-CUGAN-ncnn-Vulkan** | Portable zip | Yes | Universal; Apple Silicon listed | Moderate | MIT | Free | Fast | Anime-focused; README says early development |
| **SwinIR** | Python/PyTorch | Python script only | CUDA-oriented; MPS DIY | Model zoo varies | Apache-2.0 | Free | Research-grade, slow | Strong papers; no macOS CLI/package |
| **Topaz Photo** (formerly Photo AI) | App / `brew install --cask topaz-photo-ai` | No public CLI in current docs; GUI batch | Apple Silicon native | 88 GB free disk required | Commercial | $25/mo or $199/yr list; promo $21/$169 first year | Interactive | Dedicated Recover Faces / Preserve Text / Upscale; heavy install |
| **Pixelmator Pro** | Mac App Store | AppleScript/Shortcuts, no documented SR CLI | Apple Silicon native | App ~571 MB | Commercial | $49.99 or Creator Studio | Interactive | Apple-owned; ML Super Resolution; excellent colour management |
| **libvips / ImageMagick** | Homebrew | Yes | CPU; no ML | n/a | LGPL-2.1 / ImageMagick licence | Free | Very fast | Non-ML Lanczos; an external dependency walle should not take |

### 3.1 Upscayl and `upscayl-bin`

Upscayl is a free, open-source (AGPL-3.0) desktop GUI around the `upscayl-ncnn` backend. ([repo](https://github.com/upscayl/upscayl)) It uses Real-ESRGAN models and Vulkan, and its own README warns that a Vulkan-compatible GPU is required and many integrated GPUs do not work. ([README](https://github.com/upscayl/upscayl#-installation)) The compatibility list says macOS 12+ and "GPUs that support Vulkan 1.3 should be fine." ([wiki](https://github.com/upscayl/upscayl/wiki/Compatibility-List))

The macOS CLI is a separate download: `upscayl-bin`, a universal `x86_64`/`arm64` Mach-O. The 20251207 zip contains only the binary, licence and README; **no models**. You must pass `-m` to a models directory. The Upscayl app bundles models under `/Applications/Upscayl.app/Contents/Resources/models`, which is what its own logs show on an M1. ([release](https://github.com/upscayl/upscayl-ncnn/releases/tag/20251207-174704), [issue #699 log](https://github.com/upscayl/upscayl/issues/699))

Example CLI:

```sh
/Applications/Upscayl.app/Contents/Resources/upscayl-bin \
  -i ~/Pictures/Wallpapers \
  -o ~/Pictures/Wallpapers-upscaled \
  -m /Applications/Upscayl.app/Contents/Resources/models \
  -n realesrgan-x4plus \
  -s 2 \
  -f png
```

CLI options include `-s` output scale, `-r WxH[:filter]` exact resize, `-w` width, `-c` compression, `-t` tile size, `-g` GPU id, `-f` format. ([`upscayl-bin` help, tested](https://github.com/upscayl/upscayl-ncnn/releases/tag/20251207-174704)) `-r` forces the exact dimensions; if the aspect ratio differs, it will distort, so prefer `-s`/`-w` or crop deliberately. A directory input must be paired with a directory output, and vice versa; mixing a file and a directory fails with "Input path and Output path both must be either a file or a directory!" (tested).

**Measured:** 220×220 → 440×440 PNG took 4.0 s (startup-dominated), and the output had **no ICC profile** (`sips -g profile` → `<nil>`). The same is true of the Real-ESRGAN build below. This is a real colour-risk: an untagged P3 image may be interpreted as sRGB, shifting colours.

**Judgement:** the easiest GUI route for a user, and the easiest models source for the CLI. Not something walle should depend on.

### 3.2 Real-ESRGAN ncnn-Vulkan

Real-ESRGAN is the practical general-purpose model family from the paper "Real-ESRGAN: Training Real-World Blind Super-Resolution with Pure Synthetic Data." ([repo](https://github.com/xinntao/Real-ESRGAN), [paper](https://arxiv.org/abs/2107.10833)) The official portable macOS build is a universal `x86_64`/`arm64` Mach-O and runs on the Apple GPU through Vulkan/MoltenVK. The README's GPU list mentions Intel/AMD/Nvidia but not Apple Silicon; the macOS binary is universal and my run reported `[0 Apple M1 Pro]`. ([release](https://github.com/xinntao/Real-ESRGAN/releases/tag/v0.2.5.0))

Important details from the project's own docs:

- **Default model is anime.** `realesr-animevideov3` is the default; for photos use `-n realesrgan-x4plus`. ([README](https://github.com/xinntao/Real-ESRGAN#portable-executable-files-ncnn))
- **Models:** x4plus 32 MB, x4plus-anime 8.5 MB, anime-video 1.2 MB. (Sizes from the release zip listing.)
- **Output formats:** JPG/PNG/WebP. No HEIC, no 16-bit, no ICC profile preservation in the tested build.
- **Tile seams:** the macOS README warns that the portable executable crops the input into tiles, processes them separately and stitches them, so it "may introduce block inconsistency" and differs slightly from the PyTorch implementation. ([README_macos](https://github.com/xinntao/Real-ESRGAN/releases/tag/v0.2.5.0))
- **Speed:** 36.6 s for 1512×982 → 3024×1964, output 9.7 MB PNG, on the M1 Pro. A 220×220 → 440×440 run took 3.7 s. These are wall-clock measurements including startup, not model-only benchmarks.
- **Licence:** BSD-3-Clause for the repository. Model weights may have separate terms; check before redistributing. ([LICENSE](https://github.com/xinntao/Real-ESRGAN/blob/master/LICENSE))

The PyTorch implementation supports alpha, grayscale, 16-bit and `--outscale`, but it is a Python/CUDA-first project. On Apple Silicon you would be experimenting with MPS, not using a supported packaged path. ([README](https://github.com/xinntao/Real-ESRGAN#python-script))

**Judgement:** the best free CLI *engine* for photographic wallpapers on Apple Silicon, provided you (a) use the photo model, (b) accept 30–60 s per image, (c) reattach the colour profile, and (d) inspect the output for artifacts. **But use Upscayl's newer `upscayl-bin` build rather than this 2022 portable binary:** in the full-size A/B (§4.5) the official build produced corrupted tiles at 2× while `upscayl-bin` was clean.

**ESRGAN** (the 2018 predecessor, arXiv 1809.00219) is the architecture Real-ESRGAN extends. Its official repository is research code, not a packaged macOS CLI; for practical use, Real-ESRGAN is the superset. ([ESRGAN repo](https://github.com/xinntao/ESRGAN), [paper](https://arxiv.org/abs/1809.00219))

### 3.3 Anime models: waifu2x and Real-CUGAN

Both are explicitly anime-oriented:

- **waifu2x-ncnn-Vulkan** is an ncnn implementation of the waifu2x converter, "runs fast on Intel / AMD / NVIDIA / Apple-Silicon with Vulkan API," and ships models such as `models-cunet`. It has a CLI with `-n` noise level and `-s` scale. ([repo](https://github.com/nihui/waifu2x-ncnn-vulkan)) Licence: MIT.
- **Real-CUGAN-ncnn-Vulkan** is a "Real Cascade U-Nets for Anime Image Super Resolution" implementation, also Apple Silicon-capable, with a CLI. It warns that it is "in the early development stage." ([repo](https://github.com/nihui/realcugan-ncnn-vulkan)) Licence: MIT.

**Judgement:** do not use these on photographic wallpapers. They are trained for line art and flat colour; on photos they tend to smooth skin, plasticise texture, and produce painterly edges. They are the right tool for anime wallpapers, which is a real use case for some users.

### 3.4 SwinIR

SwinIR is a strong Transformer-based restoration model with classical, lightweight and real-world SR variants. The official repo is Apache-2.0, but it is a Python/PyTorch research codebase: model zoo downloads, `main_test_swinir.py`, CUDA-oriented instructions, no macOS app or CLI. ([repo](https://github.com/JingyunLiang/SwinIR), [paper](https://arxiv.org/abs/2108.10257))

**Judgement:** interesting for research, not a practical walle integration. It would require a Python environment, model weights, and MPS debugging — exactly the runtime dependency walle avoids.

### 3.5 Topaz Photo (formerly Photo AI)

Topaz Photo is a commercial Apple Silicon-native app with Upscale, Recover Faces, Preserve Text, Denoise, Sharpen and other models. The current system requirements are macOS 13+, Apple M-series, **16 GB RAM**, and **88 GB disk**; large upscales want 24 GB RAM. ([system requirements](https://docs.topazlabs.com/topaz-photo/system-requirements))

Current documentation describes **GUI batch processing**: import multiple images or a folder, enable Autopilot or set filters, then Export. ([batch docs](https://docs.topazlabs.com/topaz-photo/functions/batch-processing)) I found no public CLI in the current docs. Pricing is subscription: $25/month or $199/year list, with a current first-year promotion of $21/$169. ([product page](https://www.topazlabs.com/topaz-photo))

**Judgement:** the strongest option for faces/text if you are willing to pay and use a GUI. It is not a walle dependency, and the install size is an order of magnitude beyond walle's entire design.

### 3.6 Non-ML CLI alternatives

`libvips` (`vips resize`) and ImageMagick (`magick convert -resize`) are fast, scriptable, non-ML resamplers available via Homebrew. ([vips formula](https://formulae.brew.sh/formula/vips), [ImageMagick formula](https://formulae.brew.sh/formula/imagemagick)) They are useful for a shell pipeline, but walle should not take a Homebrew dependency for something vImage can do in-process.

---

## 4. Quality reality check: what ML super-resolution actually buys you

### 4.1 The optimistic case

Real-ESRGAN was trained with synthetic real-world degradations (blur, noise, resize, JPEG) and a GAN loss. The paper reports "superior visual performance" and "restoring more realistic textures" on real datasets. ([paper abstract](https://arxiv.org/abs/2107.10833), [repo](https://github.com/xinntao/Real-ESRGAN)) On a soft but clean photo, at 1.5–2×, a good model can produce edges that look sharper and textures that look more detailed than Lanczos. That is a genuine perceptual improvement, not just a bigger file.

### 4.2 The failure modes

| Failure | What it looks like | Evidence |
| --- | --- | --- |
| **Hallucinated detail** | Plausible but invented bricks, foliage, fabric, hair; the image is "sharper" but not faithful | GAN/prior-based SR searches for a realistic high-resolution image that downscales to the input; multiple different high-resolution images can satisfy that. PULSE calls this "face hallucination" and discusses biases. ([PULSE](https://arxiv.org/abs/2003.03808)) Upscayl's own FAQ says its models work by "guessing what the details could be." ([Upscayl README](https://github.com/upscayl/upscayl#-faq)) |
| **Twisted lines / aliasing** | Straight architectural edges become wavy or kinked | Real-ESRGAN paper §4.4: "some restored images (especially building and indoor scenes) have twisted lines due to aliasing issues." ([paper](https://arxiv.org/abs/2107.10833)) |
| **Unpleasant GAN artifacts** | Strange textures, blotches, "painterly" patches | Same section: "GAN training introduces unpleasant artifacts on some samples." |
| **Out-of-distribution degradation** | The model cannot remove unusual blur/noise and may amplify it | Same section: "could not remove out-of-distribution complicated degradations ... Even worse, it may amplify these artifacts." |
| **Faces** | Distorted eyes, teeth, identity drift at small sizes | Real-ESRGAN offers a separate `face_enhance` path for real faces; generic upscaling is not face-aware. ([FAQ](https://github.com/xinntao/Real-ESRGAN/blob/master/docs/FAQ.md)) Topaz has a dedicated "Recover Faces" model, which is evidence that generic upscalers struggle. ([Topaz docs](https://docs.topazlabs.com/topaz-photo/functions)) |
| **Text** | Mangled letters, doubled strokes, unreadable small type | Real-ESRGAN's sinc-filter discussion specifically mentions artifacts "around the text and lines"; Topaz has a dedicated "Preserve Text" model. ([paper](https://arxiv.org/abs/2107.10833), [Topaz docs](https://docs.topazlabs.com/topaz-photo/functions)) |
| **Halos / ringing** | Bright or dark outlines around high-contrast edges | Real-ESRGAN §3.3 discusses ringing and overshoot artifacts in real images and in training; over-sharp models can add halos. ([paper](https://arxiv.org/abs/2107.10833)) |
| **Tile seams** | Visible blocks or brightness steps in large images | The Real-ESRGAN macOS README warns of "block inconsistency" from tiled processing. ([README_macos](https://github.com/xinntao/Real-ESRGAN/releases/tag/v0.2.5.0)) |
| **Colour shift** | P3 image looks oversaturated or flat after upscale | In my tests both Real-ESRGAN and `upscayl-bin` wrote PNGs with no ICC profile. |
| **Over-smoothing** | Plastic skin, lost grain, waxy foliage | Real-ESRNet (MSE loss) is documented as having "over-smooth effects"; GAN models trade smoothness for artifacts. ([model zoo](https://github.com/xinntao/Real-ESRGAN/blob/master/docs/model_zoo.md)) |
| **Bigger but not better** | 4× file, no visible detail gain | Upscayl issue #699: a user's compressed 678×446 image came out larger but with "no improvement to see"; a maintainer suggested downscaling first. ([issue](https://github.com/upscayl/upscayl/issues/699)) |

### 4.3 What "quality" means for a wallpaper

A wallpaper is usually viewed at Retina pixel density, at normal desk distance, partially covered by windows, and often behind translucent materials. In those conditions the eye is forgiving: you are not pixel-peeping the whole image at 100%.

At that viewing distance, a 2× ML upscale of a clean 1080p photo can look meaningfully crisper. A 4× upscale of a 480p heavily compressed image usually looks worse than a clean 2× because the model has more room to invent. Text and faces are the least forgiving; landscapes, skies, foliage and architecture are the most forgiving.

**Judgement:** the best quality-per-risk setting for wallpapers is **2× with a photo model**, not 4×. If the source is already within ~1.5× of the display, leave it alone. If it is 3×+ below, accept that either it stays soft or it gets invented detail.

### 4.4 Why not just use a bigger source?

If the original high-resolution image still exists (camera, stock site, artist's shop), that is always better than any upscale. ML is for the case where the only copy is small. Say this explicitly in walle's documentation.

---

### 4.5 A/B addendum: measured on the actual wallpaper pipeline

After the research was written, the three candidates were applied to the real desktop and
the WindowServer `Wallpaper` window was captured directly at 3024×1964 (no app windows or
compositor guesswork). Source: one MiniGT photo, 1500×1000, fill mode, M1 Pro, macOS
27.0.1.

| Version | Time | Livery crop: Laplacian variance | Mean edge |
| --- | ---: | ---: | ---: |
| macOS native scaling | — | 17.94 | 2.37 |
| vImage Lanczos-5 (3024×2016) | ~0.05 s | 26.29 | 2.97 |
| Upscayl / Real-ESRGAN 2× (3000×2000) | ~43 s | 60.06 | 3.81 |

Comparison image: [`upscaling-ab-comparison.png`](../docs/upscaling-ab-comparison.png) (top:
native, middle: Lanczos-5, bottom: Upscayl).

What this changes:

- **Lanczos-5 is worth doing.** It produced a measurable and visible edge improvement over
  the native scaler on this image. It still cannot add detail, but option (b) is no longer
  purely theoretical.
- **The official 2022 Real-ESRGAN macOS binary is not reliable on this system.** At 2× it
  produced large missing blocks and tile seams with the default tile size, `-t 64` and
  `-t 2048` (the last one failed with `VK_ERROR_DEVICE_LOST` / insufficient memory). The
  output was unusable. Upscayl's newer `upscayl-bin` (20251207) with the same
  `realesrgan-x4plus` model produced a clean image. Recommendation: use Upscayl's engine,
  not the old Real-ESRGAN portable release, and inspect every output.
- **Upscayl is clearly sharper but not free of risk.** The livery text stayed legible in
  this test, but small text and faces remain the least trustworthy areas; the output also
  had slightly higher contrast.
- The ICC caveat still holds: the Upscayl CLI wrote an untagged PNG; the profile was
  reattached with `sips -e` before the A/B. `walle upscale` preserved the profile.

## 5. Recommendation for walle

### 5.1 Constraints that matter

| Constraint | Consequence |
| --- | --- |
| Two small binaries (524 KB / 640 KB), no runtime dependencies | No bundled model, no Python, no Homebrew tool. System frameworks only. ([README](../README.md)) |
| `walle` CLI does not link AppKit | Display geometry must come from `walle-picker` or a headless picker mode. ([HOW-IT-WORKS](../docs/HOW-IT-WORKS.md)) |
| No daemon, no background process | Upscaling is a one-shot command; no watcher, no queue. |
| `WALLE_*` path overrides | New output directory must derive from `WALLE_DATA_DIR` / `WALLE_CACHE_DIR`, and tests must use temp dirs. ([Paths.swift](../Sources/WalleCore/Paths.swift)) |
| Cache is under `~/Library/Caches/walle` | Applied wallpaper paths must **not** live only in cache; a cache purge would leave the system pointing at a missing file. |
| Per-display / backing scale | Target size = `NSScreen.frame` × `backingScaleFactor`; multi-display may need multiple variants. ([`--thumb-size`](../Sources/walle-picker/main.swift)) |
| Fill modes | `fill` needs a cover scale, `fit` a contain scale, `stretch` a cover scale, `center` should be skipped. ([`NSWorkspaceSetter.swift`](../Sources/WalleKit/NSWorkspaceSetter.swift)) |
| Spaces | `spaces all` copies the current wallpaper path; pruning a derived file that a Space still references would break that Space. ([SPACES](../docs/SPACES.md)) |
| HDR / colour profiles | Must preserve ICC; skip HDR/16-bit/CMYK in v1 rather than silently flattening. |

### 5.2 Decision matrix

| Option | Visual gain | Fit with walle | Runtime deps | Risk | Effort | Verdict |
| --- | --- | --- | --- | --- | --- | --- |
| **(a) Document external tools only** | Whatever the external tool gives | Excellent | None | Low | 2–3 h | **Do it** |
| **(b) Non-ML `walle upscale` with vImage Lanczos-5** | Low–moderate; deterministic; no invented detail | Excellent | None (Accelerate is a system framework) | Low–moderate (colour/HDR/disk) | 1.5–3 days | **Do it, opt-in** |
| **(c) Optional ML shell-out to Upscayl/Real-ESRGAN** | Moderate–high on some images | Poor | User-installed external tool | High (artifacts, colour, speed, AGPL) | +2–3 days, ongoing support | **Do not build now; document it** |
| **(d) Bundle a Core ML SR model** | Potentially high | Very poor | Model + Core ML code | Very high (size, licensing, ANE, quality) | Weeks | **No** |

The ratings are **judgement**, not measurements. "Fit with walle" weighs the project's stated non-goals: no daemon, no runtime dependencies, small binaries, and no permanent process.

**Recommendation: (a) + (b).** Explicitly reject (c) as a built-in feature and (d) as an architecture change.

Why (a) + (b):

- (b) gives walle a deterministic, offline, dependency-free way to produce display-sized copies, which is useful even if the visual gain over native scaling is small: it removes two variables (the target pixel size and the colour profile) and gives users a place to point `walle` when they have already upscaled with another tool.
- (a) covers the genuinely better-quality ML path without making walle responsible for a 30–60 s/image external tool, its colour-profile bugs, or its artifacts. (The AGPL matters if walle ever *bundles* the tool; shelling out to a user-installed copy is a different case, but it is still a runtime dependency.)
- (c) sounds attractive but violates the "no dependencies at runtime" promise in the common case, and it is hard to make safe: the tool may not be installed, its model folder may move, its output may be untagged, and its failures are slow.
- (d) would add 16–32 MB of model weights to a 640 KB picker, for quality no better than the external tool, plus conversion and licensing work.

**Validation gate:** before advertising a sharpness improvement, run the blind A/B in §7 on a 1080p-ish source at 2×. If there is no visible difference at normal viewing distance, ship (a) only and keep `walle upscale` as an exact-size/colour-safe utility rather than a headline feature.

### 5.3 Implementation sketch for (b)

#### Command syntax

```text
walle upscale [<path>...] [--all] [--target display|WxH] [--mode fill|fit|stretch]
              [--max-scale 4] [--format heic|png|jpeg] [--quality 0.85]
              [--per-display] [--prune] [--dry-run] [--json] [--force]
```

- No paths + `--all`: every wallpaper in the scanned library.
- Paths: files or directories; directories are scanned with the same filters as the library.
- `--target display` (default): for `apply_to = all`, the largest pixel size across screens; for `apply_to = active`, the screen under the pointer. Query it from a new `walle-picker --display-info` headless mode.
- `--mode` defaults to `fill_mode` from config.
- `--max-scale` defaults to 4; if the required scale exceeds it, skip with a warning (do not silently produce a 6× file).
- `--per-display`: one variant per distinct screen size; default is one variant at the largest target.
- `--prune`: remove stale derived files; `--dry-run` reports without deleting.
- `--json`: one summary object at the end.

Exit codes: 0 all succeeded, 1 any failure, 3 optional lock held (if a second `walle upscale` is running).

#### Sizing math

For source `(w, h)` and target `(tw, th)`:

```text
sx = tw / w
sy = th / h
scale = (mode == fit) ? min(sx, sy) : max(sx, sy)
if scale <= 1.0: skip (source is already big enough)
outW = round(w * scale)
outH = round(h * scale)
```

- `fill`/`stretch`: cover the target; macOS will crop or stretch to the exact screen.
- `fit`: contain the target; macOS will letterbox.
- `center`: skip with a warning ("center does not scale; choose fill or fit").
- For multiple displays, compute the maximum required scale across screens; with `--per-display`, emit one file per distinct `(outW, outH)`.
- Use `NSScreen.frame.width * backingScaleFactor` for pixels, matching the existing `--thumb-size` convention. ([`main.swift`](../Sources/walle-picker/main.swift))

#### Where the files live

Use the **data dir**, not the cache:

```text
~/Library/Application Support/walle/upscaled/
  index.json
  <64-hex>.heic
  <64-hex>.png
```

Reason: `NSWorkspace` stores the wallpaper file URL; `desktopImageURL(for:)` reads it back. ([Apple docs](<https://developer.apple.com/documentation/appkit/nsworkspace/desktopimageurl(for:)>)) If walle applies a file in `~/Library/Caches/walle` and the cache is purged, the system is left pointing at a file that no longer exists. The data dir is the right place for files the system references. Cache is for thumbnails that walle can regenerate. (See [`Paths.swift`](../Sources/WalleCore/Paths.swift) and [`Thumbnails.swift`](../Sources/WalleCore/Thumbnails.swift).)

`WALLE_DATA_DIR` should move this directory too; tests use a temp dir.

#### Cache key

Hash everything that can change the output:

```text
SHA256(
  "v1|" +
  canonicalSourcePath + "|" +
  sourceMtimeBitPattern + "|" +
  sourceFileSize + "|" +
  sourcePixelWidth + "x" + sourcePixelHeight + "|" +
  targetPixelWidth + "x" + targetPixelHeight + "|" +
  mode + "|" +
  "vimage-lanczos5" + "|" +
  format + "|" + quality
)
```

Filename: `<hex>.heic` (or `.png`/`.jpg`). The hash makes stale outputs impossible to serve accidentally: editing the source changes mtime/size, changing the display changes target, changing the algorithm/version changes the key.

#### Manifest

A single `index.json`, rewritten atomically after a batch:

```json
{
  "schema": 1,
  "entries": [
    {
      "key": "9f2c...",
      "source": "/Users/me/Pictures/Wallpapers/4-akane.jpg",
      "sourceMtime": 1760000000.0,
      "sourceBytes": 1234567,
      "sourceWidth": 1600,
      "sourceHeight": 900,
      "targetWidth": 3024,
      "targetHeight": 1964,
      "scale": 2.18,
      "mode": "fill",
      "algorithm": "vimage-lanczos5-v1",
      "format": "heic",
      "quality": 0.85,
      "colorSpace": "Display P3",
      "output": "9f2c....heic",
      "outputBytes": 176000,
      "createdAt": "2026-11-22T15:30:00Z"
    }
  ]
}
```

Why a manifest instead of scanning filenames: `walle set` needs to resolve a source path without walking a directory of thousands of files on every hotkey apply. The manifest is small, loaded once per process, and only when `upscale = on` (see below). If the manifest is missing or corrupt, fall back to the original; never fail an apply because the derived copy is unavailable.

#### Applying derived copies

Add a config key:

```text
upscale = off        # off (default) | on
```

When `upscale = on`:

1. Selection still works on the original library (`walle next`, `prev`, `random`, picker cards).
2. Before applying, resolve `(sourcePath, targetPixels, fillMode)` in the manifest: prefer an exact target match, otherwise the smallest entry whose target covers the screen.
3. If a fresh output exists, pass it to `NSWorkspaceSetter`; otherwise apply the original.
4. Record **the source path** in history/state, not the derived path, so `next`/`prev`/`--last` continue to work against the library. Optionally add `appliedPath` to `HistoryEntry` for diagnostics; it must be optional for backward compatibility. `walle current` still reports the derived path because that is what the system actually has. ([`History.swift`](../Sources/WalleCore/History.swift), [`ApplyRecord.swift`](../Sources/WalleCore/ApplyRecord.swift))
5. In the picker, do the same resolution before `setWallpaper`. The picker already knows `NSScreen`, so it can pass the target pixels directly.

Why keep the config off by default: the visual gain is not guaranteed, it adds disk usage, and a user who has not run `walle upscale` should not pay a manifest read on every apply.

#### Batch behaviour, progress and errors

- Scan the library once with `LibraryScanner` (already canonicalises paths and skips hidden/unsupported files). ([`Library.swift`](../Sources/WalleCore/Library.swift))
- Filter to 8-bit RGB/RGBA images. Skip 16-bit, CMYK, HDR/EDR gain-map images and unreadable files with a clear warning; do not silently convert.
- Skip images that already meet the target (`scale <= 1.0`), unless `--force`.
- Use a bounded worker pool (2–4 concurrent) because each 6 MP ARGB buffer is ~24 MB plus vImage temp buffers. The existing `WalleConcurrentResults` + `concurrentPerform` pattern is a good fit, but a small `OperationQueue` with `maxConcurrentOperationCount = min(4, activeProcessorCount)` is easier to throttle. ([`ConcurrentResults.swift`](../Sources/WalleCore/ConcurrentResults.swift))
- Write to a temp file in the same directory, `fsync`, then `rename(2)`; never leave a half-written HEIC that could be applied.
- Human progress on stderr: `12/48 4-akane.jpg -> 3488x1962 (2.18x)`. Print it for a long batch; `--json` suppresses it and emits one summary object instead.
- Collect failures; print one line per failure; exit 1 if any failed, but keep going.
- `--json` output: `{"wallpapers":48,"generated":46,"skipped":2,"failed":0,"bytes":...,"dir":"...","elapsedMs":...}`.

#### Pruning

`walle upscale --prune` should:

- Remove entries whose source is gone, whose mtime/size changed, whose output is missing, or whose algorithm version is old.
- Remove orphan files in `upscaled/` that are not in the manifest.
- **Not** remove a file currently referenced by the system wallpaper store (best effort: read the same private store walle already handles for Spaces) unless `--force`.
- Report bytes freed and entries skipped as "in use".
- Be explicit in docs: pruning a derived file that a Space still points at will break that Space's wallpaper until re-applied.
- `walle doctor` should report the derived store's size, stale entries, and whether `upscale = on` has no usable entries (a common silent no-op).

#### Colour, format and metadata

- Use `CGImageSource` → `CGColorSpace` → `vImage_CGImageFormat`/`CGContext` in the source colour space; attach the same `CGColorSpace` to the output `CGImage`; write with `CGImageDestination`.
- Default output: HEIC, quality 0.85. In my test a 3024×1964 Display P3 HEIC was 176 KB versus 3.9 MB PNG and 682 KB JPEG at q0.95, with the profile preserved. HEIC is already in walle's image extension list. ([`sips` measurement](#appendix-measurement-method), [`Library.swift`](../Sources/WalleCore/Library.swift))
- `--format png` for lossless; `--format jpeg` for compatibility.
- Apply EXIF orientation before scaling; strip/normalise orientation metadata in the output.
- Skip HDR/EDR and 16-bit sources in v1; document that they are left untouched. Revisit with `vImageScale_PlanarF`/`CGImageDestination` gain-map support if users need it.
- Do not use Core Image's convenience path unless the `CIContext` is explicitly configured with the source colour space; the naive path lost P3 in my test.

#### Tests

Add `Tests/WalleCoreTests/UpscaleTests.swift` (or split by concern):

1. **Geometry:** fill/fit/stretch scale factors; multi-screen max; `scale <= 1` skip; cap; odd dimensions rounding; center warning.
2. **Key:** deterministic; changes with path, mtime, size, target, mode, format, quality, algorithm version.
3. **Renderer:** 4×4 checkerboard → 8×8; sRGB and Display P3 profile preserved; alpha preserved; EXIF orientation applied; unsupported 16-bit/CMYK skipped with a typed error; HEIC output decodes.
4. **Store:** manifest round-trip; stale source mtime; missing output; atomic rewrite; prune keeps in-use entries; prune removes orphans; corrupt manifest falls back safely.
5. **CLI:** `--dry-run` writes nothing; `--json` schema; missing path; `--max-scale` skip; exit 1 on partial failure; `WALLE_DATA_DIR` temp dir; `upscale=off` means no manifest read on apply.
6. **Integration:** `walle set --dry-run` still prints the source path; with `upscale=on`, the picker receives the derived path but history records the source; removing the derived file falls back to the original.

Run `swift test` and the existing 163 tests; add a manual check on a real 720p image and a P3 image.

#### Effort

| Scope | Estimate |
| --- | --- |
| Generate-only MVP (vImage + geometry + manifest + CLI + tests + docs) | **1.5 days** |
| Full (b): opt-in apply integration, history semantics, prune/in-use guard, doctor | **2.5–3 days** |
| (c) ML shell-out, if ever | +2–3 days plus ongoing support |
| (d) Core ML bundle | 2–4 weeks plus model/licensing work |

The estimate assumes the existing scan/cache/CLI patterns are reused, not rewritten.

### 5.4 What to tell users about expected quality

Walle's help and docs should say, plainly:

> `walle upscale` produces a high-quality Lanczos-5 copy at your display's pixel size. It can make a small wallpaper smoother, but it cannot add detail that was never in the source. If you want invented detail, use an ML upscaler such as Upscayl or Pixelmator Pro, and inspect the result for artifacts. `walle upscale` never modifies your originals.

That honesty is better than promising "HD wallpapers" and having users notice no difference.

---

## 6. What to do today

### Step 0: know your target

On this Mac the built-in display is 3024×1964 pixels (1512×982 points at 2×). Check yours:

```sh
system_profiler SPDisplaysDataType | grep -E 'Resolution|Retina'
```

Or, if `walle-picker` is on your PATH (it also lives inside `Walle.app`), ask it for the thumbnail floor it derives from the display. That is not the same as the wallpaper target, but it confirms the geometry the current build sees (a future `--display-info` would return the screens directly):

```sh
walle-picker --thumb-size --widest-aspect 1.78
```

For a 16:9 wallpaper, covering 3024×1964 requires about 3492×1964 (the width is cropped by fill). For a 4:3 image, 3024×2268 is enough. The cover formula is `scale = max(3024/w, 1964/h)`.

### Step 1: find the wallpapers that are actually small

```sh
find "$HOME/Downloads/wallpaper" -type f \
  \( -iname '*.jpg' -o -iname '*.jpeg' -o -iname '*.png' -o -iname '*.heic' \) -print0 |
while IFS= read -r -d '' f; do
  w=$(sips -g pixelWidth  "$f" | awk '/pixelWidth/{print $2}')
  h=$(sips -g pixelHeight "$f" | awk '/pixelHeight/{print $2}')
  if [ -n "$w" ] && { [ "$w" -lt 3024 ] || [ "$h" -lt 1964 ]; }; then
    printf '%5s x %-5s  %s\n' "$w" "$h" "$f"
  fi
done
```

Adjust the directory and the 3024 threshold. This is read-only. Skip HDR/EDR or 16-bit sources for now: the tested ML tools write 8-bit SDR output, and the gain map is not preserved.

### Step 2: best-quality route — Upscayl (ML)

For a few important wallpapers, this is the best readily available result on Apple Silicon.

**GUI (recommended for most people):**

1. Install Upscayl: `brew install --cask upscayl`, or download the macOS DMG from [upscayl.org](https://upscayl.org/) / the [releases page](https://github.com/upscayl/upscayl/releases). It is free.
2. Open Upscayl, select the input folder, set the output folder to a **new** directory such as `~/Pictures/Wallpapers-upscaled`.
3. Choose a photo model: **General Photo (Real-ESRGAN)** is the safe default; **High Fidelity** and **Ultramix Balanced** are also photo-oriented. Avoid the anime models. (Model list: [Upscayl custom models](https://github.com/upscayl/custom-models).)
4. Choose **2×** for wallpapers, not 4×. 2× is the best quality-per-artifact tradeoff; 4× gives the model four times more room to invent.
5. Output PNG if you will convert to HEIC afterward; output JPEG only if you accept another lossy generation.
6. Run the batch. Inspect a few outputs at 100% before committing.

**CLI (advanced, uses the app's bundled models):**

First verify the paths exist:

```sh
ls /Applications/Upscayl.app/Contents/Resources/upscayl-bin
ls /Applications/Upscayl.app/Contents/Resources/models
```

Then:

```sh
mkdir -p "$HOME/Pictures/Wallpapers-upscaled"

/Applications/Upscayl.app/Contents/Resources/upscayl-bin \
  -i "$HOME/Downloads/wallpaper" \
  -o "$HOME/Pictures/Wallpapers-upscaled" \
  -m /Applications/Upscayl.app/Contents/Resources/models \
  -n realesrgan-x4plus \
  -s 2 \
  -f png
```

Notes:

- Directory input requires directory output. A single file must go to a single file.
- The CLI preserves the basename; the GUI may add a suffix. Check with `ls`.
- The CLI wrote untagged PNGs in my test. Reattach an sRGB profile if the source was sRGB:
  ```sh
  sips -e "/System/Library/ColorSync/Profiles/sRGB Profile.icc" \
    "$HOME/Pictures/Wallpapers-upscaled/example.png"
  ```
  For a Display P3 source, do not tag it sRGB; either convert deliberately with `sips -m` or use a tool that preserves the profile.
- Optional HEIC conversion after the profile is fixed (smaller, profile preserved in my test):
  ```sh
  sips -s format heic -s formatOptions 85 \
    "$HOME/Pictures/Wallpapers-upscaled/example.png" \
    --out "$HOME/Pictures/Wallpapers-upscaled/example.heic"
  ```

**Direct Real-ESRGAN alternative (no app):**

```sh
mkdir -p /tmp/realesrgan && cd /tmp/realesrgan
curl -LO https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.5.0/realesrgan-ncnn-vulkan-20220424-macos.zip
unzip realesrgan-ncnn-vulkan-20220424-macos.zip
chmod +x realesrgan-ncnn-vulkan

./realesrgan-ncnn-vulkan \
  -i "$HOME/Downloads/wallpaper/example.jpg" \
  -o "$HOME/Pictures/Wallpapers-upscaled/example.png" \
  -n realesrgan-x4plus \
  -s 2 \
  -f png
```

This is a portable binary; nothing is installed. The output is untagged, so reattach the profile as above. It took 36.6 s for a 1512×982 source on this M1 Pro.

### Step 3: conservative route — `sips` (no ML)

If you want predictable, fast, non-ML copies, use a cover resize. This function preserves aspect ratio and upscales only enough to cover the target; macOS fill will crop the excess.

```sh
cover_resize() {
  src="$1"; out="$2"; tw="$3"; th="$4"
  read w h < <(sips -g pixelWidth -g pixelHeight "$src" |
    awk '/pixelWidth/{w=$2}/pixelHeight/{h=$2}END{print w,h}')
  read nw nh < <(awk -v w="$w" -v h="$h" -v tw="$tw" -v th="$th" '
    BEGIN {
      s = tw/w
      if (th/h > s) s = th/h
      if (s < 1) s = 1
      printf "%d %d\n", w*s + 0.5, h*s + 0.5
    }')
  sips -z "$nh" "$nw" "$src" --out "$out" >/dev/null
}

mkdir -p "$HOME/Pictures/Wallpapers-lanczos"
for f in "$HOME/Downloads/wallpaper"/*.jpg; do
  cover_resize "$f" "$HOME/Pictures/Wallpapers-lanczos/$(basename "$f")" 3024 1964
done
```

This is resampling, not super-resolution. It will not invent detail. It is fast (~0.1 s per image) and preserved sRGB/P3 in my tests.

Preview alternative: open the images in one Preview window, select all, `Tools > Adjust Size`, set width/height or a percentage, keep "Scale proportionally" and "Resample image" on. ([Apple Support](https://support.apple.com/guide/preview/crop-resize-or-rotate-an-image-prvw2015/mac))

### Step 4: Pixelmator Pro route (paid, Apple-owned)

1. Open the image in Pixelmator Pro.
2. `Image > Super Resolution` for automatic enlargement, or `Image > Image Size` and choose "Super Resolution" to hit a specific size. ([Apple guide](https://support.apple.com/guide/pixelmator-pro/automatically-increase-image-resolution-pix1d6f0eac3/mac))
3. Export HEIC or PNG. Inspect faces, text and straight edges at 100%.
4. For a batch, try an AppleScript/Shortcut against your installed version; Apple does not document a Super Resolution CLI, so verify before relying on it.

### Step 5: verify the output

Always check dimensions and profile:

```sh
sips -g pixelWidth -g pixelHeight -g profile \
  "$HOME/Pictures/Wallpapers-upscaled/example.png"
```

Expected for a 16:9 source targeting 3024×1964: at least 3024 wide and 1964 tall after a cover resize, or 3024×1701 after a `-Z 3024` fit resize (which is not enough to cover the height; macOS would upscale the rest). For ML output, dimensions depend on the model scale and any `-r`/`-w` post-resize.

Then look at the image at 100% in Preview. Check:

- straight architectural lines,
- small text,
- faces and eyes,
- foliage and fabric texture,
- sky gradients and banding,
- halos around high-contrast edges,
- colour compared with the original.

### Step 6: point walle at the upscaled files

To try them alongside the originals (`add` includes both sets; expect duplicates in the picker):

```sh
walle add "$HOME/Pictures/Wallpapers-upscaled"
walle cache
walle list | grep Wallpapers-upscaled
```

To make the upscaled directory the library (originals stay on disk):

```sh
walle use "$HOME/Pictures/Wallpapers-upscaled"
walle cache --rebuild
```

To apply one directly:

```sh
walle set "$HOME/Pictures/Wallpapers-upscaled/example.png"
walle current
```

To go back:

```sh
walle use "$HOME/Downloads/wallpaper"
walle cache --rebuild
```

`walle use` replaces the directory list; it does not delete anything. `walle cache --rebuild` is only needed after switching libraries because the thumbnail cache is keyed by path. ([USAGE](../docs/USAGE.md))

### Step 7: A/B check

Close or minimise windows so the wallpaper is visible. Set the original, take a screenshot, then set the upscaled copy and take another:

```sh
walle set "$HOME/Downloads/wallpaper/example.jpg"
screencapture -x /tmp/original.png

walle set "$HOME/Pictures/Wallpapers-upscaled/example.png"
screencapture -x /tmp/upscaled.png
```

Both are 3024×1964 on this Mac. Compare at 100% in Preview. If you cannot see a difference at normal viewing distance, keep the original and save the disk space. That is a valid outcome, not a failure.

---

## 7. Open questions

1. **What filter does macOS actually use for desktop pictures?** No public documentation; `WallpaperAgent` is private. An A/B test with a test pattern and a screenshot could narrow it down, but colour management and compositing make it hard to isolate.
2. **Does macOS scale at backing-pixel resolution or point resolution?** A 3024×1964 screenshot suggests the desktop is composited at backing pixels, but the wallpaper path is not documented.
3. **Does macOS preserve ICC profiles and HDR gain maps for desktop pictures?** Likely for ICC, unclear for gain maps. Test with a P3/HDR HEIC and a colour meter or pixel probe.
4. **Can Pixelmator Pro's Super Resolution be batched reliably via AppleScript/Shortcuts?** Apple documents AppleScript and Shortcuts generally, but not a Super Resolution action or CLI. Test against the current app version.
5. **What is the actual quality of Pixelmator's ML Super Resolution versus Real-ESRGAN/Upscayl on photographic wallpapers?** I did not run a controlled comparison; Apple's copy is marketing, not a benchmark.
6. **Are Real-ESRGAN's model weights licensed for redistribution?** The repo is BSD-3-Clause; the weights may have separate terms. Relevant only if walle ever bundles a model (recommended: don't).
7. **Would a 2× Lanczos pre-upscale actually beat macOS's native scaling on a Retina display?** This is the central empirical question for option (b), and it needs a blind A/B test at native resolution.
8. **Is there an undocumented macOS 27 wallpaper/EDR change?** The public feature page shows no SR feature, but the wallpaper pipeline is private.

---

## Appendix: measurement method

All measurements were run on 22 November 2026 on an Apple M1 Pro (14-core GPU), macOS 27.0.1 (26A434), from `/tmp`. No tools were installed system-wide.

| Measurement | Method | Result |
| --- | --- | --- |
| `sips` upscale | `sips -z 1964 3024 big.jpg --out sips.png` on a 1512×982 sRGB JPEG | 0.09 s; 3024×1964; profile `sRGB IEC61966-2.1` |
| vImage Lanczos-5 | Swift test using `vImageScale_ARGB8888` with `kvImageHighQualityResampling` | 0.049 s; 3024×1964; profile preserved (sRGB and Display P3) |
| Core Image naive | `CIContext()` + `CILanczosScaleTransform` + `createCGImage` | 0.099 s; output `DeviceRGB`, PNG written as sRGB from a P3 source |
| Core Image configured | `CIContext(options: [.workingColorSpace: cs, .outputColorSpace: cs])` | P3 preserved; same filter |
| Real-ESRGAN ncnn | Official macOS v0.2.5.0 build, `-n realesrgan-x4plus -s 2`, 1512×982 source | 36.6 s; 3024×1964; 9.7 MB PNG; `profile: <nil>` |
| Upscayl CLI | `upscayl-bin` 20251207, models from Real-ESRGAN zip, 220×220 source | 4.0 s; 440×440; PNG; `profile: <nil>` |
| HEIC output | `sips -s format heic -s formatOptions 85` on a 3024×1964 P3 PNG | 176 KB; profile `Display P3` |
| JPEG output | `sips -s format jpeg -s formatOptions 95` on the same PNG | 682 KB; profile `Display P3` |
| PNG output | vImage output | 3.9 MB; profile `Display P3` |

**Limitations of these measurements:** single machine, single run, warm/cold cache not controlled; the Real-ESRGAN timing includes process startup and model load; the 220×220 Upscayl run is startup-dominated. They are useful for order-of-magnitude comparisons, not as a benchmark suite.

**Source notes:** Apple's `sips` man page is available locally via `man sips`; Apple does not publish it at a stable public URL. Where a claim is based on a local observation rather than a public document, the table says "measured" and the method is above.

---

## Sources

Apple documentation and support:

- [`NSWorkspace.setDesktopImageURL`](<https://developer.apple.com/documentation/appkit/nsworkspace/setdesktopimageurl(_:for:options:)>)
- [`NSWorkspace.desktopImageURL(for:)`](<https://developer.apple.com/documentation/appkit/nsworkspace/desktopimageurl(for:)>)
- [`NSWorkspace.DesktopImageOptionKey`](https://developer.apple.com/documentation/appkit/nsworkspace/desktopimageoptionkey)
- [`imageScaling`](https://developer.apple.com/documentation/appkit/nsworkspace/desktopimageoptionkey/imagescaling)
- [`allowClipping`](https://developer.apple.com/documentation/appkit/nsworkspace/desktopimageoptionkey/allowclipping)
- [`NSImageScaling`](https://developer.apple.com/documentation/appkit/nsimagescaling)
- [`CILanczosScaleTransform`](https://developer.apple.com/documentation/coreimage/cilanczosscaletransform)
- [`CIFilter.lanczosScaleTransform()`](<https://developer.apple.com/documentation/coreimage/cifilter-swift.class/lanczosscaletransform()>)
- [`vImageScale_ARGB8888`](<https://developer.apple.com/documentation/accelerate/vimagescale_argb8888(_:_:_:_:)>)
- [`kvImageHighQualityResampling`](https://developer.apple.com/documentation/accelerate/kvimagehighqualityresampling)
- [MetalFX](https://developer.apple.com/documentation/metalfx)
- [`MTLFXSpatialScaler`](https://developer.apple.com/documentation/metalfx/mtlfxspatialscaler)
- [`MTLFXSpatialScalerDescriptor`](https://developer.apple.com/documentation/metalfx/mtlfxspatialscalerdescriptor)
- [`MTLFXSpatialScalerBase.outputTexture`](https://developer.apple.com/documentation/metalfx/mtlfxspatialscalerbase/outputtexture)
- [WWDC22: Boost performance with MetalFX Upscaling](https://developer.apple.com/videos/play/wwdc2022/10103/)
- [Core ML](https://developer.apple.com/documentation/coreml)
- [`MLComputeUnits`](https://developer.apple.com/documentation/coreml/mlcomputeunits)
- [Apple Core ML model gallery](https://developer.apple.com/machine-learning/models/)
- [Vision](https://developer.apple.com/documentation/vision)
- [coremltools guide](https://apple.github.io/coremltools/docs-guides/)
- [Preview: crop, resize or rotate](https://support.apple.com/guide/preview/crop-resize-or-rotate-an-image-prvw2015/mac)
- [Photos: editing basics](https://support.apple.com/guide/photos/editing-basics-pht304c2ace6/mac)
- [Photos: adjust definition](https://support.apple.com/guide/photos/adjust-definition-phtb151c05a0/mac)
- [Photos: sharpen](https://support.apple.com/guide/photos/sharpen-a-photo-phtba5e3cf7d/mac)
- [Photos: reduce noise](https://support.apple.com/guide/photos/reduce-noise-phta85f0d224/mac)
- [macOS 27](https://www.apple.com/os/macos/)
- [Pixelmator Pro: Super Resolution](https://support.apple.com/guide/pixelmator-pro/automatically-increase-image-resolution-pix1d6f0eac3/mac)
- [Pixelmator Pro: resize an image](https://support.apple.com/guide/pixelmator-pro/resize-an-image-pix1db05dd71/mac)
- [Pixelmator Pro: colour management](https://support.apple.com/guide/pixelmator-pro/about-color-management-pix91010c515/mac)
- [Pixelmator Pro: AppleScript automation](https://support.pixelmator.com/faq-pixelmator-pro/advanced-workflows/advanced-automation-and-scripting-with-applescript)
- [Pixelmator Pro: Shortcuts/HDR guide](https://support.pixelmator.com/faq-pixelmator-pro/advanced-workflows/working-with-hdr-images-using-shortcuts)
- [Pixelmator Pro product page](https://www.pixelmator.com/pro/)
- [Pixelmator Pro on the App Store](https://apps.apple.com/us/app/pixelmator-pro/id1289583905)

Third-party projects and papers:

- [Upscayl](https://github.com/upscayl/upscayl)
- [Upscayl ncnn CLI](https://github.com/upscayl/upscayl-ncnn)
- [MoltenVK](https://github.com/KhronosGroup/MoltenVK)
- [Upscayl CLI 20251207 release](https://github.com/upscayl/upscayl-ncnn/releases/tag/20251207-174704)
- [Upscayl compatibility list](https://github.com/upscayl/upscayl/wiki/Compatibility-List)
- [Upscayl custom models](https://github.com/upscayl/custom-models)
- [Upscayl issue #699 (Apple M1 log)](https://github.com/upscayl/upscayl/issues/699)
- [Upscayl Homebrew cask](https://formulae.brew.sh/cask/upscayl)
- [Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN)
- [Real-ESRGAN paper](https://arxiv.org/abs/2107.10833)
- [ESRGAN](https://github.com/xinntao/ESRGAN)
- [ESRGAN paper](https://arxiv.org/abs/1809.00219)
- [Real-ESRGAN ncnn-Vulkan](https://github.com/xinntao/Real-ESRGAN-ncnn-vulkan)
- [Real-ESRGAN macOS portable release](https://github.com/xinntao/Real-ESRGAN/releases/tag/v0.2.5.0)
- [Real-ESRGAN FAQ](https://github.com/xinntao/Real-ESRGAN/blob/master/docs/FAQ.md)
- [Real-ESRGAN model zoo](https://github.com/xinntao/Real-ESRGAN/blob/master/docs/model_zoo.md)
- [waifu2x-ncnn-Vulkan](https://github.com/nihui/waifu2x-ncnn-vulkan)
- [Real-CUGAN-ncnn-Vulkan](https://github.com/nihui/realcugan-ncnn-vulkan)
- [SwinIR](https://github.com/JingyunLiang/SwinIR)
- [SwinIR paper](https://arxiv.org/abs/2108.10257)
- [PULSE paper](https://arxiv.org/abs/2003.03808)
- [Shannon 1949](https://doi.org/10.1109/JRPROC.1949.232969)
- [Topaz Photo](https://www.topazlabs.com/topaz-photo)
- [Topaz Photo batch processing](https://docs.topazlabs.com/topaz-photo/functions/batch-processing)
- [Topaz Photo system requirements](https://docs.topazlabs.com/topaz-photo/system-requirements)
- [Topaz Photo Homebrew cask](https://formulae.brew.sh/cask/topaz-photo-ai)
- [libvips formula](https://formulae.brew.sh/formula/vips)
- [ImageMagick formula](https://formulae.brew.sh/formula/imagemagick)

walle source:

- [`README.md`](../README.md)
- [`docs/HOW-IT-WORKS.md`](../docs/HOW-IT-WORKS.md)
- [`docs/USAGE.md`](../docs/USAGE.md)
- [`docs/SPACES.md`](../docs/SPACES.md)
- [`Sources/WalleCore/Paths.swift`](../Sources/WalleCore/Paths.swift)
- [`Sources/WalleCore/Thumbnails.swift`](../Sources/WalleCore/Thumbnails.swift)
- [`Sources/WalleCore/Library.swift`](../Sources/WalleCore/Library.swift)
- [`Sources/WalleCore/History.swift`](../Sources/WalleCore/History.swift)
- [`Sources/WalleCore/ApplyRecord.swift`](../Sources/WalleCore/ApplyRecord.swift)
- [`Sources/WalleKit/NSWorkspaceSetter.swift`](../Sources/WalleKit/NSWorkspaceSetter.swift)
- [`Sources/walle-picker/main.swift`](../Sources/walle-picker/main.swift)
