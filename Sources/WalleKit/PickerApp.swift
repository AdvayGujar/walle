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
    private let runForMs: Int
    private let launchedAt: Date

    private var window: PickerWindow?
    private var corridor: CorridorView?
    private var keyMonitor: Any?

    public init(config: Config, paths: WallePaths, library: [Wallpaper],
                focusIndex: Int, currentPath: String?, startsExpanded: Bool,
                runForMs: Int = 0, launchedAt: Date = Date()) {
        self.config = config
        self.paths = paths
        self.library = library
        self.focusIndex = focusIndex
        self.currentPath = currentPath
        self.startsExpanded = startsExpanded
        self.runForMs = runForMs
        self.launchedAt = launchedAt
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

        // Never use a thumbnail smaller than the cards need. A config written by an older
        // build can pin a value that was correct for the old card size, and the symptom is
        // only slightly soft images, which is very hard to attribute.
        let widestAspect = walleWidestAspect(library)
        let geometry = LayoutEngine(
            config: config,
            screen: ScreenMetrics(width: Double(screen.frame.width),
                                  height: Double(screen.frame.height)),
            transition: 0)
        let required = geometry.minimumThumbnailPixels(
            backingScale: Double(screen.backingScaleFactor),
            widestAspect: widestAspect)
        let thumbPixels = max(config.thumbMaxPx, required)
        if thumbPixels > config.thumbMaxPx, config.logLevel.showsWarnings {
            FileHandle.standardError.write(Data(
                ("walle-picker: thumb_max_px is " + String(config.thumbMaxPx)
                 + " but these cards need " + String(required)
                 + " on this display; using " + String(thumbPixels)
                 + ". Run 'walle config set thumb_max_px " + String(required)
                 + "' and 'walle cache --rebuild' to match.\n").utf8))
        }

        let provider = ThumbnailProvider(
            cache: ThumbnailCache(directory: paths.thumbnailsDir, maxPx: thumbPixels),
            maxPx: thumbPixels,
            imageBudget: config.slots + 2)

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
        // The picker must take keyboard focus immediately, because the whole interaction is
        // keyboard driven. Previously it only became the key window once it had been
        // clicked, which is why arrow keys did nothing before a click.
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.orderFrontRegardless()
        window.makeKey()

        self.window = window
        self.corridor = view

        // WALLE_TRACE reports how long the process took to get a window on screen, which is
        // the cold-start number the performance budget is stated in.
        if ProcessInfo.processInfo.environment["WALLE_TRACE"] != nil {
            let elapsed = Date().timeIntervalSince(launchedAt) * 1000
            FileHandle.standardError.write(Data(
                ("walle-picker: window up after " + String(format: "%.1f", elapsed) + "ms\n").utf8))
        }

        // --run-for exists so cold start and peak memory can be measured without a human.
        if runForMs > 0 {
            let delay = Double(runForMs) / 1000.0
            Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in exit(0) }
        }

        // Keyboard only. Handling keys here rather than on the view means they work no
        // matter which view happens to be first responder. Returning nil consumes the event.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [view] event in
            switch event.keyCode {
            case 53:                                    // escape        - dismiss
                exit(2)
            case 123, 126:                              // left, up      - move
                view.rotate(-1)
                return nil
            case 124, 125:                              // right, down   - move
                view.rotate(1)
                return nil
            case 49:                                    // space         - expand/collapse
                view.toggleExpanded()
                return nil
            case 36, 76:                                // return, enter - apply
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
                           startsExpanded: Bool, runForMs: Int = 0,
                           launchedAt: Date = Date()) -> Never {
        let application = NSApplication.shared
        let controller = PickerController(config: config, paths: paths, library: library,
                                          focusIndex: focusIndex, currentPath: currentPath,
                                          startsExpanded: startsExpanded,
                                          runForMs: runForMs, launchedAt: launchedAt)
        application.delegate = controller
        application.run()
        exit(0)
    }
}
