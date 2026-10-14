import Foundation
import Testing
@testable import WalleCore

/// Regression suite for an integration gap: LibrarySort.sort was correct and well
/// tested, but LibraryScanner.scan never called it, so every sort mode returned the
/// same arbitrary order. These tests go through the scanner, not the pure function.
@Suite("Scanner applies the configured sort")
struct ScannerSortTests {

    private func makeLibrary() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("walle-sort-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func write(_ name: String, in dir: URL, modified: TimeInterval) throws {
        let url = dir.appendingPathComponent(name)
        try Data("not really an image".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: modified)],
            ofItemAtPath: url.path)
    }

    @Test func nameSortIsAppliedByTheScanner() throws {
        let dir = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("b.png", in: dir, modified: 300)
        try write("a.png", in: dir, modified: 200)
        try write("c.png", in: dir, modified: 100)

        var config = Config()
        config.wallpaperDirs = [dir.path]
        config.sort = .name

        let result = LibraryScanner(config: config, home: dir).scan()
        #expect(result.wallpapers.map(\.name) == ["a.png", "b.png", "c.png"])
    }

    @Test func mtimeSortIsAppliedByTheScanner() throws {
        let dir = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        try write("b.png", in: dir, modified: 300)
        try write("a.png", in: dir, modified: 200)
        try write("c.png", in: dir, modified: 100)

        var config = Config()
        config.wallpaperDirs = [dir.path]
        config.sort = .mtime

        let result = LibraryScanner(config: config, home: dir).scan()
        #expect(result.wallpapers.map(\.name) == ["c.png", "a.png", "b.png"])
    }

    @Test func randomSortIsReproducibleForASeedAndKeepsEveryItem() throws {
        let dir = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = ["a.png", "b.png", "c.png", "d.png", "e.png"]
        for (index, name) in names.enumerated() {
            try write(name, in: dir, modified: TimeInterval(100 + index))
        }

        var config = Config()
        config.wallpaperDirs = [dir.path]
        config.sort = .random

        let scanner = LibraryScanner(config: config, home: dir)
        let first = scanner.scan(seed: 42).wallpapers.map(\.name)
        let second = scanner.scan(seed: 42).wallpapers.map(\.name)
        #expect(first == second)
        #expect(Set(first) == Set(names))
    }

    @Test func differentSeedsProduceDifferentOrders() throws {
        let dir = try makeLibrary()
        defer { try? FileManager.default.removeItem(at: dir) }
        let names = (0..<24).map { String(format: "img%02d.png", $0) }
        for (index, name) in names.enumerated() {
            try write(name, in: dir, modified: TimeInterval(100 + index))
        }

        var config = Config()
        config.wallpaperDirs = [dir.path]
        config.sort = .random

        let scanner = LibraryScanner(config: config, home: dir)
        let a = scanner.scan(seed: 1).wallpapers.map(\.name)
        let b = scanner.scan(seed: 2).wallpapers.map(\.name)
        #expect(a != b)
    }
}
