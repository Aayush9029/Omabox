import SwiftUI

/// A tool the model may use, switched on and off with a click.
struct ToolChip: View {
    let title: String
    let symbol: String
    let isOn: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .symbolVariant(isOn ? .fill : .none)
                Text(title)
                    .font(.callout.weight(.medium))
                Image(systemName: isOn ? "checkmark" : "plus")
                    .font(.system(size: 9, weight: .bold))
                    .opacity(isOn ? 1 : 0.6)
            }
            .foregroundStyle(isOn ? AnyShapeStyle(onForeground) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                isOn ? onFill : .primary.opacity(isHovering ? 0.08 : 0.04),
                in: .capsule
            )
            .overlay {
                Capsule()
                    .strokeBorder(isOn ? onFill : .primary.opacity(isHovering ? 0.2 : 0.12), lineWidth: 1)
            }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.15), value: isOn)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
    }

    private var onFill: Color { colorScheme == .dark ? .white : .black }
    private var onForeground: Color { colorScheme == .dark ? .black : .white }
}
