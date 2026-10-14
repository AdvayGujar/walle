import CoreGraphics
import Foundation

/// Where one tile ends up on screen. Everything the renderer needs, and nothing it
/// has to recompute; also everything the hit-tester needs.
public struct SlotGeometry: Sendable, Equatable {
    public var slot: Int
    public var offset: Int
    public var index: Int
    /// Final on-screen rectangle, before shear is applied.
    public var rect: CGRect
    /// z translation used for the perspective transform.
    public var z: Double
    /// Core Animation stacking order; higher is nearer the viewer.
    public var zPosition: Double
    public var alpha: Double
    /// Horizontal shear factor: x is displaced by shear * (y - rect.minY).
    public var shear: Double
    public var cornerRadius: Double
    public var isCenter: Bool
}

public struct ScreenMetrics: Sendable, Equatable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

/// Pure geometry for the tile corridor. No AppKit, no Core Animation, no state:
/// the whole visual design lives here and is exercised directly by the test suite.
public struct LayoutEngine: Sendable {
    public var config: Config
    public var screen: ScreenMetrics
    /// Expanded: the centre slot shows the full rectangle preview and neighbours
    /// make room for it. Collapsed: every tile is a parallelogram at a uniform pitch.
    public var expanded: Bool

    public init(config: Config, screen: ScreenMetrics, expanded: Bool) {
        self.config = config
        self.screen = screen
        self.expanded = expanded
    }

    public var centerX: Double { screen.width / 2 }
    public var centerY: Double { screen.height * config.rowCenterYFrac }

    /// Largest rectangle that fits the wallpaper aspect inside the preview budget.
    public func previewSize(aspect: Double) -> CGSize {
        let aspect = aspect > 0 ? aspect : config.tileWidth / config.tileHeight
        let maxW = screen.width * config.previewMaxWFrac
        let maxH = screen.height * config.previewMaxHFrac
        var w = maxW
        var h = w / aspect
        if h > maxH {
            h = maxH
            w = h * aspect
        }
        return CGSize(width: w, height: h)
    }

    /// Pitch between neighbouring tiles when collapsed.
    public var pitch: Double { config.tileWidth * (1 - config.overlap) }

    /// Builds every visible slot. centerAspect is the aspect ratio (w/h) of the
    /// focused wallpaper, used to size the centre rectangle.
    public func slots(count: Int, focus: Int, centerAspect: Double) -> [SlotGeometry] {
        let n = Queue.effectiveSlotCount(configured: config.slots, libraryCount: count)
        guard n > 0 else { return [] }
        let centerSlot = n / 2
        let preview = previewSize(aspect: centerAspect)
        let baseW = config.tileWidth
        let baseH = config.tileHeight
        let centreW = expanded ? Double(preview.width) : baseW

        var result: [SlotGeometry] = []
        result.reserveCapacity(n)

        for slot in 0..<n {
            let d = Queue.offset(forSlot: slot, centerSlot: centerSlot)
            let index = Queue.index(forSlot: slot, centerSlot: centerSlot, focus: focus, count: count)
            let ad = abs(d)

            if d == 0 {
                let w = expanded ? Double(preview.width) : baseW
                let h = expanded ? Double(preview.height) : baseH
                result.append(SlotGeometry(
                    slot: slot, offset: 0, index: index,
                    rect: CGRect(x: centerX - w / 2, y: centerY - h / 2, width: w, height: h),
                    z: 0, zPosition: 1000, alpha: 1, shear: 0,
                    cornerRadius: expanded ? 12 : 9, isCenter: true))
                continue
            }

            let falloff = pow(config.scaleFalloff, Double(ad))
            let preW = baseW * falloff
            let preH = baseH * falloff

            // Recede: negative z pushes the tile away from the viewer.
            let z = -Double(ad) * config.depthStep
            let projection = 1 - z / config.perspective  // > 1 for receding tiles
            let projW = preW / projection
            let projH = preH / projection

            // Clear the centre rectangle, then advance by one pitch per further slot.
            let innerEdge = centreW / 2 + config.previewGap + Double(ad - 1) * pitch
            let preDistance = innerEdge + preW / 2
            let distance = preDistance / projection
            let sign: Double = d > 0 ? 1 : -1
            let x = centerX + sign * distance

            let shear = shearValue(forOffset: d)

            result.append(SlotGeometry(
                slot: slot, offset: d, index: index,
                rect: CGRect(x: x - projW / 2, y: centerY - projH / 2, width: projW, height: projH),
                z: z,
                zPosition: 500 - Double(ad),
                alpha: max(config.dimFloor, 1 - config.dimFalloff * Double(ad)),
                shear: shear,
                cornerRadius: 9,
                isCenter: false))
        }

        return result
    }

    /// All tiles lean the same way in uniform mode; in mirror mode they lean toward
    /// the centre like a fan.
    public func shearValue(forOffset d: Int) -> Double {
        switch config.shearMode {
        case .uniform:
            return config.tileShear
        case .mirror:
            return d > 0 ? -config.tileShear : config.tileShear
        }
    }

    /// True when the point is inside the sheared tile silhouette.
    public static func contains(_ point: CGPoint, in slot: SlotGeometry) -> Bool {
        let r = slot.rect
        guard point.y >= r.minY, point.y <= r.maxY else { return false }
        let displacement = slot.shear * Double(point.y - r.minY)
        let unshearedX = Double(point.x) - displacement
        return unshearedX >= Double(r.minX) && unshearedX <= Double(r.maxX)
    }

    /// Which library index is under the point, or nil for the backdrop.
    /// Nearest to the viewer wins, which mirrors what is visually on top.
    public func hitTest(_ point: CGPoint, slots: [SlotGeometry]) -> Int? {
        let ordered = slots.sorted { $0.zPosition > $1.zPosition }
        for slot in ordered where LayoutEngine.contains(point, in: slot) {
            return slot.index
        }
        return nil
    }

    /// The slot under the point, or nil.
    public func hitTestSlot(_ point: CGPoint, slots: [SlotGeometry]) -> SlotGeometry? {
        let ordered = slots.sorted { $0.zPosition > $1.zPosition }
        for slot in ordered where LayoutEngine.contains(point, in: slot) {
            return slot
        }
        return nil
    }
}
