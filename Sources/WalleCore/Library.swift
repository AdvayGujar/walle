import CoreGraphics
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
    public func scan(extraDirs: [String] = [], seed: UInt64 = 0) -> ScanResult {
        var wallpapers: [Wallpaper] = []
        var warnings: [String] = []
        var rootCounts: [String: Int] = [:]
        var seenPaths = Set<String>()
        var seenFileIDs = Set<String>()

        // Records one candidate, or nil when it was already seen.
        func record(_ url: URL) -> Wallpaper? {
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            let path = canonical.path
            if seenPaths.contains(path) { return nil }

            let attributes = try? fileManager.attributesOfItem(atPath: path)
            let device = (attributes?[.systemNumber] as? NSNumber)?.uint64Value ?? 0
            let inode = (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            let fileID = String(device) + ":" + String(inode)
            if inode != 0, seenFileIDs.contains(fileID) { return nil }

            let modifiedAt = (attributes?[.modificationDate] as? Date) ?? Date(timeIntervalSince1970: 0)
            let fileSize = (attributes?[.size] as? NSNumber)?.intValue ?? 0
            let aspectRatio = walleImageAspectRatio(at: canonical)

            seenPaths.insert(path)
            if inode != 0 { seenFileIDs.insert(fileID) }

            return Wallpaper(
                url: canonical,
                path: path,
                name: canonical.lastPathComponent,
                modifiedAt: modifiedAt,
                fileSize: fileSize,
                aspectRatio: aspectRatio)
        }

        // Distinct identity for a directory, used to break symlink cycles.
        func directoryID(_ url: URL) -> String? {
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path) else {
                return nil
            }
            let device = (attributes[.systemNumber] as? NSNumber)?.uint64Value ?? 0
            let inode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
            if inode != 0 { return String(device) + ":" + String(inode) }
            return url.resolvingSymlinksInPath().standardizedFileURL.path
        }

        let rawRoots = (config.wallpaperDirs + extraDirs)
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

        for raw in rawRoots {
            let rootURL = walleExpand(raw, home: home)
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

                let keys: [URLResourceKey] = [.isHiddenKey, .isRegularFileKey]
                guard let entries = try? fileManager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: keys, options: []) else {
                    return
                }

                for entry in entries {
                    let name = entry.lastPathComponent
                    if name.hasPrefix(".") { continue }
                    if name == ".DS_Store" || name == ".localized" { continue }

                    var entryIsDirectory: ObjCBool = false
                    guard fileManager.fileExists(atPath: entry.path, isDirectory: &entryIsDirectory) else {
                        continue
                    }
                    if entryIsDirectory.boolValue {
                        if config.recursive { walk(entry) }
                        continue
                    }

                    guard walleIsImageExtension(name) else { continue }
                    if let values = try? entry.resourceValues(forKeys: [.isHiddenKey]), values.isHidden == true {
                        continue
                    }
                    if walleHasFinderInfoSkipFlag(entry) { continue }

                    if let wallpaper = record(entry) {
                        wallpapers.append(wallpaper)
                        contributed += 1
                    }
                }
            }

            walk(rootURL)
            rootCounts[raw] = contributed
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
            return items.sorted { lhs, rhs in
                let left = lhs.name.lowercased()
                let right = rhs.name.lowercased()
                if left != right { return left < right }
                if lhs.name != rhs.name { return lhs.name < rhs.name }
                return lhs.path < rhs.path
            }
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
