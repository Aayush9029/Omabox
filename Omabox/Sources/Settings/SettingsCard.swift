import SwiftUI

struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    private let radius: CGFloat = 16

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .clipShape(.rect(cornerRadius: radius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.primary.opacity(0.1), lineWidth: 1)
        }
    }
}

extension View {
    func cardBand(_ level: Int = 0) -> some View {
        modifier(CardBand(level: level))
    }
}

private struct CardBand: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let level: Int

    func body(content: Content) -> some View {
        content
            .background(fill)
            .background(.ultraThinMaterial)
    }

    private var fill: Color {
        let dark: [Double] = [0.18, 0.28, 0.38]
        let light: [Double] = [0.04, 0.03, 0.02]
        let index = min(level, dark.count - 1)
        return colorScheme == .dark
            ? .black.opacity(dark[index])
            : .primary.opacity(light[index])
    }
}
