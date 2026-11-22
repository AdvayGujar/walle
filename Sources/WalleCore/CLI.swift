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
    /// Re-exported from `WalleVersion`, the one place the version is written down.
    public static let version = WalleVersion.string

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
        case "rotate": return try rotate(rest, environment: environment)
        case "upscale": return try upscale(rest, environment: environment)
        case "add": return try dir(["add"] + rest, environment: environment)
        case "remove", "rm": return try dir(["remove"] + rest, environment: environment)
        case "use": return try dir(["use"] + rest, environment: environment)
        case "dirs": return try dir(["list"] + rest, environment: environment)
        case "dir": return try dir(rest, environment: environment)
        case "config": return try config(rest, environment: environment)
        case "set": return try set(rest, environment: environment)
        case "current": return try current(rest, environment: environment)
        case "history": return try history(rest, environment: environment)
        case "spaces": return try spaces(rest, environment: environment)
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
        guard config.logLevel.showsWarnings else { return }
        for warning in warnings {
            environment.output.err("walle: warning: \(warning)")
        }
    }

    static func emitJSON(_ object: Any, to environment: CLIEnvironment) throws {
        let data = try JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        environment.output.out(String(decoding: data, as: UTF8.self))
    }

    // MARK: - spaces

    static let spaceDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM HH:mm"
        return formatter
    }()

    /// macOS keeps the desktop picture per Space, keyed by Space UUID in a private store, and
    /// the only public API writes the default plus the Space you are currently on. This reports
    /// that store, and with "all" copies the default onto every other Space so one wallpaper is
    /// used everywhere.
    static func spaces(_ tokens: [String], environment: CLIEnvironment) throws -> Int32 {
        let options = try OptionParser.parse(
            tokens,
            spec: OptionSpec(boolOptions: ["json", "all", "prune", "dry-run", "help"],
                             shortAliases: ["j": "json", "h": "help"]))
        if options.has("help") { return help(environment) }
        let action = options.positionals.first
        if let action, !["all", "on", "off"].contains(action) {
            throw CLIError("unknown argument '" + action
                           + "'; use 'spaces', 'spaces on', 'spaces off' or 'spaces all'")
        }
        if options.positionals.count > 1 {
            throw CLIError("spaces takes at most one argument")
        }
        if options.has("dry-run"), action == nil, !options.has("all") {
            throw CLIError("--dry-run needs an action: "
                           + "'spaces all --dry-run' or 'spaces on --dry-run'")
        }

        let (settings, _) = loadConfig(environment)

        // The toggle. "on" makes every future apply reach every Space; "off" restores the
        // ordinary macOS behaviour of changing only the desktop you are looking at.
        if action == "on" || action == "off" {
            let url = WallpaperStore.indexURL(environment: environment.environment)
            if options.has("dry-run") {
                if action == "on" {
                    environment.output.out("spaces on: would apply every wallpaper to every Space")
                    // Show what turning it on would do now, without touching the config or store.
                    let preview = try WallpaperStore.applyDefaultToAllSpaces(
                        at: url,
                        options: WallpaperStore.SyncOptions(
                            liveSpaces: WallpaperStore.liveSpaceUUIDs(), dryRun: true))
                    reportSync(preview, environment, dryRun: true)
                } else {
                    environment.output.out("spaces off: would only affect the Space you are on")
                }
                return CLIExit.success.rawValue
            }
            let status = try config(["set", "spaces", action == "on" ? "all" : "current"],
                                    environment: environment)
            guard status == CLIExit.success.rawValue else { return status }
            if action == "on" {
                environment.output.out("spaces on: a wallpaper you pick will be applied to every Space")
                // Bring the Spaces that already exist into line now, rather than waiting for
                // the next apply to do it.
                reportSync(try WallpaperStore.applyDefaultToAllSpaces(
                    at: url,
                    options: WallpaperStore.SyncOptions(
                        liveSpaces: WallpaperStore.liveSpaceUUIDs())), environment)
            } else {
                environment.output.out("spaces off: a wallpaper you pick will only affect the Space you are on")
            }
            return CLIExit.success.rawValue
        }

        let url = WallpaperStore.indexURL(environment: environment.environment)

        do {
            if options.has("all") || action == "all" {
                let live = WallpaperStore.liveSpaceUUIDs()
                let dryRun = options.has("dry-run")
                let result = try WallpaperStore.applyDefaultToAllSpaces(
                    at: url,
                    options: WallpaperStore.SyncOptions(
                        liveSpaces: live,
                        pruneStale: options.has("prune"),
                        dryRun: dryRun))
                if options.has("json") {
                    try emitJSON(["updated": result.updated,
                                  "created": result.created,
                                  "alreadyMatching": result.alreadyMatching,
                                  "stale": result.stale,
                                  "pruned": result.pruned,
                                  "liveSpaces": live,
                                  "dryRun": dryRun,
                                  "backup": result.backupPath ?? ""], to: environment)
                } else {
                    reportSync(result, environment, dryRun: dryRun)
                }
                return CLIExit.success.rawValue
            }

            let summaries = try WallpaperStore.spaces(at: url)
            let image = (try? WallpaperStore.defaultImagePath(at: url)) ?? nil
            if options.has("json") {
                try emitJSON([
                    "store": url.path,
                    "defaultImage": image ?? "",
                    "spaces": summaries.map { summary -> [String: Any] in
                        var entry: [String: Any] = ["key": summary.key,
                                                    "isDefault": summary.isDefault]
                        if let when = summary.lastSet {
                            entry["lastSet"] = ISO8601DateFormatter().string(from: when)
                        }
                        return entry
                    },
                ], to: environment)
            } else {
                environment.output.out("wallpaper store: " + url.path)
                if let image { environment.output.out("default image:   " + image) }
                environment.output.out("")
                for summary in summaries {
                    let when = summary.lastSet.map { spaceDateFormatter.string(from: $0) } ?? "-"
                    environment.output.out("  " + summary.label.padding(toLength: 38,
                                                                        withPad: " ",
                                                                        startingAt: 0) + when)
                }
                let inventory = WallpaperStore.spaceInventory()
                let live = Set(inventory.all)
                let existing = Set(summaries.map(\.key))
                let missing = live.subtracting(existing).sorted()
                let stale = existing.subtracting(live).sorted()
                let differing = summaries.filter { !$0.matchesDefault }.count

                environment.output.out("")
                environment.output.out("mode: " + (settings.spaces == .all
                    ? "on  - every Space is updated when you apply"
                    : "off - only the Space you are on is updated"))
                if !inventory.isKnown {
                    environment.output.out("could not read com.apple.spaces, so Space status is unknown")
                } else {
                    let switchable = inventory.switchable
                    environment.output.out("Spaces you can switch to: \(switchable.count)"
                                           + "  (all with a store entry: "
                                           + "\(switchable.allSatisfy { existing.contains($0) }))")
                    if !inventory.collapsed.isEmpty {
                        environment.output.out("Spaces on collapsed displays: \(inventory.collapsed.count)")
                    }
                    for uuid in missing {
                        environment.output.out("  no entry:    " + (uuid.isEmpty ? "(empty uuid)" : uuid))
                    }
                }
                if !stale.isEmpty {
                    environment.output.out("stale entries for removed Spaces: \(stale.count)")
                    for uuid in stale {
                        environment.output.out("  stale:       " + uuid)
                    }
                }
                if !missing.isEmpty || differing > 0 {
                    environment.output.out("")
                    environment.output.out("'walle spaces all' gives every Space the same wallpaper"
                                           + (stale.isEmpty ? "" : ", and --prune drops the stale entries"))
                } else {
                    environment.output.out("")
                    environment.output.out("every live Space shows the same wallpaper")
                }
            }
            return CLIExit.success.rawValue
        } catch {
            throw CLIError("\(error)")
        }
    }

    /// Reports what a sync did, in the same words whether it came from "spaces on" or
    /// "spaces all".
    static func reportSync(_ result: WallpaperStore.SyncResult, _ environment: CLIEnvironment,
                           dryRun: Bool = false) {
        // The store's "" key is a real Space whose uuid is empty; printing it raw left a
        // trailing blank in the report.
        func label(_ key: String) -> String { key.isEmpty ? "(empty uuid)" : key }

        if !result.changedAnything {
            environment.output.out("every Space already shows the same wallpaper")
        } else {
            for key in result.created { environment.output.out("added   Space " + label(key)) }
            for key in result.updated { environment.output.out("updated Space " + label(key)) }
            for key in result.pruned { environment.output.out("removed stale entry " + label(key)) }
            if let backup = result.backupPath { environment.output.out("backup: " + backup) }
            if !dryRun {
                environment.output.out("WallpaperAgent restarted; switch Spaces to confirm")
            }
        }
        if dryRun { environment.output.out("dry run: nothing was written") }
        if !result.stale.isEmpty && result.pruned.isEmpty {
            environment.output.out("note: \(result.stale.count) store entr"
                                   + (result.stale.count == 1 ? "y is" : "ies are")
                                   + " for Spaces that no longer exist; "
                                   + "'walle spaces all --prune' removes them")
        }
    }

    // MARK: - help

    static func help(_ environment: CLIEnvironment) -> Int32 {
        environment.output.out("""
        walle \(version) - a keyboard-driven wallpaper switcher for macOS

        USAGE
          walle                      Open the picker
          walle <command> [options]

        PICKER
          pick                       Open the picker. A bare "walle" does the same.

        CHOOSING A WALLPAPER
          set <path>                 Apply one specific file
          set --last                 Re-apply the most recent one that still exists
          next                       Apply the next wallpaper in the library
          prev                       Apply the previous one
          random                     Apply a random one
          current                    Print the current desktop wallpaper
          Any of these accepts --dry-run to show what would be applied without
          applying it, and --json for machine readable output.

        ROTATION
          rotate [interval]          Apply the next wallpaper now, then every interval
                                     (30s, 10m, 2h; default: rotation_interval)
          rotate --once              Apply one and exit; pair it with launchd for a
                                     rotation that does not keep a process running
          rotate --dry-run           Show what would be applied each interval
          rotate --json              Machine readable output per apply
          If the picker is open when a rotation is due, that step is skipped. The
          wallpaper you pick there becomes the starting point for the next step.

        UPSCALING
          upscale on                 Cache ML copies in the background, return now
          upscale on --wait          Cache now, blocking until finished
          upscale off                Use the original images again
          upscale --refresh          Fill missing cache entries (run on picker open)
          upscale <file>...          Upscale with the ML backend and write HEIC
          upscale --all              Do that for every wallpaper in the library
          upscale --dir <path>       Scan this directory instead of the configured ones
          upscale --target <WxH>     Target pixels (default: the active display)
          upscale --mode fill|fit|stretch
                                     How macOS will place the image (default: fill_mode)
          upscale --model <name|.param>
                                     Model name, or a .param file beside its .bin
          upscale --models <dir>     Models directory (default: upscale_models)
          upscale --scale 2|3|4      Force the model pass; default picks per image
          upscale --quality 0-1      HEIC quality (default 0.85)
          upscale --output <dir>     Where to put the copies
          upscale --upscaler <path>  Replace the ML backend executable
          upscale --tool <path>      upscayl-bin path for the default backend
          upscale --dry-run          Report what would be generated, write nothing
          upscale --json             Machine readable summary
          The ML backend is a separate walle-upscaler executable. Replace it, or
          point --upscaler at your own, without changing the picker or library.

        THE LIBRARY
          list                       List the wallpapers that were found
          dirs                       Show the configured directories and their counts
          add <path>                 Add a directory (created if it does not exist)
          remove <path>              Remove a directory from the list
          use <path>                 Replace the whole list with a single directory
          dir list|add|remove|use    The same four commands, spelled out

        THUMBNAIL CACHE
          cache                      Build the cache (recommended before first use)
          cache --prune              Also drop entries whose source file is gone
          cache --rebuild            Throw the cache away and build it again

        HISTORY
          history                    Show recently applied wallpapers
          history --limit <n>        Only the n most recent entries
          history --clear            Forget everything

        SPACES
          spaces                     Show the mode, the live Spaces and the stale entries
          spaces on                  Apply every wallpaper to every Space from now on
          spaces off                 Only change the Space you are on (the default)
          spaces all                 Copy the current wallpaper onto every Space now
          spaces all --prune         Also drop entries for Spaces you have deleted
          spaces all --dry-run       Show what a sync would change, write nothing

          macOS stores the desktop picture per Space, and its public API can only
          write the one you are looking at. These commands work around that.

        CONFIGURATION
          config list                Print every setting
          config get <key>           Print one setting
          config set <key> <value>   Change one setting
          config unset <key>         Restore one setting to its default
          config path                Print the config file location
          config edit                Open it in $EDITOR

        DIAGNOSTICS
          doctor                     Check config, library, picker binary, cache
                                     and the hotkey setup
          help                       Show this help
          version                    Show the version

        OPTIONS
          --json                     Machine readable output where supported
          --dry-run                  Show what would happen, change nothing
          --limit <n>                list, history: stop after n entries
          --interval <duration>      rotate: 30s, 10m, 2h
          --sort <name|mtime|random> list: ordering
          --dir <path>               list: scan this path instead of the configured ones
          -h, --help                 Show this help
          --version                  Show the version

        KEYBOARD, WHILE THE PICKER IS OPEN
          left / right (up / down)   Move between wallpapers, wrapping both ways
          space                      Expand the centred card into the preview,
                                     or collapse it again
          enter                      Apply the centred wallpaper and close
          escape                     Close without changing anything

        EXIT CODES
          0 applied   1 error   2 dismissed   3 already running (picker, rotation or upscale)

        CONFIG FILE
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
        // Only the JSON listing exposes aspectRatio; the plain path listing would pay one
        // ImageIO open per file for a value it never prints.
        let result = scanner.scan(extraDirs: extraDirs, seed: seed,
                                  includeAspectRatio: options.has("json"))
        for warning in result.warnings {
            environment.output.err("walle: warning: \(warning)")
        }
        if config.logLevel.showsInfo {
            environment.output.err("walle: scanned \(result.wallpapers.count) wallpapers")
        }

        var wallpapers = result.wallpapers
        if let limit = try options.int("limit") {
            guard limit >= 0 else { throw CLIError("--limit must be >= 0") }
            wallpapers = Array(wallpapers.prefix(limit))
        }

        if options.has("json") {
            try emitJSON([
                "count": wallpapers.count,
                // Every root the scan actually walked: the configured ones plus --dir.
                "roots": scanConfig.wallpaperDirs + extraDirs,
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
        // dirs only needs counts and paths, never a thumbnail aspect ratio.
        let result = scanner.scan(includeAspectRatio: false)
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
        try config.save(to: environment.paths.configFile, updating: ["wallpaper_dirs"])

        if options.has("json") {
            try emitJSON(["added": root, "path": resolved, "created": created,
                          "roots": config.wallpaperDirs], to: environment)
        } else {
            environment.output.out("added \(root)")
            if created { environment.output.err("walle: created \(resolved)") }
        }
        startLibraryCacheRefresh(environment, config: config)
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
        try config.save(to: environment.paths.configFile, updating: ["wallpaper_dirs"])

        if options.has("json") {
            try emitJSON(["removed": target, "roots": config.wallpaperDirs], to: environment)
        } else {
            environment.output.out("removed \(target)")
        }
        startLibraryCacheRefresh(environment, config: config)
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
        try config.save(to: environment.paths.configFile, updating: ["wallpaper_dirs"])

        if options.has("json") {
            try emitJSON(["roots": config.wallpaperDirs], to: environment)
        } else {
            environment.output.out("using \(root)")
        }
        startLibraryCacheRefresh(environment, config: config)
        return CLIExit.success.rawValue
    }

    /// `dir add` / `dir use` should not make the user wait for an ML pass.
    private static func startLibraryCacheRefresh(_ environment: CLIEnvironment,
                                                 config: Config) {
        guard config.upscale else { return }
        if startBackgroundRefresh(environment) {
            environment.output.err("walle: caching the library in the background")
        }
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
        var childEnvironment = environment.environment
        if let argv0 = CommandLine.arguments.first {
            childEnvironment["WALLE_CLI"] = URL(fileURLWithPath: argv0)
                .resolvingSymlinksInPath().path
        }
        process.environment = childEnvironment
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Baseline the store before the child starts, so a system write that lands while it is
        // open is detected immediately after it exits instead of being waited out for the full
        // timeout. A timestamp taken after the exit cannot tell those cases apart.
        let storeURL = WallpaperStore.indexURL(environment: environment.environment)
        let storeBaseline = WallpaperStore.storeModificationDate(at: storeURL)
        try process.run()
        // Drain both pipes at once. Reading stdout to EOF first deadlocks if the child
        // fills stderr's 64 KiB buffer before it closes stdout, which a chatty picker
        // (warnings, WALLE_TRACE) can do; neither pipe would then ever be read.
        let drained = Self.drainProcessPipes(out: outPipe, err: errPipe)
        process.waitUntilExit()
        let outData = drained.stdout
        let errData = drained.stderr

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

        // With "spaces = all", bring the other Spaces into line HERE rather than inside the
        // picker. macOS persists a wallpaper change asynchronously, so syncing from inside the
        // picker raced the very apply that had just been made and lost: the system's write
        // landed afterwards and overwrote it.
        //
        // Copying the store's "most recent" entry here has the SAME race: the picker has exited
        // but its store write may not have landed yet, so the most recent entry is still the
        // PREVIOUS wallpaper. The sync then looks like a no-op (everything already matches the
        // stale entry) and the delayed write lands afterwards, changing only the current Space.
        // So instead read the path the picker itself recorded to the state file just before it
        // exited (walleRecordApplied), and sync from that — it is the wallpaper the user actually
        // picked, independent of whether the store has caught up. "--current" only reads and
        // never applies, so it must not trigger a sync at all.
        if process.terminationStatus == CLIExit.success.rawValue,
           arguments.first != "--current" {
            let (settings, _) = loadConfig(environment)
            if settings.spaces == .all {
                let state = StateStore(fileURL: environment.paths.stateFile).load()
                let appliedPath = state.lastDisplayPath ?? state.lastAppliedPath
                // macOS persists the apply asynchronously, and that write lands a beat after
                // the picker exits. Wait for it (the store's mtime advancing) so our own sync
                // write below is not overwritten by it — which reverted every other Space.
                WallpaperStore.waitForStoreWrite(at: storeURL, since: storeBaseline)
                do {
                    let result = try WallpaperStore.applyDefaultToAllSpaces(
                        at: storeURL,
                        options: WallpaperStore.SyncOptions(
                            liveSpaces: WallpaperStore.liveSpaceUUIDs(),
                            sourcePath: appliedPath,
                            settleForSystemWrite: false))
                    if settings.logLevel.showsStatus {
                        reportSync(result, environment)
                    }
                } catch {
                    environment.output.err("walle: the wallpaper was applied, but not to every "
                                           + "Space: " + String(describing: error))
                }
            }
        }
        return process.terminationStatus
    }

    /// Reads a child's stdout and stderr at the same time, so neither can fill its pipe
    /// buffer while the other is read. The calling thread drains stdout; one worker drains
    /// stderr, and both return only at EOF.
    static func drainProcessPipes(out: Pipe, err: Pipe) -> (stdout: Data, stderr: Data) {
        let results = WalleConcurrentResults<Data?>(repeating: nil, count: 2)
        let errHandle = err.fileHandleForReading
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            results.set(errHandle.readDataToEndOfFile(), at: 1)
            group.leave()
        }
        results.set(out.fileHandleForReading.readDataToEndOfFile(), at: 0)
        group.wait()
        return (results.values[0] ?? Data(), results.values[1] ?? Data())
    }

    /// Runs the picker and returns its standard output. Used to ask the picker for values
    /// only it can compute, such as the thumbnail size this display needs.
    static func capturePicker(_ arguments: [String],
                              _ environment: CLIEnvironment) -> String? {
        guard let picker = PickerLocator.locate(environment: environment.environment) else {
            return nil
        }
        let process = Process()
        process.executableURL = picker
        process.arguments = arguments
        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

        // Only the inputs the mode actually reads. An explicit path and --last resolve
        // from disk, so a full library scan (and its ImageIO reads) was pure waste; the
        // state file only matters for next/previous, which start from the current wallpaper.
        var library: [Wallpaper] = []
        var history: [HistoryEntry] = []
        var currentPath: String?
        switch mode {
        case .explicit:
            break
        case .last:
            history = (try? HistoryStore(fileURL: environment.paths.historyFile).entries()) ?? []
        case .random:
            library = LibraryScanner(config: config, home: environment.paths.home)
                .scan(includeAspectRatio: false).wallpapers
        case .next, .previous:
            library = LibraryScanner(config: config, home: environment.paths.home)
                .scan(includeAspectRatio: false).wallpapers
            let applied = StateStore(fileURL: environment.paths.stateFile)
                .load().lastAppliedPath
            currentPath = applied.map { path in
                UpscaleCache.sourceForCurrent(paths: environment.paths,
                                              displayPath: path) ?? path
            }
        }

        let chosen: Wallpaper
        do {
            chosen = try Selection.resolve(
                mode,
                library: library,
                history: history,
                currentPath: currentPath,
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

    // MARK: - rotate

    /// Runs the library on a timer for as long as the command lives.
    ///
    /// Each step re-reads the state file rather than remembering an index. That is what
    /// makes a picker session seamless: the picker records the wallpaper it applied, and
    /// the next step advances from there instead of from this loop's own last choice.
    /// A step that lands while the picker is open is skipped so the two never fight over
    /// the desktop.
    static func rotate(_ tokens: [String], environment: CLIEnvironment) throws -> Int32 {
        let options = try OptionParser.parse(
            tokens,
            spec: OptionSpec(valueOptions: ["interval"],
                             boolOptions: ["once", "dry-run", "json"],
                             shortAliases: ["j": "json", "h": "help"]))
        if options.has("help") { return help(environment) }
        guard options.positionals.count <= 1 else {
            throw CLIError("rotate takes at most one interval")
        }
        if options.value("interval") != nil, !options.positionals.isEmpty {
            throw CLIError("rotate takes the interval as an argument or --interval, not both")
        }

        let (config, warnings) = loadConfig(environment)
        reportWarnings(warnings, environment, config: config)
        let rawInterval = options.value("interval")
            ?? options.positionals.first
            ?? config.rotationInterval
        guard let interval = RotationInterval.parse(rawInterval) else {
            throw CLIError("rotate expects a duration like 30s, 10m or 2h, got '\(rawInterval)'")
        }

        let once = options.has("once")
        let dryRun = options.has("dry-run")
        let json = options.has("json")

        // One rotation loop at a time, for the same reason the picker has a lock: two
        // loops would each advance the other's choice and the library would race. The
        // lock is released when this function returns, not when this block ends, so it
        // stays held for the whole loop (dry runs touch nothing and need no lock).
        var rotationLock: SingleInstance.Lock?
        if !dryRun {
            guard let lock = SingleInstance.acquire(at: environment.paths.rotationLockFile) else {
                environment.output.err("walle: another rotation is already running")
                return CLIExit.alreadyRunning.rawValue
            }
            rotationLock = lock
        }
        defer {
            if let rotationLock { SingleInstance.release(rotationLock) }
        }

        if !once, !json, config.logLevel.showsStatus {
            environment.output.out("rotating every \(interval.description); press Ctrl-C to stop")
        }

        let settings = RotationSettings(
            interval: interval,
            config: config,
            dryRun: dryRun,
            json: json,
            stateStore: StateStore(fileURL: environment.paths.stateFile),
            environment: environment)
        var step = 0
        while true {
            step += 1
            try rotationStep(settings, isFirstStep: step == 1)
            if once { break }
            Thread.sleep(forTimeInterval: TimeInterval(interval.seconds))
        }
        return CLIExit.success.rawValue
    }

    private struct RotationSettings {
        let interval: RotationInterval
        let config: Config
        let dryRun: Bool
        let json: Bool
        let stateStore: StateStore
        let environment: CLIEnvironment
    }

    private static func rotationStep(_ settings: RotationSettings,
                                     isFirstStep: Bool) throws {
        let (interval, config, dryRun, json) =
            (settings.interval, settings.config, settings.dryRun, settings.json)
        let environment = settings.environment

        let scan = LibraryScanner(config: config, home: environment.paths.home)
            .scan(includeAspectRatio: false)
        // Scan warnings are a property of the config, so they are reported once at the
        // start rather than on every step of a loop that may run for hours.
        if config.logLevel.showsWarnings, isFirstStep {
            for warning in scan.warnings {
                environment.output.err("walle: warning: " + warning)
            }
        }
        guard !scan.wallpapers.isEmpty else {
            if isFirstStep { throw CLIError("the wallpaper library is empty") }
            environment.output.err("walle: warning: no wallpapers found; skipping this rotation")
            return
        }

        if SingleInstance.isHeld(at: environment.paths.lockFile) {
            if config.logLevel.showsInfo {
                environment.output.err("walle: the picker is open; skipping this rotation")
            }
            return
        }

        let currentPath = settings.stateStore.load().lastAppliedPath
        let chosen: Wallpaper
        do {
            chosen = try Selection.resolve(.next, library: scan.wallpapers, history: [],
                                           currentPath: currentPath, seed: 0)
        } catch {
            throw CLIError(String(describing: error))
        }

        if dryRun {
            if json {
                try emitJSON(["wouldApply": chosen.path,
                              "interval": interval.description], to: environment)
            } else {
                environment.output.out(chosen.path)
            }
            return
        }

        let status = try runPicker(["--apply", chosen.path, "--mode", "rotate"], environment)
        guard status == CLIExit.success.rawValue else {
            environment.output.err("walle: could not apply " + chosen.path
                                   + " (walle-picker exited \(status)); rotation continues")
            return
        }
        if json {
            try emitJSON(["applied": chosen.path, "interval": interval.description],
                         to: environment)
        } else if config.logLevel.showsStatus {
            environment.output.out("rotated to " + chosen.path)
        }
    }

    // MARK: - upscale

    private struct UpscaleSettings {
        let target: PixelSize
        let mode: FillMode
        let maxScale: Double
        let scaleOverride: Int?
        let model: String
        let modelsDirectory: URL?
        let tool: String?
        let upscaler: URL
        let quality: Double
        let outputDir: URL
        let dryRun: Bool
        let json: Bool
        let force: Bool
        /// True for the hidden `upscale = on` cache; false for explicit exports.
        let cache: Bool
        let config: Config
        let environment: CLIEnvironment
    }

    private struct UpscalePending {
        let wallpaper: Wallpaper
        let sourcePath: String
        let output: URL
        let plan: UpscalePlan
        let info: UpscaleSourceInfo
    }

    /// Sends a batch to the replaceable `walle-upscaler` module. This command
    /// owns scanning, target sizing, output naming and the manifest; it knows
    /// nothing about x4plus, Upscayl or the model runtime.
    private struct UpscaleSetup {
        let config: Config
        let target: PixelSize
        let mode: FillMode
        let maxScale: Double
        let scaleOverride: Int?
        let quality: Double
        let modelName: String
        let modelsDirectory: URL?
        let tool: String?
        let upscaler: URL
    }

    /// Sends a batch to the replaceable `walle-upscaler` module. This command
    /// owns scanning, target sizing, output naming and the manifest; it knows
    /// nothing about x4plus, Upscayl or the model runtime.
    static func upscale(_ tokens: [String], environment: CLIEnvironment) throws -> Int32 {
        let options = try OptionParser.parse(
            tokens,
            spec: OptionSpec(
                valueOptions: ["target", "mode", "max-scale", "scale", "quality",
                               "output", "dir", "model", "models", "upscaler", "tool"],
                boolOptions: ["all", "dry-run", "json", "force", "refresh", "wait"],
                shortAliases: ["j": "json", "h": "help"]))
        if options.has("help") { return help(environment) }

        if options.has("refresh") {
            guard options.positionals.isEmpty, !options.has("all"),
                  options.all("dir").isEmpty, options.value("output") == nil else {
                throw CLIError("upscale --refresh uses the configured library; "
                               + "no paths, --all, --dir or --output")
            }
            return try fillUpscaleCache(options, environment: environment,
                                        setConfig: false, background: false)
        }

        if let action = options.positionals.first, action == "on" || action == "off" {
            guard options.positionals.count == 1 else {
                throw CLIError("upscale \(action) takes no other arguments")
            }
            return try upscaleToggle(action == "on", options: options,
                                     environment: environment)
        }

        let usesLibrary = options.has("all") || !options.all("dir").isEmpty
        guard options.positionals.isEmpty || !usesLibrary else {
            throw CLIError("upscale takes file paths, --all or --dir, not more than one")
        }
        guard !options.positionals.isEmpty || usesLibrary else {
            throw CLIError("upscale needs file paths, --all, --dir or 'upscale on'")
        }

        let setup = try upscaleSetup(options, environment: environment)
        let wallpapers = try upscaleWallpapers(options, config: setup.config,
                                               environment: environment)
        guard !wallpapers.isEmpty else {
            throw CLIError("no wallpapers found; check the paths or 'walle list'")
        }

        let outputDir = upscaleOutputDirectory(options, target: setup.target,
                                               model: setup.modelName,
                                               environment: environment)
        let settings = UpscaleSettings(
            target: setup.target, mode: setup.mode, maxScale: setup.maxScale,
            scaleOverride: setup.scaleOverride, model: setup.modelName,
            modelsDirectory: setup.modelsDirectory, tool: setup.tool,
            upscaler: setup.upscaler, quality: setup.quality, outputDir: outputDir,
            dryRun: options.has("dry-run"), json: options.has("json"),
            force: options.has("force"), cache: false,
            config: setup.config, environment: environment)
        return try runUpscaleLocked(wallpapers, settings: settings,
                                    environment: environment)
    }

    /// `walle upscale on` enables transparent use of a hidden cache and fills
    /// it for the configured library. `off` leaves the cache on disk but uses
    /// the originals again.
    private static func upscaleToggle(
        _ on: Bool, options: ParsedOptions, environment: CLIEnvironment
    ) throws -> Int32 {
        if options.has("all") || !options.all("dir").isEmpty
            || options.positionals.count != 1 {
            throw CLIError("upscale \(on ? "on" : "off") does not take paths, --all or --dir")
        }
        if options.value("output") != nil {
            throw CLIError("upscale on/off uses a hidden cache; --output is for explicit exports")
        }
        if on, options.value("mode") != nil {
            throw CLIError("upscale on always sizes for fill; --mode is for explicit exports")
        }

        var (config, warnings) = loadConfig(environment)
        reportWarnings(warnings, environment, config: config)
        let dryRun = options.has("dry-run")
        let json = options.has("json")

        if !on {
            if !dryRun {
                config.upscale = false
                try config.save(to: environment.paths.configFile, updating: ["upscale"])
                try? FileManager.default.removeItem(at: environment.paths.upscalePendingRefresh)
            }
            if json {
                try emitJSON(["upscale": false, "dryRun": dryRun], to: environment)
            } else {
                environment.output.out("upscale off: using the original images")
            }
            return CLIExit.success.rawValue
        }

        return try fillUpscaleCache(
            options, environment: environment, setConfig: true,
            background: !options.has("wait") && !dryRun)
    }

    /// Shared by `upscale on` and the background `upscale --refresh` used when
    /// the picker opens. `setConfig` is false for refresh, so a new image can be
    /// cached without touching the user's setting.
    private static func fillUpscaleCache(
        _ options: ParsedOptions, environment: CLIEnvironment,
        setConfig: Bool, background: Bool
    ) throws -> Int32 {
        let (config, warnings) = loadConfig(environment)
        reportWarnings(warnings, environment, config: config)
        let dryRun = options.has("dry-run")
        let json = options.has("json")

        if !setConfig, !config.upscale {
            if json {
                try emitJSON(["upscale": false, "generated": 0, "skipped": 0,
                              "failed": 0], to: environment)
            }
            return CLIExit.success.rawValue
        }

        let setup = try upscaleSetup(options, environment: environment,
                                     modeOverride: .fill)
        let scan = LibraryScanner(config: setup.config, home: environment.paths.home)
            .scan(includeAspectRatio: false)
        guard !scan.wallpapers.isEmpty else {
            if !dryRun { pruneCacheLocked(environment) }
            if setConfig {
                throw CLIError("no wallpapers found; add a directory with 'walle dir add'")
            }
            return CLIExit.success.rawValue
        }

        if !dryRun, setConfig {
            var updated = config
            updated.upscale = true
            try updated.save(to: environment.paths.configFile, updating: ["upscale"])
        }

        if !dryRun, background {
            let started = startBackgroundRefresh(
                environment, extra: refreshArguments(options))
            if json {
                try emitJSON([
                    "upscale": true,
                    "background": true,
                    "log": environment.paths.upscaleRefreshLog.path,
                ], to: environment)
            } else {
                environment.output.out("upscale on: caching in the background")
                if !started, config.logLevel.showsWarnings {
                    environment.output.err(
                        "walle: a cache fill is already running or could not start; "
                        + "log: " + environment.paths.upscaleRefreshLog.path)
                }
            }
            return CLIExit.success.rawValue
        }

        let outputDir = UpscaleCache.root(paths: environment.paths,
                                          model: setup.modelName,
                                          target: setup.target)
        var cacheConfig = setup.config
        cacheConfig.upscale = true
        let settings = UpscaleSettings(
            target: setup.target, mode: .fill, maxScale: setup.maxScale,
            scaleOverride: setup.scaleOverride, model: setup.modelName,
            modelsDirectory: setup.modelsDirectory, tool: setup.tool,
            upscaler: setup.upscaler, quality: setup.quality, outputDir: outputDir,
            dryRun: dryRun, json: json, force: options.has("force"), cache: true,
            config: cacheConfig, environment: environment)
        let status = try runUpscaleLocked(scan.wallpapers, settings: settings,
                                          environment: environment)
        if status == CLIExit.success.rawValue, !dryRun {
            reapplyCachedCurrent(environment)
            consumePendingRefresh(environment)
        }
        return status
    }

    /// A change arrived while a fill was running. The fill leaves a marker, and
    /// this starts one more pass after the lock is released.
    private static func consumePendingRefresh(_ environment: CLIEnvironment) {
        let marker = environment.paths.upscalePendingRefresh
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        try? FileManager.default.removeItem(at: marker)
        let (config, _) = loadConfig(environment)
        guard config.upscale else { return }
        _ = startBackgroundRefresh(environment)
    }

    /// Start `walle upscale --refresh` detached. The CLI path is passed through
    /// WALLE_CLI so the child is found even from a Homebrew/keg relocation.
    @discardableResult
    private static func startBackgroundRefresh(
        _ environment: CLIEnvironment, extra: [String] = []
    ) -> Bool {
        var childEnvironment = environment.environment
        if childEnvironment["WALLE_CLI"] == nil,
           let argv0 = CommandLine.arguments.first {
            childEnvironment["WALLE_CLI"] = URL(fileURLWithPath: argv0)
                .resolvingSymlinksInPath().path
        }
        return UpscaleCache.refreshInBackground(
            paths: environment.paths, environment: childEnvironment,
            enabled: true, extraArguments: extra)
    }

    private static func refreshArguments(_ options: ParsedOptions) -> [String] {
        var arguments: [String] = []
        for name in ["target", "max-scale", "scale", "quality", "model",
                     "models", "tool", "upscaler"] {
            if let value = options.value(name) {
                arguments.append("--" + name)
                arguments.append(value)
            }
        }
        if options.has("force") { arguments.append("--force") }
        return arguments
    }

    /// After a fill, switch the currently displayed source to its cached copy
    /// without asking. Skipped if the picker is open or the desktop was changed
    /// outside walle.
    private static func reapplyCachedCurrent(_ environment: CLIEnvironment) {
        let (config, _) = loadConfig(environment)
        guard config.upscale else { return }
        guard !SingleInstance.isHeld(at: environment.paths.lockFile) else { return }
        let state = StateStore(fileURL: environment.paths.stateFile).load()
        guard let applied = state.lastAppliedPath else { return }
        let source = UpscaleCache.sourceForCurrent(
            paths: environment.paths, displayPath: applied) ?? applied
        guard FileManager.default.fileExists(atPath: source) else { return }
        guard let current = capturePicker(["--current"], environment),
              walleCanonicalPath(current) == walleCanonicalPath(source),
              let target = try? displayPixelSize(environment) else { return }
        let cache = UpscaleCache(paths: environment.paths,
                                 model: config.upscaleModel, target: target)
        guard let cached = cache.cachedURL(for: URL(fileURLWithPath: source)) else { return }
        if let lastDisplay = state.lastDisplayPath,
           walleCanonicalPath(lastDisplay) == walleCanonicalPath(cached.path) {
            return
        }
        environment.output.err("walle: applying the upscaled version of \(source)")
        _ = try? runPicker(["--apply", source], environment)
    }

    /// Prune without racing a running fill. The holder will prune when it
    /// finishes; this is for the empty-library / refresh path.
    private static func pruneCacheLocked(_ environment: CLIEnvironment) {
        guard let lock = SingleInstance.acquire(at: environment.paths.upscaleLockFile) else {
            return
        }
        defer { SingleInstance.release(lock) }
        UpscaleCache.pruneAll(paths: environment.paths)
    }

    private static func upscaleSetup(
        _ options: ParsedOptions, environment: CLIEnvironment,
        modeOverride: FillMode? = nil
    ) throws -> UpscaleSetup {
        let (config, warnings) = loadConfig(environment)
        reportWarnings(warnings, environment, config: config)

        let target = try upscaleTarget(options, environment: environment)
        let mode: FillMode
        if let modeOverride {
            mode = modeOverride
        } else {
            mode = try upscaleMode(options, config: config)
        }
        let maxScale = try upscaleDouble(options.value("max-scale"), name: "max-scale") ?? 4
        guard maxScale > 1 else { throw CLIError("--max-scale must be greater than 1") }
        let scaleOverride = try upscaleScale(options)
        let quality = try upscaleDouble(options.value("quality"), name: "quality") ?? 0.85
        guard (0...1).contains(quality) else {
            throw CLIError("--quality must be between 0 and 1")
        }

        let model = try upscaleModel(options, config: config, environment: environment)
        let tool = options.value("tool")
            ?? (config.upscaleTool.isEmpty ? nil : config.upscaleTool)
        let command = options.value("upscaler") ?? config.upscaleCommand
        guard let upscaler = UpscalerLocator.locate(
            command: command, environment: environment.environment) else {
            throw CLIError("could not find the upscaler '\(command)'; build walle-upscaler "
                           + "or set upscale_command / WALLE_UPSCALER")
        }

        return UpscaleSetup(
            config: config, target: target, mode: mode, maxScale: maxScale,
            scaleOverride: scaleOverride, quality: quality,
            modelName: model.name, modelsDirectory: model.directory,
            tool: tool, upscaler: upscaler)
    }

    private static func runUpscaleLocked(
        _ wallpapers: [Wallpaper], settings: UpscaleSettings,
        environment: CLIEnvironment
    ) throws -> Int32 {
        var lock: SingleInstance.Lock?
        if !settings.dryRun {
            guard let acquired = SingleInstance.acquire(at: environment.paths.upscaleLockFile) else {
                environment.output.err("walle: another upscale is already running")
                return CLIExit.alreadyRunning.rawValue
            }
            lock = acquired
            UpscaleCache.pruneAll(paths: environment.paths)
            do {
                try FileManager.default.createDirectory(at: settings.outputDir,
                                                        withIntermediateDirectories: true)
            } catch {
                SingleInstance.release(acquired)
                throw CLIError("could not create output directory "
                               + "\(settings.outputDir.path): \(error)")
            }
        }
        defer {
            if let lock { SingleInstance.release(lock) }
        }
        return try runUpscaleBatch(wallpapers, settings: settings)
    }

    static func upscaleTarget(_ options: ParsedOptions,
                              environment: CLIEnvironment) throws -> PixelSize {
        let raw = options.value("target") ?? "display"
        if raw.lowercased() == "display" { return try displayPixelSize(environment) }
        guard let size = PixelSize.parse(raw) else {
            throw CLIError("--target expects display or WxH, got '\(raw)'")
        }
        return size
    }

    static func displayPixelSize(_ environment: CLIEnvironment) throws -> PixelSize {
        guard let text = capturePicker(["--display-info"], environment),
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let screens = object["screens"] as? [[String: Any]],
              !screens.isEmpty else {
            throw CLIError("could not read the display size; pass --target WxH")
        }
        let active = screens.first { ($0["active"] as? Bool) == true } ?? screens[0]
        guard let width = active["pixelWidth"] as? Int,
              let height = active["pixelHeight"] as? Int else {
            throw CLIError("walle-picker --display-info did not report pixel dimensions")
        }
        return PixelSize(width: width, height: height)
    }

    static func upscaleMode(_ options: ParsedOptions, config: Config) throws -> FillMode {
        let raw = options.value("mode") ?? config.fillMode.rawValue
        guard let mode = FillMode.parse(raw) else {
            throw CLIError("--mode expects fill, fit, stretch or center, got '\(raw)'")
        }
        return mode
    }

    static func upscaleScale(_ options: ParsedOptions) throws -> Int? {
        guard let raw = options.value("scale") else { return nil }
        guard let value = Int(raw), [2, 3, 4].contains(value) else {
            throw CLIError("--scale expects 2, 3 or 4, got '\(raw)'")
        }
        return value
    }

    static func upscaleDouble(_ raw: String?, name: String) throws -> Double? {
        guard let raw else { return nil }
        guard let value = Double(raw), value.isFinite else {
            throw CLIError("--\(name) expects a number, got '\(raw)'")
        }
        return value
    }

    /// Resolves `--model`/`upscale_model`. The value may be a model name in the
    /// models directory, or a `.param` path whose `.bin` sits beside it.
    static func upscaleModel(
        _ options: ParsedOptions, config: Config, environment: CLIEnvironment
    ) throws -> (name: String, directory: URL?) {
        let raw = (options.value("model") ?? config.upscaleModel)
            .trimmingCharacters(in: .whitespaces)
        guard !raw.isEmpty else { throw CLIError("upscale model is empty") }

        var directory: URL?
        if let models = options.value("models"), !models.isEmpty {
            directory = walleExpand(models, home: environment.paths.home).standardizedFileURL
        } else if !config.upscaleModels.isEmpty {
            directory = walleExpand(config.upscaleModels,
                                    home: environment.paths.home).standardizedFileURL
        }

        var name = raw
        if raw.contains("/") || FileManager.default.fileExists(atPath: raw) {
            let url = walleExpand(raw, home: environment.paths.home).standardizedFileURL
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
                throw CLIError("model file does not exist: \(url.path)")
            }
            guard !isDirectory.boolValue else {
                throw CLIError("--model expects a model name or .param file, not a directory; "
                               + "use --models")
            }
            guard url.pathExtension.lowercased() == "param" else {
                throw CLIError("--model path must point at a .param file")
            }
            name = url.deletingPathExtension().lastPathComponent
            if directory == nil { directory = url.deletingLastPathComponent() }
        } else if name.hasSuffix(".param") {
            name = String(name.dropLast(6))
        }

        guard !name.isEmpty, !name.contains("/") else {
            throw CLIError("invalid model name '\(raw)'")
        }
        if let directory {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path,
                                                  isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw CLIError("models directory does not exist: \(directory.path)")
            }
        }
        return (name, directory)
    }

    static func upscaleOutputDirectory(_ options: ParsedOptions, target: PixelSize,
                                       model: String,
                                       environment: CLIEnvironment) -> URL {
        if let raw = options.value("output"), !raw.isEmpty {
            return walleExpand(raw, home: environment.paths.home).standardizedFileURL
        }
        return environment.paths.upscaledDir
            .appendingPathComponent("ml")
            .appendingPathComponent(walleSafeUpscaleModelName(model))
            .appendingPathComponent(target.description)
    }

    static func upscaleWallpapers(_ options: ParsedOptions, config: Config,
                                  environment: CLIEnvironment) throws -> [Wallpaper] {
        if !options.positionals.isEmpty {
            var seen = Set<String>()
            var result: [Wallpaper] = []
            for path in options.positionals {
                var isDirectory: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
                   isDirectory.boolValue {
                    throw CLIError("upscale takes image files, not directories; "
                                   + "use --dir \(path)")
                }
                let wallpaper: Wallpaper
                do {
                    wallpaper = try Selection.resolve(
                        .explicit(path), library: [], history: [],
                        currentPath: nil, seed: 0)
                } catch {
                    throw CLIError(String(describing: error))
                }
                let canonical = walleCanonicalPath(wallpaper.url.path)
                if seen.insert(canonical).inserted { result.append(wallpaper) }
            }
            return result
        }

        var scanConfig = config
        if !options.has("all") { scanConfig.wallpaperDirs = [] }
        let scan = LibraryScanner(config: scanConfig, home: environment.paths.home)
            .scan(extraDirs: options.all("dir"), includeAspectRatio: false)
        if config.logLevel.showsWarnings {
            for warning in scan.warnings {
                environment.output.err("walle: warning: " + warning)
            }
        }
        var seen = Set<String>()
        return scan.wallpapers.filter { seen.insert($0.path).inserted }
    }

    private static func runUpscaleBatch(_ wallpapers: [Wallpaper],
                                        settings: UpscaleSettings) throws -> Int32 {
        let outputDir = settings.outputDir
        let manifestURL = outputDir.appendingPathComponent("manifest.json")
        let previous = UpscaleManifest.load(from: manifestURL)
        var ownerByOutput: [String: String] = [:]
        for entry in previous.entries {
            ownerByOutput[entry.output.lowercased()] = entry.source
        }
        var usedNames = Set(previous.entries.map { $0.output.lowercased() })
        var processedSources = Set<String>()
        var kept: [UpscaleManifest.Entry] = []
        var results: [[String: Any]] = []
        var pending: [UpscalePending] = []
        var counts = (generated: 0, skipped: 0, failed: 0)

        for wallpaper in wallpapers {
            let sourcePath = walleCanonicalPath(wallpaper.url.path)
            processedSources.insert(sourcePath)
            do {
                let info = try UpscaleInspector.inspect(wallpaper.url)
                if let reason = UpscaleInspector.skipReason(for: info) {
                    counts.skipped += 1
                    results.append(upscaleSkipResult(source: sourcePath,
                                                     reason: reason.description))
                    reportUpscale(settings, "skipped \(wallpaper.name): " + reason.description,
                                  infoOnly: true)
                    continue
                }

                let plan: UpscalePlan
                switch UpscaleGeometry.plan(
                    sourceWidth: info.width, sourceHeight: info.height,
                    target: settings.target, mode: settings.mode,
                    maxScale: settings.maxScale,
                    scaleOverride: settings.scaleOverride) {
                case .success(let value): plan = value
                case .failure(let reason): throw reason
                }

                let existing = previous.entry(forSource: sourcePath)
                if !settings.force, let existing,
                   existing.matches(sourceInfo: info, plan: plan, mode: settings.mode,
                                    format: "heic", quality: settings.quality,
                                    model: settings.model,
                                    tool: settings.tool,
                                    modelsDirectory: settings.modelsDirectory?.path),
                   FileManager.default.fileExists(
                    atPath: outputDir.appendingPathComponent(existing.output).path) {
                    counts.skipped += 1
                    kept.append(existing)
                    results.append(upscaleEntryResult(
                        source: sourcePath,
                        output: outputDir.appendingPathComponent(existing.output),
                        entry: existing))
                    continue
                }

                let outputName = upscaleOutputName(
                    sourcePath: sourcePath, existing: existing,
                    ownerByOutput: ownerByOutput, used: &usedNames,
                    outputDir: outputDir, force: settings.force)
                pending.append(UpscalePending(
                    wallpaper: wallpaper, sourcePath: sourcePath,
                    output: outputDir.appendingPathComponent(outputName),
                    plan: plan, info: info))
            } catch let reason as UpscaleSkipReason {
                counts.skipped += 1
                results.append(upscaleSkipResult(source: sourcePath,
                                                 reason: reason.description))
                reportUpscale(settings, "skipped \(wallpaper.name): " + reason.description,
                              infoOnly: true)
            } catch {
                counts.failed += 1
                results.append(["source": sourcePath, "status": "failed",
                                "error": String(describing: error)])
                settings.environment.output.err(
                    "walle: \(sourcePath): \(String(describing: error))")
            }
        }

        if settings.dryRun {
            counts.generated = pending.count
            for item in pending {
                results.append(upscalePendingResult(item, status: "wouldGenerate"))
                let target = settings.cache ? item.output.lastPathComponent : item.output.path
                reportUpscale(settings, "would cache \(target)")
            }
            keepPrevious(previous, excluding: processedSources, from: outputDir, in: &kept)
            return try finishUpscale(settings, counts: counts, results: results)
        }

        if !pending.isEmpty {
            let executed = try executeUpscale(pending, settings: settings,
                                              kept: &kept, results: &results)
            counts.generated += executed.generated
            counts.failed += executed.failed
            counts.skipped += executed.skipped
        }
        keepPrevious(previous, excluding: processedSources, from: outputDir, in: &kept)
        if !settings.dryRun {
            var manifest = previous
            manifest.entries = kept.sorted { $0.source < $1.source }
            do {
                try manifest.save(to: manifestURL)
            } catch {
                settings.environment.output.err(
                    "walle: warning: could not write \(manifestURL.path): \(error)")
            }
        }
        return try finishUpscale(settings, counts: counts, results: results)
    }

    private static func executeUpscale(
        _ pending: [UpscalePending], settings: UpscaleSettings,
        kept: inout [UpscaleManifest.Entry],
        results: inout [[String: Any]]
    ) throws -> (generated: Int, skipped: Int, failed: Int) {
        let jobs = pending.map {
            UpscaleJobSpec.Item(source: $0.sourcePath, output: $0.output.path,
                                scale: $0.plan.outputScale)
        }
        let spec = UpscaleJobSpec(
            model: settings.model, modelsDirectory: settings.modelsDirectory?.path,
            tool: settings.tool, quality: settings.quality, format: "heic",
            target: settings.target, jobs: jobs)
        let jobURL = settings.outputDir
            .appendingPathComponent(".walle-job-\(UUID().uuidString).json")
        let resultURL = settings.outputDir
            .appendingPathComponent(".walle-result-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(at: jobURL)
            try? FileManager.default.removeItem(at: resultURL)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(spec).write(to: jobURL, options: .atomic)

        let run = runUpscaler(settings.upscaler, jobURL: jobURL,
                              resultURL: resultURL, environment: settings.environment)
        for line in run.output.split(separator: "\n", omittingEmptySubsequences: true) {
            settings.environment.output.err(String(line))
        }

        let moduleResult = try? JSONDecoder().decode(
            UpscaleJobResult.self, from: Data(contentsOf: resultURL))
        guard let moduleResult else {
            for item in pending {
                results.append(upscalePendingResult(
                    item, status: "failed",
                    error: "upscaler exited \(run.status) without a result file"))
            }
            settings.environment.output.err(
                "walle: the upscaler did not return a result; nothing was recorded")
            return (0, 0, pending.count)
        }

        var generated = 0
        var skipped = 0
        var failed = 0
        for item in pending {
            guard let answer = moduleResult.item(forOutput: item.output.path) else {
                failed += 1
                results.append(upscalePendingResult(
                    item, status: "failed", error: "upscaler returned no status"))
                continue
            }
            switch answer.status {
            case "ok":
                do {
                    let written = try UpscaleInspector.inspect(item.output)
                    let entry = UpscaleManifest.Entry(
                        source: item.sourcePath,
                        output: item.output.lastPathComponent,
                        plan: item.plan, mode: settings.mode, format: "heic",
                        quality: settings.quality, model: settings.model,
                        upscaler: settings.upscaler.path, tool: settings.tool,
                        modelsDirectory: settings.modelsDirectory?.path,
                        sourceMtime: item.info.modifiedAt,
                        sourceBytes: item.info.fileSize,
                        outputWidth: written.width, outputHeight: written.height)
                    kept.append(entry)
                    generated += 1
                    results.append(upscalePendingResult(
                        item, status: "generated",
                        width: written.width, height: written.height))
                    let location = settings.cache ? item.output.lastPathComponent
                                                  : item.output.path
                    reportUpscale(settings, "\(item.plan.outputScale)x  "
                                  + "\(written.width)x\(written.height)  "
                                  + "\(item.wallpaper.name)  \(location)")
                } catch {
                    failed += 1
                    results.append(upscalePendingResult(
                        item, status: "failed",
                        error: "output is unreadable: \(String(describing: error))"))
                }
            case "skipped":
                skipped += 1
                results.append(upscalePendingResult(
                    item, status: "skipped", reason: answer.error))
            default:
                failed += 1
                results.append(upscalePendingResult(
                    item, status: "failed",
                    error: answer.error ?? "upscaler failed"))
            }
        }
        return (generated, skipped, failed)
    }

    private static func runUpscaler(
        _ url: URL, jobURL: URL, resultURL: URL,
        environment: CLIEnvironment
    ) -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = url
        process.arguments = ["--job", jobURL.path, "--result", resultURL.path]
        process.environment = environment.environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (127, "could not run \(url.path): \(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func keepPrevious(
        _ previous: UpscaleManifest, excluding processed: Set<String>,
        from outputDir: URL, in kept: inout [UpscaleManifest.Entry]
    ) {
        for entry in previous.entries where !processed.contains(entry.source) {
            if FileManager.default.fileExists(
                atPath: outputDir.appendingPathComponent(entry.output).path) {
                kept.append(entry)
            }
        }
    }

    private static func finishUpscale(
        _ settings: UpscaleSettings, counts: (generated: Int, skipped: Int, failed: Int),
        results: [[String: Any]]
    ) throws -> Int32 {
        if settings.json {
            try emitJSON([
                "target": settings.target.description,
                "mode": settings.mode.rawValue,
                "format": "heic",
                "model": settings.model,
                "cache": settings.cache,
                "dryRun": settings.dryRun,
                "generated": counts.generated,
                "skipped": counts.skipped,
                "failed": counts.failed,
                "outputDir": settings.outputDir.path,
                "files": results,
            ], to: settings.environment)
        } else {
            let verb: String
            if settings.dryRun {
                verb = settings.cache ? "would cache" : "would generate"
            } else {
                verb = settings.cache ? "cached" : "generated"
            }
            settings.environment.output.out(
                "\(counts.generated) \(verb), \(counts.skipped) skipped, "
                    + "\(counts.failed) failed")
            settings.environment.output.out("model: \(settings.model)  "
                                            + "target: \(settings.target.description)")
            if settings.cache {
                settings.environment.output.out(
                    settings.dryRun ? "upscale: would be on" : "upscale: on")
                if settings.config.logLevel.showsInfo {
                    settings.environment.output.out("cache: \(settings.outputDir.path)")
                }
            } else {
                settings.environment.output.out("output: \(settings.outputDir.path)")
            }
        }
        return counts.failed == 0 ? CLIExit.success.rawValue : CLIExit.failure.rawValue
    }

    private static func reportUpscale(_ settings: UpscaleSettings, _ message: String,
                                      infoOnly: Bool = false) {
        let enabled = infoOnly ? settings.config.logLevel.showsInfo
                               : settings.config.logLevel.showsStatus
        guard !settings.json, enabled else { return }
        settings.environment.output.err(message)
    }

    private static func upscaleOutputName(
        sourcePath: String, existing: UpscaleManifest.Entry?,
        ownerByOutput: [String: String], used: inout Set<String>,
        outputDir: URL, force: Bool
    ) -> String {
        if let existing, existing.output.lowercased().hasSuffix(".heic"),
           ownerByOutput[existing.output.lowercased()] == sourcePath {
            return existing.output
        }

        let base = URL(fileURLWithPath: sourcePath).deletingPathExtension().lastPathComponent
        var candidate = base + ".heic"
        var attempt = 0
        while used.contains(candidate.lowercased())
            || (!force && FileManager.default.fileExists(
                atPath: outputDir.appendingPathComponent(candidate).path)) {
            attempt += 1
            let suffix = attempt == 1
                ? walleUpscaleNameSuffix(for: sourcePath)
                : walleUpscaleNameSuffix(for: sourcePath) + "-" + String(attempt)
            candidate = base + "-" + suffix + ".heic"
            if attempt > 100 { break }
        }
        used.insert(candidate.lowercased())
        return candidate
    }

    private static func upscaleSkipResult(source: String, reason: String) -> [String: Any] {
        ["source": source, "status": "skipped", "reason": reason]
    }

    private static func upscaleEntryResult(source: String, output: URL,
                                           entry: UpscaleManifest.Entry) -> [String: Any] {
        [
            "source": source,
            "output": output.path,
            "status": "skipped",
            "width": entry.outputWidth,
            "height": entry.outputHeight,
            "scale": Int(entry.scale),
        ]
    }

    private static func upscalePendingResult(
        _ item: UpscalePending, status: String, width: Int? = nil,
        height: Int? = nil, error: String? = nil, reason: String? = nil
    ) -> [String: Any] {
        var object: [String: Any] = [
            "source": item.sourcePath,
            "output": item.output.path,
            "status": status,
            "scale": item.plan.outputScale,
            "requiredScale": item.plan.requiredScale,
            "width": width ?? item.info.width * item.plan.outputScale,
            "height": height ?? item.info.height * item.plan.outputScale,
        ]
        if let error { object["error"] = error }
        if let reason { object["reason"] = reason }
        return object
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

    /// Checks the whole chain: config, library, picker binary, thumbnail cache at the size the
    /// picker will really request, history, the Spaces store and the hotkey. Everything it
    /// reports is something that has actually gone wrong for someone at least once.
    static func doctor(_ tokens: [String], environment: CLIEnvironment) throws -> Int32 {
        let options = try OptionParser.parse(
            tokens, spec: OptionSpec(boolOptions: ["json"],
                                     shortAliases: ["j": "json", "h": "help"]))
        if options.has("help") { return help(environment) }

        let fm = FileManager.default
        var checks: [(name: String, ok: Bool, detail: String)] = []
        // Config parse and sanitize warnings are advisory: a stale or mistyped line still
        // leaves a working config, so it must not make doctor report a failure. Real
        // problems (no library, no picker, no hotkey) stay in `checks` and are counted.
        var notes: [String] = []

        // Config
        let configPath = environment.paths.configFile.path
        let configExists = fm.fileExists(atPath: configPath)
        let (config, configWarnings) = loadConfig(environment)
        checks.append(("config file", true,
                       configExists ? configPath : configPath + " (absent, defaults in use)"))
        notes.append(contentsOf: configWarnings.map { "config warning: " + $0 })

        // Library
        checks.append(("wallpaper dirs", !config.wallpaperDirs.isEmpty,
                       config.wallpaperDirs.joined(separator: ", ")))
        let scan = LibraryScanner(config: config, home: environment.paths.home).scan()
        checks.append(("wallpapers", !scan.wallpapers.isEmpty,
                       String(scan.wallpapers.count) + " image"
                       + (scan.wallpapers.count == 1 ? "" : "s")))
        for warning in scan.warnings { checks.append(("library warning", false, warning)) }

        // The binary everything with a window is delegated to.
        let pickerPath = PickerLocator.locate(environment: environment.environment)
        if let pickerPath {
            checks.append(("walle-picker", true, pickerPath.path))
        } else {
            checks.append(("walle-picker", false,
                           "not found; set WALLE_PICKER or run ./scripts/install.sh"))
        }

        // Thumbnail cache, checked against the size the picker will actually request. A
        // directory full of thumbnails built for an older display looks healthy if only its
        // byte count is reported, and the symptom is soft cards.
        let thumbnailsDir = environment.paths.thumbnailsDir
        if pickerPath != nil, !scan.wallpapers.isEmpty,
           let answer = capturePicker(
             ["--thumb-size", "--widest-aspect",
              String(walleWidestAspect(scan.wallpapers))], environment),
           let pixels = Int(answer) {
            let cache = ThumbnailCache(directory: thumbnailsDir, maxPx: pixels)
            let cached = scan.wallpapers.filter { cache.existingThumbnail(for: $0) != nil }.count
            let total = scan.wallpapers.count
            let bytes = cache.cacheSizeBytes()
            if cached == total {
                checks.append(("thumbnail cache", true,
                               "\(cached)/\(total) at \(pixels) px, \(bytes) bytes"))
            } else if cached > 0 {
                checks.append(("thumbnail cache", true,
                               "\(cached)/\(total) at \(pixels) px, \(bytes) bytes"))
                notes.append("thumbnail cache is missing \(total - cached) of \(total) "
                             + "thumbnails; run 'walle cache'")
            } else {
                checks.append(("thumbnail cache", false,
                               "none of \(total) thumbnails cached at \(pixels) px; "
                               + "run 'walle cache'"))
            }
        } else {
            // Picker unavailable, or no library to size against: report raw size as before.
            let cache = ThumbnailCache(directory: thumbnailsDir, maxPx: config.thumbMaxPx)
            let cacheBytes = cache.cacheSizeBytes()
            checks.append(("thumbnail cache", cacheBytes > 0 || scan.wallpapers.isEmpty,
                           String(cacheBytes) + " bytes in " + thumbnailsDir.path
                           + (cacheBytes > 0 ? "" : " (run walle cache)")))
            if pickerPath != nil, !scan.wallpapers.isEmpty {
                notes.append("could not ask walle-picker for the thumbnail size; "
                             + "cache coverage was not checked")
            }
        }

        // History and state
        let historyURL = environment.paths.historyFile
        let entries = (try? HistoryStore(fileURL: historyURL).entries(limit: 1)) ?? []
        checks.append(("history", true,
                       entries.isEmpty ? "empty (" + historyURL.path + ")"
                                       : "latest " + entries[0].path))

        // Spaces and the private wallpaper store. This is the state the every-Space sync
        // writes, so doctor should say whether it is usable before an apply tries to use it.
        checks.append(("spaces", true,
                       config.spaces == .all
                       ? "on  - every apply is copied onto every Space"
                       : "off - only the Space you are on changes"))
        let storeURL = WallpaperStore.indexURL(environment: environment.environment)
        if let override = environment.environment["WALLE_WALLPAPER_STORE"], !override.isEmpty {
            // An override deliberately targets a copy: the live store is not touched and
            // WallpaperAgent is not restarted. Say so, or the rest of this report misleads.
            let readable = (try? WallpaperStore.spaces(at: storeURL)) != nil
            checks.append(("wallpaper store", readable,
                           readable ? "test override: " + override
                                    : "test override is not a readable store: " + override))
        } else {
            do {
                let summaries = try WallpaperStore.spaces(at: storeURL)
                let inventory = WallpaperStore.spaceInventory()
                var detail = String(summaries.count) + " entries"
                if inventory.isKnown {
                    detail += ", " + String(inventory.switchable.count) + " switchable, "
                        + String(inventory.collapsed.count) + " collapsed"
                    let stale = Set(summaries.map(\.key)).subtracting(inventory.all)
                    if !stale.isEmpty {
                        detail += ", " + String(stale.count)
                            + " stale (run 'walle spaces all --prune')"
                    }
                } else {
                    detail += ", could not read com.apple.spaces"
                }
                checks.append(("wallpaper store", true, detail))
            } catch {
                // With the every-Space sync off, an unreadable store only affects
                // 'walle spaces'; with it on, this is why an apply would report a warning.
                checks.append(("wallpaper store", config.spaces == .all,
                               String(describing: error)
                               + (config.spaces == .all ? "; every-Space sync will fail" : "")))
            }
        }

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
            let bindings = text.split(separator: "\n").filter { line in
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                return !trimmed.isEmpty && !trimmed.hasPrefix("#") && trimmed.contains("walle")
            }
            if bindings.isEmpty {
                checks.append(("skhd binding", false, "no line mentioning walle in " + rcPath))
            } else if bindings.count > 1 {
                // Two bindings mean the hotkey fires walle twice. The second instance sees
                // the lock held and signals the first to close, so the picker flashes and
                // vanishes.
                checks.append(("skhd binding", false,
                               String(bindings.count) + " duplicate bindings in " + rcPath
                               + "; keep exactly one"))
            } else {
                checks.append(("skhd binding", true, "found in " + rcPath))
            }
        } else {
            checks.append(("skhd binding", false, "no " + rcPath))
        }

        // Accessibility is granted to skhd, not to us, so it cannot be queried directly.
        // But skhd says so in its own log and then aborts, and launchd restarts it, so the
        // log is a reliable proxy and far more useful than a shrug.
        let skhdErrLog = "/tmp/skhd_" + environment.paths.home.lastPathComponent + ".err.log"
        if let data = fm.contents(atPath: skhdErrLog),
           let text = String(data: data, encoding: .utf8) {
            // Only the most recent line counts. The log is append-only and never rotated, so a
            // complaint from before the permission was granted would otherwise fail this check
            // forever — which is exactly what happened the first time. A skhd that is actually
            // broken is crash-looping, and writes the complaint on every restart, so it is
            // always the last thing in the file when it is genuinely broken.
            let lastLine = text.split(separator: "\n")
                .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .map(String.init) ?? ""
            if lastLine.lowercased().contains("accessibility") {
                checks.append(("skhd accessibility", false,
                               "skhd is aborting for lack of Accessibility access (see "
                               + skhdErrLog + "); grant it in System Settings > Privacy & "
                               + "Security > Accessibility, then restart skhd"))
            } else {
                checks.append(("skhd accessibility", true,
                               "skhd is not complaining; its last log line is unrelated"))
            }
        } else {
            checks.append(("skhd accessibility", true,
                           "no skhd log yet (grant it in System Settings if the hotkey does nothing)"))
        }

        let failures = checks.filter { !$0.ok }.count
        if options.has("json") {
            try emitJSON([
                "ok": failures == 0,
                "failures": failures,
                "checks": checks.map { ["name": $0.name, "ok": $0.ok, "detail": $0.detail] },
                "warnings": notes,
            ], to: environment)
        } else {
            for check in checks {
                environment.output.out((check.ok ? "  ok  " : " fail ") + check.name
                                       + "  " + check.detail)
            }
            for note in notes { environment.output.out(" warn " + note) }
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

        // Ask the picker what size it will really request for this display and library. The
        // picker derives a floor from the card geometry, so without asking it the cache would
        // build a different size, the keys would not match, and the picker would regenerate
        // everything on first open. That is why keeping thumb_max_px in step by hand was
        // ever necessary, and this is what makes it unnecessary.
        var thumbPixels = config.thumbMaxPx
        // The picker applies the display's geometric floor. Hand it the widest aspect we
        // already measured, so building the cache does not scan the library a second time.
        let widestAspect = walleWidestAspect(scan.wallpapers)
        if let answer = capturePicker(["--thumb-size", "--widest-aspect", String(widestAspect)],
                                      environment),
           let parsed = Int(answer) {
            thumbPixels = parsed
        }
        let cache = ThumbnailCache(directory: cacheDir, maxPx: thumbPixels)
        if config.logLevel.showsInfo {
            environment.output.err("walle: building thumbnails at \(thumbPixels) px for "
                                   + "\(scan.wallpapers.count) wallpapers")
        }

        let started = Date()
        // One thumbnail per wallpaper: the picker uses a single size for every card.
        // The batch runs concurrently and returns outcomes in library order, so the
        // summary and failure list stay deterministic.
        let outcomes = cache.ensureThumbnails(for: scan.wallpapers)
        var generated = 0
        var failed = 0
        var failures: [String] = []
        for (wallpaper, outcome) in zip(scan.wallpapers, outcomes) {
            switch outcome {
            case .existing:
                break
            case .generated:
                generated += 1
            case .failed(let error):
                failed += 1
                failures.append(wallpaper.name + ": " + String(describing: error))
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
        try clean.save(to: environment.paths.configFile, updating: [key])
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
        try config.save(to: environment.paths.configFile, updating: [key])
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
