import Foundation

/// The one thing that actually changes the desktop. It is a protocol so the CLI and
/// the selection logic can be tested without touching a real wallpaper.
public protocol WallpaperSetter: Sendable {
    func setWallpaper(at url: URL, target: ApplyTarget, fillMode: FillMode) throws
}

public enum SetterError: Error, CustomStringConvertible {
    case noScreens
    case screensFailed([String])
    case fileMissing(String)

    public var description: String {
        switch self {
        case .noScreens:
            return "no screens reported by the window server"
        case .screensFailed(let failures):
            return "could not set the wallpaper: " + failures.joined(separator: "; ")
        case .fileMissing(let path):
            return "file does not exist: " + path
        }
    }
}

/// Used by --dry-run: validates and reports without changing anything.
public struct DryRunSetter: WallpaperSetter {
    public init() {}
    public func setWallpaper(at url: URL, target: ApplyTarget, fillMode: FillMode) throws {}
}
