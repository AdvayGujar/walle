import AppKit
import WalleCore

/// One wallpaper card.
///
/// This is deliberately not a sheared transform. The card outline is a CAShapeLayer path
/// and the photo sits in an undistorted layer that is clipped by that path, so the image
/// is never skewed. The same path draws the border, which keeps the outline and the
/// clipped image in exact agreement, and it means the skew is an ordinary property that
/// can be animated between the collapsed and expanded shapes.
final class CardLayer: CALayer {

    private(set) var wallpaper: Wallpaper?

    private let imageLayer = CALayer()
    private let maskLayer = CAShapeLayer()
    private let borderLayer = CAShapeLayer()
    /// The slot last applied, used to tell whether the silhouette actually changed.
    private var lastShape: SlotGeometry?

    override init() {
        super.init()
        masksToBounds = false

        imageLayer.contentsGravity = .resizeAspectFill
        imageLayer.masksToBounds = true
        imageLayer.mask = maskLayer
        maskLayer.fillColor = NSColor.white.cgColor

        borderLayer.fillColor = nil
        borderLayer.lineJoin = .round

        addSublayer(imageLayer)
        addSublayer(borderLayer)
    }

    required init?(coder: NSCoder) { fatalError("CardLayer is created in code only") }

    func setWallpaper(_ wallpaper: Wallpaper, contents image: CGImage?) {
        self.wallpaper = wallpaper
        imageLayer.contents = image
    }

    func setContents(_ image: CGImage?) {
        imageLayer.contents = image
    }

    /// Places and shapes the card. The layer frame is the shape bounding box; the skew
    /// lives entirely in the path, so nothing about the image is distorted.
    ///
    /// The caller owns the Core Animation transaction for a whole frame, so this method
    /// only assigns properties and skips the ones that did not change. Re-assigning an
    /// identical path still makes the render server rebuild the mask and border, which is
    /// the expensive part; during a rotation the cards move without changing shape.
    func apply(_ slot: SlotGeometry, accent: CGColor, backingScale: CGFloat) {
        let size = slot.rect.size
        if bounds.size != size {
            bounds = CGRect(origin: .zero, size: size)
            imageLayer.frame = bounds
            maskLayer.frame = bounds
            borderLayer.frame = bounds
        }
        let position = CGPoint(x: slot.rect.midX, y: slot.rect.midY)
        if self.position != position { self.position = position }

        if lastShape?.hasSameShape(as: slot) != true {
            var local = slot
            local.rect = CGRect(origin: .zero, size: size)
            let path = CardPath.path(for: local)
            maskLayer.path = path
            borderLayer.path = path
            lastShape = slot
        }

        if imageLayer.contentsScale != backingScale {
            imageLayer.contentsScale = backingScale
        }
        if borderLayer.strokeColor != accent { borderLayer.strokeColor = accent }
        let lineWidth: CGFloat = slot.isCenter ? CGFloat(slot.borderWidth) : 0
        if borderLayer.lineWidth != lineWidth { borderLayer.lineWidth = lineWidth }
        let alpha = Float(slot.alpha)
        if opacity != alpha { opacity = alpha }
        if zPosition != slot.zPosition { zPosition = slot.zPosition }
    }
}
