import Foundation
import Testing
@testable import KeeplightUI

/// `Copy Command` puts a shell line on the clipboard with the display's name, which comes from the
/// monitor's EDID. Pasted into a terminal it must stay one inert word. Off the main actor: the
/// shell runs while the other suites keep the main thread.
@Suite("Copied command quoting")
struct ShellQuotingTests {
    @Test(arguments: ["DELL U2723QE", "a'b", "$(touch /tmp/keeplight-pwned)", "`id`", "x\"; rm -rf ~; \"", "'", "", "名前 ✓"])
    func aNameSurvivesTheShellUnchanged(_ name: String) throws {
        let quoted = AppModel.shellQuoted(name)
        // The shell prints the word back exactly; nothing inside it runs.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf %s \(quoted)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0)
        #expect(out == name)
        #expect(!FileManager.default.fileExists(atPath: "/tmp/keeplight-pwned"))
    }
}
