import SwiftUI

@main
struct CreatorStudioMacApp: App {
    @StateObject private var model = MacAppModel()

    var body: some Scene {
        WindowGroup {
            MacContentView()
                .environmentObject(model)
                .frame(minWidth: 960, minHeight: 640)
        }
        .commands {
            CommandGroup(after: .newItem) {
                Button("New Project…") {
                    model.isPresentingNewProject = true
                }
                .keyboardShortcut("n", modifiers: [.command, .shift])

                Divider()

                Button(model.isRecording ? "Stop Recording" : "New Screen Recording…") {
                    Task {
                        if model.isRecording {
                            await model.stopCapture()
                        } else {
                            await model.beginCapture()
                        }
                    }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.captureIsBusy)
            }
        }

        Settings {
            MacSettingsView()
                .environmentObject(model)
                .frame(width: 460)
                .padding()
        }
    }
}
