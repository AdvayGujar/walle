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
/// owns the layer pool and the animation clock; it does no geometry of its own.
///
/// Both kinds of motion run on that one clock. Expanding interpolates the transition;
/// rotating interpolates each card between the slot it came from and the slot it is going
/// to, while the card keeps its own wallpaper. That is what makes scrolling the row look
/// like the cards sliding rather than the pictures being swapped.
public final class CorridorView: NSView {

    /// Everything that changes how the corridor is rendered but not what it displays.
    /// Grouped so the initializer stays within a reasonable parameter count.
    public struct Options {
        /// 0 = resting row, 1 = expanded preview.
        public var transition: Double
        /// Flat per-slot colours instead of wallpapers, for --debug-tiles.
        public var debugColours: Bool
        /// Decode every thumbnail before returning. --snapshot renders immediately and
        /// cannot wait for the provider, so it turns this on.
        public var synchronousThumbnails: Bool

        public init(transition: Double = 1,
                    debugColours: Bool = false,
                    synchronousThumbnails: Bool = false) {
            self.transition = transition
            self.debugColours = debugColours
            self.synchronousThumbnails = synchronousThumbnails
        }
    }

    /// A card handed to a @Sendable provider completion. The provider delivers on the
    /// main queue, so the body runs under `MainActor.assumeIsolated`.
    private final class CardBox: @unchecked Sendable {
        let card: CardLayer
        init(_ card: CardLayer) { self.card = card }
    }

    /// Where every card came from and where it is heading, for the duration of one
    /// rotation. Arrays rather than dictionaries: the slots are 0..<count, and this is
    /// indexed once per card per animation tick.
    private struct Rotation {
        let from: [SlotGeometry]
        let to: [SlotGeometry]
        let contents: [Wallpaper]
    }

    private let config: Config
    private let provider: ThumbnailProvider
    private let options: Options
    /// Parsed once: the border colour cannot change for the lifetime of this view.
    private let accent: CGColor
    private var screenMetrics: ScreenMetrics

    private var library: [Wallpaper] = []
    private var focus: Int = 0
    private var transition: Double = 1

    private var cards: [CardLayer] = []
    private let backdrop = CALayer()
    private var lastCardCount = 0

    /// Slots currently on screen, so a rotation knows each card's starting geometry.
    private var currentSlots: [SlotGeometry] = []

    // One clock drives everything.
    private var animationLink: CADisplayLink?
    private var animationStart: CFTimeInterval = 0
    private var animationDurationMs: Double = 0
    private var easedProgress: Double = 1
    private var fromTransition: Double = 1
    private var toTransition: Double = 1

    private var rotation: Rotation?

    public var onApply: ((Wallpaper) -> Void)?
    public var onDismiss: (() -> Void)?

    public init(frame: NSRect, config: Config, provider: ThumbnailProvider,
                options: Options = Options()) {
        self.config = config
        self.provider = provider
        self.options = options
        self.transition = min(1, max(0, options.transition))
        self.accent = CorridorView.color(fromHex: config.cardBorderColor)
        self.screenMetrics = ScreenMetrics(width: Double(frame.width),
                                           height: Double(frame.height))
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

    public func reload(library: [Wallpaper], focus: Int) {
        self.library = library
        self.focus = library.isEmpty ? 0 : Queue.wrapIndex(focus, count: library.count)
        cancelAnimation()
        // Draw the shapes immediately and let the provider fill the images in. A cold
        // cache used to freeze the window while it generated every thumbnail; now the
        // row appears at once and each card is populated as its decode lands.
        rebuildCards()
    }

    // MARK: - animation clock

    private func cancelAnimation() {
        animationLink?.invalidate()
        animationLink = nil
        animationDurationMs = 0
        easedProgress = 1
        rotation = nil
    }

    private func startAnimation(durationMs: Double) {
        animationLink?.invalidate()
        animationLink = nil
        animationDurationMs = max(1, durationMs)
        animationStart = CACurrentMediaTime()
        easedProgress = 0
        // The interactive picker only animates once its window is on screen, which is what
        // a display link needs: it fires in step with that display instead of a fixed
        // 60 Hz. Without a display the final frame is applied immediately, so a caller
        // that animates a detached view still ends in the right state.
        guard window != nil else {
            finishAnimation()
            return
        }
        let link = displayLink(target: self, selector: #selector(displayLinkFired(_:)))
        link.add(to: .main, forMode: .common)
        animationLink = link
    }

    @objc private func displayLinkFired(_ link: CADisplayLink) {
        let elapsedMs = (link.timestamp - animationStart) * 1000
        let linear = min(1, elapsedMs / animationDurationMs)
        guard linear < 1 else {
            finishAnimation()
            return
        }
        // ease-out cubic
        easedProgress = 1 - pow(1 - linear, 3)
        transition = fromTransition + (toTransition - fromTransition) * easedProgress
        rebuildCards()
    }

    /// Applies the final frame once and drops the rotation so the next rebuild draws the
    /// resting geometry. Doing this in the tick that finishes avoids rebuilding twice.
    private func finishAnimation() {
        animationLink?.invalidate()
        animationLink = nil
        easedProgress = 1
        transition = toTransition
        rotation = nil
        rebuildCards()
    }

    /// Moves between the resting row and the expanded preview.
    public func setTransition(_ target: Double, animated: Bool) {
        let target = min(1, max(0, target))
        let needsMove = abs(target - transition) > 0.0001
        animationLink?.invalidate()
        animationLink = nil
        rotation = nil

        guard animated, config.animationMs > 0, needsMove else {
            easedProgress = 1
            transition = target
            rebuildCards()
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
            rebuildCards()
            return
        }

        var from: [SlotGeometry] = []
        var contents: [Wallpaper] = []
        from.reserveCapacity(count)
        contents.reserveCapacity(count)
        for destination in 0..<count {
            if let source = Carousel.sourceSlot(destination: destination, delta: delta,
                                                slotCount: count) {
                // The card that was at source slides into this destination, keeping its own
                // wallpaper. Getting this direction wrong is what made the row slide the
                // wrong way and then snap when the animation ended.
                from.append(oldSlots[source])
                contents.append(oldContents[source])
            } else {
                // A card entering from off the end of the row.
                var ghost = newSlots[destination]
                let push = engine.pitch * Carousel.entryDirection(delta: delta)
                ghost.rect = ghost.rect.offsetBy(dx: CGFloat(push), dy: 0)
                from.append(ghost)
                contents.append(library[newSlots[destination].index])
            }
        }

        rotation = Rotation(from: from, to: newSlots, contents: contents)
        fromTransition = transition
        toTransition = transition

        if config.animationMs > 0 {
            startAnimation(durationMs: min(config.animationMs, 260))
        } else {
            cancelAnimation()
            rebuildCards()
        }
    }

    public func applyFocused() {
        guard !library.isEmpty else { return }
        onApply?(library[Queue.wrapIndex(focus, count: library.count)])
    }

    // MARK: - keyboard

    /// Space toggles the preview on the centred card. It is a toggle rather than expand-only
    /// so the row can be returned to its resting state without dismissing the picker.
    ///
    /// Keys are handled by the application-level monitor in PickerApp, not here: that is
    /// what makes them work regardless of which view is first responder, and it keeps the
    /// Space binding in one place.
    public func toggleExpanded() {
        setTransition(transition > 0 ? 0 : 1, animated: true)
    }

    // MARK: - layout

    public override func layout() {
        super.layout()
        screenMetrics = ScreenMetrics(width: Double(bounds.width), height: Double(bounds.height))
        backdrop.frame = bounds
        rebuildCards()
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

    /// Paints a cache hit synchronously; otherwise claims the card for this wallpaper and
    /// finishes it when the provider delivers. Claiming the wallpaper with nil contents
    /// stops the animation ticks from queueing the same decode again.
    private func loadThumbnail(_ wallpaper: Wallpaper, into card: CardLayer) {
        if let cached = provider.cachedImage(for: wallpaper) {
            card.setWallpaper(wallpaper, contents: cached)
            return
        }
        card.setWallpaper(wallpaper, contents: nil)
        let box = CardBox(card)
        let expectedPath = wallpaper.path
        provider.imageAsync(for: wallpaper) { image in
            MainActor.assumeIsolated {
                // The row may have rotated while this decode was in flight.
                guard box.card.wallpaper?.path == expectedPath else { return }
                box.card.setContents(image)
            }
        }
    }

    /// Rebinds every card to this frame. One disabled-actions transaction covers the whole
    /// loop: starting one per card meant five Core Animation commits per animation tick.
    private func rebuildCards() {
        let slots = layoutSlots()
        currentSlots = slots
        ensureCardCount(slots.count)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        apply(slots)
        CATransaction.commit()

        updatePaintOrder(for: slots)
    }

    private func layoutSlots() -> [SlotGeometry] {
        LayoutEngine(config: config, screen: screenMetrics, transition: transition)
            .slots(count: library.count, focus: focus)
    }

    private func ensureCardCount(_ count: Int) {
        while cards.count < count {
            let card = CardLayer()
            layer?.addSublayer(card)
            cards.append(card)
        }
    }

    private func apply(_ slots: [SlotGeometry]) {
        let backingScale = window?.backingScaleFactor ?? 2.0
        // Rotation state only exists while a rotation runs. setTransition clears it, so an
        // expand morph never takes the interpolate branch below; rotate() sets
        // fromTransition == toTransition, so only easedProgress moves the cards.
        let morphing = rotation != nil && easedProgress < 1

        for (index, slot) in slots.enumerated() {
            let card = cards[index]
            let geometry = geometry(for: slot, at: index, morphing: morphing)
            let wallpaper = wallpaper(for: slot, at: index, morphing: morphing)
            // One thumbnail size for every card, because the cards are tall and a wide
            // wallpaper aspect-fills them. The collapsed centre card alone renders at
            // about 1512 px on the long side on a 1512-wide Retina display, so a smaller
            // thumbnail made everything visibly soft. The single size also means the image
            // never changes as a card slides into the centre, so there is no decode stall
            // and nothing to preload.
            if !options.debugColours, card.wallpaper?.path != wallpaper.path {
                if options.synchronousThumbnails {
                    card.setWallpaper(wallpaper, contents: provider.image(for: wallpaper))
                } else {
                    loadThumbnail(wallpaper, into: card)
                }
            }
            if options.debugColours {
                card.setContents(CorridorView.solidImage(forSlot: index))
            }
            card.apply(geometry, accent: accent, backingScale: backingScale)
            if card.isHidden { card.isHidden = false }
        }

        for index in slots.count..<cards.count where !cards[index].isHidden {
            cards[index].isHidden = true
        }
    }

    /// The card's own geometry for this frame: its slot, or its position between two slots
    /// while a rotation is running.
    private func geometry(for slot: SlotGeometry, at index: Int,
                          morphing: Bool) -> SlotGeometry {
        guard morphing, let rotation,
              rotation.from.indices.contains(index),
              rotation.to.indices.contains(index) else {
            return slot
        }
        return LayoutEngine.interpolate(rotation.from[index], rotation.to[index], easedProgress)
    }

    /// A card keeps its own wallpaper while it slides, so during a rotation the content
    /// comes from the rotation, not from whatever slot the card currently occupies.
    private func wallpaper(for slot: SlotGeometry, at index: Int,
                           morphing: Bool) -> Wallpaper {
        if morphing, let rotation, rotation.contents.indices.contains(index) {
            return rotation.contents[index]
        }
        return library[slot.index]
    }

    /// Paint order. The on-screen compositor sorts by zPosition but CALayer.render(in:)
    /// paints in sublayer order, so the order is made explicit. This is only redone when
    /// the number of cards changes: re-adding sublayers every frame meant restructuring
    /// the layer tree 60 times a second, which is what made the animation stutter.
    private func updatePaintOrder(for slots: [SlotGeometry]) {
        guard cards.count != lastCardCount else { return }
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
