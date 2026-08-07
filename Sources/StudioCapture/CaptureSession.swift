import Foundation

public protocol CaptureSession: Sendable {
    var events: AsyncStream<CaptureEvent> { get }

    func prepare(configuration: CaptureConfiguration) async throws -> CaptureCapabilities
    func start() async throws
    func mark(_ label: String?) async
    func stop() async throws -> CaptureArtifact
    func cancel() async
}

public actor CaptureStateMachine {
    public private(set) var state: CaptureState = .idle

    public init() {}

    @discardableResult
    public func transition(to next: CaptureState) throws -> CaptureState {
        guard Self.allowed[state, default: []].contains(next) else {
            throw CaptureError.invalidTransition(from: state, to: next)
        }
        state = next
        return state
    }

    private static let allowed: [CaptureState: Set<CaptureState>] = [
        .idle: [.preparing, .canceled],
        .preparing: [.ready, .failed, .canceled],
        .ready: [.recording, .failed, .canceled],
        .recording: [.stopping, .storageConstrained, .recovered, .failed, .canceled],
        .stopping: [.finalized, .storageConstrained, .recovered, .failed],
        .finalized: [.importing],
        .importing: [.finalized, .failed],
        .recovered: [.importing, .failed],
        .storageConstrained: [.importing, .recovered, .failed],
        .failed: [],
        .canceled: [],
    ]
}

public struct PlatformCapturePolicy: Sendable {
    public init() {}

    public func baselineCapabilities() -> CaptureCapabilities {
        #if os(iOS)
            CaptureCapabilities(
                supportedSources: [.screen, .appAudio, .microphone],
                supportsBackgroundCapture: true,
                supportsPause: false,
                caveats: [
                    "Cross-app interaction coordinates are not available.",
                    "Camera availability during system broadcast is mode dependent.",
                ]
            )
        #elseif os(macOS)
            CaptureCapabilities(
                supportedSources: [.screen, .appAudio, .microphone, .camera, .interactionEvents],
                supportsBackgroundCapture: true,
                supportsPause: false,
                caveats: [
                    "Editable pointer and keyboard events require additional user-granted permissions."
                ]
            )
        #else
            CaptureCapabilities(
                supportedSources: [],
                supportsBackgroundCapture: false,
                supportsPause: false,
                caveats: ["Screen capture adapter is unavailable on this platform."]
            )
        #endif
    }
}
