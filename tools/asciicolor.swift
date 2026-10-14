import Foundation
import CoreGraphics
import ImageIO

// Decodes a --debug-tiles snapshot into letters, so the compositing order of overlapping
// tiles can be read as text. Dimmed tiles are recovered by normalising each pixel.
let path = CommandLine.arguments[1]
let cols = Int(CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "76") ?? 76
let rows = Int(CommandLine.arguments.count > 3 ? CommandLine.arguments[3] : "30") ?? 30

let palette: [(Character, Double, Double, Double)] = [
    ("R", 1, 0, 0), ("G", 0, 1, 0), ("B", 0, 0, 1), ("Y", 1, 1, 0),
    ("M", 1, 0, 1), ("C", 0, 1, 1), ("O", 1, 0.5, 0), ("P", 0.5, 0, 1),
    ("W", 1, 1, 1),
]

guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    print("could not load \(path)")
    exit(1)
}
let space = CGColorSpace(name: CGColorSpace.sRGB)!
var pixels = [UInt8](repeating: 0, count: cols * rows * 4)
guard let context = CGContext(data: &pixels, width: cols, height: rows,
                              bitsPerComponent: 8, bytesPerRow: cols * 4, space: space,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    exit(1)
}
context.interpolationQuality = .none
context.draw(image, in: CGRect(x: 0, y: 0, width: cols, height: rows))

for y in stride(from: rows - 1, through: 0, by: -1) {
    var line = ""
    for x in 0..<cols {
        let i = (y * cols + x) * 4
        let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255
        let b = Double(pixels[i + 2]) / 255
        let brightest = max(r, max(g, b))
        if brightest < 0.12 { line.append(" "); continue }
        let nr = r / brightest, ng = g / brightest, nb = b / brightest
        var best: Character = "?"
        var bestDistance = Double.greatestFiniteMagnitude
        for (name, pr, pg, pb) in palette {
            let d = (nr - pr) * (nr - pr) + (ng - pg) * (ng - pg) + (nb - pb) * (nb - pb)
            if d < bestDistance { bestDistance = d; best = name }
        }
        line.append(best)
    }
    print(line)
}
