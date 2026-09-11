import SwiftUI

extension View {
    func omaboxGlass(cornerRadius: CGFloat) -> some View {
        glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
    }
}
