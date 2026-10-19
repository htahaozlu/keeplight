import Foundation
import Testing
@testable import DisplayCore

@Test func snapshotCodableRoundTrip() throws {
    let snapshot = DisplaySnapshot(displays: [
        entry("APP:A059:1", id: 1, name: "Built-in", mode: 54, label: "1512x982@120 hidpi", main: true, builtin: true),
        entry("DEL:A0F3:SN", id: 3, name: "Desk right", mode: 90, x: 1512, y: -200),
        entry("DEL:A0F3:SN2", id: 4, name: "Mirror", mode: nil, mirrorOf: "DEL:A0F3:SN"),
        entry("BNQ:7950:X", id: 5, name: "Off", mode: nil, enabled: false),
    ], takenAt: Date(timeIntervalSince1970: 1_800_000_000))
    let data = try FileStore.encoder.encode(snapshot)
    let decoded = try FileStore.decoder.decode(DisplaySnapshot.self, from: data)
    #expect(decoded == snapshot)
    #expect(decoded.signature == "APP:A059:1|BNQ:7950:X|DEL:A0F3:SN|DEL:A0F3:SN2")
    #expect(decoded.main?.fingerprint == "APP:A059:1")
}

@Test func restorePlanOrdersActions() {
    let target = DisplaySnapshot(displays: [
        entry("A", id: 1, mode: 10, main: true),
        entry("B", id: 2, mode: 20, x: 1000),
        entry("C", id: 3, mode: 30, mirrorOf: "A"),
        entry("D", id: 4, mode: 40, enabled: false),
    ])
    let current = DisplaySnapshot(displays: [
        entry("A", id: 1, mode: 11, x: -1000, main: false),
        entry("B", id: 2, mode: 20, x: 0, main: true),
        entry("C", id: 3, mode: 30, x: 2000),
        entry("D", id: 4, mode: 40, x: 3000),
        entry("E", id: 5, mode: 50, x: 4000),  // not in target: left alone
    ])
    let plan = DisplaySnapshot.restorePlan(from: current, to: target)
    let ref = { (fp: String) in DisplayRef(name: fp, fp: fp) }
    #expect(plan == [
        .disable(ref("D"), displayID: 4),
        .mirror(ref("C"), sourceFingerprint: "A"),
        .setMode(ref("A"), modeNumber: 10, label: nil),
        .arrange(["A": DisplayOrigin(x: 0, y: 0), "B": DisplayOrigin(x: 1000, y: 0)]),
    ])
}

@Test func restorePlanReconnectsAndIsEmptyWhenEqual() {
    let before = DisplaySnapshot(displays: [entry("A", id: 1, main: true), entry("B", id: 2, x: 100)])
    var after = before
    after.set("B") { $0.isEnabled = false }
    let plan = DisplaySnapshot.restorePlan(from: after, to: before)
    #expect(plan.first == .enable(DisplayRef(name: "B", fp: "B"), displayID: 2))
    #expect(plan.contains { if case .arrange = $0 { true } else { false } })
    #expect(DisplaySnapshot.restorePlan(from: before, to: before).isEmpty)
    // Stop mirroring when the target is separate.
    var mirrored = before
    mirrored.set("B") { $0.mirrorSourceFingerprint = "A" }
    #expect(DisplaySnapshot.restorePlan(from: mirrored, to: before).first == .unmirror(DisplayRef(name: "B", fp: "B")))
}

@Test func knownGoodKeepsNewestPerSignature() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let store = KnownGoodStore(directory: dir.url, limit: 2)
    let ab = DisplaySnapshot(displays: [entry("A", id: 1), entry("B", id: 2)], takenAt: Date(timeIntervalSince1970: 1))
    var ab2 = ab
    ab2.takenAt = Date(timeIntervalSince1970: 2)
    let a = DisplaySnapshot(displays: [entry("A", id: 1)], takenAt: Date(timeIntervalSince1970: 3))
    let c = DisplaySnapshot(displays: [entry("C", id: 3)], takenAt: Date(timeIntervalSince1970: 4))
    try store.save(ab)
    try store.save(ab2)
    #expect(store.all().count == 1)
    #expect(store.snapshot(forSignature: "A|B")?.takenAt == ab2.takenAt)
    try store.save(a)
    try store.save(c)
    #expect(store.all().map(\.signature) == ["C", "A"])  // newest first, capped at the limit
    #expect(store.snapshot(forSignature: "A|B") == nil)
}

@Test func registriesRoundTrip() throws {
    let dir = TempDir()
    defer { dir.cleanup() }
    let registry = DisconnectedRegistry(directory: dir.url)
    try registry.add(DisconnectedDisplay(fingerprint: "A", displayID: 1, name: "One"))
    try registry.add(DisconnectedDisplay(fingerprint: "B", displayID: 2, name: "Two"))
    try registry.add(DisconnectedDisplay(fingerprint: "A", displayID: 9, name: "One again"))
    #expect(registry.load().map(\.displayID) == [2, 9])
    var enabled: [UInt32] = []
    let remaining = registry.reconnectAll { id in
        enabled.append(id)
        if id == 2 { throw DisplayError.refused("still off") }
    }
    #expect(enabled == [2, 9])
    #expect(remaining.map(\.fingerprint) == ["B"])
    #expect(registry.load().map(\.fingerprint) == ["B"])

    let mirrors = MirrorRegistry(directory: dir.url)
    try mirrors.add(CreatedMirror(target: DisplayRef(name: "T", fp: "T"), sourceFingerprint: "S"))
    #expect(mirrors.load().first?.sourceFingerprint == "S")
    try mirrors.remove(targetFingerprint: "T")
    #expect(mirrors.load().isEmpty)
}
