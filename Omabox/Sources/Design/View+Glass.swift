import SwiftUI

extension View {
    func flareGlass(cornerRadius: CGFloat) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}
