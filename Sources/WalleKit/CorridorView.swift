import AppKit
import CoreGraphics
import ImageIO
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
/// All geometry comes from LayoutEngine, so this class only owns the layer pool, the
/// thumbnail requests and the paint order.
public final class CorridorView: NSView {

    private var config: Config
    private var screenMetrics: ScreenMetrics
    private var provider: ThumbnailProvider
    private var currentPath: String?

    private var library: [Wallpaper] = []
    private var focus: Int = 0
    private var expanded: Bool = true

    private var cards: [CardLayer] = []
    private let backdrop = CALayer()

    /// Diagnostic mode: fills each card with a distinct flat colour so the compositing
    /// order in an overlap can be read straight off a rendered snapshot.
    private let debugColours: Bool

    public init(frame: NSRect, config: Config, provider: ThumbnailProvider,
                currentPath: String?, expanded: Bool = true,
                debugColours: Bool = false) {
        self.config = config
        self.screenMetrics = ScreenMetrics(width: Double(frame.width),
                                           height: Double(frame.height))
        self.provider = provider
        self.currentPath = currentPath
        self.expanded = expanded
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

    public func reload(library: [Wallpaper], focus: Int) {
        self.library = library
        self.focus = library.isEmpty ? 0 : Queue.wrapIndex(focus, count: library.count)
        rebuildCards(reloadContents: true)
    }

    public func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        rebuildCards(reloadContents: true)
    }

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
        let engine = LayoutEngine(config: config, screen: screenMetrics, expanded: expanded)
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
            let wanted: ThumbSizeClass = slot.isCenter && expanded ? .preview : .row

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
        // -- which --snapshot uses -- paints them in sublayer order. Relying on zPosition
        // therefore produced a snapshot where far tiles covered near ones. Re-inserting
        // the cards back-to-front makes the paint order explicit and identical in both
        // paths, so what is verified offscreen is what appears on screen.
        let paintOrder = slots.indices
            .map { index -> (card: CardLayer, depth: Double) in
                (cards[index], slots[index].zPosition)
            }
            .sorted { $0.depth < $1.depth }
        for entry in paintOrder {
            layer?.addSublayer(entry.card)
        }
    }

    /// Renders the row straight into a PNG. Used by --snapshot so the layout can be
    /// inspected without a display.
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
