import CoreGraphics
import Testing
@testable import WalleCore

/// The anti-spin invariant: sampling the same stationary point repeatedly must promote at
/// most once, however many times it is sampled.
///
/// Note the shape of these tests: shouldPromote is mutating, and a mutating call cannot be
/// written directly inside #expect, so every call is evaluated into a local first.
@Suite("Hover gate")
struct HoverGateTests {

    @Test func firstHoverAlwaysPromotes() {
        var gate = HoverGate()
        let promoted = gate.shouldPromote(point: CGPoint(x: 100, y: 100), time: 0)
        #expect(promoted)
    }

    @Test func stationaryPointerPromotesOnlyOnce() {
        var gate = HoverGate()
        let point = CGPoint(x: 100, y: 100)
        var promotions = 0
        for step in 0..<200 {
            // Even with plenty of time between samples, a still pointer must not re-fire.
            if gate.shouldPromote(point: point, time: Double(step) * 0.5) { promotions += 1 }
        }
        #expect(promotions == 1)
    }

    @Test func subThresholdMovementIsIgnored() {
        var gate = HoverGate(travelThreshold: 12, cooldown: 0.14)
        let first = gate.shouldPromote(point: CGPoint(x: 100, y: 100), time: 0)
        let second = gate.shouldPromote(point: CGPoint(x: 105, y: 100), time: 1)
        let third = gate.shouldPromote(point: CGPoint(x: 106, y: 106), time: 2)
        #expect(first)
        #expect(!second)
        #expect(!third)
    }

    @Test func movementInsideCooldownIsIgnored() {
        var gate = HoverGate(travelThreshold: 12, cooldown: 0.14)
        let first = gate.shouldPromote(point: CGPoint(x: 0, y: 0), time: 0)
        let second = gate.shouldPromote(point: CGPoint(x: 100, y: 0), time: 0.05)
        #expect(first)
        #expect(!second)
    }

    @Test func realMovementAfterCooldownPromotes() {
        var gate = HoverGate(travelThreshold: 12, cooldown: 0.14)
        let first = gate.shouldPromote(point: CGPoint(x: 0, y: 0), time: 0)
        let second = gate.shouldPromote(point: CGPoint(x: 100, y: 0), time: 0.5)
        #expect(first)
        #expect(second)
    }

    @Test func resetAllowsTheNextHoverToFire() {
        var gate = HoverGate()
        let point = CGPoint(x: 50, y: 50)
        let first = gate.shouldPromote(point: point, time: 0)
        let blocked = gate.shouldPromote(point: point, time: 10)
        gate.reset()
        let afterReset = gate.shouldPromote(point: point, time: 10)
        #expect(first)
        #expect(!blocked)
        #expect(afterReset)
    }
}
