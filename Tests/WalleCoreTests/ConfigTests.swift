import Foundation
import Testing
@testable import WalleCore

@Suite("Config parsing and validation")
struct ConfigTests {

    @Test func serializedRoundTripPreservesDefaults() {
        let defaults = Config()
        let (parsed, warnings) = Config.parse(defaults.serialized())
        #expect(warnings.isEmpty)
        #expect(parsed == defaults)
        #expect(parsed.serialized() == defaults.serialized())
    }

    @Test func keyOrderIsUniqueAndEveryKeyIsHandled() {
        let keys = Config.keyOrder
        #expect(Set(keys).count == keys.count)

        var config = Config()
        for key in keys {
            let value = config.value(forKey: key)
            #expect(value != nil, "value(forKey:) missing for \(key)")
            #expect(config.apply(key: key, value: value ?? "") == true, "apply missing for \(key)")
        }
    }

    @Test func commentsBlankLinesAndWhitespaceAreIgnored() {
        let text = "  # a comment\n\n    # indented comment\nrecursive = false\n   sort   =   mtime\n"
        let (config, warnings) = Config.parse(text)
        #expect(warnings.isEmpty)
        #expect(config.recursive == false)
        #expect(config.sort == .mtime)
    }

    @Test func malformedLineWarnsAndDoesNotAbortParsing() {
        let text = "this line has no equals sign\nrecursive = false\n"
        let (config, warnings) = Config.parse(text)
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("not a key = value pair") == true)
        #expect(config.recursive == false)
    }

    @Test func unknownKeyWarnsAndApplyReturnsFalse() {
        var config = Config()
        #expect(config.apply(key: "mystery_key", value: "1") == false)

        let (_, warnings) = Config.parse("mystery_key = 1\n")
        #expect(warnings.count == 1)
        #expect(warnings.first?.contains("unknown key") == true)
    }

    @Test func wallpaperDirsSplitsOnColonAndDropsEmptyComponents() {
        var config = Config()
        config.apply(key: "wallpaper_dirs", value: "/one:: /two :/three")
        #expect(config.wallpaperDirs == ["/one", "/two", "/three"])

        config.apply(key: "wallpaper_dirs", value: " : : ")
        #expect(config.wallpaperDirs.isEmpty)
    }

    @Test func sanitizedClampsEvenSlotsToOdd() {
        var config = Config()
        config.slots = 8
        let (sanitized, warnings) = config.sanitized()
        #expect(sanitized.slots == 7)
        #expect(warnings.contains { $0.contains("odd") })

        config.slots = 0
        let (tiny, tinyWarnings) = config.sanitized()
        #expect(tiny.slots == 1)
        #expect(tinyWarnings.contains { $0.contains("slots must be >= 1") })
    }

    @Test func sanitizedClampsOverlapAndPerspective() {
        var config = Config()
        config.overlap = 1.5
        config.perspective = 0
        var (sanitized, warnings) = config.sanitized()
        #expect(sanitized.overlap == 0.9)
        #expect(sanitized.perspective == 1)
        #expect(warnings.contains { $0.contains("overlap") })
        #expect(warnings.contains { $0.contains("perspective") })

        config = Config()
        config.overlap = -1
        config.perspective = -12
        (sanitized, warnings) = config.sanitized()
        #expect(sanitized.overlap == 0)
        #expect(sanitized.perspective == 1)
    }

    @Test func sanitizedKeepsTypicalValuesFinite() {
        let (sanitized, _) = Config().sanitized()
        let doubles = [
            sanitized.tileWidth, sanitized.tileHeight, sanitized.tileShear, sanitized.overlap,
            sanitized.depthStep, sanitized.perspective, sanitized.scaleFalloff, sanitized.dimFalloff,
            sanitized.dimFloor, sanitized.rowCenterYFrac, sanitized.previewMaxWFrac,
            sanitized.previewMaxHFrac, sanitized.previewGap, sanitized.dimAlpha, sanitized.animationMs,
        ]
        #expect(doubles.allSatisfy { $0.isFinite })
    }

    @Test func sanitizedReplacesNaN() {
        var config = Config()
        config.tileWidth = .nan
        config.overlap = .nan
        config.rowCenterYFrac = .nan
        let (sanitized, warnings) = config.sanitized()
        #expect(!sanitized.tileWidth.isNaN)
        #expect(!sanitized.overlap.isNaN)
        #expect(!sanitized.rowCenterYFrac.isNaN)
        #expect(sanitized.tileWidth >= 24)
        #expect(warnings.filter { $0.contains("clamped") }.count >= 3)
    }

    @Test func sanitizedWarnsAboutEmptyWallpaperDirs() {
        let (_, warnings) = Config(wallpaperDirs: []).sanitized()
        #expect(warnings.contains { $0.contains("wallpaper_dirs") && $0.contains("empty") })
    }

    @Test func enumParsingIsCaseInsensitiveAndRejectsGarbage() {
        #expect(SortMode.parse("NaMe") == .name)
        #expect(SortMode.parse(" MTIME ") == .mtime)
        #expect(SortMode.parse("random") == .random)
        #expect(SortMode.parse("bogus") == nil)

        #expect(ShearMode.parse("UNIFORM") == .uniform)
        #expect(ShearMode.parse("Mirror") == .mirror)
        #expect(ShearMode.parse("sideways") == nil)

        #expect(ApplyTarget.parse("ALL") == .all)
        #expect(ApplyTarget.parse(" active ") == .active)
        #expect(ApplyTarget.parse("") == nil)

        #expect(FillMode.parse("FILL") == .fill)
        #expect(FillMode.parse("Fit") == .fit)
        #expect(FillMode.parse("stretch") == .stretch)
        #expect(FillMode.parse("CENTER") == .center)
        #expect(FillMode.parse("bogus") == nil)
    }

    @Test func saveThenLoadRoundTripsInTemporaryDirectory() throws {
        try withTempDirectory { dir in
            var config = Config()
            config.slots = 5
            config.wallpaperDirs = ["/tmp/one", "/tmp/two"]
            config.sort = .random
            config.logLevel = "debug"

            let url = dir.appendingPathComponent("config")
            try config.save(to: url)

            let (loaded, warnings) = Config.load(from: url)
            #expect(warnings.isEmpty)
            #expect(loaded == config)
        }
    }

    @Test func loadFromMissingFileReturnsDefaultsQuietly() throws {
        try withTempDirectory { dir in
            let (config, warnings) = Config.load(from: dir.appendingPathComponent("missing"))
            #expect(config == Config())
            #expect(warnings.isEmpty)
        }
    }

    @Test func booleanSpellingsParse() {
        for raw in ["true", "TRUE", "yes", "Yes", "on", "ON", "1"] {
            var config = Config()
            config.recursive = false
            #expect(config.apply(key: "recursive", value: raw) == true)
            #expect(config.recursive == true, "\(raw) should parse as true")
        }
        for raw in ["false", "FALSE", "no", "No", "off", "OFF", "0"] {
            var config = Config()
            config.recursive = true
            #expect(config.apply(key: "recursive", value: raw) == true)
            #expect(config.recursive == false, "\(raw) should parse as false")
        }

        var config = Config()
        config.recursive = true
        config.apply(key: "recursive", value: "maybe")
        #expect(config.recursive == true)
    }
}
