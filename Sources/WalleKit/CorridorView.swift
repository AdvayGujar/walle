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
/// All geometry comes from LayoutEngine as a function of a transition value, so the class
/// owns three things: the layer pool, a single animation clock, and the hit testing.
///
/// Both kinds of motion run on that one clock. Expanding interpolates the transition;
/// rotating interpolates each card between the slot it came from and the slot it is going
/// to, while the card keeps its own wallpaper. That is what makes scrolling the row look
/// like the cards sliding rather than the pictures being swapped.
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
    private var lastCardCount = 0

    /// Geometry currently on screen, reused for hit testing.
    private var currentSlots: [SlotGeometry] = []

    // One clock drives everything.
    private var animationTimer: Timer?
    private var animationStart: CFTimeInterval = 0
    private var animationDurationMs: Double = 0
    private var easedProgress: Double = 1
    private var fromTransition: Double = 1
    private var toTransition: Double = 1

    // Rotation state: where each card came from and where it is heading.
    private var rotationFrom: [Int: SlotGeometry] = [:]
    private var rotationTo: [Int: SlotGeometry] = [:]
    private var rotationContents: [Int: Wallpaper] = [:]

    public var onApply: ((Wallpaper) -> Void)?
    public var onDismiss: (() -> Void)?

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
        cancelAnimation()
        rebuildCards(reloadContents: true)
    }

    // MARK: - animation clock

    private func cancelAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
        animationDurationMs = 0
        easedProgress = 1
        rotationFrom = [:]
        rotationTo = [:]
        rotationContents = [:]
    }

    private func startAnimation(durationMs: Double) {
        animationTimer?.invalidate()
        animationDurationMs = max(1, durationMs)
        animationStart = CACurrentMediaTime()
        easedProgress = 0
        // The timer runs in .common so it keeps ticking while the pointer is being tracked.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let elapsedMs = (CACurrentMediaTime() - self.animationStart) * 1000
            let linear = min(1, elapsedMs / self.animationDurationMs)
            // ease-out cubic
            self.easedProgress = 1 - pow(1 - linear, 3)
            self.transition = self.fromTransition
                + (self.toTransition - self.fromTransition) * self.easedProgress
            self.rebuildCards(reloadContents: false)
            if linear >= 1 {
                timer.invalidate()
                self.animationTimer = nil
                self.easedProgress = 1
                self.rotationFrom = [:]
                self.rotationTo = [:]
                self.rotationContents = [:]
                self.rebuildCards(reloadContents: false)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
    }

    /// Moves between the resting row and the expanded preview.
    public func setTransition(_ target: Double, animated: Bool) {
        let target = min(1, max(0, target))
        let needsMove = abs(target - transition) > 0.0001
        animationTimer?.invalidate()
        animationTimer = nil
        rotationFrom = [:]
        rotationTo = [:]
        rotationContents = [:]

        guard animated, config.animationMs > 0, needsMove else {
            easedProgress = 1
            transition = target
            rebuildCards(reloadContents: false)
            return
        }
        fromTransition = transition
        toTransition = target
        startAnimation(durationMs: config.animationMs)
    }

    /// Rotates the row by one card, sliding every card into its neighbour's place.
    public func rotate(_ delta: Int) {
        guard library.count > 1 else { return }
        let count = currentSlots.count
        guard count > 1 else { return }

        let oldSlots = currentSlots
        let oldContents: [Wallpaper] = (0..<count).map { library[oldSlots[$0].index] }

        focus = Queue.focus(after: delta, from: focus, count: library.count)

        let engine = LayoutEngine(config: config, screen: screenMetrics, transition: transition)
        let newSlots = engine.slots(count: library.count, focus: focus)
        guard newSlots.count == count else {
            rebuildCards(reloadContents: true)
            return
        }

        var from: [Int: SlotGeometry] = [:]
        var to: [Int: SlotGeometry] = [:]
        var contents: [Int: Wallpaper] = [:]
        for destination in 0..<count {
            to[destination] = newSlots[destination]
            if let source = Carousel.sourceSlot(destination: destination, delta: delta,
                                                slotCount: count) {
                // The card that was at source slides into this destination, keeping its own
                // wallpaper. Getting this direction wrong is what made the row slide the
                // wrong way and then snap when the animation ended.
                from[destination] = oldSlots[source]
                contents[destination] = oldContents[source]
            } else {
                // A card entering from off the end of the row.
                var ghost = newSlots[destination]
                let push = engine.pitch * Carousel.entryDirection(delta: delta)
                ghost.rect = ghost.rect.offsetBy(dx: CGFloat(push), dy: 0)
                from[destination] = ghost
                contents[destination] = library[newSlots[destination].index]
            }
        }

        rotationFrom = from
        rotationTo = to
        rotationContents = contents
        fromTransition = transition
        toTransition = transition

        if config.animationMs > 0 {
            startAnimation(durationMs: min(config.animationMs, 260))
        } else {
            cancelAnimation()
            rebuildCards(reloadContents: true)
        }
    }

    public func applyFocused() {
        guard !library.isEmpty else { return }
        onApply?(library[Queue.wrapIndex(focus, count: library.count)])
    }

    // MARK: - keyboard

    /// Space toggles the preview on the centred card. It is a toggle rather than expand-only
    /// so the row can be returned to its resting state without dismissing the picker.
    public func toggleExpanded() {
        setTransition(transition > 0 ? 0 : 1, animated: true)
    }

    public override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123, 126: rotate(-1)
        case 124, 125: rotate(1)
        case 36, 49: applyFocused()
        default: super.keyDown(with: event)
        }
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
        currentSlots = slots

        while cards.count < slots.count {
            let card = CardLayer()
            layer?.addSublayer(card)
            cards.append(card)
        }

        let accent = CorridorView.color(fromHex: config.cardBorderColor)
        let backingScale = window?.backingScaleFactor ?? 2.0
        let morphing = easedProgress < 1

        for (index, slot) in slots.enumerated() {
            let card = cards[index]
            var geometry = slot
            if morphing, let from = rotationFrom[index], let to = rotationTo[index] {
                geometry = LayoutEngine.interpolate(from, to, easedProgress)
            }
            // A card keeps its own wallpaper while it slides, so take the content from the
            // rotation map rather than from whatever slot it currently occupies.
            let wallpaper = morphing ? (rotationContents[index] ?? library[slot.index])
                                     : library[slot.index]
            let wanted: ThumbSizeClass = slot.isCenter ? .preview : .row

            if reloadContents || card.wallpaper?.path != wallpaper.path
                || card.sizeClass != wanted {
                let image = provider.image(for: wallpaper, sizeClass: wanted)
                card.setWallpaper(wallpaper, contents: image, sizeClass: wanted)
            }
            if debugColours {
                card.setContents(CorridorView.solidImage(forSlot: index))
            }
            card.apply(geometry, accent: accent, backingScale: backingScale)
            card.isHidden = false
        }

        for index in slots.count..<cards.count {
            cards[index].isHidden = true
        }

        // Paint order. The on-screen compositor sorts by zPosition but CALayer.render(in:)
        // paints in sublayer order, so the order is made explicit. This is only redone when
        // the number of cards changes: re-adding sublayers every frame meant restructuring
        // the layer tree 60 times a second, which is what made the animation stutter.
        if cards.count != lastCardCount {
            lastCardCount = cards.count
            let paintOrder = slots.indices
                .map { index -> (card: CardLayer, depth: Double) in
                    (cards[index], slots[index].zPosition)
                }
                .sorted { $0.depth < $1.depth }
            for entry in paintOrder {
                layer?.addSublayer(entry.card)
            }
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
