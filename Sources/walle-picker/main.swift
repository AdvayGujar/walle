import AppKit
import Foundation
import WalleCore
import WalleKit

// walle-picker is the only part of walle that links AppKit and talks to the window
// server. The walle CLI never links AppKit: when it needs to change the desktop or read
// the current wallpaper it execs this binary.

let arguments = Array(CommandLine.arguments.dropFirst())
let launchedAt = Date()

func writeError(_ message: String) {
    FileHandle.standardError.write(Data(("walle-picker: " + message + "\n").utf8))
}

func emit(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(
        withJSONObject: object,
        options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
        writeError("could not encode json")
        exit(1)
    }
    print(String(decoding: data, as: UTF8.self))
}

func wantsJSON(_ tokens: [String]) -> Bool {
    tokens.contains("--json") || tokens.contains("-j")
}

func value(of flag: String, in tokens: [String]) -> String? {
    guard let index = tokens.firstIndex(of: flag), index + 1 < tokens.count else { return nil }
    return tokens[index + 1]
}

/// 0 is the resting row, 1 is the expanded preview. --transition takes any point between
/// them, which is how mid-morph frames are rendered for verification.
func transitionValue(_ tokens: [String]) -> Double {
    if let raw = value(of: "--transition", in: tokens), let parsed = Double(raw) {
        return min(1, max(0, parsed))
    }
    return tokens.contains("--collapsed") ? 0 : 1
}

let usageText = """
walle-picker - the macOS half of walle

Normally launched for you by the walle CLI:
  walle pick                open the picker
  walle set <path>          apply a wallpaper
  walle current             print the current wallpaper

HEADLESS MODES
  --apply <path> [--json]   apply a wallpaper and exit
  --current [--json]        print the current desktop wallpaper
  --snapshot <file>         render the corridor to a PNG and exit
                            [--width n] [--height n] [--collapsed]
  --selftest [--json]       report what this environment can do
  --help                    show this message
"""

let paths = WallePaths.resolve()
let (rawConfig, configWarnings) = Config.load(from: paths.configFile)
let (config, configSanitizeWarnings) = rawConfig.sanitized()
for warning in configWarnings + configSanitizeWarnings {
    writeError("warning: " + warning)
}

let setter = NSWorkspaceSetter()

/// The picker floors the thumbnail size at what the card geometry actually needs, because a
/// config written by an older build can pin a value that was correct for a smaller card. The
/// snapshot path has to use the same floor, or it renders blurrier than the real thing and
/// stops being a useful check.
func makeProvider(library: [Wallpaper], width: Double, height: Double) -> ThumbnailProvider {
    let widest = library.compactMap { $0.aspectRatio }
        .map { max($0, 1.0 / $0) }
        .max() ?? 1.8
    let geometry = LayoutEngine(config: config,
                                screen: ScreenMetrics(width: width, height: height),
                                transition: 0)
    let required = geometry.minimumThumbnailPixels(backingScale: 2, widestAspect: widest)
    let pixels = max(config.thumbMaxPx, required)
    return ThumbnailProvider(
        cache: ThumbnailCache(directory: paths.thumbnailsDir,
                              rowMaxPx: pixels,
                              previewMaxPx: max(config.previewMaxPx, pixels)),
        rowMaxPx: pixels,
        previewMaxPx: max(config.previewMaxPx, pixels))
}

func loadLibrary() -> [Wallpaper] {
    let scan = LibraryScanner(config: config, home: paths.home).scan()
    for warning in scan.warnings { writeError("warning: " + warning) }
    return scan.wallpapers
}

func focusIndex(in library: [Wallpaper], currentPath: String?) -> Int {
    guard let currentPath else { return 0 }
    return library.firstIndex { $0.path == currentPath } ?? 0
}

func currentWallpaperJSON() -> [String: Any] {
    var object: [String: Any] = ["screenCount": NSScreen.screens.count]
    if let url = setter.currentWallpaperURL() {
        object["path"] = url.path
        object["name"] = url.lastPathComponent
    }
    if let screen = setter.activeScreen() {
        object["activeScreen"] = [
            "width": Double(screen.frame.width),
            "height": Double(screen.frame.height),
        ]
    }
    return object
}

if arguments.contains("--help") || arguments.contains("-h") {
    print(usageText)
    exit(0)
}

let command = arguments.first ?? "--pick"
let rest = arguments.isEmpty ? [] : Array(arguments.dropFirst())

switch command {
case "--current":
    if wantsJSON(rest) {
        emit(currentWallpaperJSON())
    } else if let url = setter.currentWallpaperURL() {
        print(url.path)
    } else {
        writeError("could not read the current desktop wallpaper")
        exit(1)
    }
    exit(0)

case "--apply":
    guard let rawPath = rest.first(where: { !$0.hasPrefix("-") }) else {
        writeError("--apply needs a path")
        exit(1)
    }
    let url = walleExpand(rawPath, home: paths.home).standardizedFileURL
    guard FileManager.default.fileExists(atPath: url.path) else {
        writeError("file does not exist: " + url.path)
        exit(1)
    }
    do {
        try setter.setWallpaper(at: url, target: config.applyTo, fillMode: config.fillMode)
    } catch {
        writeError(String(describing: error))
        exit(1)
    }
    if let warning = WallpaperStore.syncIfEnabled(config.spaces) {
        writeError(warning)
    }

    // Recording happens only after the desktop actually changed, and a failure here is
    // reported rather than swallowed.
    for warning in walleRecordApplied(path: url.path, paths: paths, mode: "cli") {
        writeError("warning: " + warning)
    }

    if wantsJSON(rest) {
        emit(["applied": url.path,
              "target": config.applyTo.rawValue,
              "fillMode": config.fillMode.rawValue])
    }
    exit(0)

case "--snapshot":
    let output = rest.first { !$0.hasPrefix("-") } ?? "walle-snapshot.png"
    let url = walleExpand(output, home: paths.home).standardizedFileURL
    let width = value(of: "--width", in: rest).flatMap(Double.init) ?? 1512
    let height = value(of: "--height", in: rest).flatMap(Double.init) ?? 982
    let transition = transitionValue(rest)
    let debugColours = rest.contains("--debug-tiles")

    let library = loadLibrary()
    guard !library.isEmpty else {
        writeError("no wallpapers found; run walle list to check the library")
        exit(1)
    }
    let current = setter.currentWallpaperURL()?.path
    let view = CorridorView(frame: CGRect(x: 0, y: 0, width: width, height: height),
                            config: config,
                            provider: makeProvider(library: library,
                                                   width: width, height: height),
                            currentPath: current,
                            transition: transition,
                            debugColours: debugColours)
    view.reload(library: library, focus: focusIndex(in: library, currentPath: current))
    do {
        try view.snapshot(to: url)
    } catch {
        writeError(String(describing: error))
        exit(1)
    }
    print(url.path)
    exit(0)

case "--selftest":
    let started = Date()
    let cache = ThumbnailCache(directory: paths.thumbnailsDir,
                              rowMaxPx: config.thumbMaxPx,
                              previewMaxPx: config.previewMaxPx)
    var object: [String: Any] = [
        "screens": NSScreen.screens.count,
        "configFile": paths.configFile.path,
        "configExists": FileManager.default.fileExists(atPath: paths.configFile.path),
        "historyFile": paths.historyFile.path,
        "thumbnailsDir": paths.thumbnailsDir.path,
        "cacheBytes": cache.cacheSizeBytes(),
        "applyTo": config.applyTo.rawValue,
        "fillMode": config.fillMode.rawValue,
        "wallpaperDirs": config.wallpaperDirs,
    ]
    if let url = setter.currentWallpaperURL() { object["current"] = url.path }
    object["elapsedMs"] = Date().timeIntervalSince(started) * 1000
    if wantsJSON(rest) {
        emit(object)
    } else {
        print("screens:      " + String(NSScreen.screens.count))
        print("current:      " + (setter.currentWallpaperURL()?.path ?? "(unknown)"))
        print("config:       " + paths.configFile.path)
        print("history:      " + paths.historyFile.path)
        print("thumbnails:   " + paths.thumbnailsDir.path)
        print("library dirs: " + config.wallpaperDirs.joined(separator: ", "))
    }
    exit(0)

case "--thumb-size":
    // What size thumbnail the picker will actually request for this display and library.
    // The walle CLI asks for this so the cache it builds matches, instead of the user
    // having to keep thumb_max_px in step with their screen by hand.
    let screen = NSScreen.main ?? NSScreen.screens.first
    let screenWidth = value(of: "--width", in: rest).flatMap(Double.init)
        ?? Double(screen?.frame.width ?? 1512)
    let screenHeight = value(of: "--height", in: rest).flatMap(Double.init)
        ?? Double(screen?.frame.height ?? 982)
    let backingScale = Double(screen?.backingScaleFactor ?? 2)
    let library = loadLibrary()
    let widest = library.compactMap { $0.aspectRatio }
        .map { max($0, 1.0 / $0) }
        .max() ?? 1.8
    let geometry = LayoutEngine(config: config,
                                screen: ScreenMetrics(width: screenWidth, height: screenHeight),
                                transition: 0)
    let required = geometry.minimumThumbnailPixels(backingScale: backingScale,
                                                   widestAspect: widest)
    let pixels = max(config.thumbMaxPx, required)
    if wantsJSON(rest) {
        emit(["thumbPixels": pixels, "required": required,
              "configured": config.thumbMaxPx, "widestAspect": widest])
    } else {
        print(String(pixels))
    }
    exit(0)

case "--dump-geometry":
    let library = loadLibrary()
    let width = value(of: "--width", in: rest).flatMap(Double.init) ?? 1512
    let height = value(of: "--height", in: rest).flatMap(Double.init) ?? 982
    let transition = transitionValue(rest)
    let current = setter.currentWallpaperURL()?.path
    let engine = LayoutEngine(config: config,
                              screen: ScreenMetrics(width: width, height: height),
                              transition: transition)
    let slots = engine.slots(count: library.count,
                             focus: focusIndex(in: library, currentPath: current))
    print("transition=\(transition) slots=\(slots.count) screen=\(Int(width))x\(Int(height))")
    for slot in slots {
        print(String(format: "  slot %d  offset %+d  index %d  zPos %7.1f  alpha %.2f  midW %6.1f  h %6.1f  skew %+.2f  box x=%7.1f y=%6.1f w=%6.1f  centreX %7.1f",
                     slot.slot, slot.offset, slot.index, slot.zPosition, slot.alpha,
                     slot.width, slot.height, slot.skew,
                     slot.rect.minX, slot.rect.minY, slot.rect.width,
                     slot.rect.midX))
    }
    exit(0)

case "--pick":
    // One picker at a time. A second press asks the running one to close instead of stacking
    // another overlay, which is what a duplicate skhd binding would otherwise cause.
    guard SingleInstance.acquire(at: paths.lockFile) != nil else {
        if !SingleInstance.askHolderToDismiss(at: paths.lockFile) {
            writeError("another picker is already open")
            exit(3)
        }
        exit(0)
    }

    // SIGUSR1 means "dismiss". A dispatch source is used rather than signal() because the
    // handler has to run Swift code, which is not safe from a real signal handler.
    signal(SIGUSR1, SIG_IGN)
    let dismissSource = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
    dismissSource.setEventHandler { exit(2) }
    dismissSource.resume()

    let library = loadLibrary()
    guard !library.isEmpty else {
        writeError("no wallpapers found in " + config.wallpaperDirs.joined(separator: ", "))
        exit(2)
    }
    let current = setter.currentWallpaperURL()?.path
    // Opens resting, then the morph to the preview is driven by pointer entry, which is
    // the transition the design calls for. Per-card hover and the anti-spin guards are M5b.
    PickerApp.run(config: config,
                  paths: paths,
                  library: library,
                  focusIndex: focusIndex(in: library, currentPath: current),
                  currentPath: current,
                  startsExpanded: !config.expandOnEnter,
                  runForMs: value(of: "--run-for", in: rest).flatMap(Int.init) ?? 0,
                  launchedAt: launchedAt)

default:
    print(usageText)
    exit(0)
}
