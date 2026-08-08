import Foundation
import StudioDomain

public struct ProjectWorkspace: Hashable, Sendable {
    public var project: StudioProject
    public var timeline: TimelineDocument
    public var editHistory: TimelineEditHistory

    public init(
        project: StudioProject,
        timeline: TimelineDocument,
        editHistory: TimelineEditHistory? = nil
    ) {
        self.project = project
        self.timeline = timeline
        self.editHistory = editHistory ?? TimelineEditHistory(timeline: timeline)
    }
}

public struct MediaImportDescriptor: Hashable, Sendable {
    public var kind: MediaKind
    public var duration: StudioTime
    public var pixelSize: PixelSize?
    public var mediaMetadata: SourceMediaMetadata?
    public var originalFilename: String?

    public init(
        kind: MediaKind,
        duration: StudioTime,
        pixelSize: PixelSize? = nil,
        mediaMetadata: SourceMediaMetadata? = nil,
        originalFilename: String? = nil
    ) {
        self.kind = kind
        self.duration = duration
        self.pixelSize = pixelSize
        self.mediaMetadata = mediaMetadata
        self.originalFilename = originalFilename
    }
}

public struct ProjectMediaImportResult: Hashable, Sendable {
    public var workspace: ProjectWorkspace
    public var importedAsset: SourceAsset
    public var appendedClip: TimelineClip

    public init(
        workspace: ProjectWorkspace,
        importedAsset: SourceAsset,
        appendedClip: TimelineClip
    ) {
        self.workspace = workspace
        self.importedAsset = importedAsset
        self.appendedClip = appendedClip
    }
}

/// Result of appending another local Creator Studio project to the current
/// project's master timeline. Source bytes are copied into the destination;
/// the source project remains unchanged and independently editable.
public struct ProjectRecordingMergeResult: Hashable, Sendable {
    public var workspace: ProjectWorkspace
    public var importedAssets: [SourceAsset]
    public var sourceProjectID: ProjectID

    public init(
        workspace: ProjectWorkspace,
        importedAssets: [SourceAsset],
        sourceProjectID: ProjectID
    ) {
        self.workspace = workspace
        self.importedAssets = importedAssets
        self.sourceProjectID = sourceProjectID
    }
}

public struct ProjectAssetIngestLocation: Hashable, Sendable {
    public var sourceURL: URL
    public var cacheDirectoryURL: URL

    public init(sourceURL: URL, cacheDirectoryURL: URL) {
        self.sourceURL = sourceURL
        self.cacheDirectoryURL = cacheDirectoryURL
    }
}

public enum ProjectMediaImportError: Error, Equatable, Sendable {
    case sourceUnavailable
    case unsupportedFileType(String)
    case invalidDuration
    case invalidPixelSize
    case fileTooLarge
    case copyFailed(String)
}

extension ProjectMediaImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .sourceUnavailable:
            "The selected media file is unavailable or is not a regular file."
        case .unsupportedFileType:
            "This media file type is not supported yet."
        case .invalidDuration:
            "The selected media has no usable duration."
        case .invalidPixelSize:
            "The selected video has invalid dimensions."
        case .fileTooLarge:
            "The selected media exceeds the current project import limit."
        case .copyFailed:
            "Creator Studio could not copy the media into the project safely."
        }
    }
}
