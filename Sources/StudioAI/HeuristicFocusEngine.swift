import Foundation
import StudioDomain

public struct FocusComfortPolicy: Hashable, Codable, Sendable {
    public var minimumConfidence: Double
    public var minimumDwell: StudioTime
    public var mergeGap: StudioTime
    public var minimumRegionSide: Double
    public var maximumStrength: Double
    public var maximumCenterDistance: Double
    public var maximumMergedSide: Double

    public init(
        minimumConfidence: Double = 0.72,
        minimumDwell: StudioTime = StudioTime(seconds: 1.2),
        mergeGap: StudioTime = StudioTime(seconds: 0.35),
        minimumRegionSide: Double = 0.18,
        maximumStrength: Double = 0.85,
        maximumCenterDistance: Double = 0.22,
        maximumMergedSide: Double = 0.6
    ) {
        self.minimumConfidence = minimumConfidence
        self.minimumDwell = minimumDwell
        self.mergeGap = mergeGap
        self.minimumRegionSide = minimumRegionSide
        self.maximumStrength = maximumStrength
        self.maximumCenterDistance = maximumCenterDistance
        self.maximumMergedSide = maximumMergedSide
    }
}

public struct HeuristicFocusEngine: FocusSuggestionService {
    public var policy: FocusComfortPolicy

    public init(policy: FocusComfortPolicy = FocusComfortPolicy()) {
        self.policy = policy
    }

    public func suggestFocus(for input: FocusAnalysisInput) async throws -> [FocusSuggestion] {
        guard input.duration > .zero else { return [] }

        let filtered = input.candidates
            .filter {
                $0.timeRange.isValid &&
                    $0.timeRange.start < input.duration &&
                    $0.region.isFinite &&
                    $0.region.isPositive &&
                    $0.confidence.isFinite &&
                    $0.confidence >= policy.minimumConfidence
            }
            .sorted { $0.timeRange.start < $1.timeRange.start }

        var groups: [[FocusCandidate]] = []
        var groupRegions: [NormalizedRect] = []
        for candidate in filtered {
            if let index = groups.indices.last,
               let previous = groups[index].last,
               shouldMerge(previous, candidate, groupRegion: groupRegions[index]) {
                groups[index].append(candidate)
                groupRegions[index] = union(groupRegions[index], candidate.region)
            } else {
                groups.append([candidate])
                groupRegions.append(candidate.region)
            }
        }

        return groups.compactMap { group in
            guard let first = group.first, let last = group.last else { return nil }
            let start = first.timeRange.start
            let evidenceEnd = min(last.timeRange.end, input.duration)
            let desiredEnd = min(max(evidenceEnd, start + policy.minimumDwell), input.duration)
            guard desiredEnd > start else { return nil }

            // `expandedToMinimumSide` already lands inside the frame; clamping
            // again would shave the minimum side back off by a float epsilon.
            let region = group
                .map(\.region)
                .reduce(group[0].region, union)
                .expandedToMinimumSide(policy.minimumRegionSide)
            let confidence = group.map(\.confidence).max() ?? first.confidence
            let evidence = Array(Set(group.map(\.evidence))).sorted { $0.rawValue < $1.rawValue }
            let strength = min(policy.maximumStrength, max(0.25, 1 - max(region.size.width, region.size.height)))

            return FocusSuggestion(
                timeRange: StudioTimeRange(start: start, duration: desiredEnd - start),
                region: region,
                strength: strength,
                confidence: min(max(confidence, 0), 1),
                evidence: evidence,
                reason: group.map(\.reason).joined(separator: "; ")
            )
        }
    }

    private func shouldMerge(
        _ previous: FocusCandidate,
        _ candidate: FocusCandidate,
        groupRegion: NormalizedRect
    ) -> Bool {
        let gap = candidate.timeRange.start - previous.timeRange.end
        guard gap <= policy.mergeGap else { return false }
        let a = previous.region.center
        let b = candidate.region.center
        guard hypot(a.x - b.x, a.y - b.y) <= policy.maximumCenterDistance else { return false }

        // Pairwise proximity alone is transitive: a chain of small hops can walk
        // across the whole frame and union into a region that focuses nothing.
        let merged = union(groupRegion, candidate.region)
        return max(merged.size.width, merged.size.height) <= policy.maximumMergedSide
    }

    private func union(_ lhs: NormalizedRect, _ rhs: NormalizedRect) -> NormalizedRect {
        let minX = min(lhs.origin.x, rhs.origin.x)
        let minY = min(lhs.origin.y, rhs.origin.y)
        let maxX = max(lhs.origin.x + lhs.size.width, rhs.origin.x + rhs.size.width)
        let maxY = max(lhs.origin.y + lhs.size.height, rhs.origin.y + rhs.size.height)
        return NormalizedRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

private extension NormalizedRect {
    var center: NormalizedPoint {
        NormalizedPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
    }

    /// Slides the expanded rect back inside the frame instead of letting a later
    /// clamp shave it. Clamping would silently break the minimum-side guarantee
    /// precisely at the edges, which is where interface controls live.
    func expandedToMinimumSide(_ minimum: Double) -> NormalizedRect {
        let targetWidth = min(1, max(size.width, minimum))
        let targetHeight = min(1, max(size.height, minimum))
        return NormalizedRect(
            x: min(max(center.x - targetWidth / 2, 0), 1 - targetWidth),
            y: min(max(center.y - targetHeight / 2, 0), 1 - targetHeight),
            width: targetWidth,
            height: targetHeight
        )
    }
}
