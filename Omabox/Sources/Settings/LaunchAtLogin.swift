import Observation
import ServiceManagement

@MainActor
@Observable
public final class LaunchAtLogin {
    public private(set) var isEnabled = false
    public private(set) var failureMessage: String?

    public init() {
        refresh()
    }

    public func refresh() {
        guard !AppEnvironment.isUITesting else { return }
        isEnabled = SMAppService.mainApp.status == .enabled
    }

    public func set(_ enabled: Bool) {
        if AppEnvironment.isUITesting {
            isEnabled = enabled
            failureMessage = nil
            return
        }
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            failureMessage = nil
        } catch {
            failureMessage = error.localizedDescription
        }
        refresh()
    }
}
