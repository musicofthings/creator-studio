import Foundation
import StudioDomain
import StudioMediaPipeline

public enum VideoCodec: String, Codable, CaseIterable, Sendable {
    case h264
    case hevc
    case proRes
}

public enum AudioCodec: String, Codable, CaseIterable, Sendable {
    case aac
    case pcm
}

public enum CaptionMode: String, Codable, CaseIterable, Sendable {
    case none
    case burnedIn
    case sidecar
    case burnedInAndSidecar
}

public struct ExportProfile: Hashable, Codable, Sendable, Identifiable {
    public var id: String
    public var displayName: String
    public var canvas: CanvasSpec
    public var framesPerSecond: Int
    public var videoCodec: VideoCodec?
    public var audioCodec: AudioCodec
    public var captionMode: CaptionMode

    public init(
        id: String,
        displayName: String,
        canvas: CanvasSpec,
        framesPerSecond: Int = 30,
        videoCodec: VideoCodec? = .h264,
        audioCodec: AudioCodec = .aac,
        captionMode: CaptionMode = .burnedInAndSidecar
    ) {
        self.id = id
        self.displayName = displayName
        self.canvas = canvas
        self.framesPerSecond = framesPerSecond
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.captionMode = captionMode
    }

    public static let landscapeTutorial = ExportProfile(
        id: "landscape-tutorial-1080p",
        displayName: "Landscape Tutorial",
        canvas: .landscape1080
    )

    public static let verticalShort = ExportProfile(
        id: "vertical-short-1080p",
        displayName: "Vertical Short",
        canvas: .vertical1080
    )

    public static let squareFeed = ExportProfile(
        id: "square-feed-1080p",
        displayName: "Square Feed",
        canvas: .square1080
    )

    public static let audioEpisode = ExportProfile(
        id: "audio-episode-aac",
        displayName: "Audio Episode",
        canvas: .landscape1080,
        videoCodec: nil,
        audioCodec: .aac,
        captionMode: .sidecar
    )
}

public enum RenderEvent: Hashable, Sendable {
    case started
    case progress(Double)
    case validating
    case completed(URL)
}

public protocol RenderService: Sendable {
    func render(
        _ plan: RenderPlan,
        profile: ExportProfile,
        to outputURL: URL
    ) -> AsyncThrowingStream<RenderEvent, Error>
}

public enum ExportValidationError: Error, Equatable, Sendable {
    case invalidDimensions
    case invalidFrameRate
    case emptyTimeline
}

public struct ExportPreflight: Sendable {
    public init() {}

    public func validate(plan: RenderPlan, profile: ExportProfile) throws {
        guard profile.canvas.width > 0, profile.canvas.height > 0 else {
            throw ExportValidationError.invalidDimensions
        }
        guard (1 ... 120).contains(profile.framesPerSecond) else {
            throw ExportValidationError.invalidFrameRate
        }
        guard plan.duration > .zero else {
            throw ExportValidationError.emptyTimeline
        }
    }
}
