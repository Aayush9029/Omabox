import SwiftUI
@testable import Omabox

struct PaletteFocusHarness: View {
    let model: PaletteModel
    var size = CGSize(width: 620, height: 480)

    var body: some View {
        ZStack {
            Color.clear
            if model.isPresented {
                CommandPaletteView(model: model, onExecute: { _ in })
            }
        }
        .frame(width: size.width, height: size.height)
    }
}
