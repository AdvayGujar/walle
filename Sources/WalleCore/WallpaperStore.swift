import Foundation

/// Access to macOS's per-Space wallpaper store.
///
/// macOS keeps the desktop picture per Space. `~/Library/Application Support/
/// com.apple.wallpaper/Store/Index.plist` holds a `Spaces` dictionary keyed by Space UUID, with
/// an empty-string key acting as the default. `NSWorkspace.setDesktopImageURL` — the only
/// public API, and what System Settings itself calls — writes the default *and the Space you
/// are currently on*, and leaves every other Space's entry untouched. That is why a wallpaper
/// change appears to affect only the desktop you are looking at.
///
/// This file is private implementation detail of macOS, not a supported interface. Everything
/// here is therefore written defensively: changes are backed up first, and a missing or
/// differently-shaped store is reported rather than guessed at.
public enum WallpaperStore {

    /// The real store, unless WALLE_WALLPAPER_STORE points somewhere else. The override exists
    /// so the logic can be tested against a copy instead of the live system.
    public static func indexURL(
        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["WALLE_WALLPAPER_STORE"], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/com.apple.wallpaper/Store/Index.plist")
    }

    public struct SpaceSummary: Sendable {
        public let key: String
        public let isDefault: Bool
        public let lastSet: Date?
        /// Whether this Space shows the same picture as the default. A Space can have its own
        /// entry that happens to match, which is not the same as having no entry at all.
        public let matchesDefault: Bool
        public var label: String { isDefault ? "(default)" : key }
    }

    public enum StoreError: Error, CustomStringConvertible {
        case missing(String)
        case unreadable(String)
        case unexpectedShape(String)

        public var description: String {
            switch self {
            case .missing(let path): return "no wallpaper store at " + path
            case .unreadable(let why): return "could not read the wallpaper store: " + why
            case .unexpectedShape(let why): return "unexpected wallpaper store layout: " + why
            }
        }
    }

    static func readRoot(at url: URL) throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw StoreError.missing(url.path)
        }
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw StoreError.unreadable("empty file")
        }
        do {
            guard let root = try PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any] else {
                throw StoreError.unexpectedShape("root is not a dictionary")
            }
            return root
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.unreadable(error.localizedDescription)
        }
    }

    static func desktop(ofSpaceKey key: String, in spaces: [String: Any]) -> [String: Any]? {
        guard let entry = spaces[key] as? [String: Any],
              let fallback = entry["Default"] as? [String: Any] else { return nil }
        return fallback["Desktop"] as? [String: Any]
    }

    /// Every Space key in the store, default first.
    public static func spaces(at url: URL) throws -> [SpaceSummary] {
        let root = try readRoot(at: url)
        guard let spaces = root["Spaces"] as? [String: Any] else {
            throw StoreError.unexpectedShape("no Spaces dictionary")
        }
        let defaultNode = (spaces[""] as? [String: Any])?["Default"] as? [String: Any]
        return spaces.keys.sorted { ($0.isEmpty ? "" : $0) < ($1.isEmpty ? "" : $1) }.map { key in
            let node = (spaces[key] as? [String: Any])?["Default"] as? [String: Any]
            let matches: Bool
            if let defaultNode, let node {
                matches = (node as NSDictionary).isEqual(defaultNode as NSDictionary)
            } else {
                matches = false
            }
            return SpaceSummary(key: key,
                                isDefault: key.isEmpty,
                                lastSet: node?["LastSet"] as? Date,
                                matchesDefault: matches)
        }
    }

    /// The image the default Space points at, when it is a plain image rather than a dynamic
    /// wallpaper or an aerial.
    public static func defaultImagePath(at url: URL) throws -> String? {
        let root = try readRoot(at: url)
        guard let spaces = root["Spaces"] as? [String: Any],
              let desktopNode = desktop(ofSpaceKey: "", in: spaces),
              let content = desktopNode["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              let first = choices.first,
              let config = first["Configuration"] as? Data, !config.isEmpty,
              let inner = try? PropertyListSerialization.propertyList(
                from: config, options: [], format: nil) as? [String: Any],
              let raw = (inner["url"] as? [String: Any])?["relative"] as? String else {
            return nil
        }
        return URL(string: raw)?.path ?? raw
    }

    public struct SyncResult: Sendable {
        public let updated: [String]
        public let alreadyMatching: [String]
        public let backupPath: String?
    }

    /// Copies the default Space's desktop picture onto every other Space.
    ///
    /// This is the only way to get one wallpaper across every Space: the public API offers no
    /// way to address another Space, and system events' `every desktop` resolves to the current
    /// Space only on current macOS.
    @discardableResult
    public static func applyDefaultToAllSpaces(at url: URL) throws -> SyncResult {
        let root = try readRoot(at: url)
        guard let spaces = root["Spaces"] as? [String: Any] else {
            throw StoreError.unexpectedShape("no Spaces dictionary")
        }
        guard let defaultEntry = spaces[""] as? [String: Any],
              let defaultDesktop = defaultEntry["Default"] as? [String: Any] else {
            throw StoreError.unexpectedShape("no default Space entry to copy from")
        }

        // Back up before touching anything, so a bad result can be undone.
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("Index.plist.walle-backup")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: url, to: backup)
        let backupPath = FileManager.default.fileExists(atPath: backup.path) ? backup.path : nil

        // Compare with NSDictionary's deep equality. Serialising and comparing bytes would be
        // wrong: two equal dictionaries routinely produce different bytes, because property
        // list key order is not fixed. That bug made the sync non-idempotent.
        let wanted = defaultDesktop as NSDictionary

        var updated: [String] = []
        var alreadyMatching: [String] = []
        var newSpaces = spaces
        for key in spaces.keys.sorted() where !key.isEmpty {
            guard var entry = spaces[key] as? [String: Any] else { continue }
            // Compare as property lists rather than by identity, so a Space that already
            // matches is left completely alone and only genuinely stale ones are rewritten.
            if let existing = entry["Default"] as? [String: Any],
               (existing as NSDictionary).isEqual(wanted) {
                alreadyMatching.append(key)
                continue
            }
            entry["Default"] = defaultDesktop
            newSpaces[key] = entry
            updated.append(key)
        }

        guard !updated.isEmpty else {
            return SyncResult(updated: [], alreadyMatching: alreadyMatching, backupPath: backupPath)
        }

        var newRoot = root
        newRoot["Spaces"] = newSpaces
        let data = try PropertyListSerialization.data(fromPropertyList: newRoot,
                                                      format: .binary, options: 0)
        try data.write(to: url, options: .atomic)

        // Only poke the live agent when we actually wrote the live store. Running against a
        // copy (via WALLE_WALLPAPER_STORE) must have no effect on the running system.
        if url.path == indexURL(environment: [:]).path {
            restartWallpaperAgent()
        }
        return SyncResult(updated: updated, alreadyMatching: alreadyMatching, backupPath: backupPath)
    }

    /// WallpaperAgent caches the store, so it has to be restarted for a direct write to show.
    /// Failure is not fatal: the store is already written and will be read on next login.
    static func restartWallpaperAgent() {
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["WallpaperAgent"]
        kill.standardOutput = FileHandle.nullDevice
        kill.standardError = FileHandle.nullDevice
        try? kill.run()
        kill.waitUntilExit()
    }
}
