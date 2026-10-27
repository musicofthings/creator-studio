import Foundation

/// How screen + camera are composed on the output canvas. Mirrors common
/// Screen Studio / Loom / podcast layouts without baking pixels into sources.
public enum CaptureLayoutID: String, Codable, CaseIterable, Sendable, Identifiable {
    /// Full-bleed screen with a circular facecam bubble in the bottom-right.
    case screenWithCameraBubble
    /// Screen only (camera disabled or ignored for layout).
    case screenOnly
    /// Camera only (talking head).
    case cameraOnly
    /// Screen left (~62%), camera right (~38%).
    case splitScreenLeft
    /// Camera left, screen right.
    case splitCameraLeft
    /// Large camera with a small screen inset (bottom-left).
    case cameraFocus
    /// Equal side-by-side panels.
    case sideBySide

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .screenWithCameraBubble: "Screen + Bubble"
        case .screenOnly: "Screen Only"
        case .cameraOnly: "Camera Only"
        case .splitScreenLeft: "Split (Screen Left)"
        case .splitCameraLeft: "Split (Camera Left)"
        case .cameraFocus: "Camera Focus"
        case .sideBySide: "Side by Side"
        }
    }

    public var systemImage: String {
        switch self {
        case .screenWithCameraBubble: "rectangle.inset.filled.and.person.filled"
        case .screenOnly: "rectangle.dashed"
        case .cameraOnly: "person.crop.circle"
        case .splitScreenLeft: "rectangle.split.2x1"
        case .splitCameraLeft: "rectangle.split.2x1"
        case .cameraFocus: "person.crop.rectangle"
        case .sideBySide: "rectangle.split.2x1.fill"
        }
    }

    /// Default for dual-source screen+camera captures (podcast / demo style).
    public static let `default` = CaptureLayoutID.screenWithCameraBubble
}

public struct CaptureLayoutFrames: Hashable, Sendable {
    public var screen: ClipTransform?
    public var camera: ClipTransform?

    public init(screen: ClipTransform? = nil, camera: ClipTransform? = nil) {
        self.screen = screen
        self.camera = camera
    }
}

public enum CaptureLayout {
    /// Normalized frames for each role. Corner radius is encoded as a convention
    /// for preview and export (circle when ~0.5 of the smaller side).
    public static func frames(for id: CaptureLayoutID) -> CaptureLayoutFrames {
        switch id {
        case .screenOnly:
            return CaptureLayoutFrames(
                screen: ClipTransform(frame: .fullFrame),
                camera: nil
            )
        case .cameraOnly:
            return CaptureLayoutFrames(
                screen: nil,
                camera: ClipTransform(frame: .fullFrame)
            )
        case .screenWithCameraBubble:
            // Bottom-right circular facecam bubble (~22% of canvas width).
            let bubble = NormalizedRect(x: 0.74, y: 0.70, width: 0.22, height: 0.26)
            return CaptureLayoutFrames(
                screen: ClipTransform(frame: .fullFrame),
                camera: ClipTransform(frame: bubble, cornerRadius: 0.5)
            )
        case .splitScreenLeft:
            return CaptureLayoutFrames(
                screen: ClipTransform(
                    frame: NormalizedRect(x: 0.02, y: 0.08, width: 0.58, height: 0.84)
                ),
                camera: ClipTransform(
                    frame: NormalizedRect(x: 0.62, y: 0.15, width: 0.36, height: 0.70)
                )
            )
        case .splitCameraLeft:
            return CaptureLayoutFrames(
                screen: ClipTransform(
                    frame: NormalizedRect(x: 0.40, y: 0.08, width: 0.58, height: 0.84)
                ),
                camera: ClipTransform(
                    frame: NormalizedRect(x: 0.02, y: 0.15, width: 0.36, height: 0.70)
                )
            )
        case .cameraFocus:
            return CaptureLayoutFrames(
                screen: ClipTransform(
                    frame: NormalizedRect(x: 0.04, y: 0.68, width: 0.36, height: 0.28)
                ),
                camera: ClipTransform(
                    frame: NormalizedRect(x: 0.22, y: 0.06, width: 0.56, height: 0.58)
                )
            )
        case .sideBySide:
            return CaptureLayoutFrames(
                screen: ClipTransform(
                    frame: NormalizedRect(x: 0.02, y: 0.12, width: 0.47, height: 0.76)
                ),
                camera: ClipTransform(
                    frame: NormalizedRect(x: 0.51, y: 0.12, width: 0.47, height: 0.76)
                )
            )
        }
    }

    public static func transform(
        for kind: MediaKind,
        layout: CaptureLayoutID,
        cameraFrameOverride: NormalizedRect? = nil
    ) -> ClipTransform {
        let frames = frames(for: layout)
        switch kind {
        case .screenVideo:
            return frames.screen ?? ClipTransform(frame: .fullFrame)
        case .cameraVideo:
            var camera = frames.camera ?? ClipTransform(frame: .fullFrame)
            if let cameraFrameOverride {
                camera.frame = cameraFrameOverride.clampedToFrame()
            }
            return camera
        default:
            return ClipTransform()
        }
    }

    /// Keeps size; moves the camera frame so its center is at `center` (top-left origin).
    public static func cameraFrame(
        from prototype: NormalizedRect,
        centeredAt center: NormalizedPoint
    ) -> NormalizedRect {
        let w = prototype.size.width
        let h = prototype.size.height
        let x = min(max(center.x - w / 2, 0), 1 - w)
        let y = min(max(center.y - h / 2, 0), 1 - h)
        return NormalizedRect(x: x, y: y, width: w, height: h)
    }

    /// Layouts that make sense when both screen and camera sources exist.
    public static var dualSourceLayouts: [CaptureLayoutID] {
        [
            .screenWithCameraBubble,
            .splitScreenLeft,
            .splitCameraLeft,
            .cameraFocus,
            .sideBySide,
        ]
    }
}
