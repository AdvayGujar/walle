import CoreGraphics
import Foundation

/// Builds the card silhouette.
///
/// A card is a parallelogram inscribed in its bounding box: the top edge is shifted by
/// skew * height / 2 in one direction and the bottom edge by the same amount in the
/// other, so the horizontal cross-section at the vertical centre is exactly cardWidth
/// wide. At skew 0 the same path degenerates to a plain rounded rectangle, which is what
/// lets the shape morph smoothly between the two states.
public enum CardPath {

    public static func path(for slot: SlotGeometry) -> CGPath {
        parallelogram(midWidth: slot.width, height: slot.height, skew: slot.skew,
                      centerX: Double(slot.rect.midX), minY: Double(slot.rect.minY),
                      cornerRadius: slot.cornerRadius)
    }

    public static func parallelogram(midWidth: Double, height: Double, skew: Double,
                                     centerX: Double, minY: Double,
                                     cornerRadius: Double) -> CGPath {
        let half = CGFloat(midWidth) / 2
        let shift = CGFloat(skew * height / 2)
        let cx = CGFloat(centerX)
        let bottomShift = -shift
        let topShift = shift
        let bottomY = CGFloat(minY)
        let topY = CGFloat(minY + height)

        let bottomLeft = CGPoint(x: cx + bottomShift - half, y: bottomY)
        let bottomRight = CGPoint(x: cx + bottomShift + half, y: bottomY)
        let topRight = CGPoint(x: cx + topShift + half, y: topY)
        let topLeft = CGPoint(x: cx + topShift - half, y: topY)

        return roundedPolygon([bottomLeft, bottomRight, topRight, topLeft],
                              radius: CGFloat(cornerRadius))
    }

    public static func roundedPolygon(_ points: [CGPoint], radius: CGFloat) -> CGPath {
        let path = CGMutablePath()
        guard points.count >= 3 else { return path }
        let r = max(0, radius)
        let last = points[points.count - 1]
        let first = points[0]
        path.move(to: CGPoint(x: (last.x + first.x) / 2, y: (last.y + first.y) / 2))
        for index in 0..<points.count {
            let corner = points[index]
            let next = points[(index + 1) % points.count]
            path.addArc(tangent1End: corner, tangent2End: next, radius: r)
        }
        path.closeSubpath()
        return path
    }
}
