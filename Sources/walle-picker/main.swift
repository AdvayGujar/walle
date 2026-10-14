import AppKit
import Foundation
import WalleCore
import WalleKit

// walle-picker is the only part of walle that links AppKit and talks to the window
// server. M3 ships its headless modes; the interactive picker arrives in M4.
//
// The walle CLI never links AppKit. When it needs to change the desktop it execs this
// binary, which costs one exec rather than loading AppKit into the CLI as well.

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

let usageText = """
walle-picker - the macOS half of walle

Normally launched for you by the walle CLI:
  walle pick                open the picker
  walle set <path>          apply a wallpaper

HEADLESS MODES
  --apply <path> [--json]   apply a wallpaper and exit
  --current [--json]        print the current desktop wallpaper
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

if arguments.isEmpty || arguments.contains("--help") || arguments.contains("-h") {
    print(usageText)
    exit(0)
}

let command = arguments[0]
let rest = Array(arguments.dropFirst())

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

default:
    print(usageText)
    exit(0)
}
