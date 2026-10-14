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
        let history = HistoryStore(fileURL: paths.historyFile)
        let stateStore = StateStore(fileURL: paths.stateFile)
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
            // History is written only after the desktop actually changed.
            try? history.append(HistoryEntry(path: wallpaper.path, appliedAt: Date(),
                                             screenUUID: nil, mode: "picker"))
            var state = stateStore.load()
            state.lastAppliedPath = wallpaper.path
            try? stateStore.save(state)
            exit(0)
        }
        view.onDismiss = { exit(2) }

        window.contentView = view
        window.makeFirstResponder(view)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        self.window = window
        self.corridor = view

        // Escape dismisses with no change.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                exit(0)
            }
            return event
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
