import CoreGraphics
import Foundation
import ImageIO

/// Bridges the on-disk `ThumbnailCache` to decoded, in-memory `CGImage`s.
///
/// The picker asks for a thumbnail on the main thread while missing thumbnails are
/// generated in the background. Decoding the same image twice wastes disk and CPU, so
/// this type keeps a bounded `NSCache` of decoded images and coalesces concurrent
/// requests for the same thumbnail behind a lock-protected in-flight map. Every caller
/// that joins an in-flight request receives that request's result.
public final class ThumbnailProvider: @unchecked Sendable {

    /// One generation in progress. Waiters park on `condition` until the image is
    /// produced; asynchronous callers are notified through `completions`.
    private final class InFlight: @unchecked Sendable {
        let condition = NSCondition()
        var finished = false
        var image: CGImage?
        var completions: [@Sendable (CGImage?) -> Void] = []
    }

    /// NSCache clears itself and never reports removals, so a delegate keeps the
    /// observable count in step with reality.
    private final class MemoryCacheCounter: NSObject, NSCacheDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func recordInsert() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        func reset() {
            lock.lock()
            count = 0
            lock.unlock()
        }

        func current() -> Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
            lock.lock()
            count = max(0, count - 1)
            lock.unlock()
        }
    }

    private let cache: ThumbnailCache
    private let rowMaxPx: Int
    private let previewMaxPx: Int

    private let memoryCache = NSCache<NSString, CGImage>()
    private let counter = MemoryCacheCounter()

    private let lock = NSLock()
    private var inFlight: [String: InFlight] = [:]

    private let workQueue = DispatchQueue(
        label: "com.walle.thumbnail-provider",
        qos: .userInitiated,
        attributes: .concurrent)

    public init(cache: ThumbnailCache, rowMaxPx: Int, previewMaxPx: Int) {
        self.cache = cache
        self.rowMaxPx = rowMaxPx
        self.previewMaxPx = previewMaxPx

        // Bound the decoded-image cache by approximate bytes. One preview costs at most
        // previewMaxPx * previewMaxPx * 4 bytes, so cap the cache at a handful of them.
        let previewCost = max(1, previewMaxPx) * max(1, previewMaxPx) * 4
        memoryCache.totalCostLimit = max(1, previewCost * 8)
        memoryCache.countLimit = 512
        memoryCache.delegate = counter
    }

    // MARK: - Public API

    /// Decoded image for the wallpaper at this size class. Generates the on-disk
    /// thumbnail if missing. Returns nil for unreadable or corrupt sources. Never throws.
    public func image(for wallpaper: Wallpaper, sizeClass: ThumbSizeClass) -> CGImage? {
        let key = memoryKey(for: wallpaper, sizeClass: sizeClass)
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        lock.lock()
        if let entry = inFlight[key] {
            lock.unlock()
            // Wait on the entry itself; the provider lock must not be held while parked.
            entry.condition.lock()
            while !entry.finished {
                entry.condition.wait()
            }
            let image = entry.image
            entry.condition.unlock()
            return image
        }
        let entry = InFlight()
        inFlight[key] = entry
        lock.unlock()

        let decoded = decode(for: wallpaper, sizeClass: sizeClass)
        return finish(entry: entry, key: key, image: decoded)
    }

    /// Decodes off the calling thread and delivers on the main queue.
    /// Repeated requests for the same key while one is already in flight are coalesced
    /// into the same work; every caller still receives the result.
    public func imageAsync(
        for wallpaper: Wallpaper,
        sizeClass: ThumbSizeClass,
        completion: @escaping @Sendable (CGImage?) -> Void
    ) {
        let key = memoryKey(for: wallpaper, sizeClass: sizeClass)
        if let cached = memoryCache.object(forKey: key as NSString) {
            DispatchQueue.main.async { completion(cached) }
            return
        }

        lock.lock()
        if let entry = inFlight[key] {
            entry.completions.append(completion)
            lock.unlock()
            return
        }
        let entry = InFlight()
        entry.completions.append(completion)
        inFlight[key] = entry
        lock.unlock()

        workQueue.async { [weak self] in
            guard let self else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let decoded = self.decode(for: wallpaper, sizeClass: sizeClass)
            _ = self.finish(entry: entry, key: key, image: decoded)
        }
    }

    /// Generates and caches the requested size class for every wallpaper. Empty input is a no-op.
    public func preload(_ wallpapers: [Wallpaper], sizeClass: ThumbSizeClass) {
        for wallpaper in wallpapers {
            _ = image(for: wallpaper, sizeClass: sizeClass)
        }
    }

    public func clearMemoryCache() {
        memoryCache.removeAllObjects()
        counter.reset()
    }

    public func memoryCacheCount() -> Int {
        counter.current()
    }

    // MARK: - Internals

    /// Path plus size class: the on-disk thumbnail identity is already content-addressed,
    /// so the same key can never mix two size classes.
    private func memoryKey(for wallpaper: Wallpaper, sizeClass: ThumbSizeClass) -> String {
        cache.cacheURL(for: wallpaper, sizeClass: sizeClass).path + "|" + sizeClass.rawValue
    }

    /// Produces the on-disk thumbnail through the cache, then decodes that JPEG.
    /// A missing source, a corrupt file, or a generation failure all collapse to nil.
    private func decode(for wallpaper: Wallpaper, sizeClass: ThumbSizeClass) -> CGImage? {
        guard let url = try? cache.thumbnail(for: wallpaper, sizeClass: sizeClass) else {
            return nil
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        return CGImageSourceCreateImageAtIndex(source, 0, options as CFDictionary)
    }

    /// Publishes the result: caches it, wakes synchronous waiters and dispatches
    /// asynchronous completions on the main queue. Returns the image for the caller.
    @discardableResult
    private func finish(entry: InFlight, key: String, image: CGImage?) -> CGImage? {
        lock.lock()
        if let image {
            let cost = max(1, image.width * image.height * 4)
            memoryCache.setObject(image, forKey: key as NSString, cost: cost)
            counter.recordInsert()
        }
        inFlight.removeValue(forKey: key)
        let completions = entry.completions
        entry.completions = []
        lock.unlock()

        entry.condition.lock()
        entry.image = image
        entry.finished = true
        entry.condition.broadcast()
        entry.condition.unlock()

        for completion in completions {
            DispatchQueue.main.async { completion(image) }
        }
        return image
    }
}
