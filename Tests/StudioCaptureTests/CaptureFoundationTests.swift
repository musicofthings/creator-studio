import CryptoKit
import Foundation
@testable import StudioCapture
import StudioDomain
import Testing

@Test func captureStateMachineCoversCaptureImportAndRecovery() async throws {
    let machine = CaptureStateMachine()
    try await machine.transition(to: .preparing)
    try await machine.transition(to: .ready)
    try await machine.transition(to: .recording)
    try await machine.transition(to: .stopping)
    try await machine.transition(to: .finalized)
    try await machine.transition(to: .importing)
    try await machine.transition(to: .finalized)
    #expect(await machine.state == .finalized)

    let interrupted = CaptureStateMachine()
    try await interrupted.transition(to: .preparing)
    try await interrupted.transition(to: .ready)
    try await interrupted.transition(to: .recording)
    try await interrupted.transition(to: .recovered)
    try await interrupted.transition(to: .importing)
    #expect(await interrupted.state == .importing)
}

@Test func captureStateMachineRejectsUnsafeTransition() async throws {
    let machine = CaptureStateMachine()
    try await machine.transition(to: .preparing)
    await #expect(throws: CaptureError.self) {
        try await machine.transition(to: .recording)
    }
}

@Test func preflightReportsLowStorageAndInjectedFailures() {
    let capabilities = CaptureCapabilities(
        supportedSources: [.screen, .microphone],
        supportsBackgroundCapture: true,
        supportsPause: false
    )
    let evaluator = CapturePreflightEvaluator(
        minimumReserveBytes: 1000,
        estimatedBytesPerMinute: 100
    )

    let lowStorage = evaluator.evaluate(CapturePreflightInput(
        capabilities: capabilities,
        requestedSources: [.screen],
        appGroupAvailable: true,
        availableStorageBytes: 999,
        thermalState: .nominal
    ))
    #expect(lowStorage.status == .storageConstrained)

    let blocked = evaluator.evaluate(CapturePreflightInput(
        capabilities: capabilities,
        requestedSources: [.screen, .microphone, .camera],
        appGroupAvailable: false,
        availableStorageBytes: 10000,
        thermalState: .critical,
        microphonePermissionDenied: true
    ))
    #expect(blocked.status == .failed)
    #expect(blocked.blockers.count == 4)

    let withoutMicrophone = evaluator.evaluate(CapturePreflightInput(
        capabilities: capabilities,
        requestedSources: [.screen],
        appGroupAvailable: true,
        availableStorageBytes: 10000,
        thermalState: .nominal,
        microphonePermissionDenied: true
    ))
    #expect(withoutMicrophone.status == .ready)
}

@Test func desktopCaptureSizingPreservesAspectAndProducesEvenBoundedDimensions() {
    let sizing = DesktopCaptureSizing()

    #expect(sizing.dimensions(
        pointWidth: 1728,
        pointHeight: 1117,
        pointPixelScale: 2
    ) == CapturePixelDimensions(width: 3340, height: 2160))

    #expect(sizing.dimensions(
        pointWidth: 2560,
        pointHeight: 1440,
        pointPixelScale: 2
    ) == CapturePixelDimensions(width: 3840, height: 2160))

    #expect(sizing.dimensions(
        pointWidth: 0,
        pointHeight: 1080,
        pointPixelScale: 2
    ) == nil)
}

@Test func journalReplaysCommitMissingFromAtomicManifest() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = try CaptureSessionPersistence(
        inboxRootURL: root,
        capabilities: CaptureCapabilities(
            supportedSources: [.screen],
            supportsBackgroundCapture: true,
            supportsPause: false
        )
    )
    let staleManifest = try Data(contentsOf: persistence.directoryURL.appendingPathComponent("manifest.json"))
    let mediaURL = persistence.directoryURL.appendingPathComponent("segments/screen-0000.mov")
    let media = Data("immutable-capture-segment".utf8)
    try media.write(to: mediaURL)
    let segment = CaptureSegment(
        source: .screen,
        relativePath: "segments/screen-0000.mov",
        sha256: sha256(media),
        byteCount: Int64(media.count),
        start: .zero,
        duration: StudioTime(seconds: 2)
    )
    try persistence.commit(segment)

    // Models a process death after the flushed journal append but before manifest replacement.
    try staleManifest.write(
        to: persistence.directoryURL.appendingPathComponent("manifest.json"),
        options: [.atomic]
    )
    let recovered = try CaptureProtocolReader().loadSession(at: persistence.directoryURL)
    #expect(recovered.manifest.files == [segment])
    #expect(recovered.journalRecoveredSegmentCount == 1)
    #expect(recovered.lastSequence == 2)
}

@Test func interruptedManifestPreservesCommittedSegments() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = try CaptureSessionPersistence(
        inboxRootURL: root,
        capabilities: CaptureCapabilities(
            supportedSources: [.screen],
            supportsBackgroundCapture: true,
            supportsPause: false
        )
    )
    let media = Data("committed-before-interruption".utf8)
    let mediaURL = persistence.directoryURL.appendingPathComponent("segments/screen-0000.mov")
    try media.write(to: mediaURL)
    try persistence.commit(CaptureSegment(
        source: .screen,
        relativePath: "segments/screen-0000.mov",
        sha256: sha256(media),
        byteCount: Int64(media.count),
        start: .zero,
        duration: StudioTime(seconds: 1)
    ))
    try persistence.recordLifecycle(
        .interrupted,
        state: .interrupted,
        detail: "Injected termination"
    )

    let recovered = try CaptureProtocolReader().loadSession(at: persistence.directoryURL)
    #expect(recovered.manifest.state == .interrupted)
    #expect(recovered.manifest.files.count == 1)
    #expect(recovered.manifest.failureReason == "Injected termination")
    let names = try FileManager.default.contentsOfDirectory(atPath: persistence.directoryURL.path)
    #expect(!names.contains(where: { $0.hasPrefix(".manifest") || $0.hasSuffix(".tmp") }))
}

@Test func protocolReaderRejectsJournalPathEscapeBeforeReading() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = try CaptureSessionPersistence(
        inboxRootURL: root,
        capabilities: CaptureCapabilities(
            supportedSources: [.screen],
            supportsBackgroundCapture: true,
            supportsPause: false
        )
    )
    var manifest = persistence.manifest
    manifest.eventsRelativePath = "../events.jsonl"
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(manifest).write(
        to: persistence.directoryURL.appendingPathComponent("manifest.json"),
        options: [.atomic]
    )

    #expect(throws: CaptureInboxProtocolError.self) {
        _ = try CaptureProtocolReader().loadSession(at: persistence.directoryURL)
    }
}

@Test func readerAcceptsANewerWriterUntilTheReaderVersionSaysOtherwise() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = try CaptureSessionPersistence(
        inboxRootURL: root,
        capabilities: CaptureCapabilities(
            supportedSources: [.screen],
            supportsBackgroundCapture: true,
            supportsPause: false
        )
    )
    let manifestURL = persistence.directoryURL.appendingPathComponent("manifest.json")

    // A session written by a newer build stays recoverable: stranding it would
    // lose exactly the media this reader exists to rescue.
    try rewriteManifest(at: manifestURL) { object in
        object["schemaVersion"] = 2
        object["minimumReaderVersion"] = 1
    }
    let recovered = try CaptureProtocolReader().loadSession(at: persistence.directoryURL)
    #expect(recovered.manifest.sessionID == persistence.manifest.sessionID)

    try rewriteManifest(at: manifestURL) { object in
        object["minimumReaderVersion"] = 2
    }
    #expect(throws: CaptureInboxProtocolError.self) {
        _ = try CaptureProtocolReader().loadSession(at: persistence.directoryURL)
    }
}

@Test func manifestRecordsOnlyTheSourcesThatDeliveredMedia() throws {
    let root = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let persistence = try CaptureSessionPersistence(
        inboxRootURL: root,
        capabilities: CaptureCapabilities(
            supportedSources: [.screen, .appAudio, .microphone],
            supportsBackgroundCapture: true,
            supportsPause: false
        )
    )
    #expect(persistence.manifest.capabilities.microphone)
    #expect(persistence.manifest.observedSources.isEmpty)

    try persistence.recordObservedSource(.screen)
    try persistence.recordObservedSource(.screen)
    try persistence.recordObservedSource(.appAudio)

    let recovered = try CaptureProtocolReader().loadSession(at: persistence.directoryURL)
    #expect(recovered.manifest.observedSources == [.screen, .appAudio])
}

@Test func identifiersMatchGeneratorConfiguration() throws {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let data = try Data(contentsOf: root.appendingPathComponent("Configuration/identifiers.json"))
    let identifiers = try JSONDecoder().decode([String: String].self, from: data)

    #expect(identifiers["appGroupID"] == CaptureInboxLocation.appGroupID)
    #expect(identifiers["appBundleID"] == CaptureInboxLocation.appBundleID)
    #expect(identifiers["broadcastExtensionBundleID"] == CaptureInboxLocation.broadcastExtensionBundleID)
}

private struct ManifestFixtureError: Error {}

private func rewriteManifest(at url: URL, _ mutate: (inout [String: Any]) -> Void) throws {
    let data = try Data(contentsOf: url)
    guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ManifestFixtureError()
    }
    mutate(&object)
    try JSONSerialization
        .data(withJSONObject: object, options: [.sortedKeys])
        .write(to: url, options: [.atomic])
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("capture-foundation-test-\(UUID().uuidString)", isDirectory: true)
}

private func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
