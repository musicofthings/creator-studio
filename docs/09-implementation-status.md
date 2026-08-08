# Implementation status

**Updated:** 8 August 2026
**Milestone:** native macOS capture/workspace and E3 ingest slices implemented; runtime capture qualification pending

## macOS desktop foundation vertical slice

The repository now generates a native `CreatorStudioMac` target for macOS 15. Its `NavigationSplitView` desktop shell lists and creates projects through the same `FileProjectRepository`, opens the shared project/timeline schema, imports user-selected video and audio into immutable project storage, previews project-owned media, and renders a desktop timeline overview. The macOS target does not introduce a second project format or bypass the existing store.

Screen recording starts only after the creator chooses a window, application, or display in the system ScreenCaptureKit picker. The adapter can include system/application audio and microphone audio, keeps those sources separate, renders the cursor and click indicator, excludes Creator Studio's own audio, and caps capture dimensions to an even, aspect-preserving 4K working size. The app is sandboxed, uses a sandbox-owned recovery inbox, and has no network dependency.

ScreenCaptureKit sample buffers feed the same bounded `CaptureWriterPipeline` used by the ReplayKit foundation. Screen, application audio, and microphone are written as independent ten-second H.264/AAC segments. Every committed segment is hashed and journaled before the manifest replacement. A normal stop finalizes all open writers; an unexpected stream stop records an interrupted manifest and preserves every committed segment for the same path, hash, size, role, and immutable-copy validation used on iOS.

Still pending on macOS: signed/runtime Screen Recording and microphone qualification; A/V sync, long-capture, protected-content, thermal, storage, and multi-display measurement; editable pointer paths and input-monitoring metadata; camera capture; menu bar controls; external-drive handoff; and the full precision timeline editor. An unsigned SDK build proves compilation and package integration but does not prove TCC permission behavior or real ScreenCaptureKit media delivery.

## E3 media ingest vertical slice

`AVAssetMediaInspector` now records natural and presentation-oriented dimensions, the full preferred affine transform, source presentation start/duration, nominal and sampled frame rate, variable-frame-rate detection, and audio sample rate/channel count. These additive fields live with `SourceAsset`; existing schema-v1 packages without them still decode. Rendering and proxy work can use presentation timestamps instead of assuming that a frame index equals elapsed time, and source orientation is preserved without transcoding the immutable file.

Capture import now bootstraps real screen, application-audio, and microphone timeline tracks. Every segment retains its `captureStart` on the shared session clock, including small A/V offsets and gaps. The synchronized initial timeline is persisted atomically with the project manifest and a clean edit-history baseline; import no longer stops after copying sources.

The macOS workspace schedules ingest after import and when an older project opens. Video receives a local 960×540 editing proxy, audio receives a bounded min/max waveform envelope, and video with audio receives both. Each asset has a content-hash/generator-version cache manifest under its package-owned `cache/` directory. Jobs expose progress, can be canceled or retried, reuse valid products after relaunch, and never mutate authoritative media. The desktop source list shows ingest state, preview prefers a completed proxy, and timeline clips render available waveforms.

## Phase 1 project workspace vertical slice

The project library now opens a real workspace instead of ending at a static row. Video and audio can be selected through the Files document picker, inspected with AVFoundation, and copied into project-owned `sources/` storage while the security-scoped source is available. The copy is streamed through SHA-256, bounded by the import size limit while bytes are read, marked read-only, and recorded with original filename, byte count, duration, and video dimensions. The external file is never moved or modified.

Every successful import appends a deterministic, non-destructive clip to the corresponding screen, camera, microphone, app-audio, or music track and increments the persisted timeline revision. Existing clips on the same track remain sequential; separate source roles remain on separate tracks. The workspace provides AVPlayer-backed preview, selectable source metadata, and a horizontally scrollable timeline shell. Failed imports remove partial media and roll project/timeline documents back to their previous values.

The interrupted-capture discovery cache now re-evaluates its time-derived stale status even when the manifest has stopped changing, so a session cached while active becomes recoverable after an extension crash. Project creation also removes incomplete packages if any root state document cannot be written, and extreme playback rates no longer trap timeline-duration calculation.

## Phase 1 timeline editing vertical slice

All interactive timeline mutations now pass through one deterministic domain reducer. The command set covers add, trim, split, reorder with ripple close, delete, and enable/disable. The clip inspector exposes half-second trim adjustments, an explicit split-point slider, earlier/later movement, disable, and delete actions. Selection is clip-specific even when several clips reference one asset, and preview seeks to the selected clip's immutable source range.

Each project persists a bounded 50-entry command history in `timeline-history.json` beside the canonical `timeline.json`. Undo and redo survive relaunch, maintain monotonically increasing timeline revisions, and preserve source assets even when their clips are removed. Project manifest, timeline, and history updates use atomic file replacement with rollback to the previous workspace if any write fails. Older packages without a history file open with an empty compatible history.

Still pending in Phase 1: Photos/share-sheet import, thumbnails/filmstrips and analysis-audio caches, direct drag gestures and a project-wide playhead, duplicate and cross-track moves, source inspector controls, camera/audio recording, render implementation, export destinations, performance signposts, and golden media tests.

## Implemented behavior

The ReplayKit broadcast extension is a thin adapter. Queue accounting, segment rotation, storage guarding, drop policy, and finish ordering live in `CaptureWriterPipeline` in `StudioCapture`, which is generic over an opaque sample type and therefore unit tested without a device; the extension supplies only the ReplayKit timing closure, the `AVAssetWriter`-backed `SegmentWriting` implementation, and the volume-capacity probe. It writes independent H.264 screen-video, AAC app-audio, and AAC microphone-audio files as ten-second segments. No analysis, editing, AI, network, or project-database work runs in the extension.

The in-flight queue is bounded per source (3 video, 24 audio) to stay well inside the broadcast extension's memory ceiling. Queue overflow and encoder backpressure drop the affected sample and increment a per-source counter that is journaled in batches and summarized at finish; only a genuine writer error, unusable sample timing, or a storage reserve breach stops capture. Losing a frame is preferable to losing the remainder of a long session, and every drop stays on the record.

Every session is created under `CaptureInbox/<session UUID>/` in the configured App Group container. `events.jsonl` is append-only and flushed for lifecycle and segment-commit records. `manifest.json` is schema version 1 and atomically replaced after each journaled commit. Segment records contain role, relative path, byte length, timing in integer microseconds, and a streaming SHA-256 digest. An interrupted process can therefore recover every finalized segment even if it died after the journal flush but before the next manifest replacement. A currently open `.partial` segment is never represented as committed media.

The host app discovers current, finalized, interrupted, low-storage, failed, and imported sessions. Recordings left in `recording` state become recoverable only after a stale interval, preventing the app from importing a live extension session. Import rejects unsupported schemas or roles, absolute/traversal/backslash paths, duplicate paths, symlink escapes, unexpected media extensions, non-regular files, size mismatches, oversized files, and digest mismatches. Valid media is copied—not moved—to unique project-owned source paths, hashed again after the copy, marked read-only, and recorded with capture-session provenance and source start time. Initial role-specific clips retain that source start on the shared capture clock. The inbox is acknowledged only after project, timeline, and clean history documents are durably saved; repeated imports are idempotent by session ID and digest.

The iOS preflight checks the requested capability set, App Group availability, microphone denial, thermal state, and available storage. The UI exposes ready, recording, stopping, importing, recovered, failed, and storage-constrained states. It states that recording requires an explicit action in the system picker, the system indicator remains visible, media stays on-device, and Creator Studio performs no cloud upload.

## Automated verification

- Swift package suite covers the capture state machine, low-storage and capability seams, atomic manifest/journal replay, injected interruption, traversal, symlink, hash mismatch, partial-import reporting, immutable copy behavior, reader/writer schema compatibility, identifier drift between Swift and the project generator, deterministic timeline commands, bounded history, persisted undo/redo, synchronized capture-track bootstrapping, media metadata persistence, real AVFoundation audio/video fixture inspection, proxy export, waveform reuse, and cache cancellation.
- `CaptureWriterPipeline` is covered directly with an injected fake writer: queue-full and backpressure drops, batched drop journaling, rotation at the segment boundary, writer failure as terminal with committed segments preserved, storage-reserve stop, unusable sample timing, observed-source recording, and finish ordering (waiters released only after every segment commits, repeat finishes are inert, post-finish samples ignored).
- The Xcode project generator links only `StudioDomain` and `StudioCapture` into the broadcast extension; the extension does not gain project-store, media-analysis, AI, or export dependencies.
- The app and embedded broadcast extension build for the generic iOS Simulator with code signing disabled.
- The native macOS app builds against the macOS SDK with code signing disabled, including strict-concurrency checks across ScreenCaptureKit delegate and sample-output boundaries.
- The optional AI gateway tests and TypeScript typecheck remain part of `make check`; capture introduces no gateway or cloud dependency.

## Signed physical-device verification required

ReplayKit broadcast buffers and App Group sharing cannot be qualified by an unsigned generic Simulator build. Before calling the Phase 0 exit gate complete:

1. Replace `com.example.CreatorStudio`, `com.example.CreatorStudio.Broadcast`, and `group.com.example.CreatorStudio` in `Configuration/identifiers.json` and `CaptureInboxLocation`, then run `make xcodeproj` to regenerate both entitlements. `swift test` fails if the two sources disagree.
2. Select an Apple development team, create matching App IDs/App Group capability, regenerate the Xcode project, and install the app plus extension on an iPhone and iPad.
3. From Capture Preflight, deliberately start the Creator Studio system broadcast with microphone off and on. Exercise apps that provide and omit app audio. Confirm separate playable screen/app-audio/microphone segments, orientation metadata, duration, and sync.
4. Stop normally and verify the session moves through stopping to ready-to-import, then imports immutable sources without changing the inbox originals.
5. Force extension termination during the first segment, after several committed segments, during rotation, and during stop finalization. Relaunch the app and verify only finalized segments appear as recovered; no committed segment is lost.
6. Inject low-storage conditions above and below the 1 GB reserve. Confirm capture stops with the storage-constrained state and previously committed segments import successfully.
7. Run 5- and 30-minute captures across the supported device/OS matrix. Record extension peak memory, encoder backpressure, dropped/failed samples, thermal state, segment continuity, A/V offset/drift, and protected-content behavior.
8. Complete 50 forced-interruption runs with no loss of committed segments before checking the Phase 0 recovery exit gate.

## Known risks and boundaries

- The ten-second segmentation interval bounds interruption exposure to the currently open segment, but the interval and encoder bit rates still need device-specific memory, thermal, and quality tuning.
- Writer backpressure is lossy and recorded rather than fail-fast: samples are dropped and journaled instead of ending the session. Device measurement must confirm that the per-source queue bounds hold extension peak memory inside the platform limit and that the observed drop rate is acceptable on older devices.
- Screen, app audio, and microphone remain independent immutable sources. Initial tracks retain recorded offsets and proxy/waveform caches are rebuildable; signed-capture A/V measurement and explicit sync-adjustment UI remain outstanding.
- ReplayKit may omit protected content or app audio by platform policy. The UI and manifest capability model must continue to describe observed availability rather than promise it.
- Placeholder identifiers and unsigned builds are intentionally not treated as proof that App Group handoff works on a physical device.

## Next milestone

The highest-value next milestone is the macOS precision editor slice: reuse the deterministic timeline command inspector on desktop, add a project-wide playhead and timeline-aware preview, then compile the first 1080p landscape/vertical render through the existing `RenderPlan` boundary. Proxy and waveform products can now support that work without weakening the immutable-source boundary.
