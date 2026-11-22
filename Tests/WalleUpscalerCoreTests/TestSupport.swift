import CoreGraphics
import Foundation
import ImageIO

enum TestError: Error {
    case couldNotCreateImage
}

func makePNG(at url: URL, width: Int = 8, height: Int = 8) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
        throw TestError.couldNotCreateImage
    }
    context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
            url as CFURL, "public.png" as CFString, 1, nil) else {
        throw TestError.couldNotCreateImage
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw TestError.couldNotCreateImage
    }
}

func makeDummyModels(at directory: URL, model: String = "test-model") throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data().write(to: directory.appendingPathComponent(model + ".bin"))
    try Data().write(to: directory.appendingPathComponent(model + ".param"))
}

/// A stand-in for upscayl-bin that copies staged inputs to the output directory.
func makeFakeTool(at url: URL, fail: Bool = false) throws {
    let script = """
    #!/bin/sh
    in=""
    out=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -i) in="$2"; shift 2 ;;
            -o) out="$2"; shift 2 ;;
            *) shift ;;
        esac
    done
    \(fail ? "echo 'fake tool failed' >&2\nexit 1" : """
    for f in "$in"/*; do
        base=$(basename "$f")
        cp "$f" "$out/${base%.*}.png"
    done
    """)
    """
    try Data(script.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                          ofItemAtPath: url.path)
}

func withTempDirectory<T>(_ body: (URL) throws -> T) rethrows -> T {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("walle-upscaler-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try body(dir)
}
