import Testing
@testable import DisplayCore

@Test func backendWriteIntervals() {
    #expect(BrightnessBackend.apple.minimumWriteInterval == 0.016)
    #expect(BrightnessBackend.ddc.minimumWriteInterval == 0.1)
    #expect(WriteThrottle(backend: .ddc).interval == 0.1)
}

@Test func throttleLeadingCoalescedTrailing() {
    var t = WriteThrottle(interval: 0.1)
    #expect(t.submit(0.10, at: 0.000) == .write(0.10))           // leading write
    #expect(t.submit(0.20, at: 0.020) == .schedule(at: 0.100))   // trailing scheduled
    #expect(t.submit(0.30, at: 0.050) == .coalesced)             // latest wins
    #expect(t.fire(at: 0.060) == .schedule(at: 0.100))           // early timer: reschedule
    #expect(t.fire(at: 0.100) == .write(0.30))                   // trailing write of the final value
    #expect(t.fire(at: 0.150) == .idle)
    #expect(t.submit(0.40, at: 0.150) == .schedule(at: 0.200))   // within 100 ms of the trailing write
    #expect(t.submit(0.50, at: 0.320) == .write(0.50))           // a late timer is overtaken by a fresh leading write
    #expect(t.fire(at: 0.330) == .idle)
}

@Test func throttleRateNeverExceedsInterval() {
    // A 60 Hz drag for one second on DDC: at most 1 write / 100 ms, last value always written.
    var t = WriteThrottle(backend: .ddc)
    var writes: [(at: Double, value: Double)] = []
    var timer: Double?
    var now = 0.0
    var lastSubmitted = 0.0
    while now <= 1.0 + 1e-9 {
        if let due = timer, due <= now {
            timer = nil
            switch t.fire(at: now) {
            case .write(let v): writes.append((now, v))
            case .schedule(let at): timer = at
            default: break
            }
        }
        lastSubmitted = now
        switch t.submit(now, at: now) {
        case .write(let v): writes.append((now, v))
        case .schedule(let at): timer = at
        default: break
        }
        now += 1.0 / 60
    }
    while let due = timer {
        timer = nil
        if case .write(let v) = t.fire(at: due) { writes.append((due, v)) }
    }
    for (a, b) in zip(writes, writes.dropFirst()) { #expect(b.at - a.at >= 0.1 - 1e-6) }
    #expect(writes.count >= 9 && writes.count <= 12)
    #expect(writes.last?.value == lastSubmitted)
}

@Test func privateInterfaceTable() {
    let all = PrivateInterfaces.all
    #expect(all.count == 13)
    #expect(Set(all.map(\.symbol)).count == 13)
    #expect(Set(all.map(\.framework)) == ["CoreGraphics", "DisplayServices", "CoreDisplay", "IOKit"])
    #expect(all.filter { $0.framework == "IOKit" }.map(\.symbol)
            == ["IOAVServiceCreateWithService", "IOAVServiceReadI2C", "IOAVServiceWriteI2C", "IOAVServiceCopyEDID"])
    #expect(PrivateInterfaces.resolvedCount == all.filter(\.isResolved).count)
}
