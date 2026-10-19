import AppKit
import SwiftUI

/// Settings geometry [v4 §5]: 560 wide, 20 pt insets, groups 20 pt apart without headers, rows
/// 12 pt apart, a help line 4 pt under its row.
enum SettingsMetrics {
    static let width: CGFloat = 560
    static let inset: CGFloat = 20
    static let groupGap: CGFloat = 20
    static let rowGap: CGFloat = 12
    static let helpGap: CGFloat = 4
    static let indent: CGFloat = 20
    static let row: CGFloat = 24
    static let sidebarRow: CGFloat = 28
    static let sidebar: CGFloat = 180
    static var contentWidth: CGFloat { width - 2 * inset }
}

/// Settings type [v4 §1]: body 13, callout 12 secondary, caption 11; SF only.
extension Font {
    static let settingsBody = Font.system(size: 13)
    static let settingsCallout = Font.system(size: 12)
    static let settingsCaption = Font.system(size: 11)
    static let settingsTitle = Font.system(size: 17, weight: .semibold)
    static let settingsValue = Font.system(size: 13, weight: .semibold).monospacedDigit()
    static let wordmarkAbout = Font.system(size: 28, weight: .bold)
}

/// One tab's content at the window's width and its natural height (the window fits it).
struct SettingsPane: View {
    let tab: SettingsTab
    /// Disclosures start open (render tool only).
    var detailsOpen = false

    var body: some View {
        Group {
            switch tab {
            case .general: GeneralTab()
            case .displays: DisplaysTab(detailsOpen: detailsOpen)
            case .about: AboutTab(detailsOpen: detailsOpen)
            }
        }
        .font(.settingsBody)
        .foregroundStyle(Color.inkPrimary)
        .frame(width: SettingsMetrics.width)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// A padded column of groups, 20 pt apart.
struct SettingsForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.groupGap) { content }
            .padding(SettingsMetrics.inset)
            .frame(width: SettingsMetrics.width, alignment: .leading)
    }
}

/// Rows of one group, 12 pt apart.
struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowGap) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Title on the left, its control on the right. `detail` is one short line under the title
/// (secondary, wraps) saying what the setting does — System Settings' subtitle; `help` is the
/// tooltip of the whole row.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    var help: String?
    @ViewBuilder var control: Control

    init(_ title: String, detail: String? = nil, help: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.help = help
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.settingsCallout)
                        .foregroundStyle(Color.inkSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityHidden(true)
            control
        }
        .frame(minHeight: SettingsMetrics.row)
        .contentShape(Rectangle())
        .settingsHelp(help)
    }
}

/// A switch row; the switch carries the row title for VoiceOver.
struct SettingsToggle: View {
    let title: String
    @Binding var isOn: Bool
    var detail: String?
    var help: String?

    init(_ title: String, isOn: Binding<Bool>, detail: String? = nil, help: String? = nil) {
        self.title = title
        _isOn = isOn
        self.detail = detail
        self.help = help
    }

    var body: some View {
        SettingsRow(title, detail: detail, help: help) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .settingsHelp(help)
                .settingsDetailHint(detail)
        }
    }
}

/// The one help line a row may have: callout, secondary ink. Sits 4 pt under its row (the
/// negative spacing undoes the group's 12).
struct SettingsHelp<Accessory: View>: View {
    let text: String
    @ViewBuilder var accessory: Accessory

    init(_ text: String, @ViewBuilder accessory: () -> Accessory) {
        self.text = text
        self.accessory = accessory()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Text(text)
                .font(.settingsCallout)
                .foregroundStyle(Color.inkSecondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            accessory
        }
        .padding(.top, SettingsMetrics.helpGap - SettingsMetrics.rowGap)
    }
}

extension SettingsHelp where Accessory == EmptyView {
    init(_ text: String) { self.init(text) { EmptyView() } }
}

extension View {
    /// The row's detail line, read by VoiceOver after the control (its own text is hidden).
    @ViewBuilder func settingsDetailHint(_ text: String?) -> some View {
        if let text { accessibilityHint(text) } else { self }
    }

    /// `.help` only when there is a tooltip.
    @ViewBuilder func settingsHelp(_ text: String?) -> some View {
        if let text { help(text) } else { self }
    }
}
