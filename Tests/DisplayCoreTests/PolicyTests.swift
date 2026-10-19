import CoreGraphics
import Foundation
import Testing
@testable import DisplayCore

@Test func dragIsRelativeSnapsToDetentsAndHonorsTheFloor() {
    // A press without movement changes nothing.
    #expect(BrightnessPolicy.dragged(from: 0.4, dx: 0, width: 200, floor: 0).value == 0.4)
    // Relative: half the track width is +50 %.
    #expect(abs(BrightnessPolicy.dragged(from: 0.2, dx: 60, width: 200, floor: 0).value - 0.5) < 1e-9)
    // Within ±1 % of 50 snaps, and reports the detent.
    let near = BrightnessPolicy.dragged(from: 0.4, dx: 19.2, width: 200, floor: 0)
    #expect(near.value == 0.5 && near.detent == 0.5)
    let off = BrightnessPolicy.dragged(from: 0.4, dx: 15, width: 200, floor: 0)
    #expect(off.detent == nil && abs(off.value - 0.475) < 1e-9)
    // Clamped to 0...1, and to the 2 % floor when it is the only screen (no detent at the floor).
    #expect(BrightnessPolicy.dragged(from: 0.9, dx: 500, width: 200, floor: 0).value == 1)
    let floored = BrightnessPolicy.dragged(from: 0.1, dx: -500, width: 200, floor: BrightnessPolicy.onlyScreenFloor)
    #expect(floored.value == 0.02 && floored.detent == nil)
}

@Test func scrollAndKeyStepsFollowTheSpec() {
    #expect(abs(BrightnessPolicy.scrollStep(3, precise: true, fine: false, coarse: false) - 0.01) < 1e-12)
    #expect(BrightnessPolicy.scrollStep(1, precise: false, fine: false, coarse: false) == 0.02)
    #expect(BrightnessPolicy.scrollStep(-4, precise: false, fine: false, coarse: false) == -0.02)
    #expect(BrightnessPolicy.scrollStep(1, precise: false, fine: true, coarse: false) == 0.005)
    #expect(abs(BrightnessPolicy.scrollStep(3, precise: true, fine: false, coarse: true) - 0.05) < 1e-12)
    #expect(BrightnessPolicy.keyStep(fine: false, coarse: false) == 0.01)
    #expect(BrightnessPolicy.keyStep(fine: false, coarse: true) == 0.10)
    #expect(BrightnessPolicy.keyStep(fine: true, coarse: false) == 0.0025)
    #expect(BrightnessPolicy.percent(0.404) == 40 && BrightnessPolicy.percent(1.2) == 100)
}

@Test func wakeRestoreOnlyWhenDriftedAndRecent() {
    let now = Date(timeIntervalSince1970: 1_000_000)
    let hourAgo = now.addingTimeInterval(-3600)
    #expect(WakeRestorePolicy.shouldRestore(read: 1.0, lastWritten: 0.4, writtenAt: hourAgo, now: now))
    // 2 % or less is left alone.
    #expect(!WakeRestorePolicy.shouldRestore(read: 0.42, lastWritten: 0.4, writtenAt: hourAgo, now: now))
    #expect(WakeRestorePolicy.shouldRestore(read: 0.43, lastWritten: 0.4, writtenAt: hourAgo, now: now))
    // A week-old value is stale.
    #expect(!WakeRestorePolicy.shouldRestore(read: 1.0, lastWritten: 0.4,
                                             writtenAt: now.addingTimeInterval(-7 * 86_400), now: now))
}

@Test func settleWaitsForQuietWithACap() {
    var window = SettleWindow(start: 100)
    #expect(window.deadline == 101.5)
    #expect(!window.isSettled(at: 101))
    window.note(101)           // a reconfiguration restarts the quiet period
    #expect(window.deadline == 102.5)
    window.note(107.5)         // keeps flapping: the 8 s cap wins
    #expect(window.deadline == 108)
    #expect(window.isSettled(at: 108))
    window.note(50)            // out-of-order times never move it back
    #expect(window.lastEvent == 107.5)
}

@Test func deskOrderIsLeftToRightThenTopToBottom() {
    let order = DeskLayout.order([
        (id: "right", bounds: CGRect(x: 1512, y: 0, width: 1920, height: 1080)),
        (id: "below", bounds: CGRect(x: 0, y: 1080, width: 1512, height: 982)),
        (id: "left", bounds: CGRect(x: 0, y: 0, width: 1512, height: 982)),
    ])
    #expect(order == ["left", "below", "right"])
}

@Test func deskMapKeepsTrueRelativeGeometry() {
    let rects = DeskLayout.fit([CGRect(x: 0, y: 222, width: 1512, height: 982),
                                CGRect(x: 1512, y: 0, width: 1920, height: 1080)],
                               in: CGSize(width: 288, height: 56), inset: 4)
    #expect(rects.count == 2)
    // Uniform scale: width/height ratios are preserved.
    #expect(abs(rects[0].width / rects[0].height - 1512.0 / 982) < 1e-9)
    #expect(abs(rects[1].width / rects[1].height - 1920.0 / 1080) < 1e-9)
    // Fits inside the inset box, centered, and the displays stay adjacent.
    let union = rects[0].union(rects[1])
    #expect(union.minY >= 4 - 1e-9 && union.maxY <= 52 + 1e-9)
    #expect(abs(union.midX - 144) < 1e-9 && abs(union.midY - 28) < 1e-9)
    #expect(abs(rects[0].maxX - rects[1].minX) < 1e-9)
}

@Test func brightnessKeysStepLikeMacOS() {
    #expect(BrightnessPolicy.keyed(from: 0.30, up: true, fine: false) == 0.375)
    #expect(BrightnessPolicy.keyed(from: 0.30, up: false, fine: false) == 0.25)
    #expect(BrightnessPolicy.keyed(from: 0.5, up: true, fine: true) == 0.515625)
    #expect(BrightnessPolicy.keyed(from: 1, up: true, fine: false) == 1)
    #expect(BrightnessPolicy.keyed(from: 0.05, up: false, fine: false, floor: 0.02) == 0.02)
    #expect(BrightnessPolicy.keyed(from: 0, up: false, fine: false) == 0)
}
