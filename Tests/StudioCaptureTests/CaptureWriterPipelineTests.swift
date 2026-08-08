import CryptoKit
import Foundation
@testable import StudioCapture
import StudioDomain
import Testing

@Suite(.serialized) struct CaptureWriterPipelineSuite {
    @Test func pipelineDropsSamplesInsteadOfEndingTheSessionUnderBackpressure() throws {
        let harness = try PipelineHarness(pendingLimits: [.screen: 64])
        defer { harness.remove() }
        harness.writers.acceptEveryOtherSample = true

        for step in 0 ..< 20 {
            harness.pipeline.enqueue(FakeSample(seconds: Double(step) * 0.1), source: .screen)
        }
        harness.drain()

        #expect(harness.pipeline.dropCounts[.screen] == 10)
        #expect(harness.persistence.manifest.state == .recording)

        #expect(harness.pipeline.finishSynchronously(timeout: 30))
        #expect(harness.persistence.manifest.state == .finalized)
        #expect(harness.terminalStates.isEmpty)
    }

    @Test func pipelineDropsSamplesInsteadOfEndingTheSessionWhenTheQueueIsFull() throws {
        let harness = try PipelineHarness(pendingLimits: [.screen: 2])
        defer { harness.remove() }
        harness.queue.suspend()

        for step in 0 ..< 25 {
            harness.pipeline.enqueue(FakeSample(seconds: Double(step) * 0.1), source: .screen)
        }
        harness.queue.resume()
        harness.drain()

        // Two in flight, the rest dropped — the bound is what keeps a broadcast
        // extension under its memory ceiling.
        #expect(harness.pipeline.dropCounts[.screen] == 23)
        #expect(harness.persistence.manifest.state == .recording)
        #expect(harness.terminalStates.isEmpty)
    }

    @Test func pipelineJournalsDropsWithoutFloodingTheJournal() throws {
        let harness = try PipelineHarness(
            pendingLimits: [.screen: 64],
            storageCheckInterval: 1
        )
        defer { harness.remove() }
        harness.writers.acceptEveryOtherSample = true

        for step in 0 ..< 30 {
            harness.pipeline.enqueue(FakeSample(seconds: Double(step) * 0.1), source: .screen)
        }
        harness.drain()

        // Below the batch threshold nothing is journaled yet.
        #expect(try harness.journalEvents(ofKind: .warning).isEmpty)

        #expect(harness.pipeline.finishSynchronously(timeout: 30))
        let warnings = try harness.journalEvents(ofKind: .warning)
        #expect(warnings.count == 1)
        #expect(warnings.first?.detail?.contains("screen: 15") == true)
    }

    @Test func pipelineRotatesSegmentsAtTheDurationLimit() throws {
        let harness = try PipelineHarness(segmentDuration: 1)
        defer { harness.remove() }

        for step in 0 ..< 7 {
            harness.pipeline.enqueue(FakeSample(seconds: Double(step) * 0.5), source: .screen)
        }
        harness.drain()
        #expect(harness.pipeline.finishSynchronously(timeout: 30))

        // 0.0–0.5 | 1.0–1.5 | 2.0–2.5 | 3.0
        #expect(harness.persistence.manifest.files.count == 4)
        let recovered = try CaptureProtocolReader().loadSession(at: harness.persistence.directoryURL)
        #expect(recovered.manifest.files.count == 4)
        #expect(recovered.manifest.state == .finalized)
    }

    @Test func pipelineTreatsAWriterFailureAsTerminalAndKeepsCommittedSegments() throws {
        let harness = try PipelineHarness(segmentDuration: 1)
        defer { harness.remove() }

        harness.pipeline.enqueue(FakeSample(seconds: 0), source: .screen)
        harness.pipeline.enqueue(FakeSample(seconds: 0.5), source: .screen)
        harness.drain()

        harness.writers.failNextAppend = true
        harness.pipeline.enqueue(FakeSample(seconds: 1.5), source: .screen)
        harness.drain()
        harness.waitForTerminal()

        #expect(harness.terminalStates == [.failed])
        #expect(harness.persistence.manifest.state == .failed)
        // The segment that was open when the writer failed is still committed.
        #expect(harness.persistence.manifest.files.count == 1)
        #expect(harness.persistence.manifest.failureReason?.contains("injected") == true)
    }

    @Test func pipelineStopsBeforeExhaustingTheProtectedStorageReserve() throws {
        let harness = try PipelineHarness(
            storageCheckInterval: 2,
            protectedStorageReserve: 1000,
            availableCapacity: 999
        )
        defer { harness.remove() }

        harness.pipeline.enqueue(FakeSample(seconds: 0), source: .screen)
        harness.pipeline.enqueue(FakeSample(seconds: 0.1), source: .screen)
        harness.drain()
        harness.waitForTerminal()

        #expect(harness.terminalStates == [.storageConstrained])
        #expect(harness.persistence.manifest.state == .storageConstrained)
        #expect(harness.persistence.manifest.files.count == 1)
    }

    @Test func pipelineRejectsUnusableSampleTiming() throws {
        let harness = try PipelineHarness()
        defer { harness.remove() }

        harness.pipeline.enqueue(FakeSample(seconds: .nan), source: .screen)
        harness.drain()
        harness.waitForTerminal()

        #expect(harness.terminalStates == [.failed])
        #expect(harness.persistence.manifest.state == .failed)
    }

    @Test func pipelineRecordsOnlyTheSourcesThatDelivered() throws {
        let harness = try PipelineHarness()
        defer { harness.remove() }

        harness.pipeline.enqueue(FakeSample(seconds: 0), source: .screen)
        harness.pipeline.enqueue(FakeSample(seconds: 0.1), source: .appAudio)
        harness.pipeline.enqueue(FakeSample(seconds: 0.2), source: .screen)
        harness.drain()
        #expect(harness.pipeline.finishSynchronously(timeout: 30))

        #expect(harness.persistence.manifest.observedSources == [.screen, .appAudio])
        #expect(harness.persistence.manifest.capabilities.microphone)
    }

    @Test func finishSynchronouslyWaitsForEverySegmentToCommit() throws {
        let harness = try PipelineHarness()
        defer { harness.remove() }
        harness.writers.finishDelay = 0.2

        harness.pipeline.enqueue(FakeSample(seconds: 0), source: .screen)
        harness.pipeline.enqueue(FakeSample(seconds: 0.1), source: .appAudio)
        harness.drain()

        #expect(harness.pipeline.finishSynchronously(timeout: 30))
        #expect(harness.persistence.manifest.files.count == 2)
        #expect(harness.persistence.manifest.state == .finalized)
        #expect(harness.persistence.manifest.duration == StudioTime(seconds: 0.1))

        // Finishing twice must not stall or re-run the terminal path.
        #expect(harness.pipeline.finishSynchronously(timeout: 30))
        #expect(harness.terminalStates.isEmpty)
    }

    @Test func interruptedFinishCommitsOpenSegmentsAndRecordsRecoveryState() throws {
        let harness = try PipelineHarness()
        defer { harness.remove() }

        harness.pipeline.enqueue(FakeSample(seconds: 0), source: .screen)
        harness.pipeline.enqueue(FakeSample(seconds: 0.25), source: .appAudio)
        harness.drain()

        #expect(harness.pipeline.interruptSynchronously(
            detail: "ScreenCaptureKit stream stopped unexpectedly.",
            timeout: 30
        ))
        #expect(harness.persistence.manifest.state == .interrupted)
        #expect(harness.persistence.manifest.files.count == 2)
        #expect(harness.persistence.manifest.failureReason == "ScreenCaptureKit stream stopped unexpectedly.")
        #expect(try harness.journalEvents(ofKind: .interrupted).count == 1)
    }

    @Test func samplesArrivingAfterFinishAreIgnored() throws {
        let harness = try PipelineHarness()
        defer { harness.remove() }

        harness.pipeline.enqueue(FakeSample(seconds: 0), source: .screen)
        harness.drain()
        #expect(harness.pipeline.finishSynchronously(timeout: 30))

        harness.pipeline.enqueue(FakeSample(seconds: 1), source: .screen)
        harness.drain()

        #expect(harness.persistence.manifest.files.count == 1)
        #expect(harness.persistence.manifest.state == .finalized)
    }
}

// MARK: - Harness

private struct FakeSample: Sendable {
    var seconds: Double
}

private enum FakeWriterError: Error, CustomStringConvertible {
    case injectedAppendFailure

    var description: String { "injected append failure" }
}

/// Shared, lock-guarded control surface for the fake writers a test creates.
private final class FakeWriterControl: @unchecked Sendable {
    let completionQueue = DispatchQueue(label: "fake-writer-completion")
    private let lock = NSLock()
    private var _acceptEveryOtherSample = false
    private var _failNextAppend = false
    private var _finishDelay: TimeInterval = 0
    private var _appendCallCount = 0

    var acceptEveryOtherSample: Bool {
        get { lock.withLock { _acceptEveryOtherSample } }
        set { lock.withLock { _acceptEveryOtherSample = newValue } }
    }

    var failNextAppend: Bool {
        get { lock.withLock { _failNextAppend } }
        set { lock.withLock { _failNextAppend = newValue } }
    }

    var finishDelay: TimeInterval {
        get { lock.withLock { _finishDelay } }
        set { lock.withLock { _finishDelay = newValue } }
    }

    /// Returns true when the writer should accept this sample.
    func shouldAccept() throws -> Bool {
        try lock.withLock {
            if _failNextAppend {
                _failNextAppend = false
                throw FakeWriterError.injectedAppendFailure
            }
            _appendCallCount += 1
            return _acceptEveryOtherSample ? _appendCallCount.isMultiple(of: 2) : true
        }
    }
}

private final class FakeSegmentWriter: CaptureSegmentWriting, @unchecked Sendable {
    typealias Sample = FakeSample

    private let source: CaptureSource
    private let index: Int
    private let directoryURL: URL
    private let anchorSeconds: Double
    private let startSeconds: Double
    private let control: FakeWriterControl
    private let lock = NSLock()
    private var lastSeconds: Double
    private var accepted = 0

    init(
        source: CaptureSource,
        index: Int,
        directoryURL: URL,
        firstSample: FakeSample,
        anchorSeconds: Double,
        control: FakeWriterControl
    ) {
        self.source = source
        self.index = index
        self.directoryURL = directoryURL
        self.anchorSeconds = anchorSeconds
        self.control = control
        startSeconds = firstSample.seconds
        lastSeconds = firstSample.seconds
    }

    func shouldRotate(before presentationSeconds: Double, limit: TimeInterval) -> Bool {
        lock.withLock { accepted > 0 && presentationSeconds - startSeconds >= limit }
    }

    func append(_ sample: FakeSample) throws -> Bool {
        guard try control.shouldAccept() else { return false }
        lock.withLock {
            accepted += 1
            lastSeconds = max(lastSeconds, sample.seconds)
        }
        return true
    }

    func finish(completion: @escaping @Sendable (Result<CaptureSegment, Error>) -> Void) {
        let delay = control.finishDelay
        let (start, last, count) = lock.withLock { (startSeconds, lastSeconds, accepted) }
        let relativePath = "segments/\(source.rawValue)-\(String(format: "%04d", index)).bin"
        let url = directoryURL.appendingPathComponent(relativePath)

        // Complete inline unless a test is specifically exercising a slow
        // finish. Hopping to a shared queue would make these tests depend on the
        // global pool having a spare thread, which it may not while other tests
        // are blocked in `finishSynchronously`.
        let deliver = { @Sendable in
            do {
                guard count > 0 else {
                    throw FakeWriterError.injectedAppendFailure
                }
                let payload = Data("segment-\(relativePath)-\(count)".utf8)
                try payload.write(to: url, options: [.atomic])
                completion(.success(CaptureSegment(
                    source: self.source,
                    relativePath: relativePath,
                    sha256: SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined(),
                    byteCount: Int64(payload.count),
                    start: StudioTime(seconds: max(0, start - self.anchorSeconds)),
                    duration: StudioTime(seconds: max(0, last - start))
                )))
            } catch {
                completion(.failure(error))
            }
        }
        if delay > 0 {
            control.completionQueue.asyncAfter(deadline: .now() + delay, execute: deliver)
        } else {
            deliver()
        }
    }
}

private final class PipelineHarness: @unchecked Sendable {
    let root: URL
    let persistence: CaptureSessionPersistence
    let queue: DispatchQueue
    let writers = FakeWriterControl()
    private(set) var pipeline: CaptureWriterPipeline<FakeSample>!

    private let terminalLock = NSLock()
    private let terminalSignal = DispatchSemaphore(value: 0)
    private var _terminalStates: [CaptureManifestState] = []

    var terminalStates: [CaptureManifestState] {
        terminalLock.withLock { _terminalStates }
    }

    init(
        pendingLimits: [CaptureSource: Int] = [.screen: 64, .appAudio: 64, .microphone: 64],
        segmentDuration: TimeInterval = 10,
        storageCheckInterval: Int = 120,
        protectedStorageReserve: Int64 = 1_000_000_000,
        availableCapacity: Int64? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("capture-pipeline-test-\(UUID().uuidString)", isDirectory: true)
        persistence = try CaptureSessionPersistence(
            inboxRootURL: root,
            capabilities: CaptureCapabilities(
                supportedSources: [.screen, .appAudio, .microphone],
                supportsBackgroundCapture: true,
                supportsPause: true
            )
        )
        queue = DispatchQueue(label: "capture-pipeline-test-\(UUID().uuidString)")

        let control = writers
        pipeline = CaptureWriterPipeline(
            persistence: persistence,
            queue: queue,
            pendingLimits: pendingLimits,
            segmentDuration: segmentDuration,
            protectedStorageReserve: protectedStorageReserve,
            storageCheckInterval: storageCheckInterval,
            timing: { $0.seconds.isFinite ? $0.seconds : nil },
            makeWriter: { source, index, directoryURL, firstSample, anchorSeconds in
                FakeSegmentWriter(
                    source: source,
                    index: index,
                    directoryURL: directoryURL,
                    firstSample: firstSample,
                    anchorSeconds: anchorSeconds,
                    control: control
                )
            },
            capacityProvider: { _ in availableCapacity },
            terminalHandler: { [weak self] state, _ in
                guard let self else { return }
                terminalLock.withLock { _terminalStates.append(state) }
                terminalSignal.signal()
            }
        )
    }

    /// Blocks until everything already enqueued has been processed.
    func drain() {
        queue.sync {}
    }

    func waitForTerminal() {
        _ = terminalSignal.wait(timeout: .now() + 30)
    }

    func journalEvents(ofKind kind: CaptureJournalEventKind) throws -> [CaptureJournalEvent] {
        let url = persistence.directoryURL.appendingPathComponent(persistence.manifest.eventsRelativePath)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try Data(contentsOf: url)
            .split(separator: 0x0A, omittingEmptySubsequences: true)
            .compactMap { try? decoder.decode(CaptureJournalEvent.self, from: Data($0)) }
            .filter { $0.kind == kind }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
