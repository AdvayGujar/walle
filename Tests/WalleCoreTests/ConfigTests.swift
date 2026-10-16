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

    @Test func keyOrderIsUniqueAndEveryKeyRoundTrips() {
        let keys = Config.keyOrder
        #expect(Set(keys).count == keys.count)

        // Every registered key must render a value and read its own text back unchanged.
        // This is what keeps the single key table honest: a key whose getter and setter were
        // written against different properties would otherwise only be caught by inspection.
        let config = Config()
        for key in keys {
            let original = config.value(forKey: key)
            #expect(original != nil, "value(forKey:) missing for \(key)")
            var roundTripped = config
            #expect(roundTripped.apply(key: key, value: original ?? "") == true,
                    "apply missing for \(key)")
            #expect(roundTripped.value(forKey: key) == original,
                    "round-trip changed \(key): \(original ?? "nil") -> \(roundTripped.value(forKey: key) ?? "nil")")
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

    @Test func wallpaperDirsEscapesColonsAndBackslashes() {
        var config = Config()
        config.wallpaperDirs = ["/tmp/a:b", "/tmp/c\\d", "/plain"]
        let (parsed, warnings) = Config.parse(config.serialized())
        #expect(warnings.isEmpty)
        #expect(parsed.wallpaperDirs == ["/tmp/a:b", "/tmp/c\\d", "/plain"])

        // The documented colon-separated form still works, with or without spaces.
        var legacy = Config()
        legacy.apply(key: "wallpaper_dirs", value: "/one: /two :/three")
        #expect(legacy.wallpaperDirs == ["/one", "/two", "/three"])
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

    @Test func sanitizedClampsNewGeometryKeys() {
        var config = Config()
        config.designWidth = 10
        config.cardGap = -5
        config.cardSkew = -3
        config.cardCornerRadius = 1000
        let (low, lowWarnings) = config.sanitized()
        #expect(low.designWidth == 320)
        #expect(low.cardGap == 0)
        #expect(low.cardSkew == -2)
        #expect(low.cardCornerRadius == 400)
        for key in ["design_width", "card_gap", "card_skew", "card_corner_radius"] {
            #expect(lowWarnings.contains { $0.contains(key) }, "missing clamp warning for \(key)")
        }

        config.designWidth = 1_000_000
        config.cardGap = 5000
        config.cardSkew = 2.5
        config.cardCornerRadius = -100
        let (high, highWarnings) = config.sanitized()
        #expect(high.designWidth == 20000)
        #expect(high.cardGap == 2000)
        #expect(high.cardSkew == 2)
        #expect(high.cardCornerRadius == 0)
        #expect(!highWarnings.isEmpty)
    }

    @Test func removedGeometryKeysAreRejected() {
        var config = Config()
        for key in ["tile_width", "tile_height", "tile_shear", "shear_mode", "overlap",
                    "depth_step", "perspective", "scale_falloff", "preview_max_w_frac",
                    "preview_max_h_frac", "preview_gap", "collapsed_width_scale"] {
            #expect(config.apply(key: key, value: "1") == false, "\(key) should be unknown now")
        }
    }

    @Test func sanitizedKeepsTypicalValuesFinite() {
        let (sanitized, _) = Config().sanitized()
        let doubles = [
            sanitized.designWidth, sanitized.cardWidth, sanitized.cardHeight, sanitized.cardGap,
            sanitized.selectedCardHeight, sanitized.expandedCardWidth, sanitized.expandedCardHeight,
            sanitized.cardSkew, sanitized.cardCornerRadius, sanitized.cardBorderWidth,
            sanitized.rowCenterYFrac, sanitized.dimFalloff, sanitized.dimFloor, sanitized.dimAlpha,
            sanitized.animationMs,
        ]
        #expect(doubles.allSatisfy { $0.isFinite })
    }

    @Test func sanitizedReplacesNaN() {
        var config = Config()
        config.designWidth = .nan
        config.cardWidth = .nan
        config.rowCenterYFrac = .nan
        let (sanitized, warnings) = config.sanitized()
        #expect(!sanitized.designWidth.isNaN)
        #expect(!sanitized.cardWidth.isNaN)
        #expect(!sanitized.rowCenterYFrac.isNaN)
        #expect(sanitized.designWidth >= 320)
        #expect(warnings.filter { $0.contains("clamped") }.count >= 3)
    }

    @Test func sanitizedWarnsAboutEmptyWallpaperDirs() {
        let (_, warnings) = Config(wallpaperDirs: []).sanitized()
        #expect(warnings.contains { $0.contains("wallpaper_dirs") && $0.contains("empty") })
    }

    @Test func logLevelParsesSpellingsAndKeepsPreviousOnGarbage() {
        #expect(LogLevel.parse("WARN") == .warn)
        #expect(LogLevel.parse(" warning ") == .warn)
        #expect(LogLevel.parse("quiet") == .silent)
        #expect(LogLevel.parse("error") == .error)
        #expect(LogLevel.parse("info") == .info)
        #expect(LogLevel.parse("bogus") == nil)

        var config = Config()
        config.apply(key: "log_level", value: "info")
        #expect(config.logLevel == .info)
        // A malformed level leaves the previous one alone rather than failing the load.
        config.apply(key: "log_level", value: "bogus")
        #expect(config.logLevel == .info)
    }

    @Test func logLevelControlsWarningsStatusAndInfo() {
        #expect(LogLevel.silent.showsWarnings == false)
        #expect(LogLevel.error.showsWarnings == false)
        #expect(LogLevel.warn.showsWarnings == true)
        #expect(LogLevel.info.showsWarnings == true)
        #expect(LogLevel.silent.showsStatus == false)
        #expect(LogLevel.error.showsStatus == true)
        #expect(LogLevel.warn.showsInfo == false)
        #expect(LogLevel.info.showsInfo == true)
    }

    @Test func enumParsingIsCaseInsensitiveAndRejectsGarbage() {
        #expect(SortMode.parse("NaMe") == .name)
        #expect(SortMode.parse(" MTIME ") == .mtime)
        #expect(SortMode.parse("random") == .random)
        #expect(SortMode.parse("bogus") == nil)

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
            config.logLevel = .info

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
