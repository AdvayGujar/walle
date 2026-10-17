import Foundation

/// Collects results written from concurrent work, by index.
///
/// `DispatchQueue.concurrentPerform` takes a @Sendable closure, so it cannot capture a
/// mutable array or an unsafe buffer pointer without a concurrency warning (and a data
/// race if the indices ever overlap). This box owns the storage behind a lock; the
/// parallel scanner and thumbnail batch both write through it.
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
