import AppKit
import DisplayCore
import SwiftUI

/// The panel (docs/design/v5-panel.md): every display is a module tile with a capsule slider, the
/// tiles 6 from the panel edge and 6 apart; a notice tile above them, the `Waking…` line and the
/// footer below, on the material. A pending change is answered on the Keep card, so the modules
/// are simply locked meanwhile.
struct PanelRoot: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        PanelStack()
            .frame(width: Metrics.panelWidth)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { model.panelContentHeight = $0 }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .font(.system(size: 13))
            .foregroundStyle(Color.inkPrimary)
            .tint(Color.inkPrimary)
    }
}

private struct PanelStack: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The modules' natural height, the height the scroll view shows, and the whole stack's.
    @State private var modulesHeight = Metrics.moduleHeight
    @State private var scrollHeight = Metrics.moduleHeight
    @State private var stackHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: 0) {
            notice
            modules
            Color.clear.frame(height: Metrics.inset)
            if let line { PanelLine(text: line, waiting: model.isSettling) }
            PanelFooter()
        }
        .padding(.vertical, Metrics.inset)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { stackHeight = $0 }
    }

    // MARK: Notice

    private var notice: some View {
        let current = PanelNotice.current(safeStart: model.showSafeStart, error: model.errorMessage,
                                          receipt: model.receipt)
        let visible = model.isPanelOpen
        let transition: AnyTransition = reduceMotion
            ? .opacity.animation(Tween.noticeIn.animation(reduceMotion: true, visible: visible))
            : .asymmetric(insertion: AnyTransition(RevealTransition())
                              .animation(Tween.noticeIn.animation(reduceMotion: false, visible: visible)),
                          removal: AnyTransition(RevealTransition())
                              .animation(Tween.noticeOut.animation(reduceMotion: false, visible: visible)))
        return VStack(spacing: 0) {
            if let current {
                NoticeTile(notice: current)
                    .padding(.bottom, Metrics.inset)
                    .id(current.kind)
                    .transition(transition)
            }
        }
    }

    // MARK: Modules

    private var modules: some View {
        // What is left of the panel's maximum height after everything around the modules; the
        // modules scroll inside it.
        let limit = max(Metrics.moduleHeight, model.panelMaxHeight - (stackHeight - scrollHeight))
        let multiple = model.items.filter { !$0.info.isMirrorTarget }.count > 1
        return ScrollView {
            VStack(spacing: Metrics.inset) {
                if model.items.isEmpty, model.disconnected.isEmpty {
                    ModuleTile {
                        Text("No active displays.").foregroundStyle(Color.inkSecondary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    }
                }
                ForEach(model.items) { item in
                    DisplayModule(item: item, showsMain: multiple)
                }
                ForEach(model.disconnected) { display in
                    DisconnectedModule(display: display)
                }
            }
            .frame(maxWidth: .infinity)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { modulesHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(modulesHeight, limit))
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { scrollHeight = $0 }
    }

    /// `Waking…` while the displays settle; otherwise a short-lived notice.
    private var line: String? {
        if model.isSettling { return "Waking…" }
        return model.notice
    }
}

// MARK: - Notice transition

/// The notice tile opens its height from 0 while it fades in, so the modules below move with it
/// instead of jumping (v5 §6 `noticeIn` / `noticeOut`).
private struct RevealTransition: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        RevealLayout(fraction: phase.isIdentity ? 1 : 0) { content }
            .clipped()
            .opacity(phase.isIdentity ? 1 : 0)
    }
}

/// Reports `fraction` of its one subview's height; the subview keeps its own size, top-aligned.
private struct RevealLayout: Layout {
    var fraction: CGFloat

    var animatableData: CGFloat {
        get { fraction }
        set { fraction = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let first = subviews.first else { return .zero }
        let size = first.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: size.height * max(0, min(1, fraction)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}

// MARK: - Line and footer

/// One 24-tall line on the material, at the modules' content edge: `Waking…` with the static ink
/// ring (the waiting form of v4 §1, never animated), or a caption without it.
private struct PanelLine: View {
    let text: String
    let waiting: Bool

    var body: some View {
        HStack(spacing: 6) {
            if waiting {
                Circle().strokeBorder(Color.inkSecondary, lineWidth: 1.5)
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
            }
            Text(text).font(.callout12).foregroundStyle(Color.inkSecondary)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: Metrics.lineHeight, alignment: .leading)
        .padding(.horizontal, Metrics.inset + Metrics.moduleHPadding)
    }
}

/// `Settings…` left, `Quit` right, on the material at the modules' content edge; each hit area at
/// least 44 × 28. ⌘, and ⌘Q work but are not printed.
private struct PanelFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            Button { model.openSettings() } label: {
                Text("Settings…").frame(minWidth: 44, minHeight: 28, alignment: .leading).contentShape(Rectangle())
            }
            .keyboardShortcut(",", modifiers: .command)
            .hitTarget("Settings")
            .accessibilityLabel("Settings")
            Spacer(minLength: 0)
            Button { NSApp.terminate(nil) } label: {
                Text("Quit").frame(minWidth: 44, minHeight: 28, alignment: .trailing).contentShape(Rectangle())
            }
            .keyboardShortcut("q", modifiers: .command)
            .hitTarget("Quit")
            .accessibilityLabel("Quit Keeplight")
        }
        .buttonStyle(InkButtonStyle())
        .padding(.horizontal, Metrics.inset + Metrics.moduleHPadding)
        .frame(height: Metrics.footerHeight)
    }
}
