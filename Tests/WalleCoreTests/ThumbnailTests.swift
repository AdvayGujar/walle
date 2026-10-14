import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import WalleCore

@Suite("Thumbnail cache")
struct ThumbnailTests {

    private enum FixtureError: Error { case context, image, destination, finalize }

    /// Writes a real solid-colour image at exact pixel dimensions.
    private func writeImage(at url: URL, width: Int, height: Int, type: UTType = .png) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw FixtureError.context
        }
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw FixtureError.image }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil) else {
            throw FixtureError.destination
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.finalize }
    }

    private func scanWallpaper(in directory: URL, named name: String) throws -> Wallpaper {
        var config = Config()
        config.wallpaperDirs = [directory.path]
        let result = LibraryScanner(config: config, home: directory).scan()
        return try #require(result.wallpapers.first { $0.name == name })
    }

    private func cache(in directory: URL, row: Int = 64, preview: Int = 256) -> ThumbnailCache {
        ThumbnailCache(
            directory: directory.appendingPathComponent("thumbs", isDirectory: true),
            rowMaxPx: row,
            previewMaxPx: preview)
    }

    private func pixelSize(at url: URL) throws -> (width: Int, height: Int) {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let properties = try #require(
            CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        let width = try #require((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue)
        let height = try #require((properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue)
        return (width, height)
    }

    private func fileSize(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require((attributes[.size] as? NSNumber)?.intValue)
    }

    // MARK: - Naming

    @Test func cacheURLIsStableAndDependsOnClassAndMtime() throws {
        try withTempDirectory { dir in
            let imageURL = dir.appendingPathComponent("one.png")
            try writeImage(at: imageURL, width: 40, height: 30)
            let wallpaper = try scanWallpaper(in: dir, named: "one.png")
            let cache = cache(in: dir)

            let row = cache.cacheURL(for: wallpaper, sizeClass: .row)
            #expect(cache.cacheURL(for: wallpaper, sizeClass: .row) == row)
            #expect(cache.cacheURL(for: wallpaper, sizeClass: .preview) != row)

            var changed = wallpaper
            changed.modifiedAt = wallpaper.modifiedAt.addingTimeInterval(120)
            #expect(cache.cacheURL(for: changed, sizeClass: .row) != row)

            #expect(cache.maxPixels(for: .row) == 64)
            #expect(cache.maxPixels(for: .preview) == 256)
        }
    }

    @Test func existingThumbnailAppearsOnlyAfterGeneration() throws {
        try withTempDirectory { dir in
            let imageURL = dir.appendingPathComponent("one.png")
            try writeImage(at: imageURL, width: 40, height: 30)
            let wallpaper = try scanWallpaper(in: dir, named: "one.png")
            let cache = cache(in: dir)

            #expect(cache.existingThumbnail(for: wallpaper, sizeClass: .row) == nil)
            let url = try cache.thumbnail(for: wallpaper, sizeClass: .row)
            #expect(FileManager.default.fileExists(atPath: url.path))
            #expect(cache.existingThumbnail(for: wallpaper, sizeClass: .row) == url)
            // A second request is a cache hit, not a second write.
            let cachedAgain = try cache.thumbnail(for: wallpaper, sizeClass: .row)
            #expect(cachedAgain == url)
        }
    }

    // MARK: - Generation

    @Test func generatedRowThumbnailRespectsPixelBudgetAndAspect() throws {
        try withTempDirectory { dir in
            let imageURL = dir.appendingPathComponent("landscape.png")
            try writeImage(at: imageURL, width: 800, height: 600)
            let wallpaper = try scanWallpaper(in: dir, named: "landscape.png")
            let cache = cache(in: dir, row: 100, preview: 300)

            let thumbnailURL = try cache.thumbnail(for: wallpaper, sizeClass: .row)
            let size = try pixelSize(at: thumbnailURL)
            #expect(max(size.width, size.height) <= 100)
            #expect(max(size.width, size.height) >= 90)
            #expect(abs(Double(size.width) / Double(size.height) - 4.0 / 3.0) < 0.02)

            // It is a genuine JPEG, not merely a file with the right name.
            let source = try #require(CGImageSourceCreateWithURL(thumbnailURL as CFURL, nil))
            #expect((CGImageSourceGetType(source) as String?) == UTType.jpeg.identifier)
        }
    }

    @Test func generatedPreviewThumbnailPreservesPortraitAspect() throws {
        try withTempDirectory { dir in
            let imageURL = dir.appendingPathComponent("portrait.png")
            try writeImage(at: imageURL, width: 600, height: 800)
            let wallpaper = try scanWallpaper(in: dir, named: "portrait.png")
            let cache = cache(in: dir, row: 100, preview: 300)

            let thumbnailURL = try cache.thumbnail(for: wallpaper, sizeClass: .preview)
            let size = try pixelSize(at: thumbnailURL)
            #expect(max(size.width, size.height) <= 300)
            #expect(max(size.width, size.height) >= 290)
            #expect(abs(Double(size.width) / Double(size.height) - 0.75) < 0.02)
        }
    }

    @Test func rowAndPreviewWriteDistinctFiles() throws {
        try withTempDirectory { dir in
            let imageURL = dir.appendingPathComponent("one.png")
            try writeImage(at: imageURL, width: 320, height: 200)
            let wallpaper = try scanWallpaper(in: dir, named: "one.png")
            let cache = cache(in: dir, row: 64, preview: 256)

            let rowURL = try cache.thumbnail(for: wallpaper, sizeClass: .row)
            let previewURL = try cache.thumbnail(for: wallpaper, sizeClass: .preview)
            #expect(rowURL != previewURL)
            #expect(FileManager.default.fileExists(atPath: rowURL.path))
            #expect(FileManager.default.fileExists(atPath: previewURL.path))
            let deleted = try cache.prune(keeping: [wallpaper])
            #expect(deleted == 0)
        }
    }

    @Test func corruptImageThrowsInsteadOfCrashing() throws {
        try withTempDirectory { dir in
            let badURL = dir.appendingPathComponent("bad.png")
            try Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33]).write(to: badURL)
            let wallpaper = try scanWallpaper(in: dir, named: "bad.png")
            let cache = cache(in: dir, row: 32, preview: 64)

            #expect(throws: ThumbnailError.self) {
                _ = try cache.thumbnail(for: wallpaper, sizeClass: .row)
            }
            #expect(cache.existingThumbnail(for: wallpaper, sizeClass: .row) == nil)
        }
    }

    // MARK: - Pruning

    @Test func pruneRemovesDeletedAndInvalidatedEntriesAndKeepsLiveOnes() throws {
        try withTempDirectory { dir in
            let sourceDir = dir.appendingPathComponent("src", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
            let aURL = sourceDir.appendingPathComponent("a.png")
            let bURL = sourceDir.appendingPathComponent("b.png")
            let cURL = sourceDir.appendingPathComponent("c.png")
            for url in [aURL, bURL, cURL] {
                try writeImage(at: url, width: 48, height: 36)
            }

            var config = Config()
            config.wallpaperDirs = [sourceDir.path]
            let result = LibraryScanner(config: config, home: dir).scan()
            let a = try #require(result.wallpapers.first { $0.name == "a.png" })
            let b = try #require(result.wallpapers.first { $0.name == "b.png" })
            let c = try #require(result.wallpapers.first { $0.name == "c.png" })

            let cache = cache(in: dir, row: 32, preview: 64)
            for wallpaper in [a, b, c] {
                try cache.thumbnail(for: wallpaper, sizeClass: .row)
            }

            // b disappears entirely; c keeps its path but is modified.
            try FileManager.default.removeItem(at: bURL)
            try FileManager.default.setAttributes(
                [.modificationDate: c.modifiedAt.addingTimeInterval(3600)],
                ofItemAtPath: cURL.path)

            let deleted = try cache.prune(keeping: [a, b, c])
            #expect(deleted == 2)
            #expect(cache.existingThumbnail(for: a, sizeClass: .row) != nil)
            #expect(cache.existingThumbnail(for: b, sizeClass: .row) == nil)
            #expect(cache.existingThumbnail(for: c, sizeClass: .row) == nil)
        }
    }

    @Test func pruneOnMissingDirectoryIsQuiet() throws {
        try withTempDirectory { dir in
            let cache = cache(in: dir, row: 32, preview: 64)
            let deleted = try cache.prune(keeping: [])
            #expect(deleted == 0)
            #expect(cache.cacheSizeBytes() == 0)
        }
    }

    // MARK: - Size accounting

    @Test func cacheSizeBytesCountsWrittenThumbnails() throws {
        try withTempDirectory { dir in
            let imageURL = dir.appendingPathComponent("one.png")
            try writeImage(at: imageURL, width: 200, height: 150)
            let wallpaper = try scanWallpaper(in: dir, named: "one.png")
            let cache = cache(in: dir, row: 64, preview: 128)

            #expect(cache.cacheSizeBytes() == 0)
            let rowURL = try cache.thumbnail(for: wallpaper, sizeClass: .row)
            let rowSize = try fileSize(at: rowURL)
            #expect(cache.cacheSizeBytes() == rowSize)

            let previewURL = try cache.thumbnail(for: wallpaper, sizeClass: .preview)
            let previewSize = try fileSize(at: previewURL)
            #expect(cache.cacheSizeBytes() == rowSize + previewSize)
        }
    }
}
