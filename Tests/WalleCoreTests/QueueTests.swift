import Testing
@testable import WalleCore

@Suite("Queue wrapping and slot mapping")
struct QueueTests {

    @Test func wrapIndexNormalisesEverySign() {
        #expect(Queue.wrapIndex(0, count: 3) == 0)
        #expect(Queue.wrapIndex(4, count: 3) == 1)
        #expect(Queue.wrapIndex(3, count: 3) == 0)
        #expect(Queue.wrapIndex(100, count: 3) == 1)
        #expect(Queue.wrapIndex(-1, count: 3) == 2)
        #expect(Queue.wrapIndex(-3, count: 3) == 0)
        #expect(Queue.wrapIndex(-4, count: 3) == 2)
        #expect(Queue.wrapIndex(5, count: 0) == 0)
        #expect(Queue.wrapIndex(-5, count: 0) == 0)
    }

    @Test func effectiveSlotCountClampsToLibraryAndStaysOdd() {
        #expect(Queue.effectiveSlotCount(configured: 9, libraryCount: 0) == 0)
        #expect(Queue.effectiveSlotCount(configured: 9, libraryCount: 1) == 1)
        #expect(Queue.effectiveSlotCount(configured: 9, libraryCount: 2) == 3)
        #expect(Queue.effectiveSlotCount(configured: 9, libraryCount: 3) == 3)
        #expect(Queue.effectiveSlotCount(configured: 9, libraryCount: 4) == 5)
        #expect(Queue.effectiveSlotCount(configured: 9, libraryCount: 9) == 9)
        #expect(Queue.effectiveSlotCount(configured: 9, libraryCount: 10) == 9)
        // An even configured value is made odd before clamping.
        #expect(Queue.effectiveSlotCount(configured: 8, libraryCount: 100) == 7)
        #expect(Queue.effectiveSlotCount(configured: 8, libraryCount: 2) == 3)
        #expect(Queue.effectiveSlotCount(configured: 0, libraryCount: 20) == 1)
    }

    @Test func indexForSlotCentresOnFocusAndWraps() {
        #expect(Queue.index(forSlot: 4, centerSlot: 4, focus: 3, count: 9) == 3)
        #expect(Queue.index(forSlot: 5, centerSlot: 4, focus: 3, count: 9) == 4)
        #expect(Queue.index(forSlot: 3, centerSlot: 4, focus: 3, count: 9) == 2)
        // Wraps past the end to the left and past zero to the right.
        #expect(Queue.index(forSlot: 0, centerSlot: 4, focus: 0, count: 9) == 5)
        #expect(Queue.index(forSlot: 8, centerSlot: 4, focus: 0, count: 9) == 4)
        #expect(Queue.offset(forSlot: 6, centerSlot: 4) == 2)
        #expect(Queue.offset(forSlot: 1, centerSlot: 4) == -3)
    }

    @Test func focusAfterWrapsInBothDirections() {
        #expect(Queue.focus(after: 1, from: 8, count: 9) == 0)
        #expect(Queue.focus(after: -1, from: 0, count: 9) == 8)
        #expect(Queue.focus(after: 9, from: 0, count: 9) == 0)
        #expect(Queue.focus(after: -10, from: 0, count: 9) == 8)
        #expect(Queue.focus(after: 0, from: 4, count: 9) == 4)
    }

    @Test func slotForIndexFindsVisibleAndRejectsOffScreen() {
        #expect(Queue.slot(forIndex: 0, focus: 0, centerSlot: 4, slotCount: 9, count: 9) == 4)
        #expect(Queue.slot(forIndex: 5, focus: 0, centerSlot: 4, slotCount: 9, count: 9) == 0)
        #expect(Queue.slot(forIndex: 4, focus: 0, centerSlot: 4, slotCount: 9, count: 9) == 8)
        // With only 5 slots visible, index 3 is off screen for focus 0.
        #expect(Queue.slot(forIndex: 3, focus: 0, centerSlot: 2, slotCount: 5, count: 9) == nil)
        // The matching index is wrapped before the search: 12 wraps to 3, shown in slot 7.
        #expect(Queue.slot(forIndex: 12, focus: 0, centerSlot: 4, slotCount: 9, count: 9) == 7)
    }
}
