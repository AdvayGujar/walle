import Foundation
import Testing
@testable import WalleCore

@Suite("CLI")
struct CLITests {

    // MARK: - Harness

    private final class Captured: @unchecked Sendable {
        private let lock = NSLock()
        private var outLines: [String] = []
        private var errLines: [String] = []

        func record(stdout line: String) {
            lock.lock()
            outLines.append(line)
            lock.unlock()
        }

        func record(stderr line: String) {
            lock.lock()
            errLines.append(line)
            lock.unlock()
        }

        var stdout: String {
            lock.lock()
            defer { lock.unlock() }
            return outLines.joined(separator: "\n")
        }

        var stderr: String {
            lock.lock()
            defer { lock.unlock() }
            return errLines.joined(separator: "\n")
        }
    }

    private struct Run {
        let code: Int32
        let out: String
        let err: String
    }

    private func paths(in directory: URL) -> WallePaths {
        WallePaths(home: directory,
                   configFile: directory.appendingPathComponent("config"),
                   dataDir: directory.appendingPathComponent("data"),
                   cacheDir: directory.appendingPathComponent("cache"))
    }

    private func run(_ arguments: [String], in directory: URL,
                     environment extra: [String: String] = [:]) -> Run {
        let capture = Captured()
        let paths = paths(in: directory)
        var environment = extra
        environment["WALLE_CONFIG"] = paths.configFile.path
        environment["WALLE_DATA_DIR"] = paths.dataDir.path
        environment["WALLE_CACHE_DIR"] = paths.cacheDir.path
        let cli = CLIEnvironment(
            paths: paths,
            output: CLIOutput(out: { capture.record(stdout: $0) },
                              err: { capture.record(stderr: $0) }),
            environment: environment)
        let code = CLI.run(arguments, environment: cli)
        return Run(code: code, out: capture.stdout, err: capture.stderr)
    }

    @discardableResult
    private func saveConfig(_ paths: WallePaths,
                            dirs: [String],
                            recursive: Bool = false,
                            spaces: SpacesMode = .current,
                            logLevel: LogLevel = .silent) throws -> Config {
        var config = Config()
        config.wallpaperDirs = dirs
        config.recursive = recursive
        config.spaces = spaces
        config.logLevel = logLevel
        try config.save(to: paths.configFile)
        return config
    }

    private func makeLibrary(_ directory: URL, files: [String]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files {
            try Data(file.utf8).write(to: directory.appendingPathComponent(file))
        }
    }

    private func json(_ text: String) throws -> Any {
        try JSONSerialization.jsonObject(with: Data(text.utf8))
    }

    private func jsonObject(_ text: String) throws -> [String: Any] {
        try #require(try json(text) as? [String: Any])
    }

    private let tinyPNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!

    private func makeStore(at url: URL) throws {
        let root: [String: Any] = ["Spaces": ["" : ["Default": ["Desktop": [String: Any]()]]]]
        let data = try PropertyListSerialization.data(fromPropertyList: root,
                                                      format: .binary, options: 0)
        try data.write(to: url)
    }

    private func makeFakePicker(at url: URL, pixels: Int) throws {
        try Data("#!/bin/sh\necho \(pixels)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
    }

    /// A picker stand-in that records the arguments it was called with.
    private func makeRecordingPicker(at url: URL) throws -> URL {
        let log = url.deletingLastPathComponent().appendingPathComponent("picker-args.log")
        let script = """
        #!/bin/sh
        for argument in "$@"; do
            echo "$argument"
        done >> "\(log.path)"
        exit 0
        """
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
        return log
    }

    /// A picker stand-in that answers --display-info with a fixed screen.
    private func makeDisplayPicker(at url: URL, width: Int, height: Int) throws {
        let script = """
        #!/bin/sh
        if [ "$1" = "--display-info" ]; then
            echo '{"screens":[{"pixelWidth":\(width),"pixelHeight":\(height),"active":true}]}'
            exit 0
        fi
        exit 0
        """
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: url.path)
    }

    /// A fake replaceable upscaler: copies a small HEIC fixture to every output
    /// and writes the result JSON the real module would write.
    private func makeFakeUpscaler(in directory: URL) throws -> URL {
        let fixture = directory.appendingPathComponent("fake-output.heic")
        try makeTestHEIC(at: fixture, width: 8, height: 8)
        let script = directory.appendingPathComponent("fake-upscaler")
        let text = """
        #!/bin/sh
        job=""
        result=""
        while [ $# -gt 0 ]; do
            case "$1" in
                --job) job="$2"; shift 2 ;;
                --result) result="$2"; shift 2 ;;
                *) shift ;;
            esac
        done
        /usr/bin/python3 - "$job" "$result" "\(fixture.path)" <<'PY'
        import json, shutil, sys
        job = json.load(open(sys.argv[1]))
        results = []
        for item in job["jobs"]:
            shutil.copyfile(sys.argv[3], item["output"])
            results.append({
                "source": item["source"],
                "output": item["output"],
                "status": "ok",
                "width": 8,
                "height": 8,
            })
        json.dump({"schema": 1, "results": results}, open(sys.argv[2], "w"))
        PY
        """
        try Data(text.utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: script.path)
        return script
    }

    /// The scanner's canonical paths, not the test's possibly symlinked ones.
    private func scannedWallpapers(_ config: Config, home: URL) -> [Wallpaper] {
        LibraryScanner(config: config, home: home)
            .scan(includeAspectRatio: false).wallpapers
    }

    // MARK: - Top-level commands

    @Test func versionPrintsTheVersion() {
        withTempDirectory { dir in
            let result = run(["version"], in: dir)
            #expect(result.code == CLIExit.success.rawValue)
            #expect(result.out == "walle " + WalleVersion.string)
        }
    }

    @Test func versionFlagIsAcceptedGlobally() {
        withTempDirectory { dir in
            let result = run(["--version"], in: dir)
            #expect(result.code == CLIExit.success.rawValue)
            #expect(result.out == "walle " + WalleVersion.string)
        }
    }

    @Test func helpListsUsageAndExitCodes() {
        withTempDirectory { dir in
            let result = run(["help"], in: dir)
            #expect(result.code == CLIExit.success.rawValue)
            #expect(result.out.contains("USAGE"))
            #expect(result.out.contains("EXIT CODES"))
        }
    }

    @Test func unknownCommandFailsWithUsageHint() {
        withTempDirectory { dir in
            let result = run(["nope"], in: dir)
            #expect(result.code == CLIExit.failure.rawValue)
            #expect(result.err.contains("unknown command 'nope'"))
            #expect(result.err.contains("run 'walle help' for usage"))
        }
    }

    @Test func unknownOrIncompleteOptionsFail() {
        withTempDirectory { dir in
            let unknown = run(["list", "--nope"], in: dir)
            #expect(unknown.code == CLIExit.failure.rawValue)
            #expect(unknown.err.contains("unknown option --nope"))

            let missing = run(["history", "--limit"], in: dir)
            #expect(missing.code == CLIExit.failure.rawValue)
            #expect(missing.err.contains("option --limit needs a value"))

            let notANumber = run(["list", "--limit", "many"], in: dir)
            #expect(notANumber.code == CLIExit.failure.rawValue)
            #expect(notANumber.err.contains("expects an integer"))
        }
    }

    @Test func shortOptionAliasesResolve() throws {
        try withTempDirectory { dir in
            let result = run(["config", "get", "fill_mode", "-j"], in: dir)
            #expect(result.code == CLIExit.success.rawValue)
            let object = try jsonObject(result.out)
            #expect(object["key"] as? String == "fill_mode")
            #expect(object["value"] as? String == "fill")
        }
    }

    // MARK: - Config and directories

    @Test func configSetGetListAndUnsetRoundTrip() throws {
        try withTempDirectory { dir in
            let paths = paths(in: dir)

            let set = run(["config", "set", "slots", "7"], in: dir)
            #expect(set.code == CLIExit.success.rawValue)
            #expect(set.out == "slots = 7")

            #expect(run(["config", "get", "slots"], in: dir).out == "7")

            let list = try jsonObject(run(["config", "list", "--json"], in: dir).out)
            let settings = try #require(list["settings"] as? [String: String])
            #expect(settings["slots"] == "7")
            #expect(settings["fill_mode"] == "fill")

            #expect(run(["config", "unset", "slots"], in: dir).out == "slots = 5")

            let unknown = run(["config", "get", "nope"], in: dir)
            #expect(unknown.code == CLIExit.failure.rawValue)
            #expect(unknown.err.contains("unknown setting 'nope'"))
            #expect(FileManager.default.fileExists(atPath: paths.configFile.path))
        }
    }

    @Test func dirAddListAndRemoveRoundTrip() throws {
        try withTempDirectory { dir in
            let library = dir.appendingPathComponent("walls").standardizedFileURL
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)

            let add = run(["dir", "add", library.path], in: dir)
            #expect(add.code == CLIExit.success.rawValue)
            #expect(add.out == "added " + library.path)

            let duplicate = run(["dir", "add", library.path], in: dir)
            #expect(duplicate.code == CLIExit.success.rawValue)
            #expect(duplicate.err.contains("already configured"))

            let list = run(["dirs"], in: dir)
            #expect(list.out.contains(library.path))
            #expect(list.out.contains("0 images"))

            let remove = run(["dir", "remove", library.path], in: dir)
            #expect(remove.code == CLIExit.success.rawValue)
            #expect(remove.out.contains("removed"))

            let again = run(["dir", "remove", library.path], in: dir)
            #expect(again.code == CLIExit.failure.rawValue)
            #expect(again.err.contains("not a configured directory"))

            let missing = run(["dir", "add", dir.appendingPathComponent("missing").path,
                               "--no-create"], in: dir)
            #expect(missing.code == CLIExit.failure.rawValue)
            #expect(missing.err.contains("directory does not exist"))
        }
    }

    // MARK: - Library output

    @Test func listJSONReadsConfiguredAndExtraRoots() throws {
        try withTempDirectory { dir in
            let first = dir.appendingPathComponent("first").standardizedFileURL
            let second = dir.appendingPathComponent("second").standardizedFileURL
            try makeLibrary(first, files: ["b.png", "a.png"])
            try makeLibrary(second, files: ["c.png"])
            let paths = paths(in: dir)
            try saveConfig(paths, dirs: [first.path])

            let result = run(["list", "--json", "--limit", "1", "--dir", second.path], in: dir)
            #expect(result.code == CLIExit.success.rawValue)
            let object = try jsonObject(result.out)
            #expect(object["count"] as? Int == 1)
            let roots = try #require(object["roots"] as? [String])
            #expect(roots == [first.path, second.path])
            let wallpapers = try #require(object["wallpapers"] as? [[String: Any]])
            #expect(wallpapers.count == 1)
            #expect(wallpapers[0]["name"] as? String == "a.png")
        }
    }

    // MARK: - Selection without a picker

    @Test func setDryRunPrintsTheChosenPathWithoutApplying() throws {
        try withTempDirectory { dir in
            let file = dir.appendingPathComponent("wall.png").standardizedFileURL
            try tinyPNG.write(to: file)

            let result = run(["set", file.path, "--dry-run"], in: dir)
            #expect(result.code == CLIExit.success.rawValue)
            #expect(result.out == file.path)
            #expect(result.err.isEmpty)
        }
    }

    @Test func setNextDryRunUsesTheConfiguredLibrary() throws {
        try withTempDirectory { dir in
            let library = dir.appendingPathComponent("walls").standardizedFileURL
            try makeLibrary(library, files: ["b.png", "a.png"])
            let paths = paths(in: dir)
            try saveConfig(paths, dirs: [library.path])

            let result = run(["set", "--next", "--dry-run"], in: dir)
            #expect(result.code == CLIExit.success.rawValue)
            #expect(result.out.hasSuffix("a.png"))
        }
    }

    // MARK: - Rotation

    @Test func rotateOnceDryRunStartsFromTheLastAppliedWallpaper() throws {
        try withTempDirectory { dir in
            let library = dir.appendingPathComponent("walls").standardizedFileURL
            try makeLibrary(library, files: ["c.png", "a.png", "b.png"])
            let paths = paths(in: dir)
            let config = try saveConfig(paths, dirs: [library.path])
            let scanned = scannedWallpapers(config, home: dir)
            let first = try #require(scanned.first { $0.name == "a.png" })
            let second = try #require(scanned.first { $0.name == "b.png" })

            // No state yet: rotation starts at the beginning of the sort order.
            let initial = run(["rotate", "--once", "--dry-run"], in: dir)
            #expect(initial.code == CLIExit.success.rawValue)
            #expect(initial.out == first.path)

            // The picker applied b.png; the next rotation must advance from there.
            try StateStore(fileURL: paths.stateFile)
                .save(WalleState(lastAppliedPath: second.path))
            let continued = run(["rotate", "--once", "--dry-run"], in: dir)
            #expect(continued.code == CLIExit.success.rawValue)
            #expect(continued.out.hasSuffix("c.png"))
        }
    }

    @Test func rotateOnceAppliesThroughThePickerWithRotateMode() throws {
        try withTempDirectory { dir in
            let library = dir.appendingPathComponent("walls").standardizedFileURL
            try makeLibrary(library, files: ["a.png", "b.png"])
            let paths = paths(in: dir)
            let config = try saveConfig(paths, dirs: [library.path], logLevel: .warn)
            let scanned = scannedWallpapers(config, home: dir)
            let expected = try #require(scanned.first { $0.name == "a.png" })

            let picker = dir.appendingPathComponent("picker.sh")
            let log = try makeRecordingPicker(at: picker)

            let result = run(["rotate", "--once"], in: dir,
                             environment: ["WALLE_PICKER": picker.path])
            #expect(result.code == CLIExit.success.rawValue)
            #expect(result.out.contains("rotated to " + expected.path))

            let arguments = try String(contentsOf: log, encoding: .utf8)
            #expect(arguments.contains("--apply"))
            #expect(arguments.contains(expected.path))
            #expect(arguments.contains("--mode\nrotate"))
        }
    }

    @Test func rotateSkipsWhileThePickerIsOpen() throws {
        try withTempDirectory { dir in
            let library = dir.appendingPathComponent("walls").standardizedFileURL
            try makeLibrary(library, files: ["a.png", "b.png"])
            let paths = paths(in: dir)
            try saveConfig(paths, dirs: [library.path])

            let lock = try #require(SingleInstance.acquire(at: paths.lockFile))
            defer { SingleInstance.release(lock) }

            let result = run(["rotate", "--once", "--dry-run"], in: dir)
            #expect(result.code == CLIExit.success.rawValue)
            #expect(result.out.isEmpty)
        }
    }

    @Test func rotateRefusesASecondLoopAndReleasesItsLock() throws {
        try withTempDirectory { dir in
            let paths = paths(in: dir)
            let lock = try #require(SingleInstance.acquire(at: paths.rotationLockFile))
            defer { SingleInstance.release(lock) }

            let blocked = run(["rotate", "--once"], in: dir)
            #expect(blocked.code == CLIExit.alreadyRunning.rawValue)
            #expect(blocked.err.contains("another rotation is already running"))
        }

        try withTempDirectory { dir in
            let library = dir.appendingPathComponent("walls").standardizedFileURL
            try makeLibrary(library, files: ["a.png"])
            let paths = paths(in: dir)
            try saveConfig(paths, dirs: [library.path])
            let picker = dir.appendingPathComponent("picker.sh")
            _ = try makeRecordingPicker(at: picker)

            let result = run(["rotate", "--once"], in: dir,
                             environment: ["WALLE_PICKER": picker.path])
            #expect(result.code == CLIExit.success.rawValue)
            #expect(SingleInstance.isHeld(at: paths.rotationLockFile) == false)
        }
    }

    @Test func rotateRejectsBadIntervalsAndEmptyLibraries() {
        withTempDirectory { dir in
            let invalid = run(["rotate", "1.5m", "--once", "--dry-run"], in: dir)
            #expect(invalid.code == CLIExit.failure.rawValue)
            #expect(invalid.err.contains("expects a duration"))

            let both = run(["rotate", "10m", "--interval", "5m", "--once"], in: dir)
            #expect(both.code == CLIExit.failure.rawValue)
            #expect(both.err.contains("not both"))

            let empty = run(["rotate", "--once", "--dry-run"], in: dir)
            #expect(empty.code == CLIExit.failure.rawValue)
            #expect(empty.err.contains("library is empty"))
        }
    }

    @Test func rotateJSONReportsTheChosenWallpaper() throws {
        try withTempDirectory { dir in
            let library = dir.appendingPathComponent("walls").standardizedFileURL
            try makeLibrary(library, files: ["a.png"])
            let paths = paths(in: dir)
            let config = try saveConfig(paths, dirs: [library.path])
            let wallpaper = try #require(scannedWallpapers(config, home: dir).first)

            let result = run(["rotate", "--once", "--dry-run", "--json"], in: dir)
            let object = try jsonObject(result.out)
            #expect(object["wouldApply"] as? String == wallpaper.path)
            #expect(object["interval"] as? String == "30m")

            let override = run(["rotate", "--interval", "10m", "--once", "--dry-run", "--json"],
                               in: dir)
            #expect(try jsonObject(override.out)["interval"] as? String == "10m")
        }
    }

    // MARK: - Upscaling

    @Test func upscaleDryRunWritesNothing() throws {
        try withTempDirectory { dir in
            let source = dir.appendingPathComponent("source.png")
            try makeTestPNG(at: source, width: 4, height: 4)
            let fake = try makeFakeUpscaler(in: dir)
            let output = dir.appendingPathComponent("upscaled")

            let result = run(["upscale", source.path, "--target", "8x8",
                              "--output", output.path, "--upscaler", fake.path,
                              "--dry-run", "--json"], in: dir)
            #expect(result.code == CLIExit.success.rawValue)
            let object = try jsonObject(result.out)
            #expect(object["dryRun"] as? Bool == true)
            #expect(object["generated"] as? Int == 1)
            #expect(object["target"] as? String == "8x8")
            #expect(object["format"] as? String == "heic")
            #expect(object["model"] as? String == "realesrgan-x4plus")
            let files = try #require(object["files"] as? [[String: Any]])
            #expect(files[0]["width"] as? Int == 8)
            #expect(files[0]["height"] as? Int == 8)
            #expect(!FileManager.default.fileExists(atPath: output.path))
        }
    }

    @Test func upscaleGeneratesSkipsAndForceRegenerates() throws {
        try withTempDirectory { dir in
            let source = dir.appendingPathComponent("source.png")
            try makeTestPNG(at: source, width: 4, height: 4)
            let fake = try makeFakeUpscaler(in: dir)
            let output = dir.appendingPathComponent("upscaled")

            let first = run(["upscale", source.path, "--target", "8x8",
                             "--output", output.path, "--upscaler", fake.path], in: dir)
            #expect(first.code == CLIExit.success.rawValue)
            #expect(first.out.contains("1 generated, 0 skipped, 0 failed"))
            let rendered = output.appendingPathComponent("source.heic")
            #expect(FileManager.default.fileExists(atPath: rendered.path))
            #expect(FileManager.default.fileExists(
                atPath: output.appendingPathComponent("manifest.json").path))
            let written = try UpscaleInspector.inspect(rendered)
            #expect(written.width == 8)
            #expect(written.height == 8)

            let second = run(["upscale", source.path, "--target", "8x8",
                              "--output", output.path, "--upscaler", fake.path], in: dir)
            #expect(second.code == CLIExit.success.rawValue)
            #expect(second.out.contains("0 generated, 1 skipped, 0 failed"))

            let forced = run(["upscale", source.path, "--target", "8x8",
                              "--output", output.path, "--upscaler", fake.path,
                              "--force"], in: dir)
            #expect(forced.code == CLIExit.success.rawValue)
            #expect(forced.out.contains("1 generated, 0 skipped, 0 failed"))
        }
    }

    @Test func upscaleAllScansTheConfiguredLibrary() throws {
        try withTempDirectory { dir in
            let library = dir.appendingPathComponent("walls").standardizedFileURL
            try makeLibrary(library, files: ["a.png", "b.png"])
            try makeTestPNG(at: library.appendingPathComponent("a.png"),
                            width: 4, height: 4)
            try makeTestPNG(at: library.appendingPathComponent("b.png"),
                            width: 4, height: 4)
            let paths = paths(in: dir)
            try saveConfig(paths, dirs: [library.path])
            let fake = try makeFakeUpscaler(in: dir)
            let output = dir.appendingPathComponent("upscaled")

            let result = run(["upscale", "--all", "--target", "8x8",
                              "--output", output.path, "--upscaler", fake.path,
                              "--json"], in: dir)
            #expect(result.code == CLIExit.success.rawValue)
            let object = try jsonObject(result.out)
            #expect(object["generated"] as? Int == 2)
            #expect(object["skipped"] as? Int == 0)
        }
    }

    @Test func upscaleDirAndMaxScaleAreRespected() throws {
        try withTempDirectory { dir in
            let library = dir.appendingPathComponent("walls").standardizedFileURL
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            try makeTestPNG(at: library.appendingPathComponent("small.png"),
                            width: 4, height: 4)
            let fake = try makeFakeUpscaler(in: dir)
            let output = dir.appendingPathComponent("upscaled")

            let result = run(["upscale", "--dir", library.path, "--target", "8x8",
                              "--max-scale", "1.5", "--output", output.path,
                              "--upscaler", fake.path, "--json"], in: dir)
            #expect(result.code == CLIExit.success.rawValue)
            let object = try jsonObject(result.out)
            #expect(object["generated"] as? Int == 0)
            #expect(object["skipped"] as? Int == 1)
            let files = try #require(object["files"] as? [[String: Any]])
            #expect((files[0]["reason"] as? String)?.contains("--max-scale") == true)
        }
    }

    @Test func upscaleSkipsTransparentSources() throws {
        try withTempDirectory { dir in
            let source = dir.appendingPathComponent("alpha.png")
            try makeTestPNG(at: source, width: 4, height: 4, opaque: false)
            let fake = try makeFakeUpscaler(in: dir)
            let output = dir.appendingPathComponent("upscaled")

            let result = run(["upscale", source.path, "--target", "8x8",
                              "--output", output.path, "--upscaler", fake.path,
                              "--json"], in: dir)
            #expect(result.code == CLIExit.success.rawValue)
            let object = try jsonObject(result.out)
            #expect(object["generated"] as? Int == 0)
            #expect(object["skipped"] as? Int == 1)
            let files = try #require(object["files"] as? [[String: Any]])
            #expect((files[0]["reason"] as? String)?.contains("transparent") == true)
        }
    }

    @Test func upscaleDisplayTargetAsksThePicker() throws {
        try withTempDirectory { dir in
            let source = dir.appendingPathComponent("source.png")
            try makeTestPNG(at: source, width: 4, height: 4)
            let picker = dir.appendingPathComponent("picker.sh")
            try makeDisplayPicker(at: picker, width: 10, height: 6)
            let fake = try makeFakeUpscaler(in: dir)
            let output = dir.appendingPathComponent("upscaled")

            let result = run(["upscale", source.path, "--output", output.path,
                              "--upscaler", fake.path, "--dry-run", "--json"], in: dir,
                             environment: ["WALLE_PICKER": picker.path])
            #expect(result.code == CLIExit.success.rawValue)
            let object = try jsonObject(result.out)
            #expect(object["target"] as? String == "10x6")
            let files = try #require(object["files"] as? [[String: Any]])
            #expect(files[0]["width"] as? Int == 12)
            #expect(files[0]["height"] as? Int == 12)
        }
    }

    @Test func upscaleRejectsBadOptionsAndDirectories() throws {
        try withTempDirectory { dir in
            let noInput = run(["upscale"], in: dir)
            #expect(noInput.code == CLIExit.failure.rawValue)
            #expect(noInput.err.contains("needs file paths"))

            let source = dir.appendingPathComponent("source.png")
            try makeTestPNG(at: source, width: 4, height: 4)
            let fake = try makeFakeUpscaler(in: dir)
            for arguments in [
                ["upscale", source.path, "--target", "nope"],
                ["upscale", source.path, "--mode", "nope"],
                ["upscale", source.path, "--quality", "2"],
                ["upscale", source.path, "--max-scale", "1"],
                ["upscale", source.path, "--scale", "5"],
            ] {
                let result = run(arguments, in: dir)
                #expect(result.code == CLIExit.failure.rawValue, "\(arguments) should fail")
            }

            let directory = run(["upscale", dir.path, "--target", "8x8",
                                 "--upscaler", fake.path], in: dir)
            #expect(directory.code == CLIExit.failure.rawValue)
            #expect(directory.err.contains("use --dir"))
        }
    }

    @Test func upscaleDisambiguatesCollidingOutputNames() throws {
        try withTempDirectory { dir in
            let first = dir.appendingPathComponent("one").standardizedFileURL
            let second = dir.appendingPathComponent("two").standardizedFileURL
            try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
            try makeTestPNG(at: first.appendingPathComponent("same.png"),
                            width: 4, height: 4)
            try makeTestPNG(at: second.appendingPathComponent("same.png"),
                            width: 4, height: 4)
            let fake = try makeFakeUpscaler(in: dir)
            let output = dir.appendingPathComponent("upscaled")

            let result = run(["upscale", "--dir", first.path, "--dir", second.path,
                              "--target", "8x8", "--output", output.path,
                              "--upscaler", fake.path, "--json"], in: dir)
            #expect(result.code == CLIExit.success.rawValue)
            let object = try jsonObject(result.out)
            #expect(object["generated"] as? Int == 2)
            let files = try #require(object["files"] as? [[String: Any]])
            let names = Set(files.compactMap { ($0["output"] as? String).map {
                URL(fileURLWithPath: $0).lastPathComponent
            } })
            #expect(names.count == 2)
            #expect(names.contains("same.heic"))
            #expect(names.contains { $0.hasPrefix("same-") && $0.hasSuffix(".heic") })
        }
    }

    @Test func upscaleRefusesASecondRun() throws {
        try withTempDirectory { dir in
            let source = dir.appendingPathComponent("source.png")
            try makeTestPNG(at: source, width: 4, height: 4)
            let fake = try makeFakeUpscaler(in: dir)
            let paths = paths(in: dir)
            let lock = try #require(SingleInstance.acquire(at: paths.upscaleLockFile))
            defer { SingleInstance.release(lock) }

            let result = run(["upscale", source.path, "--target", "8x8",
                              "--output", dir.appendingPathComponent("out").path,
                              "--upscaler", fake.path], in: dir)
            #expect(result.code == CLIExit.alreadyRunning.rawValue)
            #expect(result.err.contains("another upscale is already running"))
        }
    }


    @Test func upscaleOnFillsHiddenCacheAndOffUsesOriginals() throws {
        try withTempDirectory { dir in
            let library = dir.appendingPathComponent("walls").standardizedFileURL
            try makeLibrary(library, files: ["source.png"])
            try makeTestPNG(at: library.appendingPathComponent("source.png"),
                            width: 4, height: 4)
            let paths = paths(in: dir)
            try saveConfig(paths, dirs: [library.path])
            let fake = try makeFakeUpscaler(in: dir)

            let on = run(["upscale", "on", "--wait", "--target", "8x8",
                          "--upscaler", fake.path], in: dir)
            #expect(on.code == CLIExit.success.rawValue)
            #expect(run(["config", "get", "upscale"], in: dir).out == "true")
            let root = UpscaleCache.root(paths: paths, model: "realesrgan-x4plus",
                                         target: PixelSize(width: 8, height: 8))
            let first = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "heic" }
            #expect(first.count == 1)

            // A new image is picked up by the refresh path without changing config.
            try makeTestPNG(at: library.appendingPathComponent("new.png"),
                            width: 4, height: 4)
            let refresh = run(["upscale", "--refresh", "--target", "8x8",
                               "--upscaler", fake.path], in: dir)
            #expect(refresh.code == CLIExit.success.rawValue)
            let second = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "heic" }
            #expect(second.count == 2)

            let off = run(["upscale", "off"], in: dir)
            #expect(off.code == CLIExit.success.rawValue)
            #expect(run(["config", "get", "upscale"], in: dir).out == "false")
            #expect(FileManager.default.fileExists(atPath: root.path))
        }
    }

    @Test func upscaleOnStartsADetachedRefresh() throws {
        try withTempDirectory { dir in
            let library = dir.appendingPathComponent("walls").standardizedFileURL
            try makeLibrary(library, files: ["source.png"])
            try makeTestPNG(at: library.appendingPathComponent("source.png"),
                            width: 4, height: 4)
            let paths = paths(in: dir)
            try saveConfig(paths, dirs: [library.path])
            let fake = try makeFakeUpscaler(in: dir)
            let fakeCLI = dir.appendingPathComponent("fake-cli")
            let log = dir.appendingPathComponent("fake-cli.log")
            try Data("""
            #!/bin/sh
            printf '%s\\n' "$@" >> "\(log.path)"
            """.utf8).write(to: fakeCLI)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: fakeCLI.path)

            let result = run(["upscale", "on", "--target", "8x8",
                              "--upscaler", fake.path], in: dir,
                             environment: ["WALLE_CLI": fakeCLI.path])
            #expect(result.code == CLIExit.success.rawValue)
            #expect(result.out.contains("caching in the background"))
            #expect(run(["config", "get", "upscale"], in: dir).out == "true")

            // The child is detached; give it up to a few seconds under test load.
            let deadline = Date().addingTimeInterval(3)
            while !FileManager.default.fileExists(atPath: log.path), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            let arguments = try String(contentsOf: log, encoding: .utf8)
            #expect(arguments.contains("upscale"))
            #expect(arguments.contains("--refresh"))
            #expect(arguments.contains("--target"))
            #expect(arguments.contains("8x8"))
        }
    }

    @Test func dirAddStartsBackgroundRefreshWhenUpscaleIsOn() throws {
        try withTempDirectory { dir in
            let paths = paths(in: dir)
            var config = Config()
            config.wallpaperDirs = [dir.appendingPathComponent("old").path]
            config.upscale = true
            try config.save(to: paths.configFile)
            let fakeCLI = dir.appendingPathComponent("fake-cli")
            let log = dir.appendingPathComponent("fake-cli.log")
            try Data("""
            #!/bin/sh
            printf '%s\\n' "$@" >> "\(log.path)"
            """.utf8).write(to: fakeCLI)
            try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                  ofItemAtPath: fakeCLI.path)

            let result = run(["dir", "add", dir.appendingPathComponent("new").path],
                             in: dir, environment: ["WALLE_CLI": fakeCLI.path])
            #expect(result.code == CLIExit.success.rawValue)
            #expect(result.err.contains("background"))
            let deadline = Date().addingTimeInterval(3)
            while !FileManager.default.fileExists(atPath: log.path), Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            let arguments = try String(contentsOf: log, encoding: .utf8)
            #expect(arguments.contains("upscale"))
            #expect(arguments.contains("--refresh"))
        }
    }

    @Test func upscaleOnDryRunChangesNothing() throws {
        try withTempDirectory { dir in
            let library = dir.appendingPathComponent("walls").standardizedFileURL
            try makeLibrary(library, files: ["source.png"])
            try makeTestPNG(at: library.appendingPathComponent("source.png"),
                            width: 4, height: 4)
            let paths = paths(in: dir)
            try saveConfig(paths, dirs: [library.path])
            let fake = try makeFakeUpscaler(in: dir)

            let result = run(["upscale", "on", "--target", "8x8",
                              "--upscaler", fake.path, "--dry-run", "--json"],
                             in: dir)
            #expect(result.code == CLIExit.success.rawValue)
            #expect(run(["config", "get", "upscale"], in: dir).out == "false")
            #expect(!FileManager.default.fileExists(
                atPath: paths.dataDir.appendingPathComponent("upscaled").path))
        }
    }

    // MARK: - History

    @Test func historyRoundTripAndClear() throws {
        try withTempDirectory { dir in
            let paths = paths(in: dir)
            try HistoryStore(fileURL: paths.historyFile).append(
                HistoryEntry(path: "/tmp/one.png",
                             appliedAt: Date(timeIntervalSince1970: 1),
                             mode: "cli"))

            let listed = run(["history", "--limit", "1", "--json"], in: dir)
            #expect(listed.code == CLIExit.success.rawValue)
            let entries = try #require(try json(listed.out) as? [[String: Any]])
            #expect(entries.count == 1)
            #expect(entries[0]["path"] as? String == "/tmp/one.png")

            #expect(run(["history", "--clear"], in: dir).out == "history cleared")
            let empty = run(["history"], in: dir)
            #expect(empty.code == CLIExit.success.rawValue)
            #expect(empty.out.isEmpty)
            #expect(empty.err.contains("no history yet"))
        }
    }

    // MARK: - Option parser

    @Test func optionParserHandlesEqualsBooleansAndTerminator() throws {
        let spec = OptionSpec(valueOptions: ["limit"],
                              boolOptions: ["json"],
                              shortAliases: ["j": "json", "L": "limit"])
        let parsed = try OptionParser.parse(["--limit=5", "-j", "--", "-x"], spec: spec)
        #expect(parsed.value("limit") == "5")
        #expect(parsed.has("json"))
        #expect(parsed.positionals == ["-x"])
    }

    // MARK: - Doctor

    @Test func doctorChecksTheCacheAtThePickersSize() throws {
        try withTempDirectory { dir in
            let paths = paths(in: dir)
            let library = dir.appendingPathComponent("walls")
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            let file = library.appendingPathComponent("wall.png")
            try tinyPNG.write(to: file)
            let config = try saveConfig(paths, dirs: [library.path], spaces: .all)

            let picker = dir.appendingPathComponent("picker.sh")
            try makeFakePicker(at: picker, pixels: 512)
            let store = dir.appendingPathComponent("Index.plist")
            try makeStore(at: store)

            // Use the scanner's own Wallpaper: its canonical path and mtime are what doctor
            // will hash, and /var is a symlink to /private/var on macOS.
            let scanned = LibraryScanner(config: config, home: dir).scan()
            let wallpaper = try #require(scanned.wallpapers.first)
            try ThumbnailCache(directory: paths.thumbnailsDir, maxPx: 512)
                .thumbnail(for: wallpaper)

            let result = run(["doctor", "--json"], in: dir,
                             environment: ["WALLE_PICKER": picker.path,
                                           "WALLE_WALLPAPER_STORE": store.path])
            let object = try jsonObject(result.out)
            let checks = try #require(object["checks"] as? [[String: Any]])

            let cache = try #require(checks.first { $0["name"] as? String == "thumbnail cache" })
            #expect(cache["ok"] as? Bool == true)
            #expect((cache["detail"] as? String)?.contains("1/1 at 512 px") == true)

            let spaces = try #require(checks.first { $0["name"] as? String == "spaces" })
            #expect((spaces["detail"] as? String)?.contains("on") == true)

            let storeCheck = try #require(checks.first { $0["name"] as? String == "wallpaper store" })
            #expect(storeCheck["ok"] as? Bool == true)
            #expect((storeCheck["detail"] as? String)?.contains("test override") == true)
        }
    }

    @Test func doctorFailsWhenNothingIsCachedAtThePickersSize() throws {
        try withTempDirectory { dir in
            let paths = paths(in: dir)
            let library = dir.appendingPathComponent("walls")
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            let file = library.appendingPathComponent("wall.png")
            try tinyPNG.write(to: file)
            try saveConfig(paths, dirs: [library.path])

            let picker = dir.appendingPathComponent("picker.sh")
            try makeFakePicker(at: picker, pixels: 512)
            let store = dir.appendingPathComponent("Index.plist")
            try makeStore(at: store)

            let result = run(["doctor", "--json"], in: dir,
                             environment: ["WALLE_PICKER": picker.path,
                                           "WALLE_WALLPAPER_STORE": store.path])
            let object = try jsonObject(result.out)
            let checks = try #require(object["checks"] as? [[String: Any]])
            let cache = try #require(checks.first { $0["name"] as? String == "thumbnail cache" })
            #expect(cache["ok"] as? Bool == false)
            #expect((cache["detail"] as? String)?
                .contains("none of 1 thumbnails cached at 512 px") == true)
        }
    }

    @Test func spacesAllDryRunReportsWithoutWriting() throws {
        try withTempDirectory { dir in
            let store = dir.appendingPathComponent("Index.plist")
            try makeStore(at: store)
            let before = try Data(contentsOf: store)

            let result = run(["spaces", "all", "--dry-run", "--json"], in: dir,
                             environment: ["WALLE_WALLPAPER_STORE": store.path])
            #expect(result.code == CLIExit.success.rawValue)
            let object = try jsonObject(result.out)
            #expect(object["dryRun"] as? Bool == true)
            #expect(object["backup"] as? String == "")
            #expect(try Data(contentsOf: store) == before)

            let backup = store.deletingLastPathComponent()
                .appendingPathComponent("Index.plist.walle-backup")
            #expect(!FileManager.default.fileExists(atPath: backup.path))
        }
    }

    @Test func spacesOnDryRunLeavesTheConfigAlone() throws {
        try withTempDirectory { dir in
            let paths = paths(in: dir)
            try saveConfig(paths, dirs: [], spaces: .current)
            let store = dir.appendingPathComponent("Index.plist")
            try makeStore(at: store)

            let result = run(["spaces", "on", "--dry-run"], in: dir,
                             environment: ["WALLE_WALLPAPER_STORE": store.path])
            #expect(result.code == CLIExit.success.rawValue)
            #expect(result.out.contains("would"))
            #expect(run(["config", "get", "spaces"], in: dir).out == "current")
        }
    }

    @Test func spacesDryRunNeedsAnAction() {
        withTempDirectory { dir in
            let result = run(["spaces", "--dry-run"], in: dir)
            #expect(result.code == CLIExit.failure.rawValue)
            #expect(result.err.contains("--dry-run needs an action"))
        }
    }
}
