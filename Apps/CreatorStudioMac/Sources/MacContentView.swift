import AVFoundation
import AVKit
import StudioCapture
import StudioDomain
import StudioMediaPipeline
import StudioProjectStore
import SwiftUI
import UniformTypeIdentifiers

struct MacContentView: View {
    @EnvironmentObject private var model: MacAppModel

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                MacCaptureCard()
                    .padding(12)

                Divider()

                List(model.projects, selection: $model.selectedProjectID) { project in
                    MacProjectRow(project: project)
                        .tag(project.id)
                }
                .overlay {
                    if model.projects.isEmpty {
                        ContentUnavailableView(
                            "No Projects",
                            systemImage: "rectangle.stack.badge.plus",
                            description: Text("Create a project or record your Mac to begin.")
                        )
                    }
                }
            }
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
                        model.isRecording ? "Stop Recording" : "Record",
                        systemImage: model.isRecording ? "stop.circle.fill" : "record.circle"
                    )
                }
                .tint(model.isRecording ? .red : .accentColor)
                .disabled(model.captureIsBusy)
            }
        }
        .task {
            await model.refresh()
            await model.watchCaptureInbox()
        }
        .sheet(isPresented: $model.isPresentingNewProject) {
            MacNewProjectView()
                .environmentObject(model)
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
}

struct MacSettingsView: View {
    @EnvironmentObject private var model: MacAppModel

    var body: some View {
        Form {
            Section("Recording sources") {
                Toggle("Include system and application audio", isOn: $model.includeSystemAudio)
                Toggle("Include microphone", isOn: $model.includeMicrophone)
            }

            Section("Privacy") {
                Text("Recordings, recovery journals, and projects stay in Creator Studio's sandbox. Screen or microphone access is requested only when you start a recording.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: model.includeSystemAudio) { _, _ in model.updatePreflight() }
        .onChange(of: model.includeMicrophone) { _, _ in model.updatePreflight() }
    }
}

private struct MacCaptureCard: View {
    @EnvironmentObject private var model: MacAppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: statusIcon)
                    .foregroundStyle(statusColor)
                Text(statusTitle)
                    .font(.headline)
                Spacer()
                if model.captureIsBusy {
                    ProgressView().controlSize(.small)
                }
            }

            Text(model.captureMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Toggle("System audio", isOn: $model.includeSystemAudio)
                Toggle("Microphone", isOn: $model.includeMicrophone)
            }
            .toggleStyle(.checkbox)
            .disabled(model.isRecording || model.captureIsBusy)

            if let preflight = model.preflight {
                Label(
                    "About \(preflight.estimatedMinutesRemaining) min available",
                    systemImage: preflight.status == .ready ? "internaldrive" : "exclamationmark.triangle"
                )
                .font(.caption2)
                .foregroundStyle(preflight.status == .ready ? Color.secondary : Color.orange)
            }

            if !model.importableCaptures.isEmpty {
                Divider()
                Text("Ready to import")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(model.importableCaptures, id: \.sessionID) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.status == .recovered ? "Recovered recording" : "Screen recording")
                                .font(.caption.weight(.medium))
                            Text("\(item.segmentCount) committed segment\(item.segmentCount == 1 ? "" : "s")")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Import") {
                            Task { await model.importCapture(item) }
                        }
                        .controlSize(.small)
                        .disabled(model.isWorking || model.isRecording)
                    }
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .onChange(of: model.includeSystemAudio) { _, _ in model.updatePreflight() }
        .onChange(of: model.includeMicrophone) { _, _ in model.updatePreflight() }
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
        case .storageConstrained: .orange
        case .recovered: .blue
        case .finalized: .green
        default: .accentColor
        }
    }
}

private struct MacProjectRow: View {
    let project: ProjectSummary

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.title3)
                .frame(width: 30, height: 30)
                .background(.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(project.title).lineLimit(1)
                Text("\(project.assetCount) source\(project.assetCount == 1 ? "" : "s") • \(project.updatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 3)
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

private struct MacProjectDetailView: View {
    @EnvironmentObject private var model: MacAppModel
    let projectID: ProjectID

    @State private var workspace: ProjectWorkspace?
    @State private var player: AVPlayer?
    @State private var selectedAssetID: AssetID?
    @State private var isLoading = true
    @State private var isImporting = false
    @State private var isPresentingImporter = false
    @State private var loadError: String?

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
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isPresentingImporter = true
                } label: {
                    Label("Import Media", systemImage: "square.and.arrow.down")
                }
                .disabled(workspace == nil || isImporting)
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
        .task { await loadWorkspace() }
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
                        await select(refreshedAsset)
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
                                VideoPlayer(player: player)
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

                GroupBox("Timeline") {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(workspace.timeline.tracks.sorted(by: { $0.order < $1.order })) { track in
                            HStack(alignment: .top, spacing: 12) {
                                Label(track.kind.rawValue, systemImage: "timeline.selection")
                                    .font(.caption.weight(.semibold))
                                    .frame(width: 110, alignment: .leading)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 6) {
                                        ForEach(track.clips) { clip in
                                            clipTile(clip, in: workspace)
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
        }
        .overlay {
            if isImporting {
                ZStack {
                    Color.black.opacity(0.18)
                    ProgressView("Copying media into immutable project storage…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    private func loadWorkspace() async {
        isLoading = true
        do {
            let loaded = try await model.loadWorkspace(id: projectID)
            workspace = loaded
            model.ensureIngest(for: loaded)
            if let first = loaded.project.assets.first {
                await select(first)
            }
        } catch {
            workspace = nil
            loadError = error.localizedDescription
        }
        isLoading = false
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
                await select(result.importedAsset)
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

    private func select(_ asset: SourceAsset) async {
        do {
            let url = try await model.previewURL(projectID: projectID, assetID: asset.id)
            player?.pause()
            selectedAssetID = asset.id
            player = AVPlayer(url: url)
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
        .background(.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .bottomTrailing) {
            if clip.timelineStart > .zero {
                Text("+\(timelineOffsetLabel(clip.timelineStart))")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .padding(4)
            }
        }
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
