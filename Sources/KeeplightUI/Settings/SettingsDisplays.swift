import AppKit
import DisplayCore
import SwiftUI

/// Settings › Displays [v4 §5]: names on the left, one display on the right. The diagnosis lives
/// only in Copy Report.
struct DisplaysTab: View {
    @Environment(AppModel.self) private var model
    /// The Details disclosure starts open (render tool only).
    var detailsOpen = false

    struct Entry: Identifiable, Hashable {
        let fingerprint: String
        let name: String
        /// The EDID name (the Name field's placeholder).
        let edidName: String
        let online: Bool
        var id: String { fingerprint }
    }

    /// Lowest height of the tab, so a short list still reads as a list.
    static let minHeight: CGFloat = 300

    private var entries: [Entry] {
        var result = model.items.map {
            Entry(fingerprint: $0.fingerprint, name: model.name($0.info), edidName: $0.info.name, online: true)
        }
        let known = Set(result.map(\.fingerprint))
        for gone in model.disconnected where !known.contains(gone.fingerprint) {
            result.append(Entry(fingerprint: gone.fingerprint, name: model.name(fingerprint: gone.fingerprint, fallback: gone.name),
                                edidName: gone.name, online: false))
        }
        let all = Set(result.map(\.fingerprint))
        for (fp, name) in model.prefs.knownDisplays.sorted(by: { $0.value < $1.value }) where !all.contains(fp) {
            result.append(Entry(fingerprint: fp, name: model.name(fingerprint: fp, fallback: name), edidName: name, online: false))
        }
        return result
    }

    var body: some View {
        let entries = self.entries
        let selection = model.settingsSelection.flatMap { fp in entries.first { $0.fingerprint == fp } } ?? entries.first
        HStack(alignment: .top, spacing: 0) {
            Sidebar(entries: entries, selection: selection?.fingerprint)
                .frame(width: SettingsMetrics.sidebar)
            Group {
                if let selection {
                    Detail(entry: selection, detailsOpen: detailsOpen).id(selection.fingerprint)
                } else {
                    Text("No displays").foregroundStyle(Color.inkSecondary)
                        .padding(SettingsMetrics.inset)
                }
            }
            .padding(.leading, 1)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: SettingsMetrics.width)
        .frame(minHeight: Self.minHeight, alignment: .top)
        // The sidebar's fill and edge follow the tab's full height, whatever column is taller.
        .background(alignment: .leading) {
            HStack(spacing: 0) {
                Rectangle().fill(Color.inkPrimary.opacity(0.035)).frame(width: SettingsMetrics.sidebar)
                Rectangle().fill(Color.line).frame(width: 1)
            }
        }
    }
}

/// Full names wrap instead of truncating; a display Keeplight can't see says `Disconnected`.
/// Selection uses the system's selection colours (emphasized while the list has keyboard focus);
/// ↑/↓ move it.
private struct Sidebar: View {
    @Environment(AppModel.self) private var model
    let entries: [DisplaysTab.Entry]
    let selection: String?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 2) {
            ForEach(entries) { entry in
                let selected = entry.fingerprint == selection
                Button { model.settingsSelection = entry.fingerprint } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name)
                            .fixedSize(horizontal: false, vertical: true)
                        if !entry.online {
                            Text("Disconnected")
                                .font(.settingsCaption)
                                // On a selection fill the secondary ink would drop under 4.5:1.
                                .foregroundStyle(selected ? (focused ? Color.white : Color.inkPrimary) : Color.inkSecondary)
                        }
                    }
                    .foregroundStyle(selected && focused ? Color.white : Color.inkPrimary)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity, minHeight: SettingsMetrics.sidebarRow, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.controlRadius, style: .continuous)
                            .fill(selected ? Color(nsColor: focused ? .selectedContentBackgroundColor
                                                                    : .unemphasizedSelectedContentBackgroundColor)
                                           : Color.clear)
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .hitTarget("Display \(entry.name)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            move(press.key == .downArrow ? 1 : -1)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Displays")
    }

    private func move(_ step: Int) {
        guard !entries.isEmpty else { return }
        let index = entries.firstIndex { $0.fingerprint == selection } ?? 0
        model.settingsSelection = entries[min(entries.count - 1, max(0, index + step))].fingerprint
    }
}

private struct Detail: View {
    @Environment(AppModel.self) private var model
    let entry: DisplaysTab.Entry
    @State private var detailsOpen: Bool

    init(entry: DisplaysTab.Entry, detailsOpen: Bool) {
        self.entry = entry
        _detailsOpen = State(initialValue: detailsOpen)
    }

    private var fingerprint: String { entry.fingerprint }
    private var item: DisplayItem? { model.items.first { $0.fingerprint == fingerprint } }

    /// Width of the label column (`Brightness`, `Name`).
    private static let labelWidth: CGFloat = 76

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupGap) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(entry.name)
                    .font(.settingsTitle)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if item != nil {
                    ActionButton("Identify") { model.identify() }
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: SettingsMetrics.rowGap) {
                GridRow {
                    label("Name")
                    nameField.gridCellColumns(2)
                }
                if let item {
                    GridRow {
                        label("Brightness")
                        Text(Copy.brightnessLine(model.brightness[item.id], report: model.diagnoses[fingerprint]?.report,
                                                 display: item.info))
                            .fixedSize(horizontal: false, vertical: true)
                            // The protocol's name, for whoever asks; Copy Report carries the rest.
                            .help(model.brightness[item.id]?.control?.backend == .ddc ? "DDC/CI" : "")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        checkAgain
                    }
                }
            }
            if item != nil {
                details
                HStack {
                    Spacer()
                    ActionButton(model.copied == "report:\(fingerprint)" ? "Copied" : "Copy Report") { model.copyReport(fingerprint) }
                        .disabled(model.diagnoses[fingerprint]?.report == nil)
                }
            }
        }
        .padding(SettingsMetrics.inset)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .onAppear {
            model.loadPassport(fingerprint)
            if item != nil, model.diagnoses[fingerprint]?.report == nil { model.diagnose(fingerprint) }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).frame(width: Self.labelWidth, alignment: .leading).gridColumnAlignment(.leading)
    }

    private var nameField: some View {
        let binding = Binding(get: { model.prefs.nicknames[fingerprint] ?? "" },
                              set: { model.prefs.setNickname($0, for: fingerprint) })
        // The EDID name as placeholder, drawn in `inkSecondary`: the system placeholder colour
        // measures 2.5:1.
        return TextField("Name", text: binding, prompt: Text(""))
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .disabled(model.flags.readOnly)
            .overlay(alignment: .leading) {
                if binding.wrappedValue.isEmpty {
                    Text(entry.edidName)
                        .foregroundStyle(Color.inkSecondary)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
    }

    private var checkAgain: some View {
        let running = model.diagnoses[fingerprint]?.running == true
        return ActionButton(running ? Copy.checking : "Check Again") { model.checkAgain(fingerprint) }
            .disabled(running || model.isSettling)
            .fixedSize()
    }

    /// The passport, closed by default. The diagnosis steps are support data: Copy Report only.
    private var details: some View {
        DisclosureGroup("Details", isExpanded: $detailsOpen) {
            let p = model.passports[fingerprint]
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 6) {
                row("Made", p?.made)
                row("Size", p?.size)
                row("Panel", p?.panel)
                row("Modes", p?.modes)
                row("Identity", p?.identity)
            }
            .font(.settingsCallout)
            .padding(.top, 8)
        }
    }

    private func row(_ label: String, _ value: String?) -> some View {
        GridRow {
            Text(label).foregroundStyle(Color.inkSecondary).frame(width: Self.labelWidth - 12, alignment: .leading)
            Text(value ?? "—").textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
