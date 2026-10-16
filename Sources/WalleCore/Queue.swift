import Foundation

/// The wallpaper library is a circular list: there is no first or last tile, and
/// focus wraps forever in both directions.
public enum Queue {

    /// Normalises any integer into 0..<count.
    public static func wrapIndex(_ index: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let m = index % count
        return m < 0 ? m + count : m
    }

    /// How many tiles to actually show. Clamps to the library when it is small so a
    /// 3-image library shows 3 slots instead of 9 copies of the same three.
    ///
    /// Always odd so there is a true centre slot. An even library therefore gets one
    /// extra slot: two wallpapers show as three cards, and the same wallpaper appears on
    /// both sides of the centre. That duplication is the deliberate price of keeping a
    /// real centre slot instead of a half-covered one.
    public static func effectiveSlotCount(configured: Int, libraryCount: Int) -> Int {
        guard libraryCount > 0 else { return 0 }
        var c = max(1, configured)
        if c % 2 == 0 { c -= 1 }
        if libraryCount == 1 { return 1 }
        let needed = libraryCount % 2 == 0 ? libraryCount + 1 : libraryCount
        return min(c, needed)
    }

    /// Logical library index shown in a given slot, for a given focus.
    public static func index(forSlot slot: Int, centerSlot: Int, focus: Int, count: Int) -> Int {
        wrapIndex(focus + slot - centerSlot, count: count)
    }

    /// Slot offset from centre: negative to the left, positive to the right.
    public static func offset(forSlot slot: Int, centerSlot: Int) -> Int {
        slot - centerSlot
    }

    /// The library index that should be promoted to the centre for a rotation.
    public static func focus(after delta: Int, from focus: Int, count: Int) -> Int {
        wrapIndex(focus + delta, count: count)
    }

}
