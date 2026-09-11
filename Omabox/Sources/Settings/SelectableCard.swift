import SwiftUI

struct SelectableCard<Content: View>: View {
    let isSelected: Bool
    var isBlack = false
    let action: () -> Void
    @ViewBuilder let content: Content

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    private let radius: CGFloat = 10

    var body: some View {
        Button(action: action) {
            content
                .foregroundStyle(isSelected ? AnyShapeStyle(selectedForeground) : AnyShapeStyle(.primary))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(cardBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: radius, style: .continuous)
                        .strokeBorder(
                            isSelected ? selectedFill : .primary.opacity(isHovering ? 0.18 : 0.08),
                            lineWidth: isSelected ? 2 : 1
                        )
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }

    private var selectedFill: Color {
        colorScheme == .dark ? .white : .black
    }

    private var selectedForeground: Color {
        colorScheme == .dark ? .black : .white
    }

    @ViewBuilder
    private var cardBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(selectedFill)
        } else if isBlack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(.black.opacity(colorScheme == .dark ? 0.35 : 0.06))
        } else {
            Color.clear.omaboxGlass(cornerRadius: radius)
        }
    }
}
