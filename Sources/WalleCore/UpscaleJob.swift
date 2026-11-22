import Foundation

/// The stable boundary between the `walle` CLI and the replaceable ML upscaler.
///
/// The CLI writes a job file, runs an executable with
/// `--job <file> --result <file>`, and reads the result file. Any program in any
/// language can implement that contract; the default `walle-upscaler` is a thin
/// Swift wrapper around Upscayl's `upscayl-bin`. Replacing the upscaler does not
/// require changing the picker, library, apply or rotation code.
public struct UpscaleJobSpec: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var source: String
        public var output: String
        public var scale: Int

        public init(source: String, output: String, scale: Int) {
            self.source = source
            self.output = output
            self.scale = scale
        }
    }

    public static let schema = 1

    public var schema: Int
    public var model: String
    public var modelsDirectory: String?
    public var tool: String?
    public var quality: Double
    public var format: String
    public var targetWidth: Int
    public var targetHeight: Int
    public var jobs: [Item]

    public init(model: String, modelsDirectory: String? = nil, tool: String? = nil,
                quality: Double, format: String = "heic", target: PixelSize,
                jobs: [Item]) {
        self.schema = Self.schema
        self.model = model
        self.modelsDirectory = modelsDirectory
        self.tool = tool
        self.quality = quality
        self.format = format
        self.targetWidth = target.width
        self.targetHeight = target.height
        self.jobs = jobs
    }
}

public struct UpscaleJobResult: Codable, Sendable, Equatable {
    public struct Item: Codable, Sendable, Equatable {
        public var source: String
        public var output: String
        public var status: String
        public var error: String?
        public var width: Int?
        public var height: Int?

        public init(source: String, output: String, status: String,
                    error: String? = nil, width: Int? = nil, height: Int? = nil) {
            self.source = source
            self.output = output
            self.status = status
            self.error = error
            self.width = width
            self.height = height
        }
    }

    public static let schema = 1

    public var schema: Int
    public var results: [Item]

    public init(results: [Item]) {
        self.schema = Self.schema
        self.results = results
    }

    public func item(forOutput path: String) -> Item? {
        results.first { $0.output == path }
    }
}
