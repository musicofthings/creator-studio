import Carbon
import Foundation

enum MacGlobalHotKeyAction: UInt32 {
    case toggleRecording = 1
    case markFocus = 2
}

/// Registers the two capture controls with the macOS hot-key service so they
/// remain available while the selected app, window, or display has focus.
@MainActor
final class MacGlobalHotKeyMonitor {
    private static let signature = OSType(0x4353_5455) // "CSTU"

    private let actionHandler: (MacGlobalHotKeyAction) -> Void
    private var eventHandler: EventHandlerRef?
    private var hotKeys: [EventHotKeyRef?] = []

    init(actionHandler: @escaping (MacGlobalHotKeyAction) -> Void) {
        self.actionHandler = actionHandler
        install()
    }

    /// The application model owns this for the lifetime of the app. This
    /// explicit teardown remains available for a future preferences reset;
    /// keeping it out of `deinit` satisfies Swift 6's actor-safe destruction
    /// rules for Carbon's non-Sendable handles.
    func unregister() {
        for hotKey in hotKeys {
            if let hotKey { UnregisterEventHotKey(hotKey) }
        }
        hotKeys.removeAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }

    private func install() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            Self.handleHotKeyEvent,
            1,
            &eventType,
            userData,
            &eventHandler
        )
        guard status == noErr else { return }

        register(keyCode: UInt32(kVK_ANSI_R), action: .toggleRecording)
        register(keyCode: UInt32(kVK_ANSI_F), action: .markFocus)
    }

    private func register(keyCode: UInt32, action: MacGlobalHotKeyAction) {
        var hotKey: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            UInt32(cmdKey) | UInt32(shiftKey),
            EventHotKeyID(signature: Self.signature, id: action.rawValue),
            GetApplicationEventTarget(),
            0,
            &hotKey
        )
        guard status == noErr else { return }
        hotKeys.append(hotKey)
    }

    private static let handleHotKeyEvent: EventHandlerUPP = { _, event, userData in
        guard let event, let userData else { return noErr }
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )
        guard status == noErr,
              hotKeyID.signature == signature,
              let action = MacGlobalHotKeyAction(rawValue: hotKeyID.id)
        else { return noErr }

        let monitor = Unmanaged<MacGlobalHotKeyMonitor>
            .fromOpaque(userData)
            .takeUnretainedValue()
        Task { @MainActor in
            monitor.actionHandler(action)
        }
        return noErr
    }
}
