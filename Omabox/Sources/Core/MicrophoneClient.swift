import AVFoundation
import Dependencies

nonisolated struct MicrophoneClient: Sendable {
    var isAuthorized: @Sendable () -> Bool
    var requestAccess: @Sendable () async -> Bool
}

extension MicrophoneClient: DependencyKey {
    static var liveValue: Self {
        guard !AppEnvironment.isUITesting else { return testValue }
        return Self(
            isAuthorized: { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized },
            requestAccess: { await AVCaptureDevice.requestAccess(for: .audio) }
        )
    }

    static var testValue: Self {
        Self(isAuthorized: { false }, requestAccess: { false })
    }
}

extension DependencyValues {
    var microphoneClient: MicrophoneClient {
        get { self[MicrophoneClient.self] }
        set { self[MicrophoneClient.self] = newValue }
    }
}
