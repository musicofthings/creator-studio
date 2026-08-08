import AudioToolbox
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import StudioDomain

public enum MediaInspectionError: Error, Equatable, Sendable {
    case unavailable
    case noUsableTracks
    case invalidDuration
    case invalidDimensions
    case inspectionFailed(String)
}

extension MediaInspectionError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unavailable:
            "The project source is unavailable."
        case .noUsableTracks:
            "The source does not contain a usable video or audio track."
        case .invalidDuration:
            "The source has no usable duration."
        case .invalidDimensions:
            "The source video has invalid dimensions."
        case let .inspectionFailed(message):
            "Creator Studio could not inspect this source: \(message)"
        }
    }
}

public struct MediaInspectionResult: Hashable, Sendable {
    public var duration: StudioTime
    public var displayPixelSize: PixelSize?
    public var hasVideo: Bool
    public var hasAudio: Bool
    public var metadata: SourceMediaMetadata

    public init(
        duration: StudioTime,
        displayPixelSize: PixelSize?,
        hasVideo: Bool,
        hasAudio: Bool,
        metadata: SourceMediaMetadata
    ) {
        self.duration = duration
        self.displayPixelSize = displayPixelSize
        self.hasVideo = hasVideo
        self.hasAudio = hasAudio
        self.metadata = metadata
    }
}

/// AVFoundation remains behind the portable media-pipeline boundary. The
/// inspector samples presentation timestamps to detect variable-frame-rate
/// input; no caller needs to infer elapsed time from a frame index.
public struct AVAssetMediaInspector: Sendable {
    public init() {}

    public func inspect(_ url: URL) async throws -> MediaInspectionResult {
        try await Task.detached(priority: .userInitiated) {
            try await Self.inspectInBackground(url)
        }.value
    }

    private static func inspectInBackground(_ url: URL) async throws -> MediaInspectionResult {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ),
            values.isRegularFile == true,
            values.isSymbolicLink != true
        else {
            throw MediaInspectionError.unavailable
        }

        do {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration)
            let durationSeconds = duration.seconds
            guard durationSeconds.isFinite, durationSeconds > 0 else {
                throw MediaInspectionError.invalidDuration
            }

            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            guard !videoTracks.isEmpty || !audioTracks.isEmpty else {
                throw MediaInspectionError.noUsableTracks
            }

            var naturalPixelSize: PixelSize?
            var displayPixelSize: PixelSize?
            var portableTransform = SourceAffineTransform.identity
            var nominalFrameRate: Double?
            var estimatedFrameRate: Double?
            var isVariableFrameRate = false
            var sourceStarts: [StudioTime] = []

            if let videoTrack = videoTracks.first {
                let naturalSize = try await videoTrack.load(.naturalSize)
                let preferredTransform = try await videoTrack.load(.preferredTransform)
                guard naturalSize.width.isFinite,
                      naturalSize.height.isFinite,
                      naturalSize.width > 0,
                      naturalSize.height > 0
                else {
                    throw MediaInspectionError.invalidDimensions
                }
                naturalPixelSize = PixelSize(
                    width: Int(naturalSize.width.rounded()),
                    height: Int(naturalSize.height.rounded())
                )
                let transformed = CGRect(origin: .zero, size: naturalSize)
                    .applying(preferredTransform)
                    .standardized
                guard transformed.width.isFinite,
                      transformed.height.isFinite,
                      transformed.width > 0,
                      transformed.height > 0
                else {
                    throw MediaInspectionError.invalidDimensions
                }
                displayPixelSize = PixelSize(
                    width: Int(transformed.width.rounded()),
                    height: Int(transformed.height.rounded())
                )
                portableTransform = SourceAffineTransform(
                    a: preferredTransform.a,
                    b: preferredTransform.b,
                    c: preferredTransform.c,
                    d: preferredTransform.d,
                    tx: preferredTransform.tx,
                    ty: preferredTransform.ty
                )

                let reportedFrameRate = Double(try await videoTrack.load(.nominalFrameRate))
                nominalFrameRate = Self.positiveFinite(reportedFrameRate)
                let timing = try Self.sampleFrameTiming(asset: asset, track: videoTrack)
                estimatedFrameRate = timing.estimatedFrameRate
                isVariableFrameRate = timing.isVariable
                let range = try await videoTrack.load(.timeRange)
                if let start = Self.studioTime(range.start) { sourceStarts.append(start) }
            }

            var audioFormat: SourceAudioFormat?
            if let audioTrack = audioTracks.first {
                let descriptions = try await audioTrack.load(.formatDescriptions)
                if let description = descriptions.first,
                   let stream = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                   stream.mSampleRate.isFinite,
                   stream.mSampleRate > 0,
                   stream.mChannelsPerFrame > 0 {
                    audioFormat = SourceAudioFormat(
                        sampleRate: stream.mSampleRate,
                        channelCount: Int(stream.mChannelsPerFrame)
                    )
                }
                let range = try await audioTrack.load(.timeRange)
                if let start = Self.studioTime(range.start) { sourceStarts.append(start) }
            }

            let sourceStart = sourceStarts.min() ?? .zero
            let portableDuration = StudioTime(seconds: durationSeconds)
            let metadata = SourceMediaMetadata(
                naturalPixelSize: naturalPixelSize,
                preferredTransform: portableTransform,
                sourceStart: sourceStart,
                sourceDuration: portableDuration,
                nominalFrameRate: nominalFrameRate,
                estimatedFrameRate: estimatedFrameRate,
                isVariableFrameRate: isVariableFrameRate,
                audioFormat: audioFormat
            )
            return MediaInspectionResult(
                duration: portableDuration,
                displayPixelSize: displayPixelSize,
                hasVideo: !videoTracks.isEmpty,
                hasAudio: !audioTracks.isEmpty,
                metadata: metadata
            )
        } catch let error as MediaInspectionError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw MediaInspectionError.inspectionFailed(error.localizedDescription)
        }
    }

    private static func sampleFrameTiming(
        asset: AVAsset,
        track: AVAssetTrack,
        maximumSamples: Int = 300
    ) throws -> (estimatedFrameRate: Double?, isVariable: Bool) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { return (nil, false) }
        reader.add(output)
        guard reader.startReading() else {
            throw reader.error ?? MediaInspectionError.inspectionFailed("Frame timing reader did not start.")
        }

        var times: [Double] = []
        times.reserveCapacity(maximumSamples)
        while times.count < maximumSamples, let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let seconds = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if seconds.isFinite { times.append(seconds) }
        }
        if reader.status == .failed {
            throw reader.error ?? MediaInspectionError.inspectionFailed("Frame timing reader failed.")
        }

        let sortedTimes = Array(Set(times)).sorted()
        guard sortedTimes.count >= 3 else { return (nil, false) }
        let intervals = zip(sortedTimes.dropFirst(), sortedTimes).compactMap { later, earlier -> Double? in
            let interval = later - earlier
            return interval.isFinite && interval > 0 ? interval : nil
        }
        guard !intervals.isEmpty else { return (nil, false) }
        let orderedIntervals = intervals.sorted()
        let median = orderedIntervals[orderedIntervals.count / 2]
        guard median > 0 else { return (nil, false) }
        let tolerance = max(0.000_5, median * 0.05)
        let varyingCount = intervals.lazy.filter { abs($0 - median) > tolerance }.count
        return (1 / median, varyingCount > max(1, intervals.count / 20))
    }

    private static func positiveFinite(_ value: Double) -> Double? {
        value.isFinite && value > 0 ? value : nil
    }

    private static func studioTime(_ time: CMTime) -> StudioTime? {
        let seconds = time.seconds
        guard seconds.isFinite,
              seconds >= Double(Int64.min) / 1_000_000,
              seconds <= Double(Int64.max) / 1_000_000
        else { return nil }
        return StudioTime(seconds: seconds)
    }
}

public enum MediaCacheStage: String, Hashable, Codable, Sendable {
    case preparing
    case proxy
    case waveform
    case finalizing
    case complete
}

public struct MediaCacheProgress: Hashable, Sendable {
    public var stage: MediaCacheStage
    public var fractionCompleted: Double

    public init(stage: MediaCacheStage, fractionCompleted: Double) {
        self.stage = stage
        self.fractionCompleted = min(max(fractionCompleted, 0), 1)
    }
}

public struct WaveformPoint: Hashable, Codable, Sendable {
    public var minimum: Float
    public var maximum: Float

    public init(minimum: Float, maximum: Float) {
        self.minimum = minimum
        self.maximum = maximum
    }
}

public struct WaveformEnvelope: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var assetID: AssetID
    public var sourceContentHash: String
    public var sampleRate: Double
    public var channelCount: Int
    public var points: [WaveformPoint]

    public init(
        assetID: AssetID,
        sourceContentHash: String,
        sampleRate: Double,
        channelCount: Int,
        points: [WaveformPoint]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.assetID = assetID
        self.sourceContentHash = sourceContentHash
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.points = points
    }
}

public struct MediaCacheManifest: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var assetID: AssetID
    public var sourceContentHash: String
    public var generatorVersion: Int
    public var createdAt: Date
    public var proxyRelativePath: String?
    public var waveformRelativePath: String?

    public init(
        assetID: AssetID,
        sourceContentHash: String,
        generatorVersion: Int,
        createdAt: Date,
        proxyRelativePath: String?,
        waveformRelativePath: String?
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.assetID = assetID
        self.sourceContentHash = sourceContentHash
        self.generatorVersion = generatorVersion
        self.createdAt = createdAt
        self.proxyRelativePath = proxyRelativePath
        self.waveformRelativePath = waveformRelativePath
    }
}

public struct MediaCacheGenerationResult: Hashable, Sendable {
    public var manifest: MediaCacheManifest
    public var proxyURL: URL?
    public var waveformURL: URL?
    public var waveform: WaveformEnvelope?

    public init(
        manifest: MediaCacheManifest,
        proxyURL: URL?,
        waveformURL: URL?,
        waveform: WaveformEnvelope?
    ) {
        self.manifest = manifest
        self.proxyURL = proxyURL
        self.waveformURL = waveformURL
        self.waveform = waveform
    }
}

public enum MediaCacheGenerationError: Error, Equatable, Sendable {
    case unsafeCacheDirectory
    case proxyUnavailable
    case waveformReaderFailed(String)
    case writeFailed(String)
}

extension MediaCacheGenerationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsafeCacheDirectory:
            "The project cache directory is unsafe."
        case .proxyUnavailable:
            "This source cannot be converted to the current editing proxy format."
        case let .waveformReaderFailed(message):
            "Creator Studio could not read the source waveform: \(message)"
        case let .writeFailed(message):
            "Creator Studio could not write a rebuildable media cache: \(message)"
        }
    }
}

public struct MediaCacheGenerator: Sendable {
    public static let generatorVersion = 1

    public var maximumWaveformPoints: Int

    public init(maximumWaveformPoints: Int = 4000) {
        self.maximumWaveformPoints = max(64, maximumWaveformPoints)
    }

    public func generate(
        sourceURL: URL,
        cacheDirectoryURL: URL,
        assetID: AssetID,
        sourceContentHash: String,
        inspection: MediaInspectionResult,
        progress: @escaping @Sendable (MediaCacheProgress) -> Void = { _ in }
    ) async throws -> MediaCacheGenerationResult {
        try Task.checkCancellation()
        progress(MediaCacheProgress(stage: .preparing, fractionCompleted: 0))
        let fileManager = FileManager.default
        try Self.validateCacheDirectory(cacheDirectoryURL, fileManager: fileManager)

        let manifestURL = cacheDirectoryURL.appendingPathComponent("manifest.json")
        if let existing = try Self.loadValidCache(
            manifestURL: manifestURL,
            cacheDirectoryURL: cacheDirectoryURL,
            assetID: assetID,
            sourceContentHash: sourceContentHash,
            fileManager: fileManager
        ) {
            progress(MediaCacheProgress(stage: .complete, fractionCompleted: 1))
            return existing
        }

        let proxyURL = cacheDirectoryURL.appendingPathComponent("proxy.mp4")
        let proxyPartialURL = cacheDirectoryURL.appendingPathComponent(".proxy.partial.mp4")
        let waveformURL = cacheDirectoryURL.appendingPathComponent("waveform.json")
        let waveformPartialURL = cacheDirectoryURL.appendingPathComponent(".waveform.partial.json")
        for url in [proxyPartialURL, waveformPartialURL] where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }

        var generatedProxyURL: URL?
        var generatedWaveform: WaveformEnvelope?
        do {
            let asset = AVURLAsset(url: sourceURL)
            if inspection.hasVideo {
                progress(MediaCacheProgress(stage: .proxy, fractionCompleted: 0.05))
                try await Self.generateProxy(
                    asset: asset,
                    destinationURL: proxyPartialURL
                )
                if fileManager.fileExists(atPath: proxyURL.path) { try fileManager.removeItem(at: proxyURL) }
                try fileManager.moveItem(at: proxyPartialURL, to: proxyURL)
                generatedProxyURL = proxyURL
                progress(MediaCacheProgress(stage: .proxy, fractionCompleted: 1))
            }

            if inspection.hasAudio {
                progress(MediaCacheProgress(stage: .waveform, fractionCompleted: 0))
                let waveform = try await Self.generateWaveform(
                    asset: asset,
                    assetID: assetID,
                    sourceContentHash: sourceContentHash,
                    inspection: inspection,
                    maximumPoints: maximumWaveformPoints,
                    progress: progress
                )
                try Self.writeJSON(waveform, to: waveformPartialURL)
                if fileManager.fileExists(atPath: waveformURL.path) { try fileManager.removeItem(at: waveformURL) }
                try fileManager.moveItem(at: waveformPartialURL, to: waveformURL)
                generatedWaveform = waveform
            }

            try Task.checkCancellation()
            progress(MediaCacheProgress(stage: .finalizing, fractionCompleted: 0.9))
            let manifest = MediaCacheManifest(
                assetID: assetID,
                sourceContentHash: sourceContentHash,
                generatorVersion: Self.generatorVersion,
                createdAt: .studioNow(),
                proxyRelativePath: generatedProxyURL?.lastPathComponent,
                waveformRelativePath: generatedWaveform == nil ? nil : waveformURL.lastPathComponent
            )
            try Self.writeJSON(manifest, to: manifestURL)
            progress(MediaCacheProgress(stage: .complete, fractionCompleted: 1))
            return MediaCacheGenerationResult(
                manifest: manifest,
                proxyURL: generatedProxyURL,
                waveformURL: generatedWaveform == nil ? nil : waveformURL,
                waveform: generatedWaveform
            )
        } catch is CancellationError {
            try? fileManager.removeItem(at: proxyPartialURL)
            try? fileManager.removeItem(at: waveformPartialURL)
            throw CancellationError()
        } catch let error as MediaCacheGenerationError {
            try? fileManager.removeItem(at: proxyPartialURL)
            try? fileManager.removeItem(at: waveformPartialURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: proxyPartialURL)
            try? fileManager.removeItem(at: waveformPartialURL)
            throw MediaCacheGenerationError.writeFailed(error.localizedDescription)
        }
    }

    private final class ExportBox: @unchecked Sendable {
        let session: AVAssetExportSession

        init(_ session: AVAssetExportSession) {
            self.session = session
        }
    }

    private static func generateProxy(asset: AVAsset, destinationURL: URL) async throws {
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPreset960x540
        ) else {
            throw MediaCacheGenerationError.proxyUnavailable
        }
        exporter.shouldOptimizeForNetworkUse = false
        let box = ExportBox(exporter)
        try await withTaskCancellationHandler {
            try await box.session.export(to: destinationURL, as: .mp4)
        } onCancel: {
            box.session.cancelExport()
        }
    }

    private static func generateWaveform(
        asset: AVAsset,
        assetID: AssetID,
        sourceContentHash: String,
        inspection: MediaInspectionResult,
        maximumPoints: Int,
        progress: @escaping @Sendable (MediaCacheProgress) -> Void
    ) async throws -> WaveformEnvelope {
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first else {
            throw MediaCacheGenerationError.waveformReaderFailed("No audio track is available.")
        }
        let sampleRate = inspection.metadata.audioFormat?.sampleRate ?? 48000
        let channelCount = inspection.metadata.audioFormat?.channelCount ?? 1
        let estimatedFrames = Int64(max(1, inspection.duration.seconds * sampleRate))
        var accumulator = WaveformAccumulator(
            estimatedFrameCount: estimatedFrames,
            maximumPoints: maximumPoints
        )

        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MediaCacheGenerationError.waveformReaderFailed("The audio decoder is unavailable.")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw MediaCacheGenerationError.waveformReaderFailed(
                reader.error?.localizedDescription ?? "The audio reader did not start."
            )
        }

        while let sample = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            guard length >= MemoryLayout<Float>.size else { continue }
            var data = Data(count: length)
            let status = data.withUnsafeMutableBytes { bytes in
                guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadCustomBlockSourceErr }
                return CMBlockBufferCopyDataBytes(
                    block,
                    atOffset: 0,
                    dataLength: length,
                    destination: baseAddress
                )
            }
            guard status == kCMBlockBufferNoErr else {
                throw MediaCacheGenerationError.waveformReaderFailed("The PCM buffer could not be copied.")
            }
            data.withUnsafeBytes { bytes in
                accumulator.append(
                    interleavedSamples: bytes.bindMemory(to: Float.self),
                    channelCount: channelCount
                )
            }

            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            if timestamp.isFinite, inspection.duration.seconds > 0 {
                progress(MediaCacheProgress(
                    stage: .waveform,
                    fractionCompleted: min(timestamp / inspection.duration.seconds, 0.98)
                ))
            }
        }
        guard reader.status == .completed else {
            throw MediaCacheGenerationError.waveformReaderFailed(
                reader.error?.localizedDescription ?? "The audio reader stopped early."
            )
        }
        return WaveformEnvelope(
            assetID: assetID,
            sourceContentHash: sourceContentHash,
            sampleRate: sampleRate,
            channelCount: channelCount,
            points: accumulator.finish()
        )
    }

    private static func validateCacheDirectory(_ url: URL, fileManager: FileManager) throws {
        guard let values = try? url.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ),
            values.isDirectory == true,
            values.isSymbolicLink != true
        else {
            throw MediaCacheGenerationError.unsafeCacheDirectory
        }
    }

    private static func loadValidCache(
        manifestURL: URL,
        cacheDirectoryURL: URL,
        assetID: AssetID,
        sourceContentHash: String,
        fileManager: FileManager
    ) throws -> MediaCacheGenerationResult? {
        guard let manifestValues = try? manifestURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ),
            manifestValues.isRegularFile == true,
            manifestValues.isSymbolicLink != true,
            let data = try? Data(contentsOf: manifestURL),
            let manifest = try? decoder().decode(MediaCacheManifest.self, from: data),
            manifest.schemaVersion <= MediaCacheManifest.currentSchemaVersion,
            manifest.generatorVersion == generatorVersion,
            manifest.assetID == assetID,
            manifest.sourceContentHash == sourceContentHash
        else { return nil }

        func productURL(_ relativePath: String?) -> URL? {
            guard let relativePath,
                  !relativePath.isEmpty,
                  relativePath == (relativePath as NSString).lastPathComponent
            else { return nil }
            let url = cacheDirectoryURL.appendingPathComponent(relativePath)
            guard let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            ),
                values.isRegularFile == true,
                values.isSymbolicLink != true
            else { return nil }
            return url
        }

        let proxyURL = productURL(manifest.proxyRelativePath)
        let waveformURL = productURL(manifest.waveformRelativePath)
        guard manifest.proxyRelativePath == nil || proxyURL != nil,
              manifest.waveformRelativePath == nil || waveformURL != nil
        else { return nil }
        let waveform = waveformURL.flatMap { url -> WaveformEnvelope? in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? decoder().decode(WaveformEnvelope.self, from: data)
        }
        guard waveformURL == nil || waveform != nil else { return nil }
        return MediaCacheGenerationResult(
            manifest: manifest,
            proxyURL: proxyURL,
            waveformURL: waveformURL,
            waveform: waveform
        )
    }

    private static func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
        do {
            let data = try encoder().encode(value)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw MediaCacheGenerationError.writeFailed(error.localizedDescription)
        }
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

struct WaveformAccumulator {
    private let maximumPoints: Int
    private let framesPerPoint: Int64
    private var frameCount: Int64 = 0
    private var currentMinimum: Float = 1
    private var currentMaximum: Float = -1
    private var points: [WaveformPoint] = []

    init(estimatedFrameCount: Int64, maximumPoints: Int) {
        self.maximumPoints = max(1, maximumPoints)
        framesPerPoint = max(1, Int64(ceil(Double(max(1, estimatedFrameCount)) / Double(max(1, maximumPoints)))))
        points.reserveCapacity(maximumPoints)
    }

    mutating func append(
        interleavedSamples: UnsafeBufferPointer<Float>,
        channelCount: Int
    ) {
        guard channelCount > 0, interleavedSamples.count >= channelCount else { return }
        var index = 0
        while index + channelCount <= interleavedSamples.count {
            var frameMinimum: Float = 1
            var frameMaximum: Float = -1
            for channel in 0 ..< channelCount {
                let value = interleavedSamples[index + channel]
                guard value.isFinite else { continue }
                frameMinimum = min(frameMinimum, max(-1, value))
                frameMaximum = max(frameMaximum, min(1, value))
            }
            currentMinimum = min(currentMinimum, frameMinimum)
            currentMaximum = max(currentMaximum, frameMaximum)
            frameCount += 1
            if frameCount % framesPerPoint == 0 {
                flush()
            }
            index += channelCount
        }
    }

    mutating func finish() -> [WaveformPoint] {
        if frameCount % framesPerPoint != 0 { flush() }
        guard points.count > maximumPoints else { return points }
        let stride = Int(ceil(Double(points.count) / Double(maximumPoints)))
        return Swift.stride(from: 0, to: points.count, by: stride).map { start in
            let end = min(start + stride, points.count)
            let slice = points[start ..< end]
            return WaveformPoint(
                minimum: slice.map(\.minimum).min() ?? 0,
                maximum: slice.map(\.maximum).max() ?? 0
            )
        }
    }

    private mutating func flush() {
        guard currentMaximum >= currentMinimum else { return }
        points.append(WaveformPoint(minimum: currentMinimum, maximum: currentMaximum))
        currentMinimum = 1
        currentMaximum = -1
    }
}
