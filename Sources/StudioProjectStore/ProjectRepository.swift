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
