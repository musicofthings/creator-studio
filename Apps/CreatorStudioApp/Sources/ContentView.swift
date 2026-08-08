import AVFoundation
import AVKit
import StudioCapture
import StudioDomain
import StudioProjectStore
import SwiftUI
import UniformTypeIdentifiers

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
                            NavigationLink {
                                ProjectEditorView(projectID: project.id)
                            } label: {
                                ProjectRow(project: project)
                            }
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
                HStack(spacing: 5) {
                    Text(project.updatedAt, format: .relative(presentation: .named))
                    Text("•")
                    Text("\(project.assetCount) source\(project.assetCount == 1 ? "" : "s")")
                }
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

private struct TimelineClipSelection {
    var track: TimelineTrack
    var clip: TimelineClip
    var index: Int
}

private struct ProjectEditorView: View {
    @EnvironmentObject private var model: AppModel
    let projectID: ProjectID

    @State private var workspace: ProjectWorkspace?
    @State private var selectedAssetID: AssetID?
    @State private var selectedClipID: ClipID?
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var isLoading = true
    @State private var isImporting = false
    @State private var isApplyingEdit = false
    @State private var isPresentingImporter = false
    @State private var loadError: String?
    @State private var statusMessage: String?
    @State private var splitSourceSeconds = 0.0

    var body: some View {
        Group {
            if isLoading {
                ProgressView("Opening project…")
            } else if let workspace {
                editor(workspace)
            } else {
                ContentUnavailableView {
                    Label("Project unavailable", systemImage: "exclamationmark.folder")
                } description: {
                    Text(loadError ?? "Creator Studio could not open this project.")
                } actions: {
                    Button("Try Again") { Task { await loadWorkspace() } }
                }
            }
        }
        .navigationTitle(workspace?.project.title ?? "Project")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .secondaryAction) {
                Button {
                    Task { await undo() }
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .disabled(workspace?.editHistory.canUndo != true || isApplyingEdit || isImporting)

                Button {
                    Task { await redo() }
                } label: {
                    Label("Redo", systemImage: "arrow.uturn.forward")
                }
                .disabled(workspace?.editHistory.canRedo != true || isApplyingEdit || isImporting)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    isPresentingImporter = true
                } label: {
                    Label("Import Media", systemImage: "plus")
                }
                .disabled(isLoading || isImporting || isApplyingEdit || workspace == nil)
            }
        }
        .fileImporter(
            isPresented: $isPresentingImporter,
            allowedContentTypes: [.movie, .audio],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                Task { await importMedia(from: urls) }
            case .failure(let error):
                model.errorMessage = error.localizedDescription
            }
        }
        .overlay {
            if isImporting || isApplyingEdit {
                ZStack {
                    Color.black.opacity(0.2).ignoresSafeArea()
                    ProgressView(isImporting ? "Copying media locally…" : "Saving timeline edit…")
                        .padding()
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
        }
        .task(id: projectID) { await loadWorkspace() }
        .onDisappear {
            player?.pause()
            isPlaying = false
        }
    }

    private func editor(_ workspace: ProjectWorkspace) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    preview(workspace)

                    if let statusMessage {
                        Label(statusMessage, systemImage: "checkmark.circle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .accessibilityElement(children: .combine)
                    }

                    if workspace.project.assets.isEmpty {
                        ContentUnavailableView {
                            Label("Add your first source", systemImage: "film.stack")
                        } description: {
                            Text("Import a video or audio file. It stays on this device and is copied into the project package.")
                        } actions: {
                            Button("Import Media") { isPresentingImporter = true }
                                .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    } else {
                        sources(workspace)
                        clipInspector(workspace)
                            .id("clip-inspector")
                        timeline(workspace)
                    }
                }
                .padding()
            }
            .task(id: selectedClipID) {
                guard selectedClipID != nil else { return }
                await Task.yield()
                try? await Task.sleep(for: .milliseconds(100))
                withAnimation {
                    proxy.scrollTo("clip-inspector", anchor: .top)
                }
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
    }

    private func preview(_ workspace: ProjectWorkspace) -> some View {
        let selectedAsset = workspace.project.assets.first { $0.id == selectedAssetID }
        return GroupBox {
            ZStack {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.black)
                if let selectedAsset, let player {
                    switch selectedAsset.kind {
                    case .screenVideo, .cameraVideo:
                        VideoPlayer(player: player)
                            .clipShape(RoundedRectangle(cornerRadius: 14))
                    case .appAudio, .microphoneAudio, .music:
                        VStack(spacing: 16) {
                            Image(systemName: "waveform.circle.fill")
                                .font(.system(size: 64))
                                .foregroundStyle(.white, .tint)
                            Button {
                                togglePlayback()
                            } label: {
                                Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.fill" : "play.fill")
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    case .image, .overlay:
                        Label("Preview unavailable", systemImage: "photo")
                            .foregroundStyle(.white)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "play.rectangle")
                            .font(.system(size: 54))
                        Text(workspace.project.assets.isEmpty ? "Import media to begin" : "Select a source or timeline clip")
                            .font(.subheadline)
                    }
                    .foregroundStyle(.white.opacity(0.75))
                }
            }
            .frame(height: 260)
        } label: {
            Label("Preview", systemImage: "play.rectangle")
        }
    }

    private func sources(_ workspace: ProjectWorkspace) -> some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(Array(workspace.project.assets.enumerated()), id: \.element.id) { index, asset in
                    Button {
                        Task { await select(asset) }
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: icon(for: asset.kind))
                                .font(.title2)
                                .frame(width: 36, height: 36)
                                .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(asset.originalFilename ?? asset.relativePath)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text(sourceDetail(asset))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if asset.id == selectedAssetID {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(.tint)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                    if index < workspace.project.assets.count - 1 { Divider() }
                }
            }
        } label: {
            Label("Sources", systemImage: "film.stack")
        }
    }

    private func timeline(_ workspace: ProjectWorkspace) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                ForEach(workspace.timeline.tracks.sorted(by: { $0.order < $1.order })) { track in
                    VStack(alignment: .leading, spacing: 7) {
                        Label(trackName(track.kind), systemImage: trackIcon(track.kind))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(track.clips) { clip in
                                    Button {
                                        if let asset = workspace.project.assets.first(where: { $0.id == clip.assetID }) {
                                            Task { await select(asset, clip: clip) }
                                        }
                                    } label: {
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(assetName(for: clip.assetID, in: workspace))
                                                .font(.caption.weight(.semibold))
                                                .lineLimit(1)
                                            Text(durationLabel(clip.timelineDuration))
                                                .font(.caption2)
                                        }
                                        .foregroundStyle(clip.isEnabled ? .primary : .secondary)
                                        .padding(10)
                                        .frame(width: clipWidth(clip), alignment: .leading)
                                        .background(
                                            clip.id == selectedClipID
                                                ? Color.accentColor.opacity(0.25)
                                                : Color.accentColor.opacity(0.12),
                                            in: RoundedRectangle(cornerRadius: 9)
                                        )
                                        .overlay {
                                            RoundedRectangle(cornerRadius: 9)
                                                .stroke(
                                                    clip.id == selectedClipID ? Color.accentColor : .clear,
                                                    lineWidth: 2
                                                )
                                        }
                                        .opacity(clip.isEnabled ? 1 : 0.55)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
        } label: {
            HStack {
                Label("Timeline", systemImage: "timeline.selection")
                Spacer()
                Button {
                    Task { await undo() }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .disabled(!workspace.editHistory.canUndo || isApplyingEdit || isImporting)
                .accessibilityLabel("Undo timeline edit")
                Button {
                    Task { await redo() }
                } label: {
                    Image(systemName: "arrow.uturn.forward")
                }
                .buttonStyle(.borderless)
                .disabled(!workspace.editHistory.canRedo || isApplyingEdit || isImporting)
                .accessibilityLabel("Redo timeline edit")
                Text("Revision \(workspace.timeline.revision)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func clipInspector(_ workspace: ProjectWorkspace) -> some View {
        if let selection = clipSelection(in: workspace),
           let asset = workspace.project.assets.first(where: { $0.id == selection.clip.assetID }) {
            GroupBox {
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

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Trim start")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Extend 0.5s") {
                                Task { await trimStart(selection.clip, extending: true) }
                            }
                            .disabled(selection.clip.sourceRange.start == .zero)
                            Button("Trim 0.5s") {
                                Task { await trimStart(selection.clip, extending: false) }
                            }
                            .disabled(selection.clip.sourceRange.duration.microseconds <= 500_000)
                        }
                        .buttonStyle(.bordered)

                        Text("Trim end")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        HStack {
                            Button("Trim 0.5s") {
                                Task { await trimEnd(selection.clip, asset: asset, extending: false) }
                            }
                            .disabled(selection.clip.sourceRange.duration.microseconds <= 500_000)
                            Button("Extend 0.5s") {
                                Task { await trimEnd(selection.clip, asset: asset, extending: true) }
                            }
                            .disabled(sourceEnd(of: selection.clip) >= asset.duration)
                        }
                        .buttonStyle(.bordered)
                    }

                    if let range = splitRange(for: selection.clip) {
                        Divider()
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Split point")
                                    .font(.caption.weight(.semibold))
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

                        Button {
                            Task { await move(selection.clip, to: selection.index + 1) }
                        } label: {
                            Label("Later", systemImage: "arrow.right")
                        }
                        .disabled(selection.index == selection.track.clips.count - 1)
                    }
                    .buttonStyle(.bordered)

                    HStack {
                        Button {
                            Task { await setEnabled(!selection.clip.isEnabled, for: selection.clip) }
                        } label: {
                            Label(
                                selection.clip.isEnabled ? "Disable" : "Enable",
                                systemImage: selection.clip.isEnabled ? "eye.slash" : "eye"
                            )
                        }
                        Button(role: .destructive) {
                            Task { await deleteClip(selection.clip) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                    .buttonStyle(.bordered)
                }
                .disabled(isApplyingEdit || isImporting)
            } label: {
                Label("Clip Inspector", systemImage: "slider.horizontal.3")
            }
        }
    }

    private func clipSelection(in workspace: ProjectWorkspace) -> TimelineClipSelection? {
        guard let selectedClipID else { return nil }
        for track in workspace.timeline.tracks {
            if let index = track.clips.firstIndex(where: { $0.id == selectedClipID }) {
                return TimelineClipSelection(track: track, clip: track.clips[index], index: index)
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
            statusMessage = "Redid the timeline edit."
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

    @MainActor
    private func loadWorkspace() async {
        isLoading = true
        loadError = nil
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
    private func importMedia(from urls: [URL]) async {
        guard let intent = workspace?.project.intent, !urls.isEmpty else { return }
        isImporting = true
        statusMessage = nil
        var importedCount = 0
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
                importedCount += 1
                await select(result.importedAsset, clip: result.appendedClip)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
            if hasSecurityScope { url.stopAccessingSecurityScopedResource() }
        }

        isImporting = false
        if importedCount > 0 {
            statusMessage = "Imported \(importedCount) source\(importedCount == 1 ? "" : "s") into the local timeline."
        }
        if !failures.isEmpty {
            model.errorMessage = failures.joined(separator: "\n")
        }
    }

    @MainActor
    private func select(_ asset: SourceAsset, clip: TimelineClip? = nil) async {
        do {
            let url = try await model.assetURL(projectID: projectID, assetID: asset.id)
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
            isPlaying = false
        } catch {
            model.errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func inspectMedia(at url: URL, intent: ProjectIntent) async throws -> MediaImportDescriptor {
        let media = AVURLAsset(url: url)
        let duration = try await media.load(.duration)
        let durationSeconds = duration.seconds
        guard durationSeconds.isFinite,
              durationSeconds > 0,
              durationSeconds <= Double(Int64.max) / 1_000_000
        else {
            throw ProjectMediaImportError.invalidDuration
        }

        let videoTracks = try await media.loadTracks(withMediaType: .video)
        if let track = videoTracks.first {
            let naturalSize = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            let transformed = CGRect(origin: .zero, size: naturalSize).applying(transform).standardized
            let pixelSize = PixelSize(
                width: Int(transformed.width.rounded()),
                height: Int(transformed.height.rounded())
            )
            guard pixelSize.width > 0, pixelSize.height > 0 else {
                throw ProjectMediaImportError.invalidPixelSize
            }
            let kind: MediaKind = switch intent {
            case .camera, .podcast: .cameraVideo
            default: .screenVideo
            }
            return MediaImportDescriptor(
                kind: kind,
                duration: StudioTime(seconds: durationSeconds),
                pixelSize: pixelSize,
                originalFilename: url.lastPathComponent
            )
        }

        let audioTracks = try await media.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw ProjectMediaImportError.unsupportedFileType(url.pathExtension)
        }
        let kind: MediaKind = switch intent {
        case .audio, .podcast: .microphoneAudio
        default: .music
        }
        return MediaImportDescriptor(
            kind: kind,
            duration: StudioTime(seconds: durationSeconds),
            originalFilename: url.lastPathComponent
        )
    }

    private func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying.toggle()
    }

    private func sourceDetail(_ asset: SourceAsset) -> String {
        var parts = [durationLabel(asset.duration)]
        if let pixelSize = asset.pixelSize {
            parts.append("\(pixelSize.width)×\(pixelSize.height)")
        }
        if let byteCount = asset.byteCount {
            parts.append(ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file))
        }
        return parts.joined(separator: " • ")
    }

    private func assetName(for id: AssetID, in workspace: ProjectWorkspace) -> String {
        workspace.project.assets.first(where: { $0.id == id })?.originalFilename ?? "Source"
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

    private func durationLabel(_ duration: StudioTime) -> String {
        Duration.seconds(duration.seconds)
            .formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated))
    }

    private func clipWidth(_ clip: TimelineClip) -> CGFloat {
        min(max(CGFloat(clip.timelineDuration.seconds) * 18, 100), 260)
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

    private func trackName(_ kind: TrackKind) -> String {
        switch kind {
        case .screen: "Screen"
        case .camera: "Camera"
        case .microphone: "Microphone"
        case .appAudio: "App Audio"
        case .music: "Music"
        case .overlay: "Overlay"
        case .annotation: "Annotations"
        case .captions: "Captions"
        }
    }

    private func trackIcon(_ kind: TrackKind) -> String {
        switch kind {
        case .screen: "rectangle.inset.filled.and.cursorarrow"
        case .camera: "video"
        case .microphone: "mic"
        case .appAudio: "speaker.wave.2"
        case .music: "music.note"
        case .overlay: "square.on.square"
        case .annotation: "pencil.and.outline"
        case .captions: "captions.bubble"
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
