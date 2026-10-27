import AppKit
import AVFoundation
import Foundation

/// Always-on-top facecam bubble on the desktop while recording (Screen Studio / Loom style).
/// `sharingType = .none` keeps it out of ScreenCaptureKit / system screen captures so the
/// facecam stays a separate timeline track rather than double-recording into the screen.
@MainActor
final class MacFloatingCameraBubbleController {
    private var panel: NSPanel?
    private var hostView: BubbleHostView?
    private var lastFrame: NSRect?

    var isVisible: Bool { panel?.isVisible == true }

    func show(session: MacCameraCaptureSession, isCircle: Bool = true, diameter: CGFloat = 176) {
        let size = max(120, diameter)
        if let panel, let hostView {
            hostView.attach(session: session, isCircle: isCircle)
            panel.setContentSize(NSSize(width: size, height: size))
            hostView.frame = NSRect(origin: .zero, size: NSSize(width: size, height: size))
            hostView.needsLayout = true
            if !panel.isVisible {
                panel.orderFrontRegardless()
            }
            return
        }

        let frame = initialFrame(size: size)
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        // Do not appear in the screen recording — camera is its own capture source.
        panel.sharingType = .none
        panel.title = "Facecam"
        panel.animationBehavior = .utilityWindow

        let host = BubbleHostView(frame: NSRect(origin: .zero, size: NSSize(width: size, height: size)))
        host.attach(session: session, isCircle: isCircle)
        panel.contentView = host

        self.panel = panel
        self.hostView = host
        lastFrame = frame
        panel.orderFrontRegardless()
    }

    func updateStyle(isCircle: Bool) {
        hostView?.setCircular(isCircle)
    }

    func hide() {
        if let panel {
            lastFrame = panel.frame
        }
        hostView?.detach()
        panel?.orderOut(nil)
        panel = nil
        hostView = nil
    }

    private func initialFrame(size: CGFloat) -> NSRect {
        if let lastFrame {
            return NSRect(origin: lastFrame.origin, size: NSSize(width: size, height: size))
        }
        let screen = NSScreen.main?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        let margin: CGFloat = 28
        return NSRect(
            x: screen.maxX - size - margin,
            y: screen.minY + margin,
            width: size,
            height: size
        )
    }
}

/// Circular/rounded host with live AVCapture preview and a subtle border ring.
private final class BubbleHostView: NSView {
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private let borderLayer = CAShapeLayer()
    private let backgroundLayer = CAShapeLayer()
    private var isCircle = true

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = false

        backgroundLayer.fillColor = NSColor.black.withAlphaComponent(0.35).cgColor
        layer?.addSublayer(backgroundLayer)

        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.strokeColor = NSColor.white.withAlphaComponent(0.92).cgColor
        borderLayer.lineWidth = 3
        borderLayer.shadowColor = NSColor.black.cgColor
        borderLayer.shadowOpacity = 0.45
        borderLayer.shadowRadius = 10
        borderLayer.shadowOffset = CGSize(width: 0, height: -2)
        layer?.addSublayer(borderLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func attach(session: MacCameraCaptureSession, isCircle: Bool) {
        self.isCircle = isCircle
        let preview = previewLayer ?? AVCaptureVideoPreviewLayer()
        preview.videoGravity = .resizeAspectFill
        preview.session = session.captureSession
        if previewLayer == nil {
            layer?.insertSublayer(preview, above: backgroundLayer)
            previewLayer = preview
        }
        configureMirroring(on: preview)
        needsLayout = true
        // Re-bind after a runloop turn so the layer paints once the window is on-screen.
        DispatchQueue.main.async { [weak self, weak session] in
            guard let self, let session else { return }
            self.previewLayer?.session = session.captureSession
            self.configureMirroring(on: self.previewLayer)
            self.layoutPreview()
        }
    }

    func setCircular(_ isCircle: Bool) {
        self.isCircle = isCircle
        needsLayout = true
    }

    func detach() {
        previewLayer?.session = nil
        previewLayer?.removeFromSuperlayer()
        previewLayer = nil
    }

    override func layout() {
        super.layout()
        layoutPreview()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Whole bubble is draggable via the panel's movable background.
        bounds.contains(point) ? self : nil
    }

    private func layoutPreview() {
        let path = if isCircle {
            CGPath(ellipseIn: bounds.insetBy(dx: 1.5, dy: 1.5), transform: nil)
        } else {
            CGPath(
                roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5),
                cornerWidth: 22,
                cornerHeight: 22,
                transform: nil
            )
        }
        backgroundLayer.path = path
        backgroundLayer.frame = bounds
        borderLayer.path = path
        borderLayer.frame = bounds

        if let previewLayer {
            previewLayer.frame = bounds
            previewLayer.mask = {
                let mask = CAShapeLayer()
                mask.path = path
                mask.frame = bounds
                return mask
            }()
        }
    }

    private func configureMirroring(on layer: AVCaptureVideoPreviewLayer?) {
        guard let connection = layer?.connection else { return }
        connection.automaticallyAdjustsVideoMirroring = false
        if connection.isVideoMirroringSupported {
            connection.isVideoMirrored = true
        }
    }
}
