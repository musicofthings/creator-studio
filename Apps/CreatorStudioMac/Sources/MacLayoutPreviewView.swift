import AVFoundation
import AVKit
import StudioDomain
import StudioProjectStore
import SwiftUI

/// Composites screen + camera using clip transforms so the facecam bubble
/// (or split layout) is visible in the editor — not just a single source.
struct MacLayoutPreviewView: View {
    var workspace: ProjectWorkspace
    @ObservedObject var model: MacAppModel
    var captureSessionID: UUID?
    @Binding var player: AVPlayer?
    @State private var errorMessage: String?

    private struct PreviewRequest: Hashable {
        var workspace: ProjectWorkspace
        var sessionID: UUID?
    }

    var body: some View {
        ZStack {
            Color.black
            if let player {
                MacCompositionPlayerView(player: player)
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.white).padding()
            } else {
                ProgressView("Preparing timeline preview…").tint(.white)
            }
        }
        .task(id: PreviewRequest(workspace: workspace, sessionID: captureSessionID)) {
            player?.pause()
            player = nil
            errorMessage = nil
            do {
                let item = try await model.layoutPreviewItem(workspace: workspace, sessionID: captureSessionID)
                try Task.checkCancellation()
                let next = AVPlayer(playerItem: item)
                player = next
                next.play()
            } catch is CancellationError {
                // A newer timeline or session superseded this composition.
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
        .onDisappear { player?.pause() }
    }

    static func primaryClip(
        in workspace: ProjectWorkspace,
        kind: TrackKind,
        captureSessionID: UUID? = nil
    ) -> TimelineClip? {
        let sessionAssetIDs: Set<AssetID>? = {
            guard let captureSessionID else { return nil }
            return Set(
                workspace.project.assets
                    .filter { $0.captureSessionID == captureSessionID }
                    .map(\.id)
            )
        }()
        return workspace.timeline.tracks
            .first(where: { $0.kind == kind })?
            .clips
            .filter(\.isEnabled)
            .filter { clip in
                guard let sessionAssetIDs else { return true }
                return sessionAssetIDs.contains(clip.assetID)
            }
            .sorted { $0.timelineStart < $1.timelineStart }
            .first
    }

    /// True when the whole project has both tracks (legacy helper).
    static func hasDualVideoLayout(_ workspace: ProjectWorkspace) -> Bool {
        let hasScreen = workspace.timeline.tracks.contains { $0.kind == .screen && $0.clips.contains(where: \.isEnabled) }
        let hasCamera = workspace.timeline.tracks.contains { $0.kind == .camera && $0.clips.contains(where: \.isEnabled) }
        return hasScreen && hasCamera
    }

    /// Prefer session-scoped dual layout so Unlisted Recordings does not composite
    /// screen from one capture with camera from another.
    static func hasDualVideoLayout(
        _ workspace: ProjectWorkspace,
        captureSessionID: UUID?
    ) -> Bool {
        guard let captureSessionID else { return false }
        let assets = workspace.project.assets.filter { $0.captureSessionID == captureSessionID }
        let hasScreen = assets.contains { $0.kind == .screenVideo }
        let hasCamera = assets.contains { $0.kind == .cameraVideo }
        return hasScreen && hasCamera
    }
}

/// One player owns timing, seeking, audio and all source segments.
private struct MacCompositionPlayerView: NSViewRepresentable {
    var player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) {
        view.player = player
    }

    static func dismantleNSView(_ view: AVPlayerView, coordinator: ()) {
        view.player?.pause()
        view.player = nil
    }
}
