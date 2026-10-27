import AVFoundation
import Foundation
import StudioCapture
import StudioDomain
import StudioExport
import StudioMediaPipeline
import StudioProjectStore
import SwiftUI

enum MacAssetIngestPhase: Hashable, Sendable {
    case queued
    case inspecting
    case generating(MediaCacheStage)
    case complete
    case canceled
    case failed
}

private enum MacTimelineExportError: LocalizedError {
    case noVideo
    case unsupportedAdjustment
    case compositionTrack
    case invalidVideoDimensions
    case exporterUnavailable

    var errorDescription: String? {
        switch self {
        case .noVideo:
            "Add at least one video clip before exporting a movie."
        case .unsupportedAdjustment:
            "This export supports trims, splits, ordering, audio, and focus zooms. Captions and manual visual adjustments need the next render slice."
        case .compositionTrack:
            "Creator Studio could not create an export track."
        case .invalidVideoDimensions:
            "A selected video has invalid dimensions for export."
        case .exporterUnavailable:
            "This timeline cannot be exported with the available macOS encoder."
        }
    }
}

struct MacAssetIngestStatus: Hashable, Sendable {
    var phase: MacAssetIngestPhase
    var fractionCompleted: Double
    var message: String
    var result: MediaCacheGenerationResult?

    var isRunning: Bool {
        switch phase {
        case .queued, .inspecting, .generating:
            true
        case .complete, .canceled, .failed:
            false
        }
    }
}

/// Coalesces cache-generation progress callbacks before they hop to the main actor.
private final class IngestProgressGate: @unchecked Sendable {
    private let lock = NSLock()
    private var lastStage: MediaCacheStage?
    private var lastFraction = -1.0

    func shouldPublish(_ progress: MediaCacheProgress) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let stageChanged = lastStage != progress.stage
        let fractionAdvanced = progress.fractionCompleted - lastFraction >= 0.01
        guard stageChanged || fractionAdvanced || progress.fractionCompleted >= 1 else {
            return false
        }
        lastStage = progress.stage
        lastFraction = progress.fractionCompleted
        return true
    }
}

/// Routes menu-bar and sidebar quick actions to the currently open project
/// detail without coupling the app scene to view-local presentation state.
enum MacProjectCommand: Equatable {
    case importMedia(ProjectID)
    case mergeRecording(ProjectID)
    case clearCache(ProjectID)
    case export(ProjectID, ExportProfile)
    case undo(ProjectID)
    case redo(ProjectID)
    case showMedia(ProjectID)
    case showEditor(ProjectID)
    case togglePlayback(ProjectID)
    case stepPlayback(ProjectID, by: Int)

    var projectID: ProjectID {
        switch self {
        case let .importMedia(id), let .mergeRecording(id), let .clearCache(id),
             let .undo(id), let .redo(id), let .showMedia(id), let .showEditor(id),
             let .togglePlayback(id), let .stepPlayback(id, _):
            id
        case let .export(id, _):
            id
        }
    }
}

/// After a capture is saved, open the project and select the new media for preview.
struct MacRecordingReveal: Equatable, Sendable {
    var projectID: ProjectID
    var captureSessionID: UUID?
    var preferredAssetID: AssetID?
}

@MainActor
final class MacAppModel: ObservableObject {
    @Published private(set) var projects: [ProjectSummary] = []
    @Published var selectedProjectID: ProjectID?
    @Published var errorMessage: String?
    @Published var isPresentingNewProject = false
    @Published private(set) var isWorking = false
    @Published private(set) var projectCommand: MacProjectCommand?
    /// Bumped whenever a capture is imported so an already-open project reloads.
    @Published private(set) var projectContentEpoch: UInt64 = 0
    /// Latest capture save to reveal in the project detail preview.
    @Published private(set) var pendingRecordingReveal: MacRecordingReveal?

    @Published var includeSystemAudio = true
    @Published var includeMicrophone = false
    /// Loom / Screen Studio-style facecam alongside screen (or camera-only mode).
    @Published var includeCamera = true
    @Published var selectedCameraID: String?
    /// How screen + camera are composed on the canvas (bubble, split, etc.).
    @Published var captureLayout: CaptureLayoutID = .default
    /// Live drag override for the facecam bubble (top-left normalized). Nil = layout default.
    @Published var cameraBubbleFrameOverride: NormalizedRect?
    /// True while the AVCapture camera session is running (drives live bubble UI).
    @Published private(set) var isCameraLive = false
    @Published var showCursor = true
    @Published var highlightMouseClicks = true
    @Published var trackMouseMovements = true
    @Published var automaticFocusZoom = true
    @Published private(set) var availableCameras: [MacCameraDevice] = []
    @Published private(set) var captureState: CaptureState = .ready
    @Published private(set) var captureMessage = "Choose a window, application, or display when you are ready to record."
    /// Non-fatal capture notices (Accessibility, hotkey registration, etc.).
    @Published private(set) var captureNotice: String?
    @Published private(set) var captureInbox: [CaptureInboxItem] = []
    @Published private(set) var preflight: CapturePreflightReport?
    @Published private(set) var liveCaptureSources: Set<CaptureSource> = []
    @Published private(set) var ingestStatus: [AssetID: MacAssetIngestStatus] = [:]

    private let repository: FileProjectRepository
    private let captureImporter: CaptureInboxImporter
    private let captureWatcher: CaptureInboxWatcher
    private let storageRoot: URL
    private lazy var captureCoordinator = MacScreenCaptureCoordinator(
        inboxRootURL: captureInboxRoot,
        onEvent: { [weak self] event in
            self?.handleCaptureEvent(event)
        }
    )
    private let captureInboxRoot: URL
    private static let unlistedRecordingsTitle = "Unlisted Recordings"
    private struct PendingIngest {
        var projectID: ProjectID
        var asset: SourceAsset
    }

    private var ingestTasks: [AssetID: Task<Void, Never>] = [:]
    private var pendingIngest: [PendingIngest] = []
    private var activeIngestAssetID: AssetID?
    private var globalHotKeys: MacGlobalHotKeyMonitor?
    /// Desktop always-on-top facecam bubble while the camera is live.
    private let floatingCameraBubble = MacFloatingCameraBubbleController()

    init() {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        let creatorStudioRoot = applicationSupport.appendingPathComponent(
            "CreatorStudio",
            isDirectory: true
        )
        storageRoot = creatorStudioRoot
        try? fileManager.createDirectory(at: creatorStudioRoot, withIntermediateDirectories: true)
        captureInboxRoot = creatorStudioRoot.appendingPathComponent("CaptureInbox", isDirectory: true)
        try? fileManager.createDirectory(at: captureInboxRoot, withIntermediateDirectories: true)
        repository = FileProjectRepository(
            rootURL: creatorStudioRoot.appendingPathComponent("Projects", isDirectory: true)
        )
        captureImporter = CaptureInboxImporter(
            inboxRootURL: captureInboxRoot,
            repository: repository
        )
        captureWatcher = CaptureInboxWatcher(url: captureInboxRoot)
        availableCameras = MacCameraDiscovery.devices()
        selectedCameraID = MacCameraDiscovery.defaultDevice()?.id
    }

    var isRecording: Bool { captureState == .recording }

    var selectedCameraDisplayName: String {
        availableCameras.first(where: { $0.id == selectedCameraID })?.displayName
            ?? "No camera"
    }

    /// Live camera session for the on-screen facecam bubble while recording.
    var liveCameraSession: MacCameraCaptureSession? {
        guard isRecording || isCameraLive else { return nil }
        return captureCoordinator.liveCameraSession
    }

    /// Normalized camera frame for the current layout (used by the live bubble).
    var liveCameraLayoutFrame: NormalizedRect {
        if let cameraBubbleFrameOverride { return cameraBubbleFrameOverride }
        let frames = CaptureLayout.frames(for: captureLayout)
        return frames.camera?.frame
            ?? NormalizedRect(x: 0.74, y: 0.70, width: 0.22, height: 0.26)
    }

    var liveCameraIsCircle: Bool {
        captureLayout == .screenWithCameraBubble
            || (CaptureLayout.frames(for: captureLayout).camera?.isCircular == true)
    }

    func resetCameraBubbleOverride() {
        cameraBubbleFrameOverride = nil
    }

    /// Drag the live bubble; keeps current size, moves center.
    func dragCameraBubble(toNormalizedCenter center: NormalizedPoint) {
        let prototype = CaptureLayout.frames(for: captureLayout).camera?.frame
            ?? NormalizedRect(x: 0.74, y: 0.70, width: 0.22, height: 0.26)
        cameraBubbleFrameOverride = CaptureLayout.cameraFrame(
            from: cameraBubbleFrameOverride ?? prototype,
            centeredAt: center
        )
    }

    /// Re-apply layout to an existing project's screen/camera clips (undoable).
    func applyCaptureLayout(
        _ layout: CaptureLayoutID,
        to projectID: ProjectID,
        cameraFrameOverride: NormalizedRect? = nil
    ) async throws -> ProjectWorkspace {
        captureLayout = layout
        if let cameraFrameOverride {
            cameraBubbleFrameOverride = cameraFrameOverride
        } else if layout != .screenWithCameraBubble {
            cameraBubbleFrameOverride = nil
        }
        let workspace = try await repository.applyCaptureLayout(
            layout,
            to: projectID,
            cameraFrameOverride: cameraFrameOverride ?? cameraBubbleFrameOverride
        )
        projects = try await repository.list()
        return workspace
    }

    var localStoragePath: String { storageRoot.path }

    var captureIsBusy: Bool {
        switch captureState {
        case .preparing, .stopping, .importing:
            true
        default:
            false
        }
    }

    var importableCaptures: [CaptureInboxItem] {
        captureInbox.filter(\.canImport)
    }

    /// Captures that still need a person-initiated save (or a retry after auto-import
    /// failed). Includes stuck `.completed` sessions left in the inbox.
    var recoveryCaptures: [CaptureInboxItem] {
        captureInbox.filter {
            $0.canImport
                && [.completed, .recovered, .storageConstrained, .failed].contains($0.status)
        }
    }

    func takePendingRecordingReveal(for projectID: ProjectID) -> MacRecordingReveal? {
        guard let pendingRecordingReveal, pendingRecordingReveal.projectID == projectID else {
            return nil
        }
        self.pendingRecordingReveal = nil
        return pendingRecordingReveal
    }

    func enableCaptureShortcuts() {
        guard globalHotKeys == nil else { return }
        let monitor = MacGlobalHotKeyMonitor { [weak self] action in
            guard let self else { return }
            switch action {
            case .toggleRecording:
                Task { await self.toggleCapture() }
            case .markFocus:
                self.markFocusAtCurrentCursor()
            }
        }
        globalHotKeys = monitor
        if monitor.registrationFailed {
            captureNotice =
                "Global shortcuts (⌘⇧R / ⌘⇧F) could not be registered. Use the menu bar or capture controls instead."
        }
    }

    func openAccessibilitySettings() {
        MacPointerTracker.openAccessibilitySettings()
    }

    func dismissCaptureNotice() {
        captureNotice = nil
    }

    func toggleCapture() async {
        if isRecording {
            await stopCapture()
        } else {
            await beginCapture()
        }
    }

    func refresh() async {
        do {
            async let listedProjects = repository.list()
            async let discoveredCaptures = captureImporter.discover()
            projects = try await listedProjects
            captureInbox = await discoveredCaptures
            updatePreflight()
            if selectedProjectID == nil {
                selectedProjectID = projects.first?.id
            }
            // Completed sessions that never auto-imported (e.g. older dual-source
            // clock bugs) stay in the inbox — retry them quietly so stop→view works.
            if captureState == .ready || captureState == .finalized || captureState == .failed
                || captureState == .recovered {
                let stuckCompleted = captureInbox.filter {
                    $0.status == .completed && $0.canImport
                }
                for item in stuckCompleted {
                    await saveCapture(item, discardingStagingCopy: true)
                }
            }
            if captureState == .ready,
               let recoverable = importableCaptures.first(where: {
                   [.recovered, .storageConstrained, .failed].contains($0.status)
               }) {
                captureState = .recovered
                captureMessage = "An interrupted recording has \(recoverable.segmentCount) committed segment(s) ready to recover."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func requestProjectCommand(_ command: MacProjectCommand) {
        selectedProjectID = command.projectID
        projectCommand = command
    }

    func takeProjectCommand(for projectID: ProjectID) -> MacProjectCommand? {
        guard let projectCommand, projectCommand.projectID == projectID else { return nil }
        self.projectCommand = nil
        return projectCommand
    }

    func watchCaptureInbox() async {
        for await _ in captureWatcher.changes() {
            if Task.isCancelled { return }
            captureInbox = await captureImporter.discover()
            guard captureState != .recording,
                  captureState != .stopping,
                  captureState != .importing
            else { continue }
            if let recoverable = importableCaptures.first(where: { $0.status == .recovered }) {
                captureState = .recovered
                captureMessage = "An interrupted recording has \(recoverable.segmentCount) committed segment(s) ready to recover."
            }
        }
    }

    func createProject(title: String, intent: ProjectIntent) async {
        isWorking = true
        defer { isWorking = false }
        do {
            let project = try await repository.create(title: title, intent: intent)
            projects = try await repository.list()
            selectedProjectID = project.id
            isPresentingNewProject = false
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func deleteProject(id: ProjectID) async {
        isWorking = true
        defer { isWorking = false }
        do {
            if let workspace = try? await repository.loadWorkspace(id: id) {
                for asset in workspace.project.assets {
                    cancelIngest(assetID: asset.id)
                }
            }
            try await repository.delete(id: id)
            projects = try await repository.list()
            if selectedProjectID == id {
                selectedProjectID = projects.first?.id
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadWorkspace(id: ProjectID) async throws -> ProjectWorkspace {
        try await repository.loadWorkspace(id: id)
    }

    func importMedia(
        from sourceURL: URL,
        descriptor: MediaImportDescriptor,
        into projectID: ProjectID
    ) async throws -> ProjectMediaImportResult {
        let result = try await repository.importMedia(
            from: sourceURL,
            descriptor: descriptor,
            into: projectID
        )
        projects = try await repository.list()
        ensureIngest(for: result.workspace, assets: [result.importedAsset])
        return result
    }

    func mergeRecording(
        project sourceProjectID: ProjectID,
        into destinationProjectID: ProjectID
    ) async throws -> ProjectRecordingMergeResult {
        let result = try await repository.mergeProject(sourceProjectID, into: destinationProjectID)
        projects = try await repository.list()
        ensureIngest(for: result.workspace, assets: result.importedAssets)
        return result
    }

    /// First local 1080p export path. It compiles the portable render plan,
    /// then maps its ordered clips onto an AVFoundation composition without
    /// touching any immutable project source.
    func export(
        workspace: ProjectWorkspace,
        profile: ExportProfile,
        to outputURL: URL
    ) async throws {
        let plan = try TimelineCompiler().compile(
            timeline: workspace.timeline,
            assets: workspace.project.assets,
            canvas: profile.canvas
        )
        try ExportPreflight().validate(plan: plan, profile: profile)
        guard plan.captions.isEmpty,
              plan.layers.allSatisfy({ $0.gainDB == 0 })
        else {
            throw MacTimelineExportError.unsupportedAdjustment
        }

        let fileManager = FileManager.default
        let partialURL = outputURL.deletingLastPathComponent().appendingPathComponent(
            ".\(UUID().uuidString).creatorstudio-export.mov"
        )
        defer { try? fileManager.removeItem(at: partialURL) }
        let item = try await makeComposition(plan: plan, workspace: workspace, profile: profile)
        guard let exporter = AVAssetExportSession(asset: item.asset, presetName: AVAssetExportPresetHighestQuality) else {
            throw MacTimelineExportError.exporterUnavailable
        }
        exporter.videoComposition = item.videoComposition
        exporter.shouldOptimizeForNetworkUse = true
        try await MacCompositionExport.write(exporter, to: partialURL)
        try Task.checkCancellation()
        if fileManager.fileExists(atPath: outputURL.path) {
            _ = try fileManager.replaceItemAt(outputURL, withItemAt: partialURL)
        } else {
            try fileManager.moveItem(at: partialURL, to: outputURL)
        }
    }

    /// Preview uses the same composition and compositor as export, with one playback clock.
    func layoutPreviewItem(workspace: ProjectWorkspace, sessionID: UUID?) async throws -> AVPlayerItem {
        var preview = workspace
        if let sessionID {
            let ids = Set(workspace.project.assets.filter { $0.captureSessionID == sessionID }.map(\.id))
            for index in preview.timeline.tracks.indices {
                preview.timeline.tracks[index].clips.removeAll { !ids.contains($0.assetID) }
            }
            let clips = preview.timeline.tracks.flatMap(\.clips).filter(\.isEnabled)
            let origin = clips.map(\.timelineStart).min() ?? .zero
            let end = clips.map(\.timelineRange.end).max() ?? origin
            for index in preview.timeline.tracks.indices {
                for clipIndex in preview.timeline.tracks[index].clips.indices {
                    preview.timeline.tracks[index].clips[clipIndex].timelineStart =
                        preview.timeline.tracks[index].clips[clipIndex].timelineStart - origin
                }
            }
            preview.timeline.focusEvents = preview.timeline.focusEvents.compactMap { event in
                let start = max(event.timeRange.start, origin)
                let stop = min(event.timeRange.end, end)
                guard start < stop else { return nil }
                var updated = event
                updated.timeRange = StudioTimeRange(start: start - origin, duration: stop - start)
                return updated
            }
            preview.timeline.captions = []
        }
        var profile = ExportProfile.landscapeTutorial
        profile.canvas = workspace.project.defaultCanvas
        let plan = try TimelineCompiler().compile(
            timeline: preview.timeline, assets: preview.project.assets, canvas: profile.canvas
        )
        return try await makeComposition(plan: plan, workspace: preview, profile: profile)
    }

    private func makeComposition(
        plan: RenderPlan,
        workspace: ProjectWorkspace,
        profile: ExportProfile
    ) async throws -> AVPlayerItem {
        let composition = AVMutableComposition()
        var layers: [MacCompositionLayer] = []
        let usedAssetIDs = Set(plan.layers.map(\.asset.id))
        let assetURLs = try await withThrowingTaskGroup(of: (AssetID, URL).self) { group in
            for asset in workspace.project.assets where usedAssetIDs.contains(asset.id) {
                group.addTask { [repository] in
                    (asset.id, try await repository.assetURL(projectID: workspace.project.id, assetID: asset.id))
                }
            }
            var result: [AssetID: URL] = [:]
            for try await (assetID, url) in group {
                result[assetID] = url
            }
            return result
        }

        let orderedLayers = plan.layers
            .sorted { lhs, rhs in
                Self.compositionZOrder(lhs.trackKind) > Self.compositionZOrder(rhs.trackKind)
            }

        for layer in orderedLayers {
            guard let sourceURL = assetURLs[layer.asset.id] else {
                throw ProjectStoreError.invalidProject("The export plan references a missing source asset.")
            }
            let sourceAsset = AVURLAsset(url: sourceURL)
            let sourceRange = CMTimeRange(
                start: Self.cmTime(layer.sourceRange.start),
                duration: Self.cmTime(layer.sourceRange.duration)
            )
            let timelineRange = CMTimeRange(
                start: Self.cmTime(layer.timelineRange.start),
                duration: Self.cmTime(layer.timelineRange.duration)
            )

            if let videoTrack = try await sourceAsset.loadTracks(withMediaType: .video).first {
                guard let destinationTrack = composition.addMutableTrack(
                    withMediaType: .video,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else {
                    throw MacTimelineExportError.compositionTrack
                }
                try destinationTrack.insertTimeRange(sourceRange, of: videoTrack, at: timelineRange.start)
                if sourceRange.duration != timelineRange.duration {
                    destinationTrack.scaleTimeRange(
                        CMTimeRange(start: timelineRange.start, duration: sourceRange.duration),
                        toDuration: timelineRange.duration
                    )
                }

                let instruction = AVMutableVideoCompositionLayerInstruction(assetTrack: destinationTrack)
                let baseTransform = try await Self.exportTransform(
                    for: videoTrack,
                    canvas: profile.canvas,
                    frame: layer.transform.frame
                )
                instruction.setTransform(baseTransform, at: timelineRange.start)
                try await Self.applyFocusZooms(
                    plan.focus,
                    to: instruction,
                    baseline: baseTransform,
                    for: layer,
                    track: videoTrack,
                    canvas: profile.canvas
                )
                instruction.setOpacity(Float(layer.transform.opacity), at: timelineRange.start)
                if timelineRange.end < composition.duration {
                    instruction.setOpacity(0, at: timelineRange.end)
                }
                layers.append(MacCompositionLayer(
                    trackID: destinationTrack.trackID,
                    timeRange: timelineRange,
                    frame: layer.transform.frame,
                    cornerRadius: layer.transform.cornerRadius,
                    opacity: layer.transform.opacity,
                    transformInstruction: instruction
                ))
            }

            if let audioTrack = try await sourceAsset.loadTracks(withMediaType: .audio).first {
                guard let destinationTrack = composition.addMutableTrack(
                    withMediaType: .audio,
                    preferredTrackID: kCMPersistentTrackID_Invalid
                ) else {
                    throw MacTimelineExportError.compositionTrack
                }
                try destinationTrack.insertTimeRange(sourceRange, of: audioTrack, at: timelineRange.start)
                if sourceRange.duration != timelineRange.duration {
                    destinationTrack.scaleTimeRange(
                        CMTimeRange(start: timelineRange.start, duration: sourceRange.duration),
                        toDuration: timelineRange.duration
                    )
                }
            }
        }

        guard !layers.isEmpty else { throw MacTimelineExportError.noVideo }
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = CGSize(width: profile.canvas.width, height: profile.canvas.height)
        videoComposition.frameDuration = CMTime(value: 1, timescale: CMTimeScale(profile.framesPerSecond))
        videoComposition.customVideoCompositorClass = MacTimelineCompositor.self
        videoComposition.instructions = [MacCompositionInstruction(
            timeRange: CMTimeRange(start: .zero, duration: composition.duration),
            layers: layers
        )]
        let item = AVPlayerItem(asset: composition)
        item.videoComposition = videoComposition
        return item
    }

    func assetURL(projectID: ProjectID, assetID: AssetID) async throws -> URL {
        try await repository.assetURL(projectID: projectID, assetID: assetID)
    }

    func applyTimelineCommand(
        _ command: TimelineCommand,
        to projectID: ProjectID
    ) async throws -> ProjectWorkspace {
        let workspace = try await repository.applyTimelineCommand(command, to: projectID)
        projects = try await repository.list()
        return workspace
    }

    func undoTimelineEdit(projectID: ProjectID) async throws -> ProjectWorkspace {
        let workspace = try await repository.undoTimelineEdit(projectID: projectID)
        projects = try await repository.list()
        return workspace
    }

    func redoTimelineEdit(projectID: ProjectID) async throws -> ProjectWorkspace {
        let workspace = try await repository.redoTimelineEdit(projectID: projectID)
        projects = try await repository.list()
        return workspace
    }

    func previewURL(projectID: ProjectID, assetID: AssetID) async throws -> URL {
        if let proxyURL = ingestStatus[assetID]?.result?.proxyURL {
            return proxyURL
        }
        return try await repository.assetURL(projectID: projectID, assetID: assetID)
    }

    func ensureIngest(for workspace: ProjectWorkspace, assets: [SourceAsset]? = nil) {
        let candidates = assets ?? workspace.project.assets
        for asset in candidates where Self.supportsIngest(asset.kind) {
            guard ingestStatus[asset.id]?.isRunning != true,
                  ingestStatus[asset.id]?.phase != .complete
            else { continue }
            ingestStatus[asset.id] = MacAssetIngestStatus(
                phase: .queued,
                fractionCompleted: 0,
                message: "Queued for local ingest",
                result: nil
            )
            pendingIngest.append(PendingIngest(projectID: workspace.project.id, asset: asset))
        }
        startNextIngestIfNeeded()
    }

    func cancelIngest(assetID: AssetID) {
        if let task = ingestTasks[assetID] {
            task.cancel()
            return
        }
        let wasQueued = pendingIngest.contains(where: { $0.asset.id == assetID })
        pendingIngest.removeAll(where: { $0.asset.id == assetID })
        if wasQueued {
            ingestStatus[assetID] = MacAssetIngestStatus(
                phase: .canceled,
                fractionCompleted: 0,
                message: "Ingest canceled before cache generation began",
                result: nil
            )
        }
    }

    func clearRebuildableCache(for workspace: ProjectWorkspace) async throws {
        let assetIDs = Set(workspace.project.assets.map(\.id))
        guard !assetIDs.contains(where: { ingestStatus[$0]?.isRunning == true }) else {
            throw ProjectStoreError.writeFailed(
                "Wait for local ingest to finish before clearing this project's cache."
            )
        }

        pendingIngest.removeAll { assetIDs.contains($0.asset.id) }
        try await repository.clearRebuildableCache(projectID: workspace.project.id)
        for assetID in assetIDs where Self.supportsIngest(
            workspace.project.assets.first(where: { $0.id == assetID })?.kind
        ) {
            ingestStatus[assetID] = MacAssetIngestStatus(
                phase: .canceled,
                fractionCompleted: 0,
                message: "Cache cleared; rebuild when needed",
                result: nil
            )
        }
    }

    func refreshCameras() {
        availableCameras = MacCameraDiscovery.devices()
        if selectedCameraID == nil || !availableCameras.contains(where: { $0.id == selectedCameraID }) {
            selectedCameraID = MacCameraDiscovery.defaultDevice()?.id
        }
    }

    func beginCapture() async {
        guard !captureIsBusy, !isRecording else { return }
        updatePreflight()
        refreshCameras()

        if includeMicrophone {
            let authorized = await authorizeMicrophone()
            guard authorized else {
                updatePreflight()
                captureState = .failed
                captureMessage = "Microphone access is denied. Turn off microphone capture or allow it in System Settings."
                return
            }
        }
        if includeCamera {
            let authorized = await authorizeCamera()
            if !authorized {
                // Soft-fail: still allow screen recording without camera.
                updatePreflight()
                captureNotice =
                    "Camera permission is not granted for this app build. Screen recording will continue without facecam. Toggle Camera off, or enable Camera for Creator Studio in Privacy settings (rebuilds may need a fresh grant)."
                // Continue without camera rather than aborting the whole capture.
            } else if selectedCameraID == nil, MacCameraDiscovery.defaultDevice() == nil {
                captureNotice = "No camera is available. Recording screen only."
            }
        }

        let availableStorage = availableStorageBytes()
        guard availableStorage >= 1_000_000_000 else {
            captureState = .storageConstrained
            captureMessage = "Free space is below the protected 1 GB recording reserve."
            return
        }

        captureCoordinator.presentPicker(options: captureOptions())
    }

    /// Camera-only recording for podcast / talking-head intents (no screen source).
    func beginCameraOnlyCapture() async {
        guard !captureIsBusy, !isRecording else { return }
        updatePreflight()
        refreshCameras()

        let authorized = await authorizeCamera()
        guard authorized else {
            updatePreflight()
            captureState = .failed
            captureMessage = "Camera access is denied. Allow camera access in System Settings to record."
            return
        }
        guard selectedCameraID != nil || MacCameraDiscovery.defaultDevice() != nil else {
            captureState = .failed
            captureMessage = "No camera is available. Connect a webcam or enable Continuity Camera from an iPhone."
            return
        }

        let availableStorage = availableStorageBytes()
        guard availableStorage >= 1_000_000_000 else {
            captureState = .storageConstrained
            captureMessage = "Free space is below the protected 1 GB recording reserve."
            return
        }

        var options = captureOptions()
        options.includeCamera = true
        options.includeSystemAudio = false
        await captureCoordinator.startCameraOnlyCapture(options: options)
    }

    func stopCapture() async {
        guard isRecording else { return }
        captureState = .stopping
        captureMessage = "Stopping capture and committing every open media segment…"
        await captureCoordinator.stop()
    }

    private func captureOptions() -> MacCaptureOptions {
        let cameraOK = includeCamera
            && AVCaptureDevice.authorizationStatus(for: .video) == .authorized
            && (selectedCameraID != nil || MacCameraDiscovery.defaultDevice() != nil)
        return MacCaptureOptions(
            includeSystemAudio: includeSystemAudio,
            includeMicrophone: includeMicrophone,
            includeCamera: cameraOK,
            cameraDeviceID: selectedCameraID,
            showCursor: showCursor,
            highlightMouseClicks: highlightMouseClicks,
            trackPointerMotion: trackMouseMovements || automaticFocusZoom
        )
    }

    func markFocusAtCurrentCursor() {
        guard isRecording else {
            errorMessage = "Start a screen recording before marking a focus point."
            return
        }
        guard captureCoordinator.markFocusAtCurrentCursor() else {
            captureNotice = MacPointerTracker.isAccessibilityTrusted
                ? "Pointer tracking is unavailable for this recording."
                : "Pointer tracking needs Accessibility permission in System Settings before focus markers can be recorded."
            return
        }
        captureMessage = "Focus marker added at the current cursor position. Creator Studio will zoom there in the saved recording."
    }

    func importCapture(_ item: CaptureInboxItem) async {
        await saveCapture(item, discardingStagingCopy: true)
    }

    func discardCapture(_ item: CaptureInboxItem) async {
        guard item.status != .recording, item.status != .stopping else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await captureImporter.discardSession(id: item.sessionID)
            captureInbox = await captureImporter.discover()
            captureState = .ready
            captureMessage = "Deleted the unimported recording and its recovery files."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func saveCapture(
        _ item: CaptureInboxItem,
        discardingStagingCopy: Bool
    ) async {
        guard item.canImport else { return }
        captureState = .importing
        captureMessage = "Validating hashes and saving a new local recording…"
        isWorking = true
        defer { isWorking = false }

        var createdUnlistedProjectID: ProjectID?
        do {
            let title = Self.recordingTitle(for: item)
            let destination = try await unlistedRecordingsProject()
            if destination.wasCreated {
                createdUnlistedProjectID = destination.project.id
            }
            let pointerEvents = automaticFocusZoom
                ? MacPointerTracker.loadEvents(from: captureSessionDirectory(id: item.sessionID))
                : []
            let result = try await captureImporter.importSession(
                id: item.sessionID,
                into: destination.project.id,
                recordingName: title,
                layout: captureLayout,
                cameraFrameOverride: cameraBubbleFrameOverride
            )
            projects = try await repository.list()
            selectedProjectID = destination.project.id
            var workspace = try await repository.loadWorkspace(id: destination.project.id)
            let focusEvents = Self.focusEvents(
                from: pointerEvents,
                importedAssets: result.importedAssets,
                in: workspace
            )
            if !focusEvents.isEmpty {
                do {
                    workspace = try await repository.applyTimelineCommand(
                        .addFocusEvents(focusEvents),
                        to: destination.project.id
                    )
                    projects = try await repository.list()
                } catch {
                    // The source recording is already safely imported. Keep it
                    // usable if optional focus metadata is malformed.
                    errorMessage = "The recording was saved, but its optional focus markers could not be added: \(error.localizedDescription)"
                }
            }
            ensureIngest(for: workspace, assets: result.importedAssets)
            captureState = .finalized
            if discardingStagingCopy {
                try? await captureImporter.discardSession(id: item.sessionID)
            }
            captureInbox = await captureImporter.discover()
            captureMessage = result.wasRecovered
                ? "Saved \(title) from recovered local media in Unlisted Recordings."
                : "Saved \(title) in Unlisted Recordings."

            // Prefer the first screen clip of this session for preview; fall back to camera.
            let preferred = result.importedAssets.first(where: { $0.kind == .screenVideo })
                ?? result.importedAssets.first(where: { $0.kind == .cameraVideo })
                ?? result.importedAssets.first
            pendingRecordingReveal = MacRecordingReveal(
                projectID: destination.project.id,
                captureSessionID: item.sessionID,
                preferredAssetID: preferred?.id
            )
            projectContentEpoch &+= 1
        } catch {
            if let createdUnlistedProjectID {
                try? await repository.delete(id: createdUnlistedProjectID)
            }
            captureState = .failed
            captureMessage = "Import failed validation. The recording remains untouched in the recovery inbox."
            errorMessage = error.localizedDescription
        }
    }

    func updatePreflight() {
        var requestedSources: Set<CaptureSource> = [.screen]
        if includeSystemAudio { requestedSources.insert(.appAudio) }
        if includeMicrophone { requestedSources.insert(.microphone) }
        if includeCamera { requestedSources.insert(.camera) }
        let microphoneDenied = AVCaptureDevice.authorizationStatus(for: .audio) == .denied
        let cameraDenied = AVCaptureDevice.authorizationStatus(for: .video) == .denied
        var capabilities = PlatformCapturePolicy().baselineCapabilities()
        // Desktop always can request camera as a separate source when a device exists.
        if !availableCameras.isEmpty || MacCameraDiscovery.defaultDevice() != nil {
            capabilities.supportedSources.insert(.camera)
        }
        if cameraDenied {
            capabilities.caveats.append("Camera permission is denied in System Settings.")
        }
        preflight = CapturePreflightEvaluator().evaluate(CapturePreflightInput(
            capabilities: capabilities,
            requestedSources: requestedSources,
            // The desktop recorder and importer share an app-owned directory;
            // no cross-process App Group handoff is needed on macOS.
            appGroupAvailable: true,
            availableStorageBytes: availableStorageBytes(),
            thermalState: thermalState(),
            microphonePermissionDenied: microphoneDenied
        ))
    }

    private func authorizeMicrophone() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            true
        case .notDetermined:
            await AVCaptureDevice.requestAccess(for: .audio)
        default:
            false
        }
    }

    private func authorizeCamera() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            true
        case .notDetermined:
            // Only this path shows the system camera prompt (once).
            await AVCaptureDevice.requestAccess(for: .video)
        case .denied, .restricted:
            // Already decided — do not call requestAccess again (it only bounces
            // the user into Settings without granting for a new unsigned binary).
            false
        @unknown default:
            false
        }
    }

    func openCameraPrivacySettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Camera",
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) { return }
        }
    }

    private func handleCaptureEvent(_ event: MacCaptureEvent) {
        switch event {
        case .selecting:
            liveCaptureSources = []
            isCameraLive = false
            hideFloatingCameraBubble()
            captureState = .preparing
            captureMessage = "Choose one window, application, or display in the system picker."
        case .starting:
            captureState = .preparing
            captureMessage = "Starting the local ScreenCaptureKit stream…"
        case .cameraStarted:
            isCameraLive = true
            showFloatingCameraBubbleIfNeeded()
            captureMessage = "Camera is live — facecam bubble is on your desktop."
        case .recording:
            captureState = .recording
            if captureCoordinator.liveCameraSession != nil {
                isCameraLive = true
            }
            showFloatingCameraBubbleIfNeeded()
            captureMessage = liveCaptureSources.contains(.screen)
                ? (isCameraLive
                    ? "Screen and camera are recording. Drag the facecam bubble on your desktop."
                    : "Video frames are arriving and being recorded locally.")
                : (isCameraLive
                    ? "Camera is recording. Drag the facecam bubble on your desktop."
                    : "Recording locally; waiting for the first video frame…")
        case let .sourceObserved(source):
            liveCaptureSources.insert(source)
            if source == .camera {
                isCameraLive = true
                showFloatingCameraBubbleIfNeeded()
            }
            let audioSources = liveCaptureSources.intersection([.appAudio, .microphone]).count
            let hasScreen = liveCaptureSources.contains(.screen)
            let hasCamera = liveCaptureSources.contains(.camera)
            if hasScreen, hasCamera {
                captureMessage = audioSources > 0
                    ? "Screen, camera, and audio are recording locally."
                    : "Screen and camera frames are recording locally."
            } else if hasScreen {
                captureMessage = audioSources > 0
                    ? "Video and audio frames are arriving and being recorded locally."
                    : "Video frames are arriving and being recorded locally."
            } else if hasCamera {
                captureMessage = "Camera frames are arriving and being recorded locally."
            }
        case let .stopped(sessionID):
            isCameraLive = false
            hideFloatingCameraBubble()
            captureState = .importing
            captureMessage = "Recording stopped safely. Saving it in Unlisted Recordings…"
            Task { await automaticallySaveCompletedCapture(sessionID: sessionID) }
        case let .interrupted(message):
            isCameraLive = false
            hideFloatingCameraBubble()
            captureState = .recovered
            captureMessage = message
            Task { await refresh() }
        case .canceled:
            isCameraLive = false
            hideFloatingCameraBubble()
            captureState = .ready
            captureMessage = "Capture selection was canceled; nothing was recorded."
        case let .failed(message):
            isCameraLive = false
            hideFloatingCameraBubble()
            captureState = .failed
            captureMessage = message
            Task { await refresh() }
        case let .notice(message):
            captureNotice = message
        }
    }

    private func showFloatingCameraBubbleIfNeeded() {
        guard let session = captureCoordinator.liveCameraSession else { return }
        floatingCameraBubble.show(
            session: session,
            isCircle: liveCameraIsCircle,
            diameter: 176
        )
        // Force SwiftUI observers (sidebar bubble) to re-read liveCameraSession.
        objectWillChange.send()
    }

    private func hideFloatingCameraBubble() {
        floatingCameraBubble.hide()
    }

    private func automaticallySaveCompletedCapture(sessionID: UUID) async {
        guard let item = await captureImporter.discoverSession(id: sessionID) else {
            captureState = .failed
            captureMessage = "The finished recording could not be found in local storage."
            return
        }
        captureInbox = await captureImporter.discover()
        guard item.status == .completed else {
            captureState = .recovered
            captureMessage = "The recording did not finalize normally. Its committed media is available in recovery."
            return
        }
        await saveCapture(item, discardingStagingCopy: true)
    }

    private static func recordingTitle(for item: CaptureInboxItem) -> String {
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute, .second],
            from: item.startedAt
        )
        let prefix = item.status == .recovered ? "Recovered Screen Recording" : "Screen Recording"
        return String(
            format: "%@ %04d-%02d-%02d %02d.%02d.%02d",
            prefix,
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0,
            components.hour ?? 0,
            components.minute ?? 0,
            components.second ?? 0
        )
    }

    private func unlistedRecordingsProject() async throws -> (project: StudioProject, wasCreated: Bool) {
        if let summary = try await repository.list().first(where: {
            $0.title == Self.unlistedRecordingsTitle && $0.intent == .importOnly
        }) {
            return (try await repository.load(id: summary.id), false)
        }
        return (
            try await repository.create(title: Self.unlistedRecordingsTitle, intent: .importOnly),
            true
        )
    }

    private func captureSessionDirectory(id: UUID) -> URL {
        captureInboxRoot.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
    }

    private static func focusEvents(
        from pointerEvents: [MacPointerEvent],
        importedAssets: [SourceAsset],
        in workspace: ProjectWorkspace
    ) -> [FocusEvent] {
        guard let sessionStart = workspace.timeline.tracks
            .flatMap(\.clips)
            .filter({ clip in importedAssets.contains(where: { $0.id == clip.assetID }) })
            .map(\.timelineStart)
            .min()
        else { return [] }

        let candidates = pointerEvents
            .filter { $0.kind == .click || $0.kind == .focus }
            .sorted { $0.time < $1.time }

        var lastFocusTime = -Double.infinity
        var focusEvents: [FocusEvent] = []
        for candidate in candidates {
            // Click clusters are usually one interaction. Keep the focus motion
            // calm by requiring a small dwell between automatic zooms; explicit
            // focus shortcut markers can always be added.
            if candidate.kind == .click, candidate.time - lastFocusTime < 1.7 {
                continue
            }
            let size = candidate.kind == .focus ? 0.38 : 0.46
            let region = NormalizedRect(
                x: candidate.x - size / 2,
                y: candidate.y - size / 2,
                width: size,
                height: size
            ).clampedToFrame()
            focusEvents.append(FocusEvent(
                timeRange: StudioTimeRange(
                    start: sessionStart + StudioTime(seconds: max(0, candidate.time - 0.12)),
                    duration: StudioTime(seconds: candidate.kind == .focus ? 2.0 : 1.6)
                ),
                region: region,
                strength: candidate.kind == .focus ? 1 : 0.78,
                source: candidate.kind == .focus ? .manual : .interactionEvent,
                confidence: candidate.kind == .focus ? 1 : 0.9
            ))
            lastFocusTime = candidate.time
        }
        return focusEvents
    }

    private func startIngest(projectID: ProjectID, asset: SourceAsset) {
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                self.ingestStatus[asset.id] = MacAssetIngestStatus(
                    phase: .inspecting,
                    fractionCompleted: 0,
                    message: "Inspecting orientation and source timing",
                    result: nil
                )
                try Task.checkCancellation()
                let location = try await self.repository.assetIngestLocation(
                    projectID: projectID,
                    assetID: asset.id
                )
                try Task.checkCancellation()
                let inspection = try await AVAssetMediaInspector().inspect(location.sourceURL)
                try Task.checkCancellation()
                _ = try await self.repository.updateMediaMetadata(
                    inspection.metadata,
                    displayPixelSize: inspection.displayPixelSize,
                    projectID: projectID,
                    assetID: asset.id
                )
                try Task.checkCancellation()
                let fingerprint = asset.contentHash ?? "asset:\(asset.id.description)"
                let progressGate = IngestProgressGate()
                let result = try await MediaCacheGenerator().generate(
                    sourceURL: location.sourceURL,
                    cacheDirectoryURL: location.cacheDirectoryURL,
                    assetID: asset.id,
                    sourceContentHash: fingerprint,
                    inspection: inspection
                ) { [weak self] progress in
                    guard progressGate.shouldPublish(progress) else { return }
                    Task { @MainActor [weak self] in
                        guard let self,
                              self.ingestStatus[asset.id]?.isRunning == true
                        else { return }
                        self.ingestStatus[asset.id] = MacAssetIngestStatus(
                            phase: .generating(progress.stage),
                            fractionCompleted: progress.fractionCompleted,
                            message: Self.ingestMessage(for: progress.stage),
                            result: nil
                        )
                    }
                }
                try Task.checkCancellation()
                self.ingestStatus[asset.id] = MacAssetIngestStatus(
                    phase: .complete,
                    fractionCompleted: 1,
                    message: Self.completionMessage(for: result),
                    result: result
                )
            } catch is CancellationError {
                self.ingestStatus[asset.id] = MacAssetIngestStatus(
                    phase: .canceled,
                    fractionCompleted: 0,
                    message: "Ingest canceled; existing cache products remain rebuildable",
                    result: nil
                )
            } catch {
                self.ingestStatus[asset.id] = MacAssetIngestStatus(
                    phase: .failed,
                    fractionCompleted: 0,
                    message: error.localizedDescription,
                    result: nil
                )
            }
            self.ingestTasks[asset.id] = nil
            self.activeIngestAssetID = nil
            self.startNextIngestIfNeeded()
        }
        ingestTasks[asset.id] = task
    }

    /// One encoder/reader job at a time avoids saturating the desktop with a
    /// burst of AVAsset exports when a segmented recording first opens.
    private func startNextIngestIfNeeded() {
        guard activeIngestAssetID == nil, !pendingIngest.isEmpty else { return }
        let pending = pendingIngest.removeFirst()
        activeIngestAssetID = pending.asset.id
        startIngest(projectID: pending.projectID, asset: pending.asset)
    }

    private static func supportsIngest(_ kind: MediaKind?) -> Bool {
        switch kind {
        case .screenVideo?, .cameraVideo?, .appAudio?, .microphoneAudio?, .music?:
            true
        case .image?, .overlay?, nil:
            false
        }
    }

    private static func ingestMessage(for stage: MediaCacheStage) -> String {
        switch stage {
        case .preparing: "Preparing rebuildable caches"
        case .proxy: "Generating editing proxy"
        case .waveform: "Generating waveform"
        case .finalizing: "Finalizing cache manifest"
        case .complete: "Ingest complete"
        }
    }

    private static func completionMessage(for result: MediaCacheGenerationResult) -> String {
        switch (result.proxyURL != nil, result.waveformURL != nil) {
        case (true, true): "Proxy and waveform ready"
        case (true, false): "Editing proxy ready"
        case (false, true): "Waveform ready"
        case (false, false): "Source metadata ready"
        }
    }

    private func availableStorageBytes() -> Int64 {
        guard let values = try? storageRoot.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        ) else { return 0 }
        if let important = values.volumeAvailableCapacityForImportantUsage { return important }
        return Int64(values.volumeAvailableCapacity ?? 0)
    }

    private static func cmTime(_ time: StudioTime) -> CMTime {
        CMTime(value: time.microseconds, timescale: 1_000_000)
    }

    /// Maps a source track into a normalized canvas frame (aspect-fill).
    private static func exportTransform(
        for track: AVAssetTrack,
        canvas: CanvasSpec,
        frame: NormalizedRect = .fullFrame
    ) async throws -> CGAffineTransform {
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let orientedRect = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
        guard orientedRect.width > 0, orientedRect.height > 0 else {
            throw MacTimelineExportError.invalidVideoDimensions
        }

        // Editor NormalizedRect is top-left origin; AVVideoComposition is bottom-left.
        let flippedY = 1 - frame.origin.y - frame.size.height
        let target = CGRect(
            x: frame.origin.x * CGFloat(canvas.width),
            y: flippedY * CGFloat(canvas.height),
            width: max(1, frame.size.width * CGFloat(canvas.width)),
            height: max(1, frame.size.height * CGFloat(canvas.height))
        )
        // Aspect-fill the source into the target rect (podcast bubble / split pane).
        let scale = max(
            target.width / orientedRect.width,
            target.height / orientedRect.height
        )
        let drawnWidth = orientedRect.width * scale
        let drawnHeight = orientedRect.height * scale
        let originX = target.midX - drawnWidth / 2
        let originY = target.midY - drawnHeight / 2
        return preferredTransform
            .concatenating(CGAffineTransform(translationX: -orientedRect.minX, y: -orientedRect.minY))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: originX, y: originY))
    }

    private static func compositionZOrder(_ kind: TrackKind) -> Int {
        switch kind {
        case .screen: 0
        case .camera: 10
        case .overlay, .annotation: 20
        default: 5
        }
    }

    /// Applies short, comfortable transform ramps around pointer-derived focus
    /// events. These are non-destructive timeline instructions: the source
    /// movie stays untouched and a user can undo the focus command later.
    private static func applyFocusZooms(
        _ focusEvents: [FocusInstruction],
        to instruction: AVMutableVideoCompositionLayerInstruction,
        baseline: CGAffineTransform,
        for layer: RenderLayer,
        track: AVAssetTrack,
        canvas: CanvasSpec
    ) async throws {
        guard layer.trackKind == .screen else { return }

        let layerStart = layer.timelineRange.start
        let layerEnd = layer.timelineRange.end
        var nextAvailableStart = layerStart

        for event in focusEvents {
            let eventStart = max(event.timeRange.start, layerStart)
            let eventEnd = min(event.timeRange.end, layerEnd)
            let start = max(eventStart, nextAvailableStart)
            guard start < eventEnd else { continue }

            let focusedTransform = try await focusTransform(
                for: track,
                baseline: baseline,
                canvas: canvas,
                region: event.region,
                strength: event.strength
            )
            let duration = eventEnd - start
            let rampDuration = StudioTime(seconds: min(0.18, duration.seconds / 3))
            let rampInEnd = start + rampDuration
            let rampOutStart = max(rampInEnd, eventEnd - rampDuration)

            if rampDuration > .zero {
                instruction.setTransformRamp(
                    fromStart: baseline,
                    toEnd: focusedTransform,
                    timeRange: CMTimeRange(
                        start: cmTime(start),
                        duration: cmTime(rampDuration)
                    )
                )
            } else {
                instruction.setTransform(focusedTransform, at: cmTime(start))
            }
            instruction.setTransform(focusedTransform, at: cmTime(rampInEnd))
            if eventEnd > rampOutStart {
                instruction.setTransformRamp(
                    fromStart: focusedTransform,
                    toEnd: baseline,
                    timeRange: CMTimeRange(
                        start: cmTime(rampOutStart),
                        duration: cmTime(eventEnd - rampOutStart)
                    )
                )
            }
            instruction.setTransform(baseline, at: cmTime(eventEnd))
            nextAvailableStart = eventEnd
        }
    }

    private static func focusTransform(
        for track: AVAssetTrack,
        baseline: CGAffineTransform,
        canvas: CanvasSpec,
        region: NormalizedRect,
        strength: Double
    ) async throws -> CGAffineTransform {
        let naturalSize = try await track.load(.naturalSize)
        let preferredTransform = try await track.load(.preferredTransform)
        let orientedRect = CGRect(origin: .zero, size: naturalSize)
            .applying(preferredTransform)
            .standardized
        guard orientedRect.width > 0, orientedRect.height > 0 else {
            throw MacTimelineExportError.invalidVideoDimensions
        }

        let scale = min(
            CGFloat(canvas.width) / orientedRect.width,
            CGFloat(canvas.height) / orientedRect.height
        )
        let centeredX = (CGFloat(canvas.width) - orientedRect.width * scale) / 2
        let centeredY = (CGFloat(canvas.height) - orientedRect.height * scale) / 2
        let clamped = region.clampedToFrame()
        let centerX = CGFloat(clamped.origin.x + clamped.size.width / 2)
        let centerY = CGFloat(clamped.origin.y + clamped.size.height / 2)
        let focusX = centeredX + centerX * orientedRect.width * scale
        let focusY = centeredY + (1 - centerY) * orientedRect.height * scale
        let zoom = CGFloat(1 + min(max(strength, 0), 1) * 0.75)

        // Scaling each affine component and compensating its translation is the
        // same as post-scaling the baseline composition around the focus point.
        // It keeps the selected pointer location stable while the frame grows.
        return CGAffineTransform(
            a: baseline.a * zoom,
            b: baseline.b * zoom,
            c: baseline.c * zoom,
            d: baseline.d * zoom,
            tx: (baseline.tx - focusX) * zoom + focusX,
            ty: (baseline.ty - focusY) * zoom + focusY
        )
    }

    private func thermalState() -> CaptureThermalState {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: .nominal
        case .fair: .fair
        case .serious: .serious
        case .critical: .critical
        @unknown default: .serious
        }
    }
}
