import CoreGraphics
import Foundation
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
