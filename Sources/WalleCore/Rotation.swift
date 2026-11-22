import Foundation

/// How often `walle rotate` moves to the next wallpaper.
///
/// The config file writes this as a short duration such as `30s`, `10m` or `2h`.
/// A bare number means seconds, which keeps `walle rotate 300` predictable.
public struct RotationInterval: Sendable, Equatable, CustomStringConvertible {
    public static let minimumSeconds = 1

    public var seconds: Int

    public init(seconds: Int) {
        self.seconds = seconds
    }

    /// Parses a duration: an integer followed by an optional unit.
    /// Accepted units are `s`, `m` and `h` (and their long spellings).
    public static func parse(_ raw: String) -> RotationInterval? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }

        var digits = ""
        var unit = ""
        for character in trimmed {
            if character.isASCII, character.isNumber {
                guard unit.isEmpty else { return nil }
                digits.append(character)
            } else {
                unit.append(character)
            }
        }

        guard let value = Int(digits), value >= minimumSeconds else { return nil }
        let multiplier: Int
        switch unit.trimmingCharacters(in: .whitespaces) {
        case "", "s", "sec", "secs", "second", "seconds":
            multiplier = 1
        case "m", "min", "mins", "minute", "minutes":
            multiplier = 60
        case "h", "hr", "hrs", "hour", "hours":
            multiplier = 3600
        default:
            return nil
        }

        let (seconds, overflow) = value.multipliedReportingOverflow(by: multiplier)
        guard !overflow else { return nil }
        return RotationInterval(seconds: seconds)
    }

    /// The shortest spelling that parses back to the same interval.
    public var description: String {
        if seconds >= 3600, seconds % 3600 == 0 { return String(seconds / 3600) + "h" }
        if seconds >= 60, seconds % 60 == 0 { return String(seconds / 60) + "m" }
        return String(seconds) + "s"
    }
}
