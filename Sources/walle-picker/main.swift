import AppKit
import Foundation
import WalleCore
import WalleKit

// walle-picker is the only part of walle that links AppKit and talks to the window
// server. The walle CLI never links AppKit: when it needs to change the desktop or read
// the current wallpaper it execs this binary.

let arguments = Array(CommandLine.arguments.dropFirst())

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

func makeProvider() -> ThumbnailProvider {
    ThumbnailProvider(
        cache: ThumbnailCache(directory: paths.thumbnailsDir,
                              rowMaxPx: config.thumbMaxPx,
                              previewMaxPx: config.previewMaxPx),
        rowMaxPx: config.thumbMaxPx,
        previewMaxPx: config.previewMaxPx)
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

    // History is recorded only after the desktop actually changed.
    let history = HistoryStore(fileURL: paths.historyFile)
    try? history.append(HistoryEntry(path: url.path, appliedAt: Date(),
                                     screenUUID: nil, mode: "cli"))
    let stateStore = StateStore(fileURL: paths.stateFile)
    var state = stateStore.load()
    state.lastAppliedPath = url.path
    try? stateStore.save(state)

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
    let collapsed = rest.contains("--collapsed")
    let debugColours = rest.contains("--debug-tiles")

    let library = loadLibrary()
    guard !library.isEmpty else {
        writeError("no wallpapers found; run walle list to check the library")
        exit(1)
    }
    let current = setter.currentWallpaperURL()?.path
    let view = CorridorView(frame: CGRect(x: 0, y: 0, width: width, height: height),
                            config: config,
                            provider: makeProvider(),
                            currentPath: current,
                            expanded: !collapsed,
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

case "--dump-geometry":
    let library = loadLibrary()
    let width = value(of: "--width", in: rest).flatMap(Double.init) ?? 1512
    let height = value(of: "--height", in: rest).flatMap(Double.init) ?? 982
    let expanded = !rest.contains("--collapsed")
    let current = setter.currentWallpaperURL()?.path
    let aspect = library.first?.aspectRatio ?? (config.tileWidth / config.tileHeight)
    let engine = LayoutEngine(config: config,
                              screen: ScreenMetrics(width: width, height: height),
                              expanded: expanded)
    let slots = engine.slots(count: library.count,
                             focus: focusIndex(in: library, currentPath: current),
                             centerAspect: aspect)
    print("expanded=\(expanded) slots=\(slots.count) screen=\(Int(width))x\(Int(height))")
    for slot in slots {
        print(String(format: "  slot %d  offset %+d  index %d  zPos %7.1f  alpha %.2f  shear %+.2f  rect x=%7.1f y=%7.1f w=%6.1f h=%6.1f  top=%.1f",
                     slot.slot, slot.offset, slot.index, slot.zPosition, slot.alpha,
                     slot.shear, slot.rect.minX, slot.rect.minY,
                     slot.rect.width, slot.rect.height, slot.rect.maxY))
    }
    exit(0)

case "--pick":
    let library = loadLibrary()
    guard !library.isEmpty else {
        writeError("no wallpapers found in " + config.wallpaperDirs.joined(separator: ", "))
        exit(2)
    }
    let current = setter.currentWallpaperURL()?.path
    // M4 opens expanded so the centred preview is visible; M5 adds collapse-on-open
    // and expand-on-pointer-entry using config.expandOnEnter.
    PickerApp.run(config: config,
                  paths: paths,
                  library: library,
                  focusIndex: focusIndex(in: library, currentPath: current),
                  currentPath: current,
                  startsExpanded: true)

default:
    print(usageText)
    exit(0)
}
