import Foundation

/// The hidden cache behind `upscale = on`.
///
/// Sources stay exactly where the user put them; the picker, `next`/`prev` and
/// history all keep talking about those source paths. Only the file handed to
/// NSWorkspace is swapped for a cached HEIC copy when one is fresh.
public struct UpscaleCache: Sendable {
    public let root: URL

    public init(root: URL, fileManager: FileManager = .default) {
        self.root = root
    }

    public init(paths: WallePaths, model: String, target: PixelSize,
                fileManager: FileManager = .default) {
        self.init(root: Self.root(paths: paths, model: model, target: target),
                  fileManager: fileManager)
    }

    /// Reloaded on demand so a cache fill that finishes while the picker is
    /// open is visible to the next apply.
    public var manifest: UpscaleManifest {
        UpscaleManifest.load(from: root.appendingPathComponent("manifest.json"))
    }

    public static func root(paths: WallePaths, model: String, target: PixelSize) -> URL {
        paths.upscaledDir
            .appendingPathComponent("cache")
            .appendingPathComponent(walleSafeUpscaleModelName(model))
            .appendingPathComponent(target.description)
    }

    /// A fresh cached HEIC for this source, or nil when the cache is missing,
    /// stale, or was built for a different source version.
    public func cachedURL(for source: URL, fileManager: FileManager = .default) -> URL? {
        let sourcePath = walleCanonicalPath(source.path)
        guard let entry = manifest.entries.first(where: {
            walleCanonicalPath($0.source) == sourcePath
        }) else { return nil }
        let output = root.appendingPathComponent(entry.output)
        guard fileManager.fileExists(atPath: output.path) else { return nil }
        guard let attributes = try? fileManager.attributesOfItem(atPath: sourcePath),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        guard size == entry.sourceBytes,
              abs(modified.timeIntervalSince1970 - entry.sourceMtime) < 0.0001 else {
            return nil
        }
        return output
    }

    /// The source path for a cached output, used to keep `walle current` and
    /// picker focus talking about the image the user chose.
    public func source(forOutput output: URL) -> String? {
        let target = walleCanonicalPath(output.path)
        return manifest.entries.first {
            walleCanonicalPath(root.appendingPathComponent($0.output).path) == target
        }?.source
    }

    /// Checks the state file first, then all cache namespaces. Used by
    /// `walle current` so the hidden cache path never leaks into normal output.
    public static func sourceForCurrent(paths: WallePaths, displayPath: String) -> String? {
        let state = StateStore(fileURL: paths.stateFile).load()
        let display = walleCanonicalPath(displayPath)
        if let lastDisplay = state.lastDisplayPath,
           walleCanonicalPath(lastDisplay) == display,
           let source = state.lastAppliedPath {
            return source
        }
        for root in cacheRoots(paths: paths) {
            if let source = UpscaleCache(root: root).source(forOutput: URL(fileURLWithPath: displayPath)) {
                return source
            }
        }
        return nil
    }

    /// Removes cached copies whose source is gone or changed, and orphan HEIC
    /// files. Called when the picker opens and when `walle upscale` runs, so a
    /// deleted source directory eventually takes its cache with it.
    @discardableResult
    public static func pruneAll(paths: WallePaths,
                                fileManager: FileManager = .default) -> (files: Int, entries: Int) {
        var removedFiles = 0
        var removedEntries = 0
        for root in cacheRoots(paths: paths) {
            let manifestURL = root.appendingPathComponent("manifest.json")
            var manifest = UpscaleManifest.load(from: manifestURL)
            var kept: [UpscaleManifest.Entry] = []
            for entry in manifest.entries {
                let source = URL(fileURLWithPath: entry.source)
                let output = root.appendingPathComponent(entry.output)
                let attributes = try? fileManager.attributesOfItem(atPath: source.path)
                let size = (attributes?[.size] as? NSNumber)?.intValue
                let modified = attributes?[.modificationDate] as? Date
                let fresh = size == entry.sourceBytes
                    && modified.map {
                        abs($0.timeIntervalSince1970 - entry.sourceMtime) < 0.0001
                    } == true
                if fresh, fileManager.fileExists(atPath: output.path) {
                    kept.append(entry)
                } else {
                    removedEntries += 1
                    if fileManager.fileExists(atPath: output.path) {
                        try? fileManager.removeItem(at: output)
                        removedFiles += 1
                    }
                }
            }

            let used = Set(kept.map { $0.output })
            if let files = try? fileManager.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil) {
                for file in files where file.pathExtension.lowercased() == "heic" {
                    if !used.contains(file.lastPathComponent) {
                        try? fileManager.removeItem(at: file)
                        removedFiles += 1
                    }
                }
            }

            if kept.count != manifest.entries.count {
                manifest.entries = kept
                if kept.isEmpty {
                    try? fileManager.removeItem(at: manifestURL)
                    try? fileManager.removeItem(at: root)
                } else {
                    try? manifest.save(to: manifestURL)
                }
            }
        }
        return (removedFiles, removedEntries)
    }

    /// Starts a detached `walle upscale --refresh` so new images are cached
    /// without making the user run a command. It is deliberately fire-and-forget:
    /// the child exits when done, so no walle process stays resident. If a fill
    /// is already running, the lock makes the new one a no-op.
    @discardableResult
    public static func refreshInBackground(
        paths: WallePaths, environment: [String: String], enabled: Bool,
        extraArguments: [String] = [],
        fileManager: FileManager = .default
    ) -> Bool {
        guard enabled else { return false }
        guard let cli = CLILocator.locate(environment: environment,
                                          fileManager: fileManager) else { return false }

        if SingleInstance.isHeld(at: paths.upscaleLockFile) {
            // A fill is already running. Leave a marker; that fill starts one
            // more pass after it finishes, so a directory added mid-fill is not
            // forgotten.
            try? fileManager.createDirectory(
                at: paths.upscalePendingRefresh.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            _ = fileManager.createFile(atPath: paths.upscalePendingRefresh.path,
                                       contents: nil)
            return true
        }

        let logURL = paths.upscaleRefreshLog
        try? fileManager.createDirectory(at: logURL.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: logURL.path) {
            _ = fileManager.createFile(atPath: logURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return false }
        _ = try? handle.seekToEnd()

        let arguments = ["upscale", "--refresh"] + extraArguments
        let process = Process()
        // nohup keeps the fill alive if the terminal that started it closes; the
        // child still exits as soon as the cache is current, so nothing is daemonic.
        let nohup = URL(fileURLWithPath: "/usr/bin/nohup")
        if fileManager.isExecutableFile(atPath: nohup.path) {
            process.executableURL = nohup
            process.arguments = [cli.path] + arguments
        } else {
            process.executableURL = cli
            process.arguments = arguments
        }
        var childEnvironment = environment
        childEnvironment["WALLE_CLI"] = cli.path
        process.environment = childEnvironment
        process.standardOutput = handle
        process.standardError = handle
        do {
            try process.run()
        } catch {
            try? handle.close()
            return false
        }
        // The child owns its duplicated descriptor; the caller does not wait.
        try? handle.close()
        return true
    }

    /// Every `<model>/<target>` cache directory currently on disk.
    public static func cacheRoots(paths: WallePaths,
                                  fileManager: FileManager = .default) -> [URL] {
        let base = paths.upscaledDir.appendingPathComponent("cache")
        guard let models = try? fileManager.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var roots: [URL] = []
        for model in models {
            guard let targets = try? fileManager.contentsOfDirectory(
                at: model, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for target in targets {
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: target.path, isDirectory: &isDirectory),
                      isDirectory.boolValue else { continue }
                roots.append(target)
            }
        }
        return roots
    }
}

/// Model names become one path component under the cache, never a path escape.
public func walleSafeUpscaleModelName(_ model: String) -> String {
    let safe = model.replacingOccurrences(of: "/", with: "-")
        .replacingOccurrences(of: ":", with: "-")
        .trimmingCharacters(in: .whitespaces)
    return safe.isEmpty ? "model" : safe
}
