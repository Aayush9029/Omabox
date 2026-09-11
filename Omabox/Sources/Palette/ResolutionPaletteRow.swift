import SwiftUI

struct ResolutionPaletteRow: View {
    let preset: DesktopResolutionPreset
    let isHighlighted: Bool
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: preset == .fitToScreen ? "arrow.up.left.and.arrow.down.right" : "display")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 28)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(preset.title).font(.callout.weight(.medium)).monospacedDigit()
                Text(preset.subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isCurrent {
                Image(systemName: "checkmark").font(.caption.weight(.semibold))
            } else if isHighlighted {
                Image(systemName: "return").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isHighlighted ? Color.primary.opacity(0.08) : .clear, in: .rect(cornerRadius: 10))
        .contentShape(.rect(cornerRadius: 10))
    }
}
