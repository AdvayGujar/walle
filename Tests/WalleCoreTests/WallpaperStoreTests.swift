import Foundation
import Testing
@testable import WalleCore

@Suite("Wallpaper store")
struct WallpaperStoreTests {

    /// A store shaped like the real one: a default Space that everything should fall back to,
    /// plus two Spaces carrying their own picture.
    func makeStore() -> (url: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("walle-store-" + UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("Index.plist")

        func desktop(_ name: String, at date: Date) -> [String: Any] {
            let inner: [String: Any] = ["type": "imageFile",
                                        "url": ["relative": "file:///tmp/" + name]]
            let config = try! PropertyListSerialization.data(
                fromPropertyList: inner, format: .binary, options: 0)
            // The real store also carries NSNull placeholders, but binary property list
            // serialisation rejects them, and they play no part in what is being tested.
            return ["Content": ["Choices": [["Configuration": config,
                                             "Files": [Any](),
                                             "Provider": "com.apple.wallpaper.choice.image"]]],
                    "LastSet": date]
        }

        // Distinct timestamps, because the sync falls back to the most recently set entry when
        // it is not told which wallpaper was just applied.
        let now = Date()
        let root: [String: Any] = [
            "Spaces": [
                "": ["Default": ["Desktop": desktop("shared.jpg", at: now)]],
                "SPACE-A": ["Default": ["Desktop": desktop("old-a.jpg", at: now.addingTimeInterval(-60))]],
                "SPACE-B": ["Default": ["Desktop": desktop("old-b.jpg", at: now.addingTimeInterval(-120))]],
            ],
            "Displays": ["DISPLAY-1": ["Type": "individual"]],
        ]
        let data = try! PropertyListSerialization.data(fromPropertyList: root,
                                                       format: .binary, options: 0)
        try! data.write(to: url)
        return (url, dir)
    }

    @Test("lists every Space, default first")
    func listsSpaces() throws {
        let (url, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let spaces = try WallpaperStore.spaces(at: url)
        #expect(spaces.count == 3)
        #expect(spaces[0].isDefault)
        #expect(spaces[0].key.isEmpty)
        // The default trivially matches itself; the other two do not.
        #expect(spaces[0].matchesDefault)
        #expect(spaces.filter { !$0.isDefault }.allSatisfy { !$0.matchesDefault })
    }

    @Test("reads the image the default Space points at")
    func readsDefaultImage() throws {
        let (url, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try WallpaperStore.defaultImagePath(at: url) == "/tmp/shared.jpg")
    }

    @Test("sync copies the default onto every Space")
    func syncs() throws {
        let (url, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = try WallpaperStore.applyDefaultToAllSpaces(
            at: url, liveSpaces: ["SPACE-A", "SPACE-B"], sourcePath: "/tmp/shared.jpg")
        #expect(result.updated.sorted() == ["SPACE-A", "SPACE-B"])
        #expect(result.backupPath != nil)

        let after = try WallpaperStore.spaces(at: url)
        #expect(after.allSatisfy { $0.matchesDefault })
        #expect(try WallpaperStore.defaultImagePath(at: url) == "/tmp/shared.jpg")
    }

    @Test("sync is idempotent")
    func syncIsIdempotent() throws {
        let (url, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try WallpaperStore.applyDefaultToAllSpaces(
            at: url, liveSpaces: ["SPACE-A", "SPACE-B"], sourcePath: "/tmp/shared.jpg")
        let second = try WallpaperStore.applyDefaultToAllSpaces(
            at: url, liveSpaces: ["SPACE-A", "SPACE-B"], sourcePath: "/tmp/shared.jpg")
        // Nothing to do the second time. Comparing serialised bytes would wrongly report
        // changes here, because equal dictionaries do not always serialise identically.
        #expect(second.updated.isEmpty)
        #expect(second.alreadyMatching.sorted() == ["SPACE-A", "SPACE-B"])
    }

    @Test("sync preserves unrelated keys")
    func syncPreservesOtherData() throws {
        let (url, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try WallpaperStore.applyDefaultToAllSpaces(at: url, liveSpaces: ["SPACE-A", "SPACE-B"])
        let data = try Data(contentsOf: url)
        let root = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any]
        #expect(root?["Displays"] != nil)
        let spaces = root?["Spaces"] as? [String: Any]
        #expect(spaces?.count == 3)
    }

    @Test("a live Space with no entry is created")
    func createsMissingSpaces() throws {
        let (url, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // SPACE-C exists as a Space but the store has never heard of it, which is exactly the
        // case that made a wallpaper only reach some Spaces.
        let result = try WallpaperStore.applyDefaultToAllSpaces(
            at: url, liveSpaces: ["SPACE-A", "SPACE-B", "SPACE-C"])
        #expect(result.created == ["SPACE-C"])

        let after = try WallpaperStore.spaces(at: url)
        #expect(after.count == 4)                       // default + three Spaces
        #expect(after.allSatisfy { $0.matchesDefault })
    }

    @Test("entries for removed Spaces are reported, and pruned only on request")
    func reportsStaleSpaces() throws {
        let (url, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Only SPACE-A still exists; SPACE-B was deleted, but the store keeps it forever.
        let result = try WallpaperStore.applyDefaultToAllSpaces(at: url, liveSpaces: ["SPACE-A"])
        #expect(result.stale == ["SPACE-B"])
        #expect(result.pruned.isEmpty)
        #expect(try WallpaperStore.spaces(at: url).count == 3)

        let pruned = try WallpaperStore.applyDefaultToAllSpaces(
            at: url, liveSpaces: ["SPACE-A"], pruneStale: true)
        #expect(pruned.pruned == ["SPACE-B"])
        #expect(try WallpaperStore.spaces(at: url).count == 2)
    }

    @Test("the applied wallpaper is the source, not a stale default")
    func appliedPathIsTheSource() throws {
        let (url, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // This is the bug that made the picker look broken: the default still held an old
        // picture, so copying the default silently undid the wallpaper that was just applied.
        let result = try WallpaperStore.applyDefaultToAllSpaces(
            at: url, liveSpaces: ["SPACE-A", "SPACE-B"], sourcePath: "/tmp/old-a.jpg")
        // SPACE-A already holds the chosen picture, so only SPACE-B has to be rewritten.
        #expect(result.updated == ["SPACE-B"])

        // A second run finds nothing to do, which proves both Spaces converged on the picture
        // that was applied rather than on the stale default.
        let again = try WallpaperStore.applyDefaultToAllSpaces(
            at: url, liveSpaces: ["SPACE-A", "SPACE-B"], sourcePath: "/tmp/old-a.jpg")
        #expect(again.updated.isEmpty)
        #expect(again.alreadyMatching.sorted() == ["SPACE-A", "SPACE-B"])
    }

    @Test("a missing store is reported, not guessed at")
    func missingStore() {
        let url = URL(fileURLWithPath: "/tmp/walle-no-such-store-\(UUID().uuidString).plist")
        #expect(throws: WallpaperStore.StoreError.self) {
            try WallpaperStore.spaces(at: url)
        }
    }

    @Test("an override keeps the live store path")
    func overridePath() {
        let overridden = WallpaperStore.indexURL(environment: ["WALLE_WALLPAPER_STORE": "/tmp/x.plist"])
        #expect(overridden.path == "/tmp/x.plist")
        let real = WallpaperStore.indexURL(environment: [:])
        #expect(real.path.hasSuffix("com.apple.wallpaper/Store/Index.plist"))
    }
}
