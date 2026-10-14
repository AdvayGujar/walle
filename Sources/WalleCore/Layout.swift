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
/// Collapsed: every card is a skewed slice at a uniform pitch, and the selected card is
/// taller than the rest. Expanded: the selected card becomes a flat rectangle and the
/// neighbours sit half tucked behind it, stepped outward by one pitch.
public struct LayoutEngine: Sendable {
    public var config: Config
    public var screen: ScreenMetrics
    public var expanded: Bool

    public init(config: Config, screen: ScreenMetrics, expanded: Bool) {
        self.config = config
        self.screen = screen
        self.expanded = expanded
    }

    public var scale: Double { screen.width / max(1, config.designWidth) }
    public var centerX: Double { screen.width / 2 }
    public var centerY: Double { screen.height * config.rowCenterYFrac }

    /// Centre-to-centre distance between neighbouring cards.
    public var pitch: Double { (config.cardWidth + config.cardGap) * scale }

    /// Bounding-box width of a skewed card.
    public static func boundingWidth(midWidth: Double, height: Double, skew: Double) -> Double {
        midWidth + abs(skew) * height
    }

    public func slots(count: Int, focus: Int) -> [SlotGeometry] {
        let n = Queue.effectiveSlotCount(configured: config.slots, libraryCount: count)
        guard n > 0 else { return [] }
        let centerSlot = n / 2
        let s = scale

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

            if isCentre {
                width = expanded ? wideWidth : stripWidth
                height = expanded ? wideHeight : tallHeight
                skew = expanded ? 0 : config.cardSkew
                offsetX = 0
            } else {
                width = stripWidth
                height = stripHeight
                skew = config.cardSkew
                // Expanded: the first neighbour is half tucked behind the rectangle, so
                // its centre sits on the rectangle edge. The rest step by one pitch.
                let inner = expanded ? wideWidth / 2 : step
                offsetX = sign * (inner + Double(distance - 1) * step)
            }

            let boxWidth = LayoutEngine.boundingWidth(midWidth: width, height: height, skew: skew)
            let centre = CGPoint(x: centerX + offsetX, y: centerY)
            let rect = CGRect(x: centre.x - boxWidth / 2, y: centre.y - height / 2,
                              width: boxWidth, height: height)

            result.append(SlotGeometry(
                slot: slot, offset: d, index: libraryIndex, rect: rect,
                width: width, height: height, skew: skew,
                // Expanded: everything except the focused card fades almost away so the
                // preview is the only thing being looked at. Collapsed: a gentle falloff.
                alpha: isCentre ? 1
                    : (expanded
                        ? config.expandedNeighbourAlpha
                        : max(config.dimFloor, 1 - config.dimFalloff * Double(distance))),
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
