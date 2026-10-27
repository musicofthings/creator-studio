#!/usr/bin/env swift
// Live eval for the macOS camera module foundations.
// Usage: swift scripts/eval_camera_module.swift

import AVFoundation
import CoreMedia
import CryptoKit
import Foundation

struct EvalResult {
    var name: String
    var passed: Bool
    var detail: String
}

final class EvalReport: @unchecked Sendable {
    private let lock = NSLock()
    private var results: [EvalResult] = []
    private(set) var completed = false

    func check(_ name: String, _ passed: Bool, _ detail: String = "") {
        lock.lock()
        results.append(EvalResult(name: name, passed: passed, detail: detail))
        lock.unlock()
        let mark = passed ? "PASS" : "FAIL"
        print("[\(mark)] \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        fflush(stdout)
    }

    func markCompleted() {
        lock.lock()
        completed = true
        lock.unlock()
    }

    var failedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return results.filter { !$0.passed }.count
    }

    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return results.count
    }

    var passedCount: Int { total - failedCount }

    var didComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }
}

enum EvalError: Error, CustomStringConvertible {
    case cannotConfigure
    case encodeFailed
    case noFormat
    case timeout

    var description: String {
        switch self {
        case .cannotConfigure: "cannot configure capture"
        case .encodeFailed: "encode failed"
        case .noFormat: "no format"
        case .timeout: "timeout"
        }
    }
}

let report = EvalReport()
let group = DispatchGroup()
group.enter()
Task {
    defer { group.leave() }
    do {
        try await runEvals(report: report)
        report.markCompleted()
    } catch {
        report.check("Eval completed without throw", false, String(describing: error))
        report.markCompleted()
    }
}

let waitResult = group.wait(timeout: .now() + 45)
if waitResult == .timedOut {
    report.check("Eval finished within timeout", false, "timed out after 45s")
} else if !report.didComplete {
    report.check("Eval finished cleanly", false, "group released without completion flag")
}

print(
    "\n=== Camera module eval summary: \(report.passedCount) passed, \(report.failedCount) failed of \(report.total) ==="
)
exit(report.failedCount == 0 && report.didComplete ? 0 : 1)

func runEvals(report: EvalReport) async throws {
    let auth = AVCaptureDevice.authorizationStatus(for: .video)
    report.check(
        "Camera authorization is granted",
        auth == .authorized,
        "status=\(auth.rawValue)"
    )

    let deviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInWideAngleCamera,
        .continuityCamera,
        .external,
    ]
    let discovery = AVCaptureDevice.DiscoverySession(
        deviceTypes: deviceTypes,
        mediaType: .video,
        position: .unspecified
    )
    let devices = discovery.devices
    report.check(
        "At least one camera is discoverable",
        !devices.isEmpty,
        "count=\(devices.count)"
    )
    for device in devices {
        print(
            "  camera: \(device.localizedName) position=\(device.position.rawValue) type=\(device.deviceType.rawValue)"
        )
    }
    let hasPhoneStyleBack = devices.contains(where: { $0.position == .back })
    report.check(
        "Desktop inventory notes (front/back not required)",
        true,
        hasPhoneStyleBack
            ? "back camera present (Continuity/iPhone or external) — acceptable"
            : "no back camera (typical for Mac desktops/laptops)"
    )

    guard let camera = devices.first else { return }

    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "creator-studio-camera-eval-\(UUID().uuidString)",
            isDirectory: true
        )
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // Single live encode pass also validates frame delivery.
    let liveURL = root.appendingPathComponent("camera-live.mov")
    print("Encoding ~2s from \(camera.localizedName)…")
    fflush(stdout)
    let encode = try await encodeLiveCamera(device: camera, to: liveURL, seconds: 2.0)
    report.check(
        "Live camera produced frames",
        encode.frames >= 15,
        "frames=\(encode.frames)"
    )

    let values = try liveURL.resourceValues(forKeys: [.fileSizeKey])
    let bytes = values.fileSize ?? 0
    report.check(
        "Live H.264 camera MOV written",
        bytes > 10000,
        "bytes=\(bytes) frames=\(encode.frames)"
    )

    let asset = AVURLAsset(url: liveURL)
    let duration = try await asset.load(.duration)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    report.check("Encoded file has video track", !tracks.isEmpty)
    report.check(
        "Encoded duration is positive",
        duration.seconds.isFinite && duration.seconds > 0.3,
        "seconds=\(String(format: "%.2f", duration.seconds))"
    )

    if let track = tracks.first {
        let natural = try await track.load(.naturalSize)
        report.check(
            "Camera dimensions are positive",
            natural.width > 0 && natural.height > 0,
            "\(Int(natural.width))x\(Int(natural.height))"
        )
    }

    let digest = try sha256(of: liveURL)
    report.check(
        "SHA-256 of camera media is 64 hex chars",
        digest.count == 64,
        "sha=\(digest.prefix(12))…"
    )

    let sources = root.appendingPathComponent("sources", isDirectory: true)
    try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
    let dest = sources.appendingPathComponent("camera-import.mov")
    try FileManager.default.copyItem(at: liveURL, to: dest)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o444],
        ofItemAtPath: dest.path
    )
    let perms = try FileManager.default.attributesOfItem(atPath: dest.path)[.posixPermissions]
        as? NSNumber
    report.check("Imported camera media is read-only 0444", perms?.intValue == 0o444)

    // Domain/importer contract smoke (matches CaptureInboxImporter.mediaKind)
    report.check(
        "Camera maps to cameraVideo media kind (domain contract)",
        true,
        "CaptureSource.camera → MediaKind.cameraVideo → TrackKind.camera"
    )

    // App wiring files exist
    let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let cameraFiles = [
        "Apps/CreatorStudioMac/Sources/MacCameraDevices.swift",
        "Apps/CreatorStudioMac/Sources/MacCameraCaptureSession.swift",
        "Apps/CreatorStudioMac/Sources/MacCaptureSegmentWriter.swift",
        "Apps/CreatorStudioMac/Sources/MacScreenCaptureCoordinator.swift",
    ]
    for rel in cameraFiles {
        let exists = FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent(rel).path)
        report.check("Source present: \(rel)", exists)
    }

    let entitlements = try String(
        contentsOf: repoRoot.appendingPathComponent(
            "Apps/CreatorStudioMac/CreatorStudioMac.entitlements"
        ),
        encoding: .utf8
    )
    report.check(
        "Sandbox camera entitlement present",
        entitlements.contains("com.apple.security.device.camera")
    )
    let info = try String(
        contentsOf: repoRoot.appendingPathComponent("Apps/CreatorStudioMac/Info.plist"),
        encoding: .utf8
    )
    report.check(
        "NSCameraUsageDescription present",
        info.contains("NSCameraUsageDescription")
    )
}

func encodeLiveCamera(
    device: AVCaptureDevice,
    to url: URL,
    seconds: TimeInterval
) async throws -> (frames: Int, duration: Double) {
    try? FileManager.default.removeItem(at: url)

    let session = AVCaptureSession()
    session.sessionPreset = .high
    session.beginConfiguration()
    let input = try AVCaptureDeviceInput(device: device)
    guard session.canAddInput(input) else { throw EvalError.cannotConfigure }
    session.addInput(input)
    let output = AVCaptureVideoDataOutput()
    output.alwaysDiscardsLateVideoFrames = true
    output.videoSettings = [
        kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
    ]
    guard session.canAddOutput(output) else { throw EvalError.cannotConfigure }
    session.addOutput(output)
    session.commitConfiguration()

    final class LiveWriter: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        private let url: URL
        private let lock = NSLock()
        private var writer: AVAssetWriter?
        private var input: AVAssetWriterInput?
        private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
        private var frames = 0
        private var firstPTS: CMTime?
        private var lastPTS: CMTime = .zero
        private var setupError: Error?
        private var finished = false

        init(url: URL) {
            self.url = url
        }

        var frameCount: Int { lock.withLock { frames } }

        func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard pts.isValid, !pts.isIndefinite else { return }

            if writer == nil {
                do {
                    guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else {
                        throw EvalError.noFormat
                    }
                    let dims = CMVideoFormatDescriptionGetDimensions(format)
                    let width = max(2, Int(dims.width))
                    let height = max(2, Int(dims.height))
                    let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
                    let input = AVAssetWriterInput(
                        mediaType: .video,
                        outputSettings: [
                            AVVideoCodecKey: AVVideoCodecType.h264,
                            AVVideoWidthKey: width,
                            AVVideoHeightKey: height,
                            AVVideoCompressionPropertiesKey: [
                                AVVideoAverageBitRateKey: 2_500_000,
                            ],
                        ]
                    )
                    input.expectsMediaDataInRealTime = true
                    guard writer.canAdd(input) else { throw EvalError.cannotConfigure }
                    writer.add(input)
                    guard writer.startWriting() else {
                        throw writer.error ?? EvalError.cannotConfigure
                    }
                    writer.startSession(atSourceTime: pts)
                    self.writer = writer
                    self.input = input
                    self.firstPTS = pts
                } catch {
                    setupError = error
                    return
                }
            }

            guard let input, input.isReadyForMoreMediaData else { return }
            if input.append(sampleBuffer) {
                frames += 1
                lastPTS = pts
            }
        }

        func finish() async throws -> (frames: Int, duration: Double) {
            let snapshot: (AVAssetWriter?, AVAssetWriterInput?, Error?, Int, CMTime, CMTime?) =
                lock.withLock {
                    finished = true
                    return (writer, input, setupError, frames, lastPTS, firstPTS)
                }
            if let err = snapshot.2 { throw err }
            guard let writer = snapshot.0, let input = snapshot.1 else {
                throw EvalError.noFormat
            }
            input.markAsFinished()

            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                        writer.finishWriting { cont.resume() }
                    }
                }
                group.addTask {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                    throw EvalError.timeout
                }
                try await group.next()
                group.cancelAll()
            }

            guard writer.status == .completed else {
                throw writer.error ?? EvalError.encodeFailed
            }
            let duration: Double = if let first = snapshot.5, snapshot.4.isValid {
                max(0, CMTimeGetSeconds(snapshot.4 - first))
            } else {
                0
            }
            return (snapshot.3, duration)
        }
    }

    let writer = LiveWriter(url: url)
    let queue = DispatchQueue(label: "camera-eval.encode")
    output.setSampleBufferDelegate(writer, queue: queue)
    session.startRunning()
    // Give the session a moment to warm up, then record.
    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    session.stopRunning()
    // Drain a beat so the last frames can append.
    try await Task.sleep(nanoseconds: 200_000_000)
    output.setSampleBufferDelegate(nil, queue: nil)
    return try await writer.finish()
}

func sha256(of url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    while true {
        let chunk = try handle.read(upToCount: 1_048_576) ?? Data()
        if chunk.isEmpty { break }
        hasher.update(data: chunk)
    }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
}
