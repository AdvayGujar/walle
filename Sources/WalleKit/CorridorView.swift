import AppKit
import CoreGraphics
import ImageIO
import QuartzCore
import WalleCore

public enum SnapshotError: Error, CustomStringConvertible {
    case contextCreationFailed
    case renderFailed
    case writeFailed(String)

    public var description: String {
        switch self {
        case .contextCreationFailed: return "could not create a bitmap context"
        case .renderFailed: return "could not render the corridor into an image"
        case .writeFailed(let path): return "could not write " + path
        }
    }
}

/// The card row.
///
/// All geometry comes from LayoutEngine as a function of a single transition value, so
/// this class only owns the layer pool, the thumbnails, the paint order and the clock that
/// advances the transition. Because the animation is just that one number, a snapshot at
/// any point of the transition shows exactly what the animation will render.
public final class CorridorView: NSView {

    private var config: Config
    private var screenMetrics: ScreenMetrics
    private var provider: ThumbnailProvider
    private var currentPath: String?

    private var library: [Wallpaper] = []
    private var focus: Int = 0
    private var transition: Double = 1

    private var cards: [CardLayer] = []
    private let backdrop = CALayer()
    private let debugColours: Bool

    private var animationTimer: Timer?
    private var animationStart: CFTimeInterval = 0
    private var animationFrom: Double = 0
    private var animationTo: Double = 1

    public init(frame: NSRect, config: Config, provider: ThumbnailProvider,
                currentPath: String?, transition: Double = 1,
                debugColours: Bool = false) {
        self.config = config
        self.screenMetrics = ScreenMetrics(width: Double(frame.width),
                                           height: Double(frame.height))
        self.provider = provider
        self.currentPath = currentPath
        self.transition = min(1, max(0, transition))
        self.debugColours = debugColours
        super.init(frame: frame)
        wantsLayer = true
        backdrop.backgroundColor = NSColor.black
            .withAlphaComponent(config.dimAlpha).cgColor
        backdrop.zPosition = -1000
        layer?.addSublayer(backdrop)
    }

    required init?(coder: NSCoder) { fatalError("CorridorView is created in code only") }

    public override var isFlipped: Bool { false }
    public override var acceptsFirstResponder: Bool { true }

    public var currentTransition: Double { transition }

    public func reload(library: [Wallpaper], focus: Int) {
        self.library = library
        self.focus = library.isEmpty ? 0 : Queue.wrapIndex(focus, count: library.count)
        rebuildCards(reloadContents: true)
    }

    /// Sets the morph position. Animated runs an ease-out over config.animationMs,
    /// advancing the single transition value the geometry is derived from.
    public func setTransition(_ target: Double, animated: Bool) {
        let target = min(1, max(0, target))
        animationTimer?.invalidate()
        animationTimer = nil

        guard animated, config.animationMs > 0, abs(target - transition) > 0.0001 else {
            transition = target
            rebuildCards(reloadContents: false)
            return
        }

        animationFrom = transition
        animationTo = target
        animationStart = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsedMs = (CACurrentMediaTime() - self.animationStart) * 1000
            let progress = min(1, elapsedMs / self.config.animationMs)
            // ease-out cubic
            let eased = 1 - pow(1 - progress, 3)
            self.transition = self.animationFrom
                + (self.animationTo - self.animationFrom) * eased
            self.rebuildCards(reloadContents: false)
            if progress >= 1 {
                timer.invalidate()
                self.animationTimer = nil
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    // MARK: - hover (minimal trigger; per-card hover and the anti-spin guards are M5b)

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    public override func mouseEntered(with event: NSEvent) {
        setTransition(1, animated: true)
    }

    public override func mouseExited(with event: NSEvent) {
        setTransition(0, animated: true)
    }

    public override func mouseMoved(with event: NSEvent) {
        if transition < 1 { setTransition(1, animated: true) }
    }

    // MARK: - layout

    public override func layout() {
        super.layout()
        screenMetrics = ScreenMetrics(width: Double(bounds.width), height: Double(bounds.height))
        backdrop.frame = bounds
        rebuildCards(reloadContents: false)
    }

    static func color(fromHex hex: String) -> CGColor {
        var text = hex.trimmingCharacters(in: .whitespaces).uppercased()
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else {
            return NSColor.controlAccentColor.cgColor
        }
        return CGColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                       green: CGFloat((value >> 8) & 0xFF) / 255,
                       blue: CGFloat(value & 0xFF) / 255,
                       alpha: 1)
    }

    static let debugPalette: [(name: String, red: Double, green: Double, blue: Double)] = [
        ("R", 1, 0, 0), ("G", 0, 1, 0), ("B", 0, 0, 1), ("Y", 1, 1, 0),
        ("M", 1, 0, 1), ("C", 0, 1, 1), ("O", 1, 0.5, 0), ("P", 0.5, 0, 1),
        ("W", 1, 1, 1),
    ]

    static func solidImage(forSlot slot: Int) -> CGImage? {
        let entry = debugPalette[slot % debugPalette.count]
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 4, height: 4, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.setFillColor(CGColor(srgbRed: entry.red, green: entry.green,
                                     blue: entry.blue, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
        return context.makeImage()
    }

    private func rebuildCards(reloadContents: Bool) {
        let engine = LayoutEngine(config: config, screen: screenMetrics, transition: transition)
        let slots = engine.slots(count: library.count, focus: focus)

        while cards.count < slots.count {
            let card = CardLayer()
            layer?.addSublayer(card)
            cards.append(card)
        }

        let accent = CorridorView.color(fromHex: config.cardBorderColor)
        let backingScale = window?.backingScaleFactor ?? 2.0

        for (index, slot) in slots.enumerated() {
            let card = cards[index]
            let wallpaper = library[slot.index]
            // The focused card always uses the preview-sized thumbnail: it is the one that
            // can grow large, and swapping size class mid-morph would flash.
            let wanted: ThumbSizeClass = slot.isCenter ? .preview : .row

            if reloadContents || card.wallpaper?.path != wallpaper.path
                || card.sizeClass != wanted {
                let image = provider.image(for: wallpaper, sizeClass: wanted)
                card.setWallpaper(wallpaper, contents: image, sizeClass: wanted)
            }
            if debugColours {
                card.setContents(CorridorView.solidImage(forSlot: index))
            }
            card.apply(slot, accent: accent, backingScale: backingScale)
            card.isHidden = false
        }

        for index in slots.count..<cards.count {
            cards[index].isHidden = true
        }

        // The on-screen compositor sorts siblings by zPosition, but CALayer.render(in:)
        // -- which --snapshot uses -- paints them in sublayer order. Re-inserting the cards
        // back-to-front makes the paint order explicit and identical in both paths.
        let paintOrder = slots.indices
            .map { index -> (card: CardLayer, depth: Double) in
                (cards[index], slots[index].zPosition)
            }
            .sorted { $0.depth < $1.depth }
        for entry in paintOrder {
            layer?.addSublayer(entry.card)
        }
    }

    public func snapshot(to url: URL) throws {
        layoutSubtreeIfNeeded()
        let width = Int(bounds.width.rounded())
        let height = Int(bounds.height.rounded())
        guard width > 0, height > 0 else { throw SnapshotError.contextCreationFailed }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw SnapshotError.contextCreationFailed }
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let rootLayer = layer else { throw SnapshotError.renderFailed }
        rootLayer.render(in: context)
        guard let image = context.makeImage() else { throw SnapshotError.renderFailed }
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil) else {
            throw SnapshotError.writeFailed(url.path)
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw SnapshotError.writeFailed(url.path)
        }
    }
}
