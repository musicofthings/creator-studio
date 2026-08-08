import Foundation
import StudioDomain
import Testing

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
