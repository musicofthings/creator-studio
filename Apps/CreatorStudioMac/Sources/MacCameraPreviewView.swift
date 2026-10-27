import AppKit
import AVFoundation
import StudioDomain
import SwiftUI

/// Circular (or rounded) live facecam bubble for recording preview — podcast style.
/// During live capture the bubble is pinned bottom-right of the preview host so it
/// is always visible; drag repositions it within the host.
struct MacCameraPreviewBubble: View {
    var session: MacCameraCaptureSession?
    /// Normalized layout frame (top-left origin), matching CaptureLayout.
    var frame: NormalizedRect
    var isCircle: Bool
    var isDraggable: Bool = true
    var onDragToCenter: ((NormalizedPoint) -> Void)?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // Prefer layout frame, but keep a readable minimum size in the small card.
            let rawW = max(72, frame.size.width * size.width)
            let rawH = max(72, frame.size.height * size.height)
            // For the classic bubble, force a square circle.
            let side = isCircle ? min(rawW, rawH, min(size.width, size.height) * 0.42) : min(rawW, size.width * 0.5)
            let bubbleW = isCircle ? side : rawW
            let bubbleH = isCircle ? side : max(72, rawH)

            let centerX = (frame.origin.x + frame.size.width / 2) * size.width
            let centerY = (frame.origin.y + frame.size.height / 2) * size.height
            // Clamp so the bubble stays fully inside the host.
            let x = min(max(centerX, bubbleW / 2 + 4), size.width - bubbleW / 2 - 4)
            let y = min(max(centerY, bubbleH / 2 + 4), size.height - bubbleH / 2 - 4)

            ZStack {
                if let session {
                    MacCameraPreviewRepresentable(session: session)
                        .frame(width: bubbleW, height: bubbleH)
                        .clipShape(bubbleShape)
                        .overlay(bubbleShape.stroke(Color.white.opacity(0.9), lineWidth: 2.5))
                        .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
                } else {
                    bubbleShape
                        .fill(Color.black.opacity(0.45))
                        .frame(width: bubbleW, height: bubbleH)
                        .overlay {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.white)
                        }
                        .overlay(bubbleShape.stroke(Color.white.opacity(0.5), lineWidth: 1.5))
                }
            }
            .frame(width: bubbleW, height: bubbleH)
            .position(x: x, y: y)
            .gesture(dragGesture(in: size), including: isDraggable ? .gesture : .subviews)
        }
        .contentShape(Rectangle())
    }

    private var bubbleShape: AnyShape {
        if isCircle {
            AnyShape(Circle())
        } else {
            AnyShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard isDraggable, size.width > 0, size.height > 0 else { return }
                let center = NormalizedPoint(
                    x: min(max(value.location.x / size.width, 0), 1),
                    y: min(max(value.location.y / size.height, 0), 1)
                )
                onDragToCenter?(center)
            }
    }
}

/// Type-erased shape for circle vs rounded rect.
private struct AnyShape: Shape {
    private let pathBuilder: @Sendable (CGRect) -> Path

    init<S: Shape>(_ shape: S) {
        pathBuilder = { rect in shape.path(in: rect) }
    }

    func path(in rect: CGRect) -> Path {
        pathBuilder(rect)
    }
}

private struct MacCameraPreviewRepresentable: NSViewRepresentable {
    var session: MacCameraCaptureSession

    func makeNSView(context: Context) -> PreviewHostView {
        let view = PreviewHostView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.black.cgColor
        view.layer?.masksToBounds = true
        view.bind(to: session)
        return view
    }

    func updateNSView(_ nsView: PreviewHostView, context: Context) {
        nsView.bind(to: session)
    }

    final class PreviewHostView: NSView {
        var previewLayer: AVCaptureVideoPreviewLayer?
        private weak var boundSession: MacCameraCaptureSession?

        func bind(to session: MacCameraCaptureSession) {
            boundSession = session
            let preview = previewLayer ?? AVCaptureVideoPreviewLayer()
            preview.videoGravity = .resizeAspectFill
            if previewLayer == nil {
                layer?.addSublayer(preview)
                previewLayer = preview
            }
            if preview.session !== session.captureSession {
                preview.session = session.captureSession
            }
            configureMirroring(on: preview)
            preview.frame = bounds
            // Second bind after layout — AVCapture often needs a non-zero frame first.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.boundSession === session else { return }
                self.previewLayer?.session = session.captureSession
                self.configureMirroring(on: self.previewLayer)
                self.previewLayer?.frame = self.bounds
            }
        }

        override func layout() {
            super.layout()
            previewLayer?.frame = bounds
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let session = boundSession, let previewLayer else { return }
            previewLayer.session = session.captureSession
            configureMirroring(on: previewLayer)
            previewLayer.frame = bounds
        }

        private func configureMirroring(on layer: AVCaptureVideoPreviewLayer?) {
            guard let connection = layer?.connection else { return }
            connection.automaticallyAdjustsVideoMirroring = false
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }
        }
    }
}

/// Compact layout diagram for the layout picker.
struct MacCaptureLayoutDiagram: View {
    var layout: CaptureLayoutID
    var cameraFrameOverride: NormalizedRect?

    var body: some View {
        let frames = CaptureLayout.frames(for: layout)
        let cameraFrame = cameraFrameOverride ?? frames.camera?.frame
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.12))
                if let screen = frames.screen {
                    layoutRect(screen.frame, in: geo.size, color: .accentColor.opacity(0.35))
                }
                if let cameraFrame {
                    let isBubble = layout == .screenWithCameraBubble
                        || (frames.camera?.isCircular == true)
                    layoutRect(
                        cameraFrame,
                        in: geo.size,
                        color: .orange.opacity(0.55),
                        circle: isBubble
                    )
                }
            }
        }
        .aspectRatio(16 / 10, contentMode: .fit)
    }

    @ViewBuilder
    private func layoutRect(
        _ frame: NormalizedRect,
        in size: CGSize,
        color: Color,
        circle: Bool = false
    ) -> some View {
        let rect = CGRect(
            x: frame.origin.x * size.width,
            y: frame.origin.y * size.height,
            width: frame.size.width * size.width,
            height: frame.size.height * size.height
        )
        Group {
            if circle {
                Circle().fill(color)
            } else {
                RoundedRectangle(cornerRadius: 3).fill(color)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .position(x: rect.midX, y: rect.midY)
    }
}
