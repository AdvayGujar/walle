import AppKit
import WalleCore

/// The borderless overlay that hosts the corridor.
///
/// A borderless NSWindow refuses key status by default, which is the classic reason a
/// tool like this appears on screen but ignores the keyboard. Overriding canBecomeKey
/// is the entire fix.
public final class PickerWindow: NSWindow {

    public override var canBecomeKey: Bool { true }
    public override var canBecomeMain: Bool { true }

    public static func make(screen: NSScreen, config: Config) -> PickerWindow {
        let window = PickerWindow(contentRect: screen.frame,
                                  styleMask: [.borderless],
                                  backing: .buffered,
                                  defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.isReleasedWhenClosed = false
        return window
    }
}
