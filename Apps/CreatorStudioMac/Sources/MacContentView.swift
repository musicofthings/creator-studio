import AppKit
import AVFoundation
import AVKit
import StudioCapture
import StudioDomain
import StudioExport
import StudioMediaPipeline
import StudioProjectStore
import SwiftUI
import UniformTypeIdentifiers

struct MacContentView: View {
    @EnvironmentObject private var model: MacAppModel
    @State private var projectPendingDeletion: ProjectSummary?
    @State private var expandedProjectIDs: Set<ProjectID> = []

    var body: some View {
        NavigationSplitView {
            List {
                Section {
                    MacWorkspaceSummary(
                        projectCount: model.projects.count,
                        recordingCount: model.projects.reduce(0) { $0 + $1.recordings.count }
                    )
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 4, trailing: 8))
                    .listRowBackground(Color.clear)
                } header: {
                    Label("Workspace", systemImage: "square.3.layers.3d")
                }

                Section("Projects") {
                    if model.projects.isEmpty {
                        Label("No projects yet", systemImage: "rectangle.stack.badge.plus")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(model.projects) { project in
                            MacProjectNavigationGroup(
                                project: project,
                                isSelected: model.selectedProjectID == project.id,
                                isExpanded: Binding(
                                    get: { expandedProjectIDs.contains(project.id) },
                                    set: { isExpanded in
                                        if isExpanded {
                                            expandedProjectIDs.insert(project.id)
                                        } else {
                                            expandedProjectIDs.remove(project.id)
                                        }
                                    }
                                ),
                                onOpen: {
                                    model.selectedProjectID = project.id
                                    expandedProjectIDs.insert(project.id)
                                },
                                onAddRecording: {
                                    model.requestProjectCommand(.importMedia(project.id))
                                    expandedProjectIDs.insert(project.id)
                                },
                                onDelete: {
                                    projectPendingDeletion = project
                                }
                            )
                        }
                    }
                }

                Section("Capture") {
                    MacCaptureCard()
                        .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.sidebar)
            .navigationTitle("Creator Studio")
            .navigationSplitViewColumnWidth(min: 280, ideal: 330, max: 390)
        } detail: {
            if let projectID = model.selectedProjectID {
                MacProjectDetailView(projectID: projectID)
                    .id(projectID)
            } else {
                MacWelcomeView()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    model.isPresentingNewProject = true
                } label: {
                    Label("New Project", systemImage: "plus")
                }
                .disabled(model.isWorking)
                .creatorHelp("Create a project inside the local workspace.")

                Button {
                    Task {
                        if model.isRecording {
                            await model.stopCapture()
                        } else {
                            await model.beginCapture()
                        }
                    }
                } label: {
                    Label(
                        recordActionTitle,
                        systemImage: recordActionIcon
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(recordActionColor)
                .disabled(model.captureIsBusy)
                .creatorHelp(recordActionHelp)
            }
        }
        .task {
            model.enableCaptureShortcuts()
            await model.refresh()
            if let selectedProjectID = model.selectedProjectID {
                expandedProjectIDs.insert(selectedProjectID)
            }
            await model.watchCaptureInbox()
        }
        .sheet(isPresented: $model.isPresentingNewProject) {
            MacNewProjectView()
                .environmentObject(model)
        }
        .confirmationDialog(
            "Delete \(projectPendingDeletion?.title ?? "project")?",
            isPresented: Binding(
                get: { projectPendingDeletion != nil },
                set: { if !$0 { projectPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Project", role: .destructive) {
                guard let project = projectPendingDeletion else { return }
                projectPendingDeletion = nil
                Task { await model.deleteProject(id: project.id) }
            }
        } message: {
            Text("This permanently removes the project's recordings, exports, and rebuildable caches from this Mac.")
        }
        .alert("Creator Studio", isPresented: errorBinding) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "Unknown error")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )
    }

    private var recordActionTitle: String {
        switch model.captureState {
        case .recording: "Stop Recording"
        case .preparing: "Preparing…"
        case .stopping: "Stopping…"
        case .importing: "Saving…"
        case .finalized: "New Recording"
        case .failed: "Retry Recording"
        case .storageConstrained: "Low Storage"
        default: "Record"
        }
    }

    private var recordActionIcon: String {
        switch model.captureState {
        case .recording: "stop.circle.fill"
        case .preparing: "hourglass.circle.fill"
        case .stopping: "stop.circle.fill"
        case .importing: "arrow.down.circle.fill"
        case .finalized: "checkmark.circle.fill"
        case .failed, .storageConstrained: "exclamationmark.triangle.fill"
        default: "record.circle"
        }
    }

    private var recordActionColor: Color {
        switch model.captureState {
        case .recording, .failed: .red
        case .preparing, .stopping, .importing, .storageConstrained: .orange
        case .finalized: .green
        case .recovered: .blue
        default: .red
        }
    }

    private var recordActionHelp: String {
        switch model.captureState {
        case .recording: "Stop the current screen recording and safely save its local segments."
        case .preparing, .stopping, .importing: "Capture is already in progress. Creator Studio is keeping the local recording safe."
        case .finalized: "Start another local screen recording."
        case .storageConstrained: "Free disk space before starting another screen recording."
        case .failed: "Try a new recording after reviewing the capture message."
        default: "Choose a display, window, or app to start a new screen recording."
        }
    }
}

struct MacSettingsView: View {
    @EnvironmentObject private var model: MacAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Recording", systemImage: "rectangle.dashed.badge.record")
                    .font(.title2.weight(.semibold))
                Text("Choose which audio sources accompany screen video. You still select the display, app, or window when recording starts.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox("Recording sources") {
                VStack(spacing: 0) {
                    settingsRow(
                        title: "System and application audio",
                        detail: "Capture audio delivered by the selected content.",
                        isOn: $model.includeSystemAudio
                    )
                    Divider().padding(.leading, 42)
                    settingsRow(
                        title: "Microphone",
                        detail: "Off by default. Enabling it requests microphone permission when recording starts.",
                        isOn: $model.includeMicrophone
                    )
                }
            }

            GroupBox("Privacy") {
                Label {
                    Text("Recordings, recovery journals, and projects stay in Creator Studio's local application storage. Nothing is uploaded by the capture flow.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: "lock.shield")
                        .foregroundStyle(.green)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            GroupBox("Pointer and focus") {
                VStack(spacing: 0) {
                    settingsRow(
                        title: "Show cursor",
                        detail: "Include the pointer in screen recordings.",
                        isOn: $model.showCursor
                    )
                    Divider().padding(.leading, 42)
                    settingsRow(
                        title: "Highlight mouse clicks",
                        detail: "Show a visible click pulse in the recorded video.",
                        isOn: $model.highlightMouseClicks
                    )
                    Divider().padding(.leading, 42)
                    settingsRow(
                        title: "Track pointer motion",
                        detail: "Keep local pointer movement metadata for focus suggestions.",
                        isOn: $model.trackMouseMovements
                    )
                    Divider().padding(.leading, 42)
                    settingsRow(
                        title: "Automatic focus zooms",
                        detail: "Create calm, editable zooms around clicks and focus markers after saving.",
                        isOn: $model.automaticFocusZoom
                    )
                }
            }

            GroupBox("Storage") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Projects and finished recordings are stored locally in Creator Studio's Application Support folder.")
                        .foregroundStyle(.secondary)
                    Text(model.localStoragePath)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("Each project owns immutable sources plus disposable proxy and waveform caches.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }

            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 560, height: 620, alignment: .topLeading)
        .onChange(of: model.includeSystemAudio) { _, _ in model.updatePreflight() }
        .onChange(of: model.includeMicrophone) { _, _ in model.updatePreflight() }
    }

    private func settingsRow(
        title: String,
        detail: String,
        isOn: Binding<Bool>
    ) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                Image(systemName: settingsIcon(for: title))
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 30)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.medium)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 16)
            }
        }
        .toggleStyle(.switch)
        .padding(10)
    }

    private func settingsIcon(for title: String) -> String {
        switch title {
        case "Microphone": "mic"
        case "Show cursor": "cursorarrow"
        case "Highlight mouse clicks": "cursorarrow.click"
        case "Track pointer motion": "point.3.connected.trianglepath.dotted"
        case "Automatic focus zooms": "viewfinder.circle"
        default: "speaker.wave.2"
        }
    }
}

private struct MacCaptureCard: View {
    @EnvironmentObject private var model: MacAppModel
    @State private var capturePendingDeletion: CaptureInboxItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(statusColor.opacity(0.16))
                        .frame(width: 28, height: 28)
                    Image(systemName: statusIcon)
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(statusColor)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(statusTitle)
                        .font(.headline)
                    Text(statusLabel)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(statusColor)
                }
                Spacer()
                if model.captureIsBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(statusColor)
                }
            }

            Text(model.captureMessage)
                .font(.caption)
                .foregroundStyle(statusMessageColor)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                Task {
                    if model.isRecording {
                        await model.stopCapture()
                    } else {
                        await model.beginCapture()
                    }
                }
            } label: {
                Label(captureActionTitle, systemImage: captureActionIcon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(captureActionColor)
            .disabled(model.captureIsBusy)
            .creatorHelp(captureActionHelp)

            HStack {
                Toggle("System audio", isOn: $model.includeSystemAudio)
                    .creatorHelp("Include audio supplied by the selected app, window, or display.")
                Toggle("Microphone", isOn: $model.includeMicrophone)
                    .creatorHelp("Include microphone audio. macOS asks for permission when recording begins.")
            }
            .toggleStyle(.checkbox)
            .disabled(model.isRecording || model.captureIsBusy)

            if model.isRecording {
                Button {
                    model.markFocusAtCurrentCursor()
                } label: {
                    Label("Mark Focus", systemImage: "viewfinder.circle")
                        .font(.caption.weight(.medium))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .creatorHelp("Add an editable focus zoom at the current cursor position. Shortcut: Command-Shift-F.")
            }

            if let preflight = model.preflight {
                Label(
                    "About \(preflight.estimatedMinutesRemaining) min available",
                    systemImage: preflight.status == .ready ? "internaldrive" : "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(preflight.status == .ready ? Color.secondary : Color.orange)
            }

            if model.isRecording {
                HStack(spacing: 6) {
                    captureSignal(
                        "Video",
                        systemImage: "rectangle.inset.filled",
                        isActive: model.liveCaptureSources.contains(.screen)
                    )
                    captureSignal(
                        "System audio",
                        systemImage: "speaker.wave.2.fill",
                        isActive: model.liveCaptureSources.contains(.appAudio)
                    )
                    captureSignal(
                        "Mic",
                        systemImage: "mic.fill",
                        isActive: model.liveCaptureSources.contains(.microphone)
                    )
                }
            }

            if !model.recoveryCaptures.isEmpty {
                Divider()
                Text("Recovery recordings")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(model.recoveryCaptures, id: \.sessionID) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.status == .recovered ? "Recovered recording" : "Screen recording")
                                .font(.caption.weight(.medium))
                            Text("\(item.segmentCount) committed segment\(item.segmentCount == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Save to Unlisted") {
                            Task { await model.importCapture(item) }
                        }
                        .controlSize(.small)
                        .disabled(model.isWorking || model.isRecording)
                        .creatorHelp("Copy this recovered recording into Unlisted Recordings")
                        Button(role: .destructive) {
                            capturePendingDeletion = item
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .creatorHelp("Delete this unimported recording and its recovery files")
                        .disabled(model.isWorking || model.isRecording)
                    }
                }
            }
        }
        .padding(12)
        .background(statusColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .stroke(statusColor.opacity(0.22), lineWidth: 1)
        }
        .onChange(of: model.includeSystemAudio) { _, _ in model.updatePreflight() }
        .onChange(of: model.includeMicrophone) { _, _ in model.updatePreflight() }
        .confirmationDialog(
            "Delete recovered recording?",
            isPresented: Binding(
                get: { capturePendingDeletion != nil },
                set: { if !$0 { capturePendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Recording", role: .destructive) {
                guard let item = capturePendingDeletion else { return }
                capturePendingDeletion = nil
                Task { await model.discardCapture(item) }
            }
        } message: {
            Text("This removes the unimported recording and all of its recovery files from this Mac.")
        }
    }

    private var statusTitle: String {
        switch model.captureState {
        case .recording: "Recording"
        case .stopping: "Stopping"
        case .importing: "Importing"
        case .recovered: "Recovery available"
        case .storageConstrained: "Storage constrained"
        case .failed: "Needs attention"
        case .finalized: "Recording saved"
        case .preparing: "Preparing"
        default: "Screen capture"
        }
    }

    private var statusIcon: String {
        switch model.captureState {
        case .recording: "record.circle.fill"
        case .stopping: "stop.circle"
        case .recovered: "arrow.counterclockwise.circle.fill"
        case .failed, .storageConstrained: "exclamationmark.triangle.fill"
        case .finalized: "checkmark.circle.fill"
        default: "rectangle.dashed.badge.record"
        }
    }

    private var statusColor: Color {
        switch model.captureState {
        case .recording, .failed: .red
        case .preparing, .stopping, .importing, .storageConstrained: .orange
        case .recovered: .blue
        case .finalized: .green
        default: .secondary
        }
    }

    private var statusLabel: String {
        switch model.captureState {
        case .recording: "Live local capture"
        case .preparing: "Waiting for permission"
        case .stopping: "Finalizing media"
        case .importing: "Saving a recording"
        case .finalized: "Safely saved on this Mac"
        case .recovered: "Recovery action needed"
        case .storageConstrained: "Capture paused for safety"
        case .failed: "Needs your attention"
        default: "Ready when you are"
        }
    }

    private var statusMessageColor: Color {
        switch model.captureState {
        case .failed, .storageConstrained: statusColor
        default: .secondary
        }
    }

    private var captureActionTitle: String {
        switch model.captureState {
        case .recording: "Stop and Save Recording"
        case .preparing: "Preparing Capture…"
        case .stopping: "Stopping Capture…"
        case .importing: "Saving Recording…"
        case .finalized: "Record Another Capture"
        case .failed: "Retry Recording"
        case .storageConstrained: "Check Storage and Retry"
        default: "Start Screen Recording"
        }
    }

    private var captureActionIcon: String {
        switch model.captureState {
        case .recording: "stop.fill"
        case .preparing: "hourglass"
        case .stopping: "stop.circle"
        case .importing: "arrow.down.circle"
        case .finalized: "record.circle"
        case .failed, .storageConstrained: "arrow.clockwise.circle"
        default: "record.circle"
        }
    }

    private var captureActionColor: Color {
        switch model.captureState {
        case .recording, .failed: .red
        case .preparing, .stopping, .importing, .storageConstrained: .orange
        case .finalized: .green
        case .recovered: .blue
        default: .red
        }
    }

    private var captureActionHelp: String {
        switch model.captureState {
        case .recording: "Stop the capture, finalize every segment, and save a new local recording."
        case .preparing, .stopping, .importing: "Creator Studio is already processing this recording safely."
        case .storageConstrained: "Free disk space, then retry a new screen recording."
        case .failed: "Try another screen recording after reviewing the status message."
        default: "Choose a display, application, or window in the system picker to start recording."
        }
    }

    private func captureSignal(_ title: String, systemImage: String, isActive: Bool) -> some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.medium))
            .foregroundStyle(isActive ? Color.green : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                isActive ? Color.green.opacity(0.12) : Color.secondary.opacity(0.08),
                in: Capsule()
            )
    }
}

private struct MacWorkspaceSummary: View {
    let projectCount: Int
    let recordingCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "internaldrive")
                .font(.title3)
                .frame(width: 30, height: 30)
                .background(.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text("Local Workspace")
                    .fontWeight(.medium)
                Text("\(projectCount) project\(projectCount == 1 ? "" : "s") • \(recordingCount) recording\(recordingCount == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .creatorHelp("Your local workspace contains projects, and each project contains one or more recordings. Nothing is uploaded.")
    }
}

private struct MacProjectNavigationGroup: View {
    let project: ProjectSummary
    let isSelected: Bool
    @Binding var isExpanded: Bool
    let onOpen: () -> Void
    let onAddRecording: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Button(action: onOpen) {
                    HStack(spacing: 10) {
                        Image(systemName: icon)
                            .font(.title3)
                            .frame(width: 30, height: 30)
                            .background(.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(project.title).lineLimit(1)
                            Text(projectDetail)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .padding(.vertical, 3)
                }
                .buttonStyle(.plain)
                .background(
                    isSelected ? Color.accentColor.opacity(0.16) : .clear,
                    in: RoundedRectangle(cornerRadius: 8)
                )
                .creatorHelp("Open \(project.title) and its recordings.")

                Button {
                    isExpanded.toggle()
                } label: {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption.weight(.semibold))
                        .frame(width: 18, height: 24)
                }
                .buttonStyle(.borderless)
                .creatorHelp(isExpanded ? "Hide recordings in \(project.title)" : "Show recordings in \(project.title)")

                Button(action: onAddRecording) {
                    Image(systemName: "plus.circle")
                        .frame(width: 20, height: 24)
                }
                .buttonStyle(.borderless)
                .creatorHelp("Add a video or audio recording to \(project.title)")

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "minus.circle")
                        .frame(width: 20, height: 24)
                }
                .buttonStyle(.borderless)
                .creatorHelp("Delete \(project.title) and all recordings it owns")
            }

            if isExpanded {
                if project.recordings.isEmpty {
                    Label("No recordings yet", systemImage: "film")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 42)
                        .padding(.vertical, 3)
                } else {
                    ForEach(project.recordings) { recording in
                        Button(action: onOpen) {
                            HStack(spacing: 8) {
                                Image(systemName: recordingIcon(recording))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 20)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(recording.title).lineLimit(1)
                                    Text(recordingDetail(recording))
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 3)
                            .padding(.leading, 40)
                        }
                        .buttonStyle(.plain)
                        .creatorHelp("Open \(recording.title) in \(project.title)")
                    }
                }
            }
        }
        .contextMenu {
            Button("Add Recording…", action: onAddRecording)
            Button("Delete Project…", role: .destructive, action: onDelete)
        }
    }

    private var projectDetail: String {
        "\(project.recordings.count) recording\(project.recordings.count == 1 ? "" : "s") • \(project.assetCount) source\(project.assetCount == 1 ? "" : "s")"
    }

    private var icon: String {
        switch project.intent {
        case .tutorial: "rectangle.inset.filled.and.cursorarrow"
        case .social: "rectangle.portrait"
        case .podcast: "mic"
        case .camera: "video"
        case .audio: "waveform"
        case .importOnly: "square.and.arrow.down"
        }
    }

    private func recordingIcon(_ recording: ProjectRecordingSummary) -> String {
        if recording.kinds.contains(.screenVideo) { return "rectangle.inset.filled.and.cursorarrow" }
        if recording.kinds.contains(.cameraVideo) { return "video.fill" }
        if recording.kinds.contains(.microphoneAudio) { return "mic.fill" }
        if recording.kinds.contains(.appAudio) { return "speaker.wave.2.fill" }
        return "music.note"
    }

    private func recordingDetail(_ recording: ProjectRecordingSummary) -> String {
        "\(recording.assetCount) source\(recording.assetCount == 1 ? "" : "s") • \(Duration.seconds(recording.duration.seconds).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)))"
    }
}

private struct MacWelcomeView: View {
    @EnvironmentObject private var model: MacAppModel

    var body: some View {
        ContentUnavailableView {
            Label("Create on the Mac", systemImage: "macbook.and.iphone")
        } description: {
            Text("Record a display, app, or window into recoverable local segments, or create a project and import existing media.")
        } actions: {
            HStack {
                Button("New Project") { model.isPresentingNewProject = true }
                    .buttonStyle(.bordered)
                Button("Start Recording") { Task { await model.beginCapture() } }
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct MacNewProjectView: View {
    @EnvironmentObject private var model: MacAppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = "Untitled Mac Project"
    @State private var intent: ProjectIntent = .tutorial

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("New Project").font(.title2.weight(.semibold))
            Form {
                TextField("Project name", text: $title)
                Picker("Intent", selection: $intent) {
                    ForEach(ProjectIntent.allCases, id: \.self) { intent in
                        Text(label(for: intent)).tag(intent)
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    Task { await model.createProject(title: title, intent: intent) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.isWorking)
            }
        }
        .padding(24)
        .frame(width: 440)
    }

    private func label(for intent: ProjectIntent) -> String {
        switch intent {
        case .tutorial: "Tutorial"
        case .social: "Social Clip"
        case .podcast: "Podcast"
        case .camera: "Camera"
        case .audio: "Audio"
        case .importOnly: "Import Only"
        }
    }
}

private struct MacTimelineClipSelection {
    var track: TimelineTrack
    var clip: TimelineClip
    var index: Int
}

private enum MacWorkspaceTab: Hashable {
    case media
    case editor
}

private struct MacProjectDetailView: View {
    @EnvironmentObject private var model: MacAppModel
    let projectID: ProjectID

    @State private var workspace: ProjectWorkspace?
    @State private var player: AVPlayer?
    @State private var selectedAssetID: AssetID?
    @State private var selectedClipID: ClipID?
    @State private var isLoading = true
    @State private var isImporting = false
    @State private var isApplyingEdit = false
    @State private var isClearingCache = false
    @State private var isMergingRecording = false
    @State private var isExporting = false
    @State private var isPresentingImporter = false
    @State private var isPresentingCacheClear = false
    @State private var isPresentingRecordingMerge = false
    @State private var loadError: String?
    @State private var statusMessage: String?
    @State private var splitSourceSeconds = 0.0
    @State private var workspaceTab: MacWorkspaceTab = .media

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Opening project…")
            } else if let workspace {
                projectView(workspace)
            } else {
                ContentUnavailableView(
                    "Project unavailable",
                    systemImage: "exclamationmark.folder",
                    description: Text(loadError ?? "Creator Studio could not open this project.")
                )
            }
        }
        .navigationTitle(workspace?.project.title ?? "Project")
        .toolbar {
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    isPresentingCacheClear = true
                } label: {
                    Label("Clear Rebuildable Cache", systemImage: "externaldrive.badge.xmark")
                }
                .disabled(
                    workspace == nil || isImporting || isApplyingEdit || isClearingCache
                        || workspace?.project.assets.contains(where: {
                            model.ingestStatus[$0.id]?.isRunning == true
                        }) == true
                )
                .creatorHelp("Remove only local proxy and waveform caches. Original recordings stay intact.")
            }
            ToolbarItem(placement: .secondaryAction) {
                Button {
                    isPresentingRecordingMerge = true
                } label: {
                    Label("Add Recording", systemImage: "rectangle.stack.badge.plus")
                }
                .disabled(
                    workspace == nil || isImporting || isApplyingEdit || isMergingRecording
                        || mergeCandidates.isEmpty
                )
                .creatorHelp("Append another saved Creator Studio recording to this project's master timeline.")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("1080p Landscape") {
                        export(workspace: workspace, profile: .landscapeTutorial)
                    }
                    Button("1080p Vertical") {
                        export(workspace: workspace, profile: .verticalShort)
                    }
                    Button("1080p Square") {
                        export(workspace: workspace, profile: .squareFeed)
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(
                    workspace == nil || workspace?.project.assets.isEmpty == true || isImporting
                        || isApplyingEdit || isMergingRecording || isExporting
                )
                .creatorHelp("Render the current master timeline as a local 1080p movie. Source recordings are never modified.")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await undo() }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(workspace?.editHistory.canUndo != true || isApplyingEdit || isImporting)
                .creatorHelp("Undo the last non-destructive timeline edit.")

                Button {
                    Task { await redo() }
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(workspace?.editHistory.canRedo != true || isApplyingEdit || isImporting)
                .creatorHelp("Redo the next timeline edit.")

                Button {
                    isPresentingImporter = true
                } label: {
                    Label("Import Media", systemImage: "square.and.arrow.down")
                }
                .disabled(workspace == nil || isImporting || isApplyingEdit)
                .creatorHelp("Copy video or audio from Files into this project as immutable source media.")
            }
        }
        .fileImporter(
            isPresented: $isPresentingImporter,
            allowedContentTypes: [.movie, .audio],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                Task { await importMedia(from: urls) }
            case let .failure(error):
                model.errorMessage = error.localizedDescription
            }
        }
        .confirmationDialog(
            "Clear rebuildable cache?",
            isPresented: $isPresentingCacheClear,
            titleVisibility: .visible
        ) {
            Button("Clear Cache", role: .destructive) {
                Task { await clearCache() }
            }
        } message: {
            Text("This removes locally generated proxies and waveforms for this project. Source recordings, edits, and exports are kept.")
        }
        .confirmationDialog(
            "Add a saved recording",
            isPresented: $isPresentingRecordingMerge,
            titleVisibility: .visible
        ) {
            ForEach(mergeCandidates) { project in
                Button(project.title) {
                    Task { await mergeRecording(project) }
                }
            }
        } message: {
            Text("The selected project's visible clips will be copied into this project's master timeline. The original recording remains unchanged.")
        }
        .task {
            await loadWorkspace()
            performPendingProjectCommand()
        }
        .onChange(of: model.projectCommand) { _, _ in
            performPendingProjectCommand()
        }
        .onChange(of: model.ingestStatus) { previous, current in
            guard let projectAssets = workspace?.project.assets,
                  let completedAsset = projectAssets.first(where: { asset in
                      let assetID = asset.id
                      return previous[assetID]?.phase != .complete
                          && current[assetID]?.phase == .complete
                  })
            else { return }
            Task {
                if let refreshed = try? await model.loadWorkspace(id: projectID) {
                    workspace = refreshed
                    if selectedAssetID == completedAsset.id,
                       let refreshedAsset = refreshed.project.assets.first(where: {
                           $0.id == completedAsset.id
                       }) {
                        await select(refreshedAsset, clip: clipSelection(in: refreshed)?.clip)
                    }
                }
            }
        }
        .onDisappear { player?.pause() }
    }

    private func projectView(_ workspace: ProjectWorkspace) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 18) {
                    GroupBox("Preview") {
                        ZStack {
                            Color.black
                            if let player {
                                MacNativePlayerView(player: player)
                            } else {
                                ContentUnavailableView(
                                    "Select a source",
                                    systemImage: "play.rectangle"
                                )
                                .foregroundStyle(.white.opacity(0.8))
                            }
                        }
                        .frame(minHeight: 300)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .frame(maxWidth: .infinity)

                    GroupBox("Project") {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                            GridRow { Text("Intent"); Text(workspace.project.intent.rawValue.capitalized) }
                            GridRow { Text("Sources"); Text("\(workspace.project.assets.count)") }
                            GridRow { Text("Tracks"); Text("\(workspace.timeline.tracks.count)") }
                            GridRow { Text("Revision"); Text("\(workspace.timeline.revision)") }
                        }
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 190, alignment: .leading)
                    }
                }

                Picker("Workspace", selection: $workspaceTab) {
                    Label("Media", systemImage: "film.stack").tag(MacWorkspaceTab.media)
                    Label("Editor", systemImage: "timeline.selection").tag(MacWorkspaceTab.editor)
                }
                .pickerStyle(.segmented)
                .creatorHelp("Media manages source recordings. Editor arranges clips on the master timeline.")

                if let statusMessage {
                    Label(statusMessage, systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .accessibilityElement(children: .combine)
                }

                if workspaceTab == .media {
                    GroupBox("Sources") {
                        if workspace.project.assets.isEmpty {
                            ContentUnavailableView {
                                Label("No media yet", systemImage: "film.stack")
                            } description: {
                                Text("Import video or audio. Creator Studio copies it into immutable project storage.")
                            } actions: {
                                Button("Import Media") { isPresentingImporter = true }
                            }
                            .frame(maxWidth: .infinity, minHeight: 150)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(workspace.project.assets, id: \.id) { asset in
                                    HStack(spacing: 10) {
                                        Button {
                                            Task { await select(asset) }
                                        } label: {
                                            HStack {
                                                Image(systemName: icon(for: asset.kind))
                                                    .frame(width: 28)
                                                VStack(alignment: .leading, spacing: 3) {
                                                    Text(asset.originalFilename ?? asset.relativePath)
                                                        .lineLimit(1)
                                                    Text(sourceDetail(asset))
                                                        .font(.caption)
                                                        .foregroundStyle(.secondary)
                                                    if let status = model.ingestStatus[asset.id] {
                                                        Label(status.message, systemImage: ingestIcon(status.phase))
                                                            .font(.caption2)
                                                            .foregroundStyle(ingestColor(status.phase))
                                                            .lineLimit(1)
                                                    }
                                                }
                                                Spacer()
                                                if selectedAssetID == asset.id {
                                                    Image(systemName: "checkmark.circle.fill")
                                                        .foregroundStyle(.tint)
                                                }
                                            }
                                            .contentShape(Rectangle())
                                            .padding(.vertical, 8)
                                        }
                                        .buttonStyle(.plain)

                                        if let status = model.ingestStatus[asset.id], status.isRunning {
                                            ProgressView(value: status.fractionCompleted)
                                                .frame(width: 68)
                                            Button {
                                                model.cancelIngest(assetID: asset.id)
                                            } label: {
                                                Image(systemName: "xmark.circle")
                                            }
                                            .buttonStyle(.plain)
                                            .help("Cancel rebuildable cache generation")
                                        } else if let status = model.ingestStatus[asset.id],
                                                  status.phase == .failed || status.phase == .canceled {
                                            Button {
                                                model.ensureIngest(for: workspace, assets: [asset])
                                            } label: {
                                                Image(systemName: "arrow.clockwise.circle")
                                            }
                                            .buttonStyle(.plain)
                                            .help("Retry ingest")
                                        }
                                    }
                                    Divider()
                                }
                            }
                        }
                    }
                    .creatorHelp("Sources are immutable copies stored in this project. Select one to preview it.")
                }

                if workspaceTab == .editor {
                    GroupBox("How the timeline works") {
                        VStack(alignment: .leading, spacing: 7) {
                            Text("The timeline is the editable plan for your master recording. Each horizontal row is a media role, such as screen video or microphone audio.")
                            Text("Select a clip to trim, split, move, hide, or delete it. These edits only change the timeline; they never rewrite the source recording.")
                            Text("Use Add Recording to append another saved capture while keeping its screen and audio tracks aligned.")
                        }
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    clipInspector(workspace)
                }

                if workspaceTab == .editor {
                    GroupBox("Master Timeline") {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(workspace.timeline.tracks.sorted(by: { $0.order < $1.order })) { track in
                                HStack(alignment: .top, spacing: 12) {
                                    Label(track.kind.rawValue, systemImage: "timeline.selection")
                                        .font(.caption.weight(.semibold))
                                        .frame(width: 110, alignment: .leading)
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack(spacing: 6) {
                                            ForEach(track.clips) { clip in
                                                Button {
                                                    guard let asset = workspace.project.assets.first(where: {
                                                        $0.id == clip.assetID
                                                    }) else { return }
                                                    Task { await select(asset, clip: clip) }
                                                } label: {
                                                    clipTile(clip, in: workspace)
                                                }
                                                .buttonStyle(.plain)
                                                .accessibilityLabel("Select \(assetName(clip.assetID, in: workspace)) timeline clip")
                                            }
                                        }
                                    }
                                }
                            }

                            HStack {
                                Text("Revision \(workspace.timeline.revision)")
                                Spacer()
                                Text("Edits are saved locally and never modify source media.")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .creatorHelp("Select a clip to reveal precise editing tools above. Rows play together on the shared project timeline.")
                }
            }
            .padding(20)
        }
        .overlay {
            if isImporting || isApplyingEdit || isClearingCache || isMergingRecording || isExporting {
                ZStack {
                    Color.black.opacity(0.18)
                    ProgressView(overlayMessage)
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private var overlayMessage: String {
        if isImporting { return "Copying media into immutable project storage…" }
        if isMergingRecording { return "Adding the recording to the master timeline…" }
        if isExporting { return "Rendering local 1080p movie…" }
        if isClearingCache { return "Clearing rebuildable cache…" }
        return "Saving timeline edit…"
    }

    @ViewBuilder
    private func clipInspector(_ workspace: ProjectWorkspace) -> some View {
        if let selection = clipSelection(in: workspace),
           let asset = workspace.project.assets.first(where: { $0.id == selection.clip.assetID }) {
            GroupBox("Clip Inspector") {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(asset.originalFilename ?? asset.relativePath)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                            Text(
                                "Source \(timecode(selection.clip.sourceRange.start))–\(timecode(sourceEnd(of: selection.clip))) • \(durationLabel(selection.clip.timelineDuration))"
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(selection.clip.isEnabled ? "Enabled" : "Disabled")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(selection.clip.isEnabled ? Color.green : Color.secondary)
                    }

                    Divider()

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                        GridRow {
                            Text("Trim start").foregroundStyle(.secondary)
                            HStack {
                                Button("Extend 0.5s") {
                                    Task { await trimStart(selection.clip, extending: true) }
                                }
                                .disabled(selection.clip.sourceRange.start == .zero)
                                .creatorHelp("Reveal the previous half second without changing the source file.")
                                Button("Trim 0.5s") {
                                    Task { await trimStart(selection.clip, extending: false) }
                                }
                                .disabled(selection.clip.sourceRange.duration.microseconds <= 500_000)
                                .creatorHelp("Hide the first half second from this timeline clip.")
                            }
                        }
                        GridRow {
                            Text("Trim end").foregroundStyle(.secondary)
                            HStack {
                                Button("Trim 0.5s") {
                                    Task { await trimEnd(selection.clip, asset: asset, extending: false) }
                                }
                                .disabled(selection.clip.sourceRange.duration.microseconds <= 500_000)
                                .creatorHelp("Hide the last half second from this timeline clip.")
                                Button("Extend 0.5s") {
                                    Task { await trimEnd(selection.clip, asset: asset, extending: true) }
                                }
                                .disabled(sourceEnd(of: selection.clip) >= asset.duration)
                                .creatorHelp("Reveal the next half second without changing the source file.")
                            }
                        }
                    }
                    .buttonStyle(.bordered)

                    if let range = splitRange(for: selection.clip) {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Split point").font(.caption.weight(.semibold))
                                Spacer()
                                Text(timecode(StudioTime(seconds: splitSourceSeconds)))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: $splitSourceSeconds, in: range)
                            Button {
                                Task { await split(selection.clip) }
                            } label: {
                                Label("Split Clip", systemImage: "scissors")
                            }
                            .buttonStyle(.borderedProminent)
                            .creatorHelp("Split this timeline reference at the chosen source time. The original recording stays intact.")
                        }
                    }

                    Divider()

                    HStack {
                        Button {
                            Task { await move(selection.clip, to: selection.index - 1) }
                        } label: {
                            Label("Earlier", systemImage: "arrow.left")
                        }
                        .disabled(selection.index == 0)
                        .creatorHelp("Move this clip earlier in its track and close the gap.")

                        Button {
                            Task { await move(selection.clip, to: selection.index + 1) }
                        } label: {
                            Label("Later", systemImage: "arrow.right")
                        }
                        .disabled(selection.index == selection.track.clips.count - 1)
                        .creatorHelp("Move this clip later in its track and close the gap.")

                        Spacer()

                        Button {
                            Task { await setEnabled(!selection.clip.isEnabled, for: selection.clip) }
                        } label: {
                            Label(
                                selection.clip.isEnabled ? "Disable" : "Enable",
                                systemImage: selection.clip.isEnabled ? "eye.slash" : "eye"
                            )
                        }
                        .creatorHelp(selection.clip.isEnabled ? "Hide this clip from export without deleting it." : "Include this clip in export again.")

                        Button(role: .destructive) {
                            Task { await deleteClip(selection.clip) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .creatorHelp("Remove this clip from the master timeline. Its source recording remains available and Undo restores it.")
                    }
                    .buttonStyle(.bordered)
                }
                .disabled(isApplyingEdit || isImporting)
                .padding(.vertical, 2)
            }
        }
    }

    private func clipSelection(in workspace: ProjectWorkspace) -> MacTimelineClipSelection? {
        guard let selectedClipID else { return nil }
        for track in workspace.timeline.tracks {
            if let index = track.clips.firstIndex(where: { $0.id == selectedClipID }) {
                return MacTimelineClipSelection(track: track, clip: track.clips[index], index: index)
            }
        }
        return nil
    }

    private func sourceEnd(of clip: TimelineClip) -> StudioTime {
        let (microseconds, overflow) = clip.sourceRange.start.microseconds
            .addingReportingOverflow(clip.sourceRange.duration.microseconds)
        return StudioTime(microseconds: overflow ? Int64.max : microseconds)
    }

    private func splitRange(for clip: TimelineClip) -> ClosedRange<Double>? {
        let inset: Int64 = 100_000
        guard clip.sourceRange.duration.microseconds > inset * 2 else { return nil }
        let lower = clip.sourceRange.start.microseconds + inset
        let upper = sourceEnd(of: clip).microseconds - inset
        return StudioTime(microseconds: lower).seconds ... StudioTime(microseconds: upper).seconds
    }

    private func timecode(_ time: StudioTime) -> String {
        let totalTenths = max(0, time.microseconds / 100_000)
        let hours = totalTenths / 36000
        let minutes = totalTenths / 600 % 60
        let seconds = totalTenths / 10 % 60
        let tenths = totalTenths % 10
        if hours > 0 {
            return String(format: "%lld:%02lld:%02lld.%lld", hours, minutes, seconds, tenths)
        }
        return String(format: "%lld:%02lld.%lld", minutes, seconds, tenths)
    }

    @MainActor
    private func trimStart(_ clip: TimelineClip, extending: Bool) async {
        let step: Int64 = 500_000
        let oldStart = clip.sourceRange.start.microseconds
        let end = sourceEnd(of: clip).microseconds
        let newStart = extending ? max(0, oldStart - step) : min(end - 1, oldStart + step)
        guard newStart != oldStart else { return }
        await apply(
            .trim(
                clipID: clip.id,
                sourceRange: StudioTimeRange(
                    start: StudioTime(microseconds: newStart),
                    duration: StudioTime(microseconds: end - newStart)
                )
            ),
            status: "Trimmed the clip start. The source file is unchanged."
        )
    }

    @MainActor
    private func trimEnd(_ clip: TimelineClip, asset: SourceAsset, extending: Bool) async {
        let step: Int64 = 500_000
        let start = clip.sourceRange.start.microseconds
        let oldEnd = sourceEnd(of: clip).microseconds
        let newEnd = extending
            ? min(asset.duration.microseconds, oldEnd + step)
            : max(start + 1, oldEnd - step)
        guard newEnd != oldEnd else { return }
        await apply(
            .trim(
                clipID: clip.id,
                sourceRange: StudioTimeRange(
                    start: clip.sourceRange.start,
                    duration: StudioTime(microseconds: newEnd - start)
                )
            ),
            status: "Trimmed the clip end. The source file is unchanged."
        )
    }

    @MainActor
    private func split(_ clip: TimelineClip) async {
        await apply(
            .split(
                clipID: clip.id,
                sourceTime: StudioTime(seconds: splitSourceSeconds),
                trailingClipID: ClipID()
            ),
            status: "Split the clip into two non-destructive source references."
        )
    }

    @MainActor
    private func move(_ clip: TimelineClip, to index: Int) async {
        await apply(
            .move(clipID: clip.id, toIndex: index),
            status: "Reordered the track and closed the timeline gap."
        )
    }

    @MainActor
    private func setEnabled(_ isEnabled: Bool, for clip: TimelineClip) async {
        await apply(
            .setEnabled(clipID: clip.id, isEnabled: isEnabled),
            status: isEnabled ? "Enabled the selected clip." : "Disabled the selected clip."
        )
    }

    @MainActor
    private func deleteClip(_ clip: TimelineClip) async {
        await apply(
            .delete(clipID: clip.id),
            status: "Removed the clip from the timeline. Its source remains available, and Undo can restore it."
        )
    }

    @MainActor
    private func apply(_ command: TimelineCommand, status: String) async {
        guard !isApplyingEdit else { return }
        isApplyingEdit = true
        statusMessage = nil
        defer { isApplyingEdit = false }
        do {
            let edited = try await model.applyTimelineCommand(command, to: projectID)
            workspace = edited
            reconcileSelection(in: edited)
            statusMessage = status
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func undo() async {
        guard workspace?.editHistory.canUndo == true, !isApplyingEdit else { return }
        isApplyingEdit = true
        defer { isApplyingEdit = false }
        do {
            let edited = try await model.undoTimelineEdit(projectID: projectID)
            workspace = edited
            reconcileSelection(in: edited)
            statusMessage = "Undid the last timeline edit."
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func redo() async {
        guard workspace?.editHistory.canRedo == true, !isApplyingEdit else { return }
        isApplyingEdit = true
        defer { isApplyingEdit = false }
        do {
            let edited = try await model.redoTimelineEdit(projectID: projectID)
            workspace = edited
            reconcileSelection(in: edited)
            statusMessage = "Redid the last timeline edit."
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func reconcileSelection(in workspace: ProjectWorkspace) {
        guard let selection = clipSelection(in: workspace) else {
            selectedClipID = nil
            return
        }
        selectedAssetID = selection.clip.assetID
        if let range = splitRange(for: selection.clip), !range.contains(splitSourceSeconds) {
            splitSourceSeconds = (range.lowerBound + range.upperBound) / 2
        }
    }

    private func loadWorkspace() async {
        isLoading = true
        do {
            let loaded = try await model.loadWorkspace(id: projectID)
            workspace = loaded
            if let first = loaded.project.assets.first {
                await select(first)
            }
        } catch {
            workspace = nil
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    @MainActor
    private func performPendingProjectCommand() {
        guard let workspace,
              let command = model.takeProjectCommand(for: projectID)
        else { return }

        switch command {
        case .importMedia:
            isPresentingImporter = true
        case .mergeRecording:
            isPresentingRecordingMerge = true
        case .clearCache:
            isPresentingCacheClear = true
        case let .export(_, profile):
            export(workspace: workspace, profile: profile)
        case .undo:
            Task { await undo() }
        case .redo:
            Task { await redo() }
        case .showMedia:
            workspaceTab = .media
        case .showEditor:
            workspaceTab = .editor
        case .togglePlayback:
            if let player {
                if player.timeControlStatus == .playing {
                    player.pause()
                } else {
                    player.play()
                }
            } else if let firstAsset = workspace.project.assets.first {
                Task { await select(firstAsset) }
            }
        case let .stepPlayback(_, count):
            player?.currentItem?.step(byCount: count)
        }
    }

    @MainActor
    private func clearCache() async {
        guard let workspace, !isClearingCache else { return }
        isClearingCache = true
        statusMessage = nil
        defer { isClearingCache = false }
        do {
            try await model.clearRebuildableCache(for: workspace)
            statusMessage = "Cleared local proxies and waveforms. Source recordings are unchanged."
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func mergeRecording(_ source: ProjectSummary) async {
        guard !isMergingRecording else { return }
        isMergingRecording = true
        statusMessage = nil
        defer { isMergingRecording = false }
        do {
            let merged = try await model.mergeRecording(project: source.id, into: projectID)
            workspace = merged.workspace
            workspaceTab = .editor
            statusMessage = "Added \(source.title) to the end of this master timeline. Its source files were copied locally."
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private var mergeCandidates: [ProjectSummary] {
        model.projects.filter { $0.id != projectID && $0.assetCount > 0 }
    }

    private func export(workspace: ProjectWorkspace?, profile: ExportProfile) {
        guard let workspace, !isExporting else { return }
        let panel = NSSavePanel()
        panel.title = "Export \(profile.displayName)"
        panel.allowedContentTypes = [.quickTimeMovie]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(safeFilename(workspace.project.title))-\(profile.id).mov"
        guard panel.runModal() == .OK, let outputURL = panel.url else { return }
        Task { await export(workspace: workspace, profile: profile, to: outputURL) }
    }

    @MainActor
    private func export(workspace: ProjectWorkspace, profile: ExportProfile, to outputURL: URL) async {
        isExporting = true
        statusMessage = nil
        defer { isExporting = false }
        do {
            try await model.export(workspace: workspace, profile: profile, to: outputURL)
            statusMessage = "Exported \(profile.displayName) to \(outputURL.lastPathComponent)."
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func safeFilename(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\")
        let safe = title.components(separatedBy: invalid).joined(separator: "-")
        return safe.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Creator Studio" : safe
    }

    private func importMedia(from urls: [URL]) async {
        guard let intent = workspace?.project.intent else { return }
        isImporting = true
        defer { isImporting = false }
        var failures: [String] = []

        for url in urls {
            let hasSecurityScope = url.startAccessingSecurityScopedResource()
            do {
                let descriptor = try await inspectMedia(at: url, intent: intent)
                let result = try await model.importMedia(
                    from: url,
                    descriptor: descriptor,
                    into: projectID
                )
                workspace = result.workspace
                await select(result.importedAsset, clip: result.appendedClip)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
        }
        if !failures.isEmpty {
            model.errorMessage = failures.joined(separator: "\n")
        }
    }

    private func inspectMedia(at url: URL, intent: ProjectIntent) async throws -> MediaImportDescriptor {
        let inspection = try await AVAssetMediaInspector().inspect(url)
        if inspection.hasVideo {
            let kind: MediaKind = switch intent {
            case .camera, .podcast: .cameraVideo
            default: .screenVideo
            }
            return MediaImportDescriptor(
                kind: kind,
                duration: inspection.duration,
                pixelSize: inspection.displayPixelSize,
                mediaMetadata: inspection.metadata,
                originalFilename: url.lastPathComponent
            )
        }

        guard inspection.hasAudio else {
            throw ProjectMediaImportError.unsupportedFileType(url.pathExtension)
        }
        return MediaImportDescriptor(
            kind: intent == .audio || intent == .podcast ? .microphoneAudio : .music,
            duration: inspection.duration,
            mediaMetadata: inspection.metadata,
            originalFilename: url.lastPathComponent
        )
    }

    private func select(_ asset: SourceAsset, clip: TimelineClip? = nil) async {
        do {
            if let workspace {
                model.ensureIngest(for: workspace, assets: [asset])
            }
            let url = try await model.previewURL(projectID: projectID, assetID: asset.id)
            player?.pause()
            selectedAssetID = asset.id
            selectedClipID = clip?.id
            let selectedPlayer = AVPlayer(url: url)
            if let clip {
                await selectedPlayer.seek(
                    to: CMTime(seconds: clip.sourceRange.start.seconds, preferredTimescale: 600),
                    toleranceBefore: .zero,
                    toleranceAfter: .zero
                )
                if let range = splitRange(for: clip) {
                    splitSourceSeconds = (range.lowerBound + range.upperBound) / 2
                }
            }
            player = selectedPlayer
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    private func sourceDetail(_ asset: SourceAsset) -> String {
        var details = [durationLabel(asset.duration)]
        if let pixelSize = asset.pixelSize {
            details.append("\(pixelSize.width)×\(pixelSize.height)")
        }
        if let byteCount = asset.byteCount {
            details.append(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
        }
        if asset.mediaMetadata?.isVariableFrameRate == true {
            details.append("variable frame rate")
        }
        if let audio = asset.mediaMetadata?.audioFormat {
            details.append("\(Int(audio.sampleRate.rounded())) Hz")
            details.append("\(audio.channelCount) ch")
        }
        return details.joined(separator: " • ")
    }

    private func assetName(_ id: AssetID, in workspace: ProjectWorkspace) -> String {
        workspace.project.assets.first(where: { $0.id == id })?.originalFilename ?? "Source"
    }

    private func durationLabel(_ duration: StudioTime) -> String {
        Duration.seconds(duration.seconds)
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }

    private func clipWidth(_ clip: TimelineClip) -> CGFloat {
        min(max(CGFloat(clip.timelineDuration.seconds) * 18, 100), 260)
    }

    private func clipTile(_ clip: TimelineClip, in workspace: ProjectWorkspace) -> some View {
        let waveform = model.ingestStatus[clip.assetID]?.result?.waveform
        return ZStack(alignment: .leading) {
            if let waveform, !waveform.points.isEmpty {
                MacWaveformStrip(points: waveform.points)
                    .padding(.horizontal, 6)
                    .opacity(0.75)
            }
            Text(assetName(clip.assetID, in: workspace))
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .frame(width: clipWidth(clip), height: 38, alignment: .leading)
        .background(
            clip.id == selectedClipID ? Color.accentColor.opacity(0.28) : Color.accentColor.opacity(0.14),
            in: RoundedRectangle(cornerRadius: 7)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 7)
                .stroke(clip.id == selectedClipID ? Color.accentColor : .clear, lineWidth: 2)
        }
        .overlay(alignment: .bottomTrailing) {
            if clip.timelineStart > .zero {
                Text("+\(timelineOffsetLabel(clip.timelineStart))")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
        }
        .opacity(clip.isEnabled ? 1 : 0.5)
    }

    private func timelineOffsetLabel(_ time: StudioTime) -> String {
        if time.microseconds < 1_000_000 {
            return "\(time.microseconds / 1000) ms"
        }
        return String(format: "%.2f s", time.seconds)
    }

    private func ingestIcon(_ phase: MacAssetIngestPhase) -> String {
        switch phase {
        case .complete: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .canceled: "pause.circle"
        case .queued, .inspecting, .generating: "gearshape.2"
        }
    }

    private func ingestColor(_ phase: MacAssetIngestPhase) -> Color {
        switch phase {
        case .complete: .green
        case .failed: .red
        case .canceled: .orange
        case .queued, .inspecting, .generating: .secondary
        }
    }

    private func icon(for kind: MediaKind) -> String {
        switch kind {
        case .screenVideo: "rectangle.inset.filled.and.cursorarrow"
        case .cameraVideo: "video.fill"
        case .appAudio: "speaker.wave.2.fill"
        case .microphoneAudio: "mic.fill"
        case .music: "music.note"
        case .image: "photo.fill"
        case .overlay: "square.on.square"
        }
    }
}

/// The native AppKit player avoids the private SwiftUI AVKit bridge, which can
/// abort during generic metadata resolution on Intel macOS 15 when a project
/// preview is rebuilt while another scene (such as Settings) changes.
private struct MacNativePlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        // AVPlayerView is the supported in-app route to the familiar native
        // QuickTime playback experience; the QuickTime Player app itself is
        // not an embeddable module.
        view.controlsStyle = .default
        view.videoGravity = .resizeAspect
        view.showsFrameSteppingButtons = true
        view.showsSharingServiceButton = true
        view.showsFullScreenToggleButton = true
        view.showsTimecodes = true
        view.allowsPictureInPicturePlayback = true
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player {
            view.player = player
        }
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: Void) {
        view.player = nil
    }
}

private extension View {
    /// Combines the native hover tooltip with an accessibility hint so the
    /// control remains understandable to keyboard and assistive-tech users.
    func creatorHelp(_ text: String) -> some View {
        help(text)
            .accessibilityHint(text)
    }
}

private struct MacWaveformStrip: View {
    let points: [WaveformPoint]

    var body: some View {
        Canvas { context, size in
            guard !points.isEmpty, size.width > 0, size.height > 0 else { return }
            let step = max(1, points.count / max(1, Int(size.width)))
            let visible = Swift.stride(from: 0, to: points.count, by: step).map { points[$0] }
            guard !visible.isEmpty else { return }
            var path = Path()
            let xStep = size.width / CGFloat(max(visible.count - 1, 1))
            for (index, point) in visible.enumerated() {
                let x = CGFloat(index) * xStep
                let top = (1 - CGFloat(point.maximum + 1) / 2) * size.height
                let bottom = (1 - CGFloat(point.minimum + 1) / 2) * size.height
                path.move(to: CGPoint(x: x, y: top))
                path.addLine(to: CGPoint(x: x, y: bottom))
            }
            context.stroke(path, with: .color(.accentColor.opacity(0.65)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}
