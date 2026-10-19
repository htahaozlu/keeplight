import AppKit
import DisplayCore
import Foundation
import Testing
@testable import KeeplightUI

private func isRevertFailed(_ phase: RingPhase) -> Bool {
    if case .revertFailed = phase { return true }
    return false
}

private func isReverted(_ phase: RingPhase) -> Bool {
    if case .reverted = phase { return true }
    return false
}

@MainActor
@Suite("Reverting a change")
struct RevertTests {
    @Test func failedRestoreIsNotReportedAsReverted() {
        let rig = Rig()
        let model = rig.model
        model.setMode(model.items[0], to: Rig.modes[1])
        #expect(model.pending != nil)
        rig.desk.failRestore = true
        model.revertPending(.user)
        #expect(model.pending == nil)
        #expect(isRevertFailed(model.ringPhase))
        #expect(model.receipt?.text.hasPrefix("Couldn't revert.") == true)
    }

    @Test func failedRestoreRunsRescueAndJournalsIt() {
        let rig = Rig()
        let model = rig.model
        model.setMode(model.items[0], to: Rig.modes[1])
        rig.desk.failRestore = true
        model.revertPending(.timeout)
        let rescued = rig.model.journal.entries().filter { $0.source == .rescue }
        #expect(!rescued.isEmpty)
        // Rescue put the display back on its default size.
        #expect(rig.desk.infos[0].currentMode?.modeNumber == 1)
        #expect(model.receipt?.text.contains("Rescue ran") == true)
    }

    @Test func revertOfAnAlreadyResolvedChangeClaimsNothing() throws {
        let rig = Rig()
        let model = rig.model
        model.setMode(model.items[0], to: Rig.modes[1])
        // Resolved elsewhere (CLI): the engine has nothing left to revert.
        _ = try model.engine.revert(reason: .user)
        model.revertPending(.user)
        #expect(model.pending == nil)
        #expect(!isReverted(model.ringPhase))
        #expect(model.receipt == nil)
        #expect(rig.model.journal.entries().allSatisfy { $0.source != .rescue })
    }

    @Test func cleanRestoreStaysReverted() {
        let rig = Rig()
        let model = rig.model
        model.setMode(model.items[0], to: Rig.modes[1])
        model.revertPending(.user)
        #expect(isReverted(model.ringPhase))
        #expect(model.receipt == nil)
        #expect(rig.model.journal.entries().allSatisfy { $0.source != .rescue })
    }
}

@MainActor
@Suite("Keep card copy")
struct KeepCopyTests {
    @Test func sameSizeNewRateNamesTheRate() {
        let rig = Rig()
        let model = rig.model
        model.setMode(model.items[0], to: Rig.modes[2])
        #expect(model.pending?.title == "Keep 2560 × 1440 · 120 Hz?")
    }

    @Test func newSizeStaysShort() {
        let rig = Rig()
        let model = rig.model
        model.setMode(model.items[0], to: Rig.modes[1])
        #expect(model.pending?.title == "Keep 3008 × 1692?")
    }

    @Test func titleParsing() {
        let same = OverlayCopy.modeSummary(name: "D", from: ("2560 × 1440", 60), to: ("2560 × 1440", 120))
        #expect(OverlayCopy.keepTitle(.mode, name: "D", summary: same) == "Keep 2560 × 1440 · 120 Hz?")
        let sameRate = OverlayCopy.modeSummary(name: "D", from: ("2560 × 1440", 60), to: ("2560 × 1440", 60))
        #expect(OverlayCopy.keepTitle(.mode, name: "D", summary: sameRate) == "Keep 2560 × 1440 · 60 Hz?")
        let bigger = OverlayCopy.modeSummary(name: "D", from: ("2560 × 1440", 60), to: ("3008 × 1692", 120))
        #expect(OverlayCopy.keepTitle(.mode, name: "D", summary: bigger) == "Keep 3008 × 1692?")
    }

    @Test func voiceOverStatesSecondsFromDotsAndDotDuration() {
        #expect(OverlayCopy.secondsLeft(lit: 15, secondsPerDot: 2) == 30)
        #expect(OverlayCopy.secondsLeft(lit: 7, secondsPerDot: 1) == 7)
        #expect(OverlayCopy.keepCardLabel(title: "Keep 3008 × 1692?", lit: 15, secondsPerDot: 2)
            == "Keep 3008 by 1692? 30 seconds until it goes back.")
        #expect(OverlayCopy.keepCardLabel(title: "Keep mirroring?", lit: 1, secondsPerDot: 1)
            == "Keep mirroring? 1 second until it goes back.")
    }

    @Test func cardLabelFollowsTheResolvedState() {
        let state = KeepCardState(title: "Keep mirroring?", phase: .live, lit: 3, secondsPerDot: 1)
        #expect(state.accessibilityText.hasPrefix("Keep mirroring?"))
        state.phase = .kept
        #expect(state.accessibilityText == "Kept")
        state.phase = .reverted
        #expect(state.accessibilityText == "Reverted")
        state.phase = .revertFailed
        #expect(state.accessibilityText == "Couldn't revert")
    }
}

@MainActor
@Suite("Brightness keys")
struct BrightnessKeysTests {
    private static let keyDown = CGEventMask(1) << CGEventMask(CGEventType.keyDown.rawValue)
    private static let keyUp = CGEventMask(1) << CGEventMask(CGEventType.keyUp.rawValue)
    private static let system = CGEventMask(1) << 14

    @Test func theTapHearsSystemDefinedAndKeyEvents() {
        // Two of the three forms of the sun keys are key codes, so key events are always tapped.
        let mask = BrightnessKeys.eventMask
        #expect(mask & Self.keyDown != 0 && mask & Self.keyUp != 0 && mask & Self.system != 0)
    }

    @Test func everyFormOfTheSunKeysIsRecognized() {
        // Apple keyboard without a dimmable screen (MacBook in clamshell): 144 up, 145 down.
        #expect(BrightnessKeyCode.direction(of: 144, functionKeys: false) == true)
        #expect(BrightnessKeyCode.direction(of: 145, functionKeys: false) == false)
        // Desktop Macs: F15 up, F14 down.
        #expect(BrightnessKeyCode.direction(of: 113, functionKeys: false) == true)
        #expect(BrightnessKeyCode.direction(of: 107, functionKeys: false) == false)
        // F1/F2 only when the user chose them.
        #expect(BrightnessKeyCode.direction(of: 120, functionKeys: false) == nil)
        #expect(BrightnessKeyCode.direction(of: 122, functionKeys: false) == nil)
        #expect(BrightnessKeyCode.direction(of: 120, functionKeys: true) == true)
        #expect(BrightnessKeyCode.direction(of: 122, functionKeys: true) == false)
        // Ordinary typing is never ours.
        for code: Int64 in [0, 1, 12, 36, 49, 53, 96, 97, 123, 126] {
            #expect(BrightnessKeyCode.direction(of: code, functionKeys: true) == nil)
        }
    }

    @Test func revokedAccessibilityDropsTheTapAndGrantStartsIt() {
        #expect(BrightnessKeys.trustAction(running: true, trusted: false) == .stop)
        #expect(BrightnessKeys.trustAction(running: false, trusted: true) == .start)
        #expect(BrightnessKeys.trustAction(running: true, trusted: true) == .none)
        #expect(BrightnessKeys.trustAction(running: false, trusted: false) == .none)
    }

    @Test func togglingFunctionKeysRebuildsTheTap() {
        let rig = Rig()
        #expect(rig.keys.functionKeyChanges == 0)
        let before = rig.model.prefs.functionKeysAsBrightness
        rig.model.prefs.functionKeysAsBrightness = before
        #expect(rig.keys.functionKeyChanges == 0)
        rig.model.prefs.functionKeysAsBrightness = !before
        #expect(rig.keys.functionKeyChanges == 1)
    }
}

@MainActor
@Suite("Errors in the panel")
struct ErrorRowTests {
    @Test func rawSystemTextNeverReachesTheRow() {
        let rig = Rig()
        rig.model.report(DisplayError.coreGraphics(.illegalArgument, "CGConfigureDisplayMode"))
        #expect(rig.model.errorMessage == PanelError.change)
        rig.model.report(DisplayError.ddc("reply checksum 0x6e"))
        #expect(rig.model.errorMessage == PanelError.change)
        rig.model.report(DisplayError.ioKit(-536870212, "IOAVServiceWriteI2C"))
        #expect(rig.model.errorMessage?.contains("IOReturn") == false)
        rig.model.report(DisplayError.refused("would disable the last active physical display"))
        #expect(rig.model.errorMessage == PanelError.lastDisplay)
    }

    @Test func sentencesAreShort() {
        let errors: [DisplayError] = [.displayNotFound("x"), .modeNotFound("x"), .coreGraphics(.failure, "op"),
                                      .ioKit(0, "op"), .unavailable("x"), .invalidArgument("x"), .refused("x"),
                                      .ddc("x"), .notImplemented("x")]
        for error in errors {
            let text = PanelError.sentence(for: error)
            #expect(text.count <= 40)
            #expect(text.hasSuffix(".") || text.hasSuffix("?"))
        }
    }

    @Test func limiterAllowsOneRowPerTenSeconds() {
        var limiter = ErrorRateLimiter()
        let t = Date(timeIntervalSince1970: 1_000)
        let first = limiter.allow(at: t)
        let early = limiter.allow(at: t.addingTimeInterval(9.9))
        let later = limiter.allow(at: t.addingTimeInterval(10))
        #expect(first)
        #expect(!early)
        #expect(later)
    }

    @Test func brightnessErrorsAreRateLimitedAndClearedByTheNextGoodWrite() {
        let rig = Rig()
        let model = rig.model
        let t = Date(timeIntervalSince1970: 5_000)
        model.brightnessWriteFailed(detail: "DDC 0x6e", at: t)
        #expect(model.errorMessage == PanelError.brightness)
        model.errorMessage = nil
        model.brightnessWriteFailed(detail: "DDC 0x6e", at: t.addingTimeInterval(5))
        #expect(model.errorMessage == nil)
        model.brightnessWriteFailed(detail: "DDC 0x6e", at: t.addingTimeInterval(11))
        #expect(model.errorMessage == PanelError.brightness)
        model.brightnessWriteSucceeded()
        #expect(model.errorMessage == nil)
    }

    @Test func aGoodWriteDoesNotClearAnUnrelatedError() {
        let rig = Rig()
        rig.model.report(DisplayError.refused("x"))
        rig.model.brightnessWriteSucceeded()
        #expect(rig.model.errorMessage == PanelError.change)
    }

    @Test func aFailingSliderShowsOneFixedSentenceThenRecovers() async {
        let rig = Rig(brightness: (.apple, 0.5))
        let model = rig.model
        #expect(await rig.eventually { rig.hasBrightness })
        guard let control = rig.control else { return }
        control.shouldFail = true
        model.setBrightness(7, to: 0.3)
        #expect(await rig.eventually { model.errorMessage != nil })
        #expect(model.errorMessage == PanelError.brightness)
        control.shouldFail = false
        model.setBrightness(7, to: 0.6)
        #expect(await rig.eventually { model.errorMessage == nil })
    }
}

@Suite("Rescue HUD lifecycle")
struct RescueHUDLifecycleTests {
    @Test func pressDuringThePreviousResultReplaysTheAppearance() {
        var hud = RescueHUDLifecycle()
        let first = hud.holding()
        let second = hud.holding()
        #expect(first)
        #expect(!second)
        let oldTicket = hud.showResult()
        #expect(hud.shouldClose(ticket: oldTicket))
        let replay = hud.holding()
        #expect(replay)
        #expect(!hud.shouldClose(ticket: oldTicket))
    }

    @Test func theNewResultClosesOnItsOwnTicketOnly() {
        var hud = RescueHUDLifecycle()
        let first = hud.showResult()
        _ = hud.holding()
        let second = hud.showResult()
        #expect(!hud.shouldClose(ticket: first))
        #expect(hud.shouldClose(ticket: second))
        hud.hide()
        #expect(!hud.shouldClose(ticket: second))
    }
}

@MainActor
@Suite("Erase all data")
struct EraseTests {
    @Test func preferencesStopWritingAfterErase() {
        let suite = "keeplight-tests-\(UUID().uuidString)"
        guard let store = UserDefaults(suiteName: suite) else { return }
        defer { store.removePersistentDomain(forName: suite) }
        let prefs = Preferences(store: store, domain: suite)
        prefs.knownDisplays = ["a": "A"]
        #expect(store.dictionary(forKey: "knownDisplays") != nil)
        prefs.eraseAll()
        prefs.knownDisplays = ["b": "B"]
        prefs.nicknames = ["b": "Bee"]
        prefs.lastWritten = ["b": LastWritten(value: 0.4, date: Date())]
        prefs.saveLastWritten()
        prefs.revertSeconds = 30
        #expect(store.dictionary(forKey: "knownDisplays") == nil)
        #expect(store.dictionary(forKey: "nicknames") == nil)
        #expect(store.data(forKey: "lastWritten") == nil)
        #expect(store.object(forKey: "revertSeconds") == nil)
    }

    @Test func nothingIsJournaledOrSavedAfterErase() async {
        let rig = Rig(brightness: (.apple, 0.5))
        let model = rig.model
        #expect(await rig.eventually { rig.hasBrightness })
        model.eraseAllData()
        #expect(model.erased)
        model.setBrightness(7, to: 0.3)
        model.finishGestures()
        model.record(JournalEntry(source: .panel, display: nil, kind: .brightness, result: .applied))
        model.acceptReconnectedByMacOS([])
        #expect(!FileManager.default.fileExists(atPath: rig.directory.path))
    }
}

@MainActor
@Suite("Brightness floor")
struct FloorTests {
    @Test func clampTargetOnlyRaises() {
        #expect(BrightnessFloor.clampTarget(value: 0, floor: 0.02) == 0.02)
        #expect(BrightnessFloor.clampTarget(value: 0.01, floor: 0.02) == 0.02)
        #expect(BrightnessFloor.clampTarget(value: 0.02, floor: 0.02) == nil)
        #expect(BrightnessFloor.clampTarget(value: 0.5, floor: 0.02) == nil)
        #expect(BrightnessFloor.clampTarget(value: nil, floor: 0.02) == nil)
        #expect(BrightnessFloor.clampTarget(value: 0, floor: 0) == nil)
    }

    @Test func soleApplePanelAtZeroIsRaisedOnceAndJournaled() async {
        let rig = Rig(builtin: true, brightness: (.apple, 0))
        let model = rig.model
        #expect(await rig.eventually { rig.control?.writes.last == 0.02 })
        let floorEntries = { model.journal.entries().filter { $0.kind == .brightness && $0.reason?.contains("floor") == true } }
        #expect(floorEntries().count == 1)
        #expect(floorEntries().first?.before == "0%" && floorEntries().first?.after == "2%")
        model.refresh()
        model.refresh()
        #expect(rig.control?.writes.count == 1)
        #expect(floorEntries().count == 1)
    }

    @Test func aPanelAboveTheFloorIsLeftAlone() async {
        let rig = Rig(builtin: true, brightness: (.apple, 0.5))
        #expect(await rig.eventually { rig.hasBrightness })
        rig.model.refresh()
        #expect(rig.control?.writes.isEmpty == true)
    }

    @Test func theSliderAndKeysMayGoToZeroOnTheOnlyScreen() async {
        // As in macOS: 0 is the backlight off, chosen on purpose.
        let rig = Rig(builtin: true, brightness: (.apple, 0.5))
        #expect(await rig.eventually { rig.hasBrightness })
        #expect(rig.model.brightnessFloor(for: 7) == 0)
        rig.model.setBrightness(7, to: 0)
        #expect(await rig.eventually { rig.control?.writes.last == 0 })
    }

    @Test func theKeysTakeOptionAloneAsFineSteps() {
        #expect(BrightnessKeys.isOurs([]))
        #expect(BrightnessKeys.isOurs(.maskAlternate) && BrightnessKeys.isFine(.maskAlternate))
        #expect(BrightnessKeys.isOurs([.maskAlternate, .maskShift]) && BrightnessKeys.isFine([.maskAlternate, .maskShift]))
        #expect(!BrightnessKeys.isOurs(.maskCommand) && !BrightnessKeys.isOurs(.maskControl) && !BrightnessKeys.isOurs(.maskShift))
        #expect(!BrightnessKeys.isFine([]))
        #expect(BrightnessPolicy.keyed(from: 0.5, up: false, fine: true) == 0.5 - 1.0 / 64)
    }

    @Test func aDDCMonitorMayStayAtZero() async {
        let rig = Rig(brightness: (.ddc, 0))
        #expect(await rig.eventually { rig.hasBrightness })
        rig.model.refresh()
        #expect(rig.control?.writes.isEmpty == true)
    }
}
