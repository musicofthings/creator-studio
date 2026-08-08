import CryptoKit
import Foundation
import StudioCapture
import StudioDomain

public enum CaptureInboxStatus: String, Codable, Sendable {
    case recording
    case stopping
    case completed
    case recovered
    case storageConstrained
    case failed
    case imported
}

public struct CaptureInboxItem: Hashable, Codable, Sendable, Identifiable {
    public var id: UUID { sessionID }
    public var sessionID: UUID
    public var status: CaptureInboxStatus
    public var startedAt: Date
    public var updatedAt: Date
    public var duration: StudioTime
    public var segmentCount: Int
    public var failureReason: String?

    public init(
        sessionID: UUID,
        status: CaptureInboxStatus,
        startedAt: Date,
        updatedAt: Date,
        duration: StudioTime,
        segmentCount: Int,
        failureReason: String? = nil
    ) {
        self.sessionID = sessionID
        self.status = status
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.duration = duration
        self.segmentCount = segmentCount
        self.failureReason = failureReason
    }

    public var canImport: Bool {
        segmentCount > 0 && status != .recording && status != .stopping && status != .imported
    }
}

/// A segment that failed validation and was left behind. Recovering forty good
/// segments and reporting the one bad one beats refusing the whole session.
public struct CaptureImportSkip: Hashable, Codable, Sendable {
    public var relativePath: String
    public var reason: String

    public init(relativePath: String, reason: String) {
        self.relativePath = relativePath
        self.reason = reason
    }
}

public struct CaptureImportResult: Hashable, Sendable {
    public var project: StudioProject
    public var importedAssets: [SourceAsset]
    public var skipped: [CaptureImportSkip]
    public var wasRecovered: Bool
    public var inboxAcknowledged: Bool

    public init(
        project: StudioProject,
        importedAssets: [SourceAsset],
        skipped: [CaptureImportSkip] = [],
        wasRecovered: Bool,
        inboxAcknowledged: Bool
    ) {
        self.project = project
        self.importedAssets = importedAssets
        self.skipped = skipped
        self.wasRecovered = wasRecovered
        self.inboxAcknowledged = inboxAcknowledged
    }
}

public enum CaptureImportError: Error, Equatable, Sendable {
    case sessionMissing(UUID)
    case sessionStillRecording(UUID)
    case sessionStillActive(UUID)
    case noRecoverableMedia(UUID)
    case invalidSchema(String)
    case unsafePath(String)
    case invalidFile(String)
    case hashMismatch(String)
    case copyFailed(String)
}

extension CaptureImportError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .sessionMissing:
            "The capture session is no longer available."
        case .sessionStillRecording:
            "The recording is still active and cannot be imported yet."
        case .sessionStillActive:
            "The recording is still active and cannot be deleted yet."
        case .noRecoverableMedia:
            "The session contains no committed media to recover."
        case .invalidSchema:
            "The capture manifest is invalid or from an unsupported version."
        case .unsafePath:
            "The capture contains an unsafe file path and was not imported."
        case .invalidFile:
            "A capture file failed validation and was not imported."
        case .hashMismatch:
            "A capture file changed after it was committed and was not imported."
        case .copyFailed:
            "Creator Studio could not safely copy the capture into the project."
        }
    }
}

public actor CaptureInboxImporter {
    public let inboxRootURL: URL

    private let repository: FileProjectRepository
    private let fileManager: FileManager
    private let protocolReader: CaptureProtocolReader
    private let maximumMediaBytes: Int64
    private let staleRecordingInterval: TimeInterval
    private var discoveryCache: [UUID: DiscoveryCacheEntry] = [:]

    public init(
        inboxRootURL: URL,
        repository: FileProjectRepository,
        fileManager: FileManager = .default,
        protocolReader: CaptureProtocolReader = CaptureProtocolReader(),
        maximumMediaBytes: Int64 = 100_000_000_000,
        staleRecordingInterval: TimeInterval = 45
    ) {
        self.inboxRootURL = inboxRootURL
        self.repository = repository
        self.fileManager = fileManager
        self.protocolReader = protocolReader
        self.maximumMediaBytes = maximumMediaBytes
        self.staleRecordingInterval = staleRecordingInterval
    }

    private struct DiscoveryCacheEntry {
        var manifestModified: Date
        var manifestSize: Int
        var item: CaptureInboxItem
    }

    public func discover(now: Date = .studioNow()) -> [CaptureInboxItem] {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: inboxRootURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var seen: Set<UUID> = []
        let items: [CaptureInboxItem] = directories.compactMap { directory in
            guard let id = UUID(uuidString: directory.lastPathComponent),
                  let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
                  values.isDirectory == true,
                  values.isSymbolicLink != true
            else { return nil }
            seen.insert(id)

            // Every persistence path rewrites the manifest, so its size and
            // modification date are a sound proxy for "nothing changed" — and
            // re-parsing an untouched journal every refresh is the single most
            // expensive thing this call can do while a recording is running.
            let stamp = manifestStamp(for: directory)
            if let cached = discoveryCache[id],
               let stamp,
               cached.manifestModified == stamp.modified,
               cached.manifestSize == stamp.size {
                var item = cached.item
                if item.status == .recording || item.status == .stopping,
                   item.segmentCount > 0,
                   now.timeIntervalSince(item.updatedAt) > staleRecordingInterval {
                    // Status is partly a function of time. A crashed extension
                    // stops touching its manifest, so returning the cached status
                    // unchanged would leave the session "recording" forever.
                    item.status = .recovered
                    discoveryCache[id]?.item = item
                }
                return item
            }

            let item: CaptureInboxItem
            do {
                let recovered = try protocolReader.loadSession(at: directory)
                item = recovered.manifest.sessionID == id
                    ? self.item(for: recovered.manifest, now: now)
                    : failedItem(id: id, reason: "The session ID does not match its directory.", now: now)
            } catch {
                item = failedItem(id: id, reason: String(describing: error), now: now)
            }
            if let stamp {
                discoveryCache[id] = DiscoveryCacheEntry(
                    manifestModified: stamp.modified,
                    manifestSize: stamp.size,
                    item: item
                )
            }
            return item
        }

        discoveryCache = discoveryCache.filter { seen.contains($0.key) }
        return items.sorted { $0.updatedAt > $1.updatedAt }
    }

    /// Forces a fresh manifest read for one session. A deliberate stop writes
    /// `finalized` immediately before the app imports it; relying on the normal
    /// discovery cache in that narrow window can otherwise expose the prior
    /// `recording` state and incorrectly send a completed capture to recovery.
    public func discoverSession(id: UUID, now: Date = .studioNow()) -> CaptureInboxItem? {
        discoveryCache.removeValue(forKey: id)
        return discover(now: now).first(where: { $0.sessionID == id })
    }

    public func importSession(
        id: UUID,
        into projectID: ProjectID,
        recordingName: String? = nil,
        now: Date = .studioNow()
    ) async throws -> CaptureImportResult {
        let directory = inboxRootURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path),
              let directoryValues = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              directoryValues.isDirectory == true,
              directoryValues.isSymbolicLink != true
        else {
            throw CaptureImportError.sessionMissing(id)
        }

        let recovered: RecoveredCaptureSession
        do {
            recovered = try protocolReader.loadSession(at: directory)
        } catch {
            throw CaptureImportError.invalidSchema(String(describing: error))
        }
        let manifest = recovered.manifest
        guard manifest.sessionID == id else {
            throw CaptureImportError.invalidSchema("The manifest session ID does not match its directory.")
        }

        let inboxItem = item(for: manifest, now: now)
        guard inboxItem.status != .recording, inboxItem.status != .stopping else {
            throw CaptureImportError.sessionStillRecording(id)
        }
        guard !manifest.files.isEmpty else {
            throw CaptureImportError.noRecoverableMedia(id)
        }

        let validation = try validateFiles(in: manifest, sessionDirectory: directory)
        var skipped = validation.skipped
        var project = try await repository.load(id: projectID)
        let existing = project.assets.filter { $0.captureSessionID == id }
        if !validation.validated.isEmpty,
           existing.count == validation.validated.count,
           Set(existing.compactMap(\.contentHash)) == Set(validation.validated.map { "sha256:\($0.segment.sha256)" }) {
            let workspace = try await repository.bootstrapCaptureAssets(
                existing,
                sessionID: id,
                into: projectID,
                now: now
            )
            let acknowledged = acknowledgeImport(at: directory)
            return CaptureImportResult(
                project: workspace.project,
                importedAssets: existing,
                skipped: skipped,
                wasRecovered: inboxItem.status != .completed,
                inboxAcknowledged: acknowledged
            )
        }

        let packageURL = await repository.packageURL(for: projectID)
        let sourcesURL = packageURL.appendingPathComponent("sources", isDirectory: true)
        var createdURLs: [URL] = []
        var assets: [SourceAsset] = []

        do {
            for file in validation.validated {
                let assetID = AssetID()
                let fileExtension = file.url.pathExtension.lowercased()
                let destination = sourcesURL.appendingPathComponent(
                    "\(assetID.description).\(fileExtension)",
                    isDirectory: false
                )
                guard !fileManager.fileExists(atPath: destination.path) else {
                    throw CaptureImportError.copyFailed("A generated source destination already exists.")
                }

                // One pass: copy and digest together, then compare against the
                // committed hash. Hashing the source first and the copy after
                // would read every byte three times.
                let copiedHash = try Self.copyHashingContents(
                    from: file.url,
                    to: destination,
                    fileManager: fileManager
                )
                createdURLs.append(destination)
                guard copiedHash == file.segment.sha256 else {
                    try? fileManager.removeItem(at: destination)
                    createdURLs.removeLast()
                    skipped.append(CaptureImportSkip(
                        relativePath: file.segment.relativePath,
                        reason: "The file changed after it was committed."
                    ))
                    continue
                }
                try? fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: destination.path)

                assets.append(SourceAsset(
                    id: assetID,
                    kind: Self.mediaKind(for: file.segment.source),
                    relativePath: "sources/\(destination.lastPathComponent)",
                    originalFilename: Self.recordingFilename(
                        recordingName,
                        source: file.segment.source,
                        fallback: file.url.lastPathComponent
                    ),
                    byteCount: file.segment.byteCount,
                    contentHash: "sha256:\(copiedHash)",
                    duration: file.segment.duration,
                    createdAt: now,
                    captureSessionID: id,
                    captureStart: file.segment.start
                ))
            }

            guard !assets.isEmpty else {
                throw CaptureImportError.noRecoverableMedia(id)
            }

            try copyJournalIfPresent(
                from: directory,
                relativePath: manifest.eventsRelativePath,
                to: packageURL,
                sessionID: id
            )
            try copyPointerEventsIfPresent(
                from: directory,
                to: packageURL,
                sessionID: id
            )
            let workspace = try await repository.bootstrapCaptureAssets(
                assets,
                sessionID: id,
                into: projectID,
                now: now
            )
            project = workspace.project
        } catch let error as CaptureImportError {
            for url in createdURLs { try? fileManager.removeItem(at: url) }
            throw error
        } catch {
            for url in createdURLs { try? fileManager.removeItem(at: url) }
            throw CaptureImportError.copyFailed(error.localizedDescription)
        }

        let acknowledged = acknowledgeImport(at: directory)
        return CaptureImportResult(
            project: project,
            importedAssets: assets,
            skipped: skipped,
            wasRecovered: inboxItem.status != .completed,
            inboxAcknowledged: acknowledged
        )
    }

    /// Deletes one finalized, recovered, or failed staging session. Imported
    /// media lives in a project package by this point; this removes only the
    /// recovery-inbox copy. An active capture cannot be deleted through this
    /// path because its writer may still be committing a segment.
    public func discardSession(id: UUID, now: Date = .studioNow()) throws {
        let directory = inboxRootURL.appendingPathComponent(id.uuidString.lowercased(), isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path),
              let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true,
              values.isSymbolicLink != true
        else {
            throw CaptureImportError.sessionMissing(id)
        }

        if let recovered = try? protocolReader.loadSession(at: directory) {
            guard recovered.manifest.sessionID == id else {
                throw CaptureImportError.invalidSchema("The manifest session ID does not match its directory.")
            }
            let inboxItem = item(for: recovered.manifest, now: now)
            guard inboxItem.status != .recording, inboxItem.status != .stopping else {
                throw CaptureImportError.sessionStillActive(id)
            }
        }

        do {
            try fileManager.removeItem(at: directory)
            discoveryCache.removeValue(forKey: id)
        } catch {
            throw CaptureImportError.copyFailed("Creator Studio could not delete the recording: \(error.localizedDescription)")
        }
    }

    private struct ValidatedFile {
        var segment: CaptureSegment
        var url: URL
    }

    private struct ValidationOutcome {
        var validated: [ValidatedFile]
        var skipped: [CaptureImportSkip]
    }

    /// Malformed segments are skipped and reported. Path traversal and symlinks
    /// are not: those mean the manifest was tampered with, and the safe response
    /// is to refuse the whole session rather than to import part of it.
    private func validateFiles(
        in manifest: CaptureManifest,
        sessionDirectory: URL
    ) throws -> ValidationOutcome {
        var paths = Set<String>()
        var validated: [ValidatedFile] = []
        var skipped: [CaptureImportSkip] = []

        for segment in manifest.files {
            let url = try Self.safeFileURL(
                relativePath: segment.relativePath,
                inside: sessionDirectory,
                fileManager: fileManager
            )

            guard [.screen, .appAudio, .microphone, .camera].contains(segment.source) else {
                skipped.append(CaptureImportSkip(
                    relativePath: segment.relativePath,
                    reason: "Unsupported capture role: \(segment.source.rawValue)."
                ))
                continue
            }
            guard segment.byteCount > 0, segment.byteCount <= maximumMediaBytes,
                  segment.duration.microseconds >= 0,
                  segment.start.microseconds >= 0,
                  segment.sha256.count == 64,
                  segment.sha256.allSatisfy({ $0.isHexDigit && !$0.isUppercase })
            else {
                skipped.append(CaptureImportSkip(
                    relativePath: segment.relativePath,
                    reason: "The manifest entry is malformed."
                ))
                continue
            }
            guard paths.insert(segment.relativePath).inserted else {
                skipped.append(CaptureImportSkip(
                    relativePath: segment.relativePath,
                    reason: "The manifest lists this path more than once."
                ))
                continue
            }

            let allowedExtensions: Set<String> = segment.source == .screen || segment.source == .camera
                ? ["mov", "mp4"]
                : ["m4a", "caf", "mov"]
            guard allowedExtensions.contains(url.pathExtension.lowercased()) else {
                skipped.append(CaptureImportSkip(
                    relativePath: segment.relativePath,
                    reason: "The file type is not permitted for this capture role."
                ))
                continue
            }

            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values?.isRegularFile == true,
                  values?.isSymbolicLink != true,
                  Int64(values?.fileSize ?? -1) == segment.byteCount
            else {
                skipped.append(CaptureImportSkip(
                    relativePath: segment.relativePath,
                    reason: "The file is missing or its size no longer matches the manifest."
                ))
                continue
            }

            validated.append(ValidatedFile(segment: segment, url: url))
        }

        validated.sort { lhs, rhs in
            if lhs.segment.start == rhs.segment.start {
                return lhs.segment.relativePath < rhs.segment.relativePath
            }
            return lhs.segment.start < rhs.segment.start
        }
        return ValidationOutcome(validated: validated, skipped: skipped)
    }

    private func manifestStamp(for directory: URL) -> (modified: Date, size: Int)? {
        let manifestURL = directory.appendingPathComponent("manifest.json")
        guard let values = try? manifestURL.resourceValues(
            forKeys: [.contentModificationDateKey, .fileSizeKey]
        ),
            let modified = values.contentModificationDate,
            let size = values.fileSize
        else { return nil }
        return (modified, size)
    }

    private func copyJournalIfPresent(
        from sessionDirectory: URL,
        relativePath: String,
        to packageURL: URL,
        sessionID: UUID
    ) throws {
        let source = try Self.safeFileURL(
            relativePath: relativePath,
            inside: sessionDirectory,
            fileManager: fileManager
        )
        let destination = packageURL
            .appendingPathComponent("events", isDirectory: true)
            .appendingPathComponent("capture-\(sessionID.uuidString.lowercased()).jsonl")
        if fileManager.fileExists(atPath: destination.path) { return }
        try fileManager.copyItem(at: source, to: destination)
        try? fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: destination.path)
    }

    private func copyPointerEventsIfPresent(
        from sessionDirectory: URL,
        to packageURL: URL,
        sessionID: UUID
    ) throws {
        let source = sessionDirectory.appendingPathComponent("cursor-events.jsonl")
        guard fileManager.fileExists(atPath: source.path) else { return }
        guard let values = try? source.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true
        else {
            throw CaptureImportError.invalidFile("cursor-events.jsonl")
        }
        let destination = packageURL
            .appendingPathComponent("events", isDirectory: true)
            .appendingPathComponent("cursor-\(sessionID.uuidString.lowercased()).jsonl")
        guard !fileManager.fileExists(atPath: destination.path) else { return }
        try fileManager.copyItem(at: source, to: destination)
        try? fileManager.setAttributes([.posixPermissions: 0o444], ofItemAtPath: destination.path)
    }

    private static func recordingFilename(
        _ recordingName: String?,
        source: CaptureSource,
        fallback: String
    ) -> String {
        guard let recordingName else { return fallback }
        let suffix = switch source {
        case .screen: ""
        case .appAudio: " - System Audio"
        case .microphone: " - Microphone"
        case .camera: " - Camera"
        case .interactionEvents: " - Interactions"
        }
        let fileExtension = URL(fileURLWithPath: fallback).pathExtension
        return "\(recordingName)\(suffix).\(fileExtension)"
    }

    private func acknowledgeImport(at directory: URL) -> Bool {
        do {
            let persistence = try CaptureSessionPersistence(opening: directory, fileManager: fileManager)
            try persistence.acknowledgeImport()
            return true
        } catch {
            return false
        }
    }

    private func item(for manifest: CaptureManifest, now: Date) -> CaptureInboxItem {
        let status: CaptureInboxStatus = switch manifest.state {
        case .recording:
            now.timeIntervalSince(manifest.updatedAt) > staleRecordingInterval && !manifest.files.isEmpty
                ? .recovered
                : .recording
        case .stopping:
            now.timeIntervalSince(manifest.updatedAt) > staleRecordingInterval && !manifest.files.isEmpty
                ? .recovered
                : .stopping
        case .finalized: .completed
        case .interrupted: .recovered
        case .storageConstrained: .storageConstrained
        case .failed: .failed
        case .imported: .imported
        }
        return CaptureInboxItem(
            sessionID: manifest.sessionID,
            status: status,
            startedAt: manifest.startedAt,
            updatedAt: manifest.updatedAt,
            duration: manifest.duration,
            segmentCount: manifest.files.count,
            failureReason: manifest.failureReason
        )
    }

    private func failedItem(id: UUID, reason: String, now: Date) -> CaptureInboxItem {
        CaptureInboxItem(
            sessionID: id,
            status: .failed,
            startedAt: now,
            updatedAt: now,
            duration: .zero,
            segmentCount: 0,
            failureReason: reason
        )
    }

    private static func safeFileURL(
        relativePath: String,
        inside root: URL,
        fileManager: FileManager
    ) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.contains("\\"),
              !relativePath.contains("\0"),
              !(relativePath as NSString).isAbsolutePath
        else {
            throw CaptureImportError.unsafePath(relativePath)
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CaptureImportError.unsafePath(relativePath)
        }

        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let resolved = candidate.resolvingSymlinksInPath()
        let rootPrefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard resolved.path.hasPrefix(rootPrefix) else {
            throw CaptureImportError.unsafePath(relativePath)
        }

        var cursor = root
        for component in components {
            cursor.appendPathComponent(String(component))
            if fileManager.fileExists(atPath: cursor.path),
               (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw CaptureImportError.unsafePath(relativePath)
            }
        }
        return resolved
    }

    /// Streams `source` into `destination`, returning the SHA-256 of the bytes
    /// actually written.
    private static func copyHashingContents(
        from source: URL,
        to destination: URL,
        fileManager: FileManager
    ) throws -> String {
        guard fileManager.createFile(atPath: destination.path, contents: nil) else {
            throw CaptureImportError.copyFailed("Could not create the project source file.")
        }
        let reader = try FileHandle(forReadingFrom: source)
        defer { try? reader.close() }
        let writer = try FileHandle(forWritingTo: destination)
        defer { try? writer.close() }

        var hasher = SHA256()
        while true {
            let chunk = try reader.read(upToCount: 4 * 1_048_576) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
            try writer.write(contentsOf: chunk)
        }
        try writer.synchronize()
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func mediaKind(for source: CaptureSource) -> MediaKind {
        switch source {
        case .screen: .screenVideo
        case .appAudio: .appAudio
        case .microphone: .microphoneAudio
        case .camera: .cameraVideo
        case .interactionEvents: .overlay
        }
    }
}
