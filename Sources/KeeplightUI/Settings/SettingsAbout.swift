import AppKit
import DisplayCore
import SwiftUI

/// Settings › About [v4 §5]: what Keeplight touches, measured when the tab appears, not claimed.
struct AboutTab: View {
    @Environment(AppModel.self) private var model
    @State private var reading: AboutReading
    @State private var detailsOpen: Bool

    /// `detailsOpen`: the disclosure starts open (render tool only).
    init(detailsOpen: Bool = false) {
        _detailsOpen = State(initialValue: detailsOpen)
        // A first reading now, so the tab measures at its real height; `onAppear` adds what
        // needs the model (Accessibility, the engine's folder).
        _reading = State(initialValue: AboutReading.now(accessibility: false))
    }
    @State private var confirmErase = false

    private static let labelWidth: CGFloat = 112

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: SettingsMetrics.rowGap) {
                measured("Network", reading.network)
                measured("Accessibility", reading.accessibility)
                measured("Private APIs", reading.privateAPIs)
            }
            .padding(.top, 24)
            Text("Measured now.")
                .font(.settingsCaption)
                .foregroundStyle(Color.inkSecondary)
                .padding(.top, 8)
            details
                .padding(.top, SettingsMetrics.groupGap)
            HStack {
                ActionButton(model.copied == "report:about" ? "Copied" : "Copy Report") {
                    model.copy(reading.report(), key: "report:about")
                }
                Spacer()
                ActionButton("Erase All Keeplight Data…") { confirmErase = true }
                    .disabled(model.flags.readOnly)
            }
            .padding(.top, SettingsMetrics.groupGap)
        }
        .padding(SettingsMetrics.inset)
        .frame(width: SettingsMetrics.width, alignment: .leading)
        .onAppear {
            measure()
        }
        // The tab controller keeps this view alive between visits: measure on every return too.
        .onChange(of: model.settingsTab) { _, tab in if tab == .about { measure() } }
        .confirmationDialog("Erase all Keeplight data?", isPresented: $confirmErase) {
            // No destructive role: red means a pending change, nothing else.
            Button("Erase") { model.eraseAllData() }
            Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
        } message: {
            Text("Reconnects displays, then deletes all Keeplight data.")
        }
    }

    private func measure() {
        reading = AboutReading.now(accessibility: model.brightnessKeysActive, data: model.engine.directory)
    }

    /// Icon 64 and the wordmark at 28; version and architecture on the right.
    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 64, height: 64)
                .accessibilityHidden(true)
            Text("Keeplight")
                .font(.wordmarkAbout)
                .tracking(-0.4)
            Spacer(minLength: 12)
            Text(BuildInfo.versionLine)
                .font(.settingsCallout.monospacedDigit())
                .foregroundStyle(Color.inkSecondary)
                .textSelection(.enabled)
        }
    }

    private func measured(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).frame(width: Self.labelWidth, alignment: .leading)
            Text(value).font(.settingsValue).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The symbols behind the count, the signature, where the data lives and the license.
    private var details: some View {
        DisclosureGroup("Details", isExpanded: $detailsOpen) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow(alignment: .top) {
                    detailLabel("Private APIs")
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(reading.interfaces) { row in
                            Text(AboutReading.line(row))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .textSelection(.enabled)
                }
                GridRow {
                    detailLabel("Signature")
                    Text(reading.signature)
                }
                GridRow {
                    detailLabel("Data")
                    HStack(spacing: 8) {
                        Text(reading.dataPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        Spacer(minLength: 0)
                        ActionButton("Show in Finder", small: true) { revealData() }
                    }
                }
                GridRow {
                    detailLabel("License")
                    Text("MIT")
                }
            }
            .font(.settingsCallout)
            .padding(.top, 8)
        }
    }

    private func detailLabel(_ text: String) -> some View {
        Text(text).foregroundStyle(Color.inkSecondary).frame(width: Self.labelWidth - 20, alignment: .leading)
    }

    private func revealData() {
        let preferences = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Preferences/\(Keeplight.bundleIdentifier).plist")
        let existing = [preferences, model.engine.directory].filter { FileManager.default.fileExists(atPath: $0.path) }
        if existing.isEmpty {
            NSWorkspace.shared.open(model.engine.directory.deletingLastPathComponent())
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        }
    }
}

/// One About measurement: values as shown, and the report Copy Report puts on the pasteboard.
struct AboutReading: Equatable {
    /// IP sockets of this process; nil when the kernel refused the query.
    var sockets: Int?
    var accessibilityAllowed: Bool
    var interfaces: [PrivateInterface]
    var signature: String
    var dataPath: String
    var measuredAt: Date

    static func now(accessibility: Bool, data: URL = Keeplight.supportDirectory) -> AboutReading {
        AboutReading(sockets: IntegrityProbe.ipSocketCount(), accessibilityAllowed: accessibility,
                     interfaces: PrivateInterfaces.all, signature: BuildInfo.signature,
                     dataPath: abbreviated(data.path), measuredAt: Date())
    }

    /// `0 connections`; `—` when it could not be measured.
    var network: String { sockets.map { Format.plural($0, "connection") } ?? "—" }

    var accessibility: String { accessibilityAllowed ? "Allowed" : "Not used" }

    /// `13 of 13 found`
    var privateAPIs: String { "\(interfaces.filter(\.isResolved).count) of \(interfaces.count) found" }

    /// `CGSConfigureDisplayEnabled — disconnect a display`, with ` · missing` when absent.
    static func line(_ row: PrivateInterface) -> String {
        "\(row.symbol) — \(row.purpose)" + (row.isResolved ? "" : " · missing")
    }

    /// `~/Library/…` for paths in the home folder.
    static func abbreviated(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Plain text for Copy Report: the tab's own rows (same words), then the symbols. A support
    /// paste, so the labels are the ones on screen.
    func report() -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let system = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let rows: [(String, String)] = [
            ("Network", network), ("Accessibility", accessibility), ("Private APIs", privateAPIs),
            ("Signature", signature), ("Data", dataPath), ("License", "MIT"),
        ]
        var lines = ["Keeplight" + " \(BuildInfo.version) · \(BuildInfo.architecture) · " + "macOS" + " \(system) · \(BuildInfo.commit)",
                     measuredAt.formatted(.iso8601)]
        lines += rows.map { "\($0.0): \($0.1)" }
        lines += interfaces.map { "  " + Self.line($0) }
        return lines.joined(separator: "\n") + "\n"
    }
}
