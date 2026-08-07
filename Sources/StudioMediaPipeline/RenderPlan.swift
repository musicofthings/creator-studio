import Foundation
import StudioDomain

public struct RenderLayer: Hashable, Codable, Sendable, Identifiable {
    public var id: ClipID
    public var trackID: TrackID
    public var trackKind: TrackKind
    public var asset: SourceAsset
    public var sourceRange: StudioTimeRange
    public var timelineRange: StudioTimeRange
    public var playbackRate: Double
    public var transform: ClipTransform
    public var gainDB: Double

    public init(
        id: ClipID,
        trackID: TrackID,
        trackKind: TrackKind,
        asset: SourceAsset,
        sourceRange: StudioTimeRange,
        timelineRange: StudioTimeRange,
        playbackRate: Double,
        transform: ClipTransform,
        gainDB: Double
    ) {
        self.id = id
        self.trackID = trackID
        self.trackKind = trackKind
        self.asset = asset
        self.sourceRange = sourceRange
        self.timelineRange = timelineRange
        self.playbackRate = playbackRate
        self.transform = transform
        self.gainDB = gainDB
    }
}

public struct FocusInstruction: Hashable, Codable, Sendable, Identifiable {
    public var id: FocusID
    public var timeRange: StudioTimeRange
    public var region: NormalizedRect
    public var strength: Double

    public init(id: FocusID, timeRange: StudioTimeRange, region: NormalizedRect, strength: Double) {
        self.id = id
        self.timeRange = timeRange
        self.region = region
        self.strength = strength
    }
}

public struct RenderPlan: Hashable, Codable, Sendable {
    public var projectID: ProjectID
    public var timelineID: TimelineID
    public var revision: Int
    public var canvas: CanvasSpec
    public var duration: StudioTime
    public var layers: [RenderLayer]
    public var focus: [FocusInstruction]
    public var captions: [CaptionCue]

    public init(
        projectID: ProjectID,
        timelineID: TimelineID,
        revision: Int,
        canvas: CanvasSpec,
        duration: StudioTime,
        layers: [RenderLayer],
        focus: [FocusInstruction],
        captions: [CaptionCue]
    ) {
        self.projectID = projectID
        self.timelineID = timelineID
        self.revision = revision
        self.canvas = canvas
        self.duration = duration
        self.layers = layers
        self.focus = focus
        self.captions = captions
    }
}
