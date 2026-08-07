#if os(iOS)
    import ReplayKit
    import StudioCapture
    import SwiftUI

    struct BroadcastPickerView: UIViewRepresentable {
        func makeUIView(context: Context) -> RPSystemBroadcastPickerView {
            let picker = RPSystemBroadcastPickerView(frame: .zero)
            picker.preferredExtension = CaptureInboxLocation.broadcastExtensionBundleID
            picker.showsMicrophoneButton = true
            return picker
        }

        func updateUIView(_ uiView: RPSystemBroadcastPickerView, context: Context) {}
    }
#endif
