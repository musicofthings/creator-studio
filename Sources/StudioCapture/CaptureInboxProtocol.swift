import Foundation
import StudioDomain

public enum CaptureManifestState: String, Codable, Sendable {
    case recording
    case stopping
    case finalized
    case interrupted
    case storageConstrained
    case failed
    case imported
}

public struct CaptureSegment: Hashable, Codable, Sendable {
    public var source: CaptureSource
    public var relativePath: String
    public var sha256: String
    public var byteCount: Int64
    public var start: StudioTime
    public var duration: StudioTime

    public init(
        source: CaptureSource,
        relativePath: String,
        sha256: String,
        byteCount: Int64,
        start: StudioTime,
        duration: StudioTime
    ) {
        self.source = source
        self.relativePath = relativePath
        self.sha256 = sha256
        self.byteCount = byteCount
        self.start = start
        self.duration = duration
    }

    private enum CodingKeys: String, CodingKey {
        case source = "role"
        case relativePath
        case sha256
        case byteCount
        case startUs
        case durationUs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        source = try container.decode(CaptureSource.self, forKey: .source)
        relativePath = try container.decode(String.self, forKey: .relativePath)
        sha256 = try container.decode(String.self, forKey: .sha256)
        byteCount = try container.decode(Int64.self, forKey: .byteCount)
        start = StudioTime(microseconds: try container.decode(Int64.self, forKey: .startUs))
        duration = StudioTime(microseconds: try container.decode(Int64.self, forKey: .durationUs))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(source, forKey: .source)
        try container.encode(relativePath, forKey: .relativePath)
        try container.encode(sha256, forKey: .sha256)
        try container.encode(byteCount, forKey: .byteCount)
        try container.encode(start.microseconds, forKey: .startUs)
        try container.encode(duration.microseconds, forKey: .durationUs)
    }
}

public struct CaptureCapabilitySnapshot: Hashable, Codable, Sendable {
    public var screen: Bool
    public var appAudio: Bool
    public var microphone: Bool
    public var camera: Bool
    public var interactionEvents: Bool

    public init(_ capabilities: CaptureCapabilities) {
        screen = capabilities.supportedSources.contains(.screen)
        appAudio = capabilities.supportedSources.contains(.appAudio)
        microphone = capabilities.supportedSources.contains(.microphone)
        camera = capabilities.supportedSources.contains(.camera)
        interactionEvents = capabilities.supportedSources.contains(.interactionEvents)
    }
}

public struct CaptureManifest: Hashable, Codable, Sendable {
    public static let currentSchemaVersion = 1

    public var schemaVersion: Int
    public var minimumReaderVersion: Int
    public var sessionID: UUID
    public var state: CaptureManifestState
    public var startedAt: Date
    public var updatedAt: Date
    public var duration: StudioTime
    public var capabilities: CaptureCapabilitySnapshot
    /// Sources that actually delivered media, as opposed to the sources the
    /// extension was built to support. The system broadcast picker — not the
    /// app — decides whether the microphone is live, so this is the only
    /// trustworthy record of what a session contains.
    public var observedSources: Set<CaptureSource>
    public var files: [CaptureSegment]
    public var eventsRelativePath: String
    public var failureReason: String?

    public init(
        sessionID: UUID,
        state: CaptureManifestState = .recording,
        startedAt: Date = .studioNow(),
        updatedAt: Date = .studioNow(),
        duration: StudioTime = .zero,
        capabilities: CaptureCapabilities,
        observedSources: Set<CaptureSource> = [],
        files: [CaptureSegment] = [],
        eventsRelativePath: String = "events.jsonl",
        failureReason: String? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.minimumReaderVersion = 1
        self.sessionID = sessionID
        self.state = state
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.duration = duration
        self.capabilities = CaptureCapabilitySnapshot(capabilities)
        self.observedSources = observedSources
        self.files = files
        self.eventsRelativePath = eventsRelativePath
        self.failureReason = failureReason
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case minimumReaderVersion
        case sessionID
        case state
        case startedAt
        case updatedAt
        case durationUs
        case capabilities
        case observedSources
        case files
        case eventsRelativePath = "eventsPath"
        case failureReason
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        minimumReaderVersion = try container.decode(Int.self, forKey: .minimumReaderVersion)
        sessionID = try container.decode(UUID.self, forKey: .sessionID)
        state = try container.decode(CaptureManifestState.self, forKey: .state)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        duration = StudioTime(microseconds: try container.decode(Int64.self, forKey: .durationUs))
        capabilities = try container.decode(CaptureCapabilitySnapshot.self, forKey: .capabilities)
        observedSources = Set(
            try container.decodeIfPresent([CaptureSource].self, forKey: .observedSources) ?? []
        )
        files = try container.decode([CaptureSegment].self, forKey: .files)
        eventsRelativePath = try container.decode(String.self, forKey: .eventsRelativePath)
        failureReason = try container.decodeIfPresent(String.self, forKey: .failureReason)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(minimumReaderVersion, forKey: .minimumReaderVersion)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encode(state, forKey: .state)
        try container.encode(startedAt, forKey: .startedAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(duration.microseconds, forKey: .durationUs)
        try container.encode(capabilities, forKey: .capabilities)
        try container.encode(observedSources.sorted { $0.rawValue < $1.rawValue }, forKey: .observedSources)
        try container.encode(files, forKey: .files)
        try container.encode(eventsRelativePath, forKey: .eventsRelativePath)
        try container.encodeIfPresent(failureReason, forKey: .failureReason)
    }
}

public enum CaptureJournalEventKind: String, Codable, Sendable {
    case started
    case paused
    case resumed
    case stopping
    case segmentCommitted
    case finalized
    case interrupted
    case storageConstrained
    case failed
    case importAcknowledged
    case warning
}

public struct CaptureJournalEvent: Hashable, Codable, Sendable {
    public var sequence: Int64
    public var sessionID: UUID
    public var kind: CaptureJournalEventKind
    public var recordedAt: Date
    public var segment: CaptureSegment?
    public var detail: String?

    public init(
        sequence: Int64,
        sessionID: UUID,
        kind: CaptureJournalEventKind,
        recordedAt: Date = .studioNow(),
        segment: CaptureSegment? = nil,
        detail: String? = nil
    ) {
        self.sequence = sequence
        self.sessionID = sessionID
        self.kind = kind
        self.recordedAt = recordedAt
        self.segment = segment
        self.detail = detail
    }
}

public enum CaptureInboxProtocolError: Error, Equatable, Sendable {
    case invalidSchema(found: Int, supported: Int)
    case invalidManifest(String)
    case invalidJournal(String)
    case readFailed(String)
    case writeFailed(String)
}

/// Synchronous persistence used from the extension's dedicated writer queue.
/// Journal records are flushed before the atomically replaced manifest is updated.
public final class CaptureSessionPersistence {
    public let directoryURL: URL
    public private(set) var manifest: CaptureManifest

    private var nextSequence: Int64
    private let fileManager: FileManager

    public init(
        inboxRootURL: URL,
        sessionID: UUID = UUID(),
        capabilities: CaptureCapabilities,
        now: Date = .studioNow(),
        fileManager: FileManager = .default
    ) throws {
        self.fileManager = fileManager
        directoryURL = inboxRootURL.appendingPathComponent(
            sessionID.uuidString.lowercased(),
            isDirectory: true
        )
        manifest = CaptureManifest(
            sessionID: sessionID,
            startedAt: now,
            updatedAt: now,
            capabilities: capabilities
        )
        nextSequence = 1

        do {
            guard !fileManager.fileExists(atPath: directoryURL.path) else {
                throw CaptureInboxProtocolError.writeFailed("The capture session already exists.")
            }
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: Self.protectedDirectoryAttributes
            )
            try fileManager.createDirectory(
                at: directoryURL.appendingPathComponent("segments", isDirectory: true),
                withIntermediateDirectories: false,
                attributes: Self.protectedDirectoryAttributes
            )
            try append(kind: .started, recordedAt: now)
            try writeManifest()
        } catch let error as CaptureInboxProtocolError {
            throw error
        } catch {
            throw CaptureInboxProtocolError.writeFailed(error.localizedDescription)
        }
    }

    public init(opening directoryURL: URL, fileManager: FileManager = .default) throws {
        self.directoryURL = directoryURL
        self.fileManager = fileManager
        let recovered = try CaptureProtocolReader().loadSession(at: directoryURL)
        manifest = recovered.manifest
        nextSequence = recovered.lastSequence + 1
    }

    public func recordLifecycle(
        _ kind: CaptureJournalEventKind,
        state: CaptureManifestState? = nil,
        duration: StudioTime? = nil,
        detail: String? = nil,
        at date: Date = .studioNow()
    ) throws {
        try append(kind: kind, recordedAt: date, detail: detail)
        if let state { manifest.state = state }
        if let duration { manifest.duration = max(manifest.duration, duration) }
        manifest.updatedAt = date
        if kind == .failed || kind == .storageConstrained || kind == .interrupted {
            manifest.failureReason = detail
        }
        try writeManifest()
    }

    public func commit(_ segment: CaptureSegment, at date: Date = .studioNow()) throws {
        guard segment.byteCount > 0, !segment.sha256.isEmpty else {
            throw CaptureInboxProtocolError.invalidManifest("Committed segments require a size and SHA-256 digest.")
        }
        try append(kind: .segmentCommitted, recordedAt: date, segment: segment)
        if let index = manifest.files.firstIndex(where: { $0.relativePath == segment.relativePath }) {
            manifest.files[index] = segment
        } else {
            manifest.files.append(segment)
        }
        manifest.duration = max(manifest.duration, segment.start + segment.duration)
        manifest.updatedAt = date
        try writeManifest()
    }

    public func acknowledgeImport(at date: Date = .studioNow()) throws {
        try recordLifecycle(.importAcknowledged, state: .imported, at: date)
    }

    /// Records that a source actually delivered media. Cheap to call per sample:
    /// it rewrites the manifest only the first time each source is seen.
    public func recordObservedSource(_ source: CaptureSource, at date: Date = .studioNow()) throws {
        guard !manifest.observedSources.contains(source) else { return }
        manifest.observedSources.insert(source)
        manifest.updatedAt = date
        try writeManifest()
    }

    private func append(
        kind: CaptureJournalEventKind,
        recordedAt: Date,
        segment: CaptureSegment? = nil,
        detail: String? = nil
    ) throws {
        let event = CaptureJournalEvent(
            sequence: nextSequence,
            sessionID: manifest.sessionID,
            kind: kind,
            recordedAt: recordedAt,
            segment: segment,
            detail: detail
        )

        do {
            var data = try Self.encoder().encode(event)
            data.append(0x0A)
            let url = directoryURL.appendingPathComponent(manifest.eventsRelativePath)
            if fileManager.fileExists(atPath: url.path) {
                let handle = try FileHandle(forWritingTo: url)
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.synchronize()
            } else {
                try data.write(to: url, options: [.atomic])
            }
        } catch {
            throw CaptureInboxProtocolError.writeFailed(error.localizedDescription)
        }

        // Only after the record is durable. Advancing on a failed write would
        // leave a permanent gap that the reader's contiguity check rejects.
        nextSequence += 1
    }

    private func writeManifest() throws {
        do {
            let data = try Self.encoder(prettyPrinted: true).encode(manifest)
            try data.write(
                to: directoryURL.appendingPathComponent("manifest.json"),
                options: [.atomic]
            )
        } catch {
            throw CaptureInboxProtocolError.writeFailed(error.localizedDescription)
        }
    }

    private static var protectedDirectoryAttributes: [FileAttributeKey: Any] {
        #if os(iOS)
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
            [:]
        #endif
    }

    private static func encoder(prettyPrinted: Bool = false) -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = prettyPrinted
            ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            : [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

public struct RecoveredCaptureSession: Hashable, Sendable {
    public var manifest: CaptureManifest
    public var lastSequence: Int64
    public var journalRecoveredSegmentCount: Int

    public init(
        manifest: CaptureManifest,
        lastSequence: Int64,
        journalRecoveredSegmentCount: Int
    ) {
        self.manifest = manifest
        self.lastSequence = lastSequence
        self.journalRecoveredSegmentCount = journalRecoveredSegmentCount
    }
}

public struct CaptureProtocolReader: Sendable {
    public var maximumManifestBytes: Int
    public var maximumJournalBytes: Int
    public var maximumJournalLineBytes: Int

    public init(
        maximumManifestBytes: Int = 1_048_576,
        maximumJournalBytes: Int = 8_388_608,
        maximumJournalLineBytes: Int = 65536
    ) {
        self.maximumManifestBytes = maximumManifestBytes
        self.maximumJournalBytes = maximumJournalBytes
        self.maximumJournalLineBytes = maximumJournalLineBytes
    }

    public func loadSession(at directoryURL: URL) throws -> RecoveredCaptureSession {
        let manifestURL = directoryURL.appendingPathComponent("manifest.json")
        let manifestData = try boundedData(at: manifestURL, maximumBytes: maximumManifestBytes)
        let decoder = Self.decoder()
        var manifest: CaptureManifest
        do {
            manifest = try decoder.decode(CaptureManifest.self, from: manifestData)
        } catch {
            throw CaptureInboxProtocolError.invalidManifest(error.localizedDescription)
        }
        // `minimumReaderVersion` — not the writer's schema version — is the gate.
        // Requiring an exact schema match would strand every session recorded
        // before an upgrade, which is exactly the media this reader exists to
        // recover.
        guard manifest.minimumReaderVersion <= CaptureManifest.currentSchemaVersion else {
            throw CaptureInboxProtocolError.invalidSchema(
                found: manifest.schemaVersion,
                supported: CaptureManifest.currentSchemaVersion
            )
        }

        let journalURL = try safeRelativeFileURL(
            manifest.eventsRelativePath,
            inside: directoryURL
        )
        let journalData = try boundedData(at: journalURL, maximumBytes: maximumJournalBytes)
        let lines = journalData.split(separator: 0x0A, omittingEmptySubsequences: true)
        let hasTerminatingNewline = journalData.last == 0x0A
        var lastSequence: Int64 = 0
        var recoveredCount = 0

        for (index, line) in lines.enumerated() {
            guard line.count <= maximumJournalLineBytes else {
                throw CaptureInboxProtocolError.invalidJournal("A journal record exceeds the permitted size.")
            }
            let event: CaptureJournalEvent
            do {
                event = try decoder.decode(CaptureJournalEvent.self, from: Data(line))
            } catch {
                if index == lines.count - 1, !hasTerminatingNewline { break }
                throw CaptureInboxProtocolError.invalidJournal(error.localizedDescription)
            }
            guard event.sessionID == manifest.sessionID, event.sequence == lastSequence + 1 else {
                throw CaptureInboxProtocolError.invalidJournal("Journal session or sequence is invalid.")
            }
            lastSequence = event.sequence
            if event.kind == .segmentCommitted, let segment = event.segment,
               !manifest.files.contains(where: { $0.relativePath == segment.relativePath }) {
                manifest.files.append(segment)
                manifest.duration = max(manifest.duration, segment.start + segment.duration)
                recoveredCount += 1
            }
            switch event.kind {
            case .finalized:
                manifest.state = .finalized
            case .interrupted:
                manifest.state = .interrupted
                manifest.failureReason = event.detail
            case .storageConstrained:
                manifest.state = .storageConstrained
                manifest.failureReason = event.detail
            case .failed:
                manifest.state = .failed
                manifest.failureReason = event.detail
            case .importAcknowledged:
                manifest.state = .imported
            default:
                break
            }
            manifest.updatedAt = max(manifest.updatedAt, event.recordedAt)
        }

        return RecoveredCaptureSession(
            manifest: manifest,
            lastSequence: lastSequence,
            journalRecoveredSegmentCount: recoveredCount
        )
    }

    /// Reads at most `maximumBytes`, bounding on the bytes actually read rather
    /// than on a stat taken beforehand. The extension appends to these files
    /// while the app reads them, so a size check is racy and a memory mapping
    /// can tear or fault under it.
    private func boundedData(at url: URL, maximumBytes: Int) throws -> Data {
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else {
                throw CaptureInboxProtocolError.readFailed("Capture protocol file is not a regular file.")
            }
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            let data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
            guard data.count <= maximumBytes else {
                throw CaptureInboxProtocolError.readFailed("Capture protocol file exceeds the permitted size.")
            }
            return data
        } catch let error as CaptureInboxProtocolError {
            throw error
        } catch {
            throw CaptureInboxProtocolError.readFailed(error.localizedDescription)
        }
    }

    private func safeRelativeFileURL(_ relativePath: String, inside root: URL) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.contains("\\"),
              !relativePath.contains("\0"),
              !(relativePath as NSString).isAbsolutePath
        else {
            throw CaptureInboxProtocolError.invalidManifest("The events path is unsafe.")
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CaptureInboxProtocolError.invalidManifest("The events path is unsafe.")
        }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = root.appendingPathComponent(relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let prefix = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"
        guard resolved.path.hasPrefix(prefix) else {
            throw CaptureInboxProtocolError.invalidManifest("The events path escapes the session directory.")
        }
        return resolved
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
