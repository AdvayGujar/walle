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
    func apply(_ slot: SlotGeometry, accent: CGColor, backingScale: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        bounds = CGRect(origin: .zero, size: slot.rect.size)
        position = CGPoint(x: slot.rect.midX, y: slot.rect.midY)

        var local = slot
        local.rect = CGRect(origin: .zero, size: slot.rect.size)
        let path = CardPath.path(for: local)

        imageLayer.frame = bounds
        imageLayer.contentsScale = backingScale
        maskLayer.frame = bounds
        maskLayer.path = path

        borderLayer.frame = bounds
        borderLayer.path = path
        borderLayer.lineWidth = slot.isCenter ? slot.borderWidth : 0
        borderLayer.strokeColor = accent

        opacity = Float(slot.alpha)
        zPosition = slot.zPosition

        CATransaction.commit()
    }
}
