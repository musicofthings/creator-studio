import Foundation

public struct TaggedID<Tag>: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue.uuidString.lowercased() }
}

public enum ProjectTag: Sendable {}
public enum AssetTag: Sendable {}
public enum TimelineTag: Sendable {}
public enum TrackTag: Sendable {}
public enum ClipTag: Sendable {}
public enum FocusTag: Sendable {}
public enum CaptionTag: Sendable {}
public enum SuggestionTag: Sendable {}
public enum JobTag: Sendable {}

public typealias ProjectID = TaggedID<ProjectTag>
public typealias AssetID = TaggedID<AssetTag>
public typealias TimelineID = TaggedID<TimelineTag>
public typealias TrackID = TaggedID<TrackTag>
public typealias ClipID = TaggedID<ClipTag>
public typealias FocusID = TaggedID<FocusTag>
public typealias CaptionID = TaggedID<CaptionTag>
public typealias SuggestionID = TaggedID<SuggestionTag>
public typealias JobID = TaggedID<JobTag>
