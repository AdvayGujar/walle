import AppKit
import WalleCore

/// Applies a wallpaper through the public AppKit API, which writes the system wallpaper
/// store and therefore survives reboot and Space switches.
public struct NSWorkspaceSetter: WallpaperSetter {
    public init() {}

    public func setWallpaper(at url: URL, target: ApplyTarget, fillMode: FillMode) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw SetterError.fileMissing(url.path)
        }

        let screens = try targetScreens(target)
        let options = desktopOptions(for: fillMode)

        var failures: [String] = []
        for screen in screens {
            do {
                try NSWorkspace.shared.setDesktopImageURL(url, for: screen, options: options)
            } catch {
                failures.append(error.localizedDescription)
            }
        }
        if !failures.isEmpty { throw SetterError.screensFailed(failures) }
    }

    /// The screen currently under the pointer, which is what "apply to active" should mean
    /// for a hotkey-driven tool.
    public func activeScreen() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main
    }

    public func currentWallpaperURL() -> URL? {
        guard let screen = activeScreen() ?? NSScreen.screens.first else { return nil }
        return NSWorkspace.shared.desktopImageURL(for: screen)
    }

    private func targetScreens(_ target: ApplyTarget) throws -> [NSScreen] {
        switch target {
        case .all:
            let screens = NSScreen.screens
            if screens.isEmpty { throw SetterError.noScreens }
            return screens
        case .active:
            if let screen = activeScreen() { return [screen] }
            let screens = NSScreen.screens
            if screens.isEmpty { throw SetterError.noScreens }
            return [screens[0]]
        }
    }

    /// The desktop scaling key takes an NSNumber wrapping an NSImageScaling, and
    /// "fill" versus "fit" comes from the scaling type combined with allowClipping:
    /// proportional with clipping fills the screen and crops, proportional without
    /// clipping shows the whole image with empty space around it.
    private func desktopOptions(
        for fillMode: FillMode
    ) -> [NSWorkspace.DesktopImageOptionKey: Any] {
        func scaling(_ value: NSImageScaling) -> NSNumber {
            NSNumber(value: value.rawValue)
        }
        switch fillMode {
        case .fill:
            return [.imageScaling: scaling(.scaleProportionallyUpOrDown),
                    .allowClipping: true]
        case .fit:
            return [.imageScaling: scaling(.scaleProportionallyUpOrDown),
                    .allowClipping: false]
        case .stretch:
            return [.imageScaling: scaling(.scaleAxesIndependently),
                    .allowClipping: true]
        case .center:
            return [.imageScaling: scaling(.scaleNone),
                    .allowClipping: false]
        }
    }
}
