import CoreGraphics
import Testing
@testable import WalleCore

@Suite("Layout geometry and hit testing")
struct LayoutTests {

    @Test func slotsCountMatchesEffectiveSlotCount() {
        let engine = makeLayoutEngine()
        for library in [1, 2, 3, 4, 7, 9, 10, 20] {
            let slots = engine.slots(count: library, focus: 0, centerAspect: 1.6)
            #expect(slots.count == Queue.effectiveSlotCount(configured: engine.config.slots, libraryCount: library))
        }
    }

    @Test func emptyLibraryProducesNoSlots() {
        let engine = makeLayoutEngine()
        #expect(engine.slots(count: 0, focus: 0, centerAspect: 1.6).isEmpty)
    }

    @Test func centreSlotIsNeutralWhenExpanded() {
        let engine = makeLayoutEngine(expanded: true)
        let slots = engine.slots(count: 5, focus: 4, centerAspect: 1.6)
        let centres = slots.filter { $0.isCenter }
        #expect(centres.count == 1)
        let centre = centres[0]
        #expect(centre.offset == 0)
        #expect(centre.shear == 0)
        #expect(centre.alpha == 1)
        #expect(centre.z == 0)
        #expect(centre.index == 4)
    }

    /// The resting row is a run of leaning strips, so the centre leans with them. Only
    /// the preview rectangle stands straight.
    @Test func centreSlotLeansWithTheRowWhenCollapsed() {
        let engine = makeLayoutEngine(expanded: false)
        let centre = engine.slots(count: 5, focus: 0, centerAspect: 1.6).first { $0.isCenter }
        #expect(centre != nil)
        if let centre {
            #expect(centre.shear == engine.config.tileShear)
            #expect(centre.alpha == 1)
            #expect(centre.z == 0)
        }
    }

    @Test func collapsedCentreRectUsesTheCollapsedStripWidth() {
        let engine = makeLayoutEngine(expanded: false)
        let centre = engine.slots(count: 5, focus: 0, centerAspect: 1.6).first { $0.isCenter }
        #expect(centre != nil)
        if let centre {
            let expected = engine.config.tileWidth * engine.config.collapsedWidthScale
            #expect(abs(Double(centre.rect.width) - expected) < 1e-9)
            #expect(abs(Double(centre.rect.height) - engine.config.tileHeight) < 1e-9)
        }
    }

    @Test func expandedCentreRectMatchesPreviewSize() {
        for aspect in [16.0 / 9.0, 9.0 / 16.0, 1.0, 3.0] {
            let engine = makeLayoutEngine(expanded: true)
            let centre = engine.slots(count: 5, focus: 0, centerAspect: aspect).first { $0.isCenter }
            #expect(centre != nil)
            if let centre {
                let size = engine.previewSize(aspect: aspect)
                #expect(abs(Double(centre.rect.width) - Double(size.width)) < 1e-9)
                #expect(abs(Double(centre.rect.height) - Double(size.height)) < 1e-9)
            }
        }
    }

    @Test func previewSizeFitsBudgetAndPreservesAspect() {
        let engine = makeLayoutEngine(expanded: true)
        let maxW = engine.screen.width * engine.config.previewMaxWFrac
        let maxH = engine.screen.height * engine.config.previewMaxHFrac
        for aspect in [16.0 / 9.0, 9.0 / 16.0, 1.0, 2.5] {
            let size = engine.previewSize(aspect: aspect)
            #expect(Double(size.width) <= maxW + 1e-9)
            #expect(Double(size.height) <= maxH + 1e-9)
            #expect(abs(Double(size.width) / Double(size.height) - aspect) < 1e-9)
        }

        // A non-positive aspect falls back to the tile aspect ratio.
        let fallback = engine.previewSize(aspect: 0)
        let tileAspect = engine.config.tileWidth / engine.config.tileHeight
        #expect(abs(Double(fallback.width) / Double(fallback.height) - tileAspect) < 1e-9)
    }

    @Test func sideSlotsDimRecedeAndShrinkMonotonically() {
        let engine = makeLayoutEngine()
        let slots = engine.slots(count: 9, focus: 0, centerAspect: 1.6)
        let maxOffset = slots.map { abs($0.offset) }.max() ?? 0
        #expect(maxOffset == 2)

        var previous: (alpha: Double, z: Double, zPosition: Double, area: Double)?
        for ad in 1...maxOffset {
            let group = slots.filter { abs($0.offset) == ad }
            #expect(!group.isEmpty)
            for slot in group {
                let area = Double(slot.rect.width) * Double(slot.rect.height)
                #expect(slot.alpha >= engine.config.dimFloor - 1e-9)
                if let previous {
                    #expect(slot.alpha <= previous.alpha + 1e-9)
                    #expect(slot.z < previous.z)
                    #expect(slot.zPosition < previous.zPosition)
                    #expect(area < previous.area)
                }
            }
            if let first = group.first {
                previous = (first.alpha, first.z, first.zPosition,
                            Double(first.rect.width) * Double(first.rect.height))
            }
        }
    }

    @Test func horizontalSymmetryInUniformShear() {
        let engine = makeLayoutEngine(configure: { $0.shearMode = .uniform })
        let slots = engine.slots(count: 5, focus: 0, centerAspect: 1.6)
        for ad in 1...2 {
            let left = slots.first { $0.offset == -ad }
            let right = slots.first { $0.offset == ad }
            #expect(left != nil)
            #expect(right != nil)
            if let left, let right {
                let midpoint = (Double(left.rect.midX) + Double(right.rect.midX)) / 2
                #expect(abs(midpoint - engine.centerX) < 1e-6)
                #expect(abs(Double(left.rect.width) - Double(right.rect.width)) < 1e-9)
            }
        }
    }

    @Test func stepsShrinkWithDistanceAndFlattenWithoutFalloff() {
        let engine = makeLayoutEngine(configure: { $0.slots = 7 })
        let slots = engine.slots(count: 7, focus: 0, centerAspect: 1.6)
        let gaps = (1...2).map { ad -> Double in
            guard let a = slots.first(where: { $0.offset == ad }),
                  let b = slots.first(where: { $0.offset == ad + 1 }) else { return .nan }
            return abs(Double(b.rect.midX) - Double(a.rect.midX))
        }
        #expect(gaps[1] < gaps[0])

        // With no scale falloff and no depth step every strip is the same width, so the
        // steps stop shrinking and the overlap stays identical.
        let flat = makeLayoutEngine(configure: {
            $0.slots = 7
            $0.scaleFalloff = 1
            $0.depthStep = 0
        })
        let flatSlots = flat.slots(count: 7, focus: 0, centerAspect: 1.6)
        let flatGaps = (1...2).map { ad -> Double in
            guard let a = flatSlots.first(where: { $0.offset == ad }),
                  let b = flatSlots.first(where: { $0.offset == ad + 1 }) else { return .nan }
            return abs(Double(b.rect.midX) - Double(a.rect.midX))
        }
        #expect(abs(flatGaps[0] - flatGaps[1]) < 1e-9)
    }

    @Test func shearValueIsUniformOrMirrored() {
        var config = Config()
        config.tileShear = 0.3
        let screen = ScreenMetrics(width: 1512, height: 982)
        var engine = LayoutEngine(config: config, screen: screen, expanded: false)
        for d in -4...4 {
            #expect(engine.shearValue(forOffset: d) == 0.3)
        }

        config.shearMode = .mirror
        engine = LayoutEngine(config: config, screen: screen, expanded: false)
        #expect(engine.shearValue(forOffset: 2) == -0.3)
        #expect(engine.shearValue(forOffset: -2) == 0.3)
        #expect(engine.shearValue(forOffset: 1) == -engine.shearValue(forOffset: -1))
    }

    @Test func containsAcceptsShearedCentreAndRejectsOutside() {
        let engine = makeLayoutEngine()
        let slots = engine.slots(count: 5, focus: 0, centerAspect: 1.6)
        guard let tile = slots.first(where: { $0.offset == 1 }) else {
            Issue.record("expected a right-hand tile")
            return
        }
        #expect(tile.shear != 0)

        let midY = Double(tile.rect.midY)
        let displacement = tile.shear * (midY - Double(tile.rect.minY))
        let centre = CGPoint(x: Double(tile.rect.midX) + displacement, y: midY)
        #expect(LayoutEngine.contains(centre, in: tile))

        let outsideLeft = CGPoint(x: Double(tile.rect.minX) - 0.5 + displacement, y: midY)
        let outsideRight = CGPoint(x: Double(tile.rect.maxX) + 0.5 + displacement, y: midY)
        #expect(!LayoutEngine.contains(outsideLeft, in: tile))
        #expect(!LayoutEngine.contains(outsideRight, in: tile))

        let above = CGPoint(x: Double(tile.rect.midX) + displacement, y: Double(tile.rect.minY) - 1)
        let below = CGPoint(x: Double(tile.rect.midX) + displacement, y: Double(tile.rect.maxY) + 1)
        #expect(!LayoutEngine.contains(above, in: tile))
        #expect(!LayoutEngine.contains(below, in: tile))
    }

    @Test func eachTileCoversHalfOfTheNextOne() {
        let engine = makeLayoutEngine(expanded: true, configure: { $0.slots = 7 })
        let slots = engine.slots(count: 7, focus: 0, centerAspect: 1.6)
        for ad in 0...1 {
            guard let nearer = slots.first(where: { $0.offset == ad }),
                  let further = slots.first(where: { $0.offset == ad + 1 }) else {
                Issue.record("missing offsets \(ad) and \(ad + 1)")
                return
            }
            let nearerEdge = Double(nearer.rect.maxX)
            let furtherMid = Double(further.rect.midX)
            #expect(abs(nearerEdge - furtherMid) < 1e-9)
        }
    }

    @Test func hitTestReturnsCentreSlotForCentreRect() {
        let engine = makeLayoutEngine(expanded: true)
        let slots = engine.slots(count: 5, focus: 0, centerAspect: 1.6)
        guard let centre = slots.first(where: { $0.isCenter }) else {
            Issue.record("expected a centre slot")
            return
        }
        let point = CGPoint(x: centre.rect.midX, y: centre.rect.midY)
        #expect(engine.hitTest(point, slots: slots) == centre.index)
        #expect(engine.hitTestSlot(point, slots: slots)?.slot == centre.slot)
    }

    @Test func hitTestPrefersHigherZPositionRegardlessOfArrayOrder() {
        let engine = makeLayoutEngine()
        func makeSlot(slot: Int, offset: Int, index: Int, rect: CGRect, zPosition: Double) -> SlotGeometry {
            SlotGeometry(slot: slot, offset: offset, index: index, rect: rect, z: -1,
                         zPosition: zPosition, alpha: 1, shear: 0, cornerRadius: 0, isCenter: false)
        }
        let back = makeSlot(slot: 0, offset: -1, index: 7,
                            rect: CGRect(x: 0, y: 0, width: 100, height: 100), zPosition: 1)
        let front = makeSlot(slot: 1, offset: 1, index: 2,
                             rect: CGRect(x: 50, y: 50, width: 100, height: 100), zPosition: 2)
        let point = CGPoint(x: 75, y: 75)
        #expect(engine.hitTest(point, slots: [back, front]) == 2)
        #expect(engine.hitTest(point, slots: [front, back]) == 2)
        #expect(engine.hitTestSlot(point, slots: [back, front])?.slot == 1)
    }

    @Test func hitTestReturnsNilForBackdropBelowTheRow() {
        let engine = makeLayoutEngine(expanded: false)
        let slots = engine.slots(count: 5, focus: 0, centerAspect: 1.6)
        let lowestEdge = slots.map { Double($0.rect.maxY) }.max() ?? engine.centerY
        let below = CGPoint(x: engine.centerX, y: lowestEdge + 50)
        #expect(engine.hitTest(below, slots: slots) == nil)
        #expect(engine.hitTest(CGPoint(x: 1, y: engine.centerY), slots: slots) == nil)
    }
}
