import Foundation
import StudioDomain
@testable import StudioProjectStore
import Testing

@Test func createsListsAndReloadsPortableProject() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("project-store-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let repository = FileProjectRepository(rootURL: root)
    let created = try await repository.create(title: "Demo", intent: .tutorial)
    let loaded = try await repository.load(id: created.id)
    let listed = try await repository.list()

    #expect(loaded == created)
    #expect(listed.count == 1)
    #expect(listed.first?.id == created.id)
    #expect(
        FileManager.default.fileExists(
            atPath: await repository.packageURL(for: created.id).appendingPathComponent("timeline.json").path
        )
    )
    #expect(
        FileManager.default.fileExists(
            atPath: await repository.packageURL(for: created.id)
                .appendingPathComponent("timeline-history.json").path
        )
    )
}

@Test func rejectsEmptyProjectTitle() async {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("project-store-test-\(UUID().uuidString)", isDirectory: true)
    let repository = FileProjectRepository(rootURL: root)

    await #expect(throws: ProjectStoreError.self) {
        _ = try await repository.create(title: "   ", intent: .social)
    }
}

@Test func importsMediaAsAnImmutableSourceAndTimelineClip() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("project-media-import-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("lesson.mov")
    let sourceData = Data("local-first-media-source".utf8)
    try sourceData.write(to: source)

    let repository = FileProjectRepository(rootURL: root.appendingPathComponent("Projects"))
    let project = try await repository.create(title: "Imported lesson", intent: .tutorial)
    let result = try await repository.importMedia(
        from: source,
        descriptor: MediaImportDescriptor(
            kind: .screenVideo,
            duration: StudioTime(seconds: 6),
            pixelSize: PixelSize(width: 1920, height: 1080),
            originalFilename: "lesson.mov"
        ),
        into: project.id
    )

    #expect(result.workspace.project.assets == [result.importedAsset])
    #expect(result.importedAsset.originalFilename == "lesson.mov")
    #expect(result.importedAsset.byteCount == Int64(sourceData.count))
    #expect(result.importedAsset.contentHash?.hasPrefix("sha256:") == true)
    #expect(result.appendedClip.assetID == result.importedAsset.id)
    #expect(result.workspace.timeline.tracks.first?.clips == [result.appendedClip])
    #expect(try Data(contentsOf: source) == sourceData)

    let summary = try #require((try await repository.list()).first)
    #expect(summary.recordings.count == 1)
    #expect(summary.recordings[0].title == "lesson.mov")
    #expect(summary.recordings[0].assetCount == 1)
    #expect(summary.recordings[0].duration == StudioTime(seconds: 6))

    let importedURL = try await repository.assetURL(
        projectID: project.id,
        assetID: result.importedAsset.id
    )
    #expect(importedURL != source)
    #expect(try Data(contentsOf: importedURL) == sourceData)
    let attributes = try FileManager.default.attributesOfItem(atPath: importedURL.path)
    let permissions = try #require(attributes[.posixPermissions] as? NSNumber)
    #expect(permissions.intValue & 0o222 == 0)

    let reloaded = try await repository.loadWorkspace(id: project.id)
    #expect(reloaded == result.workspace)
}

@Test func persistsTimelineCommandsAndUndoRedoAcrossReloads() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("project-edit-history-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("lesson.mov")
    try Data("immutable-edit-source".utf8).write(to: source)

    let repository = FileProjectRepository(rootURL: root.appendingPathComponent("Projects"))
    let project = try await repository.create(title: "Editable lesson", intent: .tutorial)
    let imported = try await repository.importMedia(
        from: source,
        descriptor: MediaImportDescriptor(
            kind: .screenVideo,
            duration: StudioTime(seconds: 10),
            pixelSize: PixelSize(width: 1920, height: 1080)
        ),
        into: project.id
    )
    let clipID = imported.appendedClip.id
    let edited = try await repository.applyTimelineCommand(
        .trim(
            clipID: clipID,
            sourceRange: StudioTimeRange(
                start: StudioTime(seconds: 1),
                duration: StudioTime(seconds: 6)
            )
        ),
        to: project.id
    )

    #expect(edited.timeline.revision == 2)
    #expect(edited.timeline.tracks[0].clips[0].sourceRange.duration == StudioTime(seconds: 6))
    #expect(edited.editHistory.undoStack.count == 2)
    #expect(!edited.editHistory.canRedo)
    #expect(try await repository.loadWorkspace(id: project.id) == edited)

    let undone = try await repository.undoTimelineEdit(projectID: project.id)
    #expect(undone.timeline.revision == 3)
    #expect(undone.timeline.tracks[0].clips[0].sourceRange.duration == StudioTime(seconds: 10))
    #expect(undone.editHistory.canRedo)
    #expect(undone.project.assets == [imported.importedAsset])

    let redone = try await repository.redoTimelineEdit(projectID: project.id)
    #expect(redone.timeline.revision == 4)
    #expect(redone.timeline.tracks[0].clips[0].sourceRange.duration == StudioTime(seconds: 6))
    #expect(!redone.editHistory.canRedo)
    #expect(try await repository.loadWorkspace(id: project.id) == redone)
}

@Test func rejectsUnsupportedMediaWithoutChangingTheProject() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("project-media-reject-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("payload.exe")
    try Data("not media".utf8).write(to: source)

    let repository = FileProjectRepository(rootURL: root.appendingPathComponent("Projects"))
    let project = try await repository.create(title: "Safe project", intent: .tutorial)

    await #expect(throws: ProjectMediaImportError.self) {
        try await repository.importMedia(
            from: source,
            descriptor: MediaImportDescriptor(
                kind: .screenVideo,
                duration: StudioTime(seconds: 1)
            ),
            into: project.id
        )
    }

    let workspace = try await repository.loadWorkspace(id: project.id)
    #expect(workspace.project.assets.isEmpty)
    #expect(workspace.timeline.tracks.isEmpty)
}

@Test func persistsInspectedMetadataAndUsesAnAssetScopedRebuildableCache() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("project-media-metadata-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let source = root.appendingPathComponent("portrait.mov")
    try Data("immutable-placeholder".utf8).write(to: source)

    let repository = FileProjectRepository(rootURL: root.appendingPathComponent("Projects"))
    let project = try await repository.create(title: "Metadata", intent: .tutorial)
    let imported = try await repository.importMedia(
        from: source,
        descriptor: MediaImportDescriptor(
            kind: .screenVideo,
            duration: StudioTime(seconds: 3)
        ),
        into: project.id
    )
    let metadata = SourceMediaMetadata(
        naturalPixelSize: PixelSize(width: 1920, height: 1080),
        preferredTransform: SourceAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 1080, ty: 0),
        sourceStart: StudioTime(microseconds: -20000),
        sourceDuration: StudioTime(seconds: 3),
        nominalFrameRate: 30,
        estimatedFrameRate: 29.97,
        isVariableFrameRate: true,
        audioFormat: SourceAudioFormat(sampleRate: 48000, channelCount: 2)
    )

    let updated = try await repository.updateMediaMetadata(
        metadata,
        displayPixelSize: PixelSize(width: 1080, height: 1920),
        projectID: project.id,
        assetID: imported.importedAsset.id
    )
    let location = try await repository.assetIngestLocation(
        projectID: project.id,
        assetID: imported.importedAsset.id
    )

    #expect(updated.project.assets[0].mediaMetadata == metadata)
    #expect(updated.project.assets[0].pixelSize == PixelSize(width: 1080, height: 1920))
    #expect(location.sourceURL == (try await repository.assetURL(
        projectID: project.id,
        assetID: imported.importedAsset.id
    )))
    #expect(location.cacheDirectoryURL.lastPathComponent == imported.importedAsset.id.description)
    #expect(location.cacheDirectoryURL.deletingLastPathComponent().lastPathComponent == "cache")

    let generatedProduct = location.cacheDirectoryURL.appendingPathComponent("proxy.mov")
    try Data("rebuildable proxy".utf8).write(to: generatedProduct)
    let sourceURL = try await repository.assetURL(projectID: project.id, assetID: imported.importedAsset.id)
    let sourceBefore = try Data(contentsOf: sourceURL)

    try await repository.clearRebuildableCache(projectID: project.id)

    let cacheRoot = location.cacheDirectoryURL.deletingLastPathComponent()
    #expect(FileManager.default.fileExists(atPath: cacheRoot.path))
    #expect(try FileManager.default.contentsOfDirectory(atPath: cacheRoot.path).isEmpty)
    #expect(try Data(contentsOf: sourceURL) == sourceBefore)
}

@Test func mergesAnotherProjectIntoTheEndOfTheMasterTimeline() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("project-merge-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let destinationSource = root.appendingPathComponent("destination.mov")
    let sourceVideo = root.appendingPathComponent("source.mov")
    let sourceAudio = root.appendingPathComponent("source.m4a")
    try Data("destination-source".utf8).write(to: destinationSource)
    try Data("source-video".utf8).write(to: sourceVideo)
    try Data("source-audio".utf8).write(to: sourceAudio)

    let repository = FileProjectRepository(rootURL: root.appendingPathComponent("Projects"))
    let destination = try await repository.create(title: "Master", intent: .tutorial)
    let source = try await repository.create(title: "Second recording", intent: .tutorial)
    _ = try await repository.importMedia(
        from: destinationSource,
        descriptor: MediaImportDescriptor(kind: .screenVideo, duration: StudioTime(seconds: 5)),
        into: destination.id
    )
    _ = try await repository.importMedia(
        from: sourceVideo,
        descriptor: MediaImportDescriptor(kind: .screenVideo, duration: StudioTime(seconds: 3)),
        into: source.id
    )
    _ = try await repository.importMedia(
        from: sourceAudio,
        descriptor: MediaImportDescriptor(kind: .microphoneAudio, duration: StudioTime(seconds: 3)),
        into: source.id
    )

    let merged = try await repository.mergeProject(source.id, into: destination.id)
    let screen = try #require(merged.workspace.timeline.tracks.first(where: { $0.kind == .screen }))
    let microphone = try #require(merged.workspace.timeline.tracks.first(where: { $0.kind == .microphone }))

    #expect(merged.importedAssets.count == 2)
    #expect(screen.clips.count == 2)
    #expect(screen.clips[1].timelineStart == StudioTime(seconds: 5))
    #expect(microphone.clips.count == 1)
    #expect(microphone.clips[0].timelineStart == StudioTime(seconds: 5))
    #expect(try Data(contentsOf: sourceVideo) == Data("source-video".utf8))
    #expect(try await repository.loadWorkspace(id: destination.id) == merged.workspace)
}
