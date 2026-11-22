import Foundation

/// The record of what `walle upscale` generated in one output directory.
///
/// It lets a second run skip unchanged sources, and gives the CLI enough context
/// to notice that the model, backend or target changed. A missing, corrupt or
/// older-schema manifest is treated as empty: outputs are regenerated rather
/// than making the command fail.
public struct UpscaleManifest: Codable, Sendable, Equatable {
    public static let schema = 2

    public struct Entry: Codable, Sendable, Equatable {
        public var source: String
        public var output: String
        public var targetWidth: Int
        public var targetHeight: Int
        public var outputWidth: Int
        public var outputHeight: Int
        public var scale: Double
        public var mode: String
        public var format: String
        public var quality: Double
        public var model: String
        public var upscaler: String
        public var tool: String?
        public var modelsDirectory: String?
        public var sourceMtime: Double
        public var sourceBytes: Int
        public var algorithm: String
        public var createdAt: Date

        public init(source: String, output: String, plan: UpscalePlan,
                    mode: FillMode, format: String, quality: Double,
                    model: String, upscaler: String, tool: String?,
                    modelsDirectory: String?, sourceMtime: Date,
                    sourceBytes: Int, outputWidth: Int, outputHeight: Int) {
            self.source = source
            self.output = output
            self.targetWidth = plan.targetWidth
            self.targetHeight = plan.targetHeight
            self.outputWidth = outputWidth
            self.outputHeight = outputHeight
            self.scale = Double(plan.outputScale)
            self.mode = mode.rawValue
            self.format = format
            self.quality = quality
            self.model = model
            self.upscaler = upscaler
            self.tool = tool
            self.modelsDirectory = modelsDirectory
            self.sourceMtime = sourceMtime.timeIntervalSince1970
            self.sourceBytes = sourceBytes
            self.algorithm = "ml-upscaler-v1"
            self.createdAt = Date()
        }

        public func matches(sourceInfo: UpscaleSourceInfo, plan: UpscalePlan,
                            mode: FillMode, format: String, quality: Double,
                            model: String, tool: String?,
                            modelsDirectory: String?) -> Bool {
            // The executable path is recorded for diagnostics, not as part of the
            // cache identity: switching between a debug and release build of the
            // same backend must not re-upscale an entire library.
            self.targetWidth == plan.targetWidth
                && self.targetHeight == plan.targetHeight
                && self.scale == Double(plan.outputScale)
                && self.mode == mode.rawValue
                && self.format == format
                && abs(self.quality - quality) < 0.0001
                && self.model == model
                && self.tool == tool
                && self.modelsDirectory == modelsDirectory
                && abs(self.sourceMtime - sourceInfo.modifiedAt.timeIntervalSince1970) < 0.0001
                && self.sourceBytes == sourceInfo.fileSize
                && self.algorithm == "ml-upscaler-v1"
        }
    }

    public var schema: Int
    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.schema = Self.schema
        self.entries = entries
    }

    public static func load(from url: URL) -> UpscaleManifest {
        guard let data = FileManager.default.contents(atPath: url.path),
              !data.isEmpty,
              let manifest = try? makeDecoder().decode(UpscaleManifest.self, from: data),
              manifest.schema == Self.schema else {
            return UpscaleManifest()
        }
        return manifest
    }

    public func save(to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try Self.makeEncoder().encode(self)
        let temporary = directory.appendingPathComponent(".manifest-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
        } else {
            try FileManager.default.moveItem(at: temporary, to: url)
        }
    }

    public func entry(forSource path: String) -> Entry? {
        entries.first { $0.source == path }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
