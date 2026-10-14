import Testing
@testable import WalleCore

/// Regression suite for a sign error that made the row animate the wrong way: pressing left
/// slid the right-hand card towards the centre, then the layout snapped to the correct
/// focus when the animation finished.
@Suite("Carousel slot mapping")
struct CarouselTests {

    /// The card that ends up in the centre came from the side the user moved towards.
    @Test func movingLeftBringsTheLeftNeighbourToTheCentre() {
        let centre = 2
        // delta -1 means focus moved left, so the destination centre takes its card from
        // the slot to its left.
        #expect(Carousel.sourceSlot(destination: centre, delta: -1, slotCount: 5) == 1)
        #expect(Carousel.sourceSlot(destination: centre, delta: 1, slotCount: 5) == 3)
    }

    @Test func everyCardMovesOnePlace() {
        for destination in 1..<5 {
            #expect(Carousel.sourceSlot(destination: destination, delta: -1, slotCount: 5)
                    == destination - 1)
        }
        for destination in 0..<4 {
            #expect(Carousel.sourceSlot(destination: destination, delta: 1, slotCount: 5)
                    == destination + 1)
        }
    }

    @Test func theEndOfTheRowIsFilledFromOffScreen() {
        // Moving left, the leftmost slot has nothing to its left.
        #expect(Carousel.sourceSlot(destination: 0, delta: -1, slotCount: 5) == nil)
        // Moving right, the rightmost slot has nothing to its right.
        #expect(Carousel.sourceSlot(destination: 4, delta: 1, slotCount: 5) == nil)
    }

    @Test func entryDirectionMatchesTheRotation() {
        #expect(Carousel.entryDirection(delta: 1) == 1)
        #expect(Carousel.entryDirection(delta: -1) == -1)
    }

    @Test func emptyRowHasNoSources() {
        #expect(Carousel.sourceSlot(destination: 0, delta: 1, slotCount: 0) == nil)
    }
}
