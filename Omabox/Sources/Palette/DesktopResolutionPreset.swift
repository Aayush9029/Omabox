import CasePaths
import Foundation

@CasePathable
nonisolated enum DesktopResolutionPreset: String, CaseIterable, Identifiable, Sendable {
    case fitToScreen = "fit"
    case size512x320 = "512x320"
    case size960x600 = "960x600"
    case size1280x800 = "1280x800"
    case size1440x900 = "1440x900"
    case size1920x1200 = "1920x1200"

    var id: Self { self }

    var sizeInPixels: CGSize? {
        switch self {
        case .fitToScreen: nil
        case .size512x320: CGSize(width: 512, height: 320)
        case .size960x600: CGSize(width: 960, height: 600)
        case .size1280x800: CGSize(width: 1280, height: 800)
        case .size1440x900: CGSize(width: 1440, height: 900)
        case .size1920x1200: CGSize(width: 1920, height: 1200)
        }
    }

    var title: String {
        guard let sizeInPixels else { return "Fit to screen" }
        return "\(Int(sizeInPixels.width)) × \(Int(sizeInPixels.height))"
    }

    var subtitle: String {
        guard let sizeInPixels else { return "Automatic resolution" }
        return "\(Int(sizeInPixels.height))p · 16:10"
    }

    func matches(_ size: CGSize?) -> Bool {
        guard let size, let sizeInPixels else { return false }
        return sizeInPixels == size
    }
}
