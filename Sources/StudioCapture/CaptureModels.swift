import Foundation
import StudioDomain

public enum CaptureSource: String, Codable, CaseIterable, Sendable {
    case screen
    case appAudio
    case microphone
    case camera
    case interactionEvents
}

public struct CaptureCapabilities: Hashable, Codable, Sendable {
    public var supportedSources: Set<CaptureSource>
    public var supportsBackgroundCapture: Bool
    public var supportsPause: Bool
    public var caveats: [String]

    public init(
        supportedSources: Set<CaptureSource>,
        supportsBackgroundCapture: Bool,
        supportsPause: Bool,
        caveats: [String] = []
    ) {
        self.supportedSources = supportedSources
        self.supportsBackgroundCapture = supportsBackgroundCapture
        self.supportsPause = supportsPause
        self.caveats = caveats
    }
}

public struct CaptureConfiguration: Hashable, Codable, Sendable {
    public var requestedSources: Set<CaptureSource>
    public var preferredCanvas: CanvasSpec
    public var preferredFramesPerSecond: Int

    public init(
        requestedSources: Set<CaptureSource>,
        preferredCanvas: CanvasSpec = .landscape1080,
        preferredFramesPerSecond: Int = 30
    ) {
        self.requestedSources = requestedSources
        self.preferredCanvas = preferredCanvas
        self.preferredFramesPerSecond = preferredFramesPerSecond
    }
}

public enum CaptureState: String, Codable, Sendable {
    case idle
    case preparing
    case ready
    case recording
    case stopping
    case finalized
    case importing
    case recovered
    case storageConstrained
    case failed
    case canceled
}

public enum CaptureEvent: Hashable, Codable, Sendable {
    case stateChanged(CaptureState)
    case marker(time: StudioTime, label: String?)
    case warning(code: String, message: String)
    case progress(duration: StudioTime, bytesWritten: Int64)
}

public struct CaptureFile: Hashable, Codable, Sendable {
    public var source: CaptureSource
    public var relativePath: String
    public var contentHash: String?
    public var start: StudioTime

    public init(
        source: CaptureSource,
        relativePath: String,
        contentHash: String? = nil,
        start: StudioTime = .zero
    ) {
        self.source = source
        self.relativePath = relativePath
        self.contentHash = contentHash
        self.start = start
    }
}

public struct CaptureArtifact: Hashable, Codable, Sendable {
    public var sessionID: UUID
    public var duration: StudioTime
    public var capabilities: CaptureCapabilities
    public var files: [CaptureFile]
    public var eventsRelativePath: String?

    public init(
        sessionID: UUID = UUID(),
        duration: StudioTime,
        capabilities: CaptureCapabilities,
        files: [CaptureFile],
        eventsRelativePath: String? = nil
    ) {
        self.sessionID = sessionID
        self.duration = duration
        self.capabilities = capabilities
        self.files = files
        self.eventsRelativePath = eventsRelativePath
    }
}

public enum CaptureError: Error, Equatable, Sendable {
    case invalidTransition(from: CaptureState, to: CaptureState)
    case unsupportedSources(Set<CaptureSource>)
    case permissionDenied(String)
    case sourceUnavailable(String)
    case insufficientStorage
    case interrupted(String)
    case finalizationFailed(String)
}

public enum CaptureThermalState: String, Codable, Sendable {
    case nominal
    case fair
    case serious
    case critical
}

public enum CapturePreflightStatus: String, Codable, Sendable {
    case ready
    case storageConstrained
    case failed
}

public struct CapturePreflightInput: Hashable, Codable, Sendable {
    public var capabilities: CaptureCapabilities
    public var requestedSources: Set<CaptureSource>
    public var appGroupAvailable: Bool
    public var availableStorageBytes: Int64
    public var thermalState: CaptureThermalState
    public var microphonePermissionDenied: Bool

    public init(
        capabilities: CaptureCapabilities,
        requestedSources: Set<CaptureSource>,
        appGroupAvailable: Bool,
        availableStorageBytes: Int64,
        thermalState: CaptureThermalState,
        microphonePermissionDenied: Bool = false
    ) {
        self.capabilities = capabilities
        self.requestedSources = requestedSources
        self.appGroupAvailable = appGroupAvailable
        self.availableStorageBytes = availableStorageBytes
        self.thermalState = thermalState
        self.microphonePermissionDenied = microphonePermissionDenied
    }
}

/// Blockers are structured so callers can branch on the cause. Matching on
/// user-facing prose means an editorial change silently flips a preflight check.
public enum CapturePreflightBlocker: Hashable, Codable, Sendable {
    case unsupportedSources(Set<CaptureSource>)
    case appGroupUnavailable
    case microphonePermissionDenied
    case thermalCritical

    public var message: String {
        switch self {
        case .unsupportedSources:
            "One or more requested capture sources are unavailable on this device."
        case .appGroupUnavailable:
            "The shared capture container is unavailable. Verify the App Group entitlement."
        case .microphonePermissionDenied:
            "Microphone access is denied. Enable it in Settings or record without microphone audio."
        case .thermalCritical:
            "The device is too hot to start a reliable recording."
        }
    }
}

public struct CapturePreflightReport: Hashable, Codable, Sendable {
    public var status: CapturePreflightStatus
    public var availableStorageBytes: Int64
    public var estimatedMinutesRemaining: Int
    public var blockers: [CapturePreflightBlocker]
    public var warnings: [String]

    public init(
        status: CapturePreflightStatus,
        availableStorageBytes: Int64,
        estimatedMinutesRemaining: Int,
        blockers: [CapturePreflightBlocker],
        warnings: [String]
    ) {
        self.status = status
        self.availableStorageBytes = availableStorageBytes
        self.estimatedMinutesRemaining = estimatedMinutesRemaining
        self.blockers = blockers
        self.warnings = warnings
    }
}

public struct CapturePreflightEvaluator: Sendable {
    public var minimumReserveBytes: Int64
    public var estimatedBytesPerMinute: Int64

    public init(
        minimumReserveBytes: Int64 = 1_000_000_000,
        estimatedBytesPerMinute: Int64 = 90_000_000
    ) {
        self.minimumReserveBytes = minimumReserveBytes
        self.estimatedBytesPerMinute = estimatedBytesPerMinute
    }

    public func evaluate(_ input: CapturePreflightInput) -> CapturePreflightReport {
        var blockers: [CapturePreflightBlocker] = []
        var warnings = input.capabilities.caveats
        let unsupported = input.requestedSources.subtracting(input.capabilities.supportedSources)

        if !unsupported.isEmpty {
            blockers.append(.unsupportedSources(unsupported))
        }
        if !input.appGroupAvailable {
            blockers.append(.appGroupUnavailable)
        }
        if input.microphonePermissionDenied, input.requestedSources.contains(.microphone) {
            blockers.append(.microphonePermissionDenied)
        }
        if input.thermalState == .critical {
            blockers.append(.thermalCritical)
        } else if input.thermalState == .serious {
            warnings.append("The device is warm. Long recordings may stop early.")
        }

        let usableBytes = max(0, input.availableStorageBytes - minimumReserveBytes)
        let minutes = estimatedBytesPerMinute > 0 ? Int(usableBytes / estimatedBytesPerMinute) : 0
        let status: CapturePreflightStatus
        if !blockers.isEmpty {
            status = .failed
        } else if input.availableStorageBytes < minimumReserveBytes {
            status = .storageConstrained
            warnings.append("Free storage is below the protected capture reserve.")
        } else {
            status = .ready
            if minutes < 10 {
                warnings.append("Estimated recording time is under ten minutes at the current storage level.")
            }
        }

        return CapturePreflightReport(
            status: status,
            availableStorageBytes: input.availableStorageBytes,
            estimatedMinutesRemaining: minutes,
            blockers: blockers,
            warnings: warnings
        )
    }
}
