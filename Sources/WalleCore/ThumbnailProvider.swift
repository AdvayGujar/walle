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

    private let memoryCache = NSCache<NSString, CGImage>()
    private let counter = MemoryCacheCounter()

    private let lock = NSLock()
    private var inFlight: [String: InFlight] = [:]

    private let workQueue = DispatchQueue(
        label: "com.walle.thumbnail-provider",
        qos: .userInitiated,
        attributes: .concurrent)

    public init(cache: ThumbnailCache, maxPx: Int) {
        self.cache = cache

        // Bound the decoded-image cache by real bytes, sized to what the picker actually
        // holds at once: a full row of cards plus the images that can slide through it.
        //
        // There is a single thumbnail size now, so the old "3 previews + 12 row
        // thumbnails" arithmetic is gone; the budget is one decoded image (a 16:9
        // approximation of the square pixel budget) times a row plus headroom. Getting
        // this wrong was previously the single largest contributor to the picker's memory
        // use.
        let nineSixteenths = 9.0 / 16.0
        let typical = Double(max(1, maxPx) * max(1, maxPx)) * 4 * nineSixteenths
        memoryCache.totalCostLimit = Int(typical * 15)
        memoryCache.countLimit = 64
        memoryCache.delegate = counter
    }

    // MARK: - Public API

    /// Decoded image for the wallpaper. Generates the on-disk thumbnail if missing.
    /// Returns nil for unreadable or corrupt sources. Never throws.
    public func image(for wallpaper: Wallpaper) -> CGImage? {
        let key = memoryKey(for: wallpaper)
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

        let decoded = decode(for: wallpaper)
        return finish(entry: entry, key: key, image: decoded)
    }

    /// The decoded image if it is already in memory, without generating or decoding
    /// anything. Lets the picker paint a hit synchronously and defer only a miss.
    public func cachedImage(for wallpaper: Wallpaper) -> CGImage? {
        memoryCache.object(forKey: memoryKey(for: wallpaper) as NSString)
    }

    /// Decodes off the calling thread and delivers on the main queue.
    /// Repeated requests for the same key while one is already in flight are coalesced
    /// into the same work; every caller still receives the result.
    public func imageAsync(
        for wallpaper: Wallpaper,
        completion: @escaping @Sendable (CGImage?) -> Void
    ) {
        let key = memoryKey(for: wallpaper)
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
            let decoded = self.decode(for: wallpaper)
            _ = self.finish(entry: entry, key: key, image: decoded)
        }
    }

    /// Generates and caches the thumbnail for every wallpaper. Empty input is a no-op.
    public func preload(_ wallpapers: [Wallpaper]) {
        for wallpaper in wallpapers {
            _ = image(for: wallpaper)
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

    /// The on-disk thumbnail identity is already content-addressed and includes the pixel
    /// budget, so the path alone is a complete in-memory key.
    private func memoryKey(for wallpaper: Wallpaper) -> String {
        cache.cacheURL(for: wallpaper).path
    }

    /// Produces the on-disk thumbnail through the cache, then decodes that JPEG.
    /// A missing source, a corrupt file, or a generation failure all collapse to nil.
    private func decode(for wallpaper: Wallpaper) -> CGImage? {
        guard let url = try? cache.thumbnail(for: wallpaper) else {
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
