import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import WalleCore

@Suite("Library scanning and sorting")
struct LibraryTests {

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
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let image = context.makeImage() else { throw FixtureError.image }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, type.identifier as CFString, 1, nil) else {
            throw FixtureError.destination
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw FixtureError.finalize }
    }

    private func writeText(at url: URL) throws {
        try Data("not an image".utf8).write(to: url)
    }

    private func scanner(dirs: [String], home: URL, recursive: Bool = true) -> LibraryScanner {
        var config = Config()
        config.wallpaperDirs = dirs
        config.recursive = recursive
        return LibraryScanner(config: config, home: home)
    }

    private func makeWallpaper(name: String, modifiedAt: Double) -> Wallpaper {
        let path = "/library/" + name
        return Wallpaper(
            url: URL(fileURLWithPath: path),
            path: path,
            name: name,
            modifiedAt: Date(timeIntervalSince1970: modifiedAt),
            fileSize: 10,
            aspectRatio: 1.5)
    }

    // MARK: - Scanning

    @Test func noDirectoriesYieldsEmptyResult() {
        let result = scanner(dirs: [], home: FileManager.default.temporaryDirectory).scan()
        #expect(result.wallpapers.isEmpty)
        #expect(result.warnings.isEmpty)
        #expect(result.rootCounts.isEmpty)
    }

    @Test func extensionAllowListAcceptsImagesAndRejectsOthers() throws {
        try withTempDirectory { dir in
            let accepted = ["jpg", "jpeg", "png", "heic", "heif", "avif", "webp", "tiff", "tif", "bmp", "gif"]
            for ext in accepted {
                try writeText(at: dir.appendingPathComponent("image." + ext))
            }
            for ext in ["txt", "pdf", "mp4"] {
                try writeText(at: dir.appendingPathComponent("other." + ext))
            }
            try writeText(at: dir.appendingPathComponent("extensionless"))
            let result = scanner(dirs: [dir.path], home: dir).scan()
            #expect(result.wallpapers.count == accepted.count)
            let expected = Set(accepted.map { "image." + $0 })
            #expect(Set(result.wallpapers.map(\.name)) == expected)
        }
    }

    @Test func uppercaseExtensionsAreAccepted() throws {
        try withTempDirectory { dir in
            try writeText(at: dir.appendingPathComponent("SHOT.JPG"))
            try writeText(at: dir.appendingPathComponent("ART.PnG"))
            let result = scanner(dirs: [dir.path], home: dir).scan()
            #expect(Set(result.wallpapers.map(\.name)) == ["SHOT.JPG", "ART.PnG"])
        }
    }

    @Test func hiddenAndFinderNoiseFilesAreExcluded() throws {
        try withTempDirectory { dir in
            try writeImage(at: dir.appendingPathComponent("visible.png"), width: 20, height: 10)
            try writeText(at: dir.appendingPathComponent(".hidden.png"))
            try writeText(at: dir.appendingPathComponent(".DS_Store"))
            try writeText(at: dir.appendingPathComponent(".localized"))
            let result = scanner(dirs: [dir.path], home: dir).scan()
            #expect(result.wallpapers.map(\.name) == ["visible.png"])
        }
    }

    @Test func recursiveFlagControlsSubdirectoryWalking() throws {
        try withTempDirectory { dir in
            let sub = dir.appendingPathComponent("sub", isDirectory: true)
            try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
            try writeImage(at: dir.appendingPathComponent("top.png"), width: 20, height: 10)
            try writeImage(at: sub.appendingPathComponent("deep.png"), width: 20, height: 10)

            let recursive = scanner(dirs: [dir.path], home: dir, recursive: true).scan()
            #expect(recursive.wallpapers.count == 2)

            let shallow = scanner(dirs: [dir.path], home: dir, recursive: false).scan()
            #expect(shallow.wallpapers.map(\.name) == ["top.png"])
        }
    }

    @Test func duplicatesAcrossRootsAndSymlinkAliasesCollapse() throws {
        try withTempDirectory { dir in
            let a = dir.appendingPathComponent("a", isDirectory: true)
            let b = dir.appendingPathComponent("b", isDirectory: true)
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
            let real = a.appendingPathComponent("real.png")
            try writeImage(at: real, width: 20, height: 10)

            // A symlink alias inside the same root must not double-count.
            try FileManager.default.createSymbolicLink(
                at: a.appendingPathComponent("alias.png"), withDestinationURL: real)
            #expect(scanner(dirs: [a.path], home: dir).scan().wallpapers.count == 1)

            // The same file reached from a second root must collapse too.
            try FileManager.default.createSymbolicLink(
                at: b.appendingPathComponent("link.png"), withDestinationURL: real)
            #expect(scanner(dirs: [a.path, b.path], home: dir).scan().wallpapers.count == 1)
        }
    }

    @Test func hardLinkedCopiesCollapseToASingleEntry() throws {
        try withTempDirectory { dir in
            let original = dir.appendingPathComponent("original.png")
            try writeImage(at: original, width: 20, height: 10)
            try FileManager.default.linkItem(at: original, to: dir.appendingPathComponent("linked.png"))
            // Distinct canonical paths, identical inode: only the inode key can collapse these.
            #expect(scanner(dirs: [dir.path], home: dir).scan().wallpapers.count == 1)
        }
    }

    @Test func symlinkCycleDoesNotHang() throws {
        try withTempDirectory { dir in
            let a = dir.appendingPathComponent("a", isDirectory: true)
            try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
            try writeImage(at: a.appendingPathComponent("one.png"), width: 20, height: 10)
            try FileManager.default.createSymbolicLink(
                at: a.appendingPathComponent("loop"), withDestinationURL: a)
            let result = scanner(dirs: [a.path], home: dir, recursive: true).scan()
            #expect(result.wallpapers.map(\.name) == ["one.png"])
        }
    }

    @Test func missingRootWarnsWhileValidRootStillScans() throws {
        try withTempDirectory { dir in
            let valid = dir.appendingPathComponent("valid", isDirectory: true)
            try FileManager.default.createDirectory(at: valid, withIntermediateDirectories: true)
            try writeImage(at: valid.appendingPathComponent("only.png"), width: 20, height: 10)
            let missing = dir.appendingPathComponent("does-not-exist").path

            let result = scanner(dirs: [missing, valid.path], home: dir).scan()
            #expect(result.wallpapers.map(\.name) == ["only.png"])
            #expect(result.warnings.isEmpty == false)
            #expect(result.warnings.contains { $0.contains(missing) })
            #expect(result.rootCounts[missing] == 0)
            #expect(result.rootCounts[valid.path] == 1)
        }
    }

    @Test func extraDirectoriesAreScannedAndCounted() throws {
        try withTempDirectory { dir in
            let base = dir.appendingPathComponent("base", isDirectory: true)
            let extra = dir.appendingPathComponent("extra", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: extra, withIntermediateDirectories: true)
            try writeImage(at: base.appendingPathComponent("base.png"), width: 20, height: 10)
            try writeImage(at: extra.appendingPathComponent("extra.png"), width: 20, height: 10)

            let result = scanner(dirs: [base.path], home: dir).scan(extraDirs: [extra.path])
            #expect(Set(result.wallpapers.map(\.name)) == ["base.png", "extra.png"])
            #expect(result.rootCounts[base.path] == 1)
            #expect(result.rootCounts[extra.path] == 1)
        }
    }

    @Test func tildeRootsExpandAgainstTheSuppliedHome() throws {
        try withTempDirectory { dir in
            let pictures = dir.appendingPathComponent("Pictures/Wallpapers", isDirectory: true)
            try FileManager.default.createDirectory(at: pictures, withIntermediateDirectories: true)
            try writeImage(at: pictures.appendingPathComponent("home.png"), width: 20, height: 10)
            let result = scanner(dirs: ["~/Pictures/Wallpapers"], home: dir).scan()
            #expect(result.wallpapers.map(\.name) == ["home.png"])
            #expect(result.rootCounts["~/Pictures/Wallpapers"] == 1)
        }
    }

    @Test func metadataAndAspectRatioArePopulatedForRealImages() throws {
        try withTempDirectory { dir in
            let imageURL = dir.appendingPathComponent("landscape.png")
            try writeImage(at: imageURL, width: 800, height: 600)
            let result = scanner(dirs: [dir.path], home: dir).scan()
            let wallpaper = try #require(result.wallpapers.first)
            #expect(wallpaper.name == "landscape.png")
            #expect(wallpaper.fileSize > 0)
            #expect(wallpaper.path.hasPrefix("/"))
            let aspect = try #require(wallpaper.aspectRatio)
            #expect(abs(aspect - 800.0 / 600.0) < 0.001)
            #expect(abs(wallpaper.modifiedAt.timeIntervalSinceNow) < 60)
        }
    }

    @Test func aspectRatiosAreSkippedWhenNotRequested() throws {
        try withTempDirectory { dir in
            try writeImage(at: dir.appendingPathComponent("landscape.png"), width: 80, height: 60)
            let result = scanner(dirs: [dir.path], home: dir)
                .scan(includeAspectRatio: false)
            #expect(result.wallpapers.count == 1)
            #expect(result.wallpapers.first?.aspectRatio == nil)
        }
    }

    @Test func everyAspectRatioIsCorrectWhenReadInParallel() throws {
        try withTempDirectory { dir in
            let sizes = [(800, 600), (300, 900), (1000, 250), (640, 480), (120, 360)]
            for (index, size) in sizes.enumerated() {
                try writeImage(at: dir.appendingPathComponent("img\(index).png"),
                               width: size.0, height: size.1)
            }
            let result = scanner(dirs: [dir.path], home: dir).scan()
            #expect(result.wallpapers.count == sizes.count)
            for wallpaper in result.wallpapers {
                let index = try #require(Int(wallpaper.name.dropFirst(3).dropLast(4)))
                let expected = Double(sizes[index].0) / Double(sizes[index].1)
                let aspect = try #require(wallpaper.aspectRatio)
                #expect(abs(aspect - expected) < 0.01)
            }
        }
    }

    @Test func widestAspectFoldsPortraitsAndFallsBackForAnEmptyLibrary() {
        #expect(walleWidestAspect([]) == 1.8)

        func item(_ aspect: Double?) -> Wallpaper {
            Wallpaper(url: URL(fileURLWithPath: "/library/p.png"),
                      path: "/library/p.png", name: "p.png",
                      modifiedAt: Date(timeIntervalSince1970: 0),
                      fileSize: 1, aspectRatio: aspect)
        }
        #expect(abs(walleWidestAspect([item(1.5), item(0.75), item(2.4)]) - 2.4) < 1e-9)
        // A portrait image counts by its long side, so 0.5 is as wide as 2.0.
        #expect(abs(walleWidestAspect([item(0.5)]) - 2.0) < 1e-9)
        #expect(walleWidestAspect([item(nil)]) == 1.8)
    }

    @Test func aspectRatioIsNilForCorruptFiles() throws {
        try withTempDirectory { dir in
            let bad = dir.appendingPathComponent("bad.png")
            try Data([0x00, 0x01, 0x02, 0x03]).write(to: bad)
            #expect(walleImageAspectRatio(at: bad) == nil)
            let result = scanner(dirs: [dir.path], home: dir).scan()
            #expect(result.wallpapers.count == 1)
            #expect(result.wallpapers.first?.aspectRatio == nil)
        }
    }

    // MARK: - Sorting

    @Test func nameSortIsDeterministicAndLocaleStable() {
        let items = ["zeta.png", "alpha.png", "Beta.png", "gamma.png"].map {
            makeWallpaper(name: $0, modifiedAt: 0)
        }
        let first = LibrarySort.sort(items, mode: .name, seed: 0).map(\.name)
        let second = LibrarySort.sort(items.reversed(), mode: .name, seed: 12345).map(\.name)
        #expect(first == second)
        #expect(first == ["alpha.png", "Beta.png", "gamma.png", "zeta.png"])
    }

    @Test func randomElementIsReproducibleAndNeedsNoWholeOrder() throws {
        let items = (0..<8).map { makeWallpaper(name: String($0) + ".png", modifiedAt: Double($0)) }
        #expect(LibrarySort.randomElement([], seed: 1) == nil)

        let first = try #require(LibrarySort.randomElement(items, seed: 42))
        #expect(first == LibrarySort.randomElement(items, seed: 42))
        #expect(items.contains(first))

        let picks = Set((0..<16).compactMap {
            LibrarySort.randomElement(items, seed: UInt64($0))?.path
        })
        #expect(picks.count > 1)
    }

    @Test func randomSortIsReproduciblePerSeedAndVariesAcrossSeeds() {
        let items = (0..<8).map { makeWallpaper(name: String($0) + ".png", modifiedAt: Double($0)) }
        let first = LibrarySort.sort(items, mode: .random, seed: 42).map(\.path)
        let sameSeed = LibrarySort.sort(items, mode: .random, seed: 42).map(\.path)
        let otherSeed = LibrarySort.sort(items, mode: .random, seed: 43).map(\.path)
        #expect(first == sameSeed)
        #expect(Set(first) == Set(items.map(\.path)))
        #expect(first != otherSeed)
    }

    @Test func mtimeSortOrdersByDate() {
        let items = [
            makeWallpaper(name: "old.png", modifiedAt: 100),
            makeWallpaper(name: "new.png", modifiedAt: 300),
            makeWallpaper(name: "mid.png", modifiedAt: 200),
        ]
        let sorted = LibrarySort.sort(items, mode: .mtime, seed: 0)
        #expect(sorted.map(\.modifiedAt).map(\.timeIntervalSince1970) == [100, 200, 300])
        #expect(sorted.map(\.name) == ["old.png", "mid.png", "new.png"])
    }

    @Test func sortHandlesEmptyAndSingleItemInputs() {
        #expect(LibrarySort.sort([], mode: .name, seed: 1).isEmpty)
        #expect(LibrarySort.sort([], mode: .random, seed: 1).isEmpty)
        let one = makeWallpaper(name: "one.png", modifiedAt: 1)
        #expect(LibrarySort.sort([one], mode: .random, seed: 7).map(\.path) == [one.path])
    }
}
