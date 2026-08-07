@testable import StudioDomain
import Testing

@Test func timeRangeUsesHalfOpenBounds() {
    let range = StudioTimeRange(
        start: StudioTime(seconds: 1),
        duration: StudioTime(seconds: 2)
    )

    #expect(range.contains(StudioTime(seconds: 1)))
    #expect(range.contains(StudioTime(seconds: 2.999)))
    #expect(!range.contains(StudioTime(seconds: 3)))
}

@Test func normalizedRectClampsToFrame() {
    let rect = NormalizedRect(x: -0.1, y: 0.8, width: 1.2, height: 0.5).clampedToFrame()
    #expect(rect.origin.x == 0)
    #expect(rect.origin.y == 0.8)
    #expect(rect.size.width == 1)
    #expect(abs(rect.size.height - 0.2) < 0.000_001)
}
