import StudioDomain
@testable import StudioMediaPipeline
import Testing

@Test func compilerRejectsOverflowingRangesBeforeComputingProjectDuration() throws {
    let range = StudioTimeRange(start: StudioTime(microseconds: Int64.max - 1), duration: StudioTime(microseconds: 2))
    var timeline = TimelineDocument(id: TimelineID(), projectID: ProjectID())
    let caption = CaptionCue(timeRange: range, text: "Invalid range")
    timeline.captions = [caption]
    #expect(throws: TimelineCompilationError.invalidCaption(caption.id)) {
        _ = try TimelineCompiler().compile(timeline: timeline, assets: [], canvas: .landscape1080)
    }
    timeline.captions = []
    let focus = FocusEvent(timeRange: range, region: .fullFrame, strength: 0.5, source: .manual, confidence: 1)
    timeline.focusEvents = [focus]
    #expect(throws: TimelineCompilationError.invalidFocus(focus.id)) {
        _ = try TimelineCompiler().compile(timeline: timeline, assets: [], canvas: .landscape1080)
    }
    timeline.focusEvents = []
    let asset = SourceAsset(kind: .screenVideo, relativePath: "source.mov", duration: StudioTime(seconds: 10))
    var clip = TimelineClip(assetID: asset.id, sourceRange: StudioTimeRange(start: .zero, duration: StudioTime(microseconds: 2)), timelineStart: range.start)
    timeline.tracks = [TimelineTrack(kind: .screen, order: 0, clips: [clip])]
    #expect(throws: TimelineCompilationError.invalidTimelineRange(clip.id)) {
        _ = try TimelineCompiler().compile(timeline: timeline, assets: [asset], canvas: .landscape1080)
    }
    clip.timelineStart = .zero
    clip.sourceRange = range
    timeline.tracks[0].clips = [clip]
    #expect(throws: TimelineCompilationError.invalidSourceRange(clip.id)) {
        _ = try TimelineCompiler().compile(timeline: timeline, assets: [asset], canvas: .landscape1080)
    }
}

@Test func audioGainIsValidatedAndUndoable() throws {
    let audio = SourceAsset(kind: .microphoneAudio, relativePath: "sources/mic.m4a", duration: StudioTime(seconds: 3))
    let empty = TimelineDocument(id: TimelineID(), projectID: ProjectID())
    let appended = try TimelineEditor().appending(asset: audio, to: empty)
    let edit = try TimelineEditor().performing(.setClipGain(clipID: appended.clip.id, gainDB: -6), on: appended.timeline, history: TimelineEditHistory(timeline: appended.timeline), assetDurations: [audio.id: audio.duration])
    let plan = try TimelineCompiler().compile(timeline: edit.timeline, assets: [audio], canvas: .landscape1080)
    #expect(plan.layers[0].gainDB == -6)
    #expect(abs((AudioGain.linearVolume(for: -6) ?? 0) - 0.501187) < 0.00001)
    #expect(AudioGain.linearVolume(for: .nan) == nil)
    #expect(AudioGain.linearVolume(for: 1) == nil)
    let restored = try TimelineEditor().undoing(edit.timeline, history: edit.history)
    #expect(restored.timeline.tracks[0].clips[0].gainDB == 0)
    #expect(throws: TimelineEditError.invalidGain(appended.clip.id)) {
        _ = try TimelineEditor().applying(.setClipGain(clipID: appended.clip.id, gainDB: 1), to: appended.timeline)
    }
}

@Test func audioTrackMuteIsUndoableAndExcludedFromRenderPlan() throws {
    let audio = SourceAsset(kind: .microphoneAudio, relativePath: "sources/mic.m4a", duration: StudioTime(seconds: 3))
    let video = SourceAsset(kind: .screenVideo, relativePath: "sources/screen.mov", duration: StudioTime(seconds: 3))
    let empty = TimelineDocument(id: TimelineID(), projectID: ProjectID())
    let videoEdit = try TimelineEditor().appending(asset: video, to: empty)
    let audioEdit = try TimelineEditor().appending(asset: audio, to: videoEdit.timeline)
    let trackID = try #require(audioEdit.timeline.tracks.first(where: { $0.kind == .microphone })?.id)
    let result = try TimelineEditor().performing(
        .setTrackMuted(trackID: trackID, isMuted: true),
        on: audioEdit.timeline, history: TimelineEditHistory(timeline: audioEdit.timeline),
        assetDurations: [video.id: video.duration, audio.id: audio.duration]
    )
    let plan = try TimelineCompiler().compile(timeline: result.timeline, assets: [video, audio], canvas: .landscape1080)
    #expect(plan.layers.map(\.asset.id) == [video.id])
    let restored = try TimelineEditor().undoing(result.timeline, history: result.history)
    let restoredPlan = try TimelineCompiler().compile(timeline: restored.timeline, assets: [video, audio], canvas: .landscape1080)
    #expect(Set(restoredPlan.layers.map(\.asset.id)) == Set([video.id, audio.id]))
    var locked = audioEdit.timeline
    let index = try #require(locked.tracks.firstIndex(where: { $0.id == trackID }))
    locked.tracks[index].isLocked = true
    #expect(throws: TimelineEditError.trackLocked(trackID)) {
        _ = try TimelineEditor().applying(.setTrackMuted(trackID: trackID, isMuted: true), to: locked)
    }
}

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
