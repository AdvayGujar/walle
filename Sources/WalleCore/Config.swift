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
    public var animationMs: Double
    public var expandOnEnter: Bool
    public var hoverPromotes: Bool

    public var applyTo: ApplyTarget
    public var fillMode: FillMode
    public var thumbMaxPx: Int
    public var previewMaxPx: Int
    public var typeToFilter: Bool
    public var logLevel: String

    public init(
        wallpaperDirs: [String] = ["~/Downloads/wallpaper"],
        recursive: Bool = true,
        sort: SortMode = .name,
        designWidth: Double = 1920,
        slots: Int = 5,
        cardWidth: Double = 120,
        cardHeight: Double = 420,
        cardGap: Double = 10,
        selectedCardHeight: Double = 540,
        expandedCardWidth: Double = 880,
        expandedCardHeight: Double = 400,
        cardSkew: Double = -0.35,
        cardCornerRadius: Double = 12,
        cardBorderWidth: Double = 3,
        cardBorderColor: String = "FF9F0A",
        rowCenterYFrac: Double = 0.5,
        dimFalloff: Double = 0.18,
        dimFloor: Double = 0.35,
        dimAlpha: Double = 0.35,
        animationMs: Double = 350,
        expandOnEnter: Bool = true,
        hoverPromotes: Bool = true,
        applyTo: ApplyTarget = .all,
        fillMode: FillMode = .fill,
        thumbMaxPx: Int = 512,
        previewMaxPx: Int = 1600,
        typeToFilter: Bool = true,
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
        self.animationMs = animationMs
        self.expandOnEnter = expandOnEnter
        self.hoverPromotes = hoverPromotes
        self.applyTo = applyTo
        self.fillMode = fillMode
        self.thumbMaxPx = thumbMaxPx
        self.previewMaxPx = previewMaxPx
        self.typeToFilter = typeToFilter
        self.logLevel = logLevel
    }

    public static let keyOrder: [String] = [
        "wallpaper_dirs", "recursive", "sort",
        "design_width", "slots",
        "card_width", "card_height", "card_gap", "selected_card_height",
        "expanded_card_width", "expanded_card_height",
        "card_skew", "card_corner_radius", "card_border_width", "card_border_color",
        "row_center_y_frac", "dim_falloff", "dim_floor", "dim_alpha",
        "animation_ms", "expand_on_enter", "hover_promotes",
        "apply_to", "fill_mode", "thumb_max_px", "preview_max_px",
        "type_to_filter", "log_level",
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

    @discardableResult
    public mutating func apply(key: String, value: String) -> Bool {
        switch key {
        case "wallpaper_dirs":
            wallpaperDirs = value.split(separator: ":").map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        case "recursive": recursive = parseBool(value) ?? recursive
        case "sort": sort = SortMode.parse(value) ?? sort
        case "design_width": designWidth = parseDouble(value) ?? designWidth
        case "slots": slots = parseInt(value) ?? slots
        case "card_width": cardWidth = parseDouble(value) ?? cardWidth
        case "card_height": cardHeight = parseDouble(value) ?? cardHeight
        case "card_gap": cardGap = parseDouble(value) ?? cardGap
        case "selected_card_height": selectedCardHeight = parseDouble(value) ?? selectedCardHeight
        case "expanded_card_width": expandedCardWidth = parseDouble(value) ?? expandedCardWidth
        case "expanded_card_height": expandedCardHeight = parseDouble(value) ?? expandedCardHeight
        case "card_skew": cardSkew = parseDouble(value) ?? cardSkew
        case "card_corner_radius": cardCornerRadius = parseDouble(value) ?? cardCornerRadius
        case "card_border_width": cardBorderWidth = parseDouble(value) ?? cardBorderWidth
        case "card_border_color": cardBorderColor = value
        case "row_center_y_frac": rowCenterYFrac = parseDouble(value) ?? rowCenterYFrac
        case "dim_falloff": dimFalloff = parseDouble(value) ?? dimFalloff
        case "dim_floor": dimFloor = parseDouble(value) ?? dimFloor
        case "dim_alpha": dimAlpha = parseDouble(value) ?? dimAlpha
        case "animation_ms": animationMs = parseDouble(value) ?? animationMs
        case "expand_on_enter": expandOnEnter = parseBool(value) ?? expandOnEnter
        case "hover_promotes": hoverPromotes = parseBool(value) ?? hoverPromotes
        case "apply_to": applyTo = ApplyTarget.parse(value) ?? applyTo
        case "fill_mode": fillMode = FillMode.parse(value) ?? fillMode
        case "thumb_max_px": thumbMaxPx = parseInt(value) ?? thumbMaxPx
        case "preview_max_px": previewMaxPx = parseInt(value) ?? previewMaxPx
        case "type_to_filter": typeToFilter = parseBool(value) ?? typeToFilter
        case "log_level": logLevel = value
        default: return false
        }
        return true
    }

    public func value(forKey key: String) -> String? {
        switch key {
        case "wallpaper_dirs": return wallpaperDirs.joined(separator: ":")
        case "recursive": return boolString(recursive)
        case "sort": return sort.rawValue
        case "design_width": return num(designWidth)
        case "slots": return String(slots)
        case "card_width": return num(cardWidth)
        case "card_height": return num(cardHeight)
        case "card_gap": return num(cardGap)
        case "selected_card_height": return num(selectedCardHeight)
        case "expanded_card_width": return num(expandedCardWidth)
        case "expanded_card_height": return num(expandedCardHeight)
        case "card_skew": return num(cardSkew)
        case "card_corner_radius": return num(cardCornerRadius)
        case "card_border_width": return num(cardBorderWidth)
        case "card_border_color": return cardBorderColor
        case "row_center_y_frac": return num(rowCenterYFrac)
        case "dim_falloff": return num(dimFalloff)
        case "dim_floor": return num(dimFloor)
        case "dim_alpha": return num(dimAlpha)
        case "animation_ms": return num(animationMs)
        case "expand_on_enter": return boolString(expandOnEnter)
        case "hover_promotes": return boolString(hoverPromotes)
        case "apply_to": return applyTo.rawValue
        case "fill_mode": return fillMode.rawValue
        case "thumb_max_px": return String(thumbMaxPx)
        case "preview_max_px": return String(previewMaxPx)
        case "type_to_filter": return boolString(typeToFilter)
        case "log_level": return logLevel
        default: return nil
        }
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
        clamp("animation_ms", &c.animationMs, 0, 5000)
        if c.thumbMaxPx < 16 { warnings.append("thumb_max_px too small, using 16"); c.thumbMaxPx = 16 }
        if c.previewMaxPx < 16 { warnings.append("preview_max_px too small, using 16"); c.previewMaxPx = 16 }
        if c.wallpaperDirs.isEmpty { warnings.append("wallpaper_dirs is empty") }
        return (c, warnings)
    }
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
