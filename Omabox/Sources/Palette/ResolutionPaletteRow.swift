import SwiftUI

struct ResolutionPaletteRow: View {
    let preset: DesktopResolutionPreset
    let isHighlighted: Bool
    let isCurrent: Bool

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: preset == .fitToScreen ? "arrow.up.left.and.arrow.down.right" : "display")
                .font(.system(size: 13, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 28, height: 28)
                .background(.primary.opacity(0.06), in: .rect(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(preset.title).font(.callout.weight(.medium)).monospacedDigit()
                Text(preset.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if isCurrent {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
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
