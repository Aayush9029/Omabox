import SwiftUI

/// The two tones every provider card is built from, after Compose: a darker top
/// band and a near-black bottom band in dark mode, faint greys in light.
extension ShapeStyle where Self == Color {
    static func cardTop(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .black.opacity(0.6) : .primary.opacity(0.06)
    }

    static func cardBottom(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .black.opacity(0.9) : .primary.opacity(0.03)
    }

    static func cardTile(_ scheme: ColorScheme) -> Color {
        scheme == .dark ? .black.opacity(0.7) : .primary.opacity(0.05)
    }
}
