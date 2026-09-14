import AppKit

@MainActor
enum HomeAssets {
    static let mark = image(named: "OmarchyMark")

    /// The mark as a template, so it inverts with the menu bar like a system item.
    static let menuBarMark: NSImage? = {
        guard let mark else { return nil }
        let height: CGFloat = 16
        let image = NSImage(size: NSSize(width: height, height: height), flipped: false) { rect in
            mark.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Omabox"
        return image
    }()

    private static func image(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let data = try? Data(contentsOf: url),
              let representation = NSBitmapImageRep(data: data)
        else { return nil }
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}
