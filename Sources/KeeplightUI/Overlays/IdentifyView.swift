import SwiftUI

/// Identify [A§3.3]: the display's name, large, on that screen. Nothing else.
struct IdentifyView: View {
    static let width: CGFloat = 340
    static let minHeight: CGFloat = 160

    let name: String

    var body: some View {
        Text(name)
            .font(.identify)
            .foregroundStyle(Color.Instrument.ink)
            .multilineTextAlignment(.center)
            .lineLimit(3)
            .minimumScaleFactor(0.5)
            .fixedSize(horizontal: false, vertical: true)
            .padding(28)
            .frame(width: Self.width)
            .frame(minHeight: Self.minHeight)
            .instrumentPlate()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(OverlayCopy.identifyAnnouncement([name]))
    }
}
