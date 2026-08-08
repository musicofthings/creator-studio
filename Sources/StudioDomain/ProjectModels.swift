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

/// Portable representation of a media track transform. Core Graphics remains
/// an adapter concern, while the project keeps enough information to reproduce
/// source orientation without rewriting the immutable file.
public struct SourceAffineTransform: Hashable, Codable, Sendable {
    public var a: Double
    public var b: Double
    public var c: Double
    public var d: Double
    public var tx: Double
    public var ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    public static let identity = SourceAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public var isFinite: Bool {
        a.isFinite && b.isFinite && c.isFinite && d.isFinite && tx.isFinite && ty.isFinite
    }
}

public struct SourceAudioFormat: Hashable, Codable, Sendable {
    public var sampleRate: Double
    public var channelCount: Int

    public init(sampleRate: Double, channelCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

/// Authoritative inspection metadata uses presentation timestamps rather than
/// frame numbers. That keeps variable-frame-rate media mapped to elapsed time
/// and lets proxy/cache products be deleted and rebuilt without semantic loss.
public struct SourceMediaMetadata: Hashable, Codable, Sendable {
    public var naturalPixelSize: PixelSize?
    public var preferredTransform: SourceAffineTransform
    public var sourceStart: StudioTime
    public var sourceDuration: StudioTime
    public var nominalFrameRate: Double?
    public var estimatedFrameRate: Double?
    public var isVariableFrameRate: Bool
    public var audioFormat: SourceAudioFormat?

    public init(
        naturalPixelSize: PixelSize? = nil,
        preferredTransform: SourceAffineTransform = .identity,
        sourceStart: StudioTime = .zero,
        sourceDuration: StudioTime,
        nominalFrameRate: Double? = nil,
        estimatedFrameRate: Double? = nil,
        isVariableFrameRate: Bool = false,
        audioFormat: SourceAudioFormat? = nil
    ) {
        self.naturalPixelSize = naturalPixelSize
        self.preferredTransform = preferredTransform
        self.sourceStart = sourceStart
        self.sourceDuration = sourceDuration
        self.nominalFrameRate = nominalFrameRate
        self.estimatedFrameRate = estimatedFrameRate
        self.isVariableFrameRate = isVariableFrameRate
        self.audioFormat = audioFormat
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
    public var mediaMetadata: SourceMediaMetadata?
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
        mediaMetadata: SourceMediaMetadata? = nil,
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
        self.mediaMetadata = mediaMetadata
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
