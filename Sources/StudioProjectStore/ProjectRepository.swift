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
        try createPackageDirectories(for: project.id)
        try writeProject(project)

        let timeline = TimelineDocument(id: project.timelineID, projectID: project.id)
        try write(timeline, to: packageURL(for: project.id).appendingPathComponent("timeline.json"))
        return project
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
            return try Self.decoder().decode(TimelineDocument.self, from: data)
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

    public func packageURL(for id: ProjectID) -> URL {
        rootURL.appendingPathComponent("\(id.description).creatorstudio", isDirectory: true)
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

    private func write<Value: Encodable>(_ value: Value, to url: URL) throws {
        do {
            let data = try Self.encoder().encode(value)
            try data.write(to: url, options: [.atomic])
        } catch {
            throw ProjectStoreError.writeFailed(error.localizedDescription)
        }
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
