import StudioCapture
import StudioDomain
import StudioProjectStore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var isCreating = false
    @State private var showingPreflight = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if let message = model.captureMessage {
                    CaptureStatusBanner(state: model.captureLifecycle, message: message)
                }
                Group {
                    if model.projects.isEmpty {
                        ContentUnavailableView {
                            Label("Create your first recording", systemImage: "record.circle")
                        } description: {
                            Text("Record or import once, then make tutorial, podcast, and social versions.")
                        } actions: {
                            Button("New Project") { isCreating = true }
                                .buttonStyle(.borderedProminent)
                        }
                    } else {
                        List(model.projects) { project in
                            ProjectRow(project: project)
                        }
                    }
                }
            }
            .navigationTitle("Creator Studio")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showingPreflight = true
                    } label: {
                        Label("Capture Preflight", systemImage: "checklist")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { isCreating = true } label: {
                        Label("New Project", systemImage: "plus")
                    }
                }
            }
        }
        .task { await model.refresh() }
        .sheet(isPresented: $isCreating) {
            NewProjectView()
                .environmentObject(model)
        }
        .sheet(isPresented: $showingPreflight) {
            CapturePreflightView()
                .environmentObject(model)
        }
        .alert("Something went wrong", isPresented: errorBinding) {
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
}

private struct CaptureStatusBanner: View {
    let state: CaptureState
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(tint.opacity(0.1))
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch state {
        case .ready: "Ready"
        case .recording: "Recording"
        case .stopping: "Stopping"
        case .importing: "Importing"
        case .recovered: "Recovered"
        case .storageConstrained: "Storage constrained"
        case .failed: "Capture needs attention"
        case .finalized: "Import complete"
        case .idle: "Idle"
        case .preparing: "Checking capture"
        case .canceled: "Canceled"
        }
    }

    private var icon: String {
        switch state {
        case .recording: "record.circle.fill"
        case .stopping: "stop.circle"
        case .importing: "square.and.arrow.down"
        case .recovered: "arrow.clockwise.icloud"
        case .storageConstrained: "internaldrive.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .finalized: "checkmark.circle.fill"
        default: "checkmark.shield.fill"
        }
    }

    private var tint: Color {
        switch state {
        case .recording, .failed: .red
        case .storageConstrained: .orange
        case .recovered: .blue
        default: .accentColor
        }
    }
}

private struct ProjectRow: View {
    let project: ProjectSummary

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 38, height: 38)
                .background(.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(project.title).font(.headline)
                Text(project.updatedAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(project.intent.rawValue.capitalized)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
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
}

private struct NewProjectView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                projectButton(.tutorial, icon: "rectangle.inset.filled.and.cursorarrow", detail: "Screen focus, callouts, captions")
                projectButton(.social, icon: "rectangle.portrait", detail: "Vertical layout, safe zones, brand style")
                projectButton(.podcast, icon: "mic", detail: "Long-form audio, transcript, clips")
                projectButton(.camera, icon: "video", detail: "Camera-first recording")
                projectButton(.audio, icon: "waveform", detail: "Voice or podcast audio")
                projectButton(.importOnly, icon: "square.and.arrow.down", detail: "Start with existing media")
            }
            .navigationTitle("New Project")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .disabled(model.isWorking)
        }
    }

    private func projectButton(_ intent: ProjectIntent, icon: String, detail: String) -> some View {
        Button {
            Task {
                await model.create(intent: intent)
                if model.errorMessage == nil { dismiss() }
            }
        } label: {
            Label {
                VStack(alignment: .leading) {
                    Text(intent == .importOnly ? "Import" : intent.rawValue.capitalized)
                        .font(.headline)
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: icon).font(.title2)
            }
        }
        .foregroundStyle(.primary)
    }
}

private struct CapturePreflightView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    private let capabilities = PlatformCapturePolicy().baselineCapabilities()

    var body: some View {
        NavigationStack {
            List {
                Section("Capture state") {
                    Label(lifecycleLabel, systemImage: lifecycleIcon)
                        .foregroundStyle(lifecycleTint)
                    if let message = model.captureMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Available in this build") {
                    ForEach(CaptureSource.allCases, id: \.self) { source in
                        Label(
                            sourceLabel(source),
                            systemImage: capabilities.supportedSources.contains(source) ? "checkmark.circle.fill" : "minus.circle"
                        )
                    }
                }
                Section("Before recording") {
                    Toggle(isOn: $model.includeMicrophone) {
                        Label("Plan to record microphone", systemImage: "mic")
                    }
                    Text("This checks microphone permission before you start. The microphone control in the iOS broadcast picker is what actually turns it on.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    preflightCheck(
                        "Shared capture container",
                        passed: !(model.preflight?.blockers.contains(.appGroupUnavailable) ?? true),
                        icon: "app.badge.checkmark"
                    )
                    preflightCheck(
                        storageLabel,
                        passed: model.preflight?.status != .storageConstrained,
                        icon: "internaldrive"
                    )
                    Label("Confirm the audio route in the system picker", systemImage: "speaker.wave.2")
                    Label("Hide notifications and private information", systemImage: "eye.slash")
                    Label("Recording always requires your deliberate start", systemImage: "hand.tap")
                }
                if let report = model.preflight, !report.blockers.isEmpty || !report.warnings.isEmpty {
                    Section("Preflight details") {
                        ForEach(report.blockers, id: \.self) { blocker in
                            Label(blocker.message, systemImage: "xmark.octagon.fill")
                                .foregroundStyle(.red)
                        }
                        ForEach(report.warnings, id: \.self) { warning in
                            Label(warning, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    }
                }
                if !capabilities.caveats.isEmpty {
                    Section("Platform notes") {
                        ForEach(capabilities.caveats, id: \.self) { Text($0) }
                    }
                }
                if !model.captureInbox.isEmpty {
                    Section("Capture inbox") {
                        ForEach(model.captureInbox) { item in
                            CaptureInboxRow(item: item)
                        }
                    }
                }
                Section {
                    HStack {
                        Spacer()
                        BroadcastPickerView()
                            .frame(width: 56, height: 56)
                            .accessibilityLabel("Open system screen broadcast picker")
                            .disabled(model.preflight?.status != .ready || model.isWorking)
                        Spacer()
                    }
                } footer: {
                    Text("Recording stays on this device. Creator Studio performs no cloud upload. The iOS recording indicator remains visible, and starting always requires your action in the system picker.")
                }
            }
            .navigationTitle("Capture Preflight")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await model.watchCaptureInbox() }
    }

    private func preflightCheck(_ title: String, passed: Bool, icon: String) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: passed ? "checkmark.circle.fill" : icon)
                .foregroundStyle(passed ? .green : .orange)
        }
    }

    private var storageLabel: String {
        guard let report = model.preflight else { return "Checking free storage" }
        let formatted = ByteCountFormatter.string(
            fromByteCount: report.availableStorageBytes,
            countStyle: .file
        )
        return "\(formatted) free • about \(report.estimatedMinutesRemaining) min protected estimate"
    }

    private var lifecycleLabel: String {
        switch model.captureLifecycle {
        case .ready: "Ready"
        case .recording: "Recording"
        case .stopping: "Stopping"
        case .importing: "Importing"
        case .recovered: "Recovered recording available"
        case .storageConstrained: "Storage constrained"
        case .failed: "Failed"
        case .finalized: "Import complete"
        case .idle: "Idle"
        case .preparing: "Preparing"
        case .canceled: "Canceled"
        }
    }

    private var lifecycleIcon: String {
        switch model.captureLifecycle {
        case .recording: "record.circle.fill"
        case .stopping: "stop.circle"
        case .importing: "square.and.arrow.down"
        case .recovered: "arrow.clockwise.circle.fill"
        case .storageConstrained: "internaldrive.fill"
        case .failed: "xmark.octagon.fill"
        case .finalized: "checkmark.circle.fill"
        default: "checkmark.shield"
        }
    }

    private var lifecycleTint: Color {
        switch model.captureLifecycle {
        case .recording, .failed: .red
        case .storageConstrained: .orange
        case .recovered: .blue
        default: .primary
        }
    }

    private func sourceLabel(_ source: CaptureSource) -> String {
        switch source {
        case .screen: "Screen"
        case .appAudio: "App audio"
        case .microphone: "Microphone"
        case .camera: "Camera"
        case .interactionEvents: "Interaction events"
        }
    }
}

private struct CaptureInboxRow: View {
    @EnvironmentObject private var model: AppModel
    let item: CaptureInboxItem

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(statusLabel, systemImage: statusIcon)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(item.startedAt, format: .dateTime.hour().minute())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(item.segmentCount) committed segment(s) • \(durationLabel)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let failureReason = item.failureReason {
                Text(failureReason).font(.caption).foregroundStyle(.secondary)
            }
            if item.canImport {
                Button(isRecovery ? "Recover into New Project" : "Import into New Project") {
                    Task { await model.importCapture(item) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isWorking)
            }
        }
        .padding(.vertical, 4)
    }

    private var statusLabel: String {
        switch item.status {
        case .recording: "Recording"
        case .stopping: "Stopping"
        case .completed: "Ready to import"
        case .recovered: "Interrupted • recoverable"
        case .storageConstrained: "Stopped for storage"
        case .failed: item.canImport ? "Capture failed • recoverable" : "Failed validation"
        case .imported: "Imported"
        }
    }

    private var statusIcon: String {
        switch item.status {
        case .recording: "record.circle.fill"
        case .stopping: "stop.circle"
        case .completed: "square.and.arrow.down"
        case .recovered: "arrow.clockwise.circle.fill"
        case .storageConstrained: "internaldrive.fill"
        case .failed: "xmark.octagon.fill"
        case .imported: "checkmark.circle.fill"
        }
    }

    private var durationLabel: String {
        Duration.seconds(item.duration.seconds).formatted(.units(allowed: [.minutes, .seconds], width: .abbreviated))
    }

    private var isRecovery: Bool {
        [.recovered, .storageConstrained, .failed].contains(item.status)
    }
}
