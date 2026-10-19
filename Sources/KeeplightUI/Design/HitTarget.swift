import SwiftUI

extension View {
    /// Marks an interactive control for the render tool's 24 × 24 audit. Nothing in release builds.
    @ViewBuilder
    func hitTarget(_ name: String) -> some View {
        #if DEBUG
        modifier(HitTargetReporter(name: name))
        #else
        self
        #endif
    }

    /// Dims static text with the controls around it while its section is disabled.
    func dimWhenDisabled() -> some View { modifier(DimWhenDisabled()) }
}

private struct DimWhenDisabled: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    func body(content: Content) -> some View { content.opacity(isEnabled ? 1 : 0.5) }
}

/// A `.bordered` button whose hit area is at least `Metrics.minTarget` tall: the label carries the
/// minimum height, so the bezel grows with it. `small` is the in-row size.
struct ActionButton: View {
    let title: String
    var small = false
    let action: () -> Void

    init(_ title: String, small: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.small = small
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).frame(minHeight: small ? Metrics.smallLabelHeight : Metrics.regularLabelHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.bordered)
        .controlSize(small ? .small : .regular)
        .hitTarget(title)
    }
}

#if DEBUG
/// Frames of the controls on one rendered surface, reported by `hitTarget`.
@MainActor
final class TargetSink {
    struct Target { let name: String; let frame: CGRect; let enabled: Bool }
    private(set) var targets: [UUID: Target] = [:]

    func record(_ id: UUID, name: String, frame: CGRect, enabled: Bool) {
        targets[id] = Target(name: name, frame: frame, enabled: enabled)
    }
    func remove(_ id: UUID) { targets[id] = nil }
}

private struct TargetSinkKey: EnvironmentKey {
    static let defaultValue: TargetSink? = nil
}

extension EnvironmentValues {
    var targetSink: TargetSink? {
        get { self[TargetSinkKey.self] }
        set { self[TargetSinkKey.self] = newValue }
    }
}

private struct HitTargetReporter: ViewModifier {
    let name: String
    @Environment(\.targetSink) private var sink
    @Environment(\.isEnabled) private var isEnabled
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { [id, name, isEnabled] frame in
                sink?.record(id, name: name, frame: frame, enabled: isEnabled)
            }
            .onChange(of: isEnabled) { _, enabled in
                if let frame = sink?.targets[id]?.frame { sink?.record(id, name: name, frame: frame, enabled: enabled) }
            }
            .onDisappear { [id] in sink?.remove(id) }
    }
}
#endif
