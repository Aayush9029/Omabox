import AppKit

@MainActor
enum HomeAssets {
    static let mark = image(named: "OmarchyMark")

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
