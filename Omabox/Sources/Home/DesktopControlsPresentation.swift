import Observation

@MainActor
@Observable
final class DesktopControlsPresentation {
    private(set) var isVisible = true
    private(set) var presentationID = 0

    @ObservationIgnored private let clock = ContinuousClock()
    @ObservationIgnored private var hideDeadline = ContinuousClock.now.advanced(by: .seconds(5))
    @ObservationIgnored private var isPersistent = false

    func reveal() {
        hideDeadline = clock.now.advanced(by: .seconds(5))
        guard !isVisible else { return }
        isVisible = true
        presentationID += 1
    }

    func setPersistent(_ persistent: Bool) {
        guard isPersistent != persistent else { return }
        isPersistent = persistent
        reveal()
        presentationID += 1
    }

    func hideAfterInactivity() async {
        guard !isPersistent else { return }
        while !Task.isCancelled {
            do {
                try await clock.sleep(until: hideDeadline)
            } catch {
                return
            }
            guard !Task.isCancelled, !isPersistent else { return }
            if clock.now >= hideDeadline {
                isVisible = false
                return
            }
        }
    }
}
