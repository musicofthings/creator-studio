import AVFoundation
import CoreMedia
import Foundation
import StudioCapture

/// Dedicated camera source (Screen Studio / Loom-style facecam). Samples feed
/// the same journaled `CaptureWriterPipeline` as screen and audio so camera
/// remains a separate immutable source on the timeline.
final class MacCameraCaptureSession: NSObject, @unchecked Sendable {
    private let session = AVCaptureSession()
    private let output = AVCaptureVideoDataOutput()
    private let sampleQueue = DispatchQueue(
        label: "com.creatorstudio.macos.camera-samples",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
    )
    private let lock = NSLock()
    private var pipeline: CaptureWriterPipeline<MacCaptureSample>?
    private var sourceObserver: (@Sendable (CaptureSource) -> Void)?
    private var didObserveSource = false
    private var isRunning = false
    private var previewLayer: AVCaptureVideoPreviewLayer?

    /// Shared session for optional live preview while recording.
    var captureSession: AVCaptureSession { session }

    var isActive: Bool {
        lock.withLock { isRunning }
    }

    func start(
        device: AVCaptureDevice,
        pipeline: CaptureWriterPipeline<MacCaptureSample>,
        sourceObserver: @escaping @Sendable (CaptureSource) -> Void
    ) throws {
        stop()

        session.beginConfiguration()
        session.sessionPreset = .high
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw MacCameraCaptureError.cannotAddInput
        }
        session.addInput(input)

        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = nil
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw MacCameraCaptureError.cannotAddOutput
        }
        session.addOutput(output)

        if let connection = output.connection(with: .video),
           connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = device.position != .back
        }
        session.commitConfiguration()

        lock.withLock {
            self.pipeline = pipeline
            self.sourceObserver = sourceObserver
            didObserveSource = false
            isRunning = true
        }

        session.startRunning()
        guard session.isRunning else {
            lock.withLock { isRunning = false }
            throw MacCameraCaptureError.cannotAddInput
        }
    }

    func stop() {
        lock.withLock {
            isRunning = false
            pipeline = nil
            sourceObserver = nil
            didObserveSource = false
        }
        output.setSampleBufferDelegate(nil, queue: nil)
        if session.isRunning {
            session.stopRunning()
        }
        session.beginConfiguration()
        session.inputs.forEach { session.removeInput($0) }
        session.outputs.forEach { session.removeOutput($0) }
        session.commitConfiguration()
        previewLayer?.session = nil
    }

    /// Attaches a mirrored live preview for the facecam bubble UI.
    @MainActor
    func makePreviewLayer() -> AVCaptureVideoPreviewLayer {
        if let previewLayer {
            previewLayer.session = session
            configureMirroring(on: previewLayer)
            return previewLayer
        }
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        configureMirroring(on: layer)
        previewLayer = layer
        return layer
    }

    @MainActor
    private func configureMirroring(on layer: AVCaptureVideoPreviewLayer) {
        guard let connection = layer.connection else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = true
        }
    }
}

extension MacCameraCaptureSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let delivery = lock.withLock { () -> (
            CaptureWriterPipeline<MacCaptureSample>?,
            (@Sendable (CaptureSource) -> Void)?
        ) in
            guard isRunning else { return (nil, nil) }
            let observer = didObserveSource ? nil : sourceObserver
            if observer != nil { didObserveSource = true }
            return (pipeline, observer)
        }
        guard let pipeline = delivery.0 else { return }
        delivery.1?(.camera)
        pipeline.enqueue(
            MacCaptureSample(sampleBuffer, hostUptime: ProcessInfo.processInfo.systemUptime),
            source: .camera
        )
    }
}

enum MacCameraCaptureError: Error, LocalizedError {
    case cannotAddInput
    case cannotAddOutput
    case deviceUnavailable

    var errorDescription: String? {
        switch self {
        case .cannotAddInput:
            "Creator Studio could not open the selected camera. It may be in use by another app."
        case .cannotAddOutput:
            "Creator Studio could not configure the camera encoder."
        case .deviceUnavailable:
            "No camera is available. Connect a webcam or enable Continuity Camera."
        }
    }
}
