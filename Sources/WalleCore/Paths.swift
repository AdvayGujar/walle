import Foundation

/// Resolved locations for everything walle reads or writes.
/// Every path is overridable by environment variable so development and tests
/// never touch the real user configuration, cache or wallpaper.
public struct WallePaths: Sendable, Equatable {
    public var home: URL
    public var configFile: URL
    public var dataDir: URL
    public var cacheDir: URL

    public init(home: URL, configFile: URL, dataDir: URL, cacheDir: URL) {
        self.home = home
        self.configFile = configFile
        self.dataDir = dataDir
        self.cacheDir = cacheDir
    }

    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL? = nil
    ) -> WallePaths {
        let homeURL = home ?? FileManager.default.homeDirectoryForCurrentUser
        let env = environment

        func value(_ key: String) -> String? {
            guard let v = env[key], !v.isEmpty else { return nil }
            return v
        }
        func expand(_ raw: String) -> URL { walleExpand(raw, home: homeURL) }

        let xdgConfig = value("XDG_CONFIG_HOME")
        let configFile = value("WALLE_CONFIG").map(expand)
            ?? xdgConfig.map { URL(fileURLWithPath: $0).appendingPathComponent("walle/config") }
            ?? homeURL.appendingPathComponent(".config/walle/config")

        let xdgData = value("XDG_DATA_HOME")
        let dataDir = value("WALLE_DATA_DIR").map(expand)
            ?? xdgData.map { URL(fileURLWithPath: $0).appendingPathComponent("walle") }
            ?? homeURL.appendingPathComponent("Library/Application Support/walle")

        let xdgCache = value("XDG_CACHE_HOME")
        let cacheDir = value("WALLE_CACHE_DIR").map(expand)
            ?? xdgCache.map { URL(fileURLWithPath: $0).appendingPathComponent("walle") }
            ?? homeURL.appendingPathComponent("Library/Caches/walle")

        return WallePaths(home: homeURL, configFile: configFile, dataDir: dataDir,
                          cacheDir: cacheDir)
    }

    public var thumbnailsDir: URL { cacheDir.appendingPathComponent("thumbs") }
    public var historyFile: URL { dataDir.appendingPathComponent("history.jsonl") }
    public var stateFile: URL { dataDir.appendingPathComponent("state.json") }
    public var lockFile: URL { dataDir.appendingPathComponent("picker.lock") }
}

/// Expands a leading tilde and leaves everything else alone.
public func walleExpand(_ raw: String, home: URL) -> URL {
    if raw == "~" { return home }
    if raw.hasPrefix("~/") {
        let rest = String(raw.dropFirst(2))
        return home.appendingPathComponent(rest)
    }
    return URL(fileURLWithPath: raw)
}
