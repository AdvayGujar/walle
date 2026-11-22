import Foundation

/// Finds the `walle` CLI from inside the picker, so the picker can start a
/// cache refresh for new images. The CLI normally passes its own path in
/// `WALLE_CLI`; these are the fallbacks for direct `walle-picker` launches.
public enum CLILocator {
    public static let binaryName = "walle"

    public static func locate(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> URL? {
        let home = fileManager.homeDirectoryForCurrentUser
        if let raw = environment["WALLE_CLI"], !raw.isEmpty {
            let url = walleExpand(raw, home: home).standardizedFileURL
            if fileManager.isExecutableFile(atPath: url.path) { return url }
        }

        var candidates: [URL] = []
        let bundle = Bundle.main.bundleURL
        // Installed layout: PREFIX/Walle.app and PREFIX/bin/walle.
        candidates.append(bundle.deletingLastPathComponent()
            .appendingPathComponent("bin/" + binaryName))
        if let executable = Bundle.main.executableURL {
            let directory = executable.resolvingSymlinksInPath().deletingLastPathComponent()
            candidates.append(directory.appendingPathComponent(binaryName))
        }
        let cwd = URL(fileURLWithPath: fileManager.currentDirectoryPath)
        candidates.append(cwd.appendingPathComponent(".build/scratch/release/" + binaryName))
        candidates.append(cwd.appendingPathComponent(".build/scratch/debug/" + binaryName))
        candidates.append(home.appendingPathComponent(".local/bin/" + binaryName))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/" + binaryName))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/" + binaryName))
        if let found = candidates.first(where: {
            fileManager.isExecutableFile(atPath: $0.path)
        }) {
            return found
        }

        for directory in (environment["PATH"] ?? "").split(separator: ":") {
            let candidate = URL(fileURLWithPath: String(directory))
                .appendingPathComponent(binaryName)
            if fileManager.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return nil
    }
}
