import Foundation
import StudioAI
import StudioDomain
import StudioExport
import StudioMediaPipeline
import StudioProjectStore

@main
enum StudioDemo {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("creator-studio-demo-\(UUID().uuidString)", isDirectory: true)
        let repository = FileProjectRepository(rootURL: root)
        var project = try await repository.create(title: "Welcome Tutorial", intent: .tutorial)

        let asset = SourceAsset(
            kind: .screenVideo,
            relativePath: "sources/demo.mov",
            duration: StudioTime(seconds: 8),
            pixelSize: PixelSize(width: 1920, height: 1080)
        )
        project.assets.append(asset)
        project.updatedAt = .studioNow()
        try await repository.save(project)

        let clip = TimelineClip(
            assetID: asset.id,
            sourceRange: StudioTimeRange(start: .zero, duration: asset.duration),
            timelineStart: .zero
        )
        let timeline = TimelineDocument(
            id: project.timelineID,
            projectID: project.id,
            tracks: [TimelineTrack(kind: .screen, order: 0, clips: [clip])]
        )
        let plan = try TimelineCompiler().compile(
            timeline: timeline,
            assets: project.assets,
            canvas: .vertical1080
        )

        let suggestion = try await HeuristicFocusEngine().suggestFocus(
            for: FocusAnalysisInput(
                duration: plan.duration,
                candidates: [
                    FocusCandidate(
                        timeRange: StudioTimeRange(
                            start: StudioTime(seconds: 2),
                            duration: StudioTime(seconds: 0.4)
                        ),
                        region: NormalizedRect(x: 0.62, y: 0.12, width: 0.18, height: 0.14),
                        confidence: 0.91,
                        evidence: .exactInteraction,
                        reason: "Primary action"
                    )
                ]
            )
        )

        try ExportPreflight().validate(plan: plan, profile: .verticalShort)
        print("Created project: \(project.title)")
        print("Package: \(await repository.packageURL(for: project.id).path)")
        print("Render duration: \(plan.duration.seconds)s")
        print("Focus suggestions: \(suggestion.count)")
    }
}
