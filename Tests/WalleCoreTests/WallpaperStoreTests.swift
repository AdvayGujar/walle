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

        let now = Date()
        let root: [String: Any] = [
            "Spaces": [
                "": ["Default": ["Desktop": desktop("shared.jpg", at: now)]],
                "SPACE-A": ["Default": ["Desktop": desktop("old-a.jpg", at: now)]],
                "SPACE-B": ["Default": ["Desktop": desktop("old-b.jpg", at: now)]],
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

        let result = try WallpaperStore.applyDefaultToAllSpaces(at: url)
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

        _ = try WallpaperStore.applyDefaultToAllSpaces(at: url)
        let second = try WallpaperStore.applyDefaultToAllSpaces(at: url)
        // Nothing to do the second time. Comparing serialised bytes would wrongly report
        // changes here, because equal dictionaries do not always serialise identically.
        #expect(second.updated.isEmpty)
        #expect(second.alreadyMatching.sorted() == ["SPACE-A", "SPACE-B"])
    }

    @Test("sync preserves unrelated keys")
    func syncPreservesOtherData() throws {
        let (url, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        _ = try WallpaperStore.applyDefaultToAllSpaces(at: url)
        let data = try Data(contentsOf: url)
        let root = try PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any]
        #expect(root?["Displays"] != nil)
        let spaces = root?["Spaces"] as? [String: Any]
        #expect(spaces?.count == 3)
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
