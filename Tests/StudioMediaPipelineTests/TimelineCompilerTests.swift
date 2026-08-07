import StudioDomain
@testable import StudioMediaPipeline
import Testing

@Test func compilerBuildsResponsivePlan() throws {
    let projectID = ProjectID()
    let timelineID = TimelineID()
    let asset = SourceAsset(
        kind: .screenVideo,
        relativePath: "sources/screen.mov",
        duration: StudioTime(seconds: 10)
    )
    let clip = TimelineClip(
        assetID: asset.id,
        sourceRange: StudioTimeRange(start: .zero, duration: StudioTime(seconds: 5)),
        timelineStart: StudioTime(seconds: 1)
    )
    let focus = FocusEvent(
        timeRange: StudioTimeRange(
            start: StudioTime(seconds: 2),
            duration: StudioTime(seconds: 1)
        ),
        region: NormalizedRect(x: 0.9, y: 0.9, width: 0.4, height: 0.4),
        strength: 2,
        source: .manual,
        confidence: 1
    )
    let timeline = TimelineDocument(
        id: timelineID,
        projectID: projectID,
        tracks: [TimelineTrack(kind: .screen, order: 0, clips: [clip])],
        focusEvents: [focus]
    )

    let plan = try TimelineCompiler().compile(
        timeline: timeline,
        assets: [asset],
        canvas: .vertical1080
    )

    #expect(plan.duration == StudioTime(seconds: 6))
    #expect(plan.layers.count == 1)
    #expect(plan.focus.first?.strength == 1)
    #expect(abs((plan.focus.first?.region.size.width ?? 0) - 0.1) < 0.000_001)
    #expect(plan.canvas.orientation == .portrait)
}

@Test func compilerReportsDuplicateAssetsInsteadOfTrapping() {
    let asset = SourceAsset(
        kind: .screenVideo,
        relativePath: "sources/screen.mov",
        duration: StudioTime(seconds: 10)
    )
    let clip = TimelineClip(
        assetID: asset.id,
        sourceRange: StudioTimeRange(start: .zero, duration: StudioTime(seconds: 1)),
        timelineStart: .zero
    )
    let timeline = TimelineDocument(
        id: TimelineID(),
        projectID: ProjectID(),
        tracks: [TimelineTrack(kind: .screen, order: 0, clips: [clip])]
    )

    #expect(throws: TimelineCompilationError.duplicateAsset(asset.id)) {
        _ = try TimelineCompiler().compile(
            timeline: timeline,
            assets: [asset, asset],
            canvas: .landscape1080
        )
    }
}

@Test func compilerRejectsMissingAsset() {
    let clip = TimelineClip(
        assetID: AssetID(),
        sourceRange: StudioTimeRange(start: .zero, duration: StudioTime(seconds: 1)),
        timelineStart: .zero
    )
    let timeline = TimelineDocument(
        id: TimelineID(),
        projectID: ProjectID(),
        tracks: [TimelineTrack(kind: .screen, order: 0, clips: [clip])]
    )

    #expect(throws: TimelineCompilationError.self) {
        _ = try TimelineCompiler().compile(timeline: timeline, assets: [], canvas: .landscape1080)
    }
}
