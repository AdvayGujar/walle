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

    /// The image a Desktop node points at, when it is a plain image rather than a dynamic
    /// wallpaper or an aerial.
    static func imagePath(ofDesktop desktop: [String: Any]) -> String? {
        guard let content = desktop["Content"] as? [String: Any],
              let choices = content["Choices"] as? [[String: Any]],
              let first = choices.first,
              let config = first["Configuration"] as? Data, !config.isEmpty,
              let inner = try? PropertyListSerialization.propertyList(
                from: config, options: [], format: nil) as? [String: Any],
              let raw = (inner["url"] as? [String: Any])?["relative"] as? String
        else { return nil }
        return URL(string: raw)?.path ?? raw
    }

    /// The image the default Space points at.
    public static func defaultImagePath(at url: URL) throws -> String? {
        let root = try readRoot(at: url)
        guard let spaces = root["Spaces"] as? [String: Any],
              let desktopNode = desktop(ofSpaceKey: "", in: spaces) else { return nil }
        return imagePath(ofDesktop: desktopNode)
    }

    /// A Desktop node pointing at `path`, reusing the option values (crop, colour, placement)
    /// from `template` and replacing only the image reference.
    ///
    /// This is what makes the sync correct rather than merely plausible.
    /// §setDesktopImageURL§ persists asynchronously, so reading the store immediately after
    /// applying still returns the PREVIOUS wallpaper. Copying that over every Space is
    /// indistinguishable from "applying did nothing at all", which is exactly the symptom.
    static func desktopNode(forPath path: String, using template: [String: Any]) -> [String: Any]? {
        guard let content = template["Content"] as? [String: Any],
              var choices = content["Choices"] as? [[String: Any]],
              !choices.isEmpty else { return nil }
        let reference: [String: Any] = ["type": "imageFile",
                                        "url": ["relative": URL(fileURLWithPath: path).absoluteString]]
        guard let configuration = try? PropertyListSerialization.data(
            fromPropertyList: reference, format: .binary, options: 0) else { return nil }

        choices[0]["Configuration"] = configuration
        choices[0]["Files"] = choices[0]["Files"] ?? [Any]()
        choices[0]["Provider"] = "com.apple.wallpaper.choice.image"
        var newContent = content
        newContent["Choices"] = choices
        var node = template
        node["Content"] = newContent
        node["LastSet"] = Date()
        return node
    }

    /// Which Space's entry to copy from.
    ///
    /// The default is NOT reliable as a source. Once each Space has its own entry,
    /// §setDesktopImageURL§ updates only the Space you are on and leaves the default alone, so
    /// copying the default silently reverts the wallpaper that was just applied. Prefer the
    /// entry pointing at the wallpaper the user picked, and fall back to the most recent one.
    static func sourceSpaceKey(for path: String?, in spaces: [String: Any]) -> String? {
        var candidates: [(key: String, image: String?, when: Date)] = []
        for (key, value) in spaces {
            // LastSet lives under Default -> Desktop, not under Default. Reading it one level
            // too high made every entry look equally old, so the "most recent" fallback picked
            // arbitrarily instead of picking the wallpaper that was actually just applied.
            guard let entry = value as? [String: Any],
                  let node = entry["Default"] as? [String: Any],
                  let nodeDesktop = node["Desktop"] as? [String: Any] else { continue }
            candidates.append((key, imagePath(ofDesktop: nodeDesktop),
                               nodeDesktop["LastSet"] as? Date ?? .distantPast))
        }
        guard !candidates.isEmpty else { return nil }
        if let path {
            let wanted = (path as NSString).standardizingPath
            let matching = candidates.filter {
                guard let image = $0.image else { return false }
                return (image as NSString).standardizingPath == wanted
            }
            if let best = matching.max(by: { $0.when < $1.when }) { return best.key }
        }
        return candidates.max(by: { $0.when < $1.when })?.key
    }

    public struct SyncResult: Sendable {
        /// Spaces that had an entry showing something else and were rewritten.
        public let updated: [String]
        /// Spaces that had no entry at all and were given one.
        public let created: [String]
        public let alreadyMatching: [String]
        /// Store entries for Spaces that no longer exist.
        public let stale: [String]
        public let pruned: [String]
        public let backupPath: String?

        public var changedAnything: Bool { !updated.isEmpty || !created.isEmpty || !pruned.isEmpty }
    }

    /// The Spaces macOS knows about, split by kind.
    ///
    /// A monitor record carries the Spaces you can switch to, plus a "Collapsed Space" for each
    /// display that is not currently showing a desktop. Note that a real Space can have an
    /// EMPTY uuid — the store keys it as "" — so an empty uuid is not "no Space" and must not be
    /// filtered out. That mistake is what made the count wrong and left a real Space unsynced.
    public struct SpaceInventory: Sendable {
        /// Spaces listed on a monitor, which are the ones you can actually switch between.
        public let switchable: [String]
        /// Spaces belonging to collapsed displays.
        public let collapsed: [String]
        /// Everything, which is what a sync has to cover.
        public var all: [String] { Array(Set(switchable + collapsed)).sorted() }
        public var isKnown: Bool { !switchable.isEmpty || !collapsed.isEmpty }
    }

    public static func spaceInventory(preferencesURL: URL? = nil) -> SpaceInventory {
        let url = preferencesURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.spaces.plist")
        guard let data = FileManager.default.contents(atPath: url.path),
              let root = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any],
              let config = root["SpacesDisplayConfiguration"] as? [String: Any] else {
            return SpaceInventory(switchable: [], collapsed: [])
        }

        var management = config["Management Data"] as? [String: Any]
        if management == nil, let blob = config["Management Data"] as? Data,
           let inner = try? PropertyListSerialization.propertyList(
            from: blob, options: [], format: nil) as? [String: Any] {
            management = inner
        }
        guard let monitors = management?["Monitors"] as? [[String: Any]] else {
            return SpaceInventory(switchable: [], collapsed: [])
        }

        var switchable: [String] = []
        var collapsed: [String] = []
        for monitor in monitors {
            for space in monitor["Spaces"] as? [[String: Any]] ?? [] {
                // An empty uuid is a real Space, so only require that the key exists.
                if let uuid = space["uuid"] as? String { switchable.append(uuid) }
            }
            if let folded = monitor["Collapsed Space"] as? [String: Any],
               let uuid = folded["uuid"] as? String {
                collapsed.append(uuid)
            }
        }
        return SpaceInventory(switchable: Array(Set(switchable)).sorted(),
                              collapsed: Array(Set(collapsed)).sorted())
    }

    /// Every Space a sync needs to cover.
    public static func liveSpaceUUIDs(preferencesURL: URL? = nil) -> [String] {
        let inventory = spaceInventory(preferencesURL: preferencesURL)
        return inventory.isKnown ? inventory.all : []
    }

    /// The Spaces that actually exist right now, from com.apple.spaces.
    ///
    /// This matters because the two lists drift apart in both directions. Creating a Space makes
    /// macOS add an entry to the wallpaper store, but deleting a Space leaves its entry behind
    /// forever, so the store accumulates keys for Spaces that are gone. Comparing the two is the
    /// only way to know which Spaces still need a wallpaper.
    static func legacyLiveSpaceUUIDs(preferencesURL: URL? = nil) -> [String] {
        let url = preferencesURL ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Preferences/com.apple.spaces.plist")
        guard let data = FileManager.default.contents(atPath: url.path),
              let root = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil) as? [String: Any] else { return [] }

        // Preferred source: the per-monitor Space lists. A monitor record also carries
        // "Collapsed Space" entries for displays that are not showing a desktop, and those are
        // not Spaces the user can switch to. Counting them made walle report more Spaces than
        // actually exist.
        if let config = root["SpacesDisplayConfiguration"] as? [String: Any] {
            var management = config["Management Data"] as? [String: Any]
            if management == nil, let blob = config["Management Data"] as? Data,
               let inner = try? PropertyListSerialization.propertyList(
                from: blob, options: [], format: nil) as? [String: Any] {
                management = inner
            }
            if let monitors = management?["Monitors"] as? [[String: Any]] {
                var fromMonitors: [String] = []
                for monitor in monitors {
                    for space in monitor["Spaces"] as? [[String: Any]] ?? [] {
                        if let uuid = space["uuid"] as? String, !uuid.isEmpty {
                            fromMonitors.append(uuid)
                        }
                    }
                }
                if !fromMonitors.isEmpty {
                    return Array(Set(fromMonitors)).sorted()
                }
            }
        }

        // Fallback for a layout we do not recognise: collect every uuid we can find, which may
        // over-count, but keeps the sync working rather than doing nothing.
        var found: Set<String> = []
        func walk(_ node: Any) {
            if let dict = node as? [String: Any] {
                if let uuid = dict["uuid"] as? String, !uuid.isEmpty { found.insert(uuid) }
                for value in dict.values { walk(value) }
            } else if let array = node as? [Any] {
                for value in array { walk(value) }
            } else if let nested = node as? Data,
                      let inner = try? PropertyListSerialization.propertyList(
                        from: nested, options: [], format: nil) {
                walk(inner)
            }
        }
        walk(root)
        return found.sorted()
    }

    /// Copies the current desktop picture onto every Space.
    ///
    /// This is the only way to get one wallpaper across every Space: the public API offers no
    /// way to address another Space, and System Events' `every desktop` resolves to the current
    /// Space only on current macOS.
    ///
    /// `sourcePath` is the wallpaper that was just applied, so the copy starts from what the
    /// user actually chose rather than from a default that macOS may not have updated.
    @discardableResult
    public static func applyDefaultToAllSpaces(at url: URL,
                                               liveSpaces: [String]? = nil,
                                               sourcePath: String? = nil,
                                               pruneStale: Bool = false) throws -> SyncResult {
        let root = try readRoot(at: url)
        guard let spaces = root["Spaces"] as? [String: Any] else {
            throw StoreError.unexpectedShape("no Spaces dictionary")
        }
        guard let sourceKey = sourceSpaceKey(for: sourcePath, in: spaces),
              let sourceSpaceEntry = spaces[sourceKey] as? [String: Any],
              var sourceDesktop = sourceSpaceEntry["Default"] as? [String: Any] else {
            throw StoreError.unexpectedShape("no Space entry to copy from")
        }

        // When we know which wallpaper was just applied, build the entry from that path rather
        // than trusting the store, which may not have caught up yet.
        if let sourcePath,
           let built = desktopNode(forPath: sourcePath, using: sourceDesktop) {
            sourceDesktop = built
        }

        // Which Spaces exist. Falling back to the store's own keys keeps this working on a
        // machine where com.apple.spaces cannot be read, at the cost of not noticing stale ones.
        let live = liveSpaces ?? liveSpaceUUIDs()
        let wantedKeys = live.isEmpty ? spaces.keys.sorted() : live

        // Back up before touching anything, so a bad result can be undone.
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("Index.plist.walle-backup")
        try? FileManager.default.removeItem(at: backup)
        try? FileManager.default.copyItem(at: url, to: backup)
        let backupPath = FileManager.default.fileExists(atPath: backup.path) ? backup.path : nil

        // Compare with NSDictionary's deep equality. Serialising and comparing bytes would be
        // wrong: two equal dictionaries routinely produce different bytes, because property
        // list key order is not fixed. That bug made the sync non-idempotent.
        let wanted = sourceDesktop as NSDictionary

        var updated: [String] = []
        var created: [String] = []
        var alreadyMatching: [String] = []
        var newSpaces = spaces

        for key in wantedKeys.sorted() {
            guard var entry = spaces[key] as? [String: Any] else {
                // This Space exists but the store has never heard of it, so clone the source
                // entry wholesale: it already has precisely the shape macOS expects.
                newSpaces[key] = sourceSpaceEntry
                created.append(key)
                continue
            }
            // Compare as property lists rather than by identity, so a Space that already
            // matches is left completely alone and only genuinely stale ones are rewritten.
            if let existing = entry["Default"] as? [String: Any],
               (existing as NSDictionary).isEqual(wanted) {
                alreadyMatching.append(key)
                continue
            }
            entry["Default"] = sourceDesktop
            newSpaces[key] = entry
            updated.append(key)
        }

        // The store's "" key is the Space whose uuid is empty, not a fallback, so it is
        // covered by the loop above like any other Space.

        // Delete the leftovers. Nothing else references them, but they are dead weight and
        // would silently resurface if macOS ever reused the UUID.
        let stale = spaces.keys.filter { !$0.isEmpty && !wantedKeys.contains($0) }.sorted()
        var pruned: [String] = []
        if pruneStale {
            for key in stale {
                newSpaces.removeValue(forKey: key)
                pruned.append(key)
            }
        }

        guard !updated.isEmpty || !created.isEmpty || !pruned.isEmpty else {
            return SyncResult(updated: [], created: [], alreadyMatching: alreadyMatching,
                              stale: stale, pruned: [], backupPath: backupPath)
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
        return SyncResult(updated: updated, created: created,
                          alreadyMatching: alreadyMatching, stale: stale, pruned: pruned,
                          backupPath: backupPath)
    }

    /// Applies the wallpaper to every Space, when the user has switched that on with
    /// "walle spaces on". Returns a warning rather than throwing, so an apply that already
    /// succeeded is never reported as a failure just because the Space sync did not.
    @discardableResult
    public static func syncIfEnabled(
        _ mode: SpacesMode,
        appliedPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        guard mode == .all else { return nil }
        do {
            _ = try applyDefaultToAllSpaces(at: indexURL(environment: environment),
                                            liveSpaces: liveSpaceUUIDs(),
                                            sourcePath: appliedPath)
            return nil
        } catch {
            return "the wallpaper was applied, but not to every Space: " + String(describing: error)
        }
    }

    /// WallpaperAgent caches the store, so it has to be restarted for a direct write to show.
    /// Failure is not fatal: the store is already written and will be read on next login.
    ///
    /// The pause matters. Restarting the agent instantly after §setDesktopImageURL§ races the
    /// write that the call just queued, and can lose the wallpaper that was being applied.
    static func restartWallpaperAgent() {
        Thread.sleep(forTimeInterval: 0.4)
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        kill.arguments = ["WallpaperAgent"]
        kill.standardOutput = FileHandle.nullDevice
        kill.standardError = FileHandle.nullDevice
        try? kill.run()
        kill.waitUntilExit()
    }
}
