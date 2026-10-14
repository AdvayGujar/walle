import Foundation
import CoreGraphics
import ImageIO

// Samples exact pixels from a rendered snapshot using layout coordinates
// (origin bottom-left), and names the nearest debug palette colour.
let path = CommandLine.arguments[1]
let palette: [(String, Double, Double, Double)] = [
    ("R", 1, 0, 0), ("G", 0, 1, 0), ("B", 0, 0, 1), ("Y", 1, 1, 0),
    ("M", 1, 0, 1), ("C", 0, 1, 1), ("O", 1, 0.5, 0), ("P", 0.5, 0, 1),
    ("W", 1, 1, 1),
]
guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("could not load \(path)"); exit(1)
}
let w = image.width, h = image.height
let space = CGColorSpace(name: CGColorSpace.sRGB)!
var pixels = [UInt8](repeating: 0, count: w * h * 4)
guard let context = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                              bytesPerRow: w * 4, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }
context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

for argument in CommandLine.arguments.dropFirst(2) {
    let parts = argument.split(separator: ",")
    guard parts.count == 2, let x = Int(parts[0]), let layoutY = Int(parts[1]) else { continue }
    let row = h - 1 - layoutY
    guard x >= 0, x < w, row >= 0, row < h else { continue }
    let i = (row * w + x) * 4
    let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
    let brightest = max(r, max(g, b))
    var name = "."
    if brightest >= 0.12 {
        let nr = r / brightest, ng = g / brightest, nb = b / brightest
        var best = Double.greatestFiniteMagnitude
        for (label, pr, pg, pb) in palette {
            let d = (nr - pr) * (nr - pr) + (ng - pg) * (ng - pg) + (nb - pb) * (nb - pb)
            if d < best { best = d; name = label }
        }
    }
    print(String(format: "  layout(%4d,%4d) -> rgb(%3d,%3d,%3d) letter=%@",
                 x, layoutY, Int(pixels[i]), Int(pixels[i + 1]), Int(pixels[i + 2]), name))
}
