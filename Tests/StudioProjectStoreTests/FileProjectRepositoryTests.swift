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
