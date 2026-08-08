import AppKit
import Foundation

enum MacPointerEventKind: String, Codable, Sendable {
    case movement
    case click
    case focus
}

struct MacPointerEvent: Codable, Sendable {
    var time: TimeInterval
    var x: Double
    var y: Double
    var kind: MacPointerEventKind
}

/// Captures pointer context only while an opted-in screen recording is active.
/// The sidecar stays in the same local capture session as the media and is used
/// to create editable focus events after the recording is safely imported.
final class MacPointerTracker: @unchecked Sendable {
    static let sidecarFilename = "cursor-events.jsonl"

    private let contentRect: CGRect
    private let startedUptime: TimeInterval
    private let queue = DispatchQueue(
        label: "com.creatorstudio.macos.pointer-tracking",
        qos: .utility
    )
    private let fileHandle: FileHandle
    private var monitor: Any?
    private var lastMovement: MacPointerEvent?
    private var isStopped = false

    init?(sessionDirectoryURL: URL, contentRect: CGRect) {
        guard contentRect.width > 0, contentRect.height > 0 else { return nil }
        let sidecarURL = sessionDirectoryURL.appendingPathComponent(Self.sidecarFilename)
        guard FileManager.default.createFile(atPath: sidecarURL.path, contents: nil),
              let fileHandle = try? FileHandle(forWritingTo: sidecarURL)
        else { return nil }

        self.contentRect = contentRect
        startedUptime = ProcessInfo.processInfo.systemUptime
        self.fileHandle = fileHandle
    }

    deinit {
        stop()
    }

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addGlobalMonitorForEvents(
            matching: [
                .mouseMoved,
                .leftMouseDragged,
                .rightMouseDragged,
                .otherMouseDragged,
                .leftMouseDown,
                .rightMouseDown,
                .otherMouseDown,
            ]
        ) { [weak self] event in
            let kind: MacPointerEventKind = switch event.type {
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                .click
            default:
                .movement
            }
            self?.record(point: NSEvent.mouseLocation, kind: kind)
        }
    }

    func stop() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        queue.sync {
            isStopped = true
            try? fileHandle.close()
        }
    }

    func markFocusAtCurrentCursor() {
        record(point: NSEvent.mouseLocation, kind: .focus)
    }

    static func loadEvents(from sessionDirectoryURL: URL) -> [MacPointerEvent] {
        let url = sessionDirectoryURL.appendingPathComponent(sidecarFilename)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        return text
            .split(whereSeparator: \.isNewline)
            .compactMap { try? decoder.decode(MacPointerEvent.self, from: Data($0.utf8)) }
    }

    private func record(point: NSPoint, kind: MacPointerEventKind) {
        let now = ProcessInfo.processInfo.systemUptime
        let x = (point.x - contentRect.minX) / contentRect.width
        // AppKit's global pointer coordinates originate at the lower-left;
        // focus regions use the video/editor's upper-left origin.
        let y = 1 - ((point.y - contentRect.minY) / contentRect.height)
        guard x.isFinite, y.isFinite,
              (-0.02 ... 1.02).contains(x), (-0.02 ... 1.02).contains(y)
        else { return }

        let event = MacPointerEvent(
            time: max(0, now - startedUptime),
            x: min(max(x, 0), 1),
            y: min(max(y, 0), 1),
            kind: kind
        )
        queue.async { [weak self] in
            guard let self else { return }
            guard !isStopped else { return }
            if kind == .movement,
               let previous = lastMovement,
               event.time - previous.time < 0.075,
               abs(event.x - previous.x) < 0.003,
               abs(event.y - previous.y) < 0.003 {
                return
            }
            if kind == .movement {
                lastMovement = event
            }
            guard let encoded = try? JSONEncoder().encode(event) else { return }
            fileHandle.write(encoded)
            fileHandle.write(Data([0x0A]))
        }
    }
}
