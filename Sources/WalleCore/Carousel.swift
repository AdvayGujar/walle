import Foundation

/// Slot arithmetic for sliding the row.
///
/// Rotating by delta slots means every card keeps its own wallpaper and moves one place
/// along. The card that lands in a destination slot is the one that was delta slots away in
/// the opposite direction, so a backwards rotation walks content forwards across the row.
public enum Carousel {

    /// Which slot a destination takes its card from, or nil when that destination is filled
    /// by a card entering from off the end of the row.
    public static func sourceSlot(destination: Int, delta: Int, slotCount: Int) -> Int? {
        guard slotCount > 0 else { return nil }
        let source = destination + delta
        return (source >= 0 && source < slotCount) ? source : nil
    }

    /// The push direction for a card entering from off-screen, in units of one pitch.
    public static func entryDirection(delta: Int) -> Double {
        delta > 0 ? 1 : -1
    }
}
