import AppKit
import DisplayCore

/// Settings › Displays: diagnosis (graded evidence) and the passport [O§6.5, O§7.4].
extension AppModel {
    /// The online display with this fingerprint.
    func onlineInfo(_ fingerprint: String) -> DisplayInfo? {
        items.first { $0.fingerprint == fingerprint }?.info
            ?? system.displays().first { $0.fingerprint == fingerprint }
    }

    /// Runs the six diagnostic steps off the main thread (DDC probing takes ~300 ms).
    func diagnose(_ fingerprint: String) {
        guard let info = onlineInfo(fingerprint) else { return }
        diagnoses[fingerprint] = DiagnosisState(report: diagnoses[fingerprint]?.report, running: true)
        let system = system
        Task { [weak self] in
            let started = ContinuousClock.now
            let report = await Task.detached(priority: .userInitiated) { system.diagnose(info) }.value
            // Hold "Checking…" briefly so the result doesn't flash by.
            let elapsed = ContinuousClock.now - started
            if elapsed < .milliseconds(800) { try? await Task.sleep(for: .milliseconds(800) - elapsed) }
            self?.diagnoses[fingerprint] = DiagnosisState(report: report, running: false)
        }
    }

    /// Check Again: re-diagnose and re-probe the brightness backend.
    func checkAgain(_ fingerprint: String) {
        guard let info = onlineInfo(fingerprint), !isSettling else { return }
        diagnose(fingerprint)
        probeBrightness([info])
    }

    func copyReport(_ fingerprint: String) {
        guard let report = diagnoses[fingerprint]?.report else { return }
        copy(report.markdownReport(), key: "report:\(fingerprint)")
    }

    // MARK: Passport

    func loadPassport(_ fingerprint: String) {
        guard let item = items.first(where: { $0.fingerprint == fingerprint }) else { return }
        let (info, native, modes, system) = (item.info, item.native, item.usableModes, system)
        Task { [weak self] in
            var passport = await Task.detached(priority: .utility) {
                Self.buildPassport(info: info, edid: system.edid(for: info), native: native, modes: modes)
            }.value
            passport.brightness = self?.brightnessSummary(for: item.id)
            self?.passports[fingerprint] = passport
        }
    }

    func brightnessSummary(for id: CGDirectDisplayID) -> String {
        switch brightness[id] {
        case .available(let control, _, _)?:
            switch control.backend {
            case .apple: return "Apple DisplayServices"
            case .ddc:
                let maximum = (control as? DDCBrightness).map { " · max \($0.maximum)" } ?? ""
                return "DDC/CI · VCP 0x10\(maximum)"
            }
        case .unavailable?: return "None"
        case .probing?, nil: return "Reading…"
        }
    }

    nonisolated static func buildPassport(info: DisplayInfo, edid: EDID?, native: PixelSize?,
                                          modes: [DisplayMode]) -> Passport {
        var passport = Passport()
        if let edid {
            passport.made = edid.manufactureWeek > 0
                ? "Week \(edid.manufactureWeek), \(edid.manufactureYear)" : "\(edid.manufactureYear)"
            if edid.widthCM > 0, edid.heightCM > 0 {
                let inches = Double(edid.widthCM) / 2.54
                let diagonal = (Double(edid.widthCM * edid.widthCM + edid.heightCM * edid.heightCM)).squareRoot() / 2.54
                var text = String(format: "≈%.1f″ · %d × %d cm", diagonal, edid.widthCM, edid.heightCM)
                if let native, inches > 0 { text += " · ≈\(Int((Double(native.width) / inches).rounded())) ppi" }
                passport.size = text
            }
            let serial = edid.serialString.flatMap { $0.isEmpty ? nil : Diagnostics.redact($0) }
            passport.identity = [edid.manufacturerID, String(format: "%04X", edid.productCode), serial,
                                 "EDID \(edid.version).\(edid.revision) \(edid.checksumValid ? "✓" : "✗")"]
                .compactMap { $0 }.joined(separator: " · ")
        } else {
            passport.identity = Diagnostics.redactFingerprint(info.fingerprint)
        }
        if let native {
            var text = "\(native.width) × \(native.height) pixels"
            if let hz = info.currentMode?.refreshRate, hz > 0 { text += " · \(Format.hz(hz)) Hz" }
            passport.panel = text
        }
        if let native {
            let soft = modes.filter { $0.sharpness(native: native.tuple) == .soft }.count
            let sizes = Set(modes.map { "\($0.width)x\($0.height)" }).count
            passport.modes = soft > 0 ? "\(sizes) sizes · \(soft) Soft" : "\(sizes) sizes"
        } else {
            passport.modes = "\(modes.count) usable"
        }
        return passport
    }
}
