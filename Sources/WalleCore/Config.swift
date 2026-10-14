import Foundation

public enum SortMode: String, Sendable, CaseIterable {
    case name, mtime, random

    public static func parse(_ raw: String) -> SortMode? {
        SortMode(rawValue: raw.lowercased().trimmingCharacters(in: .whitespaces))
    }
}

public enum ShearMode: String, Sendable, CaseIterable {
    case uniform, mirror

    public static func parse(_ raw: String) -> ShearMode? {
        ShearMode(rawValue: raw.lowercased().trimmingCharacters(in: .whitespaces))
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

/// Everything tunable, parsed from a plain "key = value" file.
/// A deliberately dumb format: Swift needs no TOML or JSON parser for it, it stays
/// hand-editable, and Config.set can rewrite it without losing comments elsewhere.
public struct Config: Sendable, Equatable {
    public var wallpaperDirs: [String]
    public var recursive: Bool
    public var sort: SortMode

    public var slots: Int
    public var tileWidth: Double
    public var tileHeight: Double
    public var tileShear: Double
    public var shearMode: ShearMode
    public var overlap: Double
    public var depthStep: Double
    public var perspective: Double
    public var scaleFalloff: Double
    public var dimFalloff: Double
    public var dimFloor: Double
    public var expandOnEnter: Bool
    public var hoverPromotes: Bool
    public var rowCenterYFrac: Double
    public var previewMaxWFrac: Double
    public var previewMaxHFrac: Double
    public var previewGap: Double
    public var dimAlpha: Double
    public var animationMs: Double

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
        slots: Int = 9,
        tileWidth: Double = 100,
        tileHeight: Double = 500,
        tileShear: Double = 0.22,
        shearMode: ShearMode = .uniform,
        overlap: Double = 0.22,
        depthStep: Double = 130,
        perspective: Double = 1200,
        scaleFalloff: Double = 0.85,
        dimFalloff: Double = 0.22,
        dimFloor: Double = 0.15,
        expandOnEnter: Bool = true,
        hoverPromotes: Bool = true,
        rowCenterYFrac: Double = 0.50,
        previewMaxWFrac: Double = 0.46,
        previewMaxHFrac: Double = 0.56,
        previewGap: Double = 18,
        dimAlpha: Double = 0.35,
        animationMs: Double = 220,
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
        self.slots = slots
        self.tileWidth = tileWidth
        self.tileHeight = tileHeight
        self.tileShear = tileShear
        self.shearMode = shearMode
        self.overlap = overlap
        self.depthStep = depthStep
        self.perspective = perspective
        self.scaleFalloff = scaleFalloff
        self.dimFalloff = dimFalloff
        self.dimFloor = dimFloor
        self.expandOnEnter = expandOnEnter
        self.hoverPromotes = hoverPromotes
        self.rowCenterYFrac = rowCenterYFrac
        self.previewMaxWFrac = previewMaxWFrac
        self.previewMaxHFrac = previewMaxHFrac
        self.previewGap = previewGap
        self.dimAlpha = dimAlpha
        self.animationMs = animationMs
        self.applyTo = applyTo
        self.fillMode = fillMode
        self.thumbMaxPx = thumbMaxPx
        self.previewMaxPx = previewMaxPx
        self.typeToFilter = typeToFilter
        self.logLevel = logLevel
    }

    /// The order keys are written out in. Also the canonical key list.
    public static let keyOrder: [String] = [
        "wallpaper_dirs", "recursive", "sort",
        "slots", "tile_width", "tile_height", "tile_shear", "shear_mode", "overlap",
        "depth_step", "perspective", "scale_falloff", "dim_falloff", "dim_floor",
        "expand_on_enter", "hover_promotes", "row_center_y_frac",
        "preview_max_w_frac", "preview_max_h_frac", "preview_gap",
        "dim_alpha", "animation_ms",
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

    /// Returns false when the key is unknown. Malformed values keep the default and warn.
    @discardableResult
    public mutating func apply(key: String, value: String) -> Bool {
        switch key {
        case "wallpaper_dirs":
            wallpaperDirs = value.split(separator: ":").map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        case "recursive": recursive = parseBool(value) ?? recursive
        case "sort": sort = SortMode.parse(value) ?? sort
        case "slots": slots = parseInt(value) ?? slots
        case "tile_width": tileWidth = parseDouble(value) ?? tileWidth
        case "tile_height": tileHeight = parseDouble(value) ?? tileHeight
        case "tile_shear": tileShear = parseDouble(value) ?? tileShear
        case "shear_mode": shearMode = ShearMode.parse(value) ?? shearMode
        case "overlap": overlap = parseDouble(value) ?? overlap
        case "depth_step": depthStep = parseDouble(value) ?? depthStep
        case "perspective": perspective = parseDouble(value) ?? perspective
        case "scale_falloff": scaleFalloff = parseDouble(value) ?? scaleFalloff
        case "dim_falloff": dimFalloff = parseDouble(value) ?? dimFalloff
        case "dim_floor": dimFloor = parseDouble(value) ?? dimFloor
        case "expand_on_enter": expandOnEnter = parseBool(value) ?? expandOnEnter
        case "hover_promotes": hoverPromotes = parseBool(value) ?? hoverPromotes
        case "row_center_y_frac": rowCenterYFrac = parseDouble(value) ?? rowCenterYFrac
        case "preview_max_w_frac": previewMaxWFrac = parseDouble(value) ?? previewMaxWFrac
        case "preview_max_h_frac": previewMaxHFrac = parseDouble(value) ?? previewMaxHFrac
        case "preview_gap": previewGap = parseDouble(value) ?? previewGap
        case "dim_alpha": dimAlpha = parseDouble(value) ?? dimAlpha
        case "animation_ms": animationMs = parseDouble(value) ?? animationMs
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
        case "slots": return String(slots)
        case "tile_width": return num(tileWidth)
        case "tile_height": return num(tileHeight)
        case "tile_shear": return num(tileShear)
        case "shear_mode": return shearMode.rawValue
        case "overlap": return num(overlap)
        case "depth_step": return num(depthStep)
        case "perspective": return num(perspective)
        case "scale_falloff": return num(scaleFalloff)
        case "dim_falloff": return num(dimFalloff)
        case "dim_floor": return num(dimFloor)
        case "expand_on_enter": return boolString(expandOnEnter)
        case "hover_promotes": return boolString(hoverPromotes)
        case "row_center_y_frac": return num(rowCenterYFrac)
        case "preview_max_w_frac": return num(previewMaxWFrac)
        case "preview_max_h_frac": return num(previewMaxHFrac)
        case "preview_gap": return num(previewGap)
        case "dim_alpha": return num(dimAlpha)
        case "animation_ms": return num(animationMs)
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
        lines.append("# Managed by: walle config set KEY VALUE   (or edit directly)")
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

    /// Validated for the picker: values that would produce nonsense geometry are clamped.
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
        clamp("tile_width", &c.tileWidth, 24, 2000)
        clamp("tile_height", &c.tileHeight, 24, 2000)
        clamp("tile_shear", &c.tileShear, -2, 2)
        clamp("overlap", &c.overlap, 0, 0.9)
        clamp("depth_step", &c.depthStep, 0, 10000)
        clamp("perspective", &c.perspective, 1, 100000)
        clamp("scale_falloff", &c.scaleFalloff, 0.05, 1.5)
        clamp("dim_falloff", &c.dimFalloff, 0, 1)
        clamp("dim_floor", &c.dimFloor, 0, 1)
        clamp("row_center_y_frac", &c.rowCenterYFrac, 0, 1)
        clamp("preview_max_w_frac", &c.previewMaxWFrac, 0.05, 1)
        clamp("preview_max_h_frac", &c.previewMaxHFrac, 0.05, 1)
        clamp("preview_gap", &c.previewGap, 0, 500)
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
