import SwiftUI

struct HomeResourcePresetRow: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let symbol: String
    let unit: String
    let values: [Int]
    let identifier: String
    @Binding var selection: Int

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout)
                Text("\(selection) \(unit)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(selection) \(unit)")
                    .accessibilityIdentifier("\(identifier).value")
            }
            .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 0)
            HStack(spacing: 2) {
                ForEach(values, id: \.self) { value in
                    presetButton(value)
                }
            }
            .padding(3)
            .background(.primary.opacity(0.045), in: .rect(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(.primary.opacity(0.04), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .frame(maxWidth: 280)
        }
        .padding(.vertical, 10)
        .frame(minHeight: 58)
        .accessibilityElement(children: .contain)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: selection)
    }

    private func presetButton(_ value: Int) -> some View {
        let isSelected = selection == value
        return Button {
            selection = value
        } label: {
            Text("\(value)")
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(minWidth: 26, maxWidth: .infinity, minHeight: 30)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 7)
                            .fill(.white.opacity(colorScheme == .dark ? 0.13 : 0.88))
                            .shadow(color: .black.opacity(0.1), radius: 2, y: 1)
                            .overlay {
                                RoundedRectangle(cornerRadius: 7)
                                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
                            }
                    }
                }
                .contentShape(.rect(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(value) \(unit)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("\(identifier).preset.\(value)")
    }
}
