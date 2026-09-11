import SwiftUI

/// Liquid Glass alone is too clear to read long-form text against an arbitrary desktop.
struct PanelScrim: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        (colorScheme == .dark ? Color.black.opacity(0.30) : Color.white.opacity(0.42))
            .ignoresSafeArea()
    }
}
