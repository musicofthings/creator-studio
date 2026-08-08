import AVFoundation
import Foundation
import StudioCapture
import StudioDomain
import StudioProjectStore

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var projects: [ProjectSummary] = []
    @Published var errorMessage: String?
    @Published var isWorking = false
    @Published private(set) var captureInbox: [CaptureInboxItem] = []
    @Published private(set) var captureLifecycle: CaptureState = .preparing
    @Published private(set) var preflight: CapturePreflightReport?
    @Published private(set) var captureMessage: String?
    @Published var includeMicrophone = true

    private let repository: FileProjectRepository
    private let captureImporter: CaptureInboxImporter?
    private let captureWatcher: CaptureInboxWatcher?
    private let appGroupAvailable: Bool
    private let storageProbeURL: URL

    init() {
        let fileManager = FileManager.default
        let applicationSupport = fileManager.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        let root = applicationSupport
            .appendingPathComponent("CreatorStudio", isDirectory: true)
            .appendingPathComponent("Projects", isDirectory: true)
        repository = FileProjectRepository(rootURL: root)

        if let groupRoot = CaptureInboxLocation.containerURL(fileManager: fileManager) {
            let inbox = groupRoot.appendingPathComponent(
                CaptureInboxLocation.inboxDirectoryName,
                isDirectory: true
            )
            appGroupAvailable = true
            storageProbeURL = groupRoot
            captureImporter = CaptureInboxImporter(inboxRootURL: inbox, repository: repository)
            captureWatcher = CaptureInboxWatcher(url: inbox)
        } else {
            appGroupAvailable = false
            storageProbeURL = applicationSupport
            captureImporter = nil
            captureWatcher = nil
        }
    }

    func refresh() async {
        do {
            projects = try await repository.list()
            await refreshCapture()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Refreshes on inbox change rather than on a timer. The extension rewrites
    /// `manifest.json` atomically, so every commit renames into the watched
    /// directory and wakes this loop; the watcher's own interval covers the rest.
    func watchCaptureInbox() async {
        guard let captureWatcher else {
            await refreshCapture()
            return
        }
        for await _ in captureWatcher.changes() {
            if Task.isCancelled { return }
            await refreshCapture()
        }
    }

    func refreshCapture() async {
        var requestedSources: Set<CaptureSource> = [.screen, .appAudio]
        if includeMicrophone { requestedSources.insert(.microphone) }
        let report = CapturePreflightEvaluator().evaluate(CapturePreflightInput(
            capabilities: PlatformCapturePolicy().baselineCapabilities(),
            requestedSources: requestedSources,
            appGroupAvailable: appGroupAvailable,
            availableStorageBytes: availableStorageBytes(),
            thermalState: thermalState(),
            microphonePermissionDenied: AVAudioApplication.shared.recordPermission == .denied
        ))
        preflight = report

        guard captureLifecycle != .importing else { return }

        if let captureImporter {
            captureInbox = await captureImporter.discover()
        } else {
            captureInbox = []
        }

        if let active = captureInbox.first(where: { $0.status == .recording }) {
            captureLifecycle = .recording
            captureMessage = "Recording is active. iOS keeps its recording indicator visible. \(active.segmentCount) segment(s) are committed."
        } else if captureInbox.contains(where: { $0.status == .stopping }) {
            captureLifecycle = .stopping
            captureMessage = "Recording is stopping and the final media segments are being committed."
        } else if captureInbox.contains(where: { $0.status == .recovered }) {
            captureLifecycle = .recovered
            captureMessage = "A recording was interrupted. Its committed media is ready to recover locally."
        } else if captureInbox.contains(where: { $0.status == .storageConstrained }) {
            captureLifecycle = .storageConstrained
            captureMessage = "Recording stopped before the protected storage reserve was exhausted. Committed media can still be imported."
        } else if captureInbox.contains(where: { $0.status == .failed }) {
            captureLifecycle = .failed
            captureMessage = "A capture session needs attention. No unvalidated media will be imported."
        } else if captureLifecycle == .finalized {
            // Keep the import confirmation on screen instead of overwriting it
            // with "Ready" on the next inbox change.
            return
        } else {
            switch report.status {
            case .ready:
                captureLifecycle = .ready
                captureMessage = "Ready for an explicit, local-only system broadcast."
            case .storageConstrained:
                captureLifecycle = .storageConstrained
                captureMessage = "Free space is below the protected recording reserve."
            case .failed:
                captureLifecycle = .failed
                captureMessage = report.blockers.first?.message
            }
        }
    }

    func importCapture(_ item: CaptureInboxItem) async {
        guard item.canImport, let captureImporter else { return }
        captureLifecycle = .importing
        captureMessage = "Validating and copying immutable media into a new local project."
        isWorking = true
        defer { isWorking = false }

        var createdProjectID: ProjectID?
        do {
            let project = try await repository.create(
                title: item.status == .recovered ? "Recovered Recording" : "Screen Recording",
                intent: .tutorial
            )
            createdProjectID = project.id
            let result = try await captureImporter.importSession(id: item.sessionID, into: project.id)
            projects = try await repository.list()
            captureInbox = await captureImporter.discover()
            // Always `.finalized` — the recovered/normal distinction belongs in
            // the message. Leaving it on `.recovered` makes the next inbox change
            // read it as a pending interrupted session and clear the receipt.
            captureLifecycle = .finalized
            captureMessage = importMessage(for: result)
        } catch {
            // The package was created before validation ran; leaving it behind
            // would put an empty project in the library for every failed import.
            if let createdProjectID {
                try? await repository.delete(id: createdProjectID)
            }
            captureLifecycle = .failed
            captureMessage = "Import failed validation. The inbox recording was left untouched."
            errorMessage = error.localizedDescription
        }
    }

    private func importMessage(for result: CaptureImportResult) -> String {
        let base = result.wasRecovered
            ? "Recovered media was imported as immutable local sources."
            : "Recording imported as immutable local sources."
        guard !result.skipped.isEmpty else { return base }
        return "\(base) \(result.skipped.count) segment(s) failed validation and were left in the inbox."
    }

    func create(intent: ProjectIntent) async {
        isWorking = true
        defer { isWorking = false }
        do {
            _ = try await repository.create(
                title: defaultTitle(for: intent),
                intent: intent
            )
            projects = try await repository.list()
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
        return result
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

    private func defaultTitle(for intent: ProjectIntent) -> String {
        let kind = switch intent {
        case .tutorial: "Tutorial"
        case .social: "Social Clip"
        case .podcast: "Podcast"
        case .camera: "Camera Recording"
        case .audio: "Audio Recording"
        case .importOnly: "Imported Project"
        }
        return "\(kind) \(Date.now.formatted(date: .abbreviated, time: .shortened))"
    }

    private func availableStorageBytes() -> Int64 {
        guard let values = try? storageProbeURL.resourceValues(
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
