@testable import StudioAI
import StudioDomain
import Testing

@Test func focusEngineFiltersAndMergesComfortably() async throws {
    let engine = HeuristicFocusEngine()
    let suggestions = try await engine.suggestFocus(
        for: FocusAnalysisInput(
            duration: StudioTime(seconds: 5),
            candidates: [
                FocusCandidate(
                    timeRange: StudioTimeRange(
                        start: StudioTime(seconds: 1),
                        duration: StudioTime(seconds: 0.2)
                    ),
                    region: NormalizedRect(x: 0.2, y: 0.2, width: 0.1, height: 0.1),
                    confidence: 0.9,
                    evidence: .exactInteraction,
                    reason: "Tap"
                ),
                FocusCandidate(
                    timeRange: StudioTimeRange(
                        start: StudioTime(seconds: 1.4),
                        duration: StudioTime(seconds: 0.2)
                    ),
                    region: NormalizedRect(x: 0.23, y: 0.21, width: 0.1, height: 0.1),
                    confidence: 0.82,
                    evidence: .pixelChange,
                    reason: "Changed control"
                ),
                FocusCandidate(
                    timeRange: StudioTimeRange(
                        start: StudioTime(seconds: 3),
                        duration: StudioTime(seconds: 0.2)
                    ),
                    region: NormalizedRect(x: 0.7, y: 0.7, width: 0.1, height: 0.1),
                    confidence: 0.4,
                    evidence: .pixelChange,
                    reason: "Low confidence"
                ),
            ]
        )
    )

    #expect(suggestions.count == 1)
    #expect(suggestions[0].timeRange.duration >= StudioTime(seconds: 1.2))
    #expect(suggestions[0].region.size.width >= 0.18)
    #expect(Set(suggestions[0].evidence) == Set([.exactInteraction, .pixelChange]))
}

@Test func focusRegionKeepsItsMinimumSizeAtTheFrameEdge() async throws {
    let policy = FocusComfortPolicy()
    let engine = HeuristicFocusEngine(policy: policy)
    let suggestions = try await engine.suggestFocus(
        for: FocusAnalysisInput(
            duration: StudioTime(seconds: 5),
            candidates: [
                FocusCandidate(
                    timeRange: StudioTimeRange(
                        start: StudioTime(seconds: 1),
                        duration: StudioTime(seconds: 0.2)
                    ),
                    region: NormalizedRect(x: 0.94, y: 0.94, width: 0.05, height: 0.05),
                    confidence: 0.95,
                    evidence: .exactInteraction,
                    reason: "Control in the corner"
                )
            ]
        )
    )

    let region = try #require(suggestions.first?.region)
    #expect(region.size.width >= policy.minimumRegionSide)
    #expect(region.size.height >= policy.minimumRegionSide)
    #expect(region.origin.x + region.size.width <= 1.000_001)
    #expect(region.origin.y + region.size.height <= 1.000_001)
}

@Test func focusMergingStopsBeforeTheRegionSwallowsTheFrame() async throws {
    // Each hop is close enough to merge with its predecessor; without a bound on
    // the merged region they would chain into one useless full-width suggestion.
    let candidates = (0 ..< 6).map { step in
        FocusCandidate(
            timeRange: StudioTimeRange(
                start: StudioTime(seconds: 1 + Double(step) * 0.3),
                duration: StudioTime(seconds: 0.1)
            ),
            region: NormalizedRect(x: 0.05 + Double(step) * 0.15, y: 0.4, width: 0.08, height: 0.08),
            confidence: 0.9,
            evidence: .pixelChange,
            reason: "Step \(step)"
        )
    }

    let suggestions = try await HeuristicFocusEngine().suggestFocus(
        for: FocusAnalysisInput(duration: StudioTime(seconds: 10), candidates: candidates)
    )

    #expect(suggestions.count > 1)
    for suggestion in suggestions {
        #expect(suggestion.region.size.width <= 0.65)
    }
}
