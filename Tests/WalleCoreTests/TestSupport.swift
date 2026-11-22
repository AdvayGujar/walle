import CoreGraphics
import Foundation
import ImageIO
@testable import WalleCore

/// Builds a LayoutEngine for the standard test screen unless a test overrides it.
func makeLayoutEngine(
    expanded: Bool = false,
    screen: ScreenMetrics = ScreenMetrics(width: 1512, height: 982),
    configure: (inout Config) -> Void = { _ in }
) -> LayoutEngine {
    var config = Config()
    configure(&config)
    return LayoutEngine(config: config, screen: screen, expanded: expanded)
}

/// Runs a body inside a fresh temporary directory and always removes it.
func withTempDirectory<T>(_ body: (URL) throws -> T) rethrows -> T {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("walle-core-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try body(dir)
}

enum TestImageError: Error {
    case couldNotCreateContext
}

/// A tiny HEIC fixture for the fake upscaler module.
func makeTestHEIC(at url: URL, width: Int, height: Int) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        throw TestImageError.couldNotCreateContext
    }
    context.setFillColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.heic" as CFString, 1, nil) else {
        throw TestImageError.couldNotCreateContext
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw TestImageError.couldNotCreateContext
    }
}

/// Writes a small PNG with a two-colour checkerboard. Used to exercise the
/// upscaler on real pixels without depending on a fixture binary.
func makeTestPNG(at url: URL, width: Int, height: Int,
                 colorSpace: CGColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!,
                 opaque: Bool = true, orientation: Int = 1) throws {
    let alpha: CGImageAlphaInfo = opaque ? .noneSkipLast : .premultipliedLast
    let bitmapInfo = CGBitmapInfo(rawValue: alpha.rawValue)
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: colorSpace, bitmapInfo: bitmapInfo.rawValue) else {
        throw TestImageError.couldNotCreateContext
    }
    for y in 0..<height {
        for x in 0..<width {
            let isLight = (x / 2 + y / 2) % 2 == 0
            context.setFillColor(red: isLight ? 0.9 : 0.1,
                                 green: isLight ? 0.4 : 0.2,
                                 blue: isLight ? 0.2 : 0.8,
                                 alpha: opaque ? 1 : (isLight ? 1 : 0.5))
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil) else {
        throw TestImageError.couldNotCreateContext
    }
    let properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw TestImageError.couldNotCreateContext
    }
}
