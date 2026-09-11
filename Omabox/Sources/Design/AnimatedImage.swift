import AppKit
import SwiftUI

struct AnimatedImage: NSViewRepresentable {
    let resource: String
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeNSView(context: Context) -> AnimatedImageView {
        let view = AnimatedImageView()
        view.imageScaling = .scaleAxesIndependently
        view.canDrawSubviewsIntoLayer = true
        view.image = Self.image(named: resource)
        view.allowsAnimation = !reduceMotion
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        return view
    }

    func updateNSView(_ view: AnimatedImageView, context: Context) {
        view.allowsAnimation = !reduceMotion
        guard view.image == nil else { return }
        view.image = Self.image(named: resource)
    }

    static func dismantleNSView(_ view: AnimatedImageView, coordinator: ()) {
        view.invalidate()
    }

    private static func image(named resource: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: resource, withExtension: "gif") else { return nil }
        return NSImage(contentsOf: url)
    }
}
