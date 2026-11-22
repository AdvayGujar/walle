import Foundation

/// Finds the replaceable ML upscaler executable.
///
/// The default name is `walle-upscaler`, but `upscale_command` / `--upscaler`
/// can point at any executable that implements the job/result contract. Keeping
/// this lookup here means the rest of the CLI never needs to know which ML
/// backend is installed.
public enum UpscalerLocator {
    public static let defaultName = "walle-upscaler"

    public static func locate(
        command: String = defaultName,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        argv0: String? = nil,
        fileManager: FileManager = .default
    ) -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed.contains("/") {
            let expanded = walleExpand(trimmed, home: home).standardizedFileURL
            return fileManager.isExecutableFile(atPath: expanded.path) ? expanded : nil
        }

        if let override = environment["WALLE_UPSCALER"], !override.isEmpty {
            let expanded = walleExpand(override, home: home).standardizedFileURL
            if fileManager.isExecutableFile(atPath: expanded.path) { return expanded }
        }

        var candidates: [URL] = []
        let executable = argv0 ?? CommandLine.arguments.first ?? ""
        if !executable.isEmpty {
            let resolved = URL(fileURLWithPath: executable).resolvingSymlinksInPath()
            let directory = resolved.deletingLastPathComponent()
            // Beside the CLI, which is how dist/bin and the development build are laid out.
            candidates.append(directory.appendingPathComponent(trimmed))
            // Installed layout: PREFIX/bin/walle with PREFIX/Walle.app next to it.
            candidates.append(directory.deletingLastPathComponent()
                .appendingPathComponent("Walle.app/Contents/MacOS/" + trimmed))
            candidates.append(directory.appendingPathComponent(
                "Walle.app/Contents/MacOS/" + trimmed))
        }
        if let bundleExecutable = Bundle.main.executableURL {
            candidates.append(bundleExecutable.resolvingSymlinksInPath()
                .deletingLastPathComponent()
                .appendingPathComponent(trimmed))
        }
        candidates.append(home.appendingPathComponent(
            ".local/share/walle/Walle.app/Contents/MacOS/" + trimmed))
        candidates.append(home.appendingPathComponent(
            "Applications/Walle.app/Contents/MacOS/" + trimmed))
        candidates.append(URL(fileURLWithPath: "/Applications/Walle.app/Contents/MacOS/" + trimmed))

        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent(".build/scratch/release/" + trimmed))
        candidates.append(cwd.appendingPathComponent(".build/scratch/debug/" + trimmed))
        if let found = candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
            return found
        }

        // PATH last, so an installed/development sibling wins over a stray copy.
        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(trimmed)
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
