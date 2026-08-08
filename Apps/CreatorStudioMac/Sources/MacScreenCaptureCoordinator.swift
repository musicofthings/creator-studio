import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit
import StudioCapture
import StudioDomain

struct MacCaptureOptions: Hashable, Sendable {
    var includeSystemAudio: Bool
    var includeMicrophone: Bool
}

enum MacCaptureEvent: Sendable {
    case selecting
    case starting
    case recording(UUID)
    case stopped(UUID)
    case interrupted(String)
    case canceled
    case failed(String)
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

    private lazy var streamDelegate = MacCaptureStreamDelegate { [weak self] detail in
        Task { @MainActor in
            guard let self, !self.isStopping else { return }
            await self.interrupt(detail: detail)
        }
    }

    private var options = MacCaptureOptions(includeSystemAudio: true, includeMicrophone: true)
    private var stream: SCStream?
    private var pipeline: CaptureWriterPipeline<MacCaptureSample>?
    private var activeSessionID: UUID?
    private var isStopping = false
    private var observesPicker = false

    init(
        inboxRootURL: URL,
        onEvent: @escaping @MainActor @Sendable (MacCaptureEvent) -> Void
    ) {
        self.inboxRootURL = inboxRootURL
        self.onEvent = onEvent
        super.init()
    }

    func presentPicker(options: MacCaptureOptions) {
        guard stream == nil else { return }
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

    func stop() async {
        guard let stream, let pipeline else { return }
        isStopping = true
        do {
            try await stream.stopCapture()
            sampleForwarder.clear()
            let finished = await Task.detached {
                pipeline.finishSynchronously(timeout: 20)
            }.value
            let sessionID = activeSessionID
            clearActiveCapture()
            if finished, let sessionID {
                onEvent(.stopped(sessionID))
            } else {
                onEvent(.failed(
                    "The stream stopped, but one or more media writers did not finish in time. Committed segments remain recoverable."
                ))
            }
        } catch {
            await interrupt(detail: error.localizedDescription)
        }
    }

    private func startCapture(with filter: SCContentFilter) async {
        guard stream == nil else { return }
        onEvent(.starting)
        SCContentSharingPicker.shared.isActive = false

        let capabilities = CaptureCapabilities(
            supportedSources: supportedSources(for: options),
            supportsBackgroundCapture: true,
            supportsPause: false,
            caveats: [
                "Protected content may appear blank or omit audio.",
                "Pointer clicks are rendered into the recording; editable pointer paths are a later adapter.",
            ]
        )

        var persistence: CaptureSessionPersistence?
        do {
            let createdPersistence = try CaptureSessionPersistence(
                inboxRootURL: inboxRootURL,
                capabilities: capabilities
            )
            persistence = createdPersistence
            let createdPipeline = CaptureWriterPipeline<MacCaptureSample>(
                persistence: createdPersistence,
                timing: { sample in
                    let time = CMSampleBufferGetPresentationTimeStamp(sample.buffer)
                    guard time.isValid, !time.isIndefinite else { return nil }
                    return CMTimeGetSeconds(time)
                },
                makeWriter: { source, index, directoryURL, firstSample, anchorSeconds in
                    try MacCaptureSegmentWriter(
                        source: source,
                        index: index,
                        directoryURL: directoryURL,
                        firstSample: firstSample.buffer,
                        anchorSeconds: anchorSeconds
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

            let configuration = try streamConfiguration(for: filter, options: options)
            let createdStream = SCStream(
                filter: filter,
                configuration: configuration,
                delegate: streamDelegate
            )

            sampleForwarder.install(createdPipeline)
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
            activeSessionID = createdPersistence.manifest.sessionID
            stream = createdStream
            isStopping = false
            try await createdStream.startCapture()
            onEvent(.recording(createdPersistence.manifest.sessionID))
        } catch {
            sampleForwarder.clear()
            clearActiveCapture()
            if let persistence, persistence.manifest.files.isEmpty {
                try? FileManager.default.removeItem(at: persistence.directoryURL)
            }
            onEvent(.failed(
                "Screen recording could not start: \(error.localizedDescription)"
            ))
        }
    }

    private func interrupt(detail: String) async {
        guard let pipeline else {
            clearActiveCapture()
            onEvent(.failed(detail))
            return
        }
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
        stream = nil
        pipeline = nil
        activeSessionID = nil
        isStopping = false
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

    private func supportedSources(for options: MacCaptureOptions) -> Set<CaptureSource> {
        var sources: Set<CaptureSource> = [.screen]
        if options.includeSystemAudio { sources.insert(.appAudio) }
        if options.includeMicrophone { sources.insert(.microphone) }
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
        configuration.showsCursor = true
        configuration.showMouseClicks = true
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

    init(_ buffer: CMSampleBuffer) {
        self.buffer = buffer
    }
}

private final class MacCaptureSampleForwarder: NSObject, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var pipeline: CaptureWriterPipeline<MacCaptureSample>?

    func install(_ pipeline: CaptureWriterPipeline<MacCaptureSample>) {
        lock.withLock { self.pipeline = pipeline }
    }

    func clear() {
        lock.withLock { pipeline = nil }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer),
              let pipeline = lock.withLock({ pipeline })
        else { return }

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
    private let didStop: @Sendable (String) -> Void

    init(didStop: @escaping @Sendable (String) -> Void) {
        self.didStop = didStop
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        didStop(error.localizedDescription)
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
