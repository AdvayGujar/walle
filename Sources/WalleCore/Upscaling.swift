import CoreGraphics
import CryptoKit
import Darwin
import Foundation
import ImageIO

public struct PixelSize: Sendable, Equatable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    public var description: String { "\(width)x\(height)" }

    /// Parses `3024x1964` (the `x` is case-insensitive). Used by `--target`.
    public static func parse(_ raw: String) -> PixelSize? {
        let parts = raw.lowercased().split(separator: "x")
        guard parts.count == 2,
              let width = Int(parts[0]), let height = Int(parts[1]),
              width > 0, height > 0 else { return nil }
        return PixelSize(width: width, height: height)
    }
}

/// Why an image was not handed to the ML upscaler.
public enum UpscaleSkipReason: Error, Sendable, Equatable, CustomStringConvertible {
    case centerMode
    case alreadyLargeEnough
    case exceedsMaxScale(Double)
    case unsupported(String)

    public var description: String {
        switch self {
        case .centerMode:
            return "center mode does not scale; choose fill, fit or stretch"
        case .alreadyLargeEnough:
            return "source already covers the target"
        case .exceedsMaxScale(let scale):
            return "needs \(String(format: "%.2f", scale))x, above --max-scale"
        case .unsupported(let why):
            return why
        }
    }
}

public struct UpscalePlan: Sendable, Equatable {
    public var sourceWidth: Int
    public var sourceHeight: Int
    public var targetWidth: Int
    public var targetHeight: Int
    public var requiredScale: Double
    public var outputScale: Int
}

/// Pure sizing rules for `walle upscale`.
///
/// The ML upscaler produces a 2×, 3× or 4× copy; the desktop pipeline then does
/// the small final crop/scale. `fill`/`stretch` use the cover scale, `fit` the
/// contain scale, and `center` is skipped because macOS does not scale it.
public enum UpscaleGeometry {
    public static func plan(sourceWidth: Int, sourceHeight: Int,
                            target: PixelSize, mode: FillMode,
                            maxScale: Double,
                            scaleOverride: Int? = nil) -> Result<UpscalePlan, UpscaleSkipReason> {
        guard sourceWidth > 0, sourceHeight > 0, target.width > 0, target.height > 0 else {
            return .failure(.alreadyLargeEnough)
        }
        if mode == .center { return .failure(.centerMode) }

        let horizontal = Double(target.width) / Double(sourceWidth)
        let vertical = Double(target.height) / Double(sourceHeight)
        let required = mode == .fit ? min(horizontal, vertical) : max(horizontal, vertical)
        guard required > 1 else { return .failure(.alreadyLargeEnough) }
        guard required <= maxScale else { return .failure(.exceedsMaxScale(required)) }

        return .success(UpscalePlan(
            sourceWidth: sourceWidth,
            sourceHeight: sourceHeight,
            targetWidth: target.width,
            targetHeight: target.height,
            requiredScale: required,
            outputScale: scaleOverride ?? outputScale(for: required)))
    }

    /// Pick the smallest model pass that gets close to the display. A 2× pass
    /// leaves a tiny final scale, which is cheaper and avoids inventing more
    /// detail than necessary.
    public static func outputScale(for required: Double) -> Int {
        if required <= 2.1 { return 2 }
        if required <= 3.0 { return 3 }
        return 4
    }
}

public enum UpscaleInspectError: Error, CustomStringConvertible {
    case unreadableSource(String)
    case missingDimensions(String)

    public var description: String {
        switch self {
        case .unreadableSource(let path):
            return "could not read image: " + path
        case .missingDimensions(let path):
            return "could not read image dimensions: " + path
        }
    }
}

/// Everything the CLI needs to decide which images need an ML pass, without
/// decoding pixels.
public struct UpscaleSourceInfo: Sendable, Equatable {
    public var width: Int
    public var height: Int
    public var bitsPerComponent: Int
    public var colorModel: String
    public var hasAlpha: Bool
    public var hasHDRGainMap: Bool
    public var profileName: String?
    public var fileSize: Int
    public var modifiedAt: Date
}

public enum UpscaleInspector {
    public static func inspect(_ url: URL) throws -> UpscaleSourceInfo {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any] else {
            throw UpscaleInspectError.unreadableSource(url.path)
        }
        guard let rawWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let rawHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              rawWidth > 0, rawHeight > 0 else {
            throw UpscaleInspectError.missingDimensions(url.path)
        }

        let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let swapsDimensions = orientation >= 5 && orientation <= 8

        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let modified = attributes?[.modificationDate] as? Date ?? Date(timeIntervalSince1970: 0)

        return UpscaleSourceInfo(
            width: swapsDimensions ? rawHeight : rawWidth,
            height: swapsDimensions ? rawWidth : rawHeight,
            bitsPerComponent: (properties[kCGImagePropertyDepth] as? NSNumber)?.intValue ?? 8,
            colorModel: (properties[kCGImagePropertyColorModel] as? String) ?? "RGB",
            hasAlpha: (properties[kCGImagePropertyHasAlpha] as? NSNumber)?.boolValue ?? false,
            hasHDRGainMap: CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                source, 0, kCGImageAuxiliaryDataTypeHDRGainMap) != nil,
            profileName: properties[kCGImagePropertyProfileName] as? String,
            fileSize: size,
            modifiedAt: modified)
    }

    /// A reason to leave this source alone, or nil when it can go to the ML
    /// backend. HEIC output cannot carry transparency, and this pipeline only
    /// accepts 8-bit RGB without HDR gain maps.
    public static func skipReason(for info: UpscaleSourceInfo) -> UpscaleSkipReason? {
        guard info.bitsPerComponent == 8 else {
            return .unsupported("unsupported bit depth \(info.bitsPerComponent); "
                                + "only 8-bit RGB images are upscaled")
        }
        guard info.colorModel.uppercased() == "RGB" else {
            return .unsupported("unsupported color model \(info.colorModel); "
                                + "only RGB images are upscaled")
        }
        if info.hasHDRGainMap {
            return .unsupported("HDR gain-map images are not upscaled")
        }
        if info.hasAlpha {
            return .unsupported("transparent images are not supported by HEIC output")
        }
        return nil
    }
}

/// `realpath(3)` resolves `/var` and every other symlink; `URL`'s
/// `resolvingSymlinksInPath()` deliberately leaves some system firmlinks alone.
/// Cache keys must agree between the scanner, the picker and `walle set`, so
/// this is the one path normaliser they all use.
public func walleCanonicalPath(_ path: String) -> String {
    var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
    let resolved = path.withCString { realpath($0, &buffer) }
    if resolved != nil {
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
    return URL(fileURLWithPath: path).standardizedFileURL.path
}

/// A deterministic, short suffix for colliding output names.
public func walleUpscaleNameSuffix(for path: String) -> String {
    let digest = SHA256.hash(data: Data(path.utf8))
    return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
}
