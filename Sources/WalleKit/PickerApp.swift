import AppKit
import WalleCore
import WalleKit

/// Owns the interactive picker session.
///
/// M4 renders the corridor and lets Escape dismiss it. Hover, the keyboard and
/// apply-on-click arrive in M5.
@MainActor
public final class PickerController: NSObject, NSApplicationDelegate {

    private let config: Config
    private let paths: WallePaths
    private let library: [Wallpaper]
    private let focusIndex: Int
    private let currentPath: String?
    private let startsExpanded: Bool

    private var window: PickerWindow?
    private var corridor: CorridorView?
    private var keyMonitor: Any?

    public init(config: Config, paths: WallePaths, library: [Wallpaper],
                focusIndex: Int, currentPath: String?, startsExpanded: Bool) {
        self.config = config
        self.paths = paths
        self.library = library
        self.focusIndex = focusIndex
        self.currentPath = currentPath
        self.startsExpanded = startsExpanded
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        // Accessory: no Dock icon, no menu bar, but the window can still take focus.
        NSApp.setActivationPolicy(.accessory)

        guard let screen = activeScreen() ?? NSScreen.screens.first else {
            FileHandle.standardError.write(Data("walle-picker: no screen available\n".utf8))
            exit(1)
        }

        let window = PickerWindow.make(screen: screen, config: config)
        let provider = ThumbnailProvider(
            cache: ThumbnailCache(directory: paths.thumbnailsDir,
                                  rowMaxPx: config.thumbMaxPx,
                                  previewMaxPx: config.previewMaxPx),
            rowMaxPx: config.thumbMaxPx,
            previewMaxPx: config.previewMaxPx)

        let contentFrame = CGRect(origin: .zero, size: screen.frame.size)
        let view = CorridorView(frame: contentFrame, config: config, provider: provider,
                                currentPath: currentPath,
                                transition: startsExpanded ? 1 : 0)
        view.reload(library: library, focus: focusIndex)

        let setter = NSWorkspaceSetter()
        let applyPaths = paths
        let applyTo = config.applyTo
        let fillMode = config.fillMode

        view.onApply = { wallpaper in
            do {
                try setter.setWallpaper(at: wallpaper.url, target: applyTo,
                                        fillMode: fillMode)
            } catch {
                FileHandle.standardError.write(
                    Data(("walle-picker: " + String(describing: error) + "\n").utf8))
                exit(1)
            }
            // Recording happens only after the desktop actually changed, and a failure
            // here is reported rather than swallowed.
            for warning in walleRecordApplied(path: wallpaper.path, paths: applyPaths,
                                              mode: "picker") {
                FileHandle.standardError.write(
                    Data(("walle-picker: warning: " + warning + "\n").utf8))
            }
            exit(0)
        }
        view.onDismiss = { exit(2) }

        window.contentView = view
        window.makeFirstResponder(view)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        self.window = window
        self.corridor = view

        // Keys are handled here rather than on the view, so they work no matter which view
        // happens to be first responder. Returning nil consumes the event.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [view] event in
            switch event.keyCode {
            case 53:                                    // escape
                exit(2)
            case 123, 126:                              // left, up
                view.rotate(-1)
                return nil
            case 124, 125:                              // right, down
                view.rotate(1)
                return nil
            case 36, 49:                                // return, space
                view.applyFocused()
                return nil
            default:
                return event
            }
        }
    }

    public func applicationWillTerminate(_ notification: Notification) {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    private func activeScreen() -> NSScreen? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(location) } ?? NSScreen.main
    }
}

public enum PickerApp {
    /// Runs the picker to completion and exits the process.
    @MainActor
    public static func run(config: Config, paths: WallePaths, library: [Wallpaper],
                           focusIndex: Int, currentPath: String?,
                           startsExpanded: Bool) -> Never {
        let application = NSApplication.shared
        let controller = PickerController(config: config, paths: paths, library: library,
                                          focusIndex: focusIndex, currentPath: currentPath,
                                          startsExpanded: startsExpanded)
        application.delegate = controller
        application.run()
        exit(0)
    }
}
