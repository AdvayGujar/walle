import AppKit
import WalleCore

/// One wallpaper tile.
///
/// It is a parallelogram while it sits in the row and a plain rectangle when it holds
/// the focused preview, which is only a difference in shear.
final class TileLayer: CALayer {

    private(set) var wallpaper: Wallpaper?
    private(set) var sizeClass: ThumbSizeClass?

    override init() {
        super.init()
        // The shear transform is applied about the anchor point, and LayoutEngine's
        // hit-testing anchors the shear at the tile's bottom edge. The anchor point
        // must therefore be bottom-centre or the rendered shape and the clickable
        // shape drift apart.
        anchorPoint = CGPoint(x: 0.5, y: 0)
        contentsGravity = .resizeAspectFill
        masksToBounds = true
        borderWidth = 0
        shadowOpacity = 0
    }

    required init?(coder: NSCoder) { fatalError("TileLayer is created in code only") }

    func setWallpaper(_ wallpaper: Wallpaper, contents image: CGImage?, sizeClass: ThumbSizeClass) {
        self.wallpaper = wallpaper
        self.sizeClass = sizeClass
        self.contents = image
    }

    func setContents(_ image: CGImage?) {
        self.contents = image
    }

    /// Applies pre-projected geometry.
    ///
    /// LayoutEngine already folded depth and perspective into the rectangle, so the only
    /// transform left here is the shear. That keeps what is drawn and what is hit-tested
    /// derived from one source of truth.
    func apply(_ slot: SlotGeometry) {
        bounds = CGRect(origin: .zero, size: slot.rect.size)
        position = CGPoint(x: slot.rect.midX, y: slot.rect.minY)
        transform = CATransform3DMakeAffineTransform(
            CGAffineTransform(a: 1, b: 0, c: slot.shear, d: 1, tx: 0, ty: 0))
        zPosition = slot.zPosition
        opacity = Float(slot.alpha)
        cornerRadius = slot.cornerRadius
    }

    func setAccent(_ on: Bool, color: CGColor) {
        borderWidth = on ? 2 : 0
        borderColor = on ? color : nil
    }
}
