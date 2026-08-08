import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import StudioCapture
import StudioDomain

private enum MacCaptureWriterError: Error, CustomStringConvertible {
    case invalidSample(String)
    case unsupportedSource(String)
    case cannotAddWriterInput(String)
    case writerStartFailed(String)
    case writerFailed(String)

    var description: String {
        switch self {
        case let .invalidSample(role):
            "ScreenCaptureKit delivered an invalid \(role) sample."
        case let .unsupportedSource(role):
            "The macOS capture writer does not support \(role) samples."
        case let .cannotAddWriterInput(role):
            "The media writer could not add the \(role) input."
        case let .writerStartFailed(detail):
            "The media writer could not start: \(detail)"
        case let .writerFailed(detail):
            "The media writer failed: \(detail)"
        }
    }
}

final class MacCaptureSegmentWriter: CaptureSegmentWriting, @unchecked Sendable {
    typealias Sample = MacCaptureSample

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
            throw MacCaptureWriterError.invalidSample(source.rawValue)
        }
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(firstSample)
        guard presentationTime.isValid, !presentationTime.isIndefinite else {
            throw MacCaptureWriterError.invalidSample(source.rawValue)
        }

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
        switch source {
        case .screen:
            let dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription)
            guard dimensions.width > 0, dimensions.height > 0 else {
                throw MacCaptureWriterError.invalidSample(source.rawValue)
            }
            let pixels = Int64(dimensions.width) * Int64(dimensions.height)
            let bitRate = min(24_000_000, max(4_000_000, pixels * 5))
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
        case .appAudio, .microphone:
            let description: CMAudioFormatDescription = formatDescription
            guard let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description)
            else {
                throw MacCaptureWriterError.invalidSample(source.rawValue)
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
        case .camera, .interactionEvents:
            throw MacCaptureWriterError.unsupportedSource(source.rawValue)
        }

        input.expectsMediaDataInRealTime = true
        guard writer.canAdd(input) else {
            throw MacCaptureWriterError.cannotAddWriterInput(source.rawValue)
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw MacCaptureWriterError.writerStartFailed(
                writer.error?.localizedDescription ?? "Unknown error"
            )
        }
        writer.startSession(atSourceTime: presentationTime)
    }

    func shouldRotate(before presentationSeconds: Double, limit: TimeInterval) -> Bool {
        appendedSamples > 0 && presentationSeconds - segmentStartSeconds >= limit
    }

    func append(_ sample: MacCaptureSample) throws -> Bool {
        guard writer.status == .writing else {
            throw MacCaptureWriterError.writerFailed(
                writer.error?.localizedDescription ?? source.rawValue
            )
        }
        guard input.isReadyForMoreMediaData else { return false }
        guard input.append(sample.buffer) else {
            throw MacCaptureWriterError.writerFailed(
                writer.error?.localizedDescription ?? source.rawValue
            )
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
                    throw MacCaptureWriterError.writerFailed(
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
                    CMTimeGetSeconds(
                        (self.lastPresentationTime + self.lastSampleDuration) - self.segmentStart
                    )
                )
                guard byteCount > 0,
                      relativeStartSeconds.isFinite,
                      durationSeconds.isFinite
                else {
                    throw MacCaptureWriterError.writerFailed(
                        "The finalized segment is empty or has invalid timing."
                    )
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
