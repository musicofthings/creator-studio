import StudioExport
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
            }

            CommandGroup(replacing: .undoRedo) {
                Button("Undo Timeline Edit") {
                    guard let projectID = model.selectedProjectID else { return }
                    model.requestProjectCommand(.undo(projectID))
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(model.selectedProjectID == nil)

                Button("Redo Timeline Edit") {
                    guard let projectID = model.selectedProjectID else { return }
                    model.requestProjectCommand(.redo(projectID))
                }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(model.selectedProjectID == nil)
            }

            CommandMenu("Recording") {
                Button(model.isRecording ? "Stop Screen Recording" : "Start Screen Recording…") {
                    Task { await model.toggleCapture() }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.captureIsBusy)

                Button("Mark Focus at Current Cursor") {
                    model.markFocusAtCurrentCursor()
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(!model.isRecording)

                Divider()

                Toggle("Show Cursor in Recording", isOn: $model.showCursor)
                    .disabled(model.isRecording || model.captureIsBusy)
                Toggle("Highlight Mouse Clicks", isOn: $model.highlightMouseClicks)
                    .disabled(model.isRecording || model.captureIsBusy)
                Toggle("Track Pointer Motion", isOn: $model.trackMouseMovements)
                    .disabled(model.isRecording || model.captureIsBusy)
                Toggle("Automatic Focus Zooms", isOn: $model.automaticFocusZoom)
                    .disabled(model.isRecording || model.captureIsBusy)

                Divider()

                Button("Import Media…") {
                    guard let projectID = model.selectedProjectID else { return }
                    model.requestProjectCommand(.importMedia(projectID))
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(model.selectedProjectID == nil)

                Button("Add Saved Recording…") {
                    guard let projectID = model.selectedProjectID else { return }
                    model.requestProjectCommand(.mergeRecording(projectID))
                }
                .keyboardShortcut("a", modifiers: [.command, .shift])
                .disabled(model.selectedProjectID == nil)

                Button("Clear Rebuildable Cache…") {
                    guard let projectID = model.selectedProjectID else { return }
                    model.requestProjectCommand(.clearCache(projectID))
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(model.selectedProjectID == nil)

                Divider()

                Menu("Export Current Timeline") {
                    Button("1080p Landscape…") {
                        export(.landscapeTutorial)
                    }
                    Button("1080p Vertical…") {
                        export(.verticalShort)
                    }
                    Button("1080p Square…") {
                        export(.squareFeed)
                    }
                }
                .disabled(model.selectedProjectID == nil)
            }

            CommandMenu("Playback") {
                Button("Play / Pause") {
                    guard let projectID = model.selectedProjectID else { return }
                    model.requestProjectCommand(.togglePlayback(projectID))
                }
                .disabled(model.selectedProjectID == nil)

                Button("Step Back One Frame") {
                    stepPlayback(by: -1)
                }
                .disabled(model.selectedProjectID == nil)

                Button("Step Forward One Frame") {
                    stepPlayback(by: 1)
                }
                .disabled(model.selectedProjectID == nil)

                Divider()

                Button("Show Media") {
                    guard let projectID = model.selectedProjectID else { return }
                    model.requestProjectCommand(.showMedia(projectID))
                }

                Button("Show Editor") {
                    guard let projectID = model.selectedProjectID else { return }
                    model.requestProjectCommand(.showEditor(projectID))
                }
            }
        }

        Settings {
            MacSettingsView()
                .environmentObject(model)
        }
    }

    private func export(_ profile: ExportProfile) {
        guard let projectID = model.selectedProjectID else { return }
        model.requestProjectCommand(.export(projectID, profile))
    }

    private func stepPlayback(by count: Int) {
        guard let projectID = model.selectedProjectID else { return }
        model.requestProjectCommand(.stepPlayback(projectID, by: count))
    }
}
