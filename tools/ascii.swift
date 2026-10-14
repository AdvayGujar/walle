import Foundation
import CoreGraphics
import ImageIO

// Renders a PNG as coarse ASCII art so a layout can be inspected without an image viewer.
let path = CommandLine.arguments[1]
let cols = Int(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "76") ?? 76
let rows = Int(CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "30") ?? 30

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("could not load \(path)")
    exit(1)
}
print("source: \(image.width) x \(image.height)")

let space = CGColorSpace(name: CGColorSpace.sRGB)!
var pixels = [UInt8](repeating: 0, count: cols * rows * 4)
guard let context = CGContext(data: &pixels, width: cols, height: rows,
                              bitsPerComponent: 8, bytesPerRow: cols * 4, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    exit(1)
}
context.interpolationQuality = .high
context.draw(image, in: CGRect(x: 0, y: 0, width: cols, height: rows))

let ramp = Array(" .:-=+*#%@")
for y in stride(from: rows - 1, through: 0, by: -1) {
    var line = ""
    for x in 0..<cols {
        let i = (y * cols + x) * 4
        let luminance = (Int(pixels[i]) * 299 + Int(pixels[i + 1]) * 587
                         + Int(pixels[i + 2]) * 114) / 1000
        line.append(ramp[min(ramp.count - 1, luminance * ramp.count / 256)])
    }
    print(line)
}
