import CoreGraphics
import Darwin
import Dispatch
import Foundation
import ImageIO

/// A single wallpaper discovered on disk.
public struct Wallpaper: Sendable, Equatable {
    /// Canonical location of the image (symlinks resolved).
    public var url: URL
    /// Canonical, absolute filesystem path.
    public var path: String
    /// Filename including its extension.
    public var name: String
    public var modifiedAt: Date
    /// Size in bytes.
    public var fileSize: Int
    /// width / height as stored, or nil when the properties cannot be read.
    public var aspectRatio: Double?

    public init(
        url: URL,
        path: String,
        name: String,
        modifiedAt: Date,
        fileSize: Int,
        aspectRatio: Double?
    ) {
        self.url = url
        self.path = path
        self.name = name
        self.modifiedAt = modifiedAt
        self.fileSize = fileSize
        self.aspectRatio = aspectRatio
    }
}

/// Everything a scan found, plus diagnostics that never abort the walk.
public struct ScanResult: Sendable {
    public var wallpapers: [Wallpaper]
    public var warnings: [String]
    /// How many new entries each root contributed, keyed by the root string as written.
    public var rootCounts: [String: Int]

    public init(wallpapers: [Wallpaper], warnings: [String], rootCounts: [String: Int]) {
        self.wallpapers = wallpapers
        self.warnings = warnings
        self.rootCounts = rootCounts
    }
}

/// Collects results written from concurrent work, by index.
///
/// `DispatchQueue.concurrentPerform` takes a @Sendable closure, so it cannot capture a
/// mutable array or an unsafe buffer pointer without a concurrency warning (and a data
/// race if the indices ever overlap). This box owns the storage behind a lock; the
/// parallel scans and thumbnail batch all write through it.
final class WalleConcurrentResults<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [Value]

    init(repeating value: Value, count: Int) {
        storage = Array(repeating: value, count: count)
    }

    func set(_ value: Value, at index: Int) {
        lock.lock()
        storage[index] = value
        lock.unlock()
    }

    var values: [Value] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

/// The handful of `stat` fields the scan needs, read in one syscall.
///
/// `FileManager.attributesOfItem` builds a full attribute dictionary per file, which
/// measured 152 ms per 2 000 files; `stat(2)` fills the same fields for a fraction of
/// that. Foundation's dictionaries stay in the public API; this is only the hot path.
private struct WalleFileStat {
    var device: UInt64
    var inode: UInt64
    var size: Int
    var modifiedAt: Date
    var isDirectory: Bool
}

/// Follows symlinks, which matches the scanner's historical behaviour of resolving a
/// link before reading its metadata.
private func walleStat(at url: URL) -> WalleFileStat? {
    url.withUnsafeFileSystemRepresentation { rawPath -> WalleFileStat? in
        guard let rawPath else { return nil }
        var info = stat()
        guard stat(rawPath, &info) == 0 else { return nil }
        let seconds = TimeInterval(info.st_mtimespec.tv_sec)
        let nanos = TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return WalleFileStat(
            device: UInt64(info.st_dev),
            inode: UInt64(info.st_ino),
            size: Int(info.st_size),
            modifiedAt: Date(timeIntervalSince1970: seconds + nanos),
            isDirectory: (info.st_mode & S_IFMT) == S_IFDIR)
    }
}

/// Walks the configured wallpaper roots and returns every image it can use.
///
/// The scanner is deliberately forgiving: a broken root becomes a warning and the
/// remaining roots are still scanned. Duplicate images (same canonical path, or the
/// same file reached through a hard link or symlink) collapse to a single entry, and a
/// visited-inode set guarantees a symlink cycle can never hang the walk.
public struct LibraryScanner: Sendable {
    public var config: Config
    public var home: URL
    // FileManager is documented as thread-safe; we only use it synchronously.
    nonisolated(unsafe) private let fileManager: FileManager

    public init(config: Config, home: URL, fileManager: FileManager = .default) {
        self.config = config
        self.home = home
        self.fileManager = fileManager
    }

    /// `seed` only matters for the .random sort; it stays a parameter so callers
    /// (and tests) can make the shuffle reproducible.
    ///
    /// `includeAspectRatio` defaults to on because the picker needs the widest aspect in
    /// the library. Commands that never look at it pass false, which skips one ImageIO
    /// open per file — the single largest cost of a scan.
    public func scan(extraDirs: [String] = [], seed: UInt64 = 0,
                     includeAspectRatio: Bool = true) -> ScanResult {
        var wallpapers: [Wallpaper] = []
        var warnings: [String] = []
        var rootCounts: [String: Int] = [:]
        var seenPaths = Set<String>()
        var seenFileIDs = Set<String>()

        // Records one candidate, or nil when it was already seen.
        func record(_ url: URL, isSymbolicLink: Bool) -> Wallpaper? {
            // The root is resolved once before walking, so ordinary entries are canonical
            // already; only a genuine link costs a resolution here.
            let canonical = isSymbolicLink
                ? url.resolvingSymlinksInPath().standardizedFileURL
                : url.standardizedFileURL
            let path = canonical.path
            if seenPaths.contains(path) { return nil }

            let info = walleStat(at: canonical)
            let device = info?.device ?? 0
            let inode = info?.inode ?? 0
            let fileID = String(device) + ":" + String(inode)
            if inode != 0, seenFileIDs.contains(fileID) { return nil }

            seenPaths.insert(path)
            if inode != 0 { seenFileIDs.insert(fileID) }

            return Wallpaper(
                url: canonical,
                path: path,
                name: canonical.lastPathComponent,
                modifiedAt: info?.modifiedAt ?? Date(timeIntervalSince1970: 0),
                fileSize: info?.size ?? 0,
                aspectRatio: nil)
        }

        // Distinct identity for a directory, used to break symlink cycles. stat follows
        // links, so two paths to one directory share an id and a cycle cannot hang the walk.
        func directoryID(_ url: URL) -> String? {
            if let info = walleStat(at: url), info.inode != 0 {
                return String(info.device) + ":" + String(info.inode)
            }
            return url.resolvingSymlinksInPath().standardizedFileURL.path
        }

        let rawRoots = (config.wallpaperDirs + extraDirs)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        for raw in rawRoots {
            // Resolve the root once. Resolving every walked path cost ~47 ms per 2 000
            // ordinary files; entries under a resolved root are canonical already.
            let rootURL = walleExpand(raw, home: home)
                .resolvingSymlinksInPath()
                .standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory) else {
                warnings.append("wallpaper directory does not exist: " + raw)
                rootCounts[raw] = 0
                continue
            }
            guard isDirectory.boolValue else {
                warnings.append("wallpaper path is not a directory: " + raw)
                rootCounts[raw] = 0
                continue
            }
            guard fileManager.isReadableFile(atPath: rootURL.path) else {
                warnings.append("wallpaper directory is not readable: " + raw)
                rootCounts[raw] = 0
                continue
            }

            var visitedDirectories = Set<String>()
            var contributed = 0

            func walk(_ directory: URL) {
                guard let id = directoryID(directory) else { return }
                if visitedDirectories.contains(id) { return }
                visitedDirectories.insert(id)

                // The listing prefetches these, so reading them below is a cache hit rather
                // than the extra stat that `fileExists`/a second `resourceValues` call made.
                let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isHiddenKey]
                let keySet = Set(keys)
                guard let entries = try? fileManager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: keys, options: []) else {
                    return
                }

                for entry in entries {
                    let name = entry.lastPathComponent
                    // Dot-prefixed names already cover .DS_Store and .localized.
                    if name.hasPrefix(".") { continue }

                    guard let values = try? entry.resourceValues(forKeys: keySet) else { continue }

                    var isDirectory = values.isDirectory ?? false
                    let isSymbolicLink = values.isSymbolicLink ?? false
                    if isSymbolicLink {
                        // A link's resource values describe the link, not its target, so the
                        // target needs one stat. A broken link is skipped, as it was before.
                        guard let target = walleStat(at: entry) else { continue }
                        isDirectory = target.isDirectory
                    }
                    if isDirectory {
                        if config.recursive { walk(entry) }
                        continue
                    }

                    // The hidden flag only filtered files before this refactor; a plain
                    // directory with the Finder invisible bit is still walked, as it was.
                    if values.isHidden == true { continue }
                    guard walleIsImageExtension(name) else { continue }
                    if walleHasFinderInfoSkipFlag(entry) { continue }

                    if let wallpaper = record(entry, isSymbolicLink: isSymbolicLink) {
                        wallpapers.append(wallpaper)
                        contributed += 1
                    }
                }
            }

            walk(rootURL)
            rootCounts[raw] = contributed
        }

        if includeAspectRatio, !wallpapers.isEmpty {
            let ratios = walleAspectRatios(for: wallpapers.map(\.url))
            for index in wallpapers.indices {
                wallpapers[index].aspectRatio = ratios[index]
            }
        }

        return ScanResult(
            wallpapers: LibrarySort.sort(wallpapers, mode: config.sort, seed: seed),
            warnings: warnings,
            rootCounts: rootCounts)
    }
}

/// The image types walle will show, matched case-insensitively by extension.
private let walleImageExtensions: Set<String> = [
    "jpg", "jpeg", "png", "heic", "heif", "avif", "webp", "tiff", "tif", "bmp", "gif",
]

private func walleIsImageExtension(_ name: String) -> Bool {
    let ext = (name as NSString).pathExtension.lowercased()
    return !ext.isEmpty && walleImageExtensions.contains(ext)
}

/// True when the file carries the FinderInfo bundle or invisible flag, which macOS
/// uses to mark application resources that should stay out of a wallpaper library.
private func walleHasFinderInfoSkipFlag(_ url: URL) -> Bool {
    url.withUnsafeFileSystemRepresentation { rawPath -> Bool in
        guard let rawPath else { return false }
        var buffer = [UInt8](repeating: 0, count: 32)
        let readCount = buffer.withUnsafeMutableBytes { bytes -> Int in
            getxattr(rawPath, "com.apple.FinderInfo", bytes.baseAddress, bytes.count, 0, 0)
        }
        // The Finder flags live in bytes 8-9 of the 32-byte FinderInfo structure.
        guard readCount >= 10 else { return false }
        let flags = (UInt16(buffer[8]) << 8) | UInt16(buffer[9])
        let bundleBit: UInt16 = 0x2000
        let invisibleBit: UInt16 = 0x4000
        return (flags & (bundleBit | invisibleBit)) != 0
    }
}

/// Orders wallpapers for the picker.
public enum LibrarySort {

    public static func sort(_ items: [Wallpaper], mode: SortMode, seed: UInt64) -> [Wallpaper] {
        switch mode {
        case .name:
            // Fold each name once. Calling lowercased() inside the comparator allocates
            // two strings per comparison (O(n log n) of them); decorating costs one per
            // item. The case-sensitive and path tie-breaks preserve the old total order.
            return items
                .map { (item: $0, folded: $0.name.lowercased()) }
                .sorted { lhs, rhs in
                    if lhs.folded != rhs.folded { return lhs.folded < rhs.folded }
                    if lhs.item.name != rhs.item.name { return lhs.item.name < rhs.item.name }
                    return lhs.item.path < rhs.item.path
                }
                .map { $0.item }
        case .mtime:
            return items.sorted { lhs, rhs in
                if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt }
                return lhs.path < rhs.path
            }
        case .random:
            var result = items
            guard result.count > 1 else { return result }
            var generator = WalleSplitMix64(seed: seed)
            for index in stride(from: result.count - 1, through: 1, by: -1) {
                let swap = Int(generator.next() % UInt64(index + 1))
                result.swapAt(index, swap)
            }
            return result
        }
    }
}

/// A tiny deterministic PRNG so the random sort is exactly reproducible for a seed.
private struct WalleSplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Reads the aspect ratio of every source, spreading the ImageIO work across cores.
///
/// Each `CGImageSource` is independent, so this is safe concurrently; results are written
/// by index, which keeps the input order (and therefore every caller's ordering) exact.
private func walleAspectRatios(for urls: [URL]) -> [Double?] {
    guard urls.count > 1 else {
        return urls.map { walleImageAspectRatio(at: $0) }
    }
    let ratios = WalleConcurrentResults<Double?>(repeating: nil, count: urls.count)
    DispatchQueue.concurrentPerform(iterations: urls.count) { index in
        ratios.set(walleImageAspectRatio(at: urls[index]), at: index)
    }
    return ratios.values
}

/// The widest aspect ratio in the library, with portrait images folded to their long side.
///
/// The thumbnail floor is set by the widest image: a 21:9 wallpaper needs a wider source
/// than a 4:3 one for the same card height. The fallback matches the picker's historical
/// default for an empty or unreadable library.
public func walleWidestAspect(_ wallpapers: [Wallpaper]) -> Double {
    wallpapers.compactMap(\.aspectRatio)
        .map { max($0, 1.0 / $0) }
        .max() ?? 1.8
}

/// Reads only the image properties (never decodes pixels) to obtain width / height.
/// Returns nil for non-images and corrupt files.
public func walleImageAspectRatio(at url: URL) -> Double? {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
        return nil
    }
    guard let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
          let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
          width > 0, height > 0 else {
        return nil
    }
    return width / height
}
