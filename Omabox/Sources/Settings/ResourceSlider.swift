import SwiftUI

/// A labelled `StopSlider` over a fixed set of values, after Flare's Width slider.
struct ResourceSlider: View {
    let title: String
    let stops: [Int]
    let unit: (Int) -> String
    let value: Int
    let accessibilityID: String
    let onCommit: (Int) -> Void

    @State private var preview: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title)
                Spacer()
                Text(unit(preview ?? value))
                    .font(.callout.weight(.medium))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.12), value: preview ?? value)
            }
            StopSlider(
                count: stops.count,
                index: nearestIndex,
                tint: [Color(red: 0.62, green: 0.82, blue: 0.42), Color(red: 0.45, green: 0.70, blue: 0.30)],
                onPreview: { index in preview = index.map { stops[$0] } },
                onCommit: { onCommit(stops[$0]) }
            )
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(unit(value))
        .accessibilityIdentifier(accessibilityID)
        .accessibilityAdjustableAction { direction in
            let index = nearestIndex
            switch direction {
            case .increment where index + 1 < stops.count: onCommit(stops[index + 1])
            case .decrement where index > 0: onCommit(stops[index - 1])
            default: break
            }
        }
    }

    private var nearestIndex: Int {
        stops.firstIndex(of: value)
            ?? stops.enumerated().min { abs($0.element - value) < abs($1.element - value) }?.offset
            ?? 0
    }
}
