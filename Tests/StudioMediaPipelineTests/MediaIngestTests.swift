import AVFoundation
import CoreVideo
import Foundation
import StudioDomain
@testable import StudioMediaPipeline
import Testing

@Test func inspectsAudioAndBuildsReusableWaveformCache() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("media-ingest-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sourceURL = root.appendingPathComponent("tone.wav")
    try writeTone(to: sourceURL)
    let cacheURL = root.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
    let assetID = AssetID()
    let sourceHash = "sha256:test-tone"

    let inspection = try await AVAssetMediaInspector().inspect(sourceURL)
    #expect(!inspection.hasVideo)
    #expect(inspection.hasAudio)
    #expect(inspection.duration > .zero)
    #expect(inspection.metadata.audioFormat?.channelCount == 1)
    #expect(inspection.metadata.audioFormat?.sampleRate == 8000)

    let first = try await MediaCacheGenerator(maximumWaveformPoints: 128).generate(
        sourceURL: sourceURL,
        cacheDirectoryURL: cacheURL,
        assetID: assetID,
        sourceContentHash: sourceHash,
        inspection: inspection
    )
    let second = try await MediaCacheGenerator(maximumWaveformPoints: 128).generate(
        sourceURL: sourceURL,
        cacheDirectoryURL: cacheURL,
        assetID: assetID,
        sourceContentHash: sourceHash,
        inspection: inspection
    )

    #expect(first.proxyURL == nil)
    #expect(first.waveformURL != nil)
    #expect(first.waveform?.points.isEmpty == false)
    #expect((first.waveform?.points.count ?? 0) <= 128)
    #expect(first.manifest == second.manifest)
    #expect(first.waveform == second.waveform)
}

@Test func canceledCacheJobDoesNotPublishAManifest() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("media-ingest-cancel-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sourceURL = root.appendingPathComponent("tone.wav")
    try writeTone(to: sourceURL)
    let cacheURL = root.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)
    let inspection = try await AVAssetMediaInspector().inspect(sourceURL)
    let assetID = AssetID()

    let task = Task {
        try await MediaCacheGenerator().generate(
            sourceURL: sourceURL,
            cacheDirectoryURL: cacheURL,
            assetID: assetID,
            sourceContentHash: "sha256:canceled",
            inspection: inspection
        )
    }
    task.cancel()
    await #expect(throws: CancellationError.self) {
        _ = try await task.value
    }
    #expect(!FileManager.default.fileExists(atPath: cacheURL.appendingPathComponent("manifest.json").path))
}

@Test func inspectsOrientationAndBuildsAPlayableVideoProxy() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("media-video-ingest-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let sourceURL = root.appendingPathComponent("portrait-source.mov")
    try writeVideo(to: sourceURL)
    let cacheURL = root.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: cacheURL, withIntermediateDirectories: true)

    let inspection = try await AVAssetMediaInspector().inspect(sourceURL)
    #expect(inspection.hasVideo)
    #expect(!inspection.hasAudio)
    #expect(inspection.displayPixelSize == PixelSize(width: 240, height: 320))
    #expect(inspection.metadata.naturalPixelSize == PixelSize(width: 320, height: 240))
    #expect(inspection.metadata.preferredTransform != .identity)

    let generated = try await MediaCacheGenerator().generate(
        sourceURL: sourceURL,
        cacheDirectoryURL: cacheURL,
        assetID: AssetID(),
        sourceContentHash: "sha256:test-video",
        inspection: inspection
    )
    let proxyURL = try #require(generated.proxyURL)
    #expect(FileManager.default.fileExists(atPath: proxyURL.path))
    #expect(generated.waveformURL == nil)
    let proxyInspection = try await AVAssetMediaInspector().inspect(proxyURL)
    #expect(proxyInspection.hasVideo)
    #expect(proxyInspection.duration > .zero)
}

private func writeTone(to url: URL) throws {
    let format = try #require(AVAudioFormat(
        standardFormatWithSampleRate: 8000,
        channels: 1
    ))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000))
    buffer.frameLength = 8000
    let samples = try #require(buffer.floatChannelData?[0])
    for index in 0 ..< Int(buffer.frameLength) {
        samples[index] = sin(Float(index) * 2 * .pi * 440 / 8000) * 0.6
    }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

private func writeVideo(to url: URL) throws {
    let writer = try AVAssetWriter(url: url, fileType: .mov)
    let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 320,
            AVVideoHeightKey: 240,
        ]
    )
    input.transform = CGAffineTransform(rotationAngle: .pi / 2)
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 320,
            kCVPixelBufferHeightKey as String: 240,
        ]
    )
    guard writer.canAdd(input) else { throw MediaInspectionError.inspectionFailed("Video input unavailable") }
    writer.add(input)
    guard writer.startWriting() else {
        throw writer.error ?? MediaInspectionError.inspectionFailed("Video writer did not start")
    }
    writer.startSession(atSourceTime: .zero)

    for frameIndex in 0 ..< 15 {
        while !input.isReadyForMoreMediaData { Thread.sleep(forTimeInterval: 0.001) }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            nil,
            320,
            240,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let pixelBuffer else {
            throw MediaInspectionError.inspectionFailed("Pixel buffer allocation failed")
        }
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        if let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) {
            memset(baseAddress, Int32(frameIndex * 8), CVPixelBufferGetDataSize(pixelBuffer))
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
        guard adaptor.append(
            pixelBuffer,
            withPresentationTime: CMTime(value: Int64(frameIndex), timescale: 30)
        ) else {
            throw writer.error ?? MediaInspectionError.inspectionFailed("Video frame append failed")
        }
    }
    input.markAsFinished()
    let semaphore = DispatchSemaphore(value: 0)
    writer.finishWriting { semaphore.signal() }
    semaphore.wait()
    guard writer.status == .completed else {
        throw writer.error ?? MediaInspectionError.inspectionFailed("Video writer did not finish")
    }
}
