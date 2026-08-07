# APIs and data model

## 1. Modeling rules

- IDs are UUIDs serialized as lowercase strings.
- Portable time is signed integer microseconds. Adapters convert to and from `CMTime` with explicit timescale/rounding.
- Spatial coordinates are normalized to source/canvas width and height, with origin at top-left in the domain.
- Media sources are immutable. Clips and effects reference them.
- Every document has `schemaVersion`, `minimumReaderVersion`, creation/update timestamps, and renderer/rule provenance where relevant.
- All external inputs pass syntax, size, range, path, and semantic validation.

## 2. Core entities

| Entity | Key fields | Notes |
|---|---|---|
| `StudioProject` | id, title, intent, canvas, assets, timelineID, timestamps, schema versions | Root package manifest |
| `SourceAsset` | id, mediaKind, relativePath, contentHash, duration, dimensions, audio format, capture metadata | Immutable; file may be offline/missing |
| `TimelineDocument` | id, projectID, tracks, focusEvents, captions, annotations, outputOverrides | Canonical non-destructive edit |
| `Track` | id, kind, order, muted, locked, clips | Screen, camera, mic, app audio, music, overlay |
| `Clip` | id, assetID, sourceRange, timelineStart, speed, transform, gain | Instance of a source range |
| `FocusEvent` | id, timeRange, normalizedRect, scale, source, confidence, state | Drives responsive virtual camera |
| `TranscriptWord` | id, text, sourceRange, projectRange, confidence, speaker, locale | Stable token for corrections |
| `CaptionCue` | id, wordIDs/text, timeRange, styleID, line-break override | Segmentation distinct from ASR |
| `Annotation` | id, type, timeRange, geometry, style, tracking reference | Text/arrow/box/freehand/blur |
| `BrandPreset` | id, version, fonts, colors, logo refs, backgrounds, caption/layout styles | Declarative; no executable content |
| `ExportProfile` | id, canvas, codec, resolution, frame rate, color, audio, caption mode | Destination constraints |
| `Suggestion` | id, kind, evidence, value, confidence, provider/version, inputHash, status | Never authoritative by itself |
| `Job` | id, type, state, progress, inputs, consent, attempts, result/error | Analysis and render lifecycle |

## 3. Domain APIs

The bootstrap contains small versions of these Swift protocols; production adapters expand them without changing caller intent.

```swift
public protocol CaptureSession: Sendable {
    var events: AsyncStream<CaptureEvent> { get }
    func prepare(configuration: CaptureConfiguration) async throws -> CaptureCapabilities
    func start() async throws
    func mark(_ label: String?) async
    func stop() async throws -> CaptureArtifact
    func cancel() async
}

public protocol ProjectRepository: Sendable {
    func create(title: String, intent: ProjectIntent) async throws -> StudioProject
    func load(id: ProjectID) async throws -> StudioProject
    func save(_ project: StudioProject) async throws
    func list() async throws -> [ProjectSummary]
}

public protocol TranscriptService: Sendable {
    func transcribe(_ request: TranscriptionRequest) async throws -> TranscriptResult
}

public protocol FocusSuggestionService: Sendable {
    func suggestFocus(for input: FocusAnalysisInput) async throws -> [FocusSuggestion]
}

public protocol TimelineCompiling: Sendable {
    func compile(_ timeline: TimelineDocument, assets: [SourceAsset], profile: ExportProfile) throws -> RenderPlan
}

public protocol RenderService: Sendable {
    func render(_ plan: RenderPlan, to url: URL) -> AsyncThrowingStream<RenderEvent, Error>
}
```

## 4. Capture artifact manifest

The extension/adapter output is an import contract, not the final project:

```json
{
  "schemaVersion": 1,
  "minimumReaderVersion": 1,
  "sessionID": "a44a3f52-bf95-4d98-a3bc-94e96b7fb1ac",
  "state": "finalized",
  "startedAt": "2026-08-07T12:00:00Z",
  "updatedAt": "2026-08-07T12:00:42Z",
  "durationUs": 42150000,
  "capabilities": {
    "screen": true,
    "appAudio": true,
    "microphone": true,
    "camera": false,
    "interactionEvents": false
  },
  "files": [
    {"role": "screen", "relativePath": "segments/screen-0000.mov", "sha256": "...", "byteCount": 8123456, "startUs": 0, "durationUs": 10000000},
    {"role": "microphone", "relativePath": "segments/microphone-0000.m4a", "sha256": "...", "byteCount": 121234, "startUs": 15000, "durationUs": 9990000}
  ],
  "eventsPath": "events.jsonl"
}
```

The extension appends and flushes a `segmentCommitted` journal record before atomically replacing this manifest. Recovery replays journaled commits that are missing from a stale manifest. Only finalized segment files appear in either contract; an open `.partial` writer file is never importable.

The importer accepts only known roles and canonical paths inside the session directory, rejects traversal and symlink escapes, verifies regular-file type, extension, size, and SHA-256, and copies to new project-owned immutable asset paths before acknowledging the inbox item. `recording` and `stopping` sessions are not imported while current; if either becomes stale after an extension interruption, its committed files are presented as recovered media.

## 5. Edit command API

Every edit is a typed command with preconditions and inverse/checkpoint support:

```json
{
  "commandID": "7d16e2bb-97a3-47ee-b8d6-cc8ec7e2dced",
  "baseRevision": 41,
  "type": "focus.upsert",
  "payload": {
    "focusID": "b2f37137-2d96-4f13-803c-25726e781752",
    "startUs": 3100000,
    "durationUs": 1850000,
    "rect": {"x": 0.51, "y": 0.14, "width": 0.34, "height": 0.28},
    "strength": 0.78,
    "provenance": {"kind": "acceptedSuggestion", "suggestionID": "..."}
  }
}
```

The reducer rejects stale revisions or invalid ranges. The UI may rebase non-conflicting local commands; v1 does not support concurrent multi-user edits.

## 6. Optional HTTP API

The source of truth is [contracts/openapi.yaml](../contracts/openapi.yaml). Initial endpoints:

| Method/path | Purpose | Default data class |
|---|---|---|
| `GET /health` | Liveness/version | none |
| `POST /v1/transcriptions` | Transcribe bounded audio | audio, explicit |
| `POST /v1/suggestions` | Chapters, clips, focus, title/show notes | transcript + timing; frames only when declared |
| `GET /v1/jobs/{jobId}` | Poll async provider work | identifiers/status |
| `DELETE /v1/jobs/{jobId}` | Cancel/delete retained job | identifiers |

Headers include request ID, schema version, client build, and an authorization token. Consent is not a boolean; it is a signed/validated receipt containing declared data classes, purpose, timestamp, and policy version.

## 7. Suggestion response

```json
{
  "schemaVersion": 1,
  "inputHash": "sha256:...",
  "provider": {"id": "configured-provider", "model": "server-configured", "version": "2026-08"},
  "suggestions": [
    {
      "id": "4c3df06c-4213-45f7-9d92-09642bd91d52",
      "kind": "socialClip",
      "startUs": 91000000,
      "endUs": 132000000,
      "confidence": 0.86,
      "reason": "Complete problem-and-solution segment with a strong opening claim",
      "evidence": [{"type": "transcriptRange", "startUs": 91000000, "endUs": 132000000}],
      "payload": {"title": "The 40-second fix", "targetAspect": "vertical"}
    }
  ]
}
```

Client validation requires finite/nonnegative in-bounds times, allowed kind/payload schema, evidence that maps to provided inputs, confidence in `[0,1]`, reasonable length, and no control strings interpreted as markup/code.

## 8. Versioning

- Package schema uses integer major versions and explicit `minimumReaderVersion`.
- HTTP path uses `/v1`; additive fields are backward compatible and clients ignore unknown fields only in designated extension maps.
- Presets contain their own semantic version and resolved asset hashes.
- Suggestions record provider/model/rule versions but accepted edit commands remain provider-independent.
- Renderer version is embedded in export provenance and diagnostics, not used to lock users out of older projects.
