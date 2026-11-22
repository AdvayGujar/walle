import Foundation
import WalleCore
import WalleUpscalerCore

// The default ML backend. It is intentionally a separate executable so the
// entire upscaling implementation can be replaced without touching walle.
//
// Contract:
//   walle-upscaler --job <job.json> --result <result.json>
// A replacement may read the same job file and write the same result shape in
// any language or with any model/runtime.

func writeError(_ message: String) {
    FileHandle.standardError.write(Data(("walle-upscaler: " + message + "\n").utf8))
}

func usage() -> String {
    """
    walle-upscaler - the replaceable ML backend for walle upscale

    USAGE
      walle-upscaler --job <job.json> --result <result.json>
      walle-upscaler --job - --result <result.json>

    The job file is written by `walle upscale`. The result file reports one
    status per source: ok, failed or skipped, with optional output dimensions.

    OPTIONS
      --job <path>      read the job JSON from a file, or - for stdin
      --result <path>   write the result JSON here
      -h, --help        show this help
    """
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.contains("--help") || arguments.contains("-h") {
    print(usage())
    exit(0)
}

func value(of flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

guard let jobPath = value(of: "--job"), let resultPath = value(of: "--result") else {
    writeError("--job and --result are required")
    FileHandle.standardError.write(Data((usage() + "\n").utf8))
    exit(2)
}

let jobData: Data
if jobPath == "-" {
    jobData = FileHandle.standardInput.readDataToEndOfFile()
} else {
    do {
        jobData = try Data(contentsOf: URL(fileURLWithPath: jobPath))
    } catch {
        writeError("could not read \(jobPath): \(error)")
        exit(1)
    }
}

let spec: UpscaleJobSpec
do {
    spec = try JSONDecoder().decode(UpscaleJobSpec.self, from: jobData)
} catch {
    writeError("could not parse job JSON: \(error)")
    exit(1)
}

let result = MLUpscaler.run(spec) { message in
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
guard let resultData = try? encoder.encode(result) else {
    writeError("could not encode the result")
    exit(1)
}
let resultURL = URL(fileURLWithPath: resultPath)
do {
    try FileManager.default.createDirectory(at: resultURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try resultData.write(to: resultURL, options: .atomic)
} catch {
    writeError("could not write \(resultPath): \(error)")
    exit(1)
}

exit(result.results.contains { $0.status == "failed" } ? 1 : 0)
