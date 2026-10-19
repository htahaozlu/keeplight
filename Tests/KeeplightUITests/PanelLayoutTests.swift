import AppKit
import DisplayCore
import SwiftUI
import Testing
@testable import KeeplightUI

/// The v5 panel (docs/design/v5-panel.md): capsule slider mapping and keys, the geometry tokens,
/// the panel's height per state, and the panel tweens.
@Suite("Capsule slider")
struct CapsuleSliderTests {
    let geometry = CapsuleSliderGeometry()

    @Test func theTrackFillsTheContentNextToThePercent() {
        #expect(Metrics.moduleContentWidth == 284)
        #expect(geometry.width == 246 && geometry.height == 24)
        #expect(geometry.span == 222)
    }

    @Test func theFillNeverShrinksBelowTheGlyph() {
        #expect(geometry.fillWidth(0) == 24)
        #expect(geometry.fillWidth(1) == 246)
        #expect(geometry.fillWidth(0.5) == 135)
        #expect(geometry.fillWidth(-0.3) == 24)
        #expect(geometry.fillWidth(1.7) == 246)
    }

    @Test func aPressJumpsToTheLevelUnderThePointer() {
        #expect(geometry.level(atX: 12) == 0)
        #expect(geometry.level(atX: 234) == 1)
        #expect(geometry.level(atX: 123) == 0.5)
        // Clamped: on the glyph and past the end.
        #expect(geometry.level(atX: 0) == 0)
        #expect(geometry.level(atX: -40) == 0)
        #expect(geometry.level(atX: 246) == 1)
        #expect(geometry.level(atX: 400) == 1)
    }

    @Test func thePointerSitsOnTheCentreOfTheFillsEnd() {
        for level in stride(from: 0.0, through: 1.0, by: 1.0 / 16) {
            let end = geometry.fillWidth(level)
            #expect(abs(geometry.level(atX: end - geometry.height / 2) - level) < 1e-9)
        }
    }

    @Test func arrowsStepOnTheBrightnessKeyGrid() {
        #expect(CapsuleSliderKey.increment.level(from: 0.5, fine: false, floor: 0) == 9.0 / 16)
        #expect(CapsuleSliderKey.decrement.level(from: 0.5, fine: false, floor: 0) == 7.0 / 16)
        // Off the grid: snap first, then one step (like the brightness keys).
        #expect(CapsuleSliderKey.increment.level(from: 0.52, fine: false, floor: 0) == 9.0 / 16)
        #expect(CapsuleSliderKey.decrement.level(from: 0.52, fine: false, floor: 0) == 7.0 / 16)
        // The bottom 3 / 16 is the dimmed range of a DDC monitor: still the same grid.
        #expect(CapsuleSliderKey.decrement.level(from: DimmingCurve.handover, fine: false, floor: 0) == 2.0 / 16)
    }

    @Test func optionShiftStepsInQuarters() {
        #expect(CapsuleSliderKey.increment.level(from: 0.5, fine: true, floor: 0) == 33.0 / 64)
        #expect(CapsuleSliderKey.decrement.level(from: 0.5, fine: true, floor: 0) == 31.0 / 64)
        #expect(CapsuleSliderKey.isFine([.option, .shift]))
        #expect(CapsuleSliderKey.isFine(.option))
        #expect(!CapsuleSliderKey.isFine(.shift))
        #expect(!CapsuleSliderKey.isFine([]))
    }

    @Test func homeAndEndGoToTheEndsAndTheFloorHolds() {
        #expect(CapsuleSliderKey.home.level(from: 0.7, fine: false, floor: 0) == 0)
        #expect(CapsuleSliderKey.end.level(from: 0.2, fine: false, floor: 0) == 1)
        #expect(CapsuleSliderKey.home.level(from: 0.7, fine: false, floor: 0.02) == 0.02)
        #expect(CapsuleSliderKey.decrement.level(from: 1.0 / 16, fine: false, floor: 0.02) == 0.02)
        #expect(CapsuleSliderKey.increment.level(from: 1, fine: false, floor: 0) == 1)
        #expect(CapsuleSliderKey.decrement.level(from: 0, fine: false, floor: 0) == 0)
    }

    @Test func keysMapToSteps() {
        #expect(CapsuleSliderKey(.leftArrow) == .decrement)
        #expect(CapsuleSliderKey(.downArrow) == .decrement)
        #expect(CapsuleSliderKey(.rightArrow) == .increment)
        #expect(CapsuleSliderKey(.upArrow) == .increment)
        #expect(CapsuleSliderKey(.home) == .home)
        #expect(CapsuleSliderKey(.end) == .end)
        #expect(CapsuleSliderKey(.space) == nil)
        #expect(CapsuleSliderKey(.return) == nil)
    }
}

@Suite("Panel layout")
struct PanelLayoutTests {
    @Test func geometryTokens() {
        #expect(Metrics.panelWidth == 320)
        #expect(Metrics.inset == 6)
        #expect(Metrics.moduleWidth == 308)
        #expect(Metrics.moduleHeight == 108)
        #expect(Metrics.footerHeight == 32)
        #expect(Metrics.noticeMinHeight == 36)
    }

    @Test func radiiAreConcentric() {
        #expect(Metrics.moduleRadius == Metrics.panelRadius - Metrics.inset)
        #expect(Metrics.panelRadius == (Metrics.isMacOS26 ? 18 : 16))
        #expect(Metrics.moduleRadius == (Metrics.isMacOS26 ? 12 : 10))
    }

    @Test func heightPerState() {
        // 6 + 108 + 6 + 32 + 6.
        #expect(PanelLayout.height(modules: 1) == 158)
        // Three modules, 6 apart.
        #expect(PanelLayout.height(modules: 3) == 386)
        // An empty desk keeps one tile.
        #expect(PanelLayout.height(modules: 0) == 158)
        // A notice tile and its gap above the modules; never under 36.
        let withChip: CGFloat = 158 + 40 + 6, withText: CGFloat = 158 + 36 + 6
        #expect(PanelLayout.noticeWithChip == 40)
        #expect(PanelLayout.height(modules: 1, notice: PanelLayout.noticeWithChip) == withChip)
        #expect(PanelLayout.height(modules: 1, notice: 20) == withText)
        // `Waking…` adds its 24-tall line.
        let waking: CGFloat = 272 + 24, everything: CGFloat = 386 + 46 + 24
        #expect(PanelLayout.height(modules: 2, line: true) == waking)
        #expect(PanelLayout.height(modules: 3, notice: 40, line: true) == everything)
    }

    @Test func noticePrecedence() {
        let receipt = Receipt(text: "Set Test Display back to 40", undo: nil, expires: .distantFuture)
        #expect(PanelNotice.current(safeStart: true, error: "x", receipt: receipt) == .safeStart)
        #expect(PanelNotice.current(safeStart: false, error: "x", receipt: receipt) == .error("x"))
        #expect(PanelNotice.current(safeStart: false, error: nil, receipt: receipt) == .receipt(receipt))
        #expect(PanelNotice.current(safeStart: false, error: nil, receipt: nil) == nil)
    }
}

/// The real views, laid out offscreen, against `PanelLayout`.
@MainActor
@Suite("Panel views")
struct PanelViewHeightTests {
    /// The height the panel reports to the shell (`panelContentHeight`) once laid out.
    private func measuredHeight(_ rig: Rig) -> CGFloat {
        let host = NSHostingView(rootView: PanelRoot().environment(rig.model))
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -40_000, y: -40_000, width: Metrics.panelWidth, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        rig.model.panelContentHeight = 0
        let end = Date().addingTimeInterval(2)
        repeat {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        } while Date() < end && rig.model.panelContentHeight == 0
        // A few more turns so a second pass (scroll height, notices) settles.
        for _ in 0..<10 {
            host.layoutSubtreeIfNeeded()
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return rig.model.panelContentHeight
    }

    @Test func oneDisplayIs158() async {
        let rig = Rig(brightness: (.ddc, 0.4))
        _ = await rig.eventually { rig.hasBrightness }
        #expect(measuredHeight(rig) == PanelLayout.height(modules: 1))
    }

    @Test func everyStateOfTheSliderSlotKeepsTheModuleAt108() async {
        // No control (no backend): the empty rail keeps the slot.
        let rig = Rig()
        _ = await rig.eventually { if case .unavailable? = rig.model.brightness[7] { true } else { false } }
        #expect(measuredHeight(rig) == PanelLayout.height(modules: 1))
        // Reading.
        rig.model.brightness[7] = .probing
        #expect(measuredHeight(rig) == PanelLayout.height(modules: 1))
    }

    @Test func aDisconnectedDisplayIsACompactModule() {
        let rig = Rig()
        rig.model.disconnected = [DisconnectedDisplay(fingerprint: "TEST:2", displayID: 8, name: "Other",
                                                      disconnectedAt: Date(timeIntervalSince1970: 0))]
        #expect(Metrics.compactModuleHeight == 78)
        #expect(measuredHeight(rig) == PanelLayout.height(modules: 2, compact: 1))
    }

    @Test func wakingAddsItsLine() {
        let rig = Rig()
        rig.model.isSettling = true
        #expect(measuredHeight(rig) == PanelLayout.height(modules: 1, line: true))
    }

    @Test func aReceiptWithUndoIsANoticeTileAboveTheModules() {
        let rig = Rig()
        rig.model.receipt = Receipt(text: "Set Test Display back to 40", undo: .entry("x"), expires: .distantFuture)
        #expect(measuredHeight(rig) == PanelLayout.height(modules: 1, notice: PanelLayout.noticeWithChip))
        rig.model.receipt = Receipt(text: "Set Test Display back to 40", undo: nil, expires: .distantFuture)
        #expect(measuredHeight(rig) == PanelLayout.height(modules: 1, notice: Metrics.noticeMinHeight))
    }
}

@Suite("Panel motion")
struct PanelMotionTests {
    @Test func durationsAndCurvesFollowTheSpec() {
        #expect(Tween.sliderFill.duration == 0.16 && Tween.sliderFill.easing == .decelerate)
        #expect(Tween.hover.duration == 0.12 && Tween.hover.easing == .decelerate)
        #expect(Tween.noticeIn.duration == 0.18 && Tween.noticeIn.easing == .decelerate)
        #expect(Tween.noticeOut.duration == 0.16 && Tween.noticeOut.easing == .in)
        #expect(Tween.lock.duration == 0.16)
        #expect(Easing.decelerate == Easing(c1x: 0, c1y: 0, c2x: 0.2, c2y: 1))
    }

    @Test func tweensAreOneShotPureCurvesEndingAtRest() {
        for tween in Tween.all {
            #expect(tween.progress(at: -1) == 0)
            #expect(tween.progress(at: 0) == 0)
            #expect(tween.progress(at: tween.duration) == 1)
            #expect(tween.progress(at: tween.duration * 10) == 1)
            #expect(tween.explanationProgress == 1)
            var last = 0.0
            for step in 1...20 {
                let p = tween.progress(at: tween.duration * Double(step) / 20)
                #expect(p >= last - 1e-9)
                last = p
            }
            #expect(tween.value(from: 24, to: 246, at: tween.duration) == 246)
        }
    }

    @Test func reduceMotionSnapsOrFadesAndNothingPlaysHidden() {
        #expect(Tween.sliderFill.animation(reduceMotion: true) == nil)
        #expect(Tween.hover.animation(reduceMotion: true) == nil)
        #expect(Tween.lock.animation(reduceMotion: true) == nil)
        #expect(Tween.noticeIn.animation(reduceMotion: true) == Animation.linear(duration: 0.15))
        #expect(Tween.noticeOut.animation(reduceMotion: true) == Animation.linear(duration: 0.15))
        for tween in Tween.all {
            #expect(tween.animation(reduceMotion: false) != nil)
            #expect(tween.animation(reduceMotion: false, visible: false) == nil)
            #expect(tween.animation(reduceMotion: true, visible: false) == nil)
        }
    }

    @Test func thePanelStillFadesInUnderReduceMotion() {
        let reduced = Timeline.panelOpenReduced
        #expect(reduced.duration == 0.15)
        #expect(reduced.easing == .linear)
        #expect(reduced.loops == 1)
        #expect(reduced.animatedProperties == [.opacity])
        #expect(reduced.resting == Pose(opacity: 1))
    }
}
