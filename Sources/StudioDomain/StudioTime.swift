import Foundation

public struct StudioTime: Hashable, Codable, Sendable, Comparable, AdditiveArithmetic {
    public static let zero = StudioTime(microseconds: 0)

    public let microseconds: Int64

    public init(microseconds: Int64) {
        self.microseconds = microseconds
    }

    public init(seconds: Double) {
        self.microseconds = Int64((seconds * 1_000_000).rounded())
    }

    public var seconds: Double { Double(microseconds) / 1_000_000 }

    public static func < (lhs: StudioTime, rhs: StudioTime) -> Bool {
        lhs.microseconds < rhs.microseconds
    }

    public static func + (lhs: StudioTime, rhs: StudioTime) -> StudioTime {
        StudioTime(microseconds: lhs.microseconds + rhs.microseconds)
    }

    public static func - (lhs: StudioTime, rhs: StudioTime) -> StudioTime {
        StudioTime(microseconds: lhs.microseconds - rhs.microseconds)
    }
}

public struct StudioTimeRange: Hashable, Codable, Sendable {
    public let start: StudioTime
    public let duration: StudioTime

    public init(start: StudioTime, duration: StudioTime) {
        self.start = start
        self.duration = duration
    }

    public var end: StudioTime { start + duration }
    public var isValid: Bool { start >= .zero && duration > .zero }

    public func contains(_ time: StudioTime) -> Bool {
        time >= start && time < end
    }

    public func overlaps(_ other: StudioTimeRange) -> Bool {
        start < other.end && other.start < end
    }
}
