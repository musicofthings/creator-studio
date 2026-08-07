import Foundation
import StudioDomain

public protocol TimelineCompiling: Sendable {
    func compile(
        timeline: TimelineDocument,
        assets: [SourceAsset],
        canvas: CanvasSpec
    ) throws -> RenderPlan
}

public enum TimelineCompilationError: Error, Equatable, Sendable {
    case invalidCanvas
    case missingAsset(AssetID)
    case duplicateAsset(AssetID)
    case invalidSourceRange(ClipID)
    case invalidTimelineRange(ClipID)
    case invalidPlaybackRate(ClipID)
    case invalidTransform(ClipID)
    case invalidFocus(FocusID)
    case invalidCaption(CaptionID)
}

public struct TimelineCompiler: TimelineCompiling {
    public init() {}

    public func compile(
        timeline: TimelineDocument,
        assets: [SourceAsset],
        canvas: CanvasSpec
    ) throws -> RenderPlan {
        guard canvas.width > 0, canvas.height > 0 else {
            throw TimelineCompilationError.invalidCanvas
        }

        // A repeated asset ID means the project manifest is corrupt. Reporting it
        // is the job of the compiler; `Dictionary(uniqueKeysWithValues:)` would
        // trap instead and take the app down.
        var assetsByID: [AssetID: SourceAsset] = [:]
        assetsByID.reserveCapacity(assets.count)
        for asset in assets {
            guard assetsByID.updateValue(asset, forKey: asset.id) == nil else {
                throw TimelineCompilationError.duplicateAsset(asset.id)
            }
        }
        var layers: [RenderLayer] = []

        for track in timeline.tracks.sorted(by: { $0.order < $1.order }) where !track.isMuted {
            for clip in track.clips where clip.isEnabled {
                guard let asset = assetsByID[clip.assetID] else {
                    throw TimelineCompilationError.missingAsset(clip.assetID)
                }
                guard clip.playbackRate.isFinite, clip.playbackRate > 0 else {
                    throw TimelineCompilationError.invalidPlaybackRate(clip.id)
                }
                guard clip.sourceRange.isValid, clip.sourceRange.end <= asset.duration else {
                    throw TimelineCompilationError.invalidSourceRange(clip.id)
                }
                guard clip.timelineStart >= .zero, clip.timelineDuration > .zero else {
                    throw TimelineCompilationError.invalidTimelineRange(clip.id)
                }
                guard clip.transform.frame.isFinite,
                      clip.transform.frame.isPositive,
                      clip.transform.rotationDegrees.isFinite,
                      clip.transform.opacity.isFinite,
                      (0 ... 1).contains(clip.transform.opacity)
                else {
                    throw TimelineCompilationError.invalidTransform(clip.id)
                }

                layers.append(
                    RenderLayer(
                        id: clip.id,
                        trackID: track.id,
                        trackKind: track.kind,
                        asset: asset,
                        sourceRange: clip.sourceRange,
                        timelineRange: clip.timelineRange,
                        playbackRate: clip.playbackRate,
                        transform: clip.transform,
                        gainDB: clip.gainDB
                    )
                )
            }
        }

        let layerDuration = layers.map(\.timelineRange.end).max() ?? .zero
        let captionDuration = timeline.captions.map(\.timeRange.end).max() ?? .zero
        let focusDuration = timeline.focusEvents.map(\.timeRange.end).max() ?? .zero
        let duration = max(layerDuration, captionDuration, focusDuration)

        let focusInstructions = try timeline.focusEvents.map { event in
            guard event.timeRange.isValid,
                  event.region.isFinite,
                  event.region.isPositive,
                  event.strength.isFinite,
                  event.confidence.isFinite
            else {
                throw TimelineCompilationError.invalidFocus(event.id)
            }
            return FocusInstruction(
                id: event.id,
                timeRange: event.timeRange,
                region: event.region.clampedToFrame(),
                strength: min(max(event.strength, 0), 1)
            )
        }

        for caption in timeline.captions {
            guard caption.timeRange.isValid,
                  !caption.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else {
                throw TimelineCompilationError.invalidCaption(caption.id)
            }
        }

        return RenderPlan(
            projectID: timeline.projectID,
            timelineID: timeline.id,
            revision: timeline.revision,
            canvas: canvas,
            duration: duration,
            layers: layers,
            focus: focusInstructions.sorted { $0.timeRange.start < $1.timeRange.start },
            captions: timeline.captions.sorted { $0.timeRange.start < $1.timeRange.start }
        )
    }
}
