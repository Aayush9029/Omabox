import AppKit
import SwiftUI

/// The app icon's bolt, as a shape, so the icon, the About pane and the menu bar
/// all draw the same artwork instead of three lookalike SF Symbols.
public struct OmaboxBolt: Shape {
    private static let designSize = CGSize(width: 640, height: 604)

    public init() {}

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 372.0, y: 10.8))
        path.addCurve(
            to: CGPoint(x: 395.0, y: 22.6),
            control1: CGPoint(x: 381.6, y: 2.0),
            control2: CGPoint(x: 396.8, y: 9.9)
        )
        path.addLine(to: CGPoint(x: 362.6, y: 244.0))
        path.addCurve(
            to: CGPoint(x: 375.2, y: 258.6),
            control1: CGPoint(x: 361.4, y: 251.7),
            control2: CGPoint(x: 367.4, y: 258.6)
        )
        path.addLine(to: CGPoint(x: 566.0, y: 258.6))
        path.addCurve(
            to: CGPoint(x: 576.0, y: 283.2),
            control1: CGPoint(x: 578.8, y: 258.6),
            control2: CGPoint(x: 585.2, y: 274.2)
        )
        path.addLine(to: CGPoint(x: 268.0, y: 593.2))
        path.addCurve(
            to: CGPoint(x: 245.0, y: 581.4),
            control1: CGPoint(x: 258.4, y: 602.0),
            control2: CGPoint(x: 243.2, y: 594.1)
        )
        path.addLine(to: CGPoint(x: 277.4, y: 360.0))
        path.addCurve(
            to: CGPoint(x: 264.8, y: 345.4),
            control1: CGPoint(x: 278.6, y: 352.3),
            control2: CGPoint(x: 272.6, y: 345.4)
        )
        path.addLine(to: CGPoint(x: 74.0, y: 345.4))
        path.addCurve(
            to: CGPoint(x: 64.0, y: 320.8),
            control1: CGPoint(x: 61.2, y: 345.4),
            control2: CGPoint(x: 54.8, y: 329.8)
        )
        path.closeSubpath()

        let scale = min(rect.width / Self.designSize.width, rect.height / Self.designSize.height)
        let scaled = CGSize(width: Self.designSize.width * scale, height: Self.designSize.height * scale)
        return path.applying(
            CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(
                    CGAffineTransform(
                        translationX: rect.midX - scaled.width / 2,
                        y: rect.midY - scaled.height / 2
                    )
                )
        )
    }

    /// The deep purple that reads on a light panel sinks into a dark one, so the
    /// stops lift to lavender under the dark appearance.
    public static let gradient = LinearGradient(
        colors: [
            adaptive(
                light: Color(red: 0.694, green: 0.549, blue: 1.0),
                dark: Color(red: 0.86, green: 0.78, blue: 1.0)
            ),
            adaptive(
                light: Color(red: 0.482, green: 0.247, blue: 0.894),
                dark: Color(red: 0.76, green: 0.64, blue: 1.0)
            ),
            adaptive(
                light: Color(red: 0.290, green: 0.114, blue: 0.651),
                dark: Color(red: 0.66, green: 0.50, blue: 1.0)
            ),
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    private static func adaptive(light: Color, dark: Color) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(isDark ? dark : light)
        })
    }

    /// Mirrors the `fill` in `AppIcon.icon`, so the About pane matches the Dock.
    public static let iconBackground = LinearGradient(
        colors: [
            Color(red: 0.18, green: 0.13, blue: 0.30),
            Color(red: 0.05, green: 0.03, blue: 0.09),
        ],
        startPoint: .top,
        endPoint: .bottom
    )

    /// A monochrome template image, which is what the menu bar expects so the
    /// glyph inverts correctly in light and dark menu bars.
    @MainActor
    public static func menuBarImage(height: CGFloat = 16) -> NSImage {
        let width = height * (designSize.width / designSize.height)
        let size = NSSize(width: width, height: height)
        let image = NSImage(size: size, flipped: true) { rect in
            NSColor.black.setFill()
            NSBezierPath(cgPath: OmaboxBolt().path(in: rect).cgPath).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}

/// The app icon rendered in-app, for the About pane.
public struct OmaboxAppIcon: View {
    var size: CGFloat = 52

    public init(size: CGFloat = 52) { self.size = size }

    public var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .fill(OmaboxBolt.iconBackground)
            OmaboxBolt()
                .fill(
                    LinearGradient(
                        colors: [.white, Color(white: 0.82)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: .black.opacity(0.35), radius: size * 0.03, y: size * 0.015)
                .padding(size * 0.19)
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        }
    }
}
