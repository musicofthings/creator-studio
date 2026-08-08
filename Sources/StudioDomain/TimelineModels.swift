import Foundation

public enum TrackKind: String, Codable, Sendable {
    case screen
    case camera
    case microphone
    case appAudio
    case music
    case overlay
    case annotation
    case captions
}

public struct ClipTransform: Hashable, Codable, Sendable {
    public var frame: NormalizedRect
    public var rotationDegrees: Double
    public var opacity: Double

    public init(
        frame: NormalizedRect = .fullFrame,
        rotationDegrees: Double = 0,
        opacity: Double = 1
    ) {
        self.frame = frame
        self.rotationDegrees = rotationDegrees
        self.opacity = opacity
    }
}

public struct TimelineClip: Hashable, Codable, Sendable, Identifiable {
    public var id: ClipID
    public var assetID: AssetID
    public var sourceRange: StudioTimeRange
    public var timelineStart: StudioTime
    public var playbackRate: Double
    public var transform: ClipTransform
    public var gainDB: Double
    public var isEnabled: Bool

    public init(
        id: ClipID = ClipID(),
        assetID: AssetID,
        sourceRange: StudioTimeRange,
        timelineStart: StudioTime,
        playbackRate: Double = 1,
        transform: ClipTransform = ClipTransform(),
        gainDB: Double = 0,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.assetID = assetID
        self.sourceRange = sourceRange
        self.timelineStart = timelineStart
        self.playbackRate = playbackRate
        self.transform = transform
        self.gainDB = gainDB
        self.isEnabled = isEnabled
    }

    public var timelineDuration: StudioTime {
        guard playbackRate.isFinite, playbackRate > 0 else { return .zero }
        let seconds = sourceRange.duration.seconds / playbackRate
        guard seconds.isFinite,
              seconds > 0,
              seconds <= Double(Int64.max) / 1_000_000
        else { return .zero }
        return StudioTime(seconds: seconds)
    }

    public var timelineRange: StudioTimeRange {
        StudioTimeRange(start: timelineStart, duration: timelineDuration)
    }
}

public struct TimelineTrack: Hashable, Codable, Sendable, Identifiable {
    public var id: TrackID
    public var kind: TrackKind
    public var order: Int
    public var isMuted: Bool
    public var isLocked: Bool
    public var clips: [TimelineClip]

    public init(
        id: TrackID = TrackID(),
        kind: TrackKind,
        order: Int,
        isMuted: Bool = false,
        isLocked: Bool = false,
        clips: [TimelineClip] = []
    ) {
        self.id = id
        self.kind = kind
        self.order = order
        self.isMuted = isMuted
        self.isLocked = isLocked
        self.clips = clips
    }
}

public enum FocusSource: String, Codable, Sendable {
    case manual
    case interactionEvent
    case pixelChange
    case opticalPointer
    case transcript
    case acceptedSuggestion
}

public struct FocusEvent: Hashable, Codable, Sendable, Identifiable {
    public var id: FocusID
    public var timeRange: StudioTimeRange
    public var region: NormalizedRect
    public var strength: Double
    public var source: FocusSource
    public var confidence: Double

    public init(
        id: FocusID = FocusID(),
        timeRange: StudioTimeRange,
        region: NormalizedRect,
        strength: Double,
        source: FocusSource,
        confidence: Double
    ) {
        self.id = id
        self.timeRange = timeRange
        self.region = region
        self.strength = strength
        self.source = source
        self.confidence = confidence
    }
}

public struct CaptionCue: Hashable, Codable, Sendable, Identifiable {
    public var id: CaptionID
    public var timeRange: StudioTimeRange
    public var text: String
    public var speaker: String?
    public var localeIdentifier: String?

    public init(
        id: CaptionID = CaptionID(),
        timeRange: StudioTimeRange,
        text: String,
        speaker: String? = nil,
        localeIdentifier: String? = nil
    ) {
        self.id = id
        self.timeRange = timeRange
        self.text = text
        self.speaker = speaker
        self.localeIdentifier = localeIdentifier
    }
}

public struct TimelineDocument: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var id: TimelineID
    public var projectID: ProjectID
    public var revision: Int
    public var tracks: [TimelineTrack]
    public var focusEvents: [FocusEvent]
    public var captions: [CaptionCue]

    public init(
        id: TimelineID,
        projectID: ProjectID,
        revision: Int = 0,
        tracks: [TimelineTrack] = [],
        focusEvents: [FocusEvent] = [],
        captions: [CaptionCue] = []
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.id = id
        self.projectID = projectID
        self.revision = revision
        self.tracks = tracks
        self.focusEvents = focusEvents
        self.captions = captions
    }
}
