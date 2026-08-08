import Foundation
import StudioDomain

public enum CaptureWriterPipelineError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidSampleTiming(CaptureSource)
    case storageConstrained

    public var description: String {
        switch self {
        case .invalidSampleTiming(let source):
            "The capture backend delivered a \(source.rawValue) sample with invalid timing."
        case .storageConstrained:
            "Recording stopped before the protected storage reserve was exhausted."
        }
    }
}

/// One media segment being written. The pipeline owns rotation and lifecycle;
/// the conforming type owns the encoder.
public protocol CaptureSegmentWriting<Sample>: AnyObject {
    associatedtype Sample

    func shouldRotate(before presentationSeconds: Double, limit: TimeInterval) -> Bool

    /// Returns `false` when the encoder could not accept the sample in real time
    /// and it was dropped. Throws only when the writer has genuinely failed.
    func append(_ sample: Sample) throws -> Bool

    func finish(completion: @escaping @Sendable (Result<CaptureSegment, Error>) -> Void)
}

/// Queue accounting, segment rotation, storage guarding, drop policy, and
/// finish ordering for a capture session — the failure-prone half of recording,
/// with no dependency on any particular media framework so it can be tested
/// without a device.
///
/// `Sample` is opaque: the pipeline only ever asks for its presentation time and
/// hands it back to the writer.
public final class CaptureWriterPipeline<Sample: Sendable>: @unchecked Sendable {
    public typealias Writer = any CaptureSegmentWriting<Sample>
    /// Presentation time in seconds, or `nil` if the sample's timing is unusable.
    public typealias TimingProvider = @Sendable (Sample) -> Double?
    public typealias WriterFactory = @Sendable (
        _ source: CaptureSource,
        _ index: Int,
        _ directoryURL: URL,
        _ firstSample: Sample,
        _ anchorSeconds: Double
    ) throws -> Writer
    public typealias CapacityProvider = @Sendable (URL) -> Int64?
    public typealias TerminalHandler = @Sendable (CaptureManifestState, String?) -> Void

    /// A broadcast upload extension is held to roughly 50 MB. A single 1080p
    /// video buffer is a few megabytes and comes from a fixed pool, so a deep
    /// queue both blows the memory ceiling and starves frame delivery. These
    /// bounds keep the in-flight working set at a handful of megabytes.
    public static var defaultPendingLimits: [CaptureSource: Int] {
        [.screen: 3, .camera: 3, .appAudio: 24, .microphone: 24, .interactionEvents: 24]
    }

    /// Drops are journaled in batches; a sustained stall must not turn the
    /// journal into the next bottleneck.
    public static var dropReportInterval: Int { 600 }

    private let persistence: CaptureSessionPersistence
    private let queue: DispatchQueue
    private let pendingLock = NSLock()
    private let pendingLimits: [CaptureSource: Int]
    private let segmentDuration: TimeInterval
    private let protectedStorageReserve: Int64
    private let storageCheckInterval: Int
    private let timingProvider: TimingProvider
    private let writerFactory: WriterFactory
    private let capacityProvider: CapacityProvider
    private let terminalHandler: TerminalHandler

    private var pendingSamples: [CaptureSource: Int] = [:]
    private var droppedSamples: [CaptureSource: Int] = [:]
    private var reportedDrops: [CaptureSource: Int] = [:]
    private var acceptingSamples = true
    private var writers: [CaptureSource: Writer] = [:]
    private var nextSegmentIndex: [CaptureSource: Int] = [:]
    private var observedSources: Set<CaptureSource> = []
    private var sessionAnchor: Double?
    private var lastPresentationTime: Double?
    private var processedSinceStorageCheck = 0
    private var closingWriters = 0
    private var isFinishing = false
    private var didFinish = false
    private var requestedFinalState: CaptureManifestState = .finalized
    private var requestedFinalEvent: CaptureJournalEventKind = .finalized
    private var terminalDetail: String?
    private var shouldNotifyTerminal = false
    private var finishWaiters: [DispatchSemaphore] = []

    public init(
        persistence: CaptureSessionPersistence,
        queue: DispatchQueue = DispatchQueue(
            label: "com.creatorstudio.capture-writer",
            qos: .userInitiated,
            autoreleaseFrequency: .workItem
        ),
        pendingLimits: [CaptureSource: Int] = CaptureWriterPipeline.defaultPendingLimits,
        segmentDuration: TimeInterval = 10,
        protectedStorageReserve: Int64 = 1_000_000_000,
        storageCheckInterval: Int = 120,
        timing: @escaping TimingProvider,
        makeWriter: @escaping WriterFactory,
        capacityProvider: @escaping CapacityProvider = { _ in nil },
        terminalHandler: @escaping TerminalHandler
    ) {
        self.persistence = persistence
        self.queue = queue
        self.pendingLimits = pendingLimits
        self.segmentDuration = segmentDuration
        self.protectedStorageReserve = protectedStorageReserve
        self.storageCheckInterval = storageCheckInterval
        timingProvider = timing
        writerFactory = makeWriter
        self.capacityProvider = capacityProvider
        self.terminalHandler = terminalHandler
    }

    /// Number of samples dropped per source to keep the session alive.
    public var dropCounts: [CaptureSource: Int] {
        pendingLock.lock()
        defer { pendingLock.unlock() }
        return droppedSamples
    }

    public func enqueue(_ sample: Sample, source: CaptureSource) {
        pendingLock.lock()
        guard acceptingSamples else {
            pendingLock.unlock()
            return
        }
        let limit = pendingLimits[source] ?? 4
        guard pendingSamples[source, default: 0] < limit else {
            // Drop, do not fail. A momentary encoder stall must cost one sample,
            // not a forty-minute session.
            droppedSamples[source, default: 0] += 1
            pendingLock.unlock()
            return
        }
        pendingSamples[source, default: 0] += 1
        pendingLock.unlock()

        queue.async {
            defer {
                self.pendingLock.lock()
                self.pendingSamples[source, default: 0] -= 1
                self.pendingLock.unlock()
            }
            self.process(sample, source: source)
        }
    }

    public func recordLifecycle(_ event: CaptureJournalEventKind) {
        queue.async {
            guard !self.didFinish else { return }
            do {
                try self.persistence.recordLifecycle(event, duration: self.currentDuration())
            } catch {
                self.beginTerminalFailure(error, storageConstrained: false)
            }
        }
    }

    /// Blocks until every open writer has been closed and its segment committed,
    /// or until `timeout` elapses. Returns `true` if the session finished in time.
    @discardableResult
    public func finishSynchronously(timeout: TimeInterval) -> Bool {
        finishSynchronously(
            timeout: timeout,
            state: .finalized,
            event: .finalized,
            detail: nil
        )
    }

    /// Stops accepting samples and preserves every segment that has already
    /// reached its writer when a platform capture stream ends unexpectedly.
    /// The resulting manifest stays distinguishable from a deliberate stop and
    /// can be recovered by the same inbox importer.
    @discardableResult
    public func interruptSynchronously(detail: String, timeout: TimeInterval) -> Bool {
        finishSynchronously(
            timeout: timeout,
            state: .interrupted,
            event: .interrupted,
            detail: detail
        )
    }

    private func finishSynchronously(
        timeout: TimeInterval,
        state: CaptureManifestState,
        event: CaptureJournalEventKind,
        detail: String?
    ) -> Bool {
        let waiter = DispatchSemaphore(value: 0)
        queue.async {
            if self.didFinish {
                waiter.signal()
                return
            }
            self.finishWaiters.append(waiter)
            self.beginFinish(
                state: state,
                event: event,
                detail: detail,
                notifyHost: false
            )
        }
        return waiter.wait(timeout: .now() + timeout) == .success
    }

    private func process(_ sample: Sample, source: CaptureSource) {
        guard !isFinishing else { return }
        guard let presentationSeconds = timingProvider(sample), presentationSeconds.isFinite else {
            beginTerminalFailure(
                CaptureWriterPipelineError.invalidSampleTiming(source),
                storageConstrained: false
            )
            return
        }
        if sessionAnchor == nil { sessionAnchor = presentationSeconds }
        lastPresentationTime = max(lastPresentationTime ?? presentationSeconds, presentationSeconds)

        // The capture backend, not the app, decides which sources are live.
        // Recording what actually arrived is the only honest capability record.
        if observedSources.insert(source).inserted {
            try? persistence.recordObservedSource(source)
        }

        processedSinceStorageCheck += 1
        if processedSinceStorageCheck >= storageCheckInterval {
            processedSinceStorageCheck = 0
            if let capacity = capacityProvider(persistence.directoryURL),
               capacity < protectedStorageReserve {
                beginTerminalFailure(
                    CaptureWriterPipelineError.storageConstrained,
                    storageConstrained: true
                )
                return
            }
            reportDropsIfNeeded()
        }

        do {
            if let writer = writers[source],
               writer.shouldRotate(before: presentationSeconds, limit: segmentDuration) {
                writers[source] = nil
                close(writer)
            }
            let writer: Writer
            if let existing = writers[source] {
                writer = existing
            } else {
                let index = nextSegmentIndex[source, default: 0]
                nextSegmentIndex[source] = index + 1
                writer = try writerFactory(
                    source,
                    index,
                    persistence.directoryURL,
                    sample,
                    sessionAnchor ?? presentationSeconds
                )
                writers[source] = writer
            }
            guard try writer.append(sample) else {
                pendingLock.lock()
                droppedSamples[source, default: 0] += 1
                pendingLock.unlock()
                return
            }
        } catch {
            beginTerminalFailure(error, storageConstrained: false)
        }
    }

    private func reportDropsIfNeeded(force: Bool = false) {
        pendingLock.lock()
        let dropped = droppedSamples
        pendingLock.unlock()

        var newlyDropped: [String] = []
        for (source, count) in dropped.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            let reported = reportedDrops[source, default: 0]
            guard count > reported, force || count - reported >= Self.dropReportInterval else { continue }
            reportedDrops[source] = count
            newlyDropped.append("\(source.rawValue): \(count)")
        }
        guard !newlyDropped.isEmpty else { return }
        try? persistence.recordLifecycle(
            .warning,
            duration: currentDuration(),
            detail: "Dropped samples to keep the recording alive — \(newlyDropped.joined(separator: ", "))."
        )
    }

    private func beginTerminalFailure(_ error: Error, storageConstrained: Bool) {
        beginFinish(
            state: storageConstrained ? .storageConstrained : .failed,
            event: storageConstrained ? .storageConstrained : .failed,
            detail: String(describing: error),
            notifyHost: true
        )
    }

    private func beginFinish(
        state: CaptureManifestState,
        event: CaptureJournalEventKind,
        detail: String?,
        notifyHost: Bool
    ) {
        guard !isFinishing else { return }
        isFinishing = true
        pendingLock.lock()
        acceptingSamples = false
        pendingLock.unlock()
        requestedFinalState = state
        requestedFinalEvent = event
        terminalDetail = detail
        shouldNotifyTerminal = notifyHost

        do {
            try persistence.recordLifecycle(
                .stopping,
                state: .stopping,
                duration: currentDuration(),
                detail: detail
            )
        } catch {
            terminalDetail = terminalDetail ?? String(describing: error)
            requestedFinalState = .failed
            requestedFinalEvent = .failed
            shouldNotifyTerminal = true
        }

        let openWriters = Array(writers.values)
        writers.removeAll()
        for writer in openWriters { close(writer) }
        completeIfPossible()
    }

    private func close(_ writer: Writer) {
        closingWriters += 1
        writer.finish { result in
            self.queue.async {
                defer {
                    self.closingWriters -= 1
                    self.completeIfPossible()
                }
                switch result {
                case .success(let segment):
                    do {
                        try self.persistence.commit(segment)
                    } catch {
                        self.markFailed(error)
                    }
                case .failure(let error):
                    self.markFailed(error)
                }
            }
        }
    }

    private func markFailed(_ error: Error) {
        requestedFinalState = .failed
        requestedFinalEvent = .failed
        terminalDetail = String(describing: error)
        shouldNotifyTerminal = true
    }

    private func completeIfPossible() {
        guard isFinishing, closingWriters == 0, !didFinish else { return }
        didFinish = true
        reportDropsIfNeeded(force: true)
        do {
            try persistence.recordLifecycle(
                requestedFinalEvent,
                state: requestedFinalState,
                duration: currentDuration(),
                detail: terminalDetail
            )
        } catch {
            terminalDetail = terminalDetail ?? String(describing: error)
            shouldNotifyTerminal = true
        }

        // Waiters first: a host blocked in `finishSynchronously` must be released
        // before the terminal handler, which may need the main thread.
        let waiters = finishWaiters
        finishWaiters.removeAll()
        waiters.forEach { $0.signal() }

        if shouldNotifyTerminal {
            terminalHandler(requestedFinalState, terminalDetail)
        }
    }

    private func currentDuration() -> StudioTime {
        guard let anchor = sessionAnchor, let last = lastPresentationTime else { return .zero }
        let seconds = max(0, last - anchor)
        guard seconds.isFinite else { return .zero }
        return StudioTime(seconds: seconds)
    }
}
