import Foundation
import StudioDomain
import Testing

@Test func screenWithCameraBubblePlacesFacecamInBottomRight() throws {
    let frames = CaptureLayout.frames(for: .screenWithCameraBubble)
    #expect(frames.screen?.frame == .fullFrame)
    let camera = try #require(frames.camera?.frame)
    #expect(camera.origin.x > 0.5)
    #expect(camera.origin.y > 0.5)
    #expect(camera.size.width < 0.35)
    #expect(camera.size.height < 0.35)
}

@Test func splitLayoutsDoNotOverlap() throws {
    for layout in [CaptureLayoutID.splitScreenLeft, .splitCameraLeft, .sideBySide] {
        let frames = CaptureLayout.frames(for: layout)
        let screen = try #require(frames.screen?.frame)
        let camera = try #require(frames.camera?.frame)
        #expect(!screen.overlaps(camera), "Expected non-overlapping panes for \(layout)")
    }
}

@Test func layoutTransformMapsMediaKinds() {
    let bubble = CaptureLayout.transform(for: .cameraVideo, layout: .screenWithCameraBubble)
    #expect(bubble.frame.origin.x > 0.5)
    let screen = CaptureLayout.transform(for: .screenVideo, layout: .screenWithCameraBubble)
    #expect(screen.frame == .fullFrame)
    let talkingHead = CaptureLayout.transform(for: .cameraVideo, layout: .cameraOnly)
    #expect(talkingHead.frame == .fullFrame)
}

@Test func dualSourceLayoutCatalogIsNonEmpty() {
    #expect(CaptureLayout.dualSourceLayouts.count >= 4)
    #expect(CaptureLayout.dualSourceLayouts.contains(.screenWithCameraBubble))
}

@Test func bubbleLayoutUsesCircularCornerRadius() {
    let camera = CaptureLayout.transform(for: .cameraVideo, layout: .screenWithCameraBubble)
    #expect(camera.isCircular)
    #expect(camera.cornerRadius >= 0.45)
}

@Test func cameraFrameDragKeepsSizeAndClamps() {
    let prototype = NormalizedRect(x: 0.74, y: 0.70, width: 0.22, height: 0.26)
    let moved = CaptureLayout.cameraFrame(
        from: prototype,
        centeredAt: NormalizedPoint(x: 0.1, y: 0.1)
    )
    #expect(abs(moved.size.width - prototype.size.width) < 0.000_001)
    #expect(abs(moved.size.height - prototype.size.height) < 0.000_001)
    #expect(moved.origin.x >= 0)
    #expect(moved.origin.y >= 0)
    #expect(moved.maxX <= 1.000_001)
    #expect(moved.maxY <= 1.000_001)
}

@Test func setClipTransformIsUndoable() throws {
    let projectID = ProjectID()
    var timeline = TimelineDocument(id: TimelineID(), projectID: projectID)
    let asset = SourceAsset(
        kind: .cameraVideo,
        relativePath: "sources/cam.mov",
        duration: StudioTime(seconds: 5)
    )
    let placed = try TimelineEditor().placingCapturedAsset(
        asset,
        at: .zero,
        in: timeline,
        assetDurations: [asset.id: asset.duration],
        transform: CaptureLayout.transform(for: .cameraVideo, layout: .screenWithCameraBubble)
    )
    timeline = placed.timeline
    let clipID = placed.clip.id
    let next = ClipTransform(
        frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.22, height: 0.26),
        cornerRadius: 0.5
    )
    let edited = try TimelineEditor().performing(
        .setClipTransform(clipID: clipID, transform: next),
        on: timeline,
        history: TimelineEditHistory(timeline: timeline),
        assetDurations: [asset.id: asset.duration]
    )
    #expect(edited.timeline.tracks.flatMap(\.clips).first?.transform.frame.origin.x == 0.1)
    #expect(edited.history.canUndo)
    let undone = try TimelineEditor().undoing(edited.timeline, history: edited.history)
    #expect(undone.timeline.tracks.flatMap(\.clips).first?.transform.frame.origin.x ?? 0 > 0.5)
}
