import AppKit
import SwiftUI

/// What the notice tile above the modules says; one at a time, in this order of precedence.
enum PanelNotice: Equatable {
    /// ⇧ held at launch [A§3.9]: nothing was applied.
    case safeStart
    /// A failure in one sentence.
    case error(String)
    /// What just happened, and the one Undo.
    case receipt(Receipt)

    static func current(safeStart: Bool, error: String?, receipt: Receipt?) -> PanelNotice? {
        if safeStart { return .safeStart }
        if let error { return .error(error) }
        return receipt.map(PanelNotice.receipt)
    }

    /// Identity for the in/out transition: a different kind of notice is a different tile.
    var kind: Int {
        switch self {
        case .safeStart: 0
        case .error: 1
        case .receipt: 2
        }
    }
}

/// The tile (v5 §4): `moduleRadius`, the module fill, 12 / 8 padding, at least 36 tall.
struct NoticeTile: View {
    @Environment(AppModel.self) private var model
    let notice: PanelNotice

    var body: some View {
        content
            .padding(.leading, Metrics.noticeHPadding)
            .padding(.trailing, trailingPadding)
            .padding(.vertical, Metrics.noticeVPadding)
            .frame(width: Metrics.moduleWidth, alignment: .leading)
            .frame(minHeight: Metrics.noticeMinHeight)
            .background(TileBackground())
            .accessibilityElement(children: .contain)
    }

    /// The dismiss glyph sits centred in its 24 × 24 target; its edge lines up with the text edge.
    private var trailingPadding: CGFloat {
        if case .error = notice { return Metrics.noticeHPadding - (Metrics.minTarget - 10) / 2 }
        return Metrics.noticeHPadding
    }

    @ViewBuilder private var safeStartChips: some View {
        Chip(OverlayCopy.rescue) { model.safeStartRescue() }
        Button(OverlayCopy.continueLabel) { model.safeStartContinue() }
            .buttonStyle(ChipButtonStyle())
            .keyboardShortcut(.defaultAction)
            .hitTarget(OverlayCopy.continueLabel)
    }

    @ViewBuilder private var content: some View {
        switch notice {
        case .safeStart:
            // One line when it fits beside the two chips; otherwise the sentence, then the chips
            // right-aligned under it (never a ragged two-line wrap next to them).
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text(OverlayCopy.safeStart).font(.bodyText).lineLimit(1).fixedSize()
                    Spacer(minLength: 8)
                    safeStartChips
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text(OverlayCopy.safeStart).font(.bodyText).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        safeStartChips
                    }
                }
            }
        case .error(let text):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 12))
                    .foregroundStyle(Color.inkSecondary).accessibilityHidden(true)
                Text(text).font(.bodyText).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button { model.errorMessage = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .semibold))
                        .frame(width: Metrics.minTarget, height: Metrics.minTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(InkButtonStyle())
                .hitTarget("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        case .receipt(let receipt):
            HStack(spacing: 8) {
                Text(receipt.text).font(.bodyText).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if receipt.undo != nil, model.pending == nil {
                    Chip("Undo") { model.undo(receipt: receipt) }
                }
            }
        }
    }
}
