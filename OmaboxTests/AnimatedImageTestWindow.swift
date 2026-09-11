import AppKit

@MainActor
final class AnimatedImageTestWindow: NSWindow {
    var reportsVisible = false
    var reportsMiniaturized = false
    var reportsOccluded = true

    override var isVisible: Bool { reportsVisible }
    override var isMiniaturized: Bool { reportsMiniaturized }
    override var occlusionState: NSWindow.OcclusionState {
        reportsOccluded ? [] : .visible
    }
}
