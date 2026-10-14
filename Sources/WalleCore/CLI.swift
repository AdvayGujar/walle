import Foundation

/// Exit codes are part of the command line contract.
public enum CLIExit: Int32 {
    case success = 0
    case failure = 1
    case dismissed = 2
    case alreadyRunning = 3
}

/// Injected so the CLI can be exercised in-process by tests.
public struct CLIOutput: Sendable {
    public var out: @Sendable (String) -> Void
    public var err: @Sendable (String) -> Void

    public init(out: @escaping @Sendable (String) -> Void, err: @escaping @Sendable (String) -> Void) {
        self.out = out
        self.err = err
    }

    public static var standard: CLIOutput {
        CLIOutput(
            out: { print($0) },
            err: { message in
                FileHandle.standardError.write(Data((message + "\n").utf8))
            })
    }
}

public struct CLIEnvironment: Sendable {
    public var paths: WallePaths
    public var output: CLIOutput
    public var environment: [String: String]

    public init(paths: WallePaths, output: CLIOutput,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.paths = paths
        self.output = output
        self.environment = environment
    }
}

public struct CLIError: Error, CustomStringConvertible {
    public var message: String
    public var showUsage: Bool

    public init(_ message: String, showUsage: Bool = false) {
        self.message = message
        self.showUsage = showUsage
    }

    public var description: String { message }
}

/// A small, explicit option parser. Options are only accepted when the command
/// declares them, so a typo fails loudly instead of being silently ignored.
public struct OptionSpec: Sendable {
    public var valueOptions: Set<String>
    public var boolOptions: Set<String>
    public var shortAliases: [String: String]

    public init(valueOptions: [String] = [], boolOptions: [String] = [],
                shortAliases: [String: String] = [:]) {
        self.valueOptions = Set(valueOptions)
        self.boolOptions = Set(boolOptions)
        self.shortAliases = shortAliases
    }
}

public struct ParsedOptions: Sendable {
    public var positionals: [String] = []
    public var values: [String: [String]] = [:]
    public var bools: Set<String> = []

    public func has(_ name: String) -> Bool { bools.contains(name) }
    public func all(_ name: String) -> [String] { values[name] ?? [] }
    public func value(_ name: String) -> String? { values[name]?.last }

    public func int(_ name: String) throws -> Int? {
        guard let raw = value(name) else { return nil }
        guard let parsed = Int(raw) else {
            throw CLIError("option --\(name) expects an integer, got '\(raw)'")
        }
        return parsed
    }
}

public enum OptionParser {
    public static func parse(_ tokens: [String], spec: OptionSpec) throws -> ParsedOptions {
        var result = ParsedOptions()
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                result.positionals.append(contentsOf: tokens[(index + 1)...])
                break
            }
            if token.hasPrefix("--") {
                let body = String(token.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    let name = String(body[..<eq])
                    let raw = String(body[body.index(after: eq)...])
                    guard spec.valueOptions.contains(name) else {
                        throw CLIError("unknown option --\(name)", showUsage: true)
                    }
                    result.values[name, default: []].append(raw)
                } else if spec.boolOptions.contains(body) || body == "help" {
                    // help is accepted everywhere so --help never needs declaring per command.
                    result.bools.insert(body)
                } else if spec.valueOptions.contains(body) {
                    guard index + 1 < tokens.count else {
                        throw CLIError("option --\(body) needs a value")
                    }
                    result.values[body, default: []].append(tokens[index + 1])
                    index += 1
                } else {
                    throw CLIError("unknown option --\(body)", showUsage: true)
                }
            } else if token.hasPrefix("-"), token.count > 1 {
                let short = String(token.dropFirst())
                guard let long = spec.shortAliases[short] else {
                    throw CLIError("unknown option -\(short)", showUsage: true)
                }
                if spec.boolOptions.contains(long) {
                    result.bools.insert(long)
                } else {
                    guard index + 1 < tokens.count else {
                        throw CLIError("option -\(short) needs a value")
                    }
                    result.values[long, default: []].append(tokens[index + 1])
                    index += 1
                }
            } else {
                result.positionals.append(token)
            }
            index += 1
        }
        return result
    }
}

public struct CLI {
    public static let version = "0.1.0"

    public static func run(_ arguments: [String], environment: CLIEnvironment) -> Int32 {
        do {
            return try dispatch(arguments, environment: environment)
        } catch let error as CLIError {
            environment.output.err("walle: \(error.message)")
            if error.showUsage {
                environment.output.err("run 'walle help' for usage")
            }
            return CLIExit.failure.rawValue
        } catch {
            environment.output.err("walle: \(error)")
            return CLIExit.failure.rawValue
        }
    }

    static func dispatch(_ arguments: [String], environment: CLIEnvironment) throws -> Int32 {
        // Bare "walle" opens the picker. Everything else is walle <verb>.
        var tokens = arguments
        if tokens.isEmpty { tokens = ["pick"] }

        // A leading global option is only --help / --version; everything else is a command.
        if let first = tokens.first, first == "--help" || first == "-h" { tokens = ["help"] }
        if let first = tokens.first, first == "--version" { tokens = ["version"] }

        let command = tokens[0]
        let rest = Array(tokens.dropFirst())

        switch command {
        case "help": return help(environment)
        case "version": environment.output.out("walle \(version)"); return CLIExit.success.rawValue
        case "list": return try list(rest, environment: environment)
        // Convenience verbs so common actions read as walle <verb> rather than needing a
        // second word: walle next, walle add ~/Pictures/Walls, and so on.
        case "next": return try set(["--next"] + rest, environment: environment)
        case "prev", "previous": return try set(["--prev"] + rest, environment: environment)
        case "random": return try set(["--random"] + rest, environment: environment)
        case "add": return try dir(["add"] + rest, environment: environment)
        case "remove", "rm": return try dir(["remove"] + rest, environment: environment)
        case "use": return try dir(["use"] + rest, environment: environment)
        case "dirs": return try dir(["list"] + rest, environment: environment)
        case "dir": return try dir(rest, environment: environment)
        case "config": return try config(rest, environment: environment)
        case "set": return try set(rest, environment: environment)
        case "current": return try current(rest, environment: environment)
        case "history": return try history(rest, environment: environment)
        case "cache": return try cache(rest, environment: environment)
        case "pick":
            let pickOptions = try OptionParser.parse(
                rest, spec: OptionSpec(boolOptions: ["json"],
                                       shortAliases: ["j": "json", "h": "help"]))
            if pickOptions.has("help") { return help(environment) }
            return try runPicker([], environment)
        case "doctor": return try doctor(rest, environment: environment)
        default:
            throw CLIError("unknown command '\(command)'", showUsage: true)
        }
    }

    // MARK: - config helpers

    static func loadConfig(_ environment: CLIEnvironment) -> (config: Config, warnings: [String]) {
        let (raw, parseWarnings) = Config.load(from: environment.paths.configFile)
        let (config, sanitizeWarnings) = raw.sanitized()
        return (config, parseWarnings + sanitizeWarnings)
    }

    static func reportWarnings(_ warnings: [String], _ environment: CLIEnvironment, config: Config) {
        guard config.logLevel != "silent", config.logLevel != "error" else { return }
        for warning in warnings {
            environment.output.err("walle: warning: \(warning)")
        }
    }

    static func emitJSON(_ object: Any, to environment: CLIEnvironment) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        environment.output.out(String(decoding: data, as: UTF8.self))
    }

    // MARK: - help

    static func help(_ environment: CLIEnvironment) -> Int32 {
        environment.output.out("""
        walle \(version) - a lightweight wallpaper switcher for macOS

        USAGE
          walle <command> [options]

        COMMANDS
          pick                       Open the picker (this is what a bare "walle" runs)
          next, prev, random         Apply the next, previous or a random wallpaper
          add <path>                 Add a wallpaper directory      (short for dir add)
          remove <path>              Remove a wallpaper directory   (short for dir remove)
          use <path>                 Replace the directory list     (short for dir use)
          dirs                       Show wallpaper directories     (short for dir list)
          list                       List wallpapers in the configured directories
          set <path>                 Apply a wallpaper
          set --random|--next|--prev|--last
                                     Apply a wallpaper chosen from the library
          current                    Print the current desktop wallpaper
          history                    Show recently applied wallpapers
          cache                      Build the thumbnail cache
          dir list                   Show wallpaper directories and their image counts
          dir add <path>             Add a wallpaper directory
          dir remove <path>          Remove a wallpaper directory
          dir use <path>             Replace the directory list with one path
          config path                Print the config file location
          config list                Print every setting
          config get <key>           Print one setting
          config set <key> <value>   Change one setting
          config unset <key>         Restore one setting to its default
          config edit                Open the config file in $EDITOR
          help                       Show this help
          version                    Show the version

        OPTIONS
          --json            Machine readable output where supported
          --limit <n>       list: stop after n wallpapers
          --sort <mode>     list: name | mtime | random
          --dir <path>      list: scan this path instead of the configured ones
          -h, --help        Show this help

        EXIT CODES
          0 success   1 error   2 dismissed   3 already running

        CONFIG
          \(environment.paths.configFile.path)
        """)
        return CLIExit.success.rawValue
    }

    // MARK: - list

    static func list(_ tokens: [String], environment: CLIEnvironment) throws -> Int32 {
        let spec = OptionSpec(valueOptions: ["limit", "sort", "dir"], boolOptions: ["json"],
                              shortAliases: ["j": "json", "h": "help"])
        let options = try OptionParser.parse(tokens, spec: spec)
        if options.has("help") { return help(environment) }
        guard options.positionals.isEmpty else {
            throw CLIError("list takes no positional arguments, got '\(options.positionals[0])'")
        }

        let (config, warnings) = loadConfig(environment)
        reportWarnings(warnings, environment, config: config)

        var scanConfig = config
        if let sortRaw = options.value("sort") {
            guard let mode = SortMode.parse(sortRaw) else {
                throw CLIError("--sort expects name, mtime or random, got '\(sortRaw)'")
            }
            scanConfig.sort = mode
        }
        let extraDirs = options.all("dir")

        // A fresh seed per invocation so --sort random actually varies between runs,
        // while library callers keep the deterministic seed 0.
        let seed: UInt64 = scanConfig.sort == .random
            ? UInt64(Date().timeIntervalSince1970 * 1000)
            : 0
        let scanner = LibraryScanner(config: scanConfig, home: environment.paths.home)
        let result = scanner.scan(extraDirs: extraDirs, seed: seed)
        for warning in result.warnings {
            environment.output.err("walle: warning: \(warning)")
        }

        var wallpapers = result.wallpapers
        if let limit = try options.int("limit") {
            guard limit >= 0 else { throw CLIError("--limit must be >= 0") }
            wallpapers = Array(wallpapers.prefix(limit))
        }

        if options.has("json") {
            try emitJSON([
                "count": wallpapers.count,
                "roots": scanConfig.wallpaperDirs.isEmpty ? extraDirs : scanConfig.wallpaperDirs,
                "rootCounts": result.rootCounts,
                "warnings": result.warnings,
                "wallpapers": wallpapers.map { wallpaper in
                    var object: [String: Any] = [
                        "path": wallpaper.path,
                        "name": wallpaper.name,
                        "fileSize": wallpaper.fileSize,
                        "modifiedAt": wallpaper.modifiedAt.formatted(.iso8601),
                    ]
                    if let aspect = wallpaper.aspectRatio { object["aspectRatio"] = aspect }
                    return object
                },
            ], to: environment)
        } else {
            for wallpaper in wallpapers {
                environment.output.out(wallpaper.path)
            }
            if wallpapers.isEmpty {
                let roots = scanConfig.wallpaperDirs + extraDirs
                environment.output.err(
                    roots.isEmpty
                        ? "walle: no wallpaper directories configured; run 'walle dir add <path>'"
                        : "walle: no wallpapers found in \(roots.joined(separator: ", "))")
            }
        }
        return CLIExit.success.rawValue
    }

    // MARK: - dir

    static func dir(_ tokens: [String], environment: CLIEnvironment) throws -> Int32 {
        guard let sub = tokens.first else {
            throw CLIError("dir needs a subcommand: list, add, remove or use", showUsage: true)
        }
        let rest = Array(tokens.dropFirst())
        switch sub {
        case "list": return try dirList(rest, environment: environment)
        case "add": return try dirAdd(rest, environment: environment)
        case "remove": return try dirRemove(rest, environment: environment)
        case "use": return try dirUse(rest, environment: environment)
        default: throw CLIError("unknown dir subcommand '\(sub)'", showUsage: true)
        }
    }

    static func dirList(_ tokens: [String], environment: CLIEnvironment) throws -> Int32 {
        let options = try OptionParser.parse(
            tokens, spec: OptionSpec(boolOptions: ["json"],
                                     shortAliases: ["j": "json", "h": "help"]))
        if options.has("help") { return help(environment) }

        let (config, warnings) = loadConfig(environment)
        reportWarnings(warnings, environment, config: config)

        let scanner = LibraryScanner(config: config, home: environment.paths.home)
        let result = scanner.scan()
        for warning in result.warnings {
            environment.output.err("walle: warning: \(warning)")
        }

        if options.has("json") {
            try emitJSON([
                "roots": config.wallpaperDirs.map { raw -> [String: Any] in
                    let resolved = walleExpand(raw, home: environment.paths.home).path
                    return [
                        "root": raw,
                        "path": resolved,
                        "imageCount": result.rootCounts[raw] ?? result.rootCounts[resolved] ?? 0,
                        "exists": FileManager.default.fileExists(atPath: resolved),
                    ]
                },
                "total": result.wallpapers.count,
            ], to: environment)
        } else if config.wallpaperDirs.isEmpty {
            environment.output.err(
                "walle: no wallpaper directories configured; run 'walle dir add <path>'")
        } else {
            for raw in config.wallpaperDirs {
                let resolved = walleExpand(raw, home: environment.paths.home)
                let count = result.rootCounts[raw] ?? result.rootCounts[resolved.path] ?? 0
                let exists = FileManager.default.fileExists(atPath: resolved.path)
                environment.output.out(
                    "\(resolved.path)  [\(count) image\(count == 1 ? "" : "s")"
                    + (exists ? "]" : ", missing]"))
            }
            environment.output.out("\(result.wallpapers.count) wallpaper"
                                   + (result.wallpapers.count == 1 ? "" : "s") + " total")
        }
        return CLIExit.success.rawValue
    }

    /// Keeps the tilde form for paths the user wrote that way, otherwise stores absolute.
    static func normalizeRoot(_ input: String, home: URL) -> String? {
        var trimmed = input.trimmingCharacters(in: .whitespaces)
        while trimmed.count > 1 && trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty else { return nil }
        if trimmed == "~" || trimmed.hasPrefix("~/") { return trimmed }
        return URL(fileURLWithPath: trimmed).standardizedFileURL.path
    }

    static func resolvedRoot(_ input: String, home: URL) -> String {
        walleExpand(input, home: home).standardizedFileURL.path
    }

    static func dirAdd(_ tokens: [String], environment: CLIEnvironment) throws -> Int32 {
        let options = try OptionParser.parse(
            tokens, spec: OptionSpec(boolOptions: ["json", "no-create"],
                                     shortAliases: ["j": "json", "h": "help"]))
        if options.has("help") { return help(environment) }
        guard let rawInput = options.positionals.first else {
            throw CLIError("dir add needs a path")
        }
        guard options.positionals.count == 1 else {
            throw CLIError("dir add takes exactly one path")
        }
        guard let root = normalizeRoot(rawInput, home: environment.paths.home) else {
            throw CLIError("dir add got an empty path")
        }

        var (config, warnings) = loadConfig(environment)
        reportWarnings(warnings, environment, config: config)

        let resolved = resolvedRoot(root, home: environment.paths.home)
        let existing = config.wallpaperDirs.map { resolvedRoot($0, home: environment.paths.home) }
        if existing.contains(resolved) {
            environment.output.err("walle: \(resolved) is already configured")
            return CLIExit.success.rawValue
        }

        let fileManager = FileManager.default
        var created = false
        // Creating the directory matches the documented behaviour; --no-create opts out
        // so a typo can be caught instead of silently producing an empty folder.
        if !fileManager.fileExists(atPath: resolved) {
            if options.has("no-create") {
                throw CLIError("directory does not exist: \(resolved)")
            }
            try fileManager.createDirectory(atPath: resolved, withIntermediateDirectories: true)
            created = true
        }

        config.wallpaperDirs.append(root)
        try config.save(to: environment.paths.configFile)

        if options.has("json") {
            try emitJSON(["added": root, "path": resolved, "created": created,
                          "roots": config.wallpaperDirs], to: environment)
        } else {
            environment.output.out("added \(root)")
            if created { environment.output.err("walle: created \(resolved)") }
        }
        return CLIExit.success.rawValue
    }

    static func dirRemove(_ tokens: [String], environment: CLIEnvironment) throws -> Int32 {
        let options = try OptionParser.parse(
            tokens, spec: OptionSpec(boolOptions: ["json"],
                                     shortAliases: ["j": "json", "h": "help"]))
        if options.has("help") { return help(environment) }
        guard let rawInput = options.positionals.first else {
            throw CLIError("dir remove needs a path")
        }
        let target = resolvedRoot(rawInput, home: environment.paths.home)

        var (config, _) = loadConfig(environment)
        let before = config.wallpaperDirs.count
        config.wallpaperDirs.removeAll { resolvedRoot($0, home: environment.paths.home) == target }
        guard config.wallpaperDirs.count < before else {
            throw CLIError("not a configured directory: \(target)")
        }
        try config.save(to: environment.paths.configFile)

        if options.has("json") {
            try emitJSON(["removed": target, "roots": config.wallpaperDirs], to: environment)
        } else {
            environment.output.out("removed \(target)")
        }
        return CLIExit.success.rawValue
    }

    static func dirUse(_ tokens: [String], environment: CLIEnvironment) throws -> Int32 {
        let options = try OptionParser.parse(
            tokens, spec: OptionSpec(boolOptions: ["json"],
                                     shortAliases: ["j": "json", "h": "help"]))
        if options.has("help") { return help(environment) }
        guard let rawInput = options.positionals.first else {
            throw CLIError("dir use needs a path")
        }
        guard let root = normalizeRoot(rawInput, home: environment.paths.home) else {
            throw CLIError("dir use got an empty path")
        }
        var (config, _) = loadConfig(environment)
        config.wallpaperDirs = [root]
        try config.save(to: environment.paths.configFile)

        if options.has("json") {
            try emitJSON(["roots": config.wallpaperDirs], to: environment)
        } else {
            environment.output.out("using \(root)")
        }
        return CLIExit.success.rawValue
    }

    // MARK: - set / current, delegated to walle-picker

    /// walle does not link AppKit. Anything that needs NSWorkspace is handed to the
    /// picker binary, which costs one exec instead of loading AppKit twice.
    static func locatePicker(_ environment: CLIEnvironment) throws -> URL {
        guard let url = PickerLocator.locate(environment: environment.environment) else {
            throw CLIError("could not find the walle-picker binary; "
                           + "set WALLE_PICKER or run walle install")
        }
        return url
    }

    static func runPicker(_ arguments: [String], _ environment: CLIEnvironment) throws -> Int32 {
        let process = Process()
        process.executableURL = try locatePicker(environment)
        process.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()
        // Read to EOF before waiting so a chatty child cannot fill a pipe and deadlock.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        if let text = String(data: outData, encoding: .utf8) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                environment.output.out(String(line))
            }
        }
        if let text = String(data: errData, encoding: .utf8) {
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                environment.output.err(String(line))
            }
        }
        return process.terminationStatus
    }

    static func selectionMode(_ options: ParsedOptions) throws -> SelectionMode {
        var modes: [SelectionMode] = []
        if let path = options.positionals.first { modes.append(.explicit(path)) }
        if options.has("random") { modes.append(.random) }
        if options.has("next") { modes.append(.next) }
        if options.has("prev") { modes.append(.previous) }
        if options.has("last") { modes.append(.last) }
        guard modes.count == 1 else {
            throw CLIError(modes.isEmpty
                ? "set needs a path or one of --random, --next, --prev, --last"
                : "set accepts only one of a path, --random, --next, --prev, --last")
        }
        return modes[0]
    }

    static func set(_ tokens: [String], environment: CLIEnvironment) throws -> Int32 {
        let options = try OptionParser.parse(
            tokens,
            spec: OptionSpec(boolOptions: ["random", "next", "prev", "last", "dry-run", "json"],
                             shortAliases: ["j": "json", "h": "help"]))
        if options.has("help") { return help(environment) }

        let (config, warnings) = loadConfig(environment)
        reportWarnings(warnings, environment, config: config)
        let mode = try selectionMode(options)

        let library = LibraryScanner(config: config, home: environment.paths.home).scan().wallpapers
        let history = (try? HistoryStore(fileURL: environment.paths.historyFile).entries()) ?? []
        let state = StateStore(fileURL: environment.paths.stateFile).load()

        let chosen: Wallpaper
        do {
            chosen = try Selection.resolve(
                mode,
                library: library,
                history: history,
                currentPath: state.lastAppliedPath,
                seed: UInt64(Date().timeIntervalSince1970 * 1000))
        } catch let error as SelectionError {
            throw CLIError(error.description)
        }

        if options.has("dry-run") {
            if options.has("json") {
                try emitJSON(["wouldApply": chosen.path, "dryRun": true], to: environment)
            } else {
                environment.output.out(chosen.path)
            }
            return CLIExit.success.rawValue
        }

        var pickerArguments = ["--apply", chosen.path]
        if options.has("json") { pickerArguments.append("--json") }
        return try runPicker(pickerArguments, environment)
    }

    static func current(_ tokens: [String], environment: CLIEnvironment) throws -> Int32 {
        let options = try OptionParser.parse(
            tokens, spec: OptionSpec(boolOptions: ["json"],
                                     shortAliases: ["j": "json", "h": "help"]))
        if options.has("help") { return help(environment) }
        var pickerArguments = ["--current"]
        if options.has("json") { pickerArguments.append("--json") }
        return try runPicker(pickerArguments, environment)
    }

    // MARK: - doctor

    /// Checks the whole chain: config, library, picker binary, thumbnail cache, history and
    /// the hotkey. Everything it reports is something that has actually gone wrong for
    /// someone at least once.
    static func doctor(_ tokens: [String], environment: CLIEnvironment) throws -> Int32 {
        let options = try OptionParser.parse(
            tokens, spec: OptionSpec(boolOptions: ["json"],
                                     shortAliases: ["j": "json", "h": "help"]))
        if options.has("help") { return help(environment) }

        let fm = FileManager.default
        var checks: [(name: String, ok: Bool, detail: String)] = []

        // Config
        let configPath = environment.paths.configFile.path
        let configExists = fm.fileExists(atPath: configPath)
        let (config, configWarnings) = loadConfig(environment)
        checks.append(("config file", true,
                       configExists ? configPath : configPath + " (absent, defaults in use)"))
        for warning in configWarnings { checks.append(("config warning", false, warning)) }

        // Library
        checks.append(("wallpaper dirs", !config.wallpaperDirs.isEmpty,
                       config.wallpaperDirs.joined(separator: ", ")))
        let scan = LibraryScanner(config: config, home: environment.paths.home).scan()
        checks.append(("wallpapers", !scan.wallpapers.isEmpty,
                       String(scan.wallpapers.count) + " image"
                       + (scan.wallpapers.count == 1 ? "" : "s")))
        for warning in scan.warnings { checks.append(("library warning", false, warning)) }

        // The binary everything with a window is delegated to.
        if let picker = PickerLocator.locate(environment: environment.environment) {
            checks.append(("walle-picker", true, picker.path))
        } else {
            checks.append(("walle-picker", false,
                           "not found; set WALLE_PICKER or run ./scripts/install.sh"))
        }

        // Thumbnail cache
        let cache = ThumbnailCache(directory: environment.paths.thumbnailsDir,
                                   rowMaxPx: config.thumbMaxPx,
                                   previewMaxPx: config.previewMaxPx)
        let cacheBytes = cache.cacheSizeBytes()
        checks.append(("thumbnail cache", cacheBytes > 0,
                       String(cacheBytes) + " bytes in " + environment.paths.thumbnailsDir.path
                       + (cacheBytes > 0 ? "" : " (run walle cache)")))

        // History and state
        let historyURL = environment.paths.historyFile
        let entries = (try? HistoryStore(fileURL: historyURL).entries(limit: 1)) ?? []
        checks.append(("history", true,
                       entries.isEmpty ? "empty (" + historyURL.path + ")"
                                       : "latest " + entries[0].path))

        // Hotkey daemon
        let skhdCandidates = ["/opt/homebrew/bin/skhd", "/usr/local/bin/skhd"]
        if let skhd = skhdCandidates.first(where: { fm.isExecutableFile(atPath: $0) }) {
            checks.append(("skhd installed", true, skhd))
        } else {
            checks.append(("skhd installed", false,
                           "not found; brew install koekeishiya/formulae/skhd"))
        }

        let rcPath = environment.paths.home.appendingPathComponent(".config/skhd/skhdrc").path
        if let data = fm.contents(atPath: rcPath),
           let text = String(data: data, encoding: .utf8) {
            let bound = text.split(separator: "\n").contains { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.hasPrefix("#") && trimmed.contains("walle")
            }
            checks.append(("skhd binding", bound,
                           bound ? "found in " + rcPath : "no line mentioning walle in " + rcPath))
        } else {
            checks.append(("skhd binding", false, "no " + rcPath))
        }

        // Accessibility cannot be checked from here: it is granted to skhd, not to us.
        checks.append(("skhd accessibility", true,
                       "cannot be checked from here; grant it in System Settings > "
                       + "Privacy & Security > Accessibility if the hotkey does nothing"))

        let failures = checks.filter { !$0.ok }.count
        if options.has("json") {
            try emitJSON([
                "ok": failures == 0,
                "failures": failures,
                "checks": checks.map { ["name": $0.name, "ok": $0.ok, "detail": $0.detail] },
            ], to: environment)
        } else {
            for check in checks {
                environment.output.out((check.ok ? "  ok  " : " fail ") + check.name
                                       + "  " + check.detail)
            }
            environment.output.out(failures == 0
                ? "all checks passed"
                : String(failures) + " check" + (failures == 1 ? "" : "s") + " failed")
        }
        return failures == 0 ? CLIExit.success.rawValue : CLIExit.failure.rawValue
    }

    // MARK: - history

    static func history(_ tokens: [String], environment: CLIEnvironment) throws -> Int32 {
        let options = try OptionParser.parse(
            tokens, spec: OptionSpec(valueOptions: ["limit"], boolOptions: ["json", "clear"],
                                     shortAliases: ["j": "json", "h": "help"]))
        if options.has("help") { return help(environment) }

        let store = HistoryStore(fileURL: environment.paths.historyFile)
        if options.has("clear") {
            try store.clear()
            environment.output.out("history cleared")
            return CLIExit.success.rawValue
        }

        let entries = try store.entries(limit: try options.int("limit"))
        if options.has("json") {
            try emitJSON(entries.map { entry -> [String: Any] in
                var object: [String: Any] = [
                    "path": entry.path,
                    "appliedAt": entry.appliedAt.formatted(.iso8601),
                    "mode": entry.mode,
                ]
                if let uuid = entry.screenUUID { object["screenUUID"] = uuid }
                return object
            }, to: environment)
        } else {
            for entry in entries {
                environment.output.out(entry.appliedAt.formatted(.iso8601)
                                       + "  " + entry.mode + "  " + entry.path)
            }
            if entries.isEmpty { environment.output.err("walle: no history yet") }
        }
        return CLIExit.success.rawValue
    }

    // MARK: - cache

    static func cache(_ tokens: [String], environment: CLIEnvironment) throws -> Int32 {
        let options = try OptionParser.parse(
            tokens, spec: OptionSpec(boolOptions: ["rebuild", "prune", "json"],
                                     shortAliases: ["j": "json", "h": "help"]))
        if options.has("help") { return help(environment) }

        let (config, warnings) = loadConfig(environment)
        reportWarnings(warnings, environment, config: config)

        let scan = LibraryScanner(config: config, home: environment.paths.home).scan()
        for warning in scan.warnings { environment.output.err("walle: warning: " + warning) }

        let cacheDir = environment.paths.thumbnailsDir
        if options.has("rebuild") {
            try? FileManager.default.removeItem(at: cacheDir)
        }
        let cache = ThumbnailCache(directory: cacheDir,
                                   rowMaxPx: config.thumbMaxPx,
                                   previewMaxPx: config.previewMaxPx)

        let started = Date()
        var generated = 0
        var failed = 0
        var failures: [String] = []

        for wallpaper in scan.wallpapers {
            for sizeClass in [ThumbSizeClass.row, ThumbSizeClass.preview] {
                if cache.existingThumbnail(for: wallpaper, sizeClass: sizeClass) != nil {
                    continue
                }
                do {
                    _ = try cache.thumbnail(for: wallpaper, sizeClass: sizeClass)
                    generated += 1
                } catch {
                    failed += 1
                    failures.append(wallpaper.name + " (" + sizeClass.rawValue + "): "
                                    + String(describing: error))
                }
            }
        }

        var pruned = 0
        if options.has("prune") {
            pruned = (try? cache.prune(keeping: scan.wallpapers)) ?? 0
        }

        let elapsed = Date().timeIntervalSince(started)
        for failure in failures { environment.output.err("walle: " + failure) }

        if options.has("json") {
            try emitJSON([
                "wallpapers": scan.wallpapers.count,
                "generated": generated,
                "failed": failed,
                "pruned": pruned,
                "cacheBytes": cache.cacheSizeBytes(),
                "cacheDir": cacheDir.path,
                "elapsedMs": elapsed * 1000,
            ], to: environment)
        } else {
            environment.output.out(String(scan.wallpapers.count) + " wallpapers, "
                                   + String(generated) + " thumbnails generated"
                                   + (failed > 0 ? ", " + String(failed) + " failed" : "")
                                   + (pruned > 0 ? ", " + String(pruned) + " pruned" : ""))
            environment.output.out("cache: " + String(cache.cacheSizeBytes())
                                   + " bytes in " + cacheDir.path)
        }
        return failed == 0 ? CLIExit.success.rawValue : CLIExit.failure.rawValue
    }

    // MARK: - config

    static func config(_ tokens: [String], environment: CLIEnvironment) throws -> Int32 {
        guard let sub = tokens.first else {
            throw CLIError("config needs a subcommand: path, list, get, set, unset or edit",
                           showUsage: true)
        }
        let rest = Array(tokens.dropFirst())
        switch sub {
        case "path": return try configPath(rest, environment: environment)
        case "list": return try configList(rest, environment: environment)
        case "get": return try configGet(rest, environment: environment)
        case "set": return try configSet(rest, environment: environment)
        case "unset": return try configUnset(rest, environment: environment)
        case "edit": return try configEdit(rest, environment: environment)
        default: throw CLIError("unknown config subcommand '\(sub)'", showUsage: true)
        }
    }

    static func configPath(_ tokens: [String], environment: CLIEnvironment) throws -> Int32 {
        let options = try OptionParser.parse(
            tokens, spec: OptionSpec(boolOptions: ["json"],
                                     shortAliases: ["j": "json", "h": "help"]))
        if options.has("help") { return help(environment) }
        let path = environment.paths.configFile.path
        if options.has("json") {
            try emitJSON(["config": path,
                          "exists": FileManager.default.fileExists(atPath: path)],
                         to: environment)
        } else {
            environment.output.out(path)
        }
        return CLIExit.success.rawValue
    }

    static func configList(_ tokens: [String], environment: CLIEnvironment) throws -> Int32 {
        let options = try OptionParser.parse(
            tokens, spec: OptionSpec(boolOptions: ["json"],
                                     shortAliases: ["j": "json", "h": "help"]))
        if options.has("help") { return help(environment) }
        let (config, warnings) = loadConfig(environment)
        reportWarnings(warnings, environment, config: config)
        if options.has("json") {
            var settings: [String: Any] = [:]
            for key in Config.keyOrder { settings[key] = config.value(forKey: key) ?? "" }
            try emitJSON(["config": environment.paths.configFile.path, "settings": settings],
                         to: environment)
        } else {
            for key in Config.keyOrder {
                environment.output.out("\(key) = \(config.value(forKey: key) ?? "")")
            }
        }
        return CLIExit.success.rawValue
    }

    static func configGet(_ tokens: [String], environment: CLIEnvironment) throws -> Int32 {
        let options = try OptionParser.parse(
            tokens, spec: OptionSpec(boolOptions: ["json"],
                                     shortAliases: ["j": "json", "h": "help"]))
        if options.has("help") { return help(environment) }
        guard let key = options.positionals.first else { throw CLIError("config get needs a key") }
        let (config, _) = loadConfig(environment)
        guard let value = config.value(forKey: key) else {
            throw CLIError("unknown setting '\(key)'")
        }
        if options.has("json") {
            try emitJSON(["key": key, "value": value], to: environment)
        } else {
            environment.output.out(value)
        }
        return CLIExit.success.rawValue
    }

    static func configSet(_ tokens: [String], environment: CLIEnvironment) throws -> Int32 {
        let options = try OptionParser.parse(
            tokens, spec: OptionSpec(boolOptions: ["json"],
                                     shortAliases: ["j": "json", "h": "help"]))
        if options.has("help") { return help(environment) }
        guard options.positionals.count >= 2 else {
            throw CLIError("config set needs a key and a value, for example: "
                           + "walle config set slots 9")
        }
        let key = options.positionals[0]
        let value = options.positionals.dropFirst().joined(separator: " ")
        var (config, _) = loadConfig(environment)
        guard config.apply(key: key, value: value) else {
            throw CLIError("unknown setting '\(key)'")
        }
        // Validation runs on the way out so the file on disk is always usable.
        let (clean, warnings) = config.sanitized()
        try clean.save(to: environment.paths.configFile)
        if options.has("json") {
            try emitJSON(["key": key, "value": clean.value(forKey: key) ?? "",
                          "warnings": warnings], to: environment)
        } else {
            environment.output.out("\(key) = \(clean.value(forKey: key) ?? "")")
            for warning in warnings { environment.output.err("walle: warning: \(warning)") }
        }
        return CLIExit.success.rawValue
    }

    static func configUnset(_ tokens: [String], environment: CLIEnvironment) throws -> Int32 {
        let options = try OptionParser.parse(
            tokens, spec: OptionSpec(boolOptions: ["json"],
                                     shortAliases: ["j": "json", "h": "help"]))
        if options.has("help") { return help(environment) }
        guard let key = options.positionals.first else { throw CLIError("config unset needs a key") }
        guard let defaultValue = Config().value(forKey: key) else {
            throw CLIError("unknown setting '\(key)'")
        }
        var (config, _) = loadConfig(environment)
        _ = config.apply(key: key, value: defaultValue)
        try config.save(to: environment.paths.configFile)
        if options.has("json") {
            try emitJSON(["key": key, "value": config.value(forKey: key) ?? ""], to: environment)
        } else {
            environment.output.out("\(key) = \(config.value(forKey: key) ?? "")")
        }
        return CLIExit.success.rawValue
    }

    static func configEdit(_ tokens: [String], environment: CLIEnvironment) throws -> Int32 {
        let options = try OptionParser.parse(
            tokens, spec: OptionSpec(boolOptions: ["json"],
                                     shortAliases: ["j": "json", "h": "help"]))
        if options.has("help") { return help(environment) }
        if !FileManager.default.fileExists(atPath: environment.paths.configFile.path) {
            try Config().save(to: environment.paths.configFile)
        }
        let editor = environment.environment["EDITOR"]
            ?? environment.environment["VISUAL"]
            ?? "vi"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exec " + editor + " " + shellQuote(environment.paths.configFile.path)]
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
            ? CLIExit.success.rawValue
            : CLIExit.failure.rawValue
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
