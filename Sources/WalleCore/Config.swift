import Foundation

public enum SortMode: String, Sendable, CaseIterable {
    case name, mtime, random

    public static func parse(_ raw: String) -> SortMode? {
        SortMode(rawValue: raw.lowercased().trimmingCharacters(in: .whitespaces))
    }
}

public enum ApplyTarget: String, Sendable, CaseIterable {
    case all, active

    public static func parse(_ raw: String) -> ApplyTarget? {
        ApplyTarget(rawValue: raw.lowercased().trimmingCharacters(in: .whitespaces))
    }
}

public enum FillMode: String, Sendable, CaseIterable {
    case fill, fit, stretch, center

    public static func parse(_ raw: String) -> FillMode? {
        FillMode(rawValue: raw.lowercased().trimmingCharacters(in: .whitespaces))
    }
}

/// Whether applying a wallpaper changes every Space or only the one on screen.
///
/// macOS stores the desktop picture per Space, so "all" means walle has to write the private
/// wallpaper store after applying. "current" is the ordinary macOS behaviour.
public enum SpacesMode: String, Sendable, CaseIterable {
    case current, all

    public static func parse(_ raw: String) -> SpacesMode? {
        switch raw.lowercased().trimmingCharacters(in: .whitespaces) {
        case "current", "single", "individual", "off": return .current
        case "all", "every", "sync", "on": return .all
        default: return nil
        }
    }
}

/// Everything tunable, parsed from a plain key = value file.
///
/// Geometry is expressed in design units for a 1920-wide screen. Layout multiplies every
/// length by scale = screenWidth / designWidth, so the whole composition scales with the
/// display instead of being pinned to one resolution.
public struct Config: Sendable, Equatable {
    public var wallpaperDirs: [String]
    public var recursive: Bool
    public var sort: SortMode

    public var designWidth: Double
    public var slots: Int
    public var cardWidth: Double
    public var cardHeight: Double
    public var cardGap: Double
    public var selectedCardHeight: Double
    public var expandedCardWidth: Double
    public var expandedCardHeight: Double
    public var cardSkew: Double
    public var cardCornerRadius: Double
    public var cardBorderWidth: Double
    public var cardBorderColor: String
    public var rowCenterYFrac: Double
    public var dimFalloff: Double
    public var dimFloor: Double
    public var dimAlpha: Double
    /// Alpha for every non-focused card while the preview is expanded. Kept very low so
    /// the expanded card is the only thing competing for attention.
    public var expandedNeighbourAlpha: Double
    public var animationMs: Double
    public var expandOnEnter: Bool

    public var applyTo: ApplyTarget
    public var fillMode: FillMode
    public var spaces: SpacesMode
    public var thumbMaxPx: Int
    public var previewMaxPx: Int
    public var logLevel: String

    public init(
        wallpaperDirs: [String] = ["~/Downloads/wallpaper"],
        recursive: Bool = true,
        sort: SortMode = .name,
        designWidth: Double = 1920,
        slots: Int = 5,
        cardWidth: Double = 280,
        cardHeight: Double = 420,
        cardGap: Double = 10,
        selectedCardHeight: Double = 540,
        expandedCardWidth: Double = 880,
        expandedCardHeight: Double = 400,
        cardSkew: Double = -0.25,
        cardCornerRadius: Double = 12,
        cardBorderWidth: Double = 3,
        cardBorderColor: String = "FF9F0A",
        rowCenterYFrac: Double = 0.5,
        dimFalloff: Double = 0,
        dimFloor: Double = 0.35,
        dimAlpha: Double = 0.35,
        expandedNeighbourAlpha: Double = 0.06,
        animationMs: Double = 350,
        expandOnEnter: Bool = true,
        applyTo: ApplyTarget = .all,
        fillMode: FillMode = .fill,
        spaces: SpacesMode = .current,
        thumbMaxPx: Int = 1600,
        previewMaxPx: Int = 1600,
        logLevel: String = "warn"
    ) {
        self.wallpaperDirs = wallpaperDirs
        self.recursive = recursive
        self.sort = sort
        self.designWidth = designWidth
        self.slots = slots
        self.cardWidth = cardWidth
        self.cardHeight = cardHeight
        self.cardGap = cardGap
        self.selectedCardHeight = selectedCardHeight
        self.expandedCardWidth = expandedCardWidth
        self.expandedCardHeight = expandedCardHeight
        self.cardSkew = cardSkew
        self.cardCornerRadius = cardCornerRadius
        self.cardBorderWidth = cardBorderWidth
        self.cardBorderColor = cardBorderColor
        self.rowCenterYFrac = rowCenterYFrac
        self.dimFalloff = dimFalloff
        self.dimFloor = dimFloor
        self.dimAlpha = dimAlpha
        self.expandedNeighbourAlpha = expandedNeighbourAlpha
        self.animationMs = animationMs
        self.expandOnEnter = expandOnEnter
        self.applyTo = applyTo
        self.fillMode = fillMode
        self.spaces = spaces
        self.thumbMaxPx = thumbMaxPx
        self.previewMaxPx = previewMaxPx
        self.logLevel = logLevel
    }

    /// Every key, in the order it is written to the config file.
    ///
    /// This is the single place a key is registered: `apply(key:value:)` and
    /// `value(forKey:)` are both driven by `keyTable`, so adding a setting means editing
    /// the stored property (and its default in `init`) and adding one entry below — not the
    /// four parallel switches this used to need. A round-trip test guards the table.
    public static let keyOrder: [String] = keyTable.map(\.name)

    /// One entry per config key: its name, how to render the current value, and how to apply
    /// a raw string to it. `set` takes `inout` so a malformed value can leave the previous
    /// value untouched — a typo must not reset a setting.
    private static let keyTable: [ConfigKey] = [
        ConfigKey(name: "wallpaper_dirs",
                  get: { $0.wallpaperDirs.joined(separator: ":") },
                  set: { config, value in
                      config.wallpaperDirs = value.split(separator: ":")
                          .map { String($0).trimmingCharacters(in: .whitespaces) }
                          .filter { !$0.isEmpty }
                  }),
        ConfigKey(name: "recursive",
                  get: { boolString($0.recursive) },
                  set: { config, value in config.recursive = parseBool(value) ?? config.recursive }),
        ConfigKey(name: "sort",
                  get: { $0.sort.rawValue },
                  set: { config, value in config.sort = SortMode.parse(value) ?? config.sort }),
        ConfigKey(name: "design_width",
                  get: { num($0.designWidth) },
                  set: { config, value in config.designWidth = parseDouble(value) ?? config.designWidth }),
        ConfigKey(name: "slots",
                  get: { String($0.slots) },
                  set: { config, value in config.slots = parseInt(value) ?? config.slots }),
        ConfigKey(name: "card_width",
                  get: { num($0.cardWidth) },
                  set: { config, value in config.cardWidth = parseDouble(value) ?? config.cardWidth }),
        ConfigKey(name: "card_height",
                  get: { num($0.cardHeight) },
                  set: { config, value in config.cardHeight = parseDouble(value) ?? config.cardHeight }),
        ConfigKey(name: "card_gap",
                  get: { num($0.cardGap) },
                  set: { config, value in config.cardGap = parseDouble(value) ?? config.cardGap }),
        ConfigKey(name: "selected_card_height",
                  get: { num($0.selectedCardHeight) },
                  set: { config, value in config.selectedCardHeight = parseDouble(value) ?? config.selectedCardHeight }),
        ConfigKey(name: "expanded_card_width",
                  get: { num($0.expandedCardWidth) },
                  set: { config, value in config.expandedCardWidth = parseDouble(value) ?? config.expandedCardWidth }),
        ConfigKey(name: "expanded_card_height",
                  get: { num($0.expandedCardHeight) },
                  set: { config, value in config.expandedCardHeight = parseDouble(value) ?? config.expandedCardHeight }),
        ConfigKey(name: "card_skew",
                  get: { num($0.cardSkew) },
                  set: { config, value in config.cardSkew = parseDouble(value) ?? config.cardSkew }),
        ConfigKey(name: "card_corner_radius",
                  get: { num($0.cardCornerRadius) },
                  set: { config, value in config.cardCornerRadius = parseDouble(value) ?? config.cardCornerRadius }),
        ConfigKey(name: "card_border_width",
                  get: { num($0.cardBorderWidth) },
                  set: { config, value in config.cardBorderWidth = parseDouble(value) ?? config.cardBorderWidth }),
        ConfigKey(name: "card_border_color",
                  get: { $0.cardBorderColor },
                  set: { config, value in config.cardBorderColor = value }),
        ConfigKey(name: "row_center_y_frac",
                  get: { num($0.rowCenterYFrac) },
                  set: { config, value in config.rowCenterYFrac = parseDouble(value) ?? config.rowCenterYFrac }),
        ConfigKey(name: "dim_falloff",
                  get: { num($0.dimFalloff) },
                  set: { config, value in config.dimFalloff = parseDouble(value) ?? config.dimFalloff }),
        ConfigKey(name: "dim_floor",
                  get: { num($0.dimFloor) },
                  set: { config, value in config.dimFloor = parseDouble(value) ?? config.dimFloor }),
        ConfigKey(name: "dim_alpha",
                  get: { num($0.dimAlpha) },
                  set: { config, value in config.dimAlpha = parseDouble(value) ?? config.dimAlpha }),
        ConfigKey(name: "expanded_neighbour_alpha",
                  get: { num($0.expandedNeighbourAlpha) },
                  set: { config, value in config.expandedNeighbourAlpha = parseDouble(value) ?? config.expandedNeighbourAlpha }),
        ConfigKey(name: "animation_ms",
                  get: { num($0.animationMs) },
                  set: { config, value in config.animationMs = parseDouble(value) ?? config.animationMs }),
        ConfigKey(name: "expand_on_enter",
                  get: { boolString($0.expandOnEnter) },
                  set: { config, value in config.expandOnEnter = parseBool(value) ?? config.expandOnEnter }),
        ConfigKey(name: "apply_to",
                  get: { $0.applyTo.rawValue },
                  set: { config, value in config.applyTo = ApplyTarget.parse(value) ?? config.applyTo }),
        ConfigKey(name: "fill_mode",
                  get: { $0.fillMode.rawValue },
                  set: { config, value in config.fillMode = FillMode.parse(value) ?? config.fillMode }),
        ConfigKey(name: "spaces",
                  get: { $0.spaces.rawValue },
                  set: { config, value in config.spaces = SpacesMode.parse(value) ?? config.spaces }),
        ConfigKey(name: "thumb_max_px",
                  get: { String($0.thumbMaxPx) },
                  set: { config, value in config.thumbMaxPx = parseInt(value) ?? config.thumbMaxPx }),
        ConfigKey(name: "preview_max_px",
                  get: { String($0.previewMaxPx) },
                  set: { config, value in config.previewMaxPx = parseInt(value) ?? config.previewMaxPx }),
        ConfigKey(name: "log_level",
                  get: { $0.logLevel },
                  set: { config, value in config.logLevel = value }),
    ]

    public static func parse(_ text: String) -> (config: Config, warnings: [String]) {
        var config = Config()
        var warnings: [String] = []
        for (lineNumber, rawLine) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else {
                warnings.append("line \(lineNumber + 1): not a key = value pair, ignored")
                continue
            }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !config.apply(key: key, value: value) {
                warnings.append("line \(lineNumber + 1): unknown key \(key), ignored")
            }
        }
        return (config, warnings)
    }

    /// Applies one `key = value` pair. Returns false for an unknown key, which the parser
    /// turns into a warning, so a typo is not silently ignored.
    @discardableResult
    public mutating func apply(key: String, value: String) -> Bool {
        guard let entry = Config.keyTable.first(where: { $0.name == key }) else { return false }
        entry.set(&self, value)
        return true
    }

    /// The current value of a key rendered exactly as `serialized()` writes it, or nil for
    /// an unknown key.
    public func value(forKey key: String) -> String? {
        Config.keyTable.first(where: { $0.name == key })?.get(self)
    }

    public func serialized() -> String {
        var lines: [String] = []
        lines.append("# walle configuration")
        lines.append("# Geometry is in design units for a 1920-wide screen and is scaled to")
        lines.append("# the display automatically. Managed by: walle config set KEY VALUE")
        lines.append("")
        for key in Config.keyOrder {
            lines.append(key + " = " + (value(forKey: key) ?? ""))
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    public static func load(from url: URL, fileManager: FileManager = .default) -> (config: Config, warnings: [String]) {
        guard let data = fileManager.contents(atPath: url.path),
              let text = String(data: data, encoding: .utf8) else {
            return (Config(), [])
        }
        return parse(text)
    }

    public func save(to url: URL, fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(serialized().utf8).write(to: url, options: .atomic)
    }

    public func sanitized() -> (config: Config, warnings: [String]) {
        var c = self
        var warnings: [String] = []
        func clamp(_ name: String, _ value: inout Double, _ low: Double, _ high: Double) {
            if value.isNaN || value < low || value > high {
                warnings.append("\(name) = \(value) out of range \(low)...\(high), clamped")
                value = value.isNaN ? low : min(max(value, low), high)
            }
        }
        if c.slots < 1 { warnings.append("slots must be >= 1, using 1"); c.slots = 1 }
        if c.slots % 2 == 0 { warnings.append("slots must be odd, using \(c.slots - 1)"); c.slots -= 1 }
        clamp("design_width", &c.designWidth, 320, 20000)
        clamp("card_width", &c.cardWidth, 8, 4000)
        clamp("card_height", &c.cardHeight, 8, 4000)
        clamp("card_gap", &c.cardGap, 0, 2000)
        clamp("selected_card_height", &c.selectedCardHeight, 8, 4000)
        clamp("expanded_card_width", &c.expandedCardWidth, 8, 8000)
        clamp("expanded_card_height", &c.expandedCardHeight, 8, 8000)
        clamp("card_skew", &c.cardSkew, -2, 2)
        clamp("card_corner_radius", &c.cardCornerRadius, 0, 400)
        clamp("card_border_width", &c.cardBorderWidth, 0, 40)
        clamp("row_center_y_frac", &c.rowCenterYFrac, 0, 1)
        clamp("dim_falloff", &c.dimFalloff, 0, 1)
        clamp("dim_floor", &c.dimFloor, 0, 1)
        clamp("dim_alpha", &c.dimAlpha, 0, 1)
        clamp("expanded_neighbour_alpha", &c.expandedNeighbourAlpha, 0, 1)
        clamp("animation_ms", &c.animationMs, 0, 5000)
        if c.thumbMaxPx < 16 { warnings.append("thumb_max_px too small, using 16"); c.thumbMaxPx = 16 }
        if c.previewMaxPx < 16 { warnings.append("preview_max_px too small, using 16"); c.previewMaxPx = 16 }
        if c.wallpaperDirs.isEmpty { warnings.append("wallpaper_dirs is empty") }
        return (c, warnings)
    }
}

/// One registered config key. The closures are `@Sendable` and capture nothing, so
/// `Config.keyTable` can be a concurrency-safe `static let` under Swift 6.
private struct ConfigKey: Sendable {
    let name: String
    let get: @Sendable (Config) -> String
    let set: @Sendable (inout Config, String) -> Void
}

private func parseBool(_ raw: String) -> Bool? {
    switch raw.lowercased() {
    case "true", "yes", "on", "1": return true
    case "false", "no", "off", "0": return false
    default: return nil
    }
}

private func boolString(_ value: Bool) -> String { value ? "true" : "false" }
private func parseInt(_ raw: String) -> Int? { Int(raw) }
private func parseDouble(_ raw: String) -> Double? { Double(raw) }

private func num(_ value: Double) -> String {
    if value == value.rounded() && abs(value) < 1e15 {
        return String(Int(value))
    }
    return String(value)
}
