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
}
