import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import StudioDomain

enum MacCompositionAudio {
    static func parameters(track: AVCompositionTrack, gainDB: Double, start: CMTime) throws -> AVAudioMixInputParameters {
        guard let volume = AudioGain.linearVolume(for: gainDB) else {
            throw NSError(domain: "CreatorStudio.AudioGain", code: 1)
        }
        let parameters = AVMutableAudioMixInputParameters(track: track)
        parameters.setVolume(volume, at: start)
        return parameters
    }
}

/// Immutable once the composition is handed to AVFoundation.
struct MacCompositionLayer: @unchecked Sendable {
    let trackID: CMPersistentTrackID
    let timeRange: CMTimeRange
    let frame: NormalizedRect
    let cornerRadius: Double
    let opacity: Double
    let transformInstruction: AVVideoCompositionLayerInstruction

    func transform(at time: CMTime) -> CGAffineTransform {
        var start = CGAffineTransform.identity
        var end = CGAffineTransform.identity
        var range = CMTimeRange.zero
        guard transformInstruction.getTransformRamp(
            for: time, start: &start, end: &end, timeRange: &range
        ) else { return start }
        let fraction = range.duration.seconds > 0
            ? min(max((time - range.start).seconds / range.duration.seconds, 0), 1)
            : 0
        func interpolate(_ a: CGFloat, _ b: CGFloat) -> CGFloat {
            a + (b - a) * fraction
        }
        return CGAffineTransform(
            a: interpolate(start.a, end.a), b: interpolate(start.b, end.b),
            c: interpolate(start.c, end.c), d: interpolate(start.d, end.d),
            tx: interpolate(start.tx, end.tx), ty: interpolate(start.ty, end.ty)
        )
    }
}

final class MacCompositionInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let requiredSourceTrackIDs: [NSValue]?
    /// Frontmost first, matching AVFoundation's layer order.
    let layers: [MacCompositionLayer]

    init(timeRange: CMTimeRange, layers: [MacCompositionLayer]) {
        self.timeRange = timeRange
        self.layers = layers
        requiredSourceTrackIDs = layers.map { NSNumber(value: $0.trackID) }
        super.init()
    }
}

/// One compositor for preview and export. AVFoundation owns frame scheduling,
/// encoder backpressure and audio; masks and crops are evaluated per active clip.
final class MacTimelineCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
    private let context = CIContext()

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        autoreleasepool {
            guard let instruction = request.videoCompositionInstruction as? MacCompositionInstruction,
                  let buffer = request.renderContext.newPixelBuffer()
            else {
                request.finish(with: NSError(domain: "CreatorStudio.Compositor", code: 1))
                return
            }
            let size = request.renderContext.size
            let bounds = CGRect(origin: .zero, size: size)
            var result = CIImage(color: .black).cropped(to: bounds)
            for layer in instruction.layers.reversed() {
                guard CMTimeRangeContainsTime(layer.timeRange, time: request.compositionTime) else { continue }
                guard let source = request.sourceFrame(byTrackID: layer.trackID) else {
                    request.finish(with: NSError(domain: "CreatorStudio.Compositor", code: 2))
                    return
                }
                let target = CGRect(
                    x: layer.frame.origin.x * size.width,
                    y: (1 - layer.frame.origin.y - layer.frame.size.height) * size.height,
                    width: layer.frame.size.width * size.width,
                    height: layer.frame.size.height * size.height
                )
                var image = CIImage(cvPixelBuffer: source)
                    .transformed(by: layer.transform(at: request.compositionTime))
                    .cropped(to: target)
                if layer.cornerRadius > 0 {
                    let radius = min(target.width, target.height) * layer.cornerRadius
                    let filter: CIFilter? = if layer.cornerRadius >= 0.45 {
                        CIFilter(name: "CIRadialGradient", parameters: [
                            "inputCenter": CIVector(x: target.midX, y: target.midY),
                            "inputRadius0": max(0, radius - 0.5),
                            "inputRadius1": radius + 0.5,
                            "inputColor0": CIColor.white,
                            "inputColor1": CIColor.black,
                        ])
                    } else {
                        CIFilter(name: "CIRoundedRectangleGenerator", parameters: [
                            "inputExtent": CIVector(cgRect: target),
                            "inputRadius": radius,
                            "inputColor": CIColor.white,
                        ])
                    }
                    guard let mask = filter?.outputImage?.cropped(to: bounds) else {
                        request.finish(with: NSError(domain: "CreatorStudio.Compositor", code: 3))
                        return
                    }
                    image = image.applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputBackgroundImageKey: CIImage.empty(),
                        kCIInputMaskImageKey: mask,
                    ])
                }
                if layer.opacity < 1 {
                    image = image.applyingFilter("CIColorMatrix", parameters: [
                        "inputAVector": CIVector(x: 0, y: 0, z: 0, w: layer.opacity),
                    ])
                }
                result = image.composited(over: result)
            }
            context.render(result, to: buffer, bounds: bounds, colorSpace: CGColorSpaceCreateDeviceRGB())
            request.finish(withComposedVideoFrame: buffer)
        }
    }
}

/// Owns the session across cancellation and the completion callback. The explicit
/// Void continuation also works on macOS 15 with the Xcode 26 SDK overlay.
enum MacCompositionExport {
    private final class Session: @unchecked Sendable {
        let exporter: AVAssetExportSession
        init(_ exporter: AVAssetExportSession) {
            self.exporter = exporter
        }
    }

    static func write(_ exporter: AVAssetExportSession, to url: URL) async throws {
        let session = Session(exporter)
        session.exporter.outputURL = url
        session.exporter.outputFileType = .mov
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.exporter.exportAsynchronously { continuation.resume() }
            }
            try Task.checkCancellation()
            guard session.exporter.status == .completed else {
                throw session.exporter.error ?? NSError(domain: "CreatorStudio.Export", code: 1)
            }
        } onCancel: {
            session.exporter.cancelExport()
        }
    }
}
