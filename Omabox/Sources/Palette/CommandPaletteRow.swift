import SwiftUI

struct CommandPaletteRow: View {
    let command: DesktopCommand
    let isHighlighted: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: command.symbol)
                .font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28, height: 28)
                .background(.primary.opacity(0.06), in: .rect(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(command.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Text(command.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(command.section)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.tertiary)
            if command == .resolution {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .primary.opacity(isHighlighted ? 0.14 : (isHovering ? 0.07 : 0)),
            in: .rect(cornerRadius: 10, style: .continuous)
        )
        .contentShape(.rect)
        .onHover { isHovering = $0 }
    }
}
