import CoreGraphics
import Testing
@testable import WalleCore

@Suite("Card path geometry")
struct CardPathTests {

    // MARK: - Bounding boxes

    @Test func skewZeroPathMatchesTheCardRect() {
        let engine = makeLayoutEngine(expanded: true, screen: ScreenMetrics(width: 1920, height: 1080))
        let centre = engine.slots(count: 5, focus: 0).first { $0.isCenter }!
        #expect(centre.skew == 0)

        let path = CardPath.path(for: centre)
        let bounds = path.boundingBoxOfPath
        #expect(boundsEqual(bounds, centre.rect))
        #expect(approx(Double(bounds.width), Double(centre.rect.width)))
        #expect(approx(Double(bounds.height), Double(centre.rect.height)))
    }

    @Test func skewedPathBoundingBoxMatchesTheParallelogramCorners() {
        let engine = makeLayoutEngine(screen: ScreenMetrics(width: 1920, height: 1080))
        let tile = engine.slots(count: 5, focus: 0).first { $0.offset == 1 }!
        #expect(tile.skew != 0)

        let corners = parallelogramCorners(midWidth: tile.width, height: tile.height, skew: tile.skew,
                                           centerX: Double(tile.rect.midX), minY: Double(tile.rect.minY))
        let expected = boundingBox(of: corners)

        // Without rounding the path reaches every parallelogram corner exactly, and the
        // corner box is the card rect: mid-width plus the lean on both sides.
        let sharp = CardPath.parallelogram(midWidth: tile.width, height: tile.height, skew: tile.skew,
                                           centerX: Double(tile.rect.midX), minY: Double(tile.rect.minY),
                                           cornerRadius: 0)
        #expect(boundsEqual(sharp.boundingBoxOfPath, expected))
        #expect(boundsEqual(expected, tile.rect))
        #expect(boundsEqual(sharp.boundingBoxOfPath, tile.rect))

        // Rounding cuts the extreme corners, so the real card path stays inside that box.
        let rounded = CardPath.path(for: tile)
        let bounds = rounded.boundingBoxOfPath
        #expect(bounds.minX >= tile.rect.minX - 1e-6)
        #expect(bounds.minY >= tile.rect.minY - 1e-6)
        #expect(bounds.maxX <= tile.rect.maxX + 1e-6)
        #expect(bounds.maxY <= tile.rect.maxY + 1e-6)
    }

    // MARK: - Corner rule

    @Test func cornersShiftOppositeWaysAtTopAndBottom() {
        let midWidth = 120.0
        let height = 420.0
        let skew = -0.35
        let centerX = 500.0
        let minY = 100.0
        let path = CardPath.parallelogram(midWidth: midWidth, height: height, skew: skew,
                                          centerX: centerX, minY: minY, cornerRadius: 0)

        let half = midWidth / 2
        let shift = skew * height / 2
        let bottomLeft = CGPoint(x: centerX - shift - half, y: minY)
        let bottomRight = CGPoint(x: centerX - shift + half, y: minY)
        let topRight = CGPoint(x: centerX + shift + half, y: minY + height)
        let topLeft = CGPoint(x: centerX + shift - half, y: minY + height)

        for corner in [bottomLeft, bottomRight, topRight, topLeft] {
            #expect(path.contains(corner, using: .winding), "corner \(corner) should be on the path")
        }

        // Top and bottom shift by equal and opposite amounts.
        #expect(approx(topLeft.x - bottomLeft.x, 2 * shift))
        #expect(approx(topRight.x - bottomRight.x, 2 * shift))
        #expect(approx(topLeft.x - centerX, shift - half))
        #expect(approx(bottomLeft.x - centerX, -shift - half))

        // A corner that shifts the "wrong" way is outside the path.
        let wrongBottomLeft = CGPoint(x: centerX + shift - half, y: minY)
        #expect(!path.contains(wrongBottomLeft, using: .winding))
    }

    // MARK: - Corner radius

    @Test func cornerRadiusKeepsThePathInsideTheBoundingBox() {
        let engine = makeLayoutEngine(screen: ScreenMetrics(width: 1920, height: 1080))
        let tile = engine.slots(count: 5, focus: 0).first { $0.offset == 1 }!
        #expect(tile.cornerRadius > 0)

        let path = CardPath.path(for: tile)
        let bounds = path.boundingBoxOfPath
        #expect(bounds.minX >= tile.rect.minX - 1e-6)
        #expect(bounds.minY >= tile.rect.minY - 1e-6)
        #expect(bounds.maxX <= tile.rect.maxX + 1e-6)
        #expect(bounds.maxY <= tile.rect.maxY + 1e-6)

        // The rounding cuts the sharp vertex off, so the vertex itself is outside.
        let sharpVertex = CGPoint(x: tile.rect.maxX, y: tile.rect.minY)
        #expect(!path.contains(sharpVertex, using: .winding))

        // Without rounding that same vertex is on the path.
        let sharp = CardPath.parallelogram(midWidth: tile.width, height: tile.height, skew: tile.skew,
                                           centerX: Double(tile.rect.midX), minY: Double(tile.rect.minY),
                                           cornerRadius: 0)
        #expect(sharp.contains(sharpVertex, using: .winding))
    }

    @Test func roundedPolygonNeedsAtLeastThreePoints() {
        let fewer: [[CGPoint]] = [
            [],
            [CGPoint(x: 0, y: 0)],
            [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)],
        ]
        for points in fewer {
            #expect(CardPath.roundedPolygon(points, radius: 4).isEmpty)
        }
    }
}

// MARK: - Helpers

private func approx(_ lhs: Double, _ rhs: Double, tolerance: Double = 1e-9) -> Bool {
    abs(lhs - rhs) <= tolerance
}

private func boundsEqual(_ lhs: CGRect, _ rhs: CGRect, tolerance: Double = 1e-6) -> Bool {
    abs(lhs.minX - rhs.minX) <= tolerance
        && abs(lhs.minY - rhs.minY) <= tolerance
        && abs(lhs.width - rhs.width) <= tolerance
        && abs(lhs.height - rhs.height) <= tolerance
}

private func parallelogramCorners(midWidth: Double, height: Double, skew: Double,
                                  centerX: Double, minY: Double) -> [CGPoint] {
    let half = midWidth / 2
    let shift = skew * height / 2
    return [
        CGPoint(x: centerX - shift - half, y: minY),
        CGPoint(x: centerX - shift + half, y: minY),
        CGPoint(x: centerX + shift + half, y: minY + height),
        CGPoint(x: centerX + shift - half, y: minY + height),
    ]
}

private func boundingBox(of points: [CGPoint]) -> CGRect {
    let xs = points.map { Double($0.x) }
    let ys = points.map { Double($0.y) }
    let minX = xs.min() ?? 0
    let maxX = xs.max() ?? 0
    let minY = ys.min() ?? 0
    let maxY = ys.max() ?? 0
    return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
}
