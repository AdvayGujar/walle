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
    /// z translation used for depth ordering.
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

/// Pure geometry for the tile corridor. No AppKit, no Core Animation, no state: the
/// whole visual design lives here and is exercised directly by the test suite.
///
/// The row is always the configured number of slots wide: a centre tile with that many
/// halved either side. Every tile sits one step further out than the last, where the
/// step is the nearer tile's width times one minus overlap. With the default overlap of
/// 0.5 each tile therefore covers exactly the inner half of the next one, so the overlap
/// is identical at every step rather than piling up.
public struct LayoutEngine: Sendable {
    public var config: Config
    public var screen: ScreenMetrics
    /// Expanded: the centre tile becomes the full rectangle preview and the rest of the
    /// row is sized for that. Collapsed: every tile including the centre is a strip.
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

    /// Centre-to-centre pitch for tiles that do not overlap.
    public var pitch: Double { config.tileWidth * (1 - config.overlap) }

    /// Width of a strip tile. Collapsed strips are narrower, which is what makes the
    /// resting row read as a tighter stack.
    public var stripWidth: Double {
        expanded ? config.tileWidth : config.tileWidth * config.collapsedWidthScale
    }

    /// Builds every visible slot. centerAspect is the aspect ratio (w/h) of the focused
    /// wallpaper, used to size the centre rectangle.
    public func slots(count: Int, focus: Int, centerAspect: Double) -> [SlotGeometry] {
        let n = Queue.effectiveSlotCount(configured: config.slots, libraryCount: count)
        guard n > 0 else { return [] }
        let centerSlot = n / 2
        let maxDistance = centerSlot

        let preview = previewSize(aspect: centerAspect)
        let centreWidth = expanded ? Double(preview.width) : stripWidth
        let centreHeight = expanded ? Double(preview.height) : config.tileHeight

        // Perspective-projected size of the tile at each distance from the centre.
        var widths = [Double](repeating: 0, count: maxDistance + 1)
        var heights = [Double](repeating: 0, count: maxDistance + 1)
        widths[0] = centreWidth
        heights[0] = centreHeight
        var step = 1
        while step <= maxDistance {
            let falloff = pow(config.scaleFalloff, Double(step))
            let z = -Double(step) * config.depthStep
            let projection = max(0.0001, 1 - z / config.perspective)
            widths[step] = stripWidth * falloff / projection
            heights[step] = config.tileHeight * falloff / projection
            step += 1
        }

        // Each step out is the nearer tile's width times one minus overlap, so a tile
        // covers the same fraction of the next one everywhere in the row.
        var centres = [Double](repeating: 0, count: maxDistance + 1)
        step = 1
        while step <= maxDistance {
            centres[step] = centres[step - 1]
                + widths[step - 1] * (1 - config.overlap)
                + config.previewGap
            step += 1
        }

        var result: [SlotGeometry] = []
        result.reserveCapacity(n)
        for slot in 0..<n {
            let d = Queue.offset(forSlot: slot, centerSlot: centerSlot)
            let libraryIndex = Queue.index(forSlot: slot, centerSlot: centerSlot,
                                           focus: focus, count: count)
            let distance = abs(d)
            let sign: Double = d > 0 ? 1 : (d < 0 ? -1 : 0)
            let isCentre = d == 0
            let width = widths[distance]
            let height = heights[distance]
            let x = centerX + sign * centres[distance]

            // The centre only straightens up when it is actually showing the preview.
            // While the row is resting it leans with everything else.
            let shear = isCentre && expanded ? 0 : shearValue(forOffset: d)

            let z = isCentre ? 0 : -Double(distance) * config.depthStep
            result.append(SlotGeometry(
                slot: slot, offset: d, index: libraryIndex,
                rect: CGRect(x: x - width / 2, y: centerY - height / 2,
                             width: width, height: height),
                z: z,
                zPosition: isCentre ? 1000 : 500 - Double(distance),
                alpha: isCentre ? 1
                    : max(config.dimFloor, 1 - config.dimFalloff * Double(distance)),
                shear: shear,
                cornerRadius: isCentre && expanded ? 12 : 9,
                isCenter: isCentre))
        }
        return result
    }

    /// All tiles lean the same way in uniform mode; in mirror mode they lean toward the
    /// centre like a fan.
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
