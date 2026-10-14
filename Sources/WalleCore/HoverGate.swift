import CoreGraphics
import Foundation

/// Gate that stops hover-to-promote from spinning the row.
///
/// Promoting a card rotates it to the centre, which moves it out from under a stationary
/// pointer. Re-evaluating naively would then promote whatever slid into place, and the row
/// would run away on its own. This allows a promotion only when the pointer has genuinely
/// travelled since the previous one AND enough time has passed, so a motionless pointer
/// can fire at most once no matter how often it is sampled.
public struct HoverGate: Sendable {
    public var travelThreshold: Double
    public var cooldown: Double

    private var lastPoint: CGPoint?
    private var lastFireTime: Double?

    public init(travelThreshold: Double = 12, cooldown: Double = 0.14) {
        self.travelThreshold = travelThreshold
        self.cooldown = cooldown
    }

    /// True when this hover is allowed to change the selection. Consuming a promotion
    /// records the point and time, so the next call is measured against it.
    public mutating func shouldPromote(point: CGPoint, time: Double) -> Bool {
        if let lastFire = lastFireTime, time - lastFire < cooldown { return false }
        if let previous = lastPoint {
            let dx = Double(point.x - previous.x)
            let dy = Double(point.y - previous.y)
            if (dx * dx + dy * dy).squareRoot() < travelThreshold { return false }
        }
        lastPoint = point
        lastFireTime = time
        return true
    }

    public mutating func reset() {
        lastPoint = nil
        lastFireTime = nil
    }
}
