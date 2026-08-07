# Technical requirements document

## 1. System objective

Build a deterministic, crash-tolerant, local media editor whose UI can remain simple while its project representation supports multiple capture sources, output aspects, macOS adapters, and optional AI/cloud services.

## 2. Supported platforms and toolchain

| Item | Baseline |
|---|---|
| Language | Swift 6.2 with strict concurrency |
| App UI | SwiftUI; targeted UIKit/AppKit wrappers for media/system pickers and precision controls |
| Minimum deployment proposal | iOS/iPadOS 18, macOS 15; revisit from device research |
| Enhanced APIs | iOS 26 SpeechAnalyzer and newer capture APIs behind availability checks |
| Build | Xcode project for app/extension plus Swift Package Manager for reusable modules |
| Backend | None required for core; optional Node.js/TypeScript gateway described by OpenAPI 3.1 |
| CI | macOS runner: Swift tests, iOS simulator build, gateway typecheck/test, contract lint |

The installed SDK verification is documented in [08-research-sources.md](08-research-sources.md). Do not hard-code the assumption that the same screen-capture framework is available on every Apple platform or OS revision.

## 3. Native stack

- **Capture:** ReplayKit adapters and broadcast upload extension on current iOS baseline; ScreenCaptureKit on macOS; AVFoundation camera and media import.
- **Time/media:** Core Media time at adapter boundaries; integer microseconds in the portable domain; AVAssetReader/Writer and AVVideoComposition; custom AVVideoCompositing/Metal path when responsive layout/effects exceed built-in instructions.
- **Graphics:** Metal + Core Image for full render; SwiftUI/Metal preview surface; Core Animation only for effects with verified preview/export parity.
- **Audio:** AVAudioEngine/AVAudioUnit for preview and offline processing; Accelerate/vDSP for analysis; preserve source sample rates and explicitly convert at render.
- **Speech/vision:** Speech/SpeechAnalyzer with fallback adapter, Vision OCR/face/person observations, Core ML for optional local focus/highlight models, NaturalLanguage for light local segmentation.
- **Persistence:** JSON project/edit manifests in a versioned project package, SQLite/SwiftData only for replaceable library/search indexes, Keychain for secrets, App Group files/journal for extension handoff.
- **Concurrency:** actor-owned repositories, capture state machines, render jobs, and analysis jobs; AsyncSequence event streams; bounded queues for sample buffers.

## 4. Functional technical requirements

### Capture

- `CaptureSession` is a state machine: idle → preparing → ready → recording → stopping → finalized/failed.
- Framework callbacks immediately enqueue or persist buffers; they never perform OCR, inference, or UI work.
- Video, app audio, mic audio, camera, interaction events, and state events remain separate logical sources.
- The broadcast extension writes into an App Group inbox, never directly into the primary project database.
- Capture uses fragmented files or bounded segments and an append-only journal. Finalization writes a manifest atomically.
- Backpressure policy prefers dropping non-key preview/analysis work; it must not silently block the framework callback and destabilize capture.
- Each session records capture capabilities, codec, dimensions, frame rate, color metadata, audio format, timebase anchors, app/OS/device build, and interruptions.

### Ingest and proxies

- Hash source files with a streaming SHA-256 digest and assign stable asset IDs independent of filenames.
- Normalize metadata/orientation without transcoding the immutable source.
- Generate thumbnails, filmstrips, waveforms, low-resolution proxies, and analysis audio as rebuildable cache products.
- Detect variable frame rate and preserve a time mapping. The domain never assumes frame number equals elapsed time.

### Edit graph

- Project manifest holds identity/settings; timeline document holds tracks, clips, captions, focus events, and output overrides.
- Clips reference source asset plus source time range; never duplicate media for a simple edit.
- Commands are validated, applied through one reducer, and logged for undo/redo. Persist canonical state plus a bounded command history/checkpoint.
- Automatic analysis creates `Suggestion` objects. Accepting one creates an ordinary edit command; rejecting it records user intent without deleting evidence.
- Schema migrations are pure, versioned, idempotent, backed up before write, and tested with fixtures.

### Preview and render

- Compile the edit graph into a `RenderPlan` independent of AVFoundation.
- Use the same geometry/effect functions in preview and export; only sampling/quality changes.
- Evaluate output layout at render time from normalized coordinates and target canvas, allowing one timeline to drive several aspects.
- Focus motion is a critically damped/smooth curve with configurable minimum dwell, transition duration, maximum scale/velocity, bounds padding, and conflict merge rules.
- Renderer selects passthrough/export-session paths when edits allow, built-in video composition for ordinary transforms, and Metal/custom compositor for layered responsive scenes, tracked masks, styled captions, or advanced effects.
- All render jobs are cancelable, write to a unique temporary URL, validate result, then atomically move to final output.

### Audio

- Use a common project timeline and explicit clock mapping for every audio track.
- Calculate waveform, RMS, peak, and integrated loudness during analysis.
- v1 processing order: source trim → high-pass/voice cleanup → gain/normalization → ducking/automation → limiter → output conversion.
- Preview/export graphs must share parameter values; document any algorithmic difference.
- Guard against route changes, Bluetooth latency, drift, clipping, and missing channel layouts.

### Transcription and captions

- Adapter output is word-level tokens where supported: text, start/end, confidence, speaker, locale.
- Caption segmentation is deterministic and separate from recognition. It respects maximum lines/characters, reading rate, punctuation, shot changes, and safe zones.
- User edits attach to stable token/cue identifiers. Re-analysis performs a three-way merge and cannot silently replace corrected text.
- Export SRT/VTT from project time after all clip/time-remap edits.

### AI and automation

- Local and remote providers implement the same protocols.
- Jobs contain input hashes, policy/consent snapshot, provider/model/rule versions, attempt count, status, result hash, and error.
- Cloud default sends transcript and low-resolution evidence only when the chosen feature needs them; raw media requires separate consent.
- Remote responses must pass schema validation and semantic validation (valid ranges, no overlap violation, evidence exists) before becoming suggestions.
- Cache AI results by normalized input hash and provider version.
- Do not call remote AI from a capture extension.

## 5. Non-functional requirements

| Area | Requirement |
|---|---|
| Capture reliability | ≥99.9% sessions either finalize or present recoverable fragments in qualification suite |
| Export reliability | ≥99% reference matrix success before release; errors are typed and actionable |
| A/V sync | target within ±20 ms at start/end for ordinary projects; never exceed ±40 ms without warning |
| Preview | 30 fps interaction target at proxy quality on supported baseline iPad; degrade effects before dropping UI responsiveness |
| Capture callback | no disk/network/ML blocking on framework callback queue; bounded handoff |
| Autosave | visible edits durable within 1 second after interaction settles |
| Launch/library | first useful project list under 1 second for 500 indexed projects; lazy media inspection |
| Memory | adaptive proxy/texture cache; respond to memory warning; extension budget tested empirically with margin |
| Storage | preflight estimate, continuous reserve, segment finalization, cache purge policy |
| Determinism | same source, manifest, renderer version, and preset produce equivalent timeline and geometry |
| Privacy | no network needed for core; explicit consent and disclosure for every external data class |
| Accessibility | critical workflow operable with VoiceOver and keyboard/Switch Control |

## 6. Error model

Errors use a stable domain code plus human recovery action:

- `capture.permissionDenied`, `capture.sourceUnavailable`, `capture.interrupted`, `capture.storageExhausted`, `capture.extensionTerminated`
- `media.unsupported`, `media.corrupt`, `media.missing`, `media.clockMappingFailed`
- `project.schemaTooNew`, `project.migrationFailed`, `project.writeFailed`
- `analysis.assetsUnavailable`, `analysis.canceled`, `analysis.providerRejected`, `analysis.invalidResult`
- `render.unsupportedCombination`, `render.insufficientStorage`, `render.encoderFailed`, `render.validationFailed`

Do not collapse these into a generic alert. Diagnostics contain IDs and metadata, never raw transcript/media unless the user explicitly includes it.

## 7. Security and privacy

- App Group access is limited to app/extension identifiers; import only finalized, schema-valid manifests with canonicalized relative paths.
- Reject traversal, symlink escapes, oversized manifests, unknown executable/template content, and untrusted archive decompression bombs.
- Project packages never execute embedded code. Templates are declarative and schema-validated.
- Secrets live in Keychain and are unavailable to extensions unless explicitly required by access group.
- Optional gateway authenticates short-lived app/user sessions, enforces request size/rate limits, strips logs, and never exposes provider keys to clients.
- Network security uses TLS; pinning is optional and must include an operable rotation plan.
- Recording consent/indicator and third-party AI disclosure follow Apple App Review Guidelines 2.5.14 and 5.1.
- Provide project delete, cache purge, AI history delete, and export diagnostics controls.

## 8. Testing strategy

### Unit and property tests

- time arithmetic, range transforms, layout/focus clamping, edit reducer, migrations, caption segmentation, render-plan compilation, API validation.
- generate random non-overlapping/overlapping clip cases and assert plan invariants.

### Golden tests

- render short synthetic projects in each aspect; compare geometry, selected frames, audio duration, caption timing, and perceptual image deltas.
- version goldens intentionally when renderer changes.

### Capture/device tests

- interruption by call/Siri/lock/orientation/audio route/thermal warning/low storage/app termination.
- own-app and broadcast extension; mic on/off; app audio variations; protected/blank source behavior.
- oldest supported phone, baseline iPad, current Pro devices, external display/storage.

### Performance tests

- 5, 30, 90, and 180-minute projects; 1080p/4K; vertical/landscape; caption-heavy; multilayer; low storage; cold proxy cache.
- measure real-time factor, peak memory, thermal state, dropped frames, energy, output size.

### AI evaluation

- fixed consent-safe datasets; transcription WER, caption boundary quality, focus precision/comfort, highlight precision@k, privacy suggestion recall/false positives.
- compare suggestion acceptance against manual baselines; never use lower cost/latency as success if quality gates fail.

## 9. Observability

Local structured logs use job/session IDs and signposts. An opt-in telemetry envelope may include capability state, durations, outcome codes, performance buckets, and feature events. It excludes file paths, screen content, transcript, media hashes usable as identifiers, and typed annotation text.

Support export contains manifest summaries, versions, error codes, and redacted logs. Media inclusion is a separate explicit action.

## 10. Release and migration

- Feature flags gate capture adapters, local models, cloud providers, and advanced render paths.
- Every app release reads all supported older project schemas and writes only after backup/migration.
- Preserve `minimumReaderVersion` and renderer version in project packages.
- Ship renderer/model updates with reproducibility metadata; existing accepted edits remain stable.
- Beta distribution starts with import/edit/export, then own-app capture, then broadcast capture after device qualification.
