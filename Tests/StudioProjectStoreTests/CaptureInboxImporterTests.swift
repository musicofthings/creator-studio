import CryptoKit
import Foundation
import StudioCapture
import StudioDomain
@testable import StudioProjectStore
import Testing

@Test func importsValidatedCaptureAsImmutableProjectSource() async throws {
    let fixture = try CaptureImportFixture()
    defer { fixture.remove() }
    let session = try fixture.makeSession(state: .finalized)
    let project = try await fixture.repository.create(title: "Recovered Tutorial", intent: .tutorial)

    let result = try await fixture.importer.importSession(id: session.id, into: project.id)
    #expect(result.importedAssets.count == 1)
    #expect(result.wasRecovered == false)
    #expect(result.inboxAcknowledged)
    #expect(result.importedAssets.first?.captureSessionID == session.id)

    let loaded = try await fixture.repository.load(id: project.id)
    #expect(loaded.assets == result.importedAssets)
    let workspace = try await fixture.repository.loadWorkspace(id: project.id)
    #expect(workspace.timeline.tracks.map(\.kind) == [.screen])
    #expect(workspace.timeline.tracks[0].clips[0].assetID == result.importedAssets[0].id)
    #expect(workspace.timeline.tracks[0].clips[0].timelineStart == .zero)
    let packageURL = await fixture.repository.packageURL(for: project.id)
    let copiedURL = packageURL.appendingPathComponent(try #require(loaded.assets.first).relativePath)
    let copiedBefore = try Data(contentsOf: copiedURL)
    try Data("changed inbox file".utf8).write(to: session.mediaURL)
    #expect(try Data(contentsOf: copiedURL) == copiedBefore)
    let permissions = try FileManager.default.attributesOfItem(atPath: copiedURL.path)[.posixPermissions] as? NSNumber
    #expect(permissions?.intValue == 0o444)

    let discovered = await fixture.importer.discover()
    #expect(discovered.first(where: { $0.sessionID == session.id })?.status == .imported)
}

@Test func captureImportKeepsCrossSourceOffsetsOnInitialTracks() async throws {
    let fixture = try CaptureImportFixture()
    defer { fixture.remove() }
    let persistence = try fixture.persistence()

    let segments: [(CaptureSource, String, StudioTime)] = [
        (.screen, "screen-0000.mov", .zero),
        (.appAudio, "app-audio-0000.m4a", StudioTime(microseconds: 8000)),
        (.microphone, "microphone-0000.m4a", StudioTime(microseconds: 15000)),
    ]
    for (source, filename, start) in segments {
        let data = Data("\(source.rawValue)-segment".utf8)
        try data.write(to: persistence.directoryURL.appendingPathComponent("segments/\(filename)"))
        try persistence.commit(CaptureSegment(
            source: source,
            relativePath: "segments/\(filename)",
            sha256: fixture.sha256(data),
            byteCount: Int64(data.count),
            start: start,
            duration: StudioTime(seconds: 2)
        ))
    }
    try persistence.recordLifecycle(.finalized, state: .finalized)
    let project = try await fixture.repository.create(title: "Synchronized", intent: .tutorial)

    _ = try await fixture.importer.importSession(
        id: persistence.manifest.sessionID,
        into: project.id
    )
    let workspace = try await fixture.repository.loadWorkspace(id: project.id)

    #expect(workspace.timeline.tracks.map(\.kind) == [.screen, .appAudio, .microphone])
    #expect(workspace.timeline.tracks[0].clips[0].timelineStart == .zero)
    #expect(workspace.timeline.tracks[1].clips[0].timelineStart == StudioTime(microseconds: 8000))
    #expect(workspace.timeline.tracks[2].clips[0].timelineStart == StudioTime(microseconds: 15000))
    #expect(workspace.editHistory.undoStack.isEmpty)
}

@Test func importsCommittedMediaAfterInjectedInterruption() async throws {
    let fixture = try CaptureImportFixture()
    defer { fixture.remove() }
    let session = try fixture.makeSession(state: .interrupted)
    let project = try await fixture.repository.create(title: "Interrupted", intent: .tutorial)

    let discovered = await fixture.importer.discover()
    #expect(discovered.first(where: { $0.sessionID == session.id })?.status == .recovered)
    let result = try await fixture.importer.importSession(id: session.id, into: project.id)
    #expect(result.wasRecovered)
    #expect(result.importedAssets.count == 1)
}

@Test func cachedActiveSessionBecomesRecoverableAfterTheStaleThreshold() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("capture-stale-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let inbox = root.appendingPathComponent("CaptureInbox", isDirectory: true)
    let repository = FileProjectRepository(rootURL: root.appendingPathComponent("Projects"))
    let importer = CaptureInboxImporter(
        inboxRootURL: inbox,
        repository: repository,
        staleRecordingInterval: 45
    )
    let recordedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let persistence = try CaptureSessionPersistence(
        inboxRootURL: inbox,
        capabilities: CaptureCapabilities(
            supportedSources: [.screen],
            supportsBackgroundCapture: true,
            supportsPause: false
        ),
        now: recordedAt
    )
    let media = Data("committed-before-crash".utf8)
    let mediaURL = persistence.directoryURL.appendingPathComponent("segments/screen-0000.mov")
    try media.write(to: mediaURL)
    let digest = SHA256.hash(data: media).map { String(format: "%02x", $0) }.joined()
    try persistence.commit(
        CaptureSegment(
            source: .screen,
            relativePath: "segments/screen-0000.mov",
            sha256: digest,
            byteCount: Int64(media.count),
            start: .zero,
            duration: StudioTime(seconds: 2)
        ),
        at: recordedAt
    )

    let active = await importer.discover(now: recordedAt.addingTimeInterval(5))
    #expect(active.first?.status == .recording)
    let recovered = await importer.discover(now: recordedAt.addingTimeInterval(50))
    #expect(recovered.first?.status == .recovered)
}

@Test func importsCommittedMediaAfterStorageOrWriterFailure() async throws {
    for state in [CaptureManifestState.storageConstrained, .failed] {
        let fixture = try CaptureImportFixture()
        defer { fixture.remove() }
        let session = try fixture.makeSession(state: state)
        let project = try await fixture.repository.create(title: "Failure recovery", intent: .tutorial)
        let item = try #require(
            await fixture.importer.discover().first(where: { $0.sessionID == session.id })
        )
        #expect(item.canImport)
        let result = try await fixture.importer.importSession(id: session.id, into: project.id)
        #expect(result.wasRecovered)
        #expect(result.importedAssets.count == 1)
    }
}

@Test func rejectsTraversalEvenWhenOutsideFileMatchesManifest() async throws {
    let fixture = try CaptureImportFixture()
    defer { fixture.remove() }
    let persistence = try fixture.persistence()
    let outside = persistence.directoryURL.deletingLastPathComponent().appendingPathComponent("escape.mov")
    let data = Data("outside-session".utf8)
    try data.write(to: outside)
    try persistence.commit(CaptureSegment(
        source: .screen,
        relativePath: "../escape.mov",
        sha256: fixture.sha256(data),
        byteCount: Int64(data.count),
        start: .zero,
        duration: StudioTime(seconds: 1)
    ))
    try persistence.recordLifecycle(.finalized, state: .finalized)
    let project = try await fixture.repository.create(title: "Unsafe", intent: .tutorial)

    await #expect(throws: CaptureImportError.self) {
        _ = try await fixture.importer.importSession(
            id: persistence.manifest.sessionID,
            into: project.id
        )
    }
    #expect((try await fixture.repository.load(id: project.id)).assets.isEmpty)
}

@Test func rejectsSymlinkWithoutPartialImport() async throws {
    let fixture = try CaptureImportFixture()
    defer { fixture.remove() }
    let persistence = try fixture.persistence()
    let outside = fixture.root.appendingPathComponent("outside.mov")
    let data = Data("outside".utf8)
    try data.write(to: outside)
    let link = persistence.directoryURL.appendingPathComponent("segments/link.mov")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
    try persistence.commit(CaptureSegment(
        source: .screen,
        relativePath: "segments/link.mov",
        sha256: fixture.sha256(data),
        byteCount: Int64(data.count),
        start: .zero,
        duration: StudioTime(seconds: 1)
    ))
    try persistence.recordLifecycle(.finalized, state: .finalized)
    let project = try await fixture.repository.create(title: "Symlink", intent: .tutorial)

    await #expect(throws: CaptureImportError.self) {
        _ = try await fixture.importer.importSession(
            id: persistence.manifest.sessionID,
            into: project.id
        )
    }
    #expect((try await fixture.repository.load(id: project.id)).assets.isEmpty)
}

@Test func rejectsHashMismatchWithoutPartialImport() async throws {
    let fixture = try CaptureImportFixture()
    defer { fixture.remove() }
    let session = try fixture.makeSession(state: .finalized)
    let originalCount = try Data(contentsOf: session.mediaURL).count
    try Data(repeating: 0x78, count: originalCount).write(to: session.mediaURL)
    let project = try await fixture.repository.create(title: "Hash mismatch", intent: .tutorial)

    await #expect(throws: CaptureImportError.self) {
        _ = try await fixture.importer.importSession(id: session.id, into: project.id)
    }
    #expect((try await fixture.repository.load(id: project.id)).assets.isEmpty)
}

@Test func importsSoundSegmentsAndReportsTheUnsoundOne() async throws {
    let fixture = try CaptureImportFixture()
    defer { fixture.remove() }
    let persistence = try fixture.persistence()

    let good = Data("first-good-screen-segment".utf8)
    try good.write(to: persistence.directoryURL.appendingPathComponent("segments/screen-0000.mov"))
    try persistence.commit(CaptureSegment(
        source: .screen,
        relativePath: "segments/screen-0000.mov",
        sha256: fixture.sha256(good),
        byteCount: Int64(good.count),
        start: .zero,
        duration: StudioTime(seconds: 2)
    ))

    let bad = Data("second-segment-that-gets-truncated".utf8)
    let badURL = persistence.directoryURL.appendingPathComponent("segments/screen-0001.mov")
    try bad.write(to: badURL)
    try persistence.commit(CaptureSegment(
        source: .screen,
        relativePath: "segments/screen-0001.mov",
        sha256: fixture.sha256(bad),
        byteCount: Int64(bad.count),
        start: StudioTime(seconds: 2),
        duration: StudioTime(seconds: 2)
    ))
    try Data("truncated".utf8).write(to: badURL)
    try persistence.recordLifecycle(.finalized, state: .finalized)

    let project = try await fixture.repository.create(title: "Partial recovery", intent: .tutorial)
    let result = try await fixture.importer.importSession(
        id: persistence.manifest.sessionID,
        into: project.id
    )

    #expect(result.importedAssets.count == 1)
    #expect(result.skipped.count == 1)
    #expect(result.skipped.first?.relativePath == "segments/screen-0001.mov")
    #expect(try await fixture.repository.load(id: project.id).assets.count == 1)
}

@Test func deletesTheProjectPackageItRolledBack() async throws {
    let fixture = try CaptureImportFixture()
    defer { fixture.remove() }
    let project = try await fixture.repository.create(title: "Discarded", intent: .tutorial)
    #expect(try await fixture.repository.list().count == 1)

    try await fixture.repository.delete(id: project.id)
    #expect(try await fixture.repository.list().isEmpty)
    await #expect(throws: ProjectStoreError.self) {
        _ = try await fixture.repository.load(id: project.id)
    }
}

private struct CaptureImportFixture: Sendable {
    struct Session {
        let id: UUID
        let mediaURL: URL
    }

    let root: URL
    let inbox: URL
    let repository: FileProjectRepository
    let importer: CaptureInboxImporter

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-import-test-\(UUID().uuidString)", isDirectory: true)
        inbox = root.appendingPathComponent("CaptureInbox", isDirectory: true)
        let projects = root.appendingPathComponent("Projects", isDirectory: true)
        repository = FileProjectRepository(rootURL: projects)
        importer = CaptureInboxImporter(
            inboxRootURL: inbox,
            repository: repository,
            staleRecordingInterval: 0
        )
    }

    func persistence() throws -> CaptureSessionPersistence {
        try CaptureSessionPersistence(
            inboxRootURL: inbox,
            capabilities: CaptureCapabilities(
                supportedSources: [.screen, .appAudio, .microphone],
                supportsBackgroundCapture: true,
                supportsPause: true
            )
        )
    }

    func makeSession(state: CaptureManifestState) throws -> Session {
        let persistence = try persistence()
        let media = Data("validated-immutable-screen-segment".utf8)
        let mediaURL = persistence.directoryURL.appendingPathComponent("segments/screen-0000.mov")
        try media.write(to: mediaURL)
        try persistence.commit(CaptureSegment(
            source: .screen,
            relativePath: "segments/screen-0000.mov",
            sha256: sha256(media),
            byteCount: Int64(media.count),
            start: .zero,
            duration: StudioTime(seconds: 3)
        ))
        switch state {
        case .finalized:
            try persistence.recordLifecycle(.finalized, state: .finalized)
        case .interrupted:
            try persistence.recordLifecycle(
                .interrupted,
                state: .interrupted,
                detail: "Injected extension termination"
            )
        case .storageConstrained:
            try persistence.recordLifecycle(
                .storageConstrained,
                state: .storageConstrained,
                detail: "Injected low storage"
            )
        case .failed:
            try persistence.recordLifecycle(
                .failed,
                state: .failed,
                detail: "Injected writer failure"
            )
        default:
            try persistence.recordLifecycle(.failed, state: state)
        }
        return Session(id: persistence.manifest.sessionID, mediaURL: mediaURL)
    }

    func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
