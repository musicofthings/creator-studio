// Offline regression test. Run scripts/test_timeline_compositor.sh.
import AVFoundation
import CoreImage
import Foundation
import StudioDomain

@main
struct TimelineCompositorRegression {
    static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw NSError(domain: message, code: 1) }
        print("PASS: \(message)")
    }

    static func time(_ seconds: Double) -> CMTime {
        CMTime(seconds: seconds, preferredTimescale: 600)
    }

    static func main() async {
        do { try await run() } catch {
            FileHandle.standardError.write(Data("FAIL: \(error)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let redURL = root.appendingPathComponent("screen.mov")
        let cameraURL = root.appendingPathComponent("camera.mov")
        try await generate(redURL, camera: false)
        try await generate(cameraURL, camera: true)
        let screen = AVURLAsset(url: redURL)
        let camera = AVURLAsset(url: cameraURL)
        let screenTrack = try await screen.loadTracks(withMediaType: .video)[0]
        let cameraTrack = try await camera.loadTracks(withMediaType: .video)[0]
        let composition = AVMutableComposition()
        var layers: [MacCompositionLayer] = []
        func insert(_ source: AVAssetTrack, sourceStart: Double, start: Double, duration: Double,
                    frame: NormalizedRect, circle: Bool, scale: CGFloat, translation: CGPoint, sourceDuration: Double? = nil) throws {
            let track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try track.insertTimeRange(CMTimeRange(start: time(sourceStart), duration: time(sourceDuration ?? duration)), of: source, at: time(start))
            if let sourceDuration {
                track.scaleTimeRange(CMTimeRange(start: time(start), duration: time(sourceDuration)), toDuration: time(duration))
            }
            let instruction = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
            instruction.setTransform(CGAffineTransform(scaleX: scale, y: scale)
                .concatenating(CGAffineTransform(translationX: translation.x, y: translation.y)), at: time(start))
            layers.append(MacCompositionLayer(trackID: track.trackID,
                                              timeRange: CMTimeRange(start: time(start), duration: time(duration)),
                                              frame: frame, cornerRadius: circle ? 0.5 : 0, opacity: 1, transformInstruction: instruction))
        }
        // Frontmost first. Camera appears late, changes shape/location, then disappears.
        try insert(cameraTrack, sourceStart: 0, start: 0.5, duration: 1,
                   frame: NormalizedRect(x: 0.5, y: 0.5, width: 0.4, height: 0.4), circle: true,
                   scale: 0.4, translation: CGPoint(x: 160, y: 24), sourceDuration: 1.5)
        try insert(cameraTrack, sourceStart: 1, start: 2, duration: 1,
                   frame: NormalizedRect(x: 0.1, y: 0.1, width: 0.2, height: 0.6), circle: false,
                   scale: 0.6, translation: CGPoint(x: -32, y: 72))
        try insert(screenTrack, sourceStart: 0, start: 0, duration: 4,
                   frame: .fullFrame, circle: false, scale: 1, translation: .zero)
        let toneURL = root.appendingPathComponent("tone.caf")
        try generateTone(toneURL)
        let tone = AVURLAsset(url: toneURL)
        let toneTrack = try await tone.loadTracks(withMediaType: .audio)[0]
        var mixParameters: [AVAudioMixInputParameters] = []
        for (start, gain) in [(0.0, -6.0), (2.0, 0.0)] {
            let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: time(2)), of: toneTrack, at: time(start))
            mixParameters.append(try MacCompositionAudio.parameters(track: track, gainDB: gain, start: time(start)))
        }
        let video = AVMutableVideoComposition()
        video.customVideoCompositorClass = MacTimelineCompositor.self
        video.renderSize = CGSize(width: 320, height: 240)
        video.frameDuration = CMTime(value: 1, timescale: 30)
        video.instructions = [MacCompositionInstruction(timeRange: CMTimeRange(start: .zero, duration: time(4)), layers: layers)]
        let output = root.appendingPathComponent("result.mov")
        let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
        exporter.videoComposition = video
        let mix = AVMutableAudioMix()
        mix.inputParameters = mixParameters
        exporter.audioMix = mix
        try await MacCompositionExport.write(exporter, to: output)
        let result = AVURLAsset(url: output)
        let duration = try await result.load(.duration)
        try require(abs(duration.seconds - 4) < 0.04, "export preserves full duration under encoder backpressure")
        let reader = try AVAssetReader(asset: result)
        let resultTrack = try await result.loadTracks(withMediaType: .video)[0]
        let samples = AVAssetReaderTrackOutput(track: resultTrack, outputSettings: nil)
        reader.add(samples)
        try require(reader.startReading(), "exported movie can be decoded")
        var presentationTimes: [Double] = []
        while let sample = samples.copyNextSampleBuffer() {
            presentationTimes.append(CMSampleBufferGetPresentationTimeStamp(sample).seconds)
        }
        presentationTimes.sort()
        let largestGap = zip(presentationTimes, presentationTimes.dropFirst()).map { $1 - $0 }.max() ?? 4
        try require(reader.status == .completed && presentationTimes.count >= 120
            && (presentationTimes.first ?? 4) < 0.001
            && (presentationTimes.last ?? 0) >= 3.96 && largestGap < 0.034,
            "decoded frames cover the complete export without gaps")
        func pixel(_ seconds: Double, _ x: Int, _ y: Int) async throws -> [UInt8] {
            let generator = AVAssetImageGenerator(asset: result)
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            let frame = try await generator.image(at: time(seconds)).image
            var bytes = [UInt8](repeating: 0, count: 4)
            let context = CIContext()
            context.render(CIImage(cgImage: frame), toBitmap: &bytes, rowBytes: 4,
                           bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBA8,
                           colorSpace: CGColorSpaceCreateDeviceRGB())
            return bytes
        }
        func red(_ p: [UInt8]) -> Bool {
            p[0] > 180 && p[1] < 60 && p[2] < 60
        }
        func blue(_ p: [UInt8]) -> Bool {
            p[2] > 180 && p[0] < 60
        }
        func green(_ p: [UInt8]) -> Bool {
            p[1] > 150 && p[0] < 100
        }
        try require(red(try await pixel(0.2, 224, 72)), "camera hidden before its timeline start")
        try require(blue(try await pixel(1, 224, 72)), "camera composites above the screen")
        try require(green(try await pixel(1.3, 224, 72)), "scaled clip follows its playback rate")
        try require(red(try await pixel(1, 162, 26)), "circular clip masks its corners")
        try require(red(try await pixel(1.7, 224, 72)), "gap between camera clips shows screen")
        try require(green(try await pixel(2.5, 40, 100)), "later rectangular clip uses its source trim and new location")
        try require(red(try await pixel(2.5, 110, 100)), "aspect-fill source is cropped to its pane")
        try require(red(try await pixel(3.5, 40, 100)), "camera hidden after its timeline end")
        let audioReader = try AVAssetReader(asset: result)
        let resultAudio = try await result.loadTracks(withMediaType: .audio)[0]
        let audioSamples = AVAssetReaderTrackOutput(track: resultAudio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 48000,
        ])
        audioReader.add(audioSamples)
        try require(audioReader.startReading(), "exported audio can be decoded")
        var energies = [Double](repeating: 0, count: 2)
        var counts = [Int](repeating: 0, count: 2)
        while let sample = audioSamples.copyNextSampleBuffer() {
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sample).seconds
            let bucket = timestamp > 0.3 && timestamp < 1.7 ? 0 : (timestamp > 2.3 && timestamp < 3.7 ? 1 : -1)
            guard bucket >= 0, let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let size = CMBlockBufferGetDataLength(block)
            var bytes = [Float](repeating: 0, count: size / MemoryLayout<Float>.size)
            let status = bytes.withUnsafeMutableBytes { buffer in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: buffer.baseAddress!)
            }
            guard status == noErr else { throw NSError(domain: "Audio decode", code: Int(status)) }
            for value in bytes { energies[bucket] += Double(value * value); counts[bucket] += 1 }
        }
        try require(audioReader.status == .completed && counts.allSatisfy { $0 > 0 }, "audio samples span both gain regions")
        let ratio = sqrt((energies[0] / Double(counts[0])) / (energies[1] / Double(counts[1])))
        try require(abs(ratio - 0.501) < 0.04, "exported audio applies -6 dB attenuation")
        let invalid = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
        invalid.videoComposition = video
        var rejected = false
        do {
            try await MacCompositionExport.write(invalid, to: root.appendingPathComponent("missing/result.mov"))
        } catch { rejected = true }
        try require(rejected, "export failure is reported instead of publishing success")
        let canceled = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality)!
        canceled.videoComposition = video
        let cancellation = Task { try await MacCompositionExport.write(canceled, to: root.appendingPathComponent("canceled.mov")) }
        cancellation.cancel()
        var didCancel = false
        do { try await cancellation.value } catch is CancellationError { didCancel = true }
        try require(didCancel, "canceled export reports cancellation")
        print("All compositor regression checks passed.")
    }

    static func generateTone(_ url: URL) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 192_000)!
        buffer.frameLength = 192_000
        let samples = buffer.floatChannelData![0]
        for index in 0 ..< Int(buffer.frameLength) {
            samples[index] = Float(0.2 * sin(2 * Double.pi * 440 * Double(index) / 48000))
        }
        try file.write(from: buffer)
    }

    static func generate(_ url: URL, camera: Bool) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 240,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240,
        ])
        writer.add(input)
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        let context = CIContext()
        for frame in 0 ..< 120 {
            while !input.isReadyForMoreMediaData {
                guard writer.status == .writing else { throw writer.error! }
                try await Task.sleep(for: .milliseconds(2))
            }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            let color: CIColor = camera
                ? (frame < 30 ? CIColor(red: 0, green: 0, blue: 1) : CIColor(red: 0, green: 1, blue: 0))
                : CIColor(red: 1, green: 0, blue: 0)
            context.render(CIImage(color: color), to: buffer!)
            guard adaptor.append(buffer!, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw writer.error!
            }
        }
        writer.endSession(atSourceTime: time(4))
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw writer.error! }
    }
}
