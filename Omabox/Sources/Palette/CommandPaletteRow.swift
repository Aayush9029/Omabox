import SwiftUI

struct CommandPaletteRow: View {
    let command: DesktopCommand
    let isHighlighted: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: command.symbol)
                .font(.system(size: 16, weight: .medium))
                .frame(width: 28)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(command.title).font(.callout.weight(.medium))
                Text(command.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if command == .resolution || isHighlighted {
                Image(systemName: command == .resolution ? "chevron.right" : "return")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHighlighted ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 10))
        .contentShape(.rect(cornerRadius: 10))
    }
}
