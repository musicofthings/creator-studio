import Foundation
import StudioDomain
import Testing

@Test func linkedRangeCutPreservesRatesGapsAndLaterSessions() throws {
    let assetID = AssetID()
    let fast = TimelineClip(assetID: assetID, sourceRange: StudioTimeRange(start: StudioTime(seconds: 2), duration: StudioTime(seconds: 12)), timelineStart: StudioTime(seconds: 1), playbackRate: 2)
    let slow = TimelineClip(assetID: assetID, sourceRange: StudioTimeRange(start: .zero, duration: StudioTime(seconds: 6)), timelineStart: StudioTime(seconds: 2), playbackRate: 0.5, gainDB: -6, isEnabled: false)
    let later = TimelineClip(assetID: assetID, sourceRange: StudioTimeRange(start: StudioTime(seconds: 20), duration: StudioTime(seconds: 4)), timelineStart: StudioTime(seconds: 20))
    let removed = TimelineClip(assetID: assetID, sourceRange: StudioTimeRange(start: .zero, duration: StudioTime(seconds: 1)), timelineStart: StudioTime(seconds: 4))
    var timeline = TimelineDocument(id: TimelineID(), projectID: ProjectID())
    timeline.tracks = [
        TimelineTrack(kind: .screen, order: 0, clips: [fast, later]),
        TimelineTrack(kind: .microphone, order: 1, isMuted: true, clips: [slow]),
        TimelineTrack(kind: .music, order: 2, clips: [removed]),
    ]
    timeline.captions = [CaptionCue(timeRange: StudioTimeRange(start: StudioTime(seconds: 2), duration: StudioTime(seconds: 1)), text: "Before")]
    timeline.focusEvents = [FocusEvent(timeRange: StudioTimeRange(start: StudioTime(seconds: 7), duration: StudioTime(seconds: 1)), region: .fullFrame, strength: 0.5, source: .manual, confidence: 1)]
    let tailID = ClipID()
    let range = StudioTimeRange(start: StudioTime(seconds: 3), duration: StudioTime(seconds: 4))
    let result = try TimelineEditor().performing(.removeLinked(range: range, trailingIDs: [slow.id: tailID]), on: timeline, history: TimelineEditHistory(timeline: timeline), assetDurations: [assetID: StudioTime(seconds: 30)])
    let video = result.timeline.tracks[0].clips
    #expect(video[0].sourceRange == StudioTimeRange(start: StudioTime(seconds: 2), duration: StudioTime(seconds: 4)))
    #expect(video[0].timelineStart == fast.timelineStart)
    #expect(video[1].timelineStart == StudioTime(seconds: 16))
    #expect(video[1].sourceRange == later.sourceRange)
    let audio = result.timeline.tracks[1].clips
    #expect(audio[0].sourceRange.duration == StudioTime(seconds: 0.5))
    #expect(audio[1].id == tailID)
    #expect(audio[1].sourceRange.start == StudioTime(seconds: 2.5))
    #expect(audio[1].timelineStart == StudioTime(seconds: 3))
    #expect(audio[1].timelineRange.end == StudioTime(seconds: 10))
    #expect(audio.allSatisfy { $0.playbackRate == 0.5 && $0.gainDB == -6 && !$0.isEnabled })
    #expect(result.timeline.tracks[1].isMuted)
    #expect(result.timeline.tracks[2].clips.isEmpty)
    #expect(result.timeline.captions == timeline.captions)
    #expect(result.timeline.focusEvents[0].timeRange.start == StudioTime(seconds: 3))
    // The exact command and source snapshots survive persistence for relaunch undo/redo.
    let savedHistory = try JSONDecoder().decode(TimelineEditHistory.self, from: JSONEncoder().encode(result.history))
    let undone = try TimelineEditor().undoing(result.timeline, history: savedHistory)
    #expect(undone.timeline.tracks == timeline.tracks)
    #expect(undone.timeline.focusEvents == timeline.focusEvents)
    let redone = try TimelineEditor().redoing(undone.timeline, history: undone.history)
    #expect(redone.timeline.tracks == result.timeline.tracks)
}

@Test func linkedRangeCutRejectsInvalidBoundsMetadataAndAffectedLocks() throws {
    let clip = TimelineClip(assetID: AssetID(), sourceRange: StudioTimeRange(start: .zero, duration: StudioTime(seconds: 10)), timelineStart: .zero)
    var timeline = TimelineDocument(id: TimelineID(), projectID: ProjectID(), tracks: [TimelineTrack(kind: .screen, order: 0, clips: [clip])])
    let cut = StudioTimeRange(start: StudioTime(seconds: 3), duration: StudioTime(seconds: 2))
    let command = TimelineCommand.removeLinked(range: cut, trailingIDs: [clip.id: ClipID()])
    for range in [
        StudioTimeRange(start: StudioTime(seconds: -1), duration: StudioTime(seconds: 2)),
        StudioTimeRange(start: .zero, duration: .zero),
        StudioTimeRange(start: StudioTime(seconds: 9), duration: StudioTime(seconds: 2)),
        StudioTimeRange(start: StudioTime(microseconds: Int64.max - 1), duration: StudioTime(microseconds: 2)),
    ] {
        #expect(throws: TimelineEditError.invalidTimeline) {
            _ = try TimelineEditor().applying(.removeLinked(range: range, trailingIDs: [:]), to: timeline)
        }
    }
    #expect(throws: TimelineEditError.invalidTimeline) {
        _ = try TimelineEditor().applying(.removeLinked(range: cut, trailingIDs: [clip.id: clip.id]), to: timeline)
    }
    timeline.focusEvents = [FocusEvent(timeRange: cut, region: .fullFrame, strength: 0.5, source: .manual, confidence: 1)]
    #expect(throws: TimelineEditError.linkedRemovalOverlapsMetadata) {
        _ = try TimelineEditor().applying(command, to: timeline)
    }
    timeline.focusEvents = []
    // Even a later locked track must reject a ripple, because its start would move.
    var later = clip
    later.id = ClipID()
    later.timelineStart = StudioTime(seconds: 20)
    timeline.tracks.append(TimelineTrack(kind: .microphone, order: 1, isLocked: true, clips: [later]))
    #expect(throws: TimelineEditError.trackLocked(timeline.tracks[1].id)) {
        _ = try TimelineEditor().applying(command, to: timeline)
    }
    // A lock wholly before the range does not block the cut.
    later.timelineStart = .zero
    later.sourceRange = StudioTimeRange(start: .zero, duration: StudioTime(seconds: 1))
    timeline.tracks[1].clips = [later]
    #expect(try TimelineEditor().applying(command, to: timeline).tracks[1] == timeline.tracks[1])
}

@Test func linkedEditsRejectOverflowingPersistedRangesWithoutTrapping() throws {
    let range = StudioTimeRange(start: StudioTime(microseconds: Int64.max - 1), duration: StudioTime(microseconds: 2))
    var timeline = TimelineDocument(id: TimelineID(), projectID: ProjectID())
    timeline.captions = [CaptionCue(timeRange: range, text: "Invalid")]
    #expect(throws: TimelineEditError.invalidTimeline) {
        _ = try TimelineEditor().applying(.splitLinked(time: .zero, trailingIDs: [:]), to: timeline)
    }
    timeline.captions = []
    timeline.tracks = [TimelineTrack(kind: .screen, order: 0, clips: [TimelineClip(assetID: AssetID(), sourceRange: StudioTimeRange(start: .zero, duration: StudioTime(microseconds: 2)), timelineStart: range.start)])]
    #expect(throws: TimelineEditError.invalidTimeline) {
        _ = try TimelineEditor().applying(.splitLinked(time: .zero, trailingIDs: [:]), to: timeline)
    }
}

@Test func linkedRemovalCutsAcrossTracksAndUndoRestoresSources() throws {
    let empty = TimelineDocument(id: TimelineID(), projectID: ProjectID())
    let video = SourceAsset(kind: .screenVideo, relativePath: "s.mov", duration: StudioTime(seconds: 10))
    let audio = SourceAsset(kind: .microphoneAudio, relativePath: "a.m4a", duration: StudioTime(seconds: 8))
    let durations = [video.id: video.duration, audio.id: audio.duration]
    let v = try TimelineEditor().placingCapturedAsset(video, at: .zero, in: empty, assetDurations: durations)
    let a = try TimelineEditor().placingCapturedAsset(audio, at: StudioTime(seconds: 1), in: v.timeline, assetDurations: durations)
    let range = StudioTimeRange(start: StudioTime(seconds: 3), duration: StudioTime(seconds: 2))
    let command = TimelineCommand.removeLinked(range: range, trailingIDs: [v.clip.id: ClipID(), a.clip.id: ClipID()])
    #expect(try JSONDecoder().decode(TimelineCommand.self, from: JSONEncoder().encode(command)) == command)
    var source = a.timeline
    source.captions = [CaptionCue(timeRange: StudioTimeRange(start: StudioTime(seconds: 7), duration: StudioTime(seconds: 1)), text: "Later")]
    let edit = try TimelineEditor().performing(command, on: source, history: TimelineEditHistory(timeline: source), assetDurations: durations)
    #expect(edit.timeline.tracks[0].clips.map(\.timelineStart) == [.zero, StudioTime(seconds: 3)])
    #expect(edit.timeline.tracks[1].clips.map(\.timelineStart) == [StudioTime(seconds: 1), StudioTime(seconds: 3)])
    #expect(edit.timeline.tracks[1].clips[1].sourceRange.start == StudioTime(seconds: 4))
    #expect(edit.timeline.captions[0].timeRange.start == StudioTime(seconds: 5))
    let undo = try TimelineEditor().undoing(edit.timeline, history: edit.history)
    #expect(undo.timeline.tracks == a.timeline.tracks)
    var locked = a.timeline
    locked.tracks[1].isLocked = true
    #expect(throws: TimelineEditError.trackLocked(locked.tracks[1].id)) {
        _ = try TimelineEditor().applying(command, to: locked, assetDurations: durations)
    }
    var withCaption = a.timeline
    withCaption.captions = [CaptionCue(timeRange: range, text: "Hello")]
    #expect(throws: TimelineEditError.linkedRemovalOverlapsMetadata) {
        _ = try TimelineEditor().applying(command, to: withCaption, assetDurations: durations)
    }
}

@Test func linkedSplitPreservesOffsetsAndSupportsUndoRedo() throws {
    let empty = TimelineDocument(id: TimelineID(), projectID: ProjectID())
    let screen = SourceAsset(kind: .screenVideo, relativePath: "s.mov", duration: StudioTime(seconds: 10))
    let audio = SourceAsset(kind: .microphoneAudio, relativePath: "a.m4a", duration: StudioTime(seconds: 10))
    let durations = [screen.id: screen.duration, audio.id: audio.duration]
    let s = try TimelineEditor().placingCapturedAsset(screen, at: StudioTime(seconds: 2), in: empty, assetDurations: durations)
    let a = try TimelineEditor().placingCapturedAsset(audio, at: .zero, in: s.timeline, assetDurations: durations)
    let screenTail = ClipID()
    let audioTail = ClipID()
    let command = TimelineCommand.splitLinked(time: StudioTime(seconds: 5), trailingIDs: [s.clip.id: screenTail, a.clip.id: audioTail])
    let decoded = try JSONDecoder().decode(TimelineCommand.self, from: JSONEncoder().encode(command))
    #expect(decoded == command)
    let edited = try TimelineEditor().performing(command, on: a.timeline, history: TimelineEditHistory(timeline: a.timeline), assetDurations: durations)
    #expect(edited.timeline.tracks[0].clips[0].timelineStart == StudioTime(seconds: 2))
    #expect(edited.timeline.tracks[0].clips[1].timelineStart == StudioTime(seconds: 5))
    #expect(edited.timeline.tracks[1].clips[1].timelineStart == StudioTime(seconds: 5))
    #expect(edited.timeline.tracks[1].clips[1].sourceRange.start == StudioTime(seconds: 5))
    let undone = try TimelineEditor().undoing(edited.timeline, history: edited.history)
    #expect(undone.timeline.tracks == a.timeline.tracks)
    let redone = try TimelineEditor().redoing(undone.timeline, history: undone.history)
    #expect(redone.timeline.tracks == edited.timeline.tracks)
    var locked = a.timeline
    locked.tracks[1].isLocked = true
    #expect(throws: TimelineEditError.trackLocked(locked.tracks[1].id)) {
        _ = try TimelineEditor().applying(command, to: locked, assetDurations: durations)
    }
}

@Test func synchronizedTracksKeepOffsetsWhenSplittingAndRejectRippleEdits() throws {
    let empty = TimelineDocument(id: TimelineID(), projectID: ProjectID())
    let screen = SourceAsset(kind: .screenVideo, relativePath: "sources/s.mov", duration: StudioTime(seconds: 10))
    let audio = SourceAsset(kind: .microphoneAudio, relativePath: "sources/a.m4a", duration: StudioTime(seconds: 10))
    let durations = [screen.id: screen.duration, audio.id: audio.duration]
    let s = try TimelineEditor().placingCapturedAsset(screen, at: StudioTime(seconds: 2), in: empty, assetDurations: durations)
    let a = try TimelineEditor().placingCapturedAsset(audio, at: .zero, in: s.timeline, assetDurations: durations)
    let split = try TimelineEditor().applying(.split(clipID: s.clip.id, sourceTime: StudioTime(seconds: 4), trailingClipID: ClipID()), to: a.timeline, assetDurations: durations)
    #expect(split.tracks[0].clips[0].timelineStart == StudioTime(seconds: 2))
    #expect(split.tracks[0].clips[1].timelineStart == StudioTime(seconds: 6))
    #expect(split.tracks[1].clips[0].timelineStart == .zero)
    #expect(throws: TimelineEditError.synchronizedTracksRequireLinkedEdits) {
        _ = try TimelineEditor().applying(.delete(clipID: s.clip.id), to: split, assetDurations: durations)
    }
}

@Test func appendingAssetsBuildsPersistentSequentialTracks() throws {
    let timeline = TimelineDocument(id: TimelineID(), projectID: ProjectID())
    let firstAsset = SourceAsset(
        kind: .screenVideo,
        relativePath: "sources/first.mov",
        duration: StudioTime(seconds: 4)
    )
    let secondAsset = SourceAsset(
        kind: .screenVideo,
        relativePath: "sources/second.mov",
        duration: StudioTime(seconds: 3)
    )

    let first = try TimelineEditor().appending(asset: firstAsset, to: timeline)
    let second = try TimelineEditor().appending(asset: secondAsset, to: first.timeline)

    #expect(second.timeline.revision == 2)
    #expect(second.timeline.tracks.count == 1)
    #expect(second.timeline.tracks[0].kind == .screen)
    #expect(second.timeline.tracks[0].clips.count == 2)
    #expect(second.timeline.tracks[0].clips[0].timelineStart == .zero)
    #expect(second.timeline.tracks[0].clips[1].timelineStart == StudioTime(seconds: 4))
    #expect(second.clip.assetID == secondAsset.id)
}

@Test func appendingAudioUsesASeparateTrack() throws {
    let timeline = TimelineDocument(id: TimelineID(), projectID: ProjectID())
    let video = SourceAsset(
        kind: .cameraVideo,
        relativePath: "sources/video.mov",
        duration: StudioTime(seconds: 5)
    )
    let audio = SourceAsset(
        kind: .microphoneAudio,
        relativePath: "sources/audio.m4a",
        duration: StudioTime(seconds: 5)
    )

    let withVideo = try TimelineEditor().appending(asset: video, to: timeline)
    let withAudio = try TimelineEditor().appending(asset: audio, to: withVideo.timeline)

    #expect(withAudio.timeline.tracks.map(\.kind) == [.camera, .microphone])
    #expect(withAudio.timeline.tracks[1].clips[0].timelineStart == .zero)
}

@Test func capturedAssetsPreserveTheirSharedSessionClock() throws {
    let projectID = ProjectID()
    let timeline = TimelineDocument(id: TimelineID(), projectID: projectID)
    let screen = SourceAsset(
        kind: .screenVideo,
        relativePath: "sources/screen.mov",
        duration: StudioTime(seconds: 10),
        captureStart: .zero
    )
    let microphone = SourceAsset(
        kind: .microphoneAudio,
        relativePath: "sources/microphone.m4a",
        duration: StudioTime(seconds: 9.5),
        captureStart: StudioTime(microseconds: 15000)
    )
    let durations = [screen.id: screen.duration, microphone.id: microphone.duration]

    let withScreen = try TimelineEditor().placingCapturedAsset(
        screen,
        at: screen.captureStart ?? .zero,
        in: timeline,
        assetDurations: durations
    )
    let withMicrophone = try TimelineEditor().placingCapturedAsset(
        microphone,
        at: microphone.captureStart ?? .zero,
        in: withScreen.timeline,
        assetDurations: durations
    )

    #expect(withMicrophone.timeline.tracks.map(\.kind) == [.screen, .microphone])
    #expect(withMicrophone.timeline.tracks[0].clips[0].timelineStart == .zero)
    #expect(
        withMicrophone.timeline.tracks[1].clips[0].timelineStart
            == StudioTime(microseconds: 15000)
    )
}

@Test func placeClipRejectsOverlappingRangesOnTheSameTrack() throws {
    let projectID = ProjectID()
    let timeline = TimelineDocument(id: TimelineID(), projectID: projectID)
    let first = SourceAsset(
        kind: .screenVideo,
        relativePath: "sources/first.mov",
        duration: StudioTime(seconds: 4),
        captureStart: .zero
    )
    let overlapping = SourceAsset(
        kind: .screenVideo,
        relativePath: "sources/overlap.mov",
        duration: StudioTime(seconds: 3),
        captureStart: StudioTime(seconds: 2)
    )
    let abutting = SourceAsset(
        kind: .screenVideo,
        relativePath: "sources/next.mov",
        duration: StudioTime(seconds: 2),
        captureStart: StudioTime(seconds: 4)
    )
    let durations = [
        first.id: first.duration,
        overlapping.id: overlapping.duration,
        abutting.id: abutting.duration,
    ]

    let placed = try TimelineEditor().placingCapturedAsset(
        first,
        at: .zero,
        in: timeline,
        assetDurations: durations
    )
    #expect(throws: TimelineEditError.self) {
        _ = try TimelineEditor().placingCapturedAsset(
            overlapping,
            at: StudioTime(seconds: 2),
            in: placed.timeline,
            assetDurations: durations
        )
    }
    let adjacent = try TimelineEditor().placingCapturedAsset(
        abutting,
        at: StudioTime(seconds: 4),
        in: placed.timeline,
        assetDurations: durations
    )
    #expect(adjacent.timeline.tracks[0].clips.count == 2)
    #expect(adjacent.timeline.tracks[0].clips[1].timelineStart == StudioTime(seconds: 4))
}

@Test func focusEventsArePersistentUndoableTimelineEdits() throws {
    let timeline = TimelineDocument(id: TimelineID(), projectID: ProjectID())
    let focus = FocusEvent(
        timeRange: StudioTimeRange(
            start: StudioTime(seconds: 2),
            duration: StudioTime(seconds: 1.5)
        ),
        region: NormalizedRect(x: 0.3, y: 0.4, width: 0.4, height: 0.4),
        strength: 0.8,
        source: .interactionEvent,
        confidence: 0.9
    )

    let edited = try TimelineEditor().performing(
        .addFocusEvents([focus]),
        on: timeline,
        history: TimelineEditHistory(timeline: timeline),
        assetDurations: [:]
    )
    #expect(edited.timeline.focusEvents == [focus])
    #expect(edited.history.canUndo)

    let undone = try TimelineEditor().undoing(edited.timeline, history: edited.history)
    #expect(undone.timeline.focusEvents.isEmpty)
}

@Test func extremePlaybackRateCannotTrapTimelineDuration() {
    let clip = TimelineClip(
        assetID: AssetID(),
        sourceRange: StudioTimeRange(start: .zero, duration: StudioTime(seconds: 1)),
        timelineStart: .zero,
        playbackRate: Double.leastNonzeroMagnitude
    )

    #expect(clip.timelineDuration == .zero)
}

@Test func trimmingRipplesFollowingClipsWithoutChangingTheSource() throws {
    let firstAsset = SourceAsset(
        kind: .screenVideo,
        relativePath: "sources/first.mov",
        duration: StudioTime(seconds: 8)
    )
    let secondAsset = SourceAsset(
        kind: .screenVideo,
        relativePath: "sources/second.mov",
        duration: StudioTime(seconds: 3)
    )
    let empty = TimelineDocument(id: TimelineID(), projectID: ProjectID())
    let first = try TimelineEditor().appending(asset: firstAsset, to: empty)
    let second = try TimelineEditor().appending(asset: secondAsset, to: first.timeline)

    let trimmed = try TimelineEditor().applying(
        .trim(
            clipID: first.clip.id,
            sourceRange: StudioTimeRange(
                start: StudioTime(seconds: 1),
                duration: StudioTime(seconds: 4)
            )
        ),
        to: second.timeline,
        assetDurations: [firstAsset.id: firstAsset.duration, secondAsset.id: secondAsset.duration]
    )

    #expect(trimmed.revision == 3)
    #expect(trimmed.tracks[0].clips[0].sourceRange.start == StudioTime(seconds: 1))
    #expect(trimmed.tracks[0].clips[0].sourceRange.duration == StudioTime(seconds: 4))
    #expect(trimmed.tracks[0].clips[1].timelineStart == StudioTime(seconds: 4))
    #expect(firstAsset.duration == StudioTime(seconds: 8))
}

@Test func splittingCreatesTwoSourceReferencesAndPreservesDuration() throws {
    let asset = SourceAsset(
        kind: .cameraVideo,
        relativePath: "sources/camera.mov",
        duration: StudioTime(seconds: 10)
    )
    let empty = TimelineDocument(id: TimelineID(), projectID: ProjectID())
    let appended = try TimelineEditor().appending(asset: asset, to: empty)
    let trailingID = ClipID()

    let split = try TimelineEditor().applying(
        .split(
            clipID: appended.clip.id,
            sourceTime: StudioTime(seconds: 4),
            trailingClipID: trailingID
        ),
        to: appended.timeline,
        assetDurations: [asset.id: asset.duration]
    )

    #expect(split.tracks[0].clips.count == 2)
    #expect(split.tracks[0].clips[0].sourceRange.duration == StudioTime(seconds: 4))
    #expect(split.tracks[0].clips[1].id == trailingID)
    #expect(split.tracks[0].clips[1].sourceRange.start == StudioTime(seconds: 4))
    #expect(split.tracks[0].clips[1].sourceRange.duration == StudioTime(seconds: 6))
    #expect(split.tracks[0].clips[1].timelineStart == StudioTime(seconds: 4))
}

@Test func movingAndDeletingClipsRippleTheTrack() throws {
    let assets = (1 ... 3).map { index in
        SourceAsset(
            kind: .screenVideo,
            relativePath: "sources/\(index).mov",
            duration: StudioTime(seconds: Double(index))
        )
    }
    var timeline = TimelineDocument(id: TimelineID(), projectID: ProjectID())
    var clipIDs: [ClipID] = []
    for asset in assets {
        let appended = try TimelineEditor().appending(asset: asset, to: timeline)
        timeline = appended.timeline
        clipIDs.append(appended.clip.id)
    }
    let durations = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0.duration) })

    let moved = try TimelineEditor().applying(
        .move(clipID: clipIDs[2], toIndex: 0),
        to: timeline,
        assetDurations: durations
    )
    #expect(moved.tracks[0].clips.map(\.id) == [clipIDs[2], clipIDs[0], clipIDs[1]])
    #expect(moved.tracks[0].clips.map(\.timelineStart) == [
        .zero,
        StudioTime(seconds: 3),
        StudioTime(seconds: 4),
    ])

    let deleted = try TimelineEditor().applying(
        .delete(clipID: clipIDs[0]),
        to: moved,
        assetDurations: durations
    )
    #expect(deleted.tracks[0].clips.map(\.id) == [clipIDs[2], clipIDs[1]])
    #expect(deleted.tracks[0].clips[1].timelineStart == StudioTime(seconds: 3))
}

@Test func undoRedoIsBoundedAndRevisionMonotonic() throws {
    let asset = SourceAsset(
        kind: .screenVideo,
        relativePath: "sources/lesson.mov",
        duration: StudioTime(seconds: 10)
    )
    let empty = TimelineDocument(id: TimelineID(), projectID: ProjectID())
    let appended = try TimelineEditor().appending(asset: asset, to: empty)
    var history = TimelineEditHistory(timeline: appended.timeline)
    try history.record(
        command: appended.command,
        before: empty,
        after: appended.timeline,
        maximumEntries: 2
    )
    let durations = [asset.id: asset.duration]

    let trimmed = try TimelineEditor().performing(
        .trim(
            clipID: appended.clip.id,
            sourceRange: StudioTimeRange(start: .zero, duration: StudioTime(seconds: 8))
        ),
        on: appended.timeline,
        history: history,
        assetDurations: durations
    )
    var limitedHistory = trimmed.history
    try limitedHistory.record(
        command: .setEnabled(clipID: appended.clip.id, isEnabled: false),
        before: trimmed.timeline,
        after: try TimelineEditor().applying(
            .setEnabled(clipID: appended.clip.id, isEnabled: false),
            to: trimmed.timeline,
            assetDurations: durations
        ),
        maximumEntries: 2
    )
    #expect(limitedHistory.undoStack.count == 2)

    let disabled = try TimelineEditor().performing(
        .setEnabled(clipID: appended.clip.id, isEnabled: false),
        on: trimmed.timeline,
        history: trimmed.history,
        assetDurations: durations
    )
    let undone = try TimelineEditor().undoing(disabled.timeline, history: disabled.history)
    #expect(undone.timeline.revision == disabled.timeline.revision + 1)
    #expect(undone.timeline.tracks[0].clips[0].isEnabled)
    #expect(undone.history.canRedo)

    let redone = try TimelineEditor().redoing(undone.timeline, history: undone.history)
    #expect(redone.timeline.revision == undone.timeline.revision + 1)
    #expect(!redone.timeline.tracks[0].clips[0].isEnabled)
    #expect(redone.history.canUndo)
}

@Test func lockedTracksAndOutOfBoundsTrimsAreRejected() throws {
    let asset = SourceAsset(
        kind: .music,
        relativePath: "sources/music.m4a",
        duration: StudioTime(seconds: 5)
    )
    let empty = TimelineDocument(id: TimelineID(), projectID: ProjectID())
    let appended = try TimelineEditor().appending(asset: asset, to: empty)
    var locked = appended.timeline
    locked.tracks[0].isLocked = true

    #expect(throws: TimelineEditError.self) {
        try TimelineEditor().applying(
            .delete(clipID: appended.clip.id),
            to: locked,
            assetDurations: [asset.id: asset.duration]
        )
    }
    #expect(throws: TimelineEditError.self) {
        try TimelineEditor().applying(
            .trim(
                clipID: appended.clip.id,
                sourceRange: StudioTimeRange(
                    start: StudioTime(seconds: 4),
                    duration: StudioTime(seconds: 2)
                )
            ),
            to: appended.timeline,
            assetDurations: [asset.id: asset.duration]
        )
    }
}
