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

/// The tile corridor: an endless horizontal queue of wallpaper tiles that recede and
/// dim with distance from the centre.
///
/// All of the geometry comes from LayoutEngine, so this class only owns the layer pool
/// and the thumbnail requests.
public final class CorridorView: NSView {

    private var config: Config
    private var screenMetrics: ScreenMetrics
    private var provider: ThumbnailProvider
    private var currentPath: String?

    private var library: [Wallpaper] = []
    private var focus: Int = 0
    private var expanded: Bool = true

    private var tiles: [TileLayer] = []
    private let backdrop = CALayer()

    public init(frame: NSRect, config: Config, provider: ThumbnailProvider,
                currentPath: String?, expanded: Bool = true) {
        self.config = config
        self.screenMetrics = ScreenMetrics(width: Double(frame.width),
                                           height: Double(frame.height))
        self.provider = provider
        self.currentPath = currentPath
        self.expanded = expanded
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
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
        rebuildTiles(reloadContents: true)
    }

    public func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        rebuildTiles(reloadContents: true)
    }

    public override func layout() {
        super.layout()
        screenMetrics = ScreenMetrics(width: Double(bounds.width), height: Double(bounds.height))
        backdrop.frame = bounds
        rebuildTiles(reloadContents: false)
    }

    private var centerAspect: Double {
        guard !library.isEmpty else { return config.tileWidth / config.tileHeight }
        let index = Queue.wrapIndex(focus, count: library.count)
        return library[index].aspectRatio ?? (config.tileWidth / config.tileHeight)
    }

    private func rebuildTiles(reloadContents: Bool) {
        let engine = LayoutEngine(config: config, screen: screenMetrics, expanded: expanded)
        let slots = engine.slots(count: library.count, focus: focus, centerAspect: centerAspect)

        while tiles.count < slots.count {
            let tile = TileLayer()
            tile.contentsScale = window?.backingScaleFactor ?? 2.0
            layer?.addSublayer(tile)
            tiles.append(tile)
        }

        for (index, slot) in slots.enumerated() {
            let tile = tiles[index]
            let wallpaper = library[slot.index]
            let wanted: ThumbSizeClass = slot.isCenter ? .preview : .row

            if reloadContents || tile.wallpaper?.path != wallpaper.path
                || tile.sizeClass != wanted {
                let image = provider.image(for: wallpaper, sizeClass: wanted)
                tile.setWallpaper(wallpaper, contents: image, sizeClass: wanted)
            }
            tile.apply(slot)
            tile.isHidden = false
            tile.setAccent(wallpaper.path == currentPath, color: NSColor.controlAccentColor.cgColor)
        }

        for index in slots.count..<tiles.count {
            tiles[index].isHidden = true
        }
    }

    /// Renders the corridor straight into a PNG. Used by --snapshot so the layout can be
    /// inspected without a display, and so a change to the geometry can be verified.
    public func snapshot(to url: URL) throws {
        layoutSubtreeIfNeeded()
        let width = Int(bounds.width.rounded())
        let height = Int(bounds.height.rounded())
        guard width > 0, height > 0 else {
            throw SnapshotError.contextCreationFailed
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            throw SnapshotError.contextCreationFailed
        }
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
