import SwiftUI

/// Settings › General [v4 §5]: four groups, no headers. A setting whose name does not say what
/// it does gets one short detail line under it (System Settings' subtitle), not a tooltip.
struct GeneralTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = model.prefs
        SettingsForm {
            SettingsGroup {
                SettingsToggle("Open at login",
                               isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                if model.errorMessage == PanelError.loginItem, let message = model.errorMessage {
                    SettingsHelp(message)
                }
                SettingsToggle("Show in menu bar", isOn: $prefs.showInMenuBar)
                if !prefs.showInMenuBar {
                    SettingsHelp("Reopen with \(HotKeys.Key.panel.display).")
                }
            }
            SettingsGroup {
                SettingsRow("Revert after", detail: "Unkept resolution, main display and mirroring changes go back.") {
                    Picker("Revert after", selection: $prefs.revertSeconds) {
                        Text("15 s").tag(15)
                        Text("30 s").tag(30)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                SettingsToggle("Restore brightness after wake", isOn: $prefs.restoreAfterWake,
                               detail: "For monitors that reset while asleep.")
            }
            SettingsGroup {
                SettingsToggle("Brightness keys",
                               isOn: Binding(get: { prefs.brightnessKeys }, set: { model.setBrightnessKeys($0) }),
                               detail: "Change the display under the pointer. ⌥ for finer steps.")
                if prefs.brightnessKeys && !model.brightnessKeysActive {
                    SettingsHelp("Needs Accessibility permission.") {
                        ActionButton("Allow in System Settings…", small: true) { model.openAccessibilitySettings() }
                    }
                }
                if prefs.brightnessKeys {
                    SettingsToggle("Use F1 and F2", isOn: $prefs.functionKeysAsBrightness,
                                   detail: "Plain F1 and F2 no longer reach other apps.")
                        .padding(.leading, SettingsMetrics.indent)
                }
            }
            SettingsGroup {
                shortcut("Open Keeplight", .panel)
                shortcut("Rescue (hold)", .rescue, detail: "Restores the last kept setup when a screen goes dark.")
            }
        }
    }

    /// A read-only shortcut row; a line under it only when another app holds the chord.
    @ViewBuilder private func shortcut(_ title: String, _ key: HotKeys.Key, detail: String? = nil) -> some View {
        SettingsRow(title, detail: detail) {
            Text(key.display)
                .foregroundStyle(Color.inkSecondary)
                .accessibilityLabel(title)
                .accessibilityValue(key.display)
                .settingsDetailHint(detail)
        }
        if model.hotKeyFailures.contains(key.display) {
            SettingsHelp("\(key.display) is taken by another app.")
        }
    }
}
