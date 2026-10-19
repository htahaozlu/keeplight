import AppKit
import DisplayCore
import SwiftUI

/// A tile 308 × 108 (v5 §1, §3) whose content is padded 12 / 10 and top-aligned, so every module
/// with a slider is the same height whatever its state; `compact` (78) for a mirror target or a
/// disconnected display, which have one row under the name. Locked (a change waits for Keep, the
/// displays wake): the content fades to `Metrics.lockedOpacity` and is disabled, the tile stays.
struct ModuleTile<Content: View>: View {
    var locked = false
    var compact = false
    @ViewBuilder let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .padding(.horizontal, Metrics.moduleHPadding)
            .padding(.vertical, Metrics.moduleVPadding)
            .frame(width: Metrics.moduleWidth, height: compact ? Metrics.compactModuleHeight : Metrics.moduleHeight,
                   alignment: .topLeading)
            .opacity(locked ? Metrics.lockedOpacity : 1)
            .animation(Tween.lock.animation(reduceMotion: reduceMotion), value: locked)
            .disabled(locked)
            .background(TileBackground())
    }
}

/// One display: the name row (24), the slider slot (28), the resolution chip (24), 6 apart.
struct DisplayModule: View {
    @Environment(AppModel.self) private var model
    let item: DisplayItem
    /// `Main` only means something when there is another desktop to compare with.
    let showsMain: Bool

    private var locked: Bool { model.pending != nil || model.isSettling }

    var body: some View {
        let name = model.name(item.info)
        ModuleTile(locked: locked, compact: item.info.isMirrorTarget) {
            VStack(alignment: .leading, spacing: Metrics.rowGap) {
                DisplayHeader(item: item, name: name, showsMain: showsMain)
                if item.info.isMirrorTarget {
                    MirrorRow(item: item)
                } else {
                    BrightnessSlot(item: item)
                    if let current = item.current { ResolutionChip(item: item, current: current) }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(showsMain && item.info.isMain ? "\(name), main display" : name)
    }
}

// MARK: - Header

private struct DisplayHeader: View {
    @Environment(AppModel.self) private var model
    let item: DisplayItem
    let name: String
    let showsMain: Bool

    var body: some View {
        HStack(spacing: 0) {
            Button { model.identify() } label: {
                Text(name).font(.titlePlate).lineLimit(1).truncationMode(.tail)
                    .frame(minHeight: Metrics.headerRow).contentShape(Rectangle())
            }
            .buttonStyle(BareButtonStyle())
            .hitTarget("Identify \(name)")
            .help("Show on screen")
            .accessibilityLabel(name)
            .accessibilityHint("Shows each display's name on its screen")
            Spacer(minLength: 12)
            if showsMain, item.info.isMain {
                Text("Main").font(.captionText).foregroundStyle(Color.inkSecondary)
                    .padding(.trailing, 2)
            }
            MoreMenu(item: item, name: name)
        }
        .frame(height: Metrics.headerRow)
    }
}

/// `···`: more for this display, 24 × 24, its glyph flush with the right edge of the content so it
/// shares a column edge with the percent below it. Secondary ink, primary under the pointer.
private struct MoreMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.forcedControlState) private var forced
    @State private var hovering = false
    let item: DisplayItem
    let name: String

    var body: some View {
        let others = model.items.filter { $0.id != item.id && !$0.info.isMirrorTarget }
        let mirror = model.items.first { $0.info.mirrorSource == item.id }
        let lit = (forced ?? (hovering ? .hover : .rest)) != .rest
        Menu {
            if !item.info.isMain, !item.info.isMirrorTarget {
                Button("Make Main Display") { model.makeMain(item) }
            }
            if !item.info.isMirrorTarget, !others.isEmpty {
                Menu("Mirror Onto") {
                    ForEach(others) { other in
                        Button(model.name(other.info)) { model.mirror(other, of: item) }
                    }
                }
            }
            if item.info.isMirrorTarget {
                Button("Stop Mirroring") { model.stopMirroring(item) }
            } else if let mirror {
                Button("Stop Mirroring") { model.stopMirroring(mirror) }
            }
            Divider()
            Button("Identify") { model.identify() }
            if case .available? = model.brightness[item.id] {
                Button("Copy Command") { model.copyCommand(item) }
            }
            Button("Show in Settings…") { model.openSettings(tab: .displays, selecting: item.fingerprint) }
            if model.canDisconnect(item), !item.info.isMirrorTarget {
                Divider()
                Button("Disconnect…") { model.disconnect(item) }
            }
        } label: {
            // The SF ellipsis has no side bearing, so its right edge sits on the column the
            // percentage, the dismiss glyph and `Quit` end on.
            Image(systemName: "ellipsis").font(.system(size: 13, weight: .semibold))
                .foregroundStyle(lit ? Color.inkPrimary : Color.inkSecondary)
                .frame(width: Metrics.minTarget, height: Metrics.minTarget, alignment: .trailing)
                .accessibilityLabel("More")
                .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(BareButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .trackingHover($hovering)
        .hitTarget("More")
        .accessibilityLabel("More for \(name)")
    }
}

// MARK: - Brightness

/// The slider's slot: the capsule slider, or the same rail empty while reading or without control.
private struct BrightnessSlot: View {
    @Environment(AppModel.self) private var model
    let item: DisplayItem

    var body: some View {
        Group {
            switch model.brightness[item.id] ?? .probing {
            case .available(_, let value, _):
                CapsuleSlider(value: value ?? model.prefs.lastWritten[item.fingerprint]?.value,
                              floor: model.brightnessFloor(for: item.id),
                              visible: model.isPanelOpen,
                              onChange: { model.setBrightness(item.id, to: $0) },
                              onDrag: { began in began ? model.beginDrag(item.id) : model.endDrag(item.id) })
            case .probing:
                Text("Reading…").font(.callout12).foregroundStyle(Color.inkSecondary)
                    .padding(.leading, 10)
                    .frame(width: Metrics.sliderTrackWidth, height: Metrics.chipHeight, alignment: .leading)
                    .background(RailBackground())
            case .unavailable:
                NoControlRail(item: item)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Metrics.sliderRow, maxHeight: Metrics.sliderRow, alignment: .leading)
    }
}

/// `No brightness control` in the empty rail, `info.circle` in its last 24 × 24; the whole rail
/// opens the one-line popover with `Check Again`.
private struct NoControlRail: View {
    @Environment(AppModel.self) private var model
    @Environment(\.forcedControlState) private var forced
    @State private var hovering = false
    let item: DisplayItem

    var body: some View {
        let lit = (forced ?? (hovering ? .hover : .rest)) != .rest
        Button { model.toggleWhy(item) } label: {
            HStack(spacing: 0) {
                Text("No brightness control").font(.callout12).foregroundStyle(Color.inkSecondary)
                    .lineLimit(1)
                    .padding(.leading, 10)
                Spacer(minLength: 0)
                Image(systemName: "info.circle").font(.system(size: 13))
                    .foregroundStyle(lit ? Color.inkPrimary : Color.inkSecondary)
                    .frame(width: Metrics.chipHeight, height: Metrics.chipHeight)
            }
            .frame(width: Metrics.sliderTrackWidth, height: Metrics.chipHeight)
            .background(RailBackground())
            .contentShape(Capsule())
        }
        .buttonStyle(BareButtonStyle())
        .trackingHover($hovering)
        .hitTarget("Why no brightness control")
        .accessibilityLabel("No brightness control")
        .accessibilityHint("Shows why")
        .popover(isPresented: Binding(get: { model.whyExpanded.contains(item.id) },
                                      set: { if !$0 { model.whyExpanded.remove(item.id) } }),
                 arrowEdge: .bottom) {
            WhyPopover(item: item)
        }
    }
}

struct WhyPopover: View {
    @Environment(AppModel.self) private var model
    let item: DisplayItem

    var body: some View {
        let state = model.diagnoses[item.fingerprint]
        VStack(alignment: .leading, spacing: 10) {
            Text(Copy.noControlLine(state?.report, display: item.info) ?? "Checking…")
                .fixedSize(horizontal: false, vertical: true)
            Chip(state?.running == true ? "Checking…" : "Check Again") { model.checkAgain(item.fingerprint) }
                .disabled(state?.running == true || model.isSettling)
        }
        .font(.system(size: 13))
        .tint(Color.inkPrimary)
        .padding(12)
        .frame(width: 240, alignment: .leading)
    }
}

// MARK: - Resolution

/// The resolution chip: `2560 × 1440`, `Soft` only when it is blurry, a chevron; a pull-down of
/// the recommended sizes and `Show All…`. Left-aligned; nothing to its right.
private struct ResolutionChip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.forcedControlState) private var forced
    @State private var hovering = false
    let item: DisplayItem
    let current: DisplayMode

    var body: some View {
        let soft = item.isSoft(current)
        // A menu shows no pressed state of its own (it opens on mouse down), so the chip follows
        // the pointer only.
        let state: ControlState = (forced ?? (hovering ? .hover : .rest)) == .rest ? .rest : .hover
        Menu {
            ForEach(item.recommended) { mode in
                Toggle(Self.title(mode, in: item), isOn: Binding(
                    get: { mode.modeNumber == current.modeNumber },
                    set: { _ in model.setMode(item, to: mode) }))
                    // "2560 by 1440", not "2560 times 1440".
                    .accessibilityLabel(OverlayCopy.spoken(Self.title(mode, in: item)))
            }
            Divider()
            Button("Show All…") { AllModesMenu.show(for: item, model: model) }
        } label: {
            HStack(spacing: 6) {
                Text(current.sizeText).font(.bodyText).foregroundStyle(Color.inkPrimary)
                if soft { Text("Soft").foregroundStyle(Color.inkSecondary) }
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.inkSecondary).accessibilityHidden(true)
            }
            .font(.system(size: 13))
            .padding(.horizontal, Metrics.chipHPadding)
            .frame(height: Metrics.chipHeight)
            .background(ChipCapsule(state: state))
            .contentShape(Capsule())
        }
        .menuStyle(.button)
        .buttonStyle(BareButtonStyle())
        .menuIndicator(.hidden)
        .fixedSize()
        .trackingHover($hovering)
        .frame(height: Metrics.chipRow)
        .hitTarget("Resolution")
        .accessibilityLabel("Resolution")
        .accessibilityValue(Self.spoken(current, soft: soft))
    }

    /// `2560 × 1440`, then `· 120 Hz` where the size has several rates, then `· Soft`.
    static func title(_ mode: DisplayMode, in item: DisplayItem) -> String {
        var text = mode.sizeText
        if item.hasRefreshChoice(mode), mode.refreshRate > 0 { text += " · \(Format.hz(mode.refreshRate)) Hz" }
        if item.isSoft(mode) { text += " · Soft" }
        return text
    }

    static func spoken(_ mode: DisplayMode, soft: Bool) -> String {
        "\(mode.width) by \(mode.height)" + (soft ? ", soft" : "")  // copy-budget: spoken
    }
}

/// `Show All…`: every usable mode, grouped by refresh rate.
@MainActor
enum AllModesMenu {
    static func show(for item: DisplayItem, model: AppModel) {
        let menu = NSMenu()
        menu.autoenablesItems = false
        let groups = Dictionary(grouping: item.usableModes) { Int($0.refreshRate.rounded()) }
        let showsRates = groups.count > 1
        for rate in groups.keys.sorted(by: >) {
            if showsRates { menu.addItem(NSMenuItem.sectionHeader(title: rate > 0 ? "\(rate) Hz" : "Default rate")) }
            for mode in groups[rate] ?? [] {
                var title = mode.sizeText
                if item.isSoft(mode) { title += " · Soft" }
                menu.addItem(ClosureMenuItem(title, state: mode.modeNumber == item.current?.modeNumber ? .on : .off) {
                    model.setMode(item, to: mode)
                })
            }
        }
        menu.popUpAtPointer()
    }
}

// MARK: - Mirror target

/// A mirror target shows its source's picture: the slider's slot says so, with a way out.
private struct MirrorRow: View {
    @Environment(AppModel.self) private var model
    let item: DisplayItem

    var body: some View {
        HStack(spacing: 8) {
            Text("Mirrors \(sourceName)").foregroundStyle(Color.inkSecondary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
            Chip("Stop Mirroring") { model.stopMirroring(item) }
        }
        .frame(height: Metrics.sliderRow)
    }

    private var sourceName: String {
        item.info.mirrorSource.flatMap { model.item($0) }.map { model.name($0.info) } ?? "another display"
    }
}

// MARK: - Disconnected

/// Keeplight disconnected it: the name in secondary ink, `Disconnected`, and a way back.
struct DisconnectedModule: View {
    @Environment(AppModel.self) private var model
    let display: DisconnectedDisplay

    var body: some View {
        let name = model.name(fingerprint: display.fingerprint, fallback: display.name)
        ModuleTile(locked: model.pending != nil, compact: true) {
            VStack(alignment: .leading, spacing: Metrics.rowGap) {
                HStack(spacing: 8) {
                    Text(name).font(.titlePlate).foregroundStyle(Color.inkSecondary)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text("Disconnected").font(.captionText).foregroundStyle(Color.inkSecondary)
                }
                .frame(height: Metrics.headerRow)
                HStack(spacing: 8) {
                    Text(Copy.disconnectedCaption).font(.captionText).foregroundStyle(Color.inkSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Chip("Reconnect") { model.reconnect(display) }
                }
                .frame(height: Metrics.sliderRow)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(name), disconnected")
    }
}
