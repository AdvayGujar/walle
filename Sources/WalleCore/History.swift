import Foundation

/// One recorded wallpaper application.
public struct HistoryEntry: Codable, Sendable, Equatable {
    public var path: String
    public var appliedAt: Date
    public var screenUUID: String?
    public var mode: String

    public init(path: String, appliedAt: Date, screenUUID: String? = nil, mode: String) {
        self.path = path
        self.appliedAt = appliedAt
        self.screenUUID = screenUUID
        self.mode = mode
    }
}

/// Small mutable state the picker restores between launches.
public struct WalleState: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var lastAppliedPath: String?
    public var lastFocusedIndex: Int?

    public init(schemaVersion: Int = 1, lastAppliedPath: String? = nil, lastFocusedIndex: Int? = nil) {
        self.schemaVersion = schemaVersion
        self.lastAppliedPath = lastAppliedPath
        self.lastFocusedIndex = lastFocusedIndex
    }
}

/// Append-only, newline-delimited JSON history of applied wallpapers.
///
/// Each line is one `HistoryEntry` encoded with ISO 8601 dates, so the file stays
/// diffable and readable by plain tools. Readers tolerate a truncated or corrupt
/// line by skipping it; only real I/O failures on an existing file are thrown.
public struct HistoryStore: Sendable {
    private let fileURL: URL
    // FileManager is documented as thread-safe; we only use it synchronously.
    nonisolated(unsafe) private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    /// Appends one line, creating the parent directory lazily. The whole line is
    /// written with a single `write(2)`, so a concurrent reader sees either the
    /// complete line or nothing.
    public func append(_ entry: HistoryEntry) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        var line = try Self.makeEncoder().encode(entry)
        line.append(0x0A)
        if !fileManager.fileExists(atPath: fileURL.path) {
            _ = fileManager.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// All entries, newest first. A missing file is an empty history. Corrupt lines
    /// are skipped; an unreadable existing file throws.
    ///
    /// With a limit the file is read from the end only, so `history --limit 5` does not
    /// pay for a history that has been growing for months.
    public func entries(limit: Int? = nil) throws -> [HistoryEntry] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        guard let limit else { return try allEntriesNewestFirst() }
        guard limit > 0 else { return [] }
        return try newestEntries(limit: limit)
    }

    /// The whole file, decoded newest-first.
    private func allEntriesNewestFirst() throws -> [HistoryEntry] {
        let data = try Data(contentsOf: fileURL)
        let decoder = Self.makeDecoder()
        var newestFirst: [HistoryEntry] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            if let entry = try? decoder.decode(HistoryEntry.self, from: line) {
                newestFirst.append(entry)
            }
        }
        newestFirst.reverse()
        return newestFirst
    }

    /// The newest `limit` decodable entries, read from the end of the file.
    ///
    /// Every line is a self-contained entry and the file is append-only, so walking the
    /// tail backwards gives exactly what a full read then `prefix(limit)` gives, while
    /// a corrupt or truncated line is still skipped rather than ending the read. A
    /// chunk boundary can fall mid-line, so the first fragment of each chunk is carried
    /// into the next one.
    private func newestEntries(limit: Int) throws -> [HistoryEntry] {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > 0 else { return [] }

        let decoder = Self.makeDecoder()
        var entries: [HistoryEntry] = []
        var carry = Data()
        var position = size
        while position > 0, entries.count < limit {
            let readSize = min(Self.tailChunkSize, Int(position))
            position -= UInt64(readSize)
            try handle.seek(toOffset: position)
            guard var chunk = try handle.read(upToCount: readSize) else { break }
            chunk.append(carry)

            var fragments = chunk.split(separator: 0x0A, omittingEmptySubsequences: false)
            if position > 0, !fragments.isEmpty {
                // May begin mid-line; it continues in the chunk below this one.
                carry = Data(fragments.removeFirst())
            }
            for fragment in fragments.reversed() where !fragment.isEmpty {
                if let entry = try? decoder.decode(HistoryEntry.self, from: Data(fragment)) {
                    entries.append(entry)
                    if entries.count == limit { break }
                }
            }
        }
        return entries
    }

    /// 16 KiB is enough for dozens of entries, so a small limit is normally one read.
    private static let tailChunkSize = 16 * 1024

    /// Truncates the file to empty. A missing file is not an error.
    public func clear() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try Data().write(to: fileURL, options: .atomic)
    }

    /// Path of the newest entry, or nil for an empty history.
    public func lastAppliedPath() throws -> String? {
        try entries(limit: 1).first?.path
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Atomic store for the picker's small mutable state.
public struct StateStore: Sendable {
    private let fileURL: URL
    nonisolated(unsafe) private let fileManager: FileManager

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    /// A missing, empty or corrupt file reads as the default state; never throws.
    public func load() -> WalleState {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = fileManager.contents(atPath: fileURL.path),
              !data.isEmpty,
              let state = try? JSONDecoder().decode(WalleState.self, from: data) else {
            return WalleState()
        }
        return state
    }

    /// Writes atomically, creating the parent directory lazily.
    public func save(_ state: WalleState) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                        withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(state).write(to: fileURL, options: .atomic)
    }
}

/// How the next wallpaper should be chosen.
public enum SelectionMode: Sendable, Equatable {
    case explicit(String)
    case random
    case next
    case previous
    case last
}

/// Why a selection could not be resolved.
public enum SelectionError: Error, Equatable, CustomStringConvertible {
    case emptyLibrary
    case noHistory
    case pathNotFound(String)

    public var description: String {
        switch self {
        case .emptyLibrary:
            return "the wallpaper library is empty"
        case .noHistory:
            return "no history entry points at an existing wallpaper"
        case .pathNotFound(let path):
            return "wallpaper file does not exist: \(path)"
        }
    }
}

/// Pure selection logic over a scanned library and the recorded history.
///
/// `history` is expected newest-first, which is what `HistoryStore.entries()` returns.
public enum Selection {

    public static func resolve(_ mode: SelectionMode,
                               library: [Wallpaper],
                               history: [HistoryEntry],
                               currentPath: String?,
                               seed: UInt64) throws -> Wallpaper {
        switch mode {
        case .explicit(let path):
            return try resolveExplicit(path, library: library)

        case .random:
            guard let picked = LibrarySort.randomElement(library, seed: seed) else {
                throw SelectionError.emptyLibrary
            }
            return picked

        case .next:
            guard !library.isEmpty else { throw SelectionError.emptyLibrary }
            guard let currentPath, let index = index(of: currentPath, in: library) else {
                return library[0]
            }
            return library[(index + 1) % library.count]

        case .previous:
            guard !library.isEmpty else { throw SelectionError.emptyLibrary }
            guard let currentPath, let index = index(of: currentPath, in: library) else {
                return library[library.count - 1]
            }
            return library[(index - 1 + library.count) % library.count]

        case .last:
            guard let entry = newestExisting(history) else { throw SelectionError.noHistory }
            return wallpaper(for: entry.path, library: library)
        }
    }

    // MARK: - Helpers

    /// An explicit path wins if the library already holds that file (canonical
    /// comparison via standardizedFileURL.path); otherwise it is read from disk.
    private static func resolveExplicit(_ path: String, library: [Wallpaper]) throws -> Wallpaper {
        let target = walleStandardizedPath(path)
        if let match = library.first(where: { walleStandardizedPath($0.path) == target }) {
            return match
        }
        guard FileManager.default.fileExists(atPath: target) else {
            throw SelectionError.pathNotFound(path)
        }
        return makeWallpaper(at: target)
    }

    private static func index(of path: String, in library: [Wallpaper]) -> Int? {
        let target = walleStandardizedPath(path)
        return library.firstIndex { walleStandardizedPath($0.path) == target }
    }

    /// The most recent entry whose file still exists.
    ///
    /// Because `history` is newest-first, the first entry that exists is the answer. The
    /// previous version statted every entry to stay order-agnostic, so `--last` paid one
    /// syscall per history line even though the newest wallpaper almost always survives.
    private static func newestExisting(_ history: [HistoryEntry]) -> HistoryEntry? {
        history.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func wallpaper(for path: String, library: [Wallpaper]) -> Wallpaper {
        let target = walleStandardizedPath(path)
        if let match = library.first(where: { walleStandardizedPath($0.path) == target }) {
            return match
        }
        return makeWallpaper(at: target)
    }

    /// A chosen wallpaper is used for its path only: the picker scans the library itself
    /// and records the result, and --dry-run prints the path. Reading metadata here cost
    /// a stat plus an ImageIO open per explicit/--last selection for values nobody read.
    private static func makeWallpaper(at path: String) -> Wallpaper {
        let url = URL(fileURLWithPath: path)
        return Wallpaper(
            url: url,
            path: path,
            name: url.lastPathComponent,
            modifiedAt: Date(timeIntervalSince1970: 0),
            fileSize: 0,
            aspectRatio: nil)
    }
}

/// Normalizes a path without resolving symlinks, so `./x`, `a/../x` and `/abs/x`
/// compare equal.
private func walleStandardizedPath(_ path: String) -> String {
    URL(fileURLWithPath: path).standardizedFileURL.path
}
