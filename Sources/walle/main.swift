import Foundation
import WalleCore

// walle is a command line tool. It deliberately does not link AppKit: only
// walle-picker does, which is what keeps this binary small and instant.
let environment = CLIEnvironment(
    paths: WallePaths.resolve(),
    output: .standard)

exit(CLI.run(Array(CommandLine.arguments.dropFirst()), environment: environment))
