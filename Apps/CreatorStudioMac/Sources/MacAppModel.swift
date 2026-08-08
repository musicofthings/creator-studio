import AVFoundation
import Foundation
import StudioCapture
import StudioDomain
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

@MainActor
final class MacAppModel: ObservableObject {
    @Published private(set) var projects: [ProjectSummary] = []
    @Published var selectedProjectID: ProjectID?
    @Published var errorMessage: String?
    @Published var isPresentingNewProject = false
    @Published private(set) var isWorking = false

    @Published var includeSystemAudio = true
    @Published var includeMicrophone = true
    @Published private(set) var captureState: CaptureState = .ready
    @Published private(set) var captureMessage = "Choose a window, application, or display when you are ready to record."
    @Published private(set) var captureInbox: [CaptureInboxItem] = []
    @Published private(set) var preflight: CapturePreflightReport?
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
    private struct PendingIngest {
        var projectID: ProjectID
        var asset: SourceAsset
    }

    private var ingestTasks: [AssetID: Task<Void, Never>] = [:]
    private var pendingIngest: [PendingIngest] = []
    private var activeIngestAssetID: AssetID?

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
    }

    var isRecording: Bool { captureState == .recording }

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

    func refresh() async {
        do {
            projects = try await repository.list()
            captureInbox = await captureImporter.discover()
            updatePreflight()
            if selectedProjectID == nil {
                selectedProjectID = projects.first?.id
            }
            if captureState == .ready,
               let recoverable = importableCaptures.first(where: { $0.status == .recovered }) {
                captureState = .recovered
                captureMessage = "An interrupted recording has \(recoverable.segmentCount) committed segment(s) ready to recover."
            }
        } catch {
            errorMessage = error.localizedDescription
        }
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

    func assetURL(projectID: ProjectID, assetID: AssetID) async throws -> URL {
        try await repository.assetURL(projectID: projectID, assetID: assetID)
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

    func beginCapture() async {
        guard !captureIsBusy, !isRecording else { return }
        updatePreflight()

        if includeMicrophone {
            let authorized = await authorizeMicrophone()
            guard authorized else {
                updatePreflight()
                captureState = .failed
                captureMessage = "Microphone access is denied. Turn off microphone capture or allow it in System Settings."
                return
            }
        }

        let availableStorage = availableStorageBytes()
        guard availableStorage >= 1_000_000_000 else {
            captureState = .storageConstrained
            captureMessage = "Free space is below the protected 1 GB recording reserve."
            return
        }

        captureCoordinator.presentPicker(options: MacCaptureOptions(
            includeSystemAudio: includeSystemAudio,
            includeMicrophone: includeMicrophone
        ))
    }

    func stopCapture() async {
        guard isRecording else { return }
        captureState = .stopping
        captureMessage = "Stopping capture and committing every open media segment…"
        await captureCoordinator.stop()
    }

    func importCapture(_ item: CaptureInboxItem) async {
        guard item.canImport else { return }
        captureState = .importing
        captureMessage = "Validating hashes and copying immutable recording sources into a desktop project…"
        isWorking = true
        defer { isWorking = false }

        var createdProjectID: ProjectID?
        do {
            let title = item.status == .recovered ? "Recovered Mac Recording" : "Mac Screen Recording"
            let project = try await repository.create(title: title, intent: .tutorial)
            createdProjectID = project.id
            let result = try await captureImporter.importSession(id: item.sessionID, into: project.id)
            projects = try await repository.list()
            captureInbox = await captureImporter.discover()
            selectedProjectID = project.id
            let workspace = try await repository.loadWorkspace(id: project.id)
            ensureIngest(for: workspace, assets: result.importedAssets)
            captureState = .finalized
            captureMessage = result.wasRecovered
                ? "Recovered recording imported as immutable local sources."
                : "Recording imported as immutable local sources."
        } catch {
            if let createdProjectID {
                try? await repository.delete(id: createdProjectID)
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
        let microphoneDenied = AVCaptureDevice.authorizationStatus(for: .audio) == .denied
        preflight = CapturePreflightEvaluator().evaluate(CapturePreflightInput(
            capabilities: PlatformCapturePolicy().baselineCapabilities(),
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

    private func handleCaptureEvent(_ event: MacCaptureEvent) {
        switch event {
        case .selecting:
            captureState = .preparing
            captureMessage = "Choose one window, application, or display in the system picker."
        case .starting:
            captureState = .preparing
            captureMessage = "Starting the local ScreenCaptureKit stream…"
        case .recording:
            captureState = .recording
            captureMessage = "Recording locally. The system recording indicator remains visible."
        case .stopped:
            captureState = .finalized
            captureMessage = "Recording stopped safely. Import it below to create an editable project."
            Task { await refresh() }
        case let .interrupted(message):
            captureState = .recovered
            captureMessage = message
            Task { await refresh() }
        case .canceled:
            captureState = .ready
            captureMessage = "Capture selection was canceled; nothing was recorded."
        case let .failed(message):
            captureState = .failed
            captureMessage = message
            Task { await refresh() }
        }
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
                let location = try await self.repository.assetIngestLocation(
                    projectID: projectID,
                    assetID: asset.id
                )
                let inspection = try await AVAssetMediaInspector().inspect(location.sourceURL)
                _ = try await self.repository.updateMediaMetadata(
                    inspection.metadata,
                    displayPixelSize: inspection.displayPixelSize,
                    projectID: projectID,
                    assetID: asset.id
                )
                let fingerprint = asset.contentHash ?? "asset:\(asset.id.description)"
                let result = try await MediaCacheGenerator().generate(
                    sourceURL: location.sourceURL,
                    cacheDirectoryURL: location.cacheDirectoryURL,
                    assetID: asset.id,
                    sourceContentHash: fingerprint,
                    inspection: inspection
                ) { [weak self] progress in
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

    private static func supportsIngest(_ kind: MediaKind) -> Bool {
        switch kind {
        case .screenVideo, .cameraVideo, .appAudio, .microphoneAudio, .music:
            true
        case .image, .overlay:
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
