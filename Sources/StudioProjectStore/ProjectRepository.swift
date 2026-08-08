import CryptoKit
import Foundation
import StudioDomain

public protocol ProjectRepository: Sendable {
    func create(title: String, intent: ProjectIntent) async throws -> StudioProject
    func load(id: ProjectID) async throws -> StudioProject
    func save(_ project: StudioProject) async throws
    func list() async throws -> [ProjectSummary]
}

public enum ProjectStoreError: Error, Equatable, Sendable {
    case missing(ProjectID)
    case schemaTooNew(found: Int, supported: Int)
    case invalidProject(String)
    case writeFailed(String)
    case readFailed(String)
}

extension ProjectStoreError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .missing:
            "This local project no longer exists."
        case let .schemaTooNew(found, supported):
            "This project uses schema version \(found), but this build supports up to version \(supported)."
        case let .invalidProject(message):
            message
        case let .writeFailed(message):
            "Creator Studio could not save the project: \(message)"
        case let .readFailed(message):
            "Creator Studio could not open the project: \(message)"
        }
    }
}

public actor FileProjectRepository: ProjectRepository {
    public let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL
    }

    private var fileManager: FileManager { .default }

    public func create(title: String, intent: ProjectIntent) async throws -> StudioProject {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProjectStoreError.invalidProject("Project title cannot be empty.")
        }

        let canvas: CanvasSpec = switch intent {
        case .social: .vertical1080
        default: .landscape1080
        }

        let project = StudioProject(title: trimmed, intent: intent, defaultCanvas: canvas)
        do {
            try createPackageDirectories(for: project.id)
            try writeProject(project)

            let timeline = TimelineDocument(id: project.timelineID, projectID: project.id)
            try write(timeline, to: packageURL(for: project.id).appendingPathComponent("timeline.json"))
            try write(
                TimelineEditHistory(timeline: timeline),
                to: packageURL(for: project.id).appendingPathComponent("timeline-history.json")
            )
            return project
        } catch {
            // Project creation is one logical operation. A package containing a
            // manifest but no timeline is not a project the editor can open.
            try? fileManager.removeItem(at: packageURL(for: project.id))
            throw error
        }
    }

    public func load(id: ProjectID) async throws -> StudioProject {
        let url = packageURL(for: id).appendingPathComponent("project.json")
        guard fileManager.fileExists(atPath: url.path) else {
            throw ProjectStoreError.missing(id)
        }

        do {
            let data = try Data(contentsOf: url)
            let project = try Self.decoder().decode(StudioProject.self, from: data)
            guard project.id == id else {
                throw ProjectStoreError.invalidProject("Package ID does not match project manifest.")
            }
            guard project.schemaVersion <= StudioProject.currentSchemaVersion else {
                throw ProjectStoreError.schemaTooNew(
                    found: project.schemaVersion,
                    supported: StudioProject.currentSchemaVersion
                )
            }
            return project
        } catch let error as ProjectStoreError {
            throw error
        } catch {
            throw ProjectStoreError.readFailed(error.localizedDescription)
        }
    }

    public func save(_ project: StudioProject) async throws {
        guard fileManager.fileExists(atPath: packageURL(for: project.id).path) else {
            throw ProjectStoreError.missing(project.id)
        }
        guard project.schemaVersion <= StudioProject.currentSchemaVersion else {
            throw ProjectStoreError.schemaTooNew(
                found: project.schemaVersion,
                supported: StudioProject.currentSchemaVersion
            )
        }
        try writeProject(project)
    }

    /// Removes a project package. Used to roll back a package that was created
    /// for an import that then failed validation.
    public func delete(id: ProjectID) async throws {
        let package = packageURL(for: id)
        guard fileManager.fileExists(atPath: package.path) else { return }
        do {
            try fileManager.removeItem(at: package)
        } catch {
            throw ProjectStoreError.writeFailed(error.localizedDescription)
        }
    }

    /// Removes only disposable products generated from immutable sources. The
    /// cache directory is recreated immediately so later ingest can safely
    /// rebuild proxies and waveforms without changing project semantics.
    public func clearRebuildableCache(projectID: ProjectID) async throws {
        _ = try await load(id: projectID)
        let package = packageURL(for: projectID)
        let cache = try Self.safeRelativeURL("cache", inside: package, fileManager: fileManager)

        do {
            if fileManager.fileExists(atPath: cache.path) {
                let values = try cache.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else {
                    throw ProjectStoreError.invalidProject("The project cache path is unsafe.")
                }
                try fileManager.removeItem(at: cache)
            }
            try fileManager.createDirectory(at: cache, withIntermediateDirectories: true)
        } catch let error as ProjectStoreError {
            throw error
        } catch {
            throw ProjectStoreError.writeFailed(error.localizedDescription)
        }
    }

    public func list() async throws -> [ProjectSummary] {
        guard fileManager.fileExists(atPath: rootURL.path) else { return [] }

        do {
            let urls = try fileManager.contentsOfDirectory(
                at: rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            var summaries: [ProjectSummary] = []
            for url in urls where url.pathExtension == "creatorstudio" {
                let manifestURL = url.appendingPathComponent("project.json")
                guard let data = try? Data(contentsOf: manifestURL),
                      let project = try? Self.decoder().decode(StudioProject.self, from: data),
                      project.schemaVersion <= StudioProject.currentSchemaVersion
                else { continue }
                summaries.append(ProjectSummary(project: project))
            }
            return summaries.sorted { $0.updatedAt > $1.updatedAt }
        } catch {
            throw ProjectStoreError.readFailed(error.localizedDescription)
        }
    }

    public func loadTimeline(projectID: ProjectID) throws -> TimelineDocument {
        let url = packageURL(for: projectID).appendingPathComponent("timeline.json")
        do {
            let data = try Data(contentsOf: url)
            let timeline = try Self.decoder().decode(TimelineDocument.self, from: data)
            guard timeline.projectID == projectID else {
                throw ProjectStoreError.invalidProject("Timeline project ID does not match its package.")
            }
            guard timeline.schemaVersion <= TimelineDocument.currentSchemaVersion else {
                throw ProjectStoreError.schemaTooNew(
                    found: timeline.schemaVersion,
                    supported: TimelineDocument.currentSchemaVersion
                )
            }
            return timeline
        } catch let error as ProjectStoreError {
            throw error
        } catch {
            throw ProjectStoreError.readFailed(error.localizedDescription)
        }
    }

    public func saveTimeline(_ timeline: TimelineDocument) throws {
        let package = packageURL(for: timeline.projectID)
        guard fileManager.fileExists(atPath: package.path) else {
            throw ProjectStoreError.missing(timeline.projectID)
        }
        try write(timeline, to: package.appendingPathComponent("timeline.json"))
    }

    public func loadEditHistory(for timeline: TimelineDocument) throws -> TimelineEditHistory {
        let url = packageURL(for: timeline.projectID).appendingPathComponent("timeline-history.json")
        guard fileManager.fileExists(atPath: url.path) else {
            // Phase 0 and early Phase 1 packages predate persisted edit history.
            return TimelineEditHistory(timeline: timeline)
        }
        do {
            let data = try Data(contentsOf: url)
            let history = try Self.decoder().decode(TimelineEditHistory.self, from: data)
            guard history.schemaVersion <= TimelineEditHistory.currentSchemaVersion else {
                throw ProjectStoreError.schemaTooNew(
                    found: history.schemaVersion,
                    supported: TimelineEditHistory.currentSchemaVersion
                )
            }
            guard history.timelineID == timeline.id,
                  history.projectID == timeline.projectID
            else {
                throw ProjectStoreError.invalidProject("Timeline history identifiers do not match the project.")
            }
            return history
        } catch let error as ProjectStoreError {
            throw error
        } catch {
            throw ProjectStoreError.readFailed(error.localizedDescription)
        }
    }

    public func packageURL(for id: ProjectID) -> URL {
        rootURL.appendingPathComponent("\(id.description).creatorstudio", isDirectory: true)
    }

    public func loadWorkspace(id: ProjectID) async throws -> ProjectWorkspace {
        let project = try await load(id: id)
        let timeline = try loadTimeline(projectID: id)
        guard timeline.id == project.timelineID else {
            throw ProjectStoreError.invalidProject("Project and timeline identifiers do not match.")
        }
        let editHistory = try loadEditHistory(for: timeline)
        return ProjectWorkspace(project: project, timeline: timeline, editHistory: editHistory)
    }

    public func applyTimelineCommand(
        _ command: TimelineCommand,
        to projectID: ProjectID,
        now: Date = .studioNow()
    ) async throws -> ProjectWorkspace {
        let original = try await loadWorkspace(id: projectID)
        let state = try TimelineEditor().performing(
            command,
            on: original.timeline,
            history: original.editHistory,
            assetDurations: try assetDurations(in: original.project)
        )
        var edited = ProjectWorkspace(
            project: original.project,
            timeline: state.timeline,
            editHistory: state.history
        )
        edited.project.updatedAt = now
        try persist(edited, replacing: original)
        return edited
    }

    public func undoTimelineEdit(
        projectID: ProjectID,
        now: Date = .studioNow()
    ) async throws -> ProjectWorkspace {
        let original = try await loadWorkspace(id: projectID)
        let state = try TimelineEditor().undoing(
            original.timeline,
            history: original.editHistory
        )
        var edited = ProjectWorkspace(
            project: original.project,
            timeline: state.timeline,
            editHistory: state.history
        )
        edited.project.updatedAt = now
        try persist(edited, replacing: original)
        return edited
    }

    public func redoTimelineEdit(
        projectID: ProjectID,
        now: Date = .studioNow()
    ) async throws -> ProjectWorkspace {
        let original = try await loadWorkspace(id: projectID)
        let state = try TimelineEditor().redoing(
            original.timeline,
            history: original.editHistory
        )
        var edited = ProjectWorkspace(
            project: original.project,
            timeline: state.timeline,
            editHistory: state.history
        )
        edited.project.updatedAt = now
        try persist(edited, replacing: original)
        return edited
    }

    /// Copies the visible clips from another local project and appends them as
    /// one synchronized recording block at the end of this project's master
    /// timeline. The source project and both sets of immutable source files are
    /// left untouched.
    public func mergeProject(
        _ sourceProjectID: ProjectID,
        into destinationProjectID: ProjectID,
        now: Date = .studioNow(),
        maximumBytes: Int64 = 100_000_000_000
    ) async throws -> ProjectRecordingMergeResult {
        guard sourceProjectID != destinationProjectID else {
            throw ProjectStoreError.invalidProject("Choose a different recording to add to this master timeline.")
        }

        let source = try await loadWorkspace(id: sourceProjectID)
        let destination = try await loadWorkspace(id: destinationProjectID)
        let sourceClips = source.timeline.tracks
            .sorted { $0.order < $1.order }
            .flatMap { track in track.clips.map { (track, $0) } }
        guard !sourceClips.isEmpty else {
            throw ProjectStoreError.invalidProject("The selected recording has no timeline clips to add.")
        }

        let sourceAssetIDs = Set(sourceClips.map(\.1.assetID))
        let sourceAssets = source.project.assets.filter { sourceAssetIDs.contains($0.id) }
        guard sourceAssets.count == sourceAssetIDs.count else {
            throw ProjectStoreError.invalidProject("The selected recording references a missing source asset.")
        }

        let destinationPackage = packageURL(for: destinationProjectID)
        let destinationSources = destinationPackage.appendingPathComponent("sources", isDirectory: true)
        var importedAssets: [SourceAsset] = []
        var copiedURLs: [URL] = []

        do {
            for sourceAsset in sourceAssets {
                let sourceURL = try await assetURL(projectID: sourceProjectID, assetID: sourceAsset.id)
                let newAssetID = AssetID()
                let fileExtension = sourceURL.pathExtension.lowercased()
                let destinationURL = destinationSources.appendingPathComponent(
                    "\(newAssetID.description).\(fileExtension)",
                    isDirectory: false
                )
                let copied = try Self.copyHashingContents(
                    from: sourceURL,
                    to: destinationURL,
                    maximumBytes: maximumBytes,
                    fileManager: fileManager
                )
                copiedURLs.append(destinationURL)
                if let expectedHash = sourceAsset.contentHash,
                   expectedHash != "sha256:\(copied.digest)" {
                    throw ProjectStoreError.invalidProject("A source recording changed before it could be merged.")
                }
                try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: destinationURL.path)
                importedAssets.append(SourceAsset(
                    id: newAssetID,
                    kind: sourceAsset.kind,
                    relativePath: "sources/\(destinationURL.lastPathComponent)",
                    originalFilename: sourceAsset.originalFilename,
                    byteCount: copied.byteCount,
                    contentHash: "sha256:\(copied.digest)",
                    duration: sourceAsset.duration,
                    pixelSize: sourceAsset.pixelSize,
                    mediaMetadata: sourceAsset.mediaMetadata,
                    createdAt: now,
                    captureSessionID: sourceAsset.captureSessionID,
                    captureStart: sourceAsset.captureStart
                ))
            }

            let assetIDMap = Dictionary(uniqueKeysWithValues: zip(sourceAssets.map(\.id), importedAssets.map(\.id)))
            var assetDurations = try assetDurations(in: destination.project)
            for asset in importedAssets {
                assetDurations[asset.id] = asset.duration
            }

            let destinationEnd = destination.timeline.tracks
                .flatMap(\.clips)
                .map(\.timelineRange.end)
                .max() ?? .zero
            let sourceOrigin = sourceClips.map(\.1.timelineStart).min() ?? .zero
            var timeline = destination.timeline
            var history = destination.editHistory

            for (sourceTrack, sourceClip) in sourceClips {
                guard let newAssetID = assetIDMap[sourceClip.assetID] else {
                    throw ProjectStoreError.invalidProject("The selected recording has an invalid source map.")
                }
                let destinationTrack: TimelineTrack
                if let existing = timeline.tracks.first(where: { $0.kind == sourceTrack.kind }) {
                    destinationTrack = existing
                } else {
                    let nextOrder = (timeline.tracks.map(\.order).max() ?? -1) + 1
                    destinationTrack = TimelineTrack(kind: sourceTrack.kind, order: nextOrder)
                }

                let mergedClip = TimelineClip(
                    assetID: newAssetID,
                    sourceRange: sourceClip.sourceRange,
                    timelineStart: destinationEnd + (sourceClip.timelineStart - sourceOrigin),
                    playbackRate: sourceClip.playbackRate,
                    transform: sourceClip.transform,
                    gainDB: sourceClip.gainDB,
                    isEnabled: sourceClip.isEnabled
                )
                let command = TimelineCommand.placeClip(
                    trackID: destinationTrack.id,
                    trackKind: destinationTrack.kind,
                    trackOrder: destinationTrack.order,
                    clip: mergedClip
                )
                let before = timeline
                timeline = try TimelineEditor().applying(
                    command,
                    to: timeline,
                    assetDurations: assetDurations
                )
                try history.record(command: command, before: before, after: timeline)
            }

            var project = destination.project
            project.assets.append(contentsOf: importedAssets)
            project.updatedAt = now
            let merged = ProjectWorkspace(project: project, timeline: timeline, editHistory: history)
            try persist(merged, replacing: destination)
            return ProjectRecordingMergeResult(
                workspace: merged,
                importedAssets: importedAssets,
                sourceProjectID: sourceProjectID
            )
        } catch {
            for url in copiedURLs { try? fileManager.removeItem(at: url) }
            throw error
        }
    }

    /// Copies a user-selected file into immutable project-owned storage and adds
    /// one non-destructive timeline clip. The caller is responsible for holding
    /// any security-scoped file access for the duration of this method.
    public func importMedia(
        from sourceURL: URL,
        descriptor: MediaImportDescriptor,
        into projectID: ProjectID,
        now: Date = .studioNow(),
        maximumBytes: Int64 = 100_000_000_000
    ) async throws -> ProjectMediaImportResult {
        guard descriptor.duration > .zero else {
            throw ProjectMediaImportError.invalidDuration
        }
        if let pixelSize = descriptor.pixelSize,
           pixelSize.width <= 0 || pixelSize.height <= 0 {
            throw ProjectMediaImportError.invalidPixelSize
        }

        let fileExtension = sourceURL.pathExtension.lowercased()
        guard Self.allowedExtensions(for: descriptor.kind).contains(fileExtension) else {
            throw ProjectMediaImportError.unsupportedFileType(fileExtension)
        }
        guard let values = try? sourceURL.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        ),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            let sourceSize = values.fileSize,
            sourceSize > 0
        else {
            throw ProjectMediaImportError.sourceUnavailable
        }
        guard Int64(sourceSize) <= maximumBytes else {
            throw ProjectMediaImportError.fileTooLarge
        }

        let originalWorkspace = try await loadWorkspace(id: projectID)
        let package = packageURL(for: projectID)
        let sources = package.appendingPathComponent("sources", isDirectory: true)
        let assetID = AssetID()
        let destination = sources.appendingPathComponent(
            "\(assetID.description).\(fileExtension)",
            isDirectory: false
        )
        let partial = sources.appendingPathComponent(
            ".\(assetID.description).importing",
            isDirectory: false
        )
        guard !fileManager.fileExists(atPath: destination.path),
              !fileManager.fileExists(atPath: partial.path)
        else {
            throw ProjectMediaImportError.copyFailed("The generated source destination already exists.")
        }

        var projectWasWritten = false
        var timelineWasWritten = false
        var historyWasWritten = false
        do {
            let copied = try Self.copyHashingContents(
                from: sourceURL,
                to: partial,
                maximumBytes: maximumBytes,
                fileManager: fileManager
            )
            try fileManager.moveItem(at: partial, to: destination)

            let asset = SourceAsset(
                id: assetID,
                kind: descriptor.kind,
                relativePath: "sources/\(destination.lastPathComponent)",
                originalFilename: descriptor.originalFilename ?? sourceURL.lastPathComponent,
                byteCount: copied.byteCount,
                contentHash: "sha256:\(copied.digest)",
                duration: descriptor.duration,
                pixelSize: descriptor.pixelSize,
                mediaMetadata: descriptor.mediaMetadata,
                createdAt: now
            )
            let edit = try TimelineEditor().appending(
                asset: asset,
                to: originalWorkspace.timeline,
                assetDurations: try assetDurations(in: originalWorkspace.project)
            )
            var editHistory = originalWorkspace.editHistory
            try editHistory.record(
                command: edit.command,
                before: originalWorkspace.timeline,
                after: edit.timeline
            )
            var workspace = ProjectWorkspace(
                project: originalWorkspace.project,
                timeline: edit.timeline,
                editHistory: editHistory
            )
            workspace.project.assets.append(asset)
            workspace.project.updatedAt = now

            try writeProject(workspace.project)
            projectWasWritten = true
            try write(
                workspace.timeline,
                to: package.appendingPathComponent("timeline.json")
            )
            timelineWasWritten = true
            try write(
                workspace.editHistory,
                to: package.appendingPathComponent("timeline-history.json")
            )
            historyWasWritten = true
            try fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: destination.path)

            return ProjectMediaImportResult(
                workspace: workspace,
                importedAsset: asset,
                appendedClip: edit.clip
            )
        } catch let error as ProjectMediaImportError {
            try? fileManager.removeItem(at: partial)
            try? fileManager.removeItem(at: destination)
            if projectWasWritten { try? writeProject(originalWorkspace.project) }
            if timelineWasWritten {
                try? write(
                    originalWorkspace.timeline,
                    to: package.appendingPathComponent("timeline.json")
                )
            }
            if historyWasWritten {
                try? write(
                    originalWorkspace.editHistory,
                    to: package.appendingPathComponent("timeline-history.json")
                )
            }
            throw error
        } catch {
            try? fileManager.removeItem(at: partial)
            try? fileManager.removeItem(at: destination)
            if projectWasWritten { try? writeProject(originalWorkspace.project) }
            if timelineWasWritten {
                try? write(
                    originalWorkspace.timeline,
                    to: package.appendingPathComponent("timeline.json")
                )
            }
            if historyWasWritten {
                try? write(
                    originalWorkspace.editHistory,
                    to: package.appendingPathComponent("timeline-history.json")
                )
            }
            throw ProjectMediaImportError.copyFailed(error.localizedDescription)
        }
    }

    public func assetURL(projectID: ProjectID, assetID: AssetID) async throws -> URL {
        let project = try await load(id: projectID)
        guard let asset = project.assets.first(where: { $0.id == assetID }) else {
            throw ProjectStoreError.invalidProject("The project does not contain this source asset.")
        }
        let url = try Self.safeRelativeURL(
            asset.relativePath,
            inside: packageURL(for: projectID),
            fileManager: fileManager
        )
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else {
            throw ProjectStoreError.readFailed("The project source file is unavailable.")
        }
        return url
    }

    /// Returns only validated, package-owned paths for rebuildable ingest work.
    /// The cache directory may be removed at any time without affecting project
    /// semantics; the immutable source path remains separately validated.
    public func assetIngestLocation(
        projectID: ProjectID,
        assetID: AssetID
    ) async throws -> ProjectAssetIngestLocation {
        let sourceURL = try await assetURL(projectID: projectID, assetID: assetID)
        let package = packageURL(for: projectID)
        let relativePath = "cache/\(assetID.description)"
        let cacheDirectory = try Self.safeRelativeURL(
            relativePath,
            inside: package,
            fileManager: fileManager
        )
        do {
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        } catch {
            throw ProjectStoreError.writeFailed(error.localizedDescription)
        }
        guard let values = try? cacheDirectory.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        ),
            values.isDirectory == true,
            values.isSymbolicLink != true
        else {
            throw ProjectStoreError.invalidProject("The asset cache path is unsafe.")
        }
        return ProjectAssetIngestLocation(
            sourceURL: sourceURL,
            cacheDirectoryURL: cacheDirectory
        )
    }

    /// Persists inspection results without changing source bytes or edit timing.
    /// Capture-manifest durations remain the canonical clip bounds; inspected
    /// source timing is retained alongside them for preview/render mapping.
    public func updateMediaMetadata(
        _ metadata: SourceMediaMetadata,
        displayPixelSize: PixelSize?,
        projectID: ProjectID,
        assetID: AssetID,
        now: Date = .studioNow()
    ) async throws -> ProjectWorkspace {
        try Self.validate(metadata: metadata, displayPixelSize: displayPixelSize)
        let original = try await loadWorkspace(id: projectID)
        guard let index = original.project.assets.firstIndex(where: { $0.id == assetID }) else {
            throw ProjectStoreError.invalidProject("The project does not contain this source asset.")
        }
        var updated = original
        updated.project.assets[index].mediaMetadata = metadata
        if updated.project.assets[index].pixelSize == nil {
            updated.project.assets[index].pixelSize = displayPixelSize
        }
        updated.project.updatedAt = now
        try writeProject(updated.project)
        return updated
    }

    /// Capture import establishes a synchronized baseline rather than a series
    /// of user edits. Segment clips keep their shared session timestamps so a
    /// microphone or application-audio offset is not collapsed to zero. Later
    /// captures append as their own synchronized block, which lets the local
    /// Unlisted Recordings project safely hold more than one recording.
    public func bootstrapCaptureAssets(
        _ assets: [SourceAsset],
        sessionID: UUID,
        into projectID: ProjectID,
        now: Date = .studioNow()
    ) async throws -> ProjectWorkspace {
        guard !assets.isEmpty,
              assets.allSatisfy({
                  $0.captureSessionID == sessionID
                      && $0.duration > .zero
                      && ($0.captureStart ?? .zero) >= .zero
              })
        else {
            throw ProjectStoreError.invalidProject("Capture assets do not share a valid session clock.")
        }

        let original = try await loadWorkspace(id: projectID)
        guard !original.project.assets.contains(where: { $0.captureSessionID == sessionID }) else {
            throw ProjectStoreError.invalidProject("This capture session is already present in the project.")
        }

        let sortedAssets = assets.sorted { lhs, rhs in
            let lhsStart = lhs.captureStart ?? .zero
            let rhsStart = rhs.captureStart ?? .zero
            if lhsStart != rhsStart { return lhsStart < rhsStart }
            let lhsRank = Self.captureTrackRank(lhs.kind)
            let rhsRank = Self.captureTrackRank(rhs.kind)
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs.relativePath < rhs.relativePath
        }

        var timeline = original.timeline
        var durations = try assetDurations(in: original.project)
        for asset in sortedAssets {
            guard durations.updateValue(asset.duration, forKey: asset.id) == nil else {
                throw ProjectStoreError.invalidProject("Capture assets contain duplicate identifiers.")
            }
        }

        let timelineEnd = original.timeline.tracks
            .flatMap(\.clips)
            .map(\.timelineRange.end)
            .max() ?? .zero
        let sessionOrigin = sortedAssets.map { $0.captureStart ?? .zero }.min() ?? .zero
        for asset in sortedAssets {
            timeline = try TimelineEditor().placingCapturedAsset(
                asset,
                at: timelineEnd + ((asset.captureStart ?? .zero) - sessionOrigin),
                in: timeline,
                assetDurations: durations
            ).timeline
        }

        var project = original.project
        project.assets.append(contentsOf: sortedAssets)
        project.updatedAt = now
        let updated = ProjectWorkspace(
            project: project,
            timeline: timeline,
            editHistory: TimelineEditHistory(timeline: timeline)
        )
        try persist(updated, replacing: original)
        return updated
    }

    private func createPackageDirectories(for id: ProjectID) throws {
        let package = packageURL(for: id)
        do {
            try fileManager.createDirectory(at: package, withIntermediateDirectories: true)
            for directory in ["sources", "events", "analysis", "presets", "cache", "exports", "journal"] {
                try fileManager.createDirectory(
                    at: package.appendingPathComponent(directory, isDirectory: true),
                    withIntermediateDirectories: false
                )
            }
        } catch {
            throw ProjectStoreError.writeFailed(error.localizedDescription)
        }
    }

    private func writeProject(_ project: StudioProject) throws {
        try write(project, to: packageURL(for: project.id).appendingPathComponent("project.json"))
    }

    private func assetDurations(in project: StudioProject) throws -> [AssetID: StudioTime] {
        var result: [AssetID: StudioTime] = [:]
        for asset in project.assets {
            guard result.updateValue(asset.duration, forKey: asset.id) == nil else {
                throw ProjectStoreError.invalidProject("The project contains duplicate source asset identifiers.")
            }
        }
        return result
    }

    private func persist(_ workspace: ProjectWorkspace, replacing original: ProjectWorkspace) throws {
        let package = packageURL(for: workspace.project.id)
        do {
            try writeProject(workspace.project)
            try write(workspace.timeline, to: package.appendingPathComponent("timeline.json"))
            try write(
                workspace.editHistory,
                to: package.appendingPathComponent("timeline-history.json")
            )
        } catch {
            try? writeProject(original.project)
            try? write(original.timeline, to: package.appendingPathComponent("timeline.json"))
            try? write(
                original.editHistory,
                to: package.appendingPathComponent("timeline-history.json")
            )
            throw error
        }
    }

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        do {
            let data = try Self.encoder().encode(value)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw ProjectStoreError.writeFailed(error.localizedDescription)
        }
    }

    private static func allowedExtensions(for kind: MediaKind) -> Set<String> {
        switch kind {
        case .screenVideo, .cameraVideo:
            ["mov", "mp4", "m4v"]
        case .appAudio, .microphoneAudio, .music:
            ["m4a", "mp3", "wav", "aif", "aiff", "caf"]
        case .image:
            ["png", "jpg", "jpeg", "heic", "heif"]
        case .overlay:
            []
        }
    }

    private static func captureTrackRank(_ kind: MediaKind) -> Int {
        switch kind {
        case .screenVideo: 0
        case .cameraVideo: 1
        case .appAudio: 2
        case .microphoneAudio: 3
        case .music: 4
        case .image, .overlay: 5
        }
    }

    private static func validate(
        metadata: SourceMediaMetadata,
        displayPixelSize: PixelSize?
    ) throws {
        guard metadata.preferredTransform.isFinite,
              metadata.sourceDuration > .zero,
              metadata.nominalFrameRate.map({ $0.isFinite && $0 > 0 }) ?? true,
              metadata.estimatedFrameRate.map({ $0.isFinite && $0 > 0 }) ?? true,
              metadata.naturalPixelSize.map({ $0.width > 0 && $0.height > 0 }) ?? true,
              displayPixelSize.map({ $0.width > 0 && $0.height > 0 }) ?? true,
              metadata.audioFormat.map({
                  $0.sampleRate.isFinite && $0.sampleRate > 0 && $0.channelCount > 0
              }) ?? true
        else {
            throw ProjectStoreError.invalidProject("The inspected media metadata is invalid.")
        }
    }

    private static func copyHashingContents(
        from source: URL,
        to destination: URL,
        maximumBytes: Int64,
        fileManager: FileManager
    ) throws -> (digest: String, byteCount: Int64) {
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw ProjectMediaImportError.copyFailed("Could not create a project source file.")
        }
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }

        var hasher = SHA256()
        var byteCount: Int64 = 0
        while true {
            let chunk = try reader.read(upToCount: 4 * 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            let (nextByteCount, overflow) = byteCount.addingReportingOverflow(Int64(chunk.count))
            guard !overflow, nextByteCount <= maximumBytes else {
                throw ProjectMediaImportError.fileTooLarge
            }
            byteCount = nextByteCount
            hasher.update(data: chunk)
            try writer.write(contentsOf: chunk)
        }
        try writer.synchronize()
        guard byteCount > 0 else { throw ProjectMediaImportError.sourceUnavailable }
        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (digest, byteCount)
    }

    private static func safeRelativeURL(
        _ relativePath: String,
        inside root: URL,
        fileManager: FileManager
    ) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.contains("\\"),
              !relativePath.contains("\0"),
              !(relativePath as NSString).isAbsolutePath
        else {
            throw ProjectStoreError.invalidProject("A project source path is unsafe.")
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw ProjectStoreError.invalidProject("A project source path is unsafe.")
        }

        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = root.appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let prefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard resolved.path.hasPrefix(prefix) else {
            throw ProjectStoreError.invalidProject("A project source path escapes its package.")
        }

        var cursor = root
        for component in components {
            cursor.appendPathComponent(String(component))
            if fileManager.fileExists(atPath: cursor.path),
               (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw ProjectStoreError.invalidProject("A project source path contains a symbolic link.")
            }
        }
        return resolved
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
