import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The two thumbnail budgets: small tiles in the corridor and the large centre preview.
public enum ThumbSizeClass: String, Sendable, CaseIterable {
    case row
    case preview
}

/// Why a thumbnail could not be produced. Thrown instead of trapping so the CLI can
/// report a bad file and keep going.
public enum ThumbnailError: Error, Equatable, Sendable {
    case sourceUnreadable(URL)
    case thumbnailCreationFailed(URL)
    case destinationCreationFailed(URL)
    case writeFailed(URL)
}

/// Content-addressed JPEG thumbnails stored in one flat directory.
///
/// The cache filename is a SHA256 of the canonical source path, its modification time,
/// the size class and the pixel budget, so editing an image or changing a budget never
/// serves a stale thumbnail. Generation always goes through ImageIO thumbnails and never
/// decodes the full-resolution image.
public struct ThumbnailCache: Sendable {
    public var directory: URL
    public var rowMaxPx: Int
    public var previewMaxPx: Int
    // FileManager is documented as thread-safe; we only use it synchronously.
    nonisolated(unsafe) private let fileManager: FileManager

    public init(
        directory: URL,
        rowMaxPx: Int,
        previewMaxPx: Int,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.rowMaxPx = rowMaxPx
        self.previewMaxPx = previewMaxPx
        self.fileManager = fileManager
    }

    public func maxPixels(for sizeClass: ThumbSizeClass) -> Int {
        switch sizeClass {
        case .row: return max(1, rowMaxPx)
        case .preview: return max(1, previewMaxPx)
        }
    }

    /// Deterministic cache filename: SHA256 of path + mtime + size class + pixel budget.
    public func cacheURL(for wallpaper: Wallpaper, sizeClass: ThumbSizeClass) -> URL {
        let identity = [
            wallpaper.path,
            String(wallpaper.modifiedAt.timeIntervalSince1970.bitPattern, radix: 16),
            sizeClass.rawValue,
            String(maxPixels(for: sizeClass)),
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name).appendingPathExtension("jpg")
    }

    /// Non-nil only when the cached file already exists and is readable.
    public func existingThumbnail(for wallpaper: Wallpaper, sizeClass: ThumbSizeClass) -> URL? {
        let url = cacheURL(for: wallpaper, sizeClass: sizeClass)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue,
              fileManager.isReadableFile(atPath: url.path) else {
            return nil
        }
        return url
    }

    /// Returns the cached file when present, otherwise generates and writes it.
    @discardableResult
    public func thumbnail(for wallpaper: Wallpaper, sizeClass: ThumbSizeClass) throws -> URL {
        if let existing = existingThumbnail(for: wallpaper, sizeClass: sizeClass) {
            return existing
        }

        guard let source = CGImageSourceCreateWithURL(wallpaper.url as CFURL, nil) else {
            throw ThumbnailError.sourceUnreadable(wallpaper.url)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels(for: sizeClass),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ThumbnailError.thumbnailCreationFailed(wallpaper.url)
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destinationURL = cacheURL(for: wallpaper, sizeClass: sizeClass)
        guard let destination = CGImageDestinationCreateWithURL(
            destinationURL as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ThumbnailError.destinationCreationFailed(destinationURL)
        }
        let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.8]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ThumbnailError.writeFailed(destinationURL)
        }
        return destinationURL
    }

    /// Deletes cached files whose source is gone or whose mtime no longer matches.
    /// Returns the number of files removed. A missing cache directory is not an error.
    @discardableResult
    public func prune(keeping wallpapers: [Wallpaper]) throws -> Int {
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [])
        } catch {
            return 0
        }

        var liveNames = Set<String>()
        for wallpaper in wallpapers {
            guard fileManager.fileExists(atPath: wallpaper.path) else { continue }
            let current = (try? fileManager.attributesOfItem(atPath: wallpaper.path))?[.modificationDate] as? Date
            if let current, abs(current.timeIntervalSince(wallpaper.modifiedAt)) > 1e-6 { continue }
            for sizeClass in ThumbSizeClass.allCases {
                liveNames.insert(cacheURL(for: wallpaper, sizeClass: sizeClass).lastPathComponent)
            }
        }

        var deleted = 0
        for file in contents {
            guard walleIsThumbnailFileName(file.lastPathComponent) else { continue }
            if liveNames.contains(file.lastPathComponent) { continue }
            try fileManager.removeItem(at: file)
            deleted += 1
        }
        return deleted
    }

    /// Total bytes of every recognisable thumbnail in the cache directory.
    public func cacheSizeBytes() -> Int {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.fileSizeKey], options: []) else {
            return 0
        }
        var total = 0
        for file in contents {
            guard walleIsThumbnailFileName(file.lastPathComponent) else { continue }
            if let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize {
                total += size
            } else if let attributes = try? fileManager.attributesOfItem(atPath: file.path),
                      let size = (attributes[.size] as? NSNumber)?.intValue {
                total += size
            }
        }
        return total
    }
}

/// Recognises our own output (64 hex characters plus the jpg extension) so prune and
/// cacheSizeBytes never touch an unrelated file that happens to share the directory.
private func walleIsThumbnailFileName(_ name: String) -> Bool {
    guard name.hasSuffix(".jpg") else { return false }
    let base = String(name.dropLast(4))
    guard base.count == 64 else { return false }
    return base.allSatisfy { $0.isHexDigit }
}
