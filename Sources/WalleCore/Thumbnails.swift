import CoreGraphics
import CryptoKit
import Dispatch
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Why a thumbnail could not be produced. Thrown instead of trapping so the CLI can
/// report a bad file and keep going.
public enum ThumbnailError: Error, Equatable, Sendable {
    case sourceUnreadable(URL)
    case thumbnailCreationFailed(URL)
    case cachedThumbnailUnreadable(URL)
    case destinationCreationFailed(URL)
    case writeFailed(URL)
}

/// What a batch build did for one wallpaper.
public enum ThumbnailOutcome: Sendable, Equatable {
    case existing
    case generated
    case failed(ThumbnailError)
}

/// Content-addressed JPEG thumbnails stored in one flat directory.
///
/// There is exactly one thumbnail size. The cards are taller than they are wide and
/// landscape wallpapers are aspect-filled into them, so the same image serves the resting
/// row and the expanded preview; the separate row/preview size classes this type used to
/// track were collapsed once the picker stopped requesting a distinct preview size.
///
/// The cache filename is a SHA256 of the canonical source path, its modification time and
/// the pixel budget, so editing an image or changing a budget never serves a stale
/// thumbnail. Generation always goes through ImageIO thumbnails and never decodes the
/// full-resolution image.
public struct ThumbnailCache: Sendable {
    public var directory: URL
    public var maxPx: Int
    // FileManager is documented as thread-safe; we only use it synchronously.
    nonisolated(unsafe) private let fileManager: FileManager

    public init(directory: URL, maxPx: Int, fileManager: FileManager = .default) {
        self.directory = directory
        self.maxPx = maxPx
        self.fileManager = fileManager
    }

    /// The pixel budget, never below 1 so a bad config cannot ask ImageIO for a
    /// zero-pixel thumbnail.
    public var maxPixels: Int { max(1, maxPx) }

    /// Deterministic cache filename: SHA256 of path + mtime + pixel budget.
    public func cacheURL(for wallpaper: Wallpaper) -> URL {
        let identity = [
            wallpaper.path,
            String(wallpaper.modifiedAt.timeIntervalSince1970.bitPattern, radix: 16),
            String(maxPixels),
        ].joined(separator: "|")
        let digest = SHA256.hash(data: Data(identity.utf8))
        return directory.appendingPathComponent(walleHexName(of: digest))
            .appendingPathExtension("jpg")
    }

    /// Non-nil only when the cached file already exists and is readable.
    public func existingThumbnail(for wallpaper: Wallpaper) -> URL? {
        let url = cacheURL(for: wallpaper)
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
    public func thumbnail(for wallpaper: Wallpaper) throws -> URL {
        if let existing = existingThumbnail(for: wallpaper) {
            return existing
        }
        let image = try generateImage(for: wallpaper)
        return try write(image, for: wallpaper)
    }

    /// The decoded thumbnail, generating and writing the cache file when missing.
    ///
    /// Returning the freshly generated image avoids encoding a JPEG and immediately
    /// decoding that same file again just to put it on screen; on a cold cache that was
    /// one wasted decode per new card.
    public func thumbnailImage(for wallpaper: Wallpaper) throws -> CGImage {
        if let existing = existingThumbnail(for: wallpaper) {
            guard let source = CGImageSourceCreateWithURL(existing as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(
                    source, 0,
                    [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
                throw ThumbnailError.cachedThumbnailUnreadable(existing)
            }
            return image
        }
        let image = try generateImage(for: wallpaper)
        _ = try write(image, for: wallpaper)
        return image
    }

    private func generateImage(for wallpaper: Wallpaper) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(wallpaper.url as CFURL, nil) else {
            throw ThumbnailError.sourceUnreadable(wallpaper.url)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw ThumbnailError.thumbnailCreationFailed(wallpaper.url)
        }
        return image
    }

    @discardableResult
    private func write(_ image: CGImage, for wallpaper: Wallpaper) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let destinationURL = cacheURL(for: wallpaper)
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

    /// Generates every missing thumbnail, spreading the ImageIO work across cores.
    ///
    /// Each wallpaper writes its own cache file and uses its own ImageIO objects, so the
    /// loop is safe to run concurrently. Outcomes come back in input order, which keeps a
    /// caller's report deterministic even though the work finishes out of order.
    public func ensureThumbnails(for wallpapers: [Wallpaper]) -> [ThumbnailOutcome] {
        let outcomes = WalleConcurrentResults<ThumbnailOutcome>(repeating: .existing,
                                                                count: wallpapers.count)
        let cache = self
        DispatchQueue.concurrentPerform(iterations: wallpapers.count) { index in
            let wallpaper = wallpapers[index]
            if cache.existingThumbnail(for: wallpaper) != nil {
                outcomes.set(.existing, at: index)
                return
            }
            do {
                _ = try cache.thumbnail(for: wallpaper)
                outcomes.set(.generated, at: index)
            } catch let error as ThumbnailError {
                outcomes.set(.failed(error), at: index)
            } catch {
                outcomes.set(.failed(.thumbnailCreationFailed(wallpaper.url)), at: index)
            }
        }
        return outcomes.values
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
            liveNames.insert(cacheURL(for: wallpaper).lastPathComponent)
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

/// Lowercase, zero-padded hex for a SHA256 digest.
///
/// `String(format: "%02x", byte)` per byte is ~8x slower than indexing a 256-entry table
/// (72 ms vs ~9 ms per 2 000 names) and produces exactly the same text, so existing cache
/// filenames stay valid.
private let walleHexDigits: [UInt8] = Array("0123456789abcdef".utf8)

private func walleHexName(of digest: SHA256.Digest) -> String {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(64)  // SHA256 is 32 bytes; hex doubles it
    for byte in digest {
        bytes.append(walleHexDigits[Int(byte >> 4)])
        bytes.append(walleHexDigits[Int(byte & 0x0F)])
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// Recognises our own output (64 hex characters plus the jpg extension) so prune and
/// cacheSizeBytes never touch an unrelated file that happens to share the directory.
private func walleIsThumbnailFileName(_ name: String) -> Bool {
    guard name.hasSuffix(".jpg") else { return false }
    let base = String(name.dropLast(4))
    guard base.count == 64 else { return false }
    return base.allSatisfy { $0.isHexDigit }
}
