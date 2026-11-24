import SwiftUI

enum Metrics {
    static let cardRadius: CGFloat = 12
    static let cardPadding: CGFloat = 12
    static let minTapTarget: CGFloat = 44
    static let transition: Double = 0.25
}

extension View {
    /// The 2.0 card: 12 pt padding on the card surface, 12 pt corners.
    func cardStyle() -> some View {
        padding(Metrics.cardPadding)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
    }
}

/// «ЖДЁТ ВАС · 2» — small uppercase section header.
struct SectionHeader: View {
    let title: String
    var count: Int?

    var body: some View {
        Text(count.map { "\(title) · \($0)" } ?? title)
            .font(.system(size: 13))
            .textCase(.uppercase)
            .kerning(0.3)
            .foregroundStyle(Palette.meta)
            .padding(.horizontal, 4)
            .padding(.top, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// Capsule toast floating above the bottom bar, with an optional action.
struct ToastView: View {
    let text: String
    var actionTitle: String?
    var action: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            Text(text)
                .font(.system(size: 15))
                .foregroundStyle(Palette.text)
            if let actionTitle {
                Button(actionTitle, action: action)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.tint)
                    .frame(minHeight: Metrics.minTapTarget)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
        .background(.regularMaterial, in: Capsule())
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}
