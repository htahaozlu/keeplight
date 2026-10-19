import DisplayCore
import Testing
@testable import KeeplightUI

@Suite("Overlay copy")
struct OverlayCopyTests {
    @Test func keepTitles() {
        let mode = "DELL U2723QE · 2560 × 1440 → 3008 × 1692"
        #expect(OverlayCopy.keepTitle(.mode, name: "DELL U2723QE", summary: mode) == "Keep 3008 × 1692?")
        #expect(OverlayCopy.keepTitle(.mode, name: "DELL", summary: mode + " · 120 Hz") == "Keep 3008 × 1692?")
        #expect(OverlayCopy.keepTitle(.main, name: "DELL U2723QE", summary: "") == "Keep DELL U2723QE as main?")
        #expect(OverlayCopy.keepTitle(.mirror, name: "x", summary: "") == "Keep mirroring?")
        #expect(OverlayCopy.keepTitle(.unmirror, name: "x", summary: "") == "Keep displays separate?")
        #expect(OverlayCopy.keepTitle(.disconnect, name: "LG HDR 4K", summary: "") == "Keep LG HDR 4K disconnected?")
        #expect(OverlayCopy.keepTitle(.restore, name: "x", summary: "") == "Keep this setup?")
    }

    @Test func spokenTitleSaysBy() {
        #expect(OverlayCopy.keepAnnouncement("Keep 3008 × 1692?", seconds: 15)
            == "Keep 3008 by 1692? Goes back in 15 seconds.")
    }

    @Test func resolvedTimelineHoldsThenFades() {
        let t = Timeline.cardResolved
        #expect(t.pose(at: 0.5).opacity == 1)
        #expect(t.pose(at: 0.86).opacity == 0)
        #expect(t.explanationPose.opacity == 1)
    }
}
