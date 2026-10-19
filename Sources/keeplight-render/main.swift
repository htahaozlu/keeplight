#if DEBUG
import AppKit
@testable import KeeplightUI

MainActor.assumeIsolated {
    exit(RenderTool.run(arguments: Array(CommandLine.arguments.dropFirst())))
}
#else
import Foundation

// `@testable import` needs a debug build; release builds get this stub so `swift build -c release`
// still succeeds. The stub is never bundled (scripts/check-bundle.sh).
FileHandle.standardError.write(Data("keeplight-render is a debug-only tool: swift run keeplight-render\n".utf8))
exit(2)
#endif
