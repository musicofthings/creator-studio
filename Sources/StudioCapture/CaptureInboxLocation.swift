import Foundation

/// The identifiers the app, the broadcast extension, and the Xcode project
/// generator must all agree on. A mismatch fails silently at runtime — the
/// App Group container simply resolves to `nil` — so this is the only Swift-side
/// definition. `Configuration/identifiers.json` mirrors it for the Ruby
/// generator, and `identifiersMatchGeneratorConfiguration` fails if they drift.
public enum CaptureInboxLocation {
    public static let appGroupID = "group.com.example.CreatorStudio"
    public static let appBundleID = "com.example.CreatorStudio"
    public static let broadcastExtensionBundleID = "com.example.CreatorStudio.Broadcast"
    public static let inboxDirectoryName = "CaptureInbox"

    public static func containerURL(fileManager: FileManager = .default) -> URL? {
        fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    public static func inboxURL(fileManager: FileManager = .default) -> URL? {
        containerURL(fileManager: fileManager)?
            .appendingPathComponent(inboxDirectoryName, isDirectory: true)
    }

    /// Creates the inbox with an explicit data-protection class. Relying on the
    /// default would let writes start failing the moment the screen locks
    /// mid-recording.
    @discardableResult
    public static func createInbox(fileManager: FileManager = .default) throws -> URL {
        guard let url = inboxURL(fileManager: fileManager) else {
            throw CaptureInboxProtocolError.writeFailed("The App Group capture container is unavailable.")
        }
        var attributes: [FileAttributeKey: Any] = [:]
        #if os(iOS)
            attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
        #endif
        try fileManager.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: attributes
        )
        return url
    }
}

/// Signals inbox changes so readers do not have to poll. The extension replaces
/// `manifest.json` atomically, which renames into the session directory and
/// therefore fires a directory event; the fallback interval covers the cases a
/// vnode source cannot see.
public struct CaptureInboxWatcher: Sendable {
    public let url: URL
    public let fallbackInterval: TimeInterval

    public init(url: URL, fallbackInterval: TimeInterval = 5) {
        self.url = url
        self.fallbackInterval = fallbackInterval
    }

    /// Yields once immediately, then on every observed change.
    public func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: "com.creatorstudio.capture-inbox-watcher", qos: .utility)
            let descriptor = open(url.path, O_EVTONLY)
            let directorySource: DispatchSourceFileSystemObject? = descriptor >= 0
                ? DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: descriptor,
                    eventMask: [.write, .rename, .delete, .attrib],
                    queue: queue
                )
                : nil

            if let directorySource {
                directorySource.setEventHandler { continuation.yield(()) }
                directorySource.setCancelHandler { close(descriptor) }
                directorySource.resume()
            }

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(
                deadline: .now(),
                repeating: .milliseconds(Int(fallbackInterval * 1000)),
                leeway: .seconds(1)
            )
            timer.setEventHandler { continuation.yield(()) }
            timer.resume()

            continuation.onTermination = { _ in
                timer.cancel()
                directorySource?.cancel()
            }
        }
    }
}
