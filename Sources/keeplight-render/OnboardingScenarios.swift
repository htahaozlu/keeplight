#if DEBUG
import AppKit
import SwiftUI
@testable import KeeplightUI

/// The onboarding window's content (560 × 440) for every page and state, drawn as a still at each
/// scene's explainT pose. The view is the app's own `OnboardingView` on a debug model; its window
/// here is the renderer's offscreen one, so the motion gate stays shut and nothing animates.
extension Scenarios {
    static func onboarding() -> [Scenario] {
        [
            onboardingScenario("welcome-3", "Page 1 of 3: Welcome, three displays at their arrangement") { _ in },
            onboardingScenario("welcome-1", "Page 1 of 2: Welcome, one built-in display (no DDC, no keys page)", desk: .single) { _ in },
            onboardingScenario("keep", "Page 2 of 3: Changes wait for Keep (Fuse at 10 of 15)") { $0.step = .keep },
            onboardingScenario("keep-last", "Page 2 of 2 (no DDC display): Done and Open at login", desk: .single) {
                $0.step = .keep
            },
            onboardingScenario("keys-not-asked", "Page 3 of 3: brightness keys, not asked yet (Not Now · Allow…)") {
                $0.step = .keys
            },
            onboardingScenario("keys-waiting", "Page 3 of 3: Allow pressed, waiting for Accessibility") {
                $0.step = .keys
                $0.permission = .waiting
            },
            onboardingScenario("keys-granted", "Page 3 of 3: Accessibility granted, brightness keys on, Done") {
                $0.step = .keys
                $0.permission = .granted
            },
            onboardingScenario("keys-login-off", "Page 3 of 3: Open at login switched off", configure: {
                $0.step = .keys
                $0.openAtLogin = false
            }),
        ]
    }

    private static func onboardingScenario(_ name: String, _ state: String, desk: Desk.Kind = .three,
                                           configure: @escaping @MainActor (OnboardingFlow) -> Void) -> Scenario {
        Scenario(name: "onboarding-\(name)", surface: "Onboarding", state: state) { look in
            let model = Models.make(desk)
            model.showFirstRun = true
            let flow = OnboardingFlow(model: model)
            configure(flow)
            let view = OnboardingView(flow: flow)
            let capture = Renderer.render(OnboardingStill(view: view), look: look, frame: .window,
                                          width: OnboardingMetrics.size.width, height: OnboardingMetrics.size.height,
                                          settle: 0.6)
            OnboardingStill.recordTargets(of: view, into: capture.sink)
            return capture
        }
    }
}

/// Hosts the AppKit onboarding content for the SwiftUI renderer and poses it at explainT.
struct OnboardingStill: NSViewRepresentable {
    let view: OnboardingView

    func makeNSView(context: Context) -> OnboardingView { view }

    func updateNSView(_ view: OnboardingView, context: Context) {
        view.applyPalette()
        view.showStill()
    }

    /// The window's controls as render targets (the AppKit equivalent of `hitTarget`).
    @MainActor
    static func recordTargets(of view: OnboardingView, into sink: TargetSink) {
        view.layoutSubtreeIfNeeded()
        let height = view.window?.contentView?.bounds.height ?? view.bounds.height
        func walk(_ v: NSView) {
            guard !v.isHidden else { return }
            let name: String? = switch v {
            case let b as NSButton: b.title.isEmpty ? "button" : b.title
            case is LoginRow: OnboardingCopy.openAtLogin
            default: nil
            }
            if let name {
                let r = v.convert(v.bounds, to: nil)
                sink.record(UUID(), name: name, frame: CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height),
                            enabled: (v as? NSControl)?.isEnabled ?? true)
                if v is LoginRow { return } // its switch is part of the row's target
            }
            v.subviews.forEach(walk)
        }
        walk(view)
    }
}
#endif
