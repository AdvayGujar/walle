import Foundation
import WalleCore

/// The default ML backend: one Upscayl `upscayl-bin` process per scale group,
/// then HEIC conversion with the source colour profile attached.
///
/// This is deliberately replaceable. The CLI only knows the job/result JSON
/// contract in `WalleCore`; a different executable (Core ML, Metal, a remote
/// service, a different model runner) can replace `walle-upscaler` entirely.
public struct MLUpscaler: Sendable {
    public init() {}

    public static func run(
        _ spec: UpscaleJobSpec,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        progress: @Sendable (String) -> Void = { _ in }
    ) -> UpscaleJobResult {
        guard spec.format.lowercased() == "heic" else {
            return failure(spec, "unsupported output format '\(spec.format)'; expected heic")
        }
        guard !spec.jobs.isEmpty else { return UpscaleJobResult(results: []) }
        guard !spec.model.isEmpty, !spec.model.contains("/") else {
            return failure(spec, "invalid model name '\(spec.model)'")
        }

        let tool: URL
        let models: URL
        do {
            tool = try locateTool(spec, environment: environment)
            models = try locateModels(spec, environment: environment)
            try validateModel(spec.model, in: models)
        } catch {
            return failure(spec, String(describing: error))
        }

        let groups = Dictionary(grouping: spec.jobs, by: \.scale)
            .sorted { $0.key < $1.key }
        var results: [UpscaleJobResult.Item] = []
        for (scale, jobs) in groups {
            guard [2, 3, 4].contains(scale) else {
                results.append(contentsOf: jobs.map {
                    .init(source: $0.source, output: $0.output, status: "failed",
                          error: "unsupported scale \(scale); expected 2, 3 or 4")
                })
                continue
            }
            results.append(contentsOf: runGroup(
                jobs, scale: scale, spec: spec, tool: tool, models: models,
                progress: progress))
        }
        return UpscaleJobResult(results: results)
    }

    private static func runGroup(
        _ jobs: [UpscaleJobSpec.Item], scale: Int, spec: UpscaleJobSpec,
        tool: URL, models: URL, progress: @Sendable (String) -> Void
    ) -> [UpscaleJobResult.Item] {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("walle-upscaler-\(UUID().uuidString)", isDirectory: true)
        let inputDir = work.appendingPathComponent("in", isDirectory: true)
        let outputDir = work.appendingPathComponent("out", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: work) }

        do {
            try FileManager.default.createDirectory(at: inputDir, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
        } catch {
            return jobs.map { .init(source: $0.source, output: $0.output,
                                   status: "failed", error: String(describing: error)) }
        }

        var staged: [(job: UpscaleJobSpec.Item, stem: String, source: URL)] = []
        for (index, job) in jobs.enumerated() {
            let source = URL(fileURLWithPath: job.source)
            let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension
            let stem = String(format: "%04d", index)
            let destination = inputDir.appendingPathComponent("\(stem).\(ext)")
            do {
                try stage(source, at: destination)
                staged.append((job, stem, source))
            } catch {
                // handled below as a failed item
                staged.append((job, "", source))
            }
        }

        let valid = staged.filter { !$0.stem.isEmpty }
        guard !valid.isEmpty else {
            return staged.map { entry in
                .init(source: entry.job.source, output: entry.job.output,
                      status: "failed", error: "could not stage the source image")
            }
        }

        progress("upscaling \(valid.count) image\(valid.count == 1 ? "" : "s") "
                 + "with \(spec.model) at \(scale)x")
        let arguments = [
            "-i", inputDir.path,
            "-o", outputDir.path,
            "-m", models.path,
            "-n", spec.model,
            "-s", String(scale),
            "-f", "png",
        ]
        let run = runProcess(tool, arguments: arguments)
        guard run.status == 0 else {
            let detail = tail(run.output.isEmpty ? "upscayl-bin failed" : run.output)
            return staged.map { entry in
                .init(source: entry.job.source, output: entry.job.output,
                      status: "failed", error: detail)
            }
        }

        var results: [UpscaleJobResult.Item] = []
        for entry in staged {
            guard !entry.stem.isEmpty else {
                results.append(.init(source: entry.job.source, output: entry.job.output,
                                     status: "failed", error: "could not stage the source image"))
                continue
            }
            guard let produced = producedImage(in: outputDir, stem: entry.stem) else {
                results.append(.init(source: entry.job.source, output: entry.job.output,
                                     status: "failed", error: "upscaler produced no output"))
                continue
            }
            do {
                let outputURL = URL(fileURLWithPath: entry.job.output)
                try HEICWriter.write(
                    imageURL: produced, to: outputURL, quality: spec.quality,
                    sourceProfile: HEICWriter.profileName(for: entry.source))
                let info = try UpscaleInspector.inspect(outputURL)
                results.append(.init(source: entry.job.source, output: entry.job.output,
                                     status: "ok", width: info.width, height: info.height))
                progress("wrote \(outputURL.lastPathComponent) "
                         + "(\(info.width)x\(info.height))")
            } catch {
                results.append(.init(source: entry.job.source, output: entry.job.output,
                                     status: "failed", error: String(describing: error)))
            }
        }
        return results
    }

    private static func stage(_ source: URL, at destination: URL) throws {
        do {
            try FileManager.default.linkItem(at: source, to: destination)
        } catch {
            try FileManager.default.copyItem(at: source, to: destination)
        }
    }

    private static func producedImage(in directory: URL, stem: String) -> URL? {
        let preferred = directory.appendingPathComponent(stem + ".png")
        if FileManager.default.fileExists(atPath: preferred.path) { return preferred }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil) else { return nil }
        return entries.first { $0.deletingPathExtension().lastPathComponent == stem }
    }

    private static func runProcess(_ tool: URL,
                                   arguments: [String]) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (127, "could not run \(tool.path): \(error)")
        }
        // A single combined pipe cannot deadlock: the child can fill it, but the
        // parent is already draining it to EOF.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, text)
    }

    private static func tail(_ text: String) -> String {
        text.split(separator: "\n")
            .suffix(4)
            .joined(separator: " | ")
    }

    private static func failure(_ spec: UpscaleJobSpec, _ message: String) -> UpscaleJobResult {
        UpscaleJobResult(results: spec.jobs.map {
            .init(source: $0.source, output: $0.output, status: "failed", error: message)
        })
    }

    private static func locateTool(
        _ spec: UpscaleJobSpec, environment: [String: String]
    ) throws -> URL {
        if let raw = spec.tool, !raw.isEmpty {
            let url = walleExpand(raw, home: FileManager.default.homeDirectoryForCurrentUser)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
            throw UpscalerSetupError.toolNotFound(raw)
        }
        var candidates: [URL] = []
        if let raw = environment["WALLE_UPSCAYL_BIN"], !raw.isEmpty {
            candidates.append(walleExpand(raw, home: FileManager.default.homeDirectoryForCurrentUser))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(WallePaths.resolve(environment: environment)
            .upscalerDir.appendingPathComponent("upscayl-bin"))
        candidates.append(URL(fileURLWithPath: "/Applications/Upscayl.app/Contents/Resources/upscayl-bin"))
        candidates.append(home.appendingPathComponent(
            "Applications/Upscayl.app/Contents/Resources/upscayl-bin"))
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            candidates.append(URL(fileURLWithPath: String(directory))
                .appendingPathComponent("upscayl-bin"))
        }
        if let found = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) {
            return found
        }
        throw UpscalerSetupError.toolNotFound("upscayl-bin")
    }

    private static func locateModels(
        _ spec: UpscaleJobSpec, environment: [String: String]
    ) throws -> URL {
        if let raw = spec.modelsDirectory, !raw.isEmpty {
            let url = walleExpand(raw, home: FileManager.default.homeDirectoryForCurrentUser)
            if isDirectory(url) { return url }
            throw UpscalerSetupError.modelsNotFound(raw)
        }
        var candidates: [URL] = []
        if let raw = environment["WALLE_UPSCAYL_MODELS"], !raw.isEmpty {
            candidates.append(walleExpand(raw, home: FileManager.default.homeDirectoryForCurrentUser))
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        candidates.append(WallePaths.resolve(environment: environment)
            .upscalerDir.appendingPathComponent("models"))
        candidates.append(URL(fileURLWithPath: "/Applications/Upscayl.app/Contents/Resources/models"))
        candidates.append(home.appendingPathComponent(
            "Applications/Upscayl.app/Contents/Resources/models"))
        if let found = candidates.first(where: isDirectory) { return found }
        throw UpscalerSetupError.modelsNotFound("Upscayl models")
    }

    private static func validateModel(_ model: String, in directory: URL) throws {
        for ext in ["bin", "param"] {
            let file = directory.appendingPathComponent(model + "." + ext)
            guard FileManager.default.fileExists(atPath: file.path) else {
                throw UpscalerSetupError.modelNotFound(model, file.path)
            }
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            && isDirectory.boolValue
    }
}

public enum UpscalerSetupError: Error, CustomStringConvertible {
    case toolNotFound(String)
    case modelsNotFound(String)
    case modelNotFound(String, String)

    public var description: String {
        switch self {
        case .toolNotFound(let path):
            return "upscayl-bin not found at \(path); install Upscayl or set "
                + "upscale_tool / WALLE_UPSCAYL_BIN"
        case .modelsNotFound(let path):
            return "Upscayl models not found at \(path); set upscale_models / "
                + "WALLE_UPSCAYL_MODELS"
        case .modelNotFound(let name, let path):
            return "model \(name) is missing \(path); put the .bin and .param pair "
                + "in the models directory"
        }
    }
}
