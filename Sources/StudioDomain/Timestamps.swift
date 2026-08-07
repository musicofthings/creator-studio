import Foundation

public extension Date {
    /// Project packages and capture manifests both serialize timestamps as
    /// whole-second ISO-8601. Minting them at that precision keeps
    /// `load(save(x)) == x` instead of leaving a sub-second remainder that only
    /// exists in memory.
    static func studioNow() -> Date {
        Date().truncatedToSeconds()
    }

    func truncatedToSeconds() -> Date {
        Date(timeIntervalSinceReferenceDate: timeIntervalSinceReferenceDate.rounded(.down))
    }
}
