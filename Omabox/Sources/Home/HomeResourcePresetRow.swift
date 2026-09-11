import SwiftUI

struct HomeResourcePresetRow: View {
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
            HStack(spacing: 4) {
                ForEach(values, id: \.self) { value in
                    presetButton(value)
                }
            }
            .frame(maxWidth: 280)
        }
        .padding(.vertical, 10)
        .frame(minHeight: 58)
        .accessibilityElement(children: .contain)
    }

    private func presetButton(_ value: Int) -> some View {
        let isSelected = selection == value
        return Button {
            selection = value
        } label: {
            Text("\(value)")
                .font(.system(size: 12, weight: isSelected ? .semibold : .regular, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                .frame(minWidth: 24, maxWidth: .infinity, minHeight: 32)
                .background(isSelected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.045), in: .rect(cornerRadius: 5))
                .overlay {
                    RoundedRectangle(cornerRadius: 5)
                        .strokeBorder(isSelected ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.08), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(value) \(unit)")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier("\(identifier).preset.\(value)")
    }
}
