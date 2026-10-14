import Foundation

/// Finds the walle-picker binary.
///
/// walle deliberately does not link AppKit: applying a wallpaper needs NSWorkspace, so
/// the CLI hands that job to walle-picker. The cost is one exec, which is nothing
/// compared with loading AppKit into the CLI process as well.
public enum PickerLocator {
    public static let binaryName = "walle-picker"

    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment,
                              argv0: String? = nil,
                              fileManager: FileManager = .default) -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser
        var candidates: [URL] = []

        if let override = environment["WALLE_PICKER"], !override.isEmpty {
            candidates.append(walleExpand(override, home: home))
        }

        let executable = argv0 ?? CommandLine.arguments.first ?? ""
        if !executable.isEmpty {
            let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
            candidates.append(resolved.deletingLastPathComponent()
                .appendingPathComponent(binaryName))
        }
        if let bundleExecutable = Bundle.main.executableURL {
            candidates.append(bundleExecutable.resolvingSymlinksInPath()
                .deletingLastPathComponent()
                .appendingPathComponent(binaryName))
        }

        candidates.append(home.appendingPathComponent(
            ".local/share/walle/Walle.app/Contents/MacOS/" + binaryName))
        candidates.append(home.appendingPathComponent(
            "Applications/Walle.app/Contents/MacOS/" + binaryName))
        candidates.append(URL(fileURLWithPath: "/Applications/Walle.app/Contents/MacOS/" + binaryName))

        // Development convenience: a repo-local build, release preferred over debug.
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent(".build/scratch/release/" + binaryName))
        candidates.append(cwd.appendingPathComponent(".build/scratch/debug/" + binaryName))

        return candidates.first { fileManager.isExecutableFile(atPath: $0.path) }
    }
}
