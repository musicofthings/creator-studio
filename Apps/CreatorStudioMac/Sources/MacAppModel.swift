import AVFoundation
import Foundation
import StudioCapture
import StudioDomain
import StudioProjectStore
import SwiftUI

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
        return result
    }

    func assetURL(projectID: ProjectID, assetID: AssetID) async throws -> URL {
        try await repository.assetURL(projectID: projectID, assetID: assetID)
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
