import CoreGraphics
import Foundation

/// Where one card ends up. Everything the renderer needs, and everything the hit-tester
/// needs, with no state and no AppKit.
public struct SlotGeometry: Sendable, Equatable {
    public var slot: Int
    public var offset: Int
    public var index: Int
    /// Bounding box of the card shape. Wider than the mid-section width whenever the card
    /// is skewed, because the lean pushes the top and bottom edges outwards.
    public var rect: CGRect
    /// Horizontal cross-section width at the vertical centre.
    public var width: Double
    public var height: Double
    /// Horizontal shear. The top edge shifts by skew * height / 2, the bottom edge by the
    /// negative of that.
    public var skew: Double
    public var alpha: Double
    /// Core Animation stacking order; higher is nearer the viewer.
    public var zPosition: Double
    public var isCenter: Bool
    public var cornerRadius: Double
    public var borderWidth: Double
}

public struct ScreenMetrics: Sendable, Equatable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// Pure geometry for the card row. Design units are multiplied by
/// scale = screenWidth / designWidth, so the composition scales with the display.
///
/// Geometry is a continuous function of the transition value: 0 is the resting row of
/// skewed slices, 1 is the expanded preview, and every value in between is a valid frame
/// of the morph. That is what lets the animation be driven by a single number, and what
/// lets a snapshot at an arbitrary point of the transition be used to verify it.
public struct LayoutEngine: Sendable {
    public var config: Config
    public var screen: ScreenMetrics
    /// 0 = resting row, 1 = fully expanded preview.
    public var transition: Double

    public init(config: Config, screen: ScreenMetrics, transition: Double) {
        self.config = config
        self.screen = screen
        self.transition = transition
    }

    public init(config: Config, screen: ScreenMetrics, expanded: Bool) {
        self.init(config: config, screen: screen, transition: expanded ? 1 : 0)
    }

    public var expanded: Bool { transition >= 1 }

    public var scale: Double { screen.width / max(1, config.designWidth) }
    public var centerX: Double { screen.width / 2 }
    public var centerY: Double { screen.height * config.rowCenterYFrac }

    /// Centre-to-centre distance between neighbouring cards at rest.
    public var pitch: Double { (config.cardWidth + config.cardGap) * scale }

    /// Bounding-box width of a skewed card.
    public static func boundingWidth(midWidth: Double, height: Double, skew: Double) -> Double {
        midWidth + abs(skew) * height
    }

    static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double { a + (b - a) * t }

    /// Interpolates between two card states so a card can slide from one slot to the next.
    /// The bounding box is recomputed from the interpolated mid-width, height and skew
    /// rather than interpolated on its own, so the shape stays self-consistent throughout.
    public static func interpolate(_ a: SlotGeometry, _ b: SlotGeometry, _ t: Double) -> SlotGeometry {
        let u = min(1, max(0, t))
        var result = b
        result.width = lerp(a.width, b.width, u)
        result.height = lerp(a.height, b.height, u)
        result.skew = lerp(a.skew, b.skew, u)
        result.alpha = lerp(a.alpha, b.alpha, u)
        let midX = lerp(Double(a.rect.midX), Double(b.rect.midX), u)
        let midY = lerp(Double(a.rect.midY), Double(b.rect.midY), u)
        let boxWidth = boundingWidth(midWidth: result.width, height: result.height, skew: result.skew)
        result.rect = CGRect(x: midX - boxWidth / 2, y: midY - result.height / 2,
                             width: boxWidth, height: result.height)
        return result
    }

    public func slots(count: Int, focus: Int) -> [SlotGeometry] {
        let n = Queue.effectiveSlotCount(configured: config.slots, libraryCount: count)
        guard n > 0 else { return [] }
        let centerSlot = n / 2
        let s = scale
        let t = min(1, max(0, transition))

        let stripWidth = config.cardWidth * s
        let stripHeight = config.cardHeight * s
        let tallHeight = config.selectedCardHeight * s
        let wideWidth = config.expandedCardWidth * s
        let wideHeight = config.expandedCardHeight * s
        let step = pitch

        var result: [SlotGeometry] = []
        result.reserveCapacity(n)
        for slot in 0..<n {
            let d = Queue.offset(forSlot: slot, centerSlot: centerSlot)
            let libraryIndex = Queue.index(forSlot: slot, centerSlot: centerSlot,
                                           focus: focus, count: count)
            let distance = abs(d)
            let sign: Double = d > 0 ? 1 : (d < 0 ? -1 : 0)
            let isCentre = d == 0

            let width: Double
            let height: Double
            let skew: Double
            let offsetX: Double
            let alpha: Double

            if isCentre {
                // Width, height and skew all move together: the slice straightens out and
                // opens up into the flat preview rectangle.
                width = LayoutEngine.lerp(stripWidth, wideWidth, t)
                height = LayoutEngine.lerp(tallHeight, wideHeight, t)
                skew = LayoutEngine.lerp(config.cardSkew, 0, t)
                offsetX = 0
                alpha = 1
            } else {
                width = stripWidth
                height = stripHeight
                skew = config.cardSkew
                // Neighbours slide outward to make room as the centre widens.
                let resting = step * Double(distance)
                let opened = wideWidth / 2 + Double(distance - 1) * step
                offsetX = sign * LayoutEngine.lerp(resting, opened, t)
                let restingAlpha = max(config.dimFloor, 1 - config.dimFalloff * Double(distance))
                alpha = LayoutEngine.lerp(restingAlpha, config.expandedNeighbourAlpha, t)
            }

            let boxWidth = LayoutEngine.boundingWidth(midWidth: width, height: height, skew: skew)
            let centre = CGPoint(x: centerX + offsetX, y: centerY)
            let rect = CGRect(x: centre.x - boxWidth / 2, y: centre.y - height / 2,
                              width: boxWidth, height: height)

            result.append(SlotGeometry(
                slot: slot, offset: d, index: libraryIndex, rect: rect,
                width: width, height: height, skew: skew, alpha: alpha,
                zPosition: isCentre ? 1000 : 500 - Double(distance),
                isCenter: isCentre,
                cornerRadius: config.cardCornerRadius * s,
                borderWidth: config.cardBorderWidth * s))
        }
        return result
    }

    /// True when the point is inside the card silhouette. The lean passes through zero at
    /// the vertical centre, so undoing it means subtracting the interpolated shift.
    public static func contains(_ point: CGPoint, in slot: SlotGeometry) -> Bool {
        let r = slot.rect
        guard point.y >= r.minY, point.y <= r.maxY else { return false }
        guard r.height > 0 else { return false }
        let t = Double(point.y - r.minY) / Double(r.height)
        let shift = slot.skew * slot.height * (t - 0.5)
        let unshearedX = Double(point.x) - shift
        let midX = Double(r.midX)
        let half = slot.width / 2
        return unshearedX >= midX - half && unshearedX <= midX + half
    }

    /// Which library index is under the point, or nil for the backdrop.
    public func hitTest(_ point: CGPoint, slots: [SlotGeometry]) -> Int? {
        for slot in slots.sorted(by: { $0.zPosition > $1.zPosition })
        where LayoutEngine.contains(point, in: slot) {
            return slot.index
        }
        return nil
    }

    public func hitTestSlot(_ point: CGPoint, slots: [SlotGeometry]) -> SlotGeometry? {
        for slot in slots.sorted(by: { $0.zPosition > $1.zPosition })
        where LayoutEngine.contains(point, in: slot) {
            return slot
        }
        return nil
    }
}
