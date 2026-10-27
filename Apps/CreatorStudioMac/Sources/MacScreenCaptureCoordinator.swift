import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import StudioCapture
import StudioDomain

struct MacCaptureOptions: Hashable, Sendable {
    var includeSystemAudio: Bool
    var includeMicrophone: Bool
    var includeCamera: Bool
    /// `AVCaptureDevice.uniqueID` for the selected facecam, when known.
    var cameraDeviceID: String?
    var showCursor: Bool
    var highlightMouseClicks: Bool
    var trackPointerMotion: Bool
}

enum MacCaptureEvent: Sendable {
    case selecting
    case starting
    case recording(UUID)
    /// Camera session is running and ready for the live facecam bubble.
    case cameraStarted
    case sourceObserved(CaptureSource)
    case stopped(UUID)
    case interrupted(String)
    case canceled
    case failed(String)
    /// Non-fatal capture-side notice (permissions, degraded features).
    case notice(String)
}

@MainActor
final class MacScreenCaptureCoordinator: NSObject {
    private let inboxRootURL: URL
    private let onEvent: @MainActor @Sendable (MacCaptureEvent) -> Void
    private let sampleQueue = DispatchQueue(
        label: "com.creatorstudio.macos.screen-capture-samples",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    private let sampleForwarder = MacCaptureSampleForwarder()
    private lazy var pickerObserver = MacContentPickerObserver { [weak self] event in
        Task { @MainActor in
            self?.handlePickerEvent(event)
        }
    }

    private lazy var streamDelegate = MacCaptureStreamDelegate { [weak self] error in
        Task { @MainActor in
            guard let self else { return }
            // App-initiated stop owns finalization; ignore the delegate callback.
            guard !self.isStopping else { return }
            // ScreenCaptureKit reports intentional user stops through
            // didStopWithError (SCStreamError.userStopped). That is a normal
            // end of recording, not crash recovery.
            if Self.isUserInitiatedStop(error) {
                await self.finalizeActiveCapture()
                return
            }
            await self.interrupt(detail: error.localizedDescription)
        }
    }

    private var options = MacCaptureOptions(
        includeSystemAudio: true,
        includeMicrophone: false,
        includeCamera: false,
        cameraDeviceID: nil,
        showCursor: true,
        highlightMouseClicks: true,
        trackPointerMotion: true
    )
    private var stream: SCStream?
    private var pipeline: CaptureWriterPipeline<MacCaptureSample>?
    private var pointerTracker: MacPointerTracker?
    private let cameraSession = MacCameraCaptureSession()
    private var activeSessionID: UUID?
    private var isStopping = false
    private var observesPicker = false

    /// Live facecam session for the on-screen bubble while recording.
    var liveCameraSession: MacCameraCaptureSession? {
        cameraSession.isActive ? cameraSession : nil
    }

    init(
        inboxRootURL: URL,
        onEvent: @escaping @MainActor @Sendable (MacCaptureEvent) -> Void
    ) {
        self.inboxRootURL = inboxRootURL
        self.onEvent = onEvent
        super.init()
    }

    func presentPicker(options: MacCaptureOptions) {
        guard stream == nil, !cameraSession.isActive else { return }
        self.options = options

        let picker = SCContentSharingPicker.shared
        if !observesPicker {
            picker.add(pickerObserver)
            observesPicker = true
        }
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow, .singleApplication, .singleDisplay]
        configuration.allowsChangingSelectedContent = false
        if let bundleIdentifier = Bundle.main.bundleIdentifier {
            configuration.excludedBundleIDs = [bundleIdentifier]
        }
        picker.defaultConfiguration = configuration
        picker.isActive = true
        onEvent(.selecting)
        picker.present()
    }

    /// Camera-only / podcast-style recording without a screen source (PRD Phase 1).
    func startCameraOnlyCapture(options: MacCaptureOptions) async {
        guard stream == nil, !cameraSession.isActive else { return }
        self.options = options
        onEvent(.starting)
        do {
            try await beginSession(screenFilter: nil)
        } catch {
            sampleForwarder.clear()
            clearActiveCapture()
            onEvent(.failed("Camera recording could not start: \(error.localizedDescription)"))
        }
    }

    func stop() async {
        guard pipeline != nil else { return }
        isStopping = true
        // stopCapture often completes by surfacing SCStreamError.userStopped to
        // the delegate and/or as a thrown error. Both are expected for a normal
        // Stop; always finalize as a completed session, never as recovery.
        if let stream {
            do {
                try await stream.stopCapture()
            } catch {
                if !Self.isBenignStopError(error) {
                    onEvent(.notice("Stream stop reported: \(error.localizedDescription)"))
                }
            }
        }
        await finalizeActiveCapture()
    }

    @discardableResult
    func markFocusAtCurrentCursor() -> Bool {
        guard activeSessionID != nil, let pointerTracker else { return false }
        pointerTracker.markFocusAtCurrentCursor()
        return true
    }

    private func startCapture(with filter: SCContentFilter) async {
        guard stream == nil, !cameraSession.isActive else { return }
        onEvent(.starting)
        SCContentSharingPicker.shared.isActive = false
        do {
            try await beginSession(screenFilter: filter)
        } catch {
            sampleForwarder.clear()
            clearActiveCapture()
            onEvent(.failed(
                "Screen recording could not start: \(error.localizedDescription)"
            ))
        }
    }

    /// Shared session bootstrap for screen (+ optional camera) or camera-only.
    private func beginSession(screenFilter: SCContentFilter?) async throws {
        let wantsScreen = screenFilter != nil
        let wantsCamera = options.includeCamera || !wantsScreen
        guard wantsScreen || wantsCamera else {
            throw MacCameraCaptureError.deviceUnavailable
        }

        var caveats = [
            "Protected content may appear blank or omit audio.",
            "Pointer clicks are rendered into the recording; editable pointer paths are a later adapter.",
        ]
        if wantsCamera {
            caveats.append(MacCameraDevice.desktopAvailabilityNote)
        }

        let capabilities = CaptureCapabilities(
            supportedSources: supportedSources(for: options, includeScreen: wantsScreen, includeCamera: wantsCamera),
            supportsBackgroundCapture: true,
            supportsPause: false,
            caveats: caveats
        )

        let createdPersistence: CaptureSessionPersistence
        do {
            createdPersistence = try CaptureSessionPersistence(
                inboxRootURL: inboxRootURL,
                capabilities: capabilities
            )
        } catch {
            throw error
        }
        do {
            let createdPipeline = CaptureWriterPipeline<MacCaptureSample>(
                persistence: createdPersistence,
                timing: { sample in
                    // Prefer host uptime so ScreenCaptureKit + AVCapture share one axis.
                    guard sample.hostUptime.isFinite else { return nil }
                    return sample.hostUptime
                },
                makeWriter: { source, index, directoryURL, firstSample, anchorSeconds in
                    // Session placement uses host uptime (anchorSeconds + first sample host
                    // uptime). Encoding still starts at each buffer's own media PTS inside
                    // the writer — do not use media PTS as the session anchor or every
                    // rotated segment gets startUs=0 and import fails on overlapping clips.
                    try MacCaptureSegmentWriter(
                        source: source,
                        index: index,
                        directoryURL: directoryURL,
                        firstSample: firstSample.buffer,
                        sessionAnchorSeconds: anchorSeconds,
                        segmentHostStartSeconds: firstSample.hostUptime
                    )
                },
                capacityProvider: { url in
                    guard let values = try? url.resourceValues(
                        forKeys: [
                            .volumeAvailableCapacityForImportantUsageKey,
                            .volumeAvailableCapacityKey,
                        ]
                    ) else { return nil }
                    if let important = values.volumeAvailableCapacityForImportantUsage {
                        return important
                    }
                    return Int64(values.volumeAvailableCapacity ?? 0)
                },
                terminalHandler: { [weak self] state, detail in
                    Task { @MainActor in
                        guard let self else { return }
                        let message = detail ?? "Desktop capture ended unexpectedly."
                        if state == .storageConstrained {
                            self.onEvent(.interrupted(
                                "Recording stopped before the protected storage reserve was exhausted. Committed segments remain recoverable."
                            ))
                        } else {
                            self.onEvent(.interrupted(message))
                        }
                        if let stream = self.stream {
                            self.isStopping = true
                            try? await stream.stopCapture()
                        }
                        self.sampleForwarder.clear()
                        self.clearActiveCapture()
                    }
                }
            )

            let sourceObserver: @Sendable (CaptureSource) -> Void = { [weak self] source in
                Task { @MainActor in
                    self?.onEvent(.sourceObserved(source))
                }
            }

            if let filter = screenFilter {
                let configuration = try streamConfiguration(for: filter, options: options)
                let tracker = options.trackPointerMotion
                    ? MacPointerTracker(
                        sessionDirectoryURL: createdPersistence.directoryURL,
                        contentRect: filter.contentRect
                    )
                    : nil
                let createdStream = SCStream(
                    filter: filter,
                    configuration: configuration,
                    delegate: streamDelegate
                )

                sampleForwarder.install(
                    createdPipeline,
                    sourceObserver: sourceObserver,
                    firstScreenSample: { [weak tracker] in
                        tracker?.noteMediaClockOrigin()
                    }
                )
                try createdStream.addStreamOutput(
                    sampleForwarder,
                    type: .screen,
                    sampleHandlerQueue: sampleQueue
                )
                if options.includeSystemAudio {
                    try createdStream.addStreamOutput(
                        sampleForwarder,
                        type: .audio,
                        sampleHandlerQueue: sampleQueue
                    )
                }
                if options.includeMicrophone {
                    try createdStream.addStreamOutput(
                        sampleForwarder,
                        type: .microphone,
                        sampleHandlerQueue: sampleQueue
                    )
                }

                pipeline = createdPipeline
                pointerTracker = tracker
                activeSessionID = createdPersistence.manifest.sessionID
                stream = createdStream
                isStopping = false

                // Start camera before the screen stream so the live bubble is ready
                // as soon as recording UI appears.
                if wantsCamera {
                    do {
                        try startCamera(pipeline: createdPipeline, sourceObserver: sourceObserver)
                        onEvent(.cameraStarted)
                    } catch {
                        onEvent(.notice(
                            "Camera could not start (\(error.localizedDescription)). Continuing with screen only. If Camera is already enabled in Settings, toggle it off/on for Creator Studio after a rebuild."
                        ))
                    }
                }

                if let tracker {
                    // Never force the system Accessibility prompt during capture start —
                    // that opens System Settings and steals focus from recording.
                    if !MacPointerTracker.isAccessibilityTrusted {
                        onEvent(.notice(
                            "Pointer tracking needs Accessibility permission. Recording continues; enable Accessibility for click/focus metadata."
                        ))
                    } else if !tracker.start() {
                        onEvent(.notice(
                            "Pointer tracking could not install its monitor. Recording continues without click or focus metadata."
                        ))
                    }
                }
                try await createdStream.startCapture()
                onEvent(.recording(createdPersistence.manifest.sessionID))
            } else {
                // Camera-only: optional microphone still uses ScreenCaptureKit is not available
                // without a content filter, so mic for camera-only is left to a later AVAudioEngine pass.
                pipeline = createdPipeline
                activeSessionID = createdPersistence.manifest.sessionID
                isStopping = false
                try startCamera(pipeline: createdPipeline, sourceObserver: sourceObserver)
                onEvent(.cameraStarted)
                if options.includeMicrophone {
                    onEvent(.notice(
                        "Camera-only mode records the selected camera. Include microphone with a screen recording, or import a separate audio track for now."
                    ))
                }
                onEvent(.recording(createdPersistence.manifest.sessionID))
            }
        } catch {
            sampleForwarder.clear()
            clearActiveCapture()
            if createdPersistence.manifest.files.isEmpty {
                try? FileManager.default.removeItem(at: createdPersistence.directoryURL)
            }
            throw error
        }
    }

    private func startCamera(
        pipeline: CaptureWriterPipeline<MacCaptureSample>,
        sourceObserver: @escaping @Sendable (CaptureSource) -> Void
    ) throws {
        guard let device = MacCameraDiscovery.device(id: options.cameraDeviceID) else {
            throw MacCameraCaptureError.deviceUnavailable
        }
        try cameraSession.start(
            device: device,
            pipeline: pipeline,
            sourceObserver: sourceObserver
        )
    }

    /// Commits open segments as a normal finalized session and auto-imports.
    private func finalizeActiveCapture() async {
        guard let pipeline else {
            clearActiveCapture()
            return
        }
        isStopping = true
        sampleForwarder.clear()
        // Hold the pipeline across the wait so finish callbacks can still
        // commit segments after a host-side timeout.
        let finished = await Task.detached {
            pipeline.finishSynchronously(timeout: 20)
        }.value
        let sessionID = activeSessionID
        clearActiveCapture()
        if finished, let sessionID {
            onEvent(.stopped(sessionID))
        } else {
            // Timed-out finalize is reclassified as interrupted on disk.
            onEvent(.interrupted(
                "The stream stopped, but one or more media writers did not finish in time. Committed segments remain recoverable."
            ))
        }
    }

    private func interrupt(detail: String) async {
        guard let pipeline else {
            clearActiveCapture()
            onEvent(.failed(detail))
            return
        }
        isStopping = true
        sampleForwarder.clear()
        let preserved = await Task.detached {
            pipeline.interruptSynchronously(detail: detail, timeout: 20)
        }.value
        clearActiveCapture()
        onEvent(.interrupted(
            preserved
                ? "Screen recording was interrupted. Every committed segment remains ready to recover."
                : "Screen recording was interrupted while media writers were closing. Already committed segments remain recoverable."
        ))
    }

    private func clearActiveCapture() {
        cameraSession.stop()
        pointerTracker?.stop()
        pointerTracker = nil
        stream = nil
        pipeline = nil
        activeSessionID = nil
        isStopping = false
    }

    /// Intentional end of capture (in-app Stop, menu bar stop, or picker end).
    private static func isUserInitiatedStop(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == SCStreamErrorDomain,
           nsError.code == SCStreamError.Code.userStopped.rawValue {
            return true
        }
        // Be tolerant of localization/domain differences across OS versions.
        let message = nsError.localizedDescription.lowercased()
        return message.contains("user stopped") || message.contains("stopped by the user")
    }

    /// Errors that are expected while deliberately stopping a stream.
    private static func isBenignStopError(_ error: Error) -> Bool {
        if isUserInitiatedStop(error) { return true }
        let nsError = error as NSError
        guard nsError.domain == SCStreamErrorDomain else { return false }
        switch nsError.code {
        case SCStreamError.Code.attemptToStopStreamState.rawValue,
             SCStreamError.Code.removingStream.rawValue:
            return true
        default:
            return false
        }
    }

    private func handlePickerEvent(_ event: MacContentPickerEvent) {
        switch event {
        case .canceled:
            SCContentSharingPicker.shared.isActive = false
            onEvent(.canceled)
        case let .selected(filter):
            Task { await startCapture(with: filter.value) }
        case let .failed(detail):
            SCContentSharingPicker.shared.isActive = false
            onEvent(.failed("The system content picker could not open: \(detail)"))
        }
    }

    private func supportedSources(
        for options: MacCaptureOptions,
        includeScreen: Bool,
        includeCamera: Bool
    ) -> Set<CaptureSource> {
        var sources: Set<CaptureSource> = []
        if includeScreen { sources.insert(.screen) }
        if includeCamera { sources.insert(.camera) }
        if options.includeSystemAudio, includeScreen { sources.insert(.appAudio) }
        if options.includeMicrophone, includeScreen { sources.insert(.microphone) }
        return sources
    }

    private func streamConfiguration(
        for filter: SCContentFilter,
        options: MacCaptureOptions
    ) throws -> SCStreamConfiguration {
        guard let dimensions = DesktopCaptureSizing().dimensions(
            pointWidth: filter.contentRect.width,
            pointHeight: filter.contentRect.height,
            pointPixelScale: Double(filter.pointPixelScale)
        ) else {
            throw MacScreenCaptureError.invalidSelectionDimensions
        }

        let configuration = SCStreamConfiguration()
        configuration.width = dimensions.width
        configuration.height = dimensions.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        configuration.queueDepth = 5
        configuration.showsCursor = options.showCursor
        configuration.showMouseClicks = options.highlightMouseClicks
        configuration.capturesAudio = options.includeSystemAudio
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48000
        configuration.channelCount = 2
        configuration.captureMicrophone = options.includeMicrophone
        return configuration
    }
}

final class MacCaptureSample: @unchecked Sendable {
    let buffer: CMSampleBuffer
    /// Monotonic host uptime used for cross-source journal timing (screen + camera).
    let hostUptime: Double

    init(_ buffer: CMSampleBuffer, hostUptime: Double = ProcessInfo.processInfo.systemUptime) {
        self.buffer = buffer
        self.hostUptime = hostUptime
    }
}

private final class MacCaptureSampleForwarder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var pipeline: CaptureWriterPipeline<MacCaptureSample>?
    private var sourceObserver: (@Sendable (CaptureSource) -> Void)?
    private var firstScreenSample: (@Sendable () -> Void)?
    private var observedSources: Set<CaptureSource> = []
    private var didNoteFirstScreenSample = false

    func install(
        _ pipeline: CaptureWriterPipeline<MacCaptureSample>,
        sourceObserver: @escaping @Sendable (CaptureSource) -> Void,
        firstScreenSample: (@Sendable () -> Void)? = nil
    ) {
        lock.withLock {
            self.pipeline = pipeline
            self.sourceObserver = sourceObserver
            self.firstScreenSample = firstScreenSample
            observedSources = []
            didNoteFirstScreenSample = false
        }
    }

    func clear() {
        lock.withLock {
            pipeline = nil
            sourceObserver = nil
            firstScreenSample = nil
            observedSources = []
            didNoteFirstScreenSample = false
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }

        let source: CaptureSource
        switch type {
        case .screen:
            guard Self.isCompleteScreenFrame(sampleBuffer) else { return }
            source = .screen
        case .audio:
            source = .appAudio
        case .microphone:
            source = .microphone
        @unknown default:
            return
        }
        let delivery = lock.withLock { () -> (
            CaptureWriterPipeline<MacCaptureSample>?,
            (@Sendable (CaptureSource) -> Void)?,
            (@Sendable () -> Void)?
        ) in
            let observer = observedSources.insert(source).inserted ? sourceObserver : nil
            let mediaOrigin: (@Sendable () -> Void)?
            if source == .screen, !didNoteFirstScreenSample {
                didNoteFirstScreenSample = true
                mediaOrigin = firstScreenSample
            } else {
                mediaOrigin = nil
            }
            return (pipeline, observer, mediaOrigin)
        }
        guard let pipeline = delivery.0 else { return }
        delivery.2?()
        delivery.1?(source)
        pipeline.enqueue(MacCaptureSample(sampleBuffer), source: source)
    }

    private static func isCompleteScreenFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: false
        ) as? [[SCStreamFrameInfo: Any]],
            let rawStatus = attachments.first?[.status] as? Int,
            let status = SCFrameStatus(rawValue: rawStatus)
        else { return false }
        return status == .complete
    }
}

private enum MacContentPickerEvent: Sendable {
    case canceled
    case selected(UncheckedSendableBox<SCContentFilter>)
    case failed(String)
}

private final class MacContentPickerObserver: NSObject, SCContentSharingPickerObserver, @unchecked Sendable {
    private let handler: @Sendable (MacContentPickerEvent) -> Void

    init(handler: @escaping @Sendable (MacContentPickerEvent) -> Void) {
        self.handler = handler
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didCancelFor stream: SCStream?
    ) {
        handler(.canceled)
    }

    func contentSharingPicker(
        _ picker: SCContentSharingPicker,
        didUpdateWith filter: SCContentFilter,
        for stream: SCStream?
    ) {
        // ScreenCaptureKit hands the observer an immutable selection filter.
        // Boxing the Objective-C reference keeps the protocol callback off the
        // main actor while the coordinator consumes it on that actor.
        handler(.selected(UncheckedSendableBox(filter)))
    }

    func contentSharingPickerStartDidFailWithError(_ error: Error) {
        handler(.failed(error.localizedDescription))
    }
}

private final class MacCaptureStreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
    private let didStop: @Sendable (Error) -> Void

    init(didStop: @escaping @Sendable (Error) -> Void) {
        self.didStop = didStop
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        didStop(error)
    }
}

private final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) {
        self.value = value
    }
}

private enum MacScreenCaptureError: Error, LocalizedError {
    case invalidSelectionDimensions

    var errorDescription: String? {
        "The selected content has no usable capture dimensions."
    }
}
