import AVFoundation
import Foundation

/// A discoverable camera the user can attach as a dedicated capture source.
/// Desktop Macs do not have iPhone-style front/back pairs; they expose the
/// built-in FaceTime camera, Continuity Camera (iPhone), and USB webcams.
struct MacCameraDevice: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var position: AVCaptureDevice.Position
    var isContinuityCamera: Bool

    var displayName: String {
        if isContinuityCamera { return "\(name) (Continuity)" }
        switch position {
        case .front: return "\(name) (Front)"
        case .back: return "\(name) (Back)"
        default: return name
        }
    }

    /// Human-readable guidance for the capture settings UI.
    static var desktopAvailabilityNote: String {
        "Macs use the built-in FaceTime camera, Continuity Camera from an iPhone, or a USB webcam. There is no separate back camera like on iPhone."
    }
}

enum MacCameraDiscovery {
    /// All video devices suitable for facecam / camera-only recording.
    static func devices() -> [MacCameraDevice] {
        let deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .continuityCamera,
            .external,
        ]
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        )
        return session.devices.map { device in
            MacCameraDevice(
                id: device.uniqueID,
                name: device.localizedName,
                position: device.position,
                isContinuityCamera: device.deviceType == .continuityCamera
            )
        }
        .sorted { lhs, rhs in
            // Prefer built-in / front-facing devices for the default facecam.
            if lhs.isContinuityCamera != rhs.isContinuityCamera {
                return !lhs.isContinuityCamera && rhs.isContinuityCamera
            }
            if lhs.position != rhs.position {
                return lhs.position.rawValue < rhs.position.rawValue
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    static func defaultDevice() -> MacCameraDevice? {
        let all = devices()
        return all.first(where: { $0.position == .front && !$0.isContinuityCamera })
            ?? all.first(where: { !$0.isContinuityCamera })
            ?? all.first
    }

    static func device(id: String?) -> AVCaptureDevice? {
        guard let id else { return defaultDevice().flatMap { AVCaptureDevice(uniqueID: $0.id) } }
        return AVCaptureDevice(uniqueID: id) ?? defaultDevice().flatMap { AVCaptureDevice(uniqueID: $0.id) }
    }
}
