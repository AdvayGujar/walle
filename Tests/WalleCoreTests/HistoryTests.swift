import Foundation
import Testing
@testable import WalleCore

// MARK: - Shared helpers

private func historyEntry(_ path: String,
                          seconds: TimeInterval,
                          mode: String = "picker",
                          screen: String? = nil) -> HistoryEntry {
    HistoryEntry(path: path,
                 appliedAt: Date(timeIntervalSince1970: seconds),
                 screenUUID: screen,
                 mode: mode)
}

private func encodedLine(_ entry: HistoryEntry) throws -> String {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return String(decoding: try encoder.encode(entry), as: UTF8.self)
}

private func makeFile(_ url: URL, contents: String = "x") throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
}

private func makeWallpaper(_ url: URL) -> Wallpaper {
    Wallpaper(url: url,
              path: url.path,
              name: url.lastPathComponent,
              modifiedAt: Date(timeIntervalSince1970: 0),
              fileSize: 1,
              aspectRatio: nil)
}

// MARK: - History

@Suite("History store")
struct HistoryStoreTests {

    @Test func appendThenEntriesReturnsTheOneEntry() throws {
        try withTempDirectory { dir in
            let store = HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl"))
            let entry = historyEntry("/wall/a.png", seconds: 1_700_000_000,
                                     mode: "picker", screen: "SCREEN-1")
            try store.append(entry)

            let got = try store.entries()
            #expect(got == [entry])
            #expect(got.first?.appliedAt == entry.appliedAt)
            #expect(got.first?.screenUUID == "SCREEN-1")
            #expect(got.first?.mode == "picker")
        }
    }

    @Test func appendingThreeReturnsThemNewestFirst() throws {
        try withTempDirectory { dir in
            let store = HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl"))
            try store.append(historyEntry("/wall/one.png", seconds: 10))
            try store.append(historyEntry("/wall/two.png", seconds: 20))
            try store.append(historyEntry("/wall/three.png", seconds: 30))

            let got = try store.entries()
            #expect(got.map(\.path) == ["/wall/three.png", "/wall/two.png", "/wall/one.png"])
        }
    }

    @Test func limitReturnsTheNewestTwo() throws {
        try withTempDirectory { dir in
            let store = HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl"))
            try store.append(historyEntry("/wall/one.png", seconds: 10))
            try store.append(historyEntry("/wall/two.png", seconds: 20))
            try store.append(historyEntry("/wall/three.png", seconds: 30))

            let got = try store.entries(limit: 2)
            #expect(got.map(\.path) == ["/wall/three.png", "/wall/two.png"])
        }
    }

    @Test func limitReadsTheTailAcrossChunkBoundaries() throws {
        try withTempDirectory { dir in
            let store = HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl"))
            // Long paths make 120 entries span many 16 KiB chunks, so most lines cross a
            // read boundary at least once.
            let prefix = "/wall/" + String(repeating: "x", count: 400) + "/"
            for index in 0..<120 {
                try store.append(historyEntry(prefix + "\(index).png",
                                              seconds: TimeInterval(index)))
            }

            let newest = try store.entries(limit: 3)
            #expect(newest.map(\.path) == [119, 118, 117].map { prefix + "\($0).png" })
            #expect(try store.lastAppliedPath() == prefix + "119.png")
        }
    }

    @Test func limitLargerThanTheHistoryReturnsAllNewestFirst() throws {
        try withTempDirectory { dir in
            let store = HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl"))
            try store.append(historyEntry("/wall/one.png", seconds: 10))
            try store.append(historyEntry("/wall/two.png", seconds: 20))
            #expect(try store.entries(limit: 10).map(\.path) == ["/wall/two.png",
                                                                 "/wall/one.png"])
            #expect(try store.entries(limit: 0).isEmpty)
        }
    }

    @Test func limitSkipsACorruptFinalLine() throws {
        try withTempDirectory { dir in
            let fileURL = dir.appendingPathComponent("history.jsonl")
            let store = HistoryStore(fileURL: fileURL)
            let good = historyEntry("/wall/one.png", seconds: 10)
            try Data((try encodedLine(good) + "\n" + "{\"path\": \"/wall/two").utf8)
                .write(to: fileURL)
            #expect(try store.entries(limit: 2).map(\.path) == ["/wall/one.png"])
            #expect(try store.lastAppliedPath() == "/wall/one.png")
        }
    }

    @Test func corruptMiddleLineIsSkippedAndGoodEntriesSurvive() throws {
        try withTempDirectory { dir in
            let fileURL = dir.appendingPathComponent("history.jsonl")
            let store = HistoryStore(fileURL: fileURL)
            let older = historyEntry("/wall/one.png", seconds: 10)
            let newer = historyEntry("/wall/two.png", seconds: 20)
            let olderLine = try encodedLine(older)
            let newerLine = try encodedLine(newer)
            let text = olderLine + "\n" + "{\"path\": \"broken\"\n" + newerLine + "\n"
            try Data(text.utf8).write(to: fileURL)

            let got = try store.entries()
            #expect(got.map(\.path) == ["/wall/two.png", "/wall/one.png"])
        }
    }

    @Test func truncatedFinalLineIsSkippedAndGoodEntriesSurvive() throws {
        try withTempDirectory { dir in
            let fileURL = dir.appendingPathComponent("history.jsonl")
            let store = HistoryStore(fileURL: fileURL)
            let older = historyEntry("/wall/one.png", seconds: 10)
            let text = try encodedLine(older) + "\n" + "{\"path\": \"/wall/two"
            try Data(text.utf8).write(to: fileURL)

            let got = try store.entries()
            #expect(got.map(\.path) == ["/wall/one.png"])
            #expect(try store.lastAppliedPath() == "/wall/one.png")
        }
    }

    @Test func clearEmptiesTheStoreAndMissingFileClearsQuietly() throws {
        try withTempDirectory { dir in
            let fileURL = dir.appendingPathComponent("history.jsonl")
            let store = HistoryStore(fileURL: fileURL)
            try store.append(historyEntry("/wall/one.png", seconds: 10))
            try store.clear()

            let afterClear = try store.entries()
            #expect(afterClear.isEmpty)

            let missing = HistoryStore(fileURL: dir.appendingPathComponent("missing.jsonl"))
            try missing.clear() // must not throw
            let missingEntries = try missing.entries()
            #expect(missingEntries.isEmpty)
        }
    }

    @Test func lastAppliedPathReturnsNewestAndNilWhenEmpty() throws {
        try withTempDirectory { dir in
            let store = HistoryStore(fileURL: dir.appendingPathComponent("history.jsonl"))
            let empty = try store.lastAppliedPath()
            #expect(empty == nil)

            try store.append(historyEntry("/wall/one.png", seconds: 10))
            try store.append(historyEntry("/wall/two.png", seconds: 20))
            #expect(try store.lastAppliedPath() == "/wall/two.png")
        }
    }
}

// MARK: - State

@Suite("State store")
struct StateStoreTests {

    @Test func loadMissingFileReturnsDefault() {
        withTempDirectory { dir in
            let store = StateStore(fileURL: dir.appendingPathComponent("state.json"))
            #expect(store.load() == WalleState())
        }
    }

    @Test func loadCorruptOrEmptyFileReturnsDefault() throws {
        try withTempDirectory { dir in
            let fileURL = dir.appendingPathComponent("state.json")
            let store = StateStore(fileURL: fileURL)

            try Data("not json at all".utf8).write(to: fileURL)
            #expect(store.load() == WalleState())

            try Data().write(to: fileURL)
            #expect(store.load() == WalleState())
        }
    }

    @Test func saveThenLoadRoundTripsIncludingNils() throws {
        try withTempDirectory { dir in
            let store = StateStore(fileURL: dir.appendingPathComponent("state.json"))

            let allNil = WalleState(schemaVersion: 1, lastAppliedPath: nil, lastFocusedIndex: nil)
            try store.save(allNil)
            #expect(store.load() == allNil)

            let filled = WalleState(schemaVersion: 2,
                                    lastAppliedPath: "/wall/one.png",
                                    lastFocusedIndex: 7)
            try store.save(filled)
            #expect(store.load() == filled)
        }
    }
}

// MARK: - Selection

@Suite("Selection")
struct SelectionTests {

    @Test func explicitResolvesAnItemPresentInTheLibrary() throws {
        try withTempDirectory { dir in
            let a = dir.appendingPathComponent("a.png")
            let b = dir.appendingPathComponent("b.png")
            try makeFile(a)
            try makeFile(b)
            let library = [makeWallpaper(a), makeWallpaper(b)]

            let got = try Selection.resolve(.explicit(a.path), library: library,
                                            history: [], currentPath: nil, seed: 0)
            #expect(got == library[0])
        }
    }

    @Test func explicitAcceptsAFileNotInTheLibrary() throws {
        try withTempDirectory { dir in
            let c = dir.appendingPathComponent("c.png")
            try makeFile(c)

            let got = try Selection.resolve(.explicit(c.path), library: [],
                                            history: [], currentPath: nil, seed: 0)
            #expect(got.path == c.path)
            #expect(got.name == "c.png")
            #expect(got.url.path == c.path)
        }
    }

    @Test func explicitThrowsPathNotFoundForAMissingFile() {
        withTempDirectory { dir in
            let missing = dir.appendingPathComponent("missing.png")
            #expect(throws: SelectionError.pathNotFound(missing.path)) {
                _ = try Selection.resolve(.explicit(missing.path), library: [],
                                          history: [], currentPath: nil, seed: 0)
            }
        }
    }

    @Test func explicitMatchesAnEquivalentButDifferentlyWrittenPath() throws {
        try withTempDirectory { dir in
            let a = dir.appendingPathComponent("sub/a.png")
            try makeFile(a)
            let library = [makeWallpaper(a)]

            let dot = dir.path + "/sub/./a.png"
            let dotDot = dir.path + "/sub/../sub/a.png"

            let fromDot = try Selection.resolve(.explicit(dot), library: library,
                                                history: [], currentPath: nil, seed: 0)
            let fromDotDot = try Selection.resolve(.explicit(dotDot), library: library,
                                                   history: [], currentPath: nil, seed: 0)
            #expect(fromDot == library[0])
            #expect(fromDotDot == library[0])
        }
    }

    @Test func randomIsReproducibleForASeedAndAlwaysALibraryMember() throws {
        try withTempDirectory { dir in
            var library: [Wallpaper] = []
            for name in ["a", "b", "c", "d"] {
                let url = dir.appendingPathComponent("\(name).png")
                try makeFile(url)
                library.append(makeWallpaper(url))
            }

            let first = try Selection.resolve(.random, library: library,
                                              history: [], currentPath: nil, seed: 0xDEAD_BEEF)
            let second = try Selection.resolve(.random, library: library,
                                               history: [], currentPath: nil, seed: 0xDEAD_BEEF)
            #expect(first == second)
            #expect(library.contains(first))
        }
    }

    @Test func nextAndPreviousWrapAround() throws {
        try withTempDirectory { dir in
            let urls = ["a", "b", "c"].map { dir.appendingPathComponent("\($0).png") }
            for url in urls { try makeFile(url) }
            let library = urls.map(makeWallpaper)

            let nextFromLast = try Selection.resolve(.next, library: library, history: [],
                                                     currentPath: urls[2].path, seed: 0)
            #expect(nextFromLast == library[0])

            let nextFromFirst = try Selection.resolve(.next, library: library, history: [],
                                                      currentPath: urls[0].path, seed: 0)
            #expect(nextFromFirst == library[1])

            let previousFromFirst = try Selection.resolve(.previous, library: library, history: [],
                                                          currentPath: urls[0].path, seed: 0)
            #expect(previousFromFirst == library[2])

            let previousFromLast = try Selection.resolve(.previous, library: library, history: [],
                                                         currentPath: urls[2].path, seed: 0)
            #expect(previousFromLast == library[1])
        }
    }

    @Test func nextAndPreviousFallBackOnNilOrUnknownCurrentPath() throws {
        try withTempDirectory { dir in
            let urls = ["a", "b", "c"].map { dir.appendingPathComponent("\($0).png") }
            for url in urls { try makeFile(url) }
            let library = urls.map(makeWallpaper)
            let unknown = dir.appendingPathComponent("nope.png").path

            let nextNil = try Selection.resolve(.next, library: library, history: [],
                                                currentPath: nil, seed: 0)
            #expect(nextNil == library[0])

            let previousNil = try Selection.resolve(.previous, library: library, history: [],
                                                    currentPath: nil, seed: 0)
            #expect(previousNil == library[2])

            let nextUnknown = try Selection.resolve(.next, library: library, history: [],
                                                    currentPath: unknown, seed: 0)
            #expect(nextUnknown == library[0])

            let previousUnknown = try Selection.resolve(.previous, library: library, history: [],
                                                        currentPath: unknown, seed: 0)
            #expect(previousUnknown == library[2])
        }
    }

    @Test func lastReturnsNewestExistingAndSkipsDeleted() throws {
        try withTempDirectory { dir in
            let a = dir.appendingPathComponent("a.png")
            let b = dir.appendingPathComponent("b.png")
            try makeFile(a)
            try makeFile(b)

            let history = [
                historyEntry(b.path, seconds: 200, mode: "cli"),
                historyEntry(a.path, seconds: 100, mode: "picker"),
            ]

            let newest = try Selection.resolve(.last, library: [], history: history,
                                               currentPath: nil, seed: 0)
            #expect(newest.path == b.path)

            try FileManager.default.removeItem(at: b)
            let surviving = try Selection.resolve(.last, library: [], history: history,
                                                  currentPath: nil, seed: 0)
            #expect(surviving.path == a.path)
        }
    }

    @Test func lastThrowsNoHistoryWhenEmptyOrAllMissing() {
        withTempDirectory { dir in
            #expect(throws: SelectionError.noHistory) {
                _ = try Selection.resolve(.last, library: [], history: [],
                                          currentPath: nil, seed: 0)
            }

            let gone = dir.appendingPathComponent("gone.png")
            let history = [historyEntry(gone.path, seconds: 100, mode: "cli")]
            #expect(throws: SelectionError.noHistory) {
                _ = try Selection.resolve(.last, library: [], history: history,
                                          currentPath: nil, seed: 0)
            }
        }
    }

    @Test func randomNextAndPreviousThrowEmptyLibrary() throws {
        #expect(throws: SelectionError.emptyLibrary) {
            _ = try Selection.resolve(.random, library: [], history: [],
                                      currentPath: nil, seed: 1)
        }
        #expect(throws: SelectionError.emptyLibrary) {
            _ = try Selection.resolve(.next, library: [], history: [],
                                      currentPath: nil, seed: 1)
        }
        #expect(throws: SelectionError.emptyLibrary) {
            _ = try Selection.resolve(.previous, library: [], history: [],
                                      currentPath: nil, seed: 1)
        }
    }
}
