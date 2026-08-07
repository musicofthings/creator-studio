import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import ReplayKit
import StudioCapture
import StudioDomain

/// ReplayKit/AVFoundation adapter. Everything that can fail in an interesting
/// way — queue bounds, rotation, drop policy, finish ordering — lives in
/// `CaptureWriterPipeline` in StudioCapture, where it is unit tested.
final class SampleHandler: RPBroadcastSampleHandler, @unchecked Sendable {
    private var pipeline: CaptureWriterPipeline<BroadcastSample>?

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        do {
            let inbox = try CaptureInboxLocation.createInbox()
            let capabilities = CaptureCapabilities(
                supportedSources: [.screen, .appAudio, .microphone],
                supportsBackgroundCapture: true,
                supportsPause: true,
                caveats: [
                    "Cross-app interaction coordinates are not available.",
                    "Protected content may appear blank or omit audio.",
                ]
            )
            let persistence = try CaptureSessionPersistence(
                inboxRootURL: inbox,
                capabilities: capabilities
            )
            pipeline = CaptureWriterPipeline(
                persistence: persistence,
                timing: { sample in
                    let time = CMSampleBufferGetPresentationTimeStamp(sample.buffer)
                    guard time.isValid, !time.isIndefinite else { return nil }
                    return CMTimeGetSeconds(time)
                },
                makeWriter: { source, index, directoryURL, firstSample, anchorSeconds in
                    try SegmentWriter(
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
                    DispatchQueue.main.async {
                        self?.finishBroadcastWithError(Self.terminalError(state: state, detail: detail))
                    }
                }
            )
        } catch {
            finishBroadcastWithError(Self.nsError(error))
        }
    }

    override func broadcastPaused() {
        pipeline?.recordLifecycle(.paused)
    }

    override func broadcastResumed() {
        pipeline?.recordLifecycle(.resumed)
    }

    override func broadcastFinished() {
        pipeline?.finishSynchronously(timeout: 12)
        pipeline = nil
    }

    override func processSampleBuffer(
        _ sampleBuffer: CMSampleBuffer,
        with sampleBufferType: RPSampleBufferType
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let source: CaptureSource
        switch sampleBufferType {
        case .video: source = .screen
        case .audioApp: source = .appAudio
        case .audioMic: source = .microphone
        @unknown default: return
        }
        pipeline?.enqueue(BroadcastSample(sampleBuffer), source: source)
    }

    private static func terminalError(state: CaptureManifestState, detail: String?) -> NSError {
        NSError(
            domain: "CreatorStudio.Broadcast",
            code: state == .storageConstrained ? 2 : 3,
            userInfo: [
                NSLocalizedDescriptionKey: detail
                    ?? "Capture stopped unexpectedly. Committed segments remain recoverable.",
            ]
        )
    }

    private static func nsError(_ error: Error) -> NSError {
        NSError(
            domain: "CreatorStudio.Broadcast",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: String(describing: error)]
        )
    }
}

private enum CapturePipelineError: Error, CustomStringConvertible {
    case invalidSample(String)
    case cannotAddWriterInput(String)
    case writerStartFailed(String)
    case writerFailed(String)

    var description: String {
        switch self {
        case .invalidSample(let role):
            "ReplayKit delivered an invalid \(role) sample."
        case .cannotAddWriterInput(let role):
            "The media writer could not add the \(role) input."
        case .writerStartFailed(let detail):
            "The media writer could not start: \(detail)"
        case .writerFailed(let detail):
            "The media writer failed: \(detail)"
        }
    }
}

/// Boxes a ReplayKit sample so it can cross the pipeline's writer queue.
private final class BroadcastSample: @unchecked Sendable {
    let buffer: CMSampleBuffer

    init(_ buffer: CMSampleBuffer) {
        self.buffer = buffer
    }
}

private final class SegmentWriter: CaptureSegmentWriting, @unchecked Sendable {
    typealias Sample = BroadcastSample

    private let source: CaptureSource
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let partialURL: URL
    private let finalURL: URL
    private let anchorSeconds: Double
    private let segmentStart: CMTime
    private let segmentStartSeconds: Double
    private var lastPresentationTime: CMTime
    private var lastSampleDuration: CMTime = .zero
    private var appendedSamples = 0

    init(
        source: CaptureSource,
        index: Int,
        directoryURL: URL,
        firstSample: CMSampleBuffer,
        anchorSeconds: Double
    ) throws {
        guard let formatDescription = CMSampleBufferGetFormatDescription(firstSample) else {
            throw CapturePipelineError.invalidSample(source.rawValue)
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(firstSample)
        self.source = source
        self.anchorSeconds = anchorSeconds
        segmentStart = presentationTime
        segmentStartSeconds = CMTimeGetSeconds(presentationTime)
        lastPresentationTime = presentationTime

        let baseName = "\(Self.filePrefix(for: source))-\(String(format: "%04d", index))"
        let fileExtension = source == .screen ? "mov" : "m4a"
        let segments = directoryURL.appendingPathComponent("segments", isDirectory: true)
        partialURL = segments.appendingPathComponent("\(baseName).partial.\(fileExtension)")
        finalURL = segments.appendingPathComponent("\(baseName).\(fileExtension)")
        try? FileManager.default.removeItem(at: partialURL)

        writer = try AVAssetWriter(
            outputURL: partialURL,
            fileType: source == .screen ? .mov : .m4a
        )
        if source == .screen {
            let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
            guard dimensions.width > 0, dimensions.height > 0 else {
                throw CapturePipelineError.invalidSample(source.rawValue)
            }
            let pixels = Int64(dimensions.width) * Int64(dimensions.height)
            let bitRate = min(12_000_000, max(2_000_000, pixels * 4))
            input = AVAssetWriterInput(
                mediaType: .video,
                outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: Int(dimensions.width),
                    AVVideoHeightKey: Int(dimensions.height),
                    AVVideoCompressionPropertiesKey: [
                        AVVideoAverageBitRateKey: bitRate,
                        AVVideoExpectedSourceFrameRateKey: 30,
                        AVVideoMaxKeyFrameIntervalKey: 60,
                    ],
                ],
                sourceFormatHint: formatDescription
            )
        } else {
            let description: CMAudioFormatDescription = formatDescription
            guard let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)
            else {
                throw CapturePipelineError.invalidSample(source.rawValue)
            }
            let sampleRate = max(8000, streamDescription.pointee.mSampleRate)
            let channels = max(1, Int(streamDescription.pointee.mChannelsPerFrame))
            input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: sampleRate,
                    AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: channels > 1 ? 192_000 : 96000,
                ],
                sourceFormatHint: description
            )
        }
        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw CapturePipelineError.cannotAddWriterInput(source.rawValue)
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw CapturePipelineError.writerStartFailed(writer.error?.localizedDescription ?? "Unknown error")
        }
        writer.startSession(atSourceTime: presentationTime)
    }

    func shouldRotate(before presentationSeconds: Double, limit: TimeInterval) -> Bool {
        appendedSamples > 0 && presentationSeconds - segmentStartSeconds >= limit
    }

    func append(_ sample: BroadcastSample) throws -> Bool {
        guard writer.status == .writing else {
            throw CapturePipelineError.writerFailed(writer.error?.localizedDescription ?? source.rawValue)
        }
        guard input.isReadyForMoreMediaData else { return false }
        guard input.append(sample.buffer) else {
            throw CapturePipelineError.writerFailed(writer.error?.localizedDescription ?? source.rawValue)
        }
        appendedSamples += 1
        lastPresentationTime = CMSampleBufferGetPresentationTimeStamp(sample.buffer)
        let duration = CMSampleBufferGetDuration(sample.buffer)
        if duration.isValid, !duration.isIndefinite { lastSampleDuration = duration }
        return true
    }

    func finish(completion: @escaping @Sendable (Result<CaptureSegment, Error>) -> Void) {
        input.markAsFinished()
        writer.finishWriting {
            do {
                guard self.writer.status == .completed else {
                    throw CapturePipelineError.writerFailed(
                        self.writer.error?.localizedDescription ?? self.source.rawValue
                    )
                }
                if FileManager.default.fileExists(atPath: self.finalURL.path) {
                    try FileManager.default.removeItem(at: self.finalURL)
                }
                try FileManager.default.moveItem(at: self.partialURL, to: self.finalURL)
                let values = try self.finalURL.resourceValues(forKeys: [.fileSizeKey])
                let byteCount = Int64(values.fileSize ?? 0)
                let digest = try Self.sha256(at: self.finalURL)
                let relativeStartSeconds = max(0, self.segmentStartSeconds - self.anchorSeconds)
                let durationSeconds = max(
                    0,
                    CMTimeGetSeconds((self.lastPresentationTime + self.lastSampleDuration) - self.segmentStart)
                )
                guard byteCount > 0, relativeStartSeconds.isFinite, durationSeconds.isFinite else {
                    throw CapturePipelineError.writerFailed("The finalized segment is empty or has invalid timing.")
                }
                completion(.success(CaptureSegment(
                    source: self.source,
                    relativePath: "segments/\(self.finalURL.lastPathComponent)",
                    sha256: digest,
                    byteCount: byteCount,
                    start: StudioTime(seconds: relativeStartSeconds),
                    duration: StudioTime(seconds: durationSeconds)
                )))
            } catch {
                completion(.failure(error))
            }
        }
    }

    private static func filePrefix(for source: CaptureSource) -> String {
        switch source {
        case .screen: "screen"
        case .appAudio: "app-audio"
        case .microphone: "microphone"
        case .camera: "camera"
        case .interactionEvents: "events"
        }
    }

    private static func sha256(at url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1_048_576) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
