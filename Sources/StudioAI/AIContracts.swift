import Foundation
import StudioDomain

public struct TranscriptWord: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID
    public var text: String
    public var timeRange: StudioTimeRange
    public var confidence: Double?
    public var speaker: String?

    public init(
        id: UUID = UUID(),
        text: String,
        timeRange: StudioTimeRange,
        confidence: Double? = nil,
        speaker: String? = nil
    ) {
        self.id = id
        self.text = text
        self.timeRange = timeRange
        self.confidence = confidence
        self.speaker = speaker
    }
}

public struct TranscriptionRequest: Hashable, Codable, Sendable {
    public var assetID: AssetID
    public var localeIdentifier: String?
    public var requiresWordTimestamps: Bool
    public var requiresSpeakerLabels: Bool

    public init(
        assetID: AssetID,
        localeIdentifier: String? = nil,
        requiresWordTimestamps: Bool = true,
        requiresSpeakerLabels: Bool = false
    ) {
        self.assetID = assetID
        self.localeIdentifier = localeIdentifier
        self.requiresWordTimestamps = requiresWordTimestamps
        self.requiresSpeakerLabels = requiresSpeakerLabels
    }
}

public struct TranscriptResult: Hashable, Codable, Sendable {
    public var words: [TranscriptWord]
    public var localeIdentifier: String
    public var providerID: String
    public var providerVersion: String

    public init(
        words: [TranscriptWord],
        localeIdentifier: String,
        providerID: String,
        providerVersion: String
    ) {
        self.words = words
        self.localeIdentifier = localeIdentifier
        self.providerID = providerID
        self.providerVersion = providerVersion
    }
}

public protocol TranscriptService: Sendable {
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptResult
}

public enum FocusEvidence: String, Codable, Sendable {
    case exactInteraction
    case pixelChange
    case opticalPointer
    case recognizedRegion
    case spokenCue
    case manualSeed
}

public struct FocusCandidate: Hashable, Codable, Sendable {
    public var timeRange: StudioTimeRange
    public var region: NormalizedRect
    public var confidence: Double
    public var evidence: FocusEvidence
    public var reason: String

    public init(
        timeRange: StudioTimeRange,
        region: NormalizedRect,
        confidence: Double,
        evidence: FocusEvidence,
        reason: String
    ) {
        self.timeRange = timeRange
        self.region = region
        self.confidence = confidence
        self.evidence = evidence
        self.reason = reason
    }
}

public struct FocusAnalysisInput: Hashable, Codable, Sendable {
    public var duration: StudioTime
    public var candidates: [FocusCandidate]

    public init(duration: StudioTime, candidates: [FocusCandidate]) {
        self.duration = duration
        self.candidates = candidates
    }
}

public struct FocusSuggestion: Hashable, Codable, Sendable, Identifiable {
    public var id: SuggestionID
    public var timeRange: StudioTimeRange
    public var region: NormalizedRect
    public var strength: Double
    public var confidence: Double
    public var evidence: [FocusEvidence]
    public var reason: String

    public init(
        id: SuggestionID = SuggestionID(),
        timeRange: StudioTimeRange,
        region: NormalizedRect,
        strength: Double,
        confidence: Double,
        evidence: [FocusEvidence],
        reason: String
    ) {
        self.id = id
        self.timeRange = timeRange
        self.region = region
        self.strength = strength
        self.confidence = confidence
        self.evidence = evidence
        self.reason = reason
    }
}

public protocol FocusSuggestionService: Sendable {
    func suggestFocus(for input: FocusAnalysisInput) async throws -> [FocusSuggestion]
}

public enum ExternalDataClass: String, Codable, CaseIterable, Sendable {
    case transcript
    case audio
    case sampledFrames
    case fullMedia
    case projectMetadata
}

public struct ConsentReceipt: Hashable, Codable, Sendable {
    public var id: UUID
    public var purpose: String
    public var dataClasses: Set<ExternalDataClass>
    public var policyVersion: String
    public var grantedAt: Date

    public init(
        id: UUID = UUID(),
        purpose: String,
        dataClasses: Set<ExternalDataClass>,
        policyVersion: String,
        grantedAt: Date = Date()
    ) {
        self.id = id
        self.purpose = purpose
        self.dataClasses = dataClasses
        self.policyVersion = policyVersion
        self.grantedAt = grantedAt
    }
}
