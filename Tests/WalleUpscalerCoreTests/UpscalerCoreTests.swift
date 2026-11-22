import Foundation
import Testing
import WalleCore
@testable import WalleUpscalerCore

@Suite("ML upscaler core")
struct UpscalerCoreTests {

    @Test func heicWriterPreservesDimensionsAndProfile() throws {
        try withTempDirectory { dir in
            let source = dir.appendingPathComponent("source.png")
            let output = dir.appendingPathComponent("output.heic")
            try makePNG(at: source)
            try HEICWriter.write(imageURL: source, to: output, quality: 0.85,
                                 sourceProfile: "sRGB IEC61966-2.1")
            let info = try UpscaleInspector.inspect(output)
            #expect(info.width == 8)
            #expect(info.height == 8)
            #expect(info.profileName?.localizedCaseInsensitiveContains("srgb") == true)
        }
    }

    @Test func runsABatchThroughTheReplaceableTool() throws {
        try withTempDirectory { dir in
            let models = dir.appendingPathComponent("models")
            try makeDummyModels(at: models)
            let tool = dir.appendingPathComponent("upscayl-bin")
            try makeFakeTool(at: tool)
            let source = dir.appendingPathComponent("source.png")
            try makePNG(at: source)
            let output = dir.appendingPathComponent("out.heic")

            let spec = UpscaleJobSpec(
                model: "test-model", modelsDirectory: models.path,
                tool: tool.path, quality: 0.85, format: "heic",
                target: PixelSize(width: 16, height: 16),
                jobs: [.init(source: source.path, output: output.path, scale: 2)])
            let messages = MessageBox()
            let result = MLUpscaler.run(spec, environment: ["PATH": ""]) {
                messages.append($0)
            }

            #expect(result.results.count == 1)
            #expect(result.results[0].status == "ok")
            #expect(result.results[0].width == 8)
            #expect(result.results[0].height == 8)
            #expect(FileManager.default.fileExists(atPath: output.path))
            #expect(messages.values.contains { $0.contains("upscaling 1 image") })
        }
    }

    @Test func groupsDifferentScalesAndWritesBoth() throws {
        try withTempDirectory { dir in
            let models = dir.appendingPathComponent("models")
            try makeDummyModels(at: models)
            let tool = dir.appendingPathComponent("upscayl-bin")
            try makeFakeTool(at: tool)
            let first = dir.appendingPathComponent("one.png")
            let second = dir.appendingPathComponent("two.png")
            try makePNG(at: first)
            try makePNG(at: second)
            let outOne = dir.appendingPathComponent("one.heic")
            let outTwo = dir.appendingPathComponent("two.heic")

            let spec = UpscaleJobSpec(
                model: "test-model", modelsDirectory: models.path,
                tool: tool.path, quality: 0.85, format: "heic",
                target: PixelSize(width: 16, height: 16),
                jobs: [.init(source: first.path, output: outOne.path, scale: 2),
                       .init(source: second.path, output: outTwo.path, scale: 3)])
            let result = MLUpscaler.run(spec, environment: ["PATH": ""])
            #expect(result.results.allSatisfy { $0.status == "ok" })
            #expect(FileManager.default.fileExists(atPath: outOne.path))
            #expect(FileManager.default.fileExists(atPath: outTwo.path))
        }
    }

    @Test func reportsAToolFailurePerJob() throws {
        try withTempDirectory { dir in
            let models = dir.appendingPathComponent("models")
            try makeDummyModels(at: models)
            let tool = dir.appendingPathComponent("upscayl-bin")
            try makeFakeTool(at: tool, fail: true)
            let source = dir.appendingPathComponent("source.png")
            try makePNG(at: source)
            let output = dir.appendingPathComponent("out.heic")

            let spec = UpscaleJobSpec(
                model: "test-model", modelsDirectory: models.path,
                tool: tool.path, quality: 0.85, format: "heic",
                target: PixelSize(width: 16, height: 16),
                jobs: [.init(source: source.path, output: output.path, scale: 2)])
            let result = MLUpscaler.run(spec, environment: ["PATH": ""])
            #expect(result.results[0].status == "failed")
            #expect(result.results[0].error?.contains("fake tool failed") == true)
        }
    }

    private final class MessageBox: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ message: String) {
            lock.lock()
            storage.append(message)
            lock.unlock()
        }

        var values: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    @Test func reportsAMissingModelBeforeRunning() throws {
        try withTempDirectory { dir in
            let models = dir.appendingPathComponent("models")
            try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
            let tool = dir.appendingPathComponent("upscayl-bin")
            try makeFakeTool(at: tool)
            let source = dir.appendingPathComponent("source.png")
            try makePNG(at: source)
            let output = dir.appendingPathComponent("out.heic")

            let spec = UpscaleJobSpec(
                model: "missing-model", modelsDirectory: models.path,
                tool: tool.path, quality: 0.85, format: "heic",
                target: PixelSize(width: 16, height: 16),
                jobs: [.init(source: source.path, output: output.path, scale: 2)])
            let result = MLUpscaler.run(spec, environment: ["PATH": ""])
            #expect(result.results[0].status == "failed")
            #expect(result.results[0].error?.contains("missing-model") == true)
        }
    }
}
