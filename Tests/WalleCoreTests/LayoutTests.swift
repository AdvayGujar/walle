import CoreGraphics
import Testing
@testable import WalleCore

@Suite("Layout geometry and hit testing")
struct LayoutTests {

    // MARK: - Slot count

    @Test func slotCountMatchesEffectiveSlotCountAndDefaultsToFive() {
        let engine = makeLayoutEngine()
        #expect(Config().slots == 5)
        #expect(engine.config.slots == 5)
        for library in [1, 2, 3, 4, 7, 9, 10, 20] {
            let slots = engine.slots(count: library, focus: 0)
            #expect(slots.count
                == Queue.effectiveSlotCount(configured: engine.config.slots, libraryCount: library))
        }
    }

    @Test func emptyLibraryProducesNoSlots() {
        let engine = makeLayoutEngine()
        #expect(engine.slots(count: 0, focus: 0).isEmpty)
    }

    // MARK: - Collapsed row

    @Test func collapsedSlotsAllLeanAndCentreIsTaller() {
        let engine = makeLayoutEngine(expanded: false, screen: ScreenMetrics(width: 1920, height: 1080))
        let slots = engine.slots(count: 5, focus: 0)
        #expect(slots.count == 5)
        for slot in slots {
            #expect(approx(slot.skew, engine.config.cardSkew))
        }

        let centre = slots.first { $0.isCenter }!
        #expect(approx(centre.height, engine.config.selectedCardHeight))
        #expect(approx(centre.width, engine.config.cardWidth))
        #expect(approx(centre.cornerRadius, engine.config.cardCornerRadius))
        #expect(approx(centre.borderWidth, engine.config.cardBorderWidth))

        for slot in slots where !slot.isCenter {
            #expect(approx(slot.width, engine.config.cardWidth))
            #expect(approx(slot.height, engine.config.cardHeight))
            #expect(slot.height < centre.height)
        }
    }

    @Test func collapsedNeighbourCentresStepByOneUniformPitch() {
        let engine = makeLayoutEngine(expanded: false, screen: ScreenMetrics(width: 1920, height: 1080))
        let slots = engine.slots(count: 5, focus: 0)
        for distance in 1...2 {
            let left = slots.first { $0.offset == -distance }!
            let right = slots.first { $0.offset == distance }!
            #expect(approx(Double(left.rect.midX), engine.centerX - Double(distance) * engine.pitch))
            #expect(approx(Double(right.rect.midX), engine.centerX + Double(distance) * engine.pitch))
        }
    }

    // MARK: - Expanded row

    @Test func expandedCentreIsFlatAndShorterThanItsNeighbours() {
        let engine = makeLayoutEngine(expanded: true, screen: ScreenMetrics(width: 1920, height: 1080))
        let slots = engine.slots(count: 5, focus: 0)
        let centre = slots.first { $0.isCenter }!
        #expect(approx(centre.skew, 0))
        #expect(approx(centre.width, engine.config.expandedCardWidth))
        #expect(approx(centre.height, engine.config.expandedCardHeight))

        for slot in slots where !slot.isCenter {
            #expect(approx(slot.skew, engine.config.cardSkew))
            #expect(approx(slot.height, engine.config.cardHeight))
            #expect(slot.height > centre.height)
        }
    }

    @Test func expandedFirstNeighbourCentreSitsOnTheRectangleEdge() {
        let engine = makeLayoutEngine(expanded: true, screen: ScreenMetrics(width: 1920, height: 1080))
        let slots = engine.slots(count: 5, focus: 0)
        let edge = engine.config.expandedCardWidth * engine.scale / 2
        let centre = slots.first { $0.isCenter }!
        let firstRight = slots.first { $0.offset == 1 }!
        let firstLeft = slots.first { $0.offset == -1 }!

        // The tuck rule: the first neighbour's centre is exactly on the rectangle edge.
        #expect(approx(Double(firstRight.rect.midX), engine.centerX + edge))
        #expect(approx(Double(firstLeft.rect.midX), engine.centerX - edge))
        #expect(approx(Double(centre.rect.maxX), Double(firstRight.rect.midX)))
        #expect(approx(Double(centre.rect.minX), Double(firstLeft.rect.midX)))

        // Further neighbours keep stepping outward by one pitch.
        for distance in 1...2 {
            let right = slots.first { $0.offset == distance }!
            let left = slots.first { $0.offset == -distance }!
            #expect(approx(Double(right.rect.midX),
                            engine.centerX + edge + Double(distance - 1) * engine.pitch))
            #expect(approx(Double(left.rect.midX),
                            engine.centerX - edge - Double(distance - 1) * engine.pitch))
        }
    }

    // MARK: - Scaling

    @Test func geometryScalesWithScreenWidth() {
        let design = makeLayoutEngine(screen: ScreenMetrics(width: 1920, height: 1080))
        let doubled = makeLayoutEngine(screen: ScreenMetrics(width: 3840, height: 1080))
        #expect(approx(design.scale, 1))
        #expect(approx(doubled.scale, 2))
        #expect(approx(design.pitch, design.config.cardWidth + design.config.cardGap))
        #expect(approx(doubled.pitch, design.pitch * 2))

        for expanded in [false, true] {
            let designEngine = makeLayoutEngine(expanded: expanded,
                                                screen: ScreenMetrics(width: 1920, height: 1080))
            let doubledEngine = makeLayoutEngine(expanded: expanded,
                                                 screen: ScreenMetrics(width: 3840, height: 1080))
            let small = designEngine.slots(count: 5, focus: 0)
            let large = doubledEngine.slots(count: 5, focus: 0)
            #expect(small.count == large.count)
            for index in 0..<small.count {
                #expect(approx(large[index].width, small[index].width * 2))
                #expect(approx(large[index].height, small[index].height * 2))
                #expect(approx(Double(large[index].rect.width), Double(small[index].rect.width) * 2))
                #expect(approx(large[index].skew, small[index].skew))
            }
            for offset in [-2, -1, 1, 2] {
                let smallSlot = small.first { $0.offset == offset }!
                let largeSlot = large.first { $0.offset == offset }!
                let smallDelta = Double(smallSlot.rect.midX) - designEngine.centerX
                let largeDelta = Double(largeSlot.rect.midX) - doubledEngine.centerX
                #expect(approx(largeDelta, smallDelta * 2))
            }
        }
    }

    @Test func at1920DesignUnitsAreExact() {
        let engine = makeLayoutEngine(screen: ScreenMetrics(width: 1920, height: 1080))
        let config = engine.config
        let collapsed = engine.slots(count: 5, focus: 0)
        let centre = collapsed.first { $0.isCenter }!
        let neighbour = collapsed.first { !$0.isCenter }!
        #expect(approx(centre.width, config.cardWidth))
        #expect(approx(centre.height, config.selectedCardHeight))
        #expect(approx(neighbour.width, config.cardWidth))
        #expect(approx(neighbour.height, config.cardHeight))
        #expect(approx(neighbour.skew, config.cardSkew))
        #expect(approx(engine.pitch, config.cardWidth + config.cardGap))

        let expanded = makeLayoutEngine(expanded: true,
                                        screen: ScreenMetrics(width: 1920, height: 1080))
            .slots(count: 5, focus: 0)
        let expandedCentre = expanded.first { $0.isCenter }!
        #expect(approx(expandedCentre.width, config.expandedCardWidth))
        #expect(approx(expandedCentre.height, config.expandedCardHeight))
    }

    // MARK: - Bounding box vs mid-section width

    @Test func boundingBoxIsWiderThanMidSectionForSkewedCards() {
        for expanded in [false, true] {
            let engine = makeLayoutEngine(expanded: expanded,
                                          screen: ScreenMetrics(width: 1920, height: 1080))
            for slot in engine.slots(count: 5, focus: 0) {
                let expected = LayoutEngine.boundingWidth(midWidth: slot.width,
                                                          height: slot.height, skew: slot.skew)
                #expect(approx(Double(slot.rect.width), expected))
                #expect(approx(expected, slot.width + abs(slot.skew) * slot.height))
                if slot.skew != 0 {
                    #expect(Double(slot.rect.width) > slot.width)
                } else {
                    #expect(approx(Double(slot.rect.width), slot.width))
                }
            }
        }
    }

    // MARK: - Dimming and stacking

    @Test func sideSlotsDimMonotonicallyAndStayAboveFloor() {
        let engine = makeLayoutEngine(screen: ScreenMetrics(width: 1920, height: 1080),
                                      configure: { $0.slots = 9 })
        let slots = engine.slots(count: 9, focus: 0)
        #expect(slots.map { abs($0.offset) }.max() == 4)

        var previous = Double.infinity
        for slot in slots.sorted(by: { abs($0.offset) < abs($1.offset) }) {
            #expect(slot.alpha <= previous + 1e-9)
            #expect(slot.alpha >= engine.config.dimFloor - 1e-9)
            previous = slot.alpha
        }
        #expect(slots.first { $0.isCenter }!.alpha == 1)
    }

    @Test func centreSlotHasHighestZPosition() {
        let engine = makeLayoutEngine(screen: ScreenMetrics(width: 1920, height: 1080))
        let slots = engine.slots(count: 5, focus: 0)
        let centre = slots.first { $0.isCenter }!
        for slot in slots where !slot.isCenter {
            #expect(slot.zPosition < centre.zPosition)
        }
    }

    // MARK: - Hit testing

    @Test func containsUndoesTheSymmetricLean() {
        let engine = makeLayoutEngine(screen: ScreenMetrics(width: 1920, height: 1080))
        let tile = engine.slots(count: 5, focus: 0).first { $0.offset == 1 }!
        #expect(tile.skew != 0)

        let midX = Double(tile.rect.midX)
        let minY = Double(tile.rect.minY)
        let height = tile.height
        let half = tile.width / 2
        let midY = minY + height / 2
        let shift = tile.skew * height / 2

        // Shift is zero at the vertical centre, so the mid-section centre is accepted as-is.
        #expect(LayoutEngine.contains(CGPoint(x: midX, y: midY), in: tile))
        // Shift is maximal at the top and bottom edges, and opposite in sign.
        #expect(LayoutEngine.contains(CGPoint(x: midX + shift, y: minY + height), in: tile))
        #expect(LayoutEngine.contains(CGPoint(x: midX - shift, y: minY), in: tile))
        // The top edge lies exactly within midX + shift +/- half, so the lean is measured
        // rather than assumed. (An earlier version of this test asserted that midX itself
        // was outside at the edges, which only held while the cards were narrow enough for
        // the lean to clear them entirely.)
        #expect(!LayoutEngine.contains(
            CGPoint(x: midX + shift + half + 0.5, y: minY + height), in: tile))
        #expect(!LayoutEngine.contains(
            CGPoint(x: midX + shift - half - 0.5, y: minY + height), in: tile))
        #expect(!LayoutEngine.contains(
            CGPoint(x: midX - shift + half + 0.5, y: minY), in: tile))
        #expect(!LayoutEngine.contains(
            CGPoint(x: midX - shift - half - 0.5, y: minY), in: tile))

        // Just outside the mid-section is rejected.
        #expect(!LayoutEngine.contains(CGPoint(x: midX + half + 0.5, y: midY), in: tile))
        #expect(!LayoutEngine.contains(CGPoint(x: midX - half - 0.5, y: midY), in: tile))
        // Above and below the card are rejected.
        #expect(!LayoutEngine.contains(CGPoint(x: midX, y: minY - 1), in: tile))
        #expect(!LayoutEngine.contains(CGPoint(x: midX, y: minY + height + 1), in: tile))
    }

    @Test func hitTestReturnsCentreIndexAndNilForBackdrop() {
        let engine = makeLayoutEngine(expanded: true, screen: ScreenMetrics(width: 1920, height: 1080))
        let slots = engine.slots(count: 5, focus: 0)
        let centre = slots.first { $0.isCenter }!
        let point = CGPoint(x: centre.rect.midX, y: centre.rect.midY)
        #expect(engine.hitTest(point, slots: slots) == centre.index)
        #expect(engine.hitTestSlot(point, slots: slots)?.slot == centre.slot)

        let lowestEdge = slots.map { Double($0.rect.maxY) }.max() ?? engine.centerY
        #expect(engine.hitTest(CGPoint(x: engine.centerX, y: lowestEdge + 50), slots: slots) == nil)
        #expect(engine.hitTest(CGPoint(x: 1, y: engine.centerY), slots: slots) == nil)
    }

    @Test func hitTestPrefersHigherZPositionRegardlessOfArrayOrder() {
        let engine = makeLayoutEngine()
        func makeSlot(slot: Int, offset: Int, index: Int, rect: CGRect, zPosition: Double) -> SlotGeometry {
            SlotGeometry(slot: slot, offset: offset, index: index, rect: rect,
                         width: Double(rect.width), height: Double(rect.height), skew: 0,
                         alpha: 1, zPosition: zPosition, isCenter: false,
                         cornerRadius: 0, borderWidth: 0)
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
}

private func approx(_ lhs: Double, _ rhs: Double, tolerance: Double = 1e-9) -> Bool {
    abs(lhs - rhs) <= tolerance
}
