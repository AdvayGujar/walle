import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import WalleCore

@Suite("Upscaling")
struct UpscalingTests {

    @Test func fillFitStretchAndCenterGeometry() {
        let target = PixelSize(width: 3024, height: 1964)
        switch UpscaleGeometry.plan(sourceWidth: 1500, sourceHeight: 1000,
                                    target: target, mode: .fill, maxScale: 4) {
        case .success(let plan):
            #expect(abs(plan.requiredScale - 2.016) < 0.0001)
            #expect(plan.outputScale == 2)
        case .failure(let reason):
            Issue.record("fill should be possible: \(reason)")
        }

        switch UpscaleGeometry.plan(sourceWidth: 1500, sourceHeight: 1000,
                                    target: target, mode: .fit, maxScale: 4) {
        case .success(let plan):
            #expect(abs(plan.requiredScale - 1.964) < 0.0001)
            #expect(plan.outputScale == 2)
        case .failure(let reason):
            Issue.record("fit should be possible: \(reason)")
        }

        switch UpscaleGeometry.plan(sourceWidth: 1500, sourceHeight: 1000,
                                    target: target, mode: .stretch, maxScale: 4) {
        case .success(let plan):
            #expect(abs(plan.requiredScale - 2.016) < 0.0001)
            #expect(plan.outputScale == 2)
        case .failure(let reason):
            Issue.record("stretch should cover like fill: \(reason)")
        }

        if case .success = UpscaleGeometry.plan(
            sourceWidth: 1500, sourceHeight: 1000, target: target,
            mode: .center, maxScale: 4) {
            Issue.record("center must be skipped")
        }
    }

    @Test func geometrySkipsLargeSourcesAndScaleCaps() {
        let target = PixelSize(width: 1000, height: 1000)
        if case .success = UpscaleGeometry.plan(
            sourceWidth: 2000, sourceHeight: 2000, target: target,
            mode: .fill, maxScale: 4) {
            Issue.record("a source larger than the target must be skipped")
        }

        switch UpscaleGeometry.plan(sourceWidth: 500, sourceHeight: 500,
                                    target: target, mode: .fill, maxScale: 1.5) {
        case .failure(.exceedsMaxScale(let scale)):
            #expect(scale == 2)
        default:
            Issue.record("expected an exceedsMaxScale skip")
        }
    }

    @Test func scaleOverrideAndAutomaticScale() {
        let target = PixelSize(width: 3024, height: 1964)
        switch UpscaleGeometry.plan(sourceWidth: 1500, sourceHeight: 1000,
                                    target: target, mode: .fill, maxScale: 4,
                                    scaleOverride: 4) {
        case .success(let plan): #expect(plan.outputScale == 4)
        case .failure(let reason): Issue.record("override failed: \(reason)")
        }

        #expect(UpscaleGeometry.outputScale(for: 1.5) == 2)
        #expect(UpscaleGeometry.outputScale(for: 2.5) == 3)
        #expect(UpscaleGeometry.outputScale(for: 3.5) == 4)
    }

    @Test func pixelSizeParsing() {
        #expect(PixelSize.parse("3024x1964") == PixelSize(width: 3024, height: 1964))
        #expect(PixelSize.parse("3024X1964") == PixelSize(width: 3024, height: 1964))
        for raw in ["", "3024", "3024x", "x1964", "0x10", "-2x10", "a x b"] {
            #expect(PixelSize.parse(raw) == nil, "\(raw) should be rejected")
        }
    }

    @Test func inspectorReadsDimensionsOrientationAndAlpha() throws {
        try withTempDirectory { dir in
            let sourceURL = dir.appendingPathComponent("source.png")
            try makeTestPNG(at: sourceURL, width: 8, height: 4, orientation: 6)
            let info = try UpscaleInspector.inspect(sourceURL)
            #expect(info.width == 4)
            #expect(info.height == 8)
            #expect(info.bitsPerComponent == 8)
            #expect(info.colorModel.uppercased() == "RGB")
            #expect(info.hasAlpha == false)

            let alphaURL = dir.appendingPathComponent("alpha.png")
            try makeTestPNG(at: alphaURL, width: 8, height: 8, opaque: false)
            let alpha = try UpscaleInspector.inspect(alphaURL)
            #expect(alpha.hasAlpha)
            if case .unsupported(let why)? = UpscaleInspector.skipReason(for: alpha) {
                #expect(why.contains("transparent"))
            } else {
                Issue.record("transparent images should be skipped")
            }
        }
    }

    @Test func manifestRoundTripsAndMatchesTheSource() throws {
        try withTempDirectory { dir in
            let url = dir.appendingPathComponent("manifest.json")
            let plan = UpscalePlan(
                sourceWidth: 1500, sourceHeight: 1000,
                targetWidth: 3024, targetHeight: 1964,
                requiredScale: 2.016, outputScale: 2)
            let mtime = Date(timeIntervalSince1970: 1_700_000_000)
            let entry = UpscaleManifest.Entry(
                source: "/tmp/source.jpg", output: "source.heic", plan: plan,
                mode: .fill, format: "heic", quality: 0.85,
                model: "realesrgan-x4plus",
                upscaler: "/usr/local/bin/walle-upscaler",
                tool: "/tools/upscayl-bin", modelsDirectory: "/models",
                sourceMtime: mtime, sourceBytes: 1234,
                outputWidth: 3000, outputHeight: 2000)
            try UpscaleManifest(entries: [entry]).save(to: url)

            let loaded = UpscaleManifest.load(from: url)
            #expect(loaded.entries.count == 1)
            #expect(loaded.entries[0].source == entry.source)
            #expect(loaded.entries[0].output == entry.output)
            #expect(loaded.entries[0].outputWidth == 3000)
            #expect(loaded.entries[0].matches(
                sourceInfo: UpscaleSourceInfo(
                    width: 1500, height: 1000, bitsPerComponent: 8,
                    colorModel: "RGB", hasAlpha: false, hasHDRGainMap: false,
                    profileName: "sRGB", fileSize: 1234, modifiedAt: mtime),
                plan: plan, mode: .fill, format: "heic", quality: 0.85,
                model: "realesrgan-x4plus",
                tool: "/tools/upscayl-bin", modelsDirectory: "/models"))

            try Data("not json".utf8).write(to: url)
            #expect(UpscaleManifest.load(from: url).entries.isEmpty)
        }
    }

    @Test func jobSpecRoundTrips() throws {
        let spec = UpscaleJobSpec(
            model: "realesrgan-x4plus", modelsDirectory: "/models",
            tool: "/tools/upscayl-bin", quality: 0.85, format: "heic",
            target: PixelSize(width: 3024, height: 1964),
            jobs: [.init(source: "/a.png", output: "/a.heic", scale: 2)])
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(UpscaleJobSpec.self, from: data)
        #expect(decoded == spec)

        let result = UpscaleJobResult(results: [
            .init(source: "/a.png", output: "/a.heic", status: "ok",
                  width: 3000, height: 2000),
        ])
        let resultData = try JSONEncoder().encode(result)
        #expect(try JSONDecoder().decode(UpscaleJobResult.self,
                                         from: resultData) == result)
    }

    @Test func cacheResolvesFreshCopiesAndPrunesDeletedSources() throws {
        try withTempDirectory { dir in
            let paths = WallePaths(
                home: dir,
                configFile: dir.appendingPathComponent("config"),
                dataDir: dir.appendingPathComponent("data"),
                cacheDir: dir.appendingPathComponent("cache"))
            let source = dir.appendingPathComponent("source.png")
            try makeTestPNG(at: source, width: 8, height: 8)
            let info = try UpscaleInspector.inspect(source)
            let target = PixelSize(width: 8, height: 8)
            let root = UpscaleCache.root(paths: paths, model: "realesrgan-x4plus",
                                         target: target)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let cached = root.appendingPathComponent("source.heic")
            try makeTestHEIC(at: cached, width: 8, height: 8)
            let plan = UpscalePlan(sourceWidth: 8, sourceHeight: 8,
                                   targetWidth: 8, targetHeight: 8,
                                   requiredScale: 1, outputScale: 2)
            let entry = UpscaleManifest.Entry(
                source: source.path, output: "source.heic", plan: plan,
                mode: .fill, format: "heic", quality: 0.85,
                model: "realesrgan-x4plus",
                upscaler: "/usr/local/bin/walle-upscaler",
                tool: nil, modelsDirectory: nil,
                sourceMtime: info.modifiedAt, sourceBytes: info.fileSize,
                outputWidth: 8, outputHeight: 8)
            try UpscaleManifest(entries: [entry]).save(
                to: root.appendingPathComponent("manifest.json"))

            let cache = UpscaleCache(paths: paths, model: "realesrgan-x4plus",
                                     target: target)
            #expect(cache.cachedURL(for: source)?.path == cached.path)
            #expect(cache.source(forOutput: cached) == source.path)

            // Changing the source invalidates the copy.
            try Data("changed".utf8).write(to: source)
            #expect(cache.cachedURL(for: source) == nil)

            // A missing source removes its cached file and entry.
            try FileManager.default.removeItem(at: source)
            let orphan = root.appendingPathComponent("orphan.heic")
            try makeTestHEIC(at: orphan, width: 8, height: 8)
            let pruned = UpscaleCache.pruneAll(paths: paths)
            #expect(pruned.files >= 2)
            #expect(!FileManager.default.fileExists(atPath: cached.path))
            #expect(!FileManager.default.fileExists(atPath: orphan.path))
        }
    }

    @Test func sourceForCurrentUsesStateThenCache() throws {
        try withTempDirectory { dir in
            let paths = WallePaths(
                home: dir,
                configFile: dir.appendingPathComponent("config"),
                dataDir: dir.appendingPathComponent("data"),
                cacheDir: dir.appendingPathComponent("cache"))
            let source = dir.appendingPathComponent("source.png")
            try makeTestPNG(at: source, width: 8, height: 8)
            try StateStore(fileURL: paths.stateFile).save(
                WalleState(lastAppliedPath: source.path,
                           lastDisplayPath: "/cache/source.heic"))
            #expect(UpscaleCache.sourceForCurrent(
                paths: paths, displayPath: "/cache/source.heic") == source.path)
        }
    }

    @Test func refreshWhileFillIsRunningLeavesAPendingMarker() throws {
        try withTempDirectory { dir in
            let paths = WallePaths(
                home: dir,
                configFile: dir.appendingPathComponent("config"),
                dataDir: dir.appendingPathComponent("data"),
                cacheDir: dir.appendingPathComponent("cache"))
            let cli = dir.appendingPathComponent("fake-cli")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: cli)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: cli.path)
            let lock = try #require(SingleInstance.acquire(at: paths.upscaleLockFile))
            defer { SingleInstance.release(lock) }

            let started = UpscaleCache.refreshInBackground(
                paths: paths, environment: ["WALLE_CLI": cli.path], enabled: true)
            #expect(started)
            #expect(FileManager.default.fileExists(
                atPath: paths.upscalePendingRefresh.path))
        }
    }

    @Test func programmaticUpscalerLocations() throws {
        try withTempDirectory { dir in
            let tool = dir.appendingPathComponent("custom-upscaler")
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tool)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: tool.path)
            #expect(UpscalerLocator.locate(command: tool.path, argv0: nil) == tool)
            #expect(UpscalerLocator.locate(command: "missing-upscaler",
                                           environment: ["PATH": ""], argv0: nil) == nil)
        }
    }
}
