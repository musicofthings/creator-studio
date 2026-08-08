import Foundation

public enum ProjectIntent: String, CaseIterable, Codable, Sendable {
    case tutorial
    case social
    case podcast
    case camera
    case audio
    case importOnly
}

public enum MediaKind: String, Codable, Sendable {
    case screenVideo
    case cameraVideo
    case appAudio
    case microphoneAudio
    case music
    case image
    case overlay
}

public struct PixelSize: Hashable, Codable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

public struct SourceAsset: Hashable, Codable, Sendable {
    public var id: AssetID
    public var kind: MediaKind
    public var relativePath: String
    public var originalFilename: String?
    public var byteCount: Int64?
    public var contentHash: String?
    public var duration: StudioTime
    public var pixelSize: PixelSize?
    public var createdAt: Date
    public var captureSessionID: UUID?
    public var captureStart: StudioTime?

    public init(
        id: AssetID = AssetID(),
        kind: MediaKind,
        relativePath: String,
        originalFilename: String? = nil,
        byteCount: Int64? = nil,
        contentHash: String? = nil,
        duration: StudioTime,
        pixelSize: PixelSize? = nil,
        createdAt: Date = .studioNow(),
        captureSessionID: UUID? = nil,
        captureStart: StudioTime? = nil
    ) {
        self.id = id
        self.kind = kind
        self.relativePath = relativePath
        self.originalFilename = originalFilename
        self.byteCount = byteCount
        self.contentHash = contentHash
        self.duration = duration
        self.pixelSize = pixelSize
        self.createdAt = createdAt
        self.captureSessionID = captureSessionID
        self.captureStart = captureStart
    }
}

public struct StudioProject: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var minimumReaderVersion: Int
    public var id: ProjectID
    public var timelineID: TimelineID
    public var title: String
    public var intent: ProjectIntent
    public var defaultCanvas: CanvasSpec
    public var assets: [SourceAsset]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: ProjectID = ProjectID(),
        timelineID: TimelineID = TimelineID(),
        title: String,
        intent: ProjectIntent,
        defaultCanvas: CanvasSpec = .landscape1080,
        assets: [SourceAsset] = [],
        createdAt: Date = .studioNow(),
        updatedAt: Date = .studioNow()
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.minimumReaderVersion = 1
        self.id = id
        self.timelineID = timelineID
        self.title = title
        self.intent = intent
        self.defaultCanvas = defaultCanvas
        self.assets = assets
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

public struct ProjectSummary: Hashable, Codable, Sendable, Identifiable {
    public var id: ProjectID
    public var title: String
    public var intent: ProjectIntent
    public var updatedAt: Date
    public var assetCount: Int

    public init(project: StudioProject) {
        self.id = project.id
        self.title = project.title
        self.intent = project.intent
        self.updatedAt = project.updatedAt
        self.assetCount = project.assets.count
    }
}
