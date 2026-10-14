import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import WalleCore

@Suite("Thumbnail provider")
struct ThumbnailProviderTests {

    private enum FixtureError: Error { case context, image, destination, finalize }

    // MARK: - Fixtures

    /// Writes a real solid-colour image at exact pixel dimensions.
    private func writeImage(at url: URL, width: Int, height: Int, type: UTType = .png) throws {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw FixtureError.context
        }
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw FixtureError.image }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil) else {
            throw FixtureError.destination
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.finalize }
    }

    private func scanWallpapers(in directory: URL) -> [Wallpaper] {
        var config = Config()
        config.wallpaperDirs = [directory.path]
        return LibraryScanner(config: config, home: directory).scan().wallpapers
    }

    private func wallpaper(named name: String, in directory: URL) throws -> Wallpaper {
        let all = scanWallpapers(in: directory)
        return try #require(all.first { $0.name == name })
    }

    private func makeProvider(
        dir: URL,
        row: Int = 64,
        preview: Int = 256,
        fileManager: FileManager = .default
    ) -> (provider: ThumbnailProvider, cache: ThumbnailCache) {
        let cache = ThumbnailCache(
            directory: dir.appendingPathComponent("thumbs", isDirectory: true),
            rowMaxPx: row,
            previewMaxPx: preview,
            fileManager: fileManager)
        let provider = ThumbnailProvider(cache: cache, rowMaxPx: row, previewMaxPx: preview)
        return (provider, cache)
    }

    private func modificationDate(at url: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.modificationDate] as? Date)
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("walle-thumb-provider-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Records how many times the cache looked up or created an on-disk thumbnail.
    /// The optional arrival barrier keeps concurrent callers from collapsing into a
    /// serial sequence, so the coalescing test can detect duplicate generation.
    private final class RecordingFileManager: FileManager, @unchecked Sendable {
        private let condition = NSCondition()
        private var lookups = 0
        private var creates = 0
        private var released = false
        private let expectedLookups: Int

        init(expectedConcurrentLookups: Int = 1) {
            self.expectedLookups = max(1, expectedConcurrentLookups)
            super.init()
        }

        override func fileExists(atPath path: String, isDirectory: UnsafeMutablePointer<ObjCBool>?) -> Bool {
            if path.hasSuffix(".jpg") {
                condition.lock()
                lookups += 1
                if expectedLookups <= 1 || lookups >= expectedLookups {
                    released = true
                    condition.broadcast()
                } else if !released {
                    let deadline = Date().addingTimeInterval(1.5)
                    while !released && Date() < deadline {
                        condition.wait(until: deadline)
                    }
                }
                condition.unlock()
            }
            return super.fileExists(atPath: path, isDirectory: isDirectory)
        }

        override func createDirectory(
            at url: URL,
            withIntermediateDirectories createIntermediates: Bool,
            attributes: [FileAttributeKey: Any]? = nil
        ) throws {
            if url.path.contains("thumbs") {
                condition.lock()
                creates += 1
                condition.unlock()
            }
            try super.createDirectory(
                at: url, withIntermediateDirectories: createIntermediates, attributes: attributes)
        }

        func thumbnailLookups() -> Int {
            condition.lock()
            defer { condition.unlock() }
            return lookups
        }

        func generationCount() -> Int {
            condition.lock()
            defer { condition.unlock() }
            return creates
        }
    }

    private final class ImageCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var images: [CGImage?] = []

        func append(_ image: CGImage?) {
            lock.lock()
            images.append(image)
            lock.unlock()
        }

        func all() -> [CGImage?] {
            lock.lock()
            defer { lock.unlock() }
            return images
        }
    }

    private final class AsyncResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var image: CGImage?
        private var completed = false
        private var onMain = false

        func record(_ image: CGImage?, onMain: Bool) {
            lock.lock()
            self.image = image
            self.completed = true
            self.onMain = onMain
            lock.unlock()
        }

        func snapshot() -> (image: CGImage?, completed: Bool, onMain: Bool) {
            lock.lock()
            defer { lock.unlock() }
            return (image, completed, onMain)
        }
    }

    // MARK: - Synchronous decoding

    @Test func imageReturnsNonNilAndRespectsMaxPixelBudgets() throws {
        try withTempDirectory { dir in
            let imageURL = dir.appendingPathComponent("big.png")
            try writeImage(at: imageURL, width: 800, height: 600)
            let wallpaper = try wallpaper(named: "big.png", in: dir)
            let (provider, _) = makeProvider(dir: dir, row: 96, preview: 320)

            let row = try #require(provider.image(for: wallpaper, sizeClass: .row))
            #expect(row.width > 1 && row.height > 1)
            #expect(max(row.width, row.height) <= 96)

            let preview = try #require(provider.image(for: wallpaper, sizeClass: .preview))
            #expect(max(preview.width, preview.height) <= 320)
            // The preview budget is larger, so the decoded preview is strictly bigger.
            #expect(max(preview.width, preview.height) > max(row.width, row.height))
        }
    }

    @Test func imageReturnsNilForMissingFile() throws {
        withTempDirectory { dir in
            let (provider, _) = makeProvider(dir: dir, row: 64, preview: 128)
            let missing = dir.appendingPathComponent("does-not-exist.png")
            let wallpaper = Wallpaper(
                url: missing, path: missing.path, name: "does-not-exist.png",
                modifiedAt: Date(), fileSize: 0, aspectRatio: nil)
            #expect(provider.image(for: wallpaper, sizeClass: .row) == nil)
        }
    }

    @Test func imageReturnsNilForCorruptFile() throws {
        try withTempDirectory { dir in
            let badURL = dir.appendingPathComponent("bad.png")
            try Data([0xDE, 0xAD, 0xBE, 0xEF, 0x00, 0x11, 0x22, 0x33]).write(to: badURL)
            let wallpaper = try wallpaper(named: "bad.png", in: dir)
            let (provider, _) = makeProvider(dir: dir, row: 32, preview: 64)

            #expect(provider.image(for: wallpaper, sizeClass: .row) == nil)
            #expect(provider.memoryCacheCount() == 0)
        }
    }

    @Test func memoryCacheCountGrowsAndClears() throws {
        try withTempDirectory { dir in
            let imageURL = dir.appendingPathComponent("one.png")
            try writeImage(at: imageURL, width: 200, height: 150)
            let wallpaper = try wallpaper(named: "one.png", in: dir)
            let (provider, _) = makeProvider(dir: dir, row: 64, preview: 128)

            #expect(provider.memoryCacheCount() == 0)
            #expect(provider.image(for: wallpaper, sizeClass: .row) != nil)
            #expect(provider.memoryCacheCount() > 0)

            provider.clearMemoryCache()
            #expect(provider.memoryCacheCount() == 0)
        }
    }

    @Test func repeatedRequestsDoNotRegenerateTheThumbnail() throws {
        try withTempDirectory { dir in
            let imageURL = dir.appendingPathComponent("repeat.png")
            try writeImage(at: imageURL, width: 400, height: 300)
            let wallpaper = try wallpaper(named: "repeat.png", in: dir)
            let recording = RecordingFileManager()
            let (provider, cache) = makeProvider(dir: dir, row: 64, preview: 128, fileManager: recording)

            let thumbnailURL = cache.cacheURL(for: wallpaper, sizeClass: .row)

            #expect(provider.image(for: wallpaper, sizeClass: .row) != nil)
            #expect(recording.generationCount() == 1)
            let afterFirst = try modificationDate(at: thumbnailURL)

            // A memory hit must not touch the disk at all.
            #expect(provider.image(for: wallpaper, sizeClass: .row) != nil)
            #expect(recording.generationCount() == 1)

            // Even after dropping the memory cache, the existing JPEG is reused.
            provider.clearMemoryCache()
            #expect(provider.image(for: wallpaper, sizeClass: .row) != nil)
            #expect(recording.generationCount() == 1)
            #expect(try modificationDate(at: thumbnailURL) == afterFirst)
        }
    }

    // MARK: - Concurrency

    @Test func concurrentRequestsCoalesceIntoOneGeneration() throws {
        try withTempDirectory { dir in
            let imageURL = dir.appendingPathComponent("concurrent.png")
            try writeImage(at: imageURL, width: 640, height: 480)
            let wallpaper = try wallpaper(named: "concurrent.png", in: dir)
            // Eight lookups must all arrive before generation begins, otherwise a serial
            // run could hide duplicate generation behind the on-disk cache.
            let recording = RecordingFileManager(expectedConcurrentLookups: 8)
            let (provider, _) = makeProvider(dir: dir, row: 64, preview: 128, fileManager: recording)

            let iterations = 8
            let collector = ImageCollector()
            DispatchQueue.concurrentPerform(iterations: iterations) { _ in
                collector.append(provider.image(for: wallpaper, sizeClass: .row))
            }

            let images = collector.all()
            #expect(images.count == iterations)
            #expect(images.allSatisfy { $0 != nil })
            // Coalescing means the on-disk thumbnail was produced exactly once.
            #expect(recording.generationCount() == 1)
        }
    }

    // MARK: - Asynchronous decoding

    @Test @MainActor func imageAsyncDeliversImageOnMainQueue() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let imageURL = dir.appendingPathComponent("async.png")
            try writeImage(at: imageURL, width: 200, height: 150)
            let wallpaper = try wallpaper(named: "async.png", in: dir)
            let (provider, _) = makeProvider(dir: dir, row: 64, preview: 128)

            let box = AsyncResultBox()
            let semaphore = DispatchSemaphore(value: 0)
            provider.imageAsync(for: wallpaper, sizeClass: .row) { image in
                box.record(image, onMain: Thread.isMainThread)
                semaphore.signal()
            }

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    _ = semaphore.wait(timeout: .now() + 10)
                    continuation.resume()
                }
            }

            let result = box.snapshot()
            #expect(result.completed)
            #expect(result.onMain)
            #expect(result.image != nil)
        }
    }

    @Test @MainActor func imageAsyncDeliversNilOnMainQueueForCorruptFile() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            let badURL = dir.appendingPathComponent("corrupt.png")
            try Data([0x00, 0x01, 0x02, 0x03, 0x04]).write(to: badURL)
            let wallpaper = try wallpaper(named: "corrupt.png", in: dir)
            let (provider, _) = makeProvider(dir: dir, row: 32, preview: 64)

            let box = AsyncResultBox()
            let semaphore = DispatchSemaphore(value: 0)
            provider.imageAsync(for: wallpaper, sizeClass: .row) { image in
                box.record(image, onMain: Thread.isMainThread)
                semaphore.signal()
            }

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global().async {
                    _ = semaphore.wait(timeout: .now() + 10)
                    continuation.resume()
                }
            }

            let result = box.snapshot()
            #expect(result.completed)
            #expect(result.onMain)
            #expect(result.image == nil)
        }
    }

    // MARK: - Preload

    @Test func preloadWarmsTheMemoryCache() throws {
        try withTempDirectory { dir in
            var names: [String] = []
            for index in 0..<3 {
                let name = "preload\(index).png"
                try writeImage(at: dir.appendingPathComponent(name), width: 120, height: 90)
                names.append(name)
            }
            let wallpapers = names.compactMap { name in
                scanWallpapers(in: dir).first { $0.name == name }
            }
            #expect(wallpapers.count == 3)
            let (provider, cache) = makeProvider(dir: dir, row: 64, preview: 128)

            provider.preload(wallpapers, sizeClass: .row)
            #expect(provider.memoryCacheCount() == 3)
            for wallpaper in wallpapers {
                #expect(cache.existingThumbnail(for: wallpaper, sizeClass: .row) != nil)
            }
            // Only the requested class was generated.
            for wallpaper in wallpapers {
                #expect(cache.existingThumbnail(for: wallpaper, sizeClass: .preview) == nil)
            }
        }
    }

    @Test func preloadWithEmptyArrayDoesNothing() throws {
        withTempDirectory { dir in
            let (provider, _) = makeProvider(dir: dir, row: 64, preview: 128)
            provider.preload([], sizeClass: .preview)
            #expect(provider.memoryCacheCount() == 0)
        }
    }

    // MARK: - Bounded memory cache

    @Test func memoryCacheStaysBoundedUnderManyDistinctImages() throws {
        try withTempDirectory { dir in
            let total = 40
            var names: [String] = []
            for index in 0..<total {
                let name = "many\(index).png"
                try writeImage(at: dir.appendingPathComponent(name), width: 48, height: 48)
                names.append(name)
            }
            let byName = Dictionary(uniqueKeysWithValues: scanWallpapers(in: dir).map { ($0.name, $0) })
            let wallpapers = names.compactMap { byName[$0] }
            #expect(wallpapers.count == total)

            // Tiny budgets keep the cost limit small enough to exceed cheaply.
            let (provider, _) = makeProvider(dir: dir, row: 16, preview: 16)
            for wallpaper in wallpapers {
                #expect(provider.image(for: wallpaper, sizeClass: .row) != nil)
            }

            let count = provider.memoryCacheCount()
            #expect(count > 0)
            // The cost limit is far below the total cost of 40 decoded images, so the
            // cache must evict rather than grow without bound.
            #expect(count < total)
        }
    }
}
